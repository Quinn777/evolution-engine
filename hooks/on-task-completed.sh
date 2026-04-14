#!/bin/bash
# ================================================================
# Evolution Engine v2.4 — TaskCompleted Hook
# 当 AI 标记任务为 completed 时触发。
# 检查任务是否真的完成了（验证步骤、未处理错误）。
# ================================================================

EVO_DIR="$HOME/.claude/evolution"
SCRIPTS_DIR="$HOME/.claude/hooks/scripts"
source "$SCRIPTS_DIR/find_python.sh"

# 紧急关闭开关
[ -f "$EVO_DIR/.disabled" ] && exit 0

INPUT=$(cat)

# 安全提取字段（临时文件，不用 eval）
TRANSCRIPT_PATH=""
TASK_SUBJECT=""
TASK_DESCRIPTION=""
if [ -n "$PYTHON" ]; then
  INPUT_FILE=$(mktemp)
  RESULT_FILE=$(mktemp)
  printf '%s' "$INPUT" > "$INPUT_FILE"

  PYTHONUTF8=1 "$PYTHON" -c '
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        d = json.load(f)
    result = {
        "transcript_path": d.get("transcript_path", ""),
        "task_subject": d.get("task_subject", "")[:200],
        "task_description": d.get("task_description", "")[:300]
    }
    with open(sys.argv[2], "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False)
except Exception:
    pass
' "$INPUT_FILE" "$RESULT_FILE" 2>/dev/null

  if [ -s "$RESULT_FILE" ]; then
    TRANSCRIPT_PATH=$("$PYTHON" -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));print(d.get('transcript_path',''))" "$RESULT_FILE" 2>/dev/null)
    TASK_SUBJECT=$("$PYTHON" -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));print(d.get('task_subject',''))" "$RESULT_FILE" 2>/dev/null)
    TASK_DESCRIPTION=$("$PYTHON" -c "import json,sys;d=json.load(open(sys.argv[1],encoding='utf-8'));print(d.get('task_description',''))" "$RESULT_FILE" 2>/dev/null)
  fi
  rm -f "$INPUT_FILE" "$RESULT_FILE"
fi

# 没有 transcript 就无法审查
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  exit 0
fi

# 用 Python 分析 transcript，检查任务完成质量
REVIEW_RESULT=""
if [ -n "$PYTHON" ]; then
  REVIEW_RESULT=$(PYTHONUTF8=1 _EVO_TP="$TRANSCRIPT_PATH" _EVO_SUBJ="$TASK_SUBJECT" _EVO_DESC="$TASK_DESCRIPTION" "$PYTHON" -c "
import json,os

tp = os.environ.get('_EVO_TP','')
subj = os.environ.get('_EVO_SUBJ','')
desc = os.environ.get('_EVO_DESC','')

if not tp or not os.path.exists(tp):
    exit(0)

tool_uses = []
tool_results = []
has_verify_step = False
unhandled_errors = []

try:
    with open(tp, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue

            if entry.get('role') == 'assistant':
                for block in entry.get('content', []):
                    if block.get('type') == 'tool_use':
                        name = block.get('name','')
                        tool_uses.append(name)
                        inp = block.get('input', {})
                        cmd = inp.get('command','')
                        if name == 'Bash' and any(kw in cmd for kw in ['test','pytest','npm test','node ','python ','check','verify','--version','status','diff']):
                            has_verify_step = True

            if entry.get('role') == 'user':
                for block in entry.get('content', []):
                    if block.get('type') == 'tool_result':
                        is_error = block.get('is_error', False)
                        content = block.get('content','')
                        if isinstance(content, list):
                            content = ' '.join(p.get('text','') for p in content if isinstance(p,dict))
                        content = str(content)
                        tool_results.append({'error': is_error, 'preview': content[:100]})
                        if is_error:
                            unhandled_errors.append(content[:100])

except (IOError, OSError):
    exit(0)

if len(tool_uses) < 2:
    exit(0)

issues = []

modify_count = sum(1 for t in tool_uses if t in ('Edit','Write','Bash'))
if modify_count >= 2 and not has_verify_step:
    issues.append('任务涉及 {} 次修改/执行操作但没有验证步骤'.format(modify_count))

if unhandled_errors:
    last_results = tool_results[-3:] if len(tool_results) >= 3 else tool_results
    recent_errors = [r for r in last_results if r['error']]
    if recent_errors:
        issues.append('最近的工具调用中有 {} 个错误未处理: {}'.format(
            len(recent_errors), recent_errors[0]['preview'][:80]))

if issues:
    issues_text = '; '.join(issues)
    ctx = '【任务完成审查】任务\"{}\"被标记为完成，但发现以下问题: {}。请先解决这些问题再标记完成。'.format(subj[:100], issues_text)
    result = {
        'decision': 'block',
        'reason': 'task_completion_check: ' + issues_text,
        'hookSpecificOutput': {
            'hookEventName': 'TaskCompleted',
            'additionalContext': ctx
        }
    }
    print(json.dumps(result, ensure_ascii=False))
" 2>/dev/null)
fi

if [ -n "$REVIEW_RESULT" ]; then
  echo "$REVIEW_RESULT"
fi

exit 0
