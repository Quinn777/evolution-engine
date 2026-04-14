#!/bin/bash
# ================================================================
# Evolution Engine v2.4 — PostToolUse Hook
# 通过 PostToolUse 事件捕获 Agent 工具完成，审查子 agent 工作质量。
# 对非 Agent 工具调用立即退出（< 1ms 开销）。
# ================================================================

EVO_DIR="$HOME/.claude/evolution"
SCRIPTS_DIR="$HOME/.claude/hooks/scripts"
source "$SCRIPTS_DIR/find_python.sh"
STATS_SCRIPT="$SCRIPTS_DIR/stats_rw.py"
ACTIVE_VARIANT="$EVO_DIR/active_variant.txt"
CONFIG="$EVO_DIR/config.json"

# 紧急关闭开关
[ -f "$EVO_DIR/.disabled" ] && exit 0

INPUT=$(cat)

# 快速探针：提取 tool_name
TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name":"[^"]*"' | head -1 | sed 's/"tool_name":"//;s/"$//')
[ -z "$TOOL_NAME" ] && TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name" *: *"[^"]*"' | head -1 | sed 's/"tool_name" *: *"//;s/"$//')

# 快速过滤：只处理 tool_name=Agent
if [ "$TOOL_NAME" != "Agent" ]; then
  exit 0
fi

# 检查是否显式关闭做事审查
if grep -q '"task_review_enabled": *false' "$CONFIG" 2>/dev/null; then
  exit 0
fi

# ================================================================
# 用 Python 提取 Agent payload（一次调用，安全方式）
# ================================================================
AGENT_PROMPT=""
AGENT_TYPE=""
AGENT_RESPONSE=""
AGENT_TOOL_COUNT=0
AGENT_STATUS=""

if [ -n "$PYTHON" ]; then
  INPUT_FILE=$(mktemp)
  RESULT_FILE=$(mktemp)
  printf '%s' "$INPUT" > "$INPUT_FILE"

  PYTHONUTF8=1 "$PYTHON" -c '
import json, sys

input_file = sys.argv[1]
result_file = sys.argv[2]

try:
    with open(input_file, "r", encoding="utf-8") as f:
        d = json.load(f)
    ti = d.get("tool_input", {})
    tr = d.get("tool_response", {})

    prompt = ti.get("prompt", "")[:500]
    agent_type = ti.get("subagent_type", ti.get("description", ""))[:50]
    status = tr.get("status", "")

    # 提取 Agent 回答文本：穷举所有可能的字段名
    response_text = ""

    # 方式1：tool_response.content 是列表（Claude API 格式）
    content = tr.get("content", [])
    if isinstance(content, list):
        for c in content:
            if isinstance(c, dict) and c.get("type") == "text":
                response_text += c.get("text", "")
    elif isinstance(content, str):
        response_text = content

    # 方式2-4：常见字段名 fallback
    for key in ("result", "output", "text"):
        if not response_text:
            val = tr.get(key, "")
            if isinstance(val, str) and val:
                response_text = val

    # 方式5：tool_response 本身是字符串
    if not response_text and isinstance(tr, str):
        response_text = tr

    response_text = response_text[:1500]
    tool_count = tr.get("totalToolUseCount", 0)

    result = {
        "prompt": prompt,
        "agent_type": agent_type,
        "response": response_text,
        "tool_count": tool_count,
        "status": status
    }
    with open(result_file, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False)
except Exception:
    pass
' "$INPUT_FILE" "$RESULT_FILE" 2>/dev/null

  # 安全读取：用 Python 输出 NUL 分隔的值，避免 eval 注入风险
  if [ -s "$RESULT_FILE" ]; then
    PARSED=$("$PYTHON" -c "
import json,sys
d=json.load(open(sys.argv[1],encoding='utf-8'))
# NUL 分隔输出，避免换行符干扰
fields=[d.get('prompt',''),d.get('agent_type',''),d.get('response',''),str(d.get('tool_count',0)),d.get('status','')]
sys.stdout.buffer.write(b'\0'.join(f.encode('utf-8','replace') for f in fields))
" "$RESULT_FILE" 2>/dev/null)

    if [ -n "$PARSED" ]; then
      IFS=$'\0' read -r -d '' AGENT_PROMPT AGENT_TYPE AGENT_RESPONSE AGENT_TOOL_COUNT AGENT_STATUS <<< "$PARSED" 2>/dev/null || true
    fi
  fi
  rm -f "$INPUT_FILE" "$RESULT_FILE"
fi

# 过滤：只审查已完成且有实际工作量的子 agent
[ "$AGENT_STATUS" != "completed" ] && exit 0
[ "$AGENT_TOOL_COUNT" -lt 2 ] 2>/dev/null && exit 0

# ================================================================
# 调用 Sonnet 审查子 agent 工作质量
# ================================================================
command -v claude &>/dev/null || exit 0

VARIANT=$(cat "$ACTIVE_VARIANT" 2>/dev/null || echo "A")
USER_Q=$(cat "$EVO_DIR/.last_user_question" 2>/dev/null | head -c 300)

REVIEW_PROMPT_FILE=$(mktemp)
cat > "$REVIEW_PROMPT_FILE" << 'ENDPROMPT'
你是"做事质量"审查员。一个子 Agent 刚完成了任务。
你的职责：审查子 Agent 做的事是否全面、是否遗漏了重要步骤。
ENDPROMPT

cat >> "$REVIEW_PROMPT_FILE" << ENDPROMPT

用户原始问题: ${USER_Q}

给子 Agent 的指令: ${AGENT_PROMPT}

子 Agent 类型: ${AGENT_TYPE}
子 Agent 工具调用次数: ${AGENT_TOOL_COUNT}

子 Agent 的回答:
${AGENT_RESPONSE}

严格按以下格式回复（每行一个字段）:
THOROUGH:true或false
GAPS:遗漏了哪些应该做的步骤（用分号分隔，没有则写"无"）
VERIFIED:子Agent是否验证了结果（true/false）
VERDICT:THOROUGH或INCOMPLETE或SUPERFICIAL

判定标准:
- THOROUGH: 覆盖了任务的所有合理步骤
- INCOMPLETE: 做了核心步骤但遗漏了 1-2 个重要步骤
- SUPERFICIAL: 明显偷懒——只做了最表面的部分，遗漏了多个重要步骤

重要：不要因为步骤少就判 SUPERFICIAL。关键是看任务本身需要多少步骤。
如果任务只需要 2 步而子 Agent 做了 2 步，那就是 THOROUGH。
ENDPROMPT

REVIEW_RESULT=$(claude -p --model sonnet < "$REVIEW_PROMPT_FILE" 2>/dev/null)
rm -f "$REVIEW_PROMPT_FILE"

[ -z "$REVIEW_RESULT" ] && exit 0

VERDICT=$(echo "$REVIEW_RESULT" | grep -i 'VERDICT:' | sed 's/^.*VERDICT://I' | sed 's/^[[:space:]]*//' | tr '[:lower:]' '[:upper:]')
GAPS=$(echo "$REVIEW_RESULT" | grep -i 'GAPS:' | sed 's/^.*GAPS://I' | sed 's/^[[:space:]]*//')

# 记录审查结果
if [ -n "$PYTHON" ] && [ -f "$HOME/.claude/hooks/scripts/task_reviewer.py" ]; then
  PYTHONUTF8=1 "$PYTHON" "$HOME/.claude/hooks/scripts/task_reviewer.py" record "$VARIANT" "${VERDICT:-UNKNOWN}" "${GAPS:-none}" "$AGENT_TOOL_COUNT" 2>/dev/null
fi

# quiet_mode 检查
QUIET_MODE=$(grep -o '"quiet_mode": *true' "$CONFIG" 2>/dev/null)

if echo "$VERDICT" | grep -qi "SUPERFICIAL"; then
  CTX="【子Agent做事审查】子agent(${AGENT_TYPE})做了${AGENT_TOOL_COUNT}次工具调用，但被判定为不全面。遗漏: ${GAPS}。请补充遗漏的步骤。"
  [ -n "$QUIET_MODE" ] && CTX="[子Agent审查] 请补充遗漏的步骤。"
  if [ -n "$PYTHON" ]; then
    PYTHONUTF8=1 _EVO_CTX="$CTX" "$PYTHON" -c "
import json,os
ctx=os.environ.get('_EVO_CTX','')
print(json.dumps({'decision':'block','reason':'subagent_task_review: '+ctx[:200],'hookSpecificOutput':{'hookEventName':'PostToolUse','additionalContext':ctx}},ensure_ascii=False))
"
  fi
  exit 0

elif echo "$VERDICT" | grep -qi "INCOMPLETE"; then
  # quiet_mode 时不显示 INCOMPLETE 提醒
  [ -n "$QUIET_MODE" ] && exit 0
  CTX="【子Agent做事审查】子agent(${AGENT_TYPE})可能遗漏了: ${GAPS}。请在后续交互中补充。"
  if [ -n "$PYTHON" ]; then
    PYTHONUTF8=1 _EVO_CTX="$CTX" "$PYTHON" -c "
import json,os
ctx=os.environ.get('_EVO_CTX','')
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PostToolUse','additionalContext':ctx}},ensure_ascii=False))
"
  fi
  exit 0
fi

exit 0
