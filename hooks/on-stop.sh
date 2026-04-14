#!/bin/bash
# ================================================================
# Evolution Engine v2 — Stop Hook (v2.3)
# v2.3 改造：
#   1. transcript_path 替代手动累积（从 stdin JSON 提取 transcript_path，
#      end_turn 时直接从中读取工具调用和结果）
#   2. stop_hook_active 双保险（true 时直接 exit 0，
#      保留 .block_count 作为跨轮备份防线）
#   3. tool_use 时不再做任何处理，直接 exit 0
# ================================================================

EVO_DIR="$HOME/.claude/evolution"
SIGNALS_DIR="$EVO_DIR/signals"
INSTINCTS_FILE="$EVO_DIR/instincts/index.json"
ACTIVE_VARIANT="$EVO_DIR/active_variant.txt"
CONFIG="$EVO_DIR/config.json"
SCRIPTS_DIR="$HOME/.claude/hooks/scripts"
source "$SCRIPTS_DIR/find_python.sh"
INSTINCT_SCRIPT="$SCRIPTS_DIR/instinct_manager.py"
STATS_SCRIPT="$SCRIPTS_DIR/stats_rw.py"
TASK_REVIEWER="$SCRIPTS_DIR/task_reviewer.py"
BG_SCRIPT="$SCRIPTS_DIR/bg_run.py"
EXAMPLES_FILE="$EVO_DIR/initiative_examples.jsonl"

# 紧急关闭开关
[ -f "$EVO_DIR/.disabled" ] && exit 0

mkdir -p "$SIGNALS_DIR" 2>/dev/null
touch "$SIGNALS_DIR/blocks.jsonl" "$SIGNALS_DIR/sonnet_reviews.jsonl" 2>/dev/null

INPUT=$(cat)
TS=$(date +%Y%m%d_%H%M%S)

# ================================================================
# 改造2：stop_hook_active 双保险
# 如果 stop_hook_active=true，说明这是 hook 自身触发的 stop，
# 直接 exit 0 避免递归
# ================================================================

STOP_HOOK_ACTIVE=""
if [ -f "$PYTHON" ]; then
  STOP_HOOK_ACTIVE=$("$PYTHON" -c "
import sys,json
try:
  d=json.load(sys.stdin)
  if d.get('stop_hook_active',False):
    print('true')
except: pass
" <<< "$INPUT" 2>/dev/null)
fi

if [ "$STOP_HOOK_ACTIVE" = "true" ]; then
  exit 0
fi

# ================================================================
# 改造1：从 stdin JSON 提取 transcript_path
# ================================================================

TRANSCRIPT_PATH=""
if [ -f "$PYTHON" ]; then
  TRANSCRIPT_PATH=$("$PYTHON" -c "
import sys,json
try:
  d=json.load(sys.stdin)
  tp=d.get('transcript_path','')
  if tp: print(tp)
except: pass
" <<< "$INPUT" 2>/dev/null)
fi

# ================================================================
# 文本提取（Bug#5 修复：提取所有 text block 拼接，不只第一个）
# ================================================================

RESPONSE=""
USER_QUESTION=""
if [ -f "$PYTHON" ]; then
  EXTRACTED=$("$PYTHON" -c "
import sys,json
try:
  d=json.load(sys.stdin)
  # Claude Code 实际格式：last_assistant_message 是纯字符串
  msg=d.get('last_assistant_message','')
  if msg:
    print(msg)
  else:
    # 兼容旧格式
    texts=[]
    for c in d.get('assistant_message',{}).get('content',[]):
      if c.get('type')=='text':
        texts.append(c.get('text',''))
    print('\n'.join(texts))
except: pass
" <<< "$INPUT" 2>/dev/null)
  RESPONSE="$EXTRACTED"
fi

if [ -z "$RESPONSE" ]; then
  # 正则 fallback：先试 last_assistant_message，再试 text
  RESPONSE=$(echo "$INPUT" | grep -o '"last_assistant_message":"[^"]*"' | sed 's/"last_assistant_message":"//;s/"$//' | head -1)
  [ -z "$RESPONSE" ] && RESPONSE=$(echo "$INPUT" | grep -o '"text":"[^"]*"' | sed 's/"text":"//;s/"$//' | head -1)
fi

# 无回答文本则跳过
[ -z "$RESPONSE" ] && exit 0

VARIANT=$(cat "$ACTIVE_VARIANT" 2>/dev/null || echo "A")
RLEN=${#RESPONSE}

# ================================================================
# Bug#4 修复：通用 block 计数器（兜底防死循环）——改造2保留为备份防线
# ================================================================

BLOCK_COUNT_FILE="$EVO_DIR/.block_count"
BLOCK_COUNT=$(cat "$BLOCK_COUNT_FILE" 2>/dev/null || echo 0)

# 连续 block 3 次后强制放行
if [ "$BLOCK_COUNT" -ge 3 ]; then
  echo "0" > "$BLOCK_COUNT_FILE"
  echo "{\"time\":\"$TS\",\"event\":\"force_pass_after_3_blocks\",\"variant\":\"$VARIANT\"}" >> "$SIGNALS_DIR/blocks.jsonl"
  exit 0
fi

# ================================================================
# 辅助函数
# ================================================================

update_blocks_stat() {
  if [ -f "$PYTHON" ] && [ -f "$STATS_SCRIPT" ]; then
    "$PYTHON" "$STATS_SCRIPT" increment "$VARIANT" blocks 2>>"$EVO_DIR/error.log" || true
  fi
}

increment_block_count() {
  BLOCK_COUNT=$((BLOCK_COUNT + 1))
  echo "$BLOCK_COUNT" > "$BLOCK_COUNT_FILE"
}

safe_sonnet_review() {
  local prompt_text="$1"
  local tmpfile=$(mktemp)
  echo "$prompt_text" > "$tmpfile"
  local result=$(claude -p --model sonnet < "$tmpfile" 2>/dev/null)
  rm -f "$tmpfile"
  echo "$result"
}

safe_json_block() {
  local reason="$1"
  local context="$2"
  increment_block_count

  # quiet_mode：只输出问题原因，修正格式指令已在 rules 文件中
  local quiet=$(grep -o '"quiet_mode": *true' "$CONFIG" 2>/dev/null)
  if [ -n "$quiet" ]; then
    if [ -f "$PYTHON" ]; then
      PYTHONUTF8=1 _EVO_REASON="$reason" "$PYTHON" -c "
import json,os
reason=os.environ.get('_EVO_REASON','')
print(json.dumps({'decision':'block','reason':reason},ensure_ascii=False))
"
    else
      local esc_r=$(echo "$reason" | sed 's/"/\\"/g' | tr '\n' ' ')
      echo "{\"decision\":\"block\",\"reason\":\"${esc_r}\"}"
    fi
    return
  fi

  # 非 quiet_mode：保持原有行为
  context="${context} 请先输出'---'分隔线，然后给出修正版本。"
  if [ -f "$PYTHON" ]; then
    PYTHONUTF8=1 _EVO_REASON="$reason" _EVO_CTX="$context" "$PYTHON" -c "
import json,os
reason=os.environ.get('_EVO_REASON','')
ctx=os.environ.get('_EVO_CTX',reason)
print(json.dumps({'decision':'block','reason':reason,'hookSpecificOutput':{'hookEventName':'Stop','additionalContext':ctx}},ensure_ascii=False))
"
  else
    local esc_r=$(echo "$reason" | sed 's/"/\\"/g' | tr '\n' ' ')
    local esc_c=$(echo "$context" | sed 's/"/\\"/g' | tr '\n' ' ')
    echo "{\"decision\":\"block\",\"reason\":\"${esc_r}\",\"hookSpecificOutput\":{\"hookEventName\":\"Stop\",\"additionalContext\":\"${esc_c}\"}}"
  fi
}

safe_json_context() {
  local context="$1"
  # block 没触发，重置计数器
  echo "0" > "$BLOCK_COUNT_FILE"

  # quiet_mode 时不输出非 block 的 context（静默通过）
  local quiet=$(grep -o '"quiet_mode": *true' "$CONFIG" 2>/dev/null)
  if [ -n "$quiet" ]; then
    exit 0
  fi

  if [ -f "$PYTHON" ]; then
    PYTHONUTF8=1 _EVO_CTX="$context" "$PYTHON" -c "
import json,os
ctx=os.environ.get('_EVO_CTX','')
print(json.dumps({'hookSpecificOutput':{'hookEventName':'Stop','additionalContext':ctx}},ensure_ascii=False))
"
  else
    local esc=$(echo "$context" | sed 's/"/\\"/g' | tr '\n' ' ')
    echo "{\"hookSpecificOutput\":{\"hookEventName\":\"Stop\",\"additionalContext\":\"${esc}\"}}"
  fi
}

# 安全地后台添加 instinct（Bug#3 修复：用临时文件传递 pattern，不嵌入 bash -c）
safe_bg_add_instinct() {
  local prompt_text="$1"
  local category="$2"
  local source="$3"
  local prompt_file=$(mktemp)
  echo "$prompt_text" > "$prompt_file"
  "$PYTHON" "$BG_SCRIPT" bash -c "
    export PYTHONUTF8=1
    LESSON=\$(claude -p --model sonnet < '$prompt_file' 2>/dev/null)
    rm -f '$prompt_file'
    if [ -n \"\$LESSON\" ] && [ \${#LESSON} -gt 5 ] && [ \${#LESSON} -lt 80 ]; then
      LESSON_FILE=\$(mktemp)
      printf '%s' \"\$LESSON\" > \"\$LESSON_FILE\"
      '$PYTHON' '$INSTINCT_SCRIPT' add-file \"\$LESSON_FILE\" '$category' '$source' 2>/dev/null
      rm -f \"\$LESSON_FILE\"
    fi
  "
}

# ================================================================
# 读取最近用户问题（最近 3 条，提供对话上下文）
# ================================================================

LAST_USER_Q_FILE="$EVO_DIR/.last_user_question"
RECENT_Q_FILE="$EVO_DIR/.recent_user_questions"
USER_QUESTION=""
if [ -f "$LAST_USER_Q_FILE" ]; then
  USER_QUESTION=$(cat "$LAST_USER_Q_FILE" 2>/dev/null | head -c 300)
fi
RECENT_CONTEXT=""
if [ -f "$RECENT_Q_FILE" ]; then
  RECENT_CONTEXT=$(cat "$RECENT_Q_FILE" 2>/dev/null | head -c 600)
fi

# ================================================================
# Bug#2 修复：已修正验证 — 仅当存在 block flag 文件时才进入此路径
# ================================================================

BLOCK_FLAG="$EVO_DIR/.block_active"

if [ -f "$BLOCK_FLAG" ] && echo "$RESPONSE" | grep -q '已修正'; then
  rm -f "$BLOCK_FLAG"

  LAST_BLOCK=$(grep "block_event\|sonnet_block\|debate_block" "$SIGNALS_DIR/blocks.jsonl" | tail -1)
  BLOCK_REASON=$(echo "$LAST_BLOCK" | grep -o '"trigger":"[^"]*"\|"issues":"[^"]*"\|"verdict":"[^"]*"' | sed 's/"trigger":"//;s/"issues":"//;s/"verdict":"//;s/"$//' | head -1)

  REWRITE_COUNT_FILE="$EVO_DIR/.rewrite_count"
  REWRITE_COUNT=$(cat "$REWRITE_COUNT_FILE" 2>/dev/null || echo 0)

  if [ "$REWRITE_COUNT" -ge 2 ]; then
    echo "0" > "$REWRITE_COUNT_FILE"
    echo "0" > "$BLOCK_COUNT_FILE"
    echo "{\"time\":\"$TS\",\"event\":\"rewrite_pass_forced\",\"variant\":\"$VARIANT\"}" >> "$SIGNALS_DIR/blocks.jsonl"
    exit 0
  fi

  if [ -n "$BLOCK_REASON" ] && [ "$RLEN" -ge 50 ] && command -v claude &>/dev/null; then
    PREVIEW="${RESPONSE:0:800}"
    VERIFY_RESULT=$(safe_sonnet_review "原始拦截原因: $BLOCK_REASON
修正后的回答摘要: $PREVIEW
问题：修正后是否真正解决了拦截原因？只回复PASS或FAIL加一句理由。")

    if echo "$VERIFY_RESULT" | grep -qi "FAIL"; then
      REWRITE_COUNT=$((REWRITE_COUNT + 1))
      echo "$REWRITE_COUNT" > "$REWRITE_COUNT_FILE"
      touch "$BLOCK_FLAG"
      safe_json_block "修正未通过验证: ${VERIFY_RESULT}" "修正未通过Sonnet验证: ${VERIFY_RESULT}。原始原因: $BLOCK_REASON。请真正解决问题。修正后末尾加【已修正】。"
      exit 0
    fi
  fi

  echo "0" > "$REWRITE_COUNT_FILE"
  echo "0" > "$BLOCK_COUNT_FILE"
  echo "{\"time\":\"$TS\",\"event\":\"rewrite_pass_verified\",\"variant\":\"$VARIANT\"}" >> "$SIGNALS_DIR/blocks.jsonl"

  # 后台学习（安全方式）
  if [ -n "$BLOCK_REASON" ] && command -v claude &>/dev/null && [ -f "$PYTHON" ]; then
    safe_bg_add_instinct "用一句话总结这个AI偷懒模式作为规则(不超过30字): ${BLOCK_REASON:0:100}" "laziness" "block_rewrite"
  fi
  exit 0
fi

# 如果有 block flag 但没写"已修正"，也清理 flag（防止 flag 永久残留）
[ -f "$BLOCK_FLAG" ] && rm -f "$BLOCK_FLAG"

ISSUES=""

# ================================================================
# Bug#6+10 修复：正则拦截（改进误判）
# ================================================================

VAGUE="大约|大概|一般来说|通常来说|据说|据了解|有消息称|差不多|若干"
# 移除"可能需要"——在技术文档中太常见且合法

if [ -f "$INSTINCTS_FILE" ]; then
  EXTRA=$(grep '"category":"laziness"' "$INSTINCTS_FILE" -A1 2>/dev/null | grep '"pattern"' | sed 's/.*"pattern":"//;s/".*//' | awk 'length<15' | sed 's/[.*+?^$()|\[\]{}\\]/\\&/g' | tr '\n' '|' | sed 's/|$//')
  if [ -n "$EXTRA" ] && ! echo "$EXTRA" | grep -q '必须\|应该\|不能\|全面'; then
    VAGUE="${VAGUE}|${EXTRA}"
  fi
fi

# Bug#10 修复：剥离引号/括号内的内容后再检查模糊词
# 修复：用临时文件传递 RESPONSE，避免环境变量 32KB 长度限制
if [ -f "$PYTHON" ]; then
  RESP_TMPFILE=$(mktemp)
  printf '%s' "$RESPONSE" > "$RESP_TMPFILE"
  CLEAN_RESPONSE=$(PYTHONUTF8=1 "$PYTHON" -c '
import re,sys
with open(sys.argv[1],"r",encoding="utf-8",errors="replace") as f:
  r=f.read()
r=re.sub(r"\x22[^\x22]*\x22","",r)
r=re.sub(r"\u201c[^\u201d]*\u201d","",r)
r=re.sub(r"\u300c[^\u300d]*\u300d","",r)
r=re.sub(r"\u3010[^\u3011]*\u3011","",r)
r=re.sub(r"\x27[^\x27]*\x27","",r)
print(r)
' "$RESP_TMPFILE" 2>/dev/null)
  rm -f "$RESP_TMPFILE"
  [ -z "$CLEAN_RESPONSE" ] && CLEAN_RESPONSE="$RESPONSE"
else
  CLEAN_RESPONSE="$RESPONSE"
fi

FOUND=$(echo "$CLEAN_RESPONSE" | grep -oE "$VAGUE" | head -3 | tr '\n' ' ')
[ -n "$FOUND" ] && ISSUES="${ISSUES}模糊用词: ${FOUND}。"

# Bug#6 修复：数字范围检测——排除年份(4位数)，要求单位紧跟范围
if echo "$CLEAN_RESPONSE" | grep -qE '[0-9]{1,3}-[0-9]{1,3} *(元|块|美元|万|千)'; then
  echo "$RESPONSE" | grep -qE '[×*=]|依据|来源|根据|官方|文档' || ISSUES="${ISSUES}数字范围缺少依据。"
fi

if [ -n "$ISSUES" ]; then
  if [ -f "$PYTHON" ]; then
    PYTHONUTF8=1 _EVO_ISSUES="$ISSUES" "$PYTHON" -c "
import json,os
issues=os.environ.get('_EVO_ISSUES','')
entry={'time':'$TS','event':'block_event','trigger':issues,'len':$RLEN,'variant':'$VARIANT'}
bfile=os.path.join(os.path.expanduser('~'),'.claude','evolution','signals','blocks.jsonl')
with open(bfile,'a',encoding='utf-8') as f:
  f.write(json.dumps(entry,ensure_ascii=False)+'\n')
" 2>/dev/null
  fi
  update_blocks_stat
  touch "$BLOCK_FLAG"
  safe_json_block "正则拦截: ${ISSUES}" "正则拦截: ${ISSUES} 修正后末尾加【已修正】。"
  exit 0
fi

# ================================================================
# 强制搜索检查：涉及技术/工具/方案/数据的问题，必须先搜索再回答
# 从 transcript 检查是否调用了 WebSearch/WebFetch，
# 如果用户问题包含技术关键词但没搜索，拦截
# ================================================================

SEARCH_CHECK_ENABLED=$(grep -o '"quiet_mode": *true' "$CONFIG" 2>/dev/null)
# 只在有 transcript 且有 Python 时执行
if [ -n "$SEARCH_CHECK_ENABLED" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$PYTHON" ] && [ -n "$USER_QUESTION" ]; then
  SEARCH_BLOCK=$(PYTHONUTF8=1 _EVO_TP="$TRANSCRIPT_PATH" _EVO_UQ="$USER_QUESTION" "$PYTHON" -c "
import json, os, re

tp = os.environ.get('_EVO_TP', '')
uq = os.environ.get('_EVO_UQ', '')

if not tp or not os.path.exists(tp) or not uq:
    exit(0)

# 用户问题是否涉及需要搜索的主题
tech_keywords = [
    '技术方案', '工具', '选型', '框架', '库', '平台', '怎么实现', '有没有办法',
    '能不能', '有什么方法', '推荐', '对比', '哪个好', '最新', '2024', '2025', '2026',
    'tool', 'framework', 'library', 'how to', 'is there', 'recommend', 'compare',
    '安装', '部署', '配置', '监控', '性能', '优化', '解决方案',
    'install', 'deploy', 'monitor', 'performance', 'solution',
    '价格', '定价', '收费', '费用', '成本', 'pricing', 'cost',
]

question_needs_search = any(kw in uq.lower() for kw in tech_keywords)

if not question_needs_search:
    exit(0)

# 检查 transcript 中是否有 WebSearch 或 WebFetch 调用
has_search = False
try:
    with open(tp, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except:
                continue
            if entry.get('role') == 'assistant':
                for block in entry.get('content', []):
                    if block.get('type') == 'tool_use':
                        name = block.get('name', '')
                        if name in ('WebSearch', 'WebFetch', 'Agent'):
                            has_search = True
                            break
                if has_search:
                    break
except:
    exit(0)

if not has_search:
    print('BLOCK')
" 2>/dev/null)

  if [ "$SEARCH_BLOCK" = "BLOCK" ]; then
    if [ -f "$PYTHON" ]; then
      PYTHONUTF8=1 "$PYTHON" -c "
import json,os
entry={'time':'$TS','event':'search_block','variant':'$VARIANT'}
bfile=os.path.join(os.path.expanduser('~'),'.claude','evolution','signals','blocks.jsonl')
with open(bfile,'a',encoding='utf-8') as f:
  f.write(json.dumps(entry,ensure_ascii=False)+'\n')
" 2>/dev/null
    fi
    update_blocks_stat
    touch "$BLOCK_FLAG"
    safe_json_block "未搜索就回答技术问题" "你回答了涉及技术/工具/方案的问题但没有先搜索。请先用 WebSearch 搜索相关信息，基于搜索结果重新回答。修正后末尾加【已修正】。"
    exit 0
  fi
fi

# ================================================================
# v2.3 做事型任务审查（改造1：从 transcript_path 读取工具调用和结果）
# 触发条件：stop_reason=end_turn 且 transcript 中有工具调用
# ================================================================

TASK_REVIEW_CONTEXT=""
# 检查是否显式关闭
TASK_REVIEW_DISABLED=$(grep -o '"task_review_enabled": *false' "$CONFIG" 2>/dev/null)
TASK_REVIEW_ENABLED="true"
[ -n "$TASK_REVIEW_DISABLED" ] && TASK_REVIEW_ENABLED=""

if [ -n "$TASK_REVIEW_ENABLED" ] && [ -f "$PYTHON" ] && [ -f "$TASK_REVIEWER" ] && [ -n "$TRANSCRIPT_PATH" ]; then
  # 阶段1：从 transcript 本地分类（<100ms）
  TASK_CLASS=$(PYTHONUTF8=1 "$PYTHON" "$TASK_REVIEWER" classify "$TRANSCRIPT_PATH" 2>/dev/null)
  TASK_TYPE=$(echo "$TASK_CLASS" | grep -o '"type": *"[^"]*"' | sed 's/"type": *"//;s/"$//')
  TASK_TOOL_COUNT=$(echo "$TASK_CLASS" | grep -o '"tool_count": *[0-9]*' | grep -o '[0-9]*')
  [ -z "$TASK_TYPE" ] && TASK_TYPE="no_tools"
  [ -z "$TASK_TOOL_COUNT" ] && TASK_TOOL_COUNT=0

  # 阶段2：只对 action/investigation 类型调 Sonnet 审查
  if [ "$TASK_TYPE" = "action" ] || [ "$TASK_TYPE" = "investigation" ]; then
    if command -v claude &>/dev/null; then
      PREVIEW="${RESPONSE:0:1500}"
      USER_Q_FOR_TASK="${USER_QUESTION:0:300}"

      # 改造1：用 transcript_path 生成审查 prompt（含工具结果摘要）
      TASK_PROMPT_FILE=$(mktemp)
      PYTHONUTF8=1 _EVO_UQ="$USER_Q_FOR_TASK" _EVO_PREVIEW="$PREVIEW" _EVO_TP="$TRANSCRIPT_PATH" "$PYTHON" -c "
import os,sys
sys.path.insert(0, os.path.join(os.path.expanduser('~'), '.claude', 'hooks', 'scripts'))
from task_reviewer import build_prompt
build_prompt(os.environ.get('_EVO_TP',''), os.environ.get('_EVO_UQ',''), os.environ.get('_EVO_PREVIEW',''))
" > "$TASK_PROMPT_FILE" 2>/dev/null

      TASK_REVIEW_RESULT=$(claude -p --model sonnet < "$TASK_PROMPT_FILE" 2>/dev/null)
      rm -f "$TASK_PROMPT_FILE"

      if [ -n "$TASK_REVIEW_RESULT" ]; then
        TASK_VERDICT=$(echo "$TASK_REVIEW_RESULT" | grep -i 'VERDICT:' | sed 's/^.*VERDICT://I' | sed 's/^[[:space:]]*//' | tr '[:lower:]' '[:upper:]')
        TASK_GAPS=$(echo "$TASK_REVIEW_RESULT" | grep -i 'GAPS:' | sed 's/^.*GAPS://I' | sed 's/^[[:space:]]*//')
        TASK_VERIFIED=$(echo "$TASK_REVIEW_RESULT" | grep -i 'VERIFIED:' | sed 's/^.*VERIFIED://I' | sed 's/^[[:space:]]*//')

        # 记录审查结果
        PYTHONUTF8=1 "$PYTHON" "$TASK_REVIEWER" record "$VARIANT" "${TASK_VERDICT:-UNKNOWN}" "${TASK_GAPS:-none}" "$TASK_TOOL_COUNT" 2>/dev/null

        if echo "$TASK_VERDICT" | grep -qi "SUPERFICIAL"; then
          [ -z "$TASK_GAPS" ] && TASK_GAPS="Sonnet判定做事不全面"
          if [ -f "$PYTHON" ]; then
            PYTHONUTF8=1 _EVO_ISSUES="task_superficial:$TASK_GAPS" "$PYTHON" -c "
import json,os
issues=os.environ.get('_EVO_ISSUES','')
entry={'time':'$TS','event':'task_review_block','issues':issues,'tool_count':$TASK_TOOL_COUNT,'variant':'$VARIANT'}
bfile=os.path.join(os.path.expanduser('~'),'.claude','evolution','signals','blocks.jsonl')
with open(bfile,'a',encoding='utf-8') as f:
  f.write(json.dumps(entry,ensure_ascii=False)+'\n')
" 2>/dev/null
          fi
          update_blocks_stat
          touch "$BLOCK_FLAG"

          BLOCK_MSG="做事型任务审查：你做了 ${TASK_TOOL_COUNT} 次工具调用，但被判定为不全面。"
          [ -n "$TASK_GAPS" ] && BLOCK_MSG="${BLOCK_MSG} 遗漏的步骤: ${TASK_GAPS}。"
          echo "$TASK_VERIFIED" | grep -qi "false" && BLOCK_MSG="${BLOCK_MSG} 你没有验证自己做的事的结果。"
          BLOCK_MSG="${BLOCK_MSG} 请补充遗漏的步骤，完成后末尾加【已修正】。"

          safe_json_block "做事审查: ${TASK_GAPS}" "$BLOCK_MSG"
          exit 0

        elif echo "$TASK_VERDICT" | grep -qi "INCOMPLETE"; then
          TASK_REVIEW_CONTEXT="【做事型审查】Sonnet发现你可能遗漏了: ${TASK_GAPS}。"
          echo "$TASK_VERIFIED" | grep -qi "false" && TASK_REVIEW_CONTEXT="${TASK_REVIEW_CONTEXT} 你没有验证结果。"
          TASK_REVIEW_CONTEXT="${TASK_REVIEW_CONTEXT} 请在后续交互中补充。"

          # 后台学习
          if [ -n "$TASK_GAPS" ] && [ -f "$INSTINCT_SCRIPT" ]; then
            safe_bg_add_instinct "AI做事时遗漏了: ${TASK_GAPS:0:100}。用一句话总结应该记住的规则(不超过30字)" "laziness" "task_review"
          fi
        else
          # THOROUGH：做得好
          TASK_REVIEW_CONTEXT="[做事审查] 做事全面性通过 (${TASK_TOOL_COUNT}次工具调用)。"
        fi
      fi
    fi
  fi
fi

# ================================================================
# Bug#7 修复：Sonnet 跨模型审查（调优 prompt，区分偷懒和合理简洁）
# ================================================================

SONNET_ENABLED=$(grep -o '"sonnet_review_enabled": *true' "$CONFIG" 2>/dev/null)
MIN_LEN=$(grep -o '"sonnet_review_min_length": *[0-9]*' "$CONFIG" 2>/dev/null | grep -o '[0-9]*')
[ -z "$MIN_LEN" ] && MIN_LEN=400

SONNET_CONTEXT=""
# 合并做事型审查的上下文
[ -n "$TASK_REVIEW_CONTEXT" ] && SONNET_CONTEXT="$TASK_REVIEW_CONTEXT"

if [ -n "$SONNET_ENABLED" ] && [ "$RLEN" -ge "$MIN_LEN" ]; then
  if command -v claude &>/dev/null; then
    PREVIEW="${RESPONSE:0:2000}"

    # 构建用户上下文（最近 3 条消息，不只最后 1 条）
    USER_Q_SECTION=""
    if [ -n "$RECENT_CONTEXT" ]; then
      USER_Q_SECTION="最近几轮用户消息（从旧到新）:
${RECENT_CONTEXT}"
    elif [ -n "$USER_QUESTION" ]; then
      USER_Q_SECTION="用户最新问题: ${USER_QUESTION:0:200}"
    fi

    # 合并审查：质量+辩论+深度审查 一次 Sonnet 调用完成
    DEBATE_SECTION=""
    if [ "$RLEN" -ge 800 ]; then
      DEBATE_SECTION="
ATTACKS:扮演严格质疑方，攻击回答的弱点/遗漏/不够深入的地方，至少3个(分号分隔)
SEVERITY:这些攻击的严重程度——SERIOUS(有严重问题需要修正)/MINOR(小问题)/DISMISS(质疑不成立)"
    fi

    REVIEW_PROMPT="你是综合质量审查员。用下面的精确格式回复，每行一个字段：
LAZY:true或false
ISSUES:具体问题(一行，分号分隔，没有则写\"无\")
INITIATIVE:1到10
PROACTIVE:AI有没有主动提出用户没问但重要的点？YES或NO
MISSED:如果PROACTIVE是NO，AI应该主动想到什么？(一句话，否则写\"无\")
CHALLENGES:提出3个AI可能遗漏或想得不够深的点(分号分隔)${DEBATE_SECTION}
INSTINCT:值得记录的行为模式(一句话)

重要：你只能看到最近几条用户消息，无法看到完整对话历史。如果AI的回答主题看起来和最后一条消息不直接相关，很可能是因为它在回应更早的对话上下文——不要因此判定LAZY。只有在AI明显回避核心问题、遗漏关键维度、或给半成品答案时才判LAZY。

LAZY=true 仅用于以下严重情况：
- 分析明显遗漏了关键维度（如讨论定价却没考虑重要成本项）
- 用空话套话填充而没有实质内容
- 给出半成品答案明显在等用户追问
不要因为回答简洁就判 LAZY——简洁但全面是好的。

审查标准：1)是否回避核心问题 2)分析维度是否全面 3)有没有空话套话 4)有没有主动提出用户没想到的东西 5)建议下一步时有没有跳过当前应完成的步骤
${USER_Q_SECTION}
回答全文(${RLEN}字符): ${PREVIEW}"

    SONNET_RESULT=$(safe_sonnet_review "$REVIEW_PROMPT")

    if [ -z "$SONNET_RESULT" ]; then
      :
    else
      LAZY_FLAG=$(echo "$SONNET_RESULT" | grep -i 'LAZY:' | grep -i 'true')
      INIT_SCORE=$(echo "$SONNET_RESULT" | grep -i 'INITIATIVE:' | grep -o '[0-9]*' | head -1)
      SONNET_ISSUES=$(echo "$SONNET_RESULT" | grep -i 'ISSUES:' | sed 's/^.*ISSUES://I' | sed 's/^[[:space:]]*//')
      INSTINCT_SUGGEST=$(echo "$SONNET_RESULT" | grep -i 'INSTINCT:' | sed 's/^.*INSTINCT://I' | sed 's/^[[:space:]]*//')

      [ -z "$LAZY_FLAG" ] && LAZY_FLAG=$(echo "$SONNET_RESULT" | grep -o '"lazy": *true\|"lazy":true')
      [ -z "$INIT_SCORE" ] && INIT_SCORE=$(echo "$SONNET_RESULT" | grep -o '"initiative": *[0-9]*' | grep -o '[0-9]*' | head -1)

      echo "{\"time\":\"$TS\",\"variant\":\"$VARIANT\",\"lazy\":\"$([ -n "$LAZY_FLAG" ] && echo true || echo false)\",\"initiative\":${INIT_SCORE:-0}}" >> "$SIGNALS_DIR/sonnet_reviews.jsonl"

      # LAZY 拦截
      if [ -n "$LAZY_FLAG" ]; then
        [ -z "$SONNET_ISSUES" ] && SONNET_ISSUES="Sonnet判定偷懒"
        if [ -f "$PYTHON" ]; then
          PYTHONUTF8=1 _EVO_ISSUES="$SONNET_ISSUES" "$PYTHON" -c "
import json,os
issues=os.environ.get('_EVO_ISSUES','')
entry={'time':'$TS','event':'sonnet_block','issues':issues,'variant':'$VARIANT'}
bfile=os.path.join(os.path.expanduser('~'),'.claude','evolution','signals','blocks.jsonl')
with open(bfile,'a',encoding='utf-8') as f:
  f.write(json.dumps(entry,ensure_ascii=False)+'\n')
" 2>/dev/null
        fi
        update_blocks_stat
        touch "$BLOCK_FLAG"
        safe_json_block "Sonnet审查: ${SONNET_ISSUES}" "Sonnet跨模型审查: ${SONNET_ISSUES}。修正后末尾加【已修正】。"
        exit 0
      fi

      # 辩论严重性检查（从合并结果中提取）
      if [ "$RLEN" -ge 800 ]; then
        ATTACKS=$(echo "$SONNET_RESULT" | grep -i 'ATTACKS:' | sed 's/^.*ATTACKS://I' | sed 's/^[[:space:]]*//')
        SEVERITY=$(echo "$SONNET_RESULT" | grep -i 'SEVERITY:' | sed 's/^.*SEVERITY://I' | sed 's/^[[:space:]]*//' | tr '[:lower:]' '[:upper:]')

        if echo "$SEVERITY" | grep -qi "SERIOUS"; then
          if [ -f "$PYTHON" ]; then
            PYTHONUTF8=1 _EVO_VERDICT="$ATTACKS" "$PYTHON" -c "
import json,os
verdict=os.environ.get('_EVO_VERDICT','')
entry={'time':'$TS','event':'debate_block','verdict':verdict,'variant':'$VARIANT'}
bfile=os.path.join(os.path.expanduser('~'),'.claude','evolution','signals','blocks.jsonl')
with open(bfile,'a',encoding='utf-8') as f:
  f.write(json.dumps(entry,ensure_ascii=False)+'\n')
" 2>/dev/null
          fi
          update_blocks_stat
          touch "$BLOCK_FLAG"
          safe_json_block "辩论审查发现严重问题: ${ATTACKS}" "辩论审查: ${ATTACKS}。严重程度: SERIOUS。请修正这些问题。修正后末尾加【已修正】。"
          exit 0
        fi

        if echo "$SEVERITY" | grep -qi "MINOR"; then
          SONNET_CONTEXT="${SONNET_CONTEXT} [辩论审查] 质疑方提出了小问题: ${ATTACKS:0:300}。裁判判定为非严重但值得注意。"
        fi
      fi

      # 深度审查 CHALLENGES
      CHALLENGES=$(echo "$SONNET_RESULT" | grep -i 'CHALLENGES:' | sed 's/^.*CHALLENGES://I' | sed 's/^[[:space:]]*//')
      if [ -n "$CHALLENGES" ] && [ ${#CHALLENGES} -gt 10 ]; then
        SONNET_CONTEXT="${SONNET_CONTEXT} 【强制深度审查】Sonnet提出以下质疑，你必须在回答中补充回应（如果还没有的话）：${CHALLENGES}"
      fi

      # 主动思考检查
      PROACTIVE_NO=$(echo "$SONNET_RESULT" | grep -i 'PROACTIVE:' | grep -i 'NO')
      MISSED_THOUGHT=$(echo "$SONNET_RESULT" | grep -i 'MISSED:' | sed 's/^.*MISSED:[[:space:]]*//')
      PROACTIVE_GEN="$HOME/.claude/hooks/scripts/proactive_generator.py"

      if [ -n "$PROACTIVE_NO" ] && [ -n "$MISSED_THOUGHT" ] && [ ${#MISSED_THOUGHT} -gt 3 ] && [ -f "$PYTHON" ] && [ -f "$PROACTIVE_GEN" ]; then
        "$PYTHON" "$BG_SCRIPT" "$PYTHON" "$PROACTIVE_GEN" missed "$MISSED_THOUGHT"
        SONNET_CONTEXT="[错失主动思考] 你没有主动想到: ${MISSED_THOUGHT}。下次类似场景请主动想到。"
      fi

      INIT_SCORE=$(echo "$INIT_SCORE" | grep -o '^[0-9]*' | head -1)
      [ -z "$INIT_SCORE" ] && INIT_SCORE=5

      if [ "$INIT_SCORE" -ge 6 ] 2>/dev/null; then
        SONNET_CONTEXT="Sonnet评价主动性${INIT_SCORE}/10(优秀)。"
        # 安全方式添加 instinct
        if [ -n "$INSTINCT_SUGGEST" ] && [ -f "$PYTHON" ] && [ -f "$INSTINCT_SCRIPT" ]; then
          INST_TMP=$(mktemp)
          printf '%s' "$INSTINCT_SUGGEST" > "$INST_TMP"
          PYTHONUTF8=1 "$PYTHON" "$BG_SCRIPT" "$PYTHON" "$INSTINCT_SCRIPT" add-file "$INST_TMP" initiative sonnet_review
        fi
        if [ -n "$INSTINCT_SUGGEST" ]; then
          PYTHONUTF8=1 _EVO_PATTERN="$INSTINCT_SUGGEST" "$PYTHON" -c "
import json,os
pattern=os.environ.get('_EVO_PATTERN','')
entry={'time':'$TS','score':$INIT_SCORE,'pattern':pattern}
ef=os.path.join(os.path.expanduser('~'),'.claude','evolution','initiative_examples.jsonl')
with open(ef,'a',encoding='utf-8') as f:
  f.write(json.dumps(entry,ensure_ascii=False)+'\n')
lines=open(ef,'r',encoding='utf-8').readlines()
if len(lines)>10:
  with open(ef,'w',encoding='utf-8') as f:
    f.writelines(lines[-10:])
" 2>/dev/null
        fi
        SONNET_CONTEXT="${SONNET_CONTEXT} 好模式已记录。"

      elif [ "$INIT_SCORE" -le 3 ] 2>/dev/null; then
        SONNET_CONTEXT="Sonnet评价主动性${INIT_SCORE}/10(不足)。下次更主动提出用户没想到的点。"
        if [ -n "$INSTINCT_SUGGEST" ] && [ -f "$PYTHON" ] && [ -f "$INSTINCT_SCRIPT" ]; then
          INST_TMP=$(mktemp)
          printf '%s' "$INSTINCT_SUGGEST" > "$INST_TMP"
          PYTHONUTF8=1 "$PYTHON" "$BG_SCRIPT" "$PYTHON" "$INSTINCT_SCRIPT" add-file "$INST_TMP" laziness sonnet_review
        fi
      fi
    fi
  fi
fi

# ================================================================
# 输出
# ================================================================

if [ -n "$SONNET_CONTEXT" ]; then
  safe_json_context "$SONNET_CONTEXT"
  exit 0
fi

# 没有任何问题，重置 block 计数器
echo "0" > "$BLOCK_COUNT_FILE"
exit 0
