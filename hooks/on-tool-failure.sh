#!/bin/bash
# ================================================================
# Evolution Engine v2.4 — PostToolUseFailure Hook
# 当工具执行失败时触发。注入提醒让 AI 不要忽略错误。
# ================================================================

EVO_DIR="$HOME/.claude/evolution"
SCRIPTS_DIR="$HOME/.claude/hooks/scripts"
source "$SCRIPTS_DIR/find_python.sh"

# 紧急关闭开关
[ -f "$EVO_DIR/.disabled" ] && exit 0

INPUT=$(cat)

# 安全提取字段（临时文件，不用 eval）
TOOL_NAME=""
ERROR_MSG=""
if [ -n "$PYTHON" ]; then
  INPUT_FILE=$(mktemp)
  printf '%s' "$INPUT" > "$INPUT_FILE"

  TOOL_NAME=$("$PYTHON" -c "
import json,sys
try:
    with open(sys.argv[1],'r',encoding='utf-8') as f:
        d=json.load(f)
    print(d.get('tool_name','unknown'))
except: print('unknown')
" "$INPUT_FILE" 2>/dev/null)

  ERROR_MSG=$("$PYTHON" -c "
import json,sys
try:
    with open(sys.argv[1],'r',encoding='utf-8') as f:
        d=json.load(f)
    # 优先从 error 顶层字段提取，fallback 到 tool_response 中的错误信息
    err=d.get('error','')
    if not err:
        tr=d.get('tool_response',{})
        if isinstance(tr,dict):
            err=tr.get('error',tr.get('message',''))
        elif isinstance(tr,str):
            err=tr
    print(str(err)[:300])
except: pass
" "$INPUT_FILE" 2>/dev/null)

  rm -f "$INPUT_FILE"
fi

# grep 兜底
if [ -z "$TOOL_NAME" ] || [ "$TOOL_NAME" = "unknown" ]; then
  TOOL_NAME=$(echo "$INPUT" | grep -o '"tool_name":"[^"]*"' | sed 's/"tool_name":"//;s/"$//' | head -1)
  [ -z "$TOOL_NAME" ] && TOOL_NAME="unknown"
fi
if [ -z "$ERROR_MSG" ]; then
  ERROR_MSG=$(echo "$INPUT" | grep -o '"error":"[^"]*"' | sed 's/"error":"//;s/"$//' | head -1)
fi

ERROR_PREVIEW="${ERROR_MSG:0:200}"
CONTEXT="【工具失败提醒】工具 ${TOOL_NAME} 执行失败: ${ERROR_PREVIEW}。不要忽略这个错误——请分析失败原因并采取相应措施。"

if [ -n "$PYTHON" ]; then
  PYTHONUTF8=1 _EVO_CTX="$CONTEXT" "$PYTHON" -c "
import json,os
ctx=os.environ.get('_EVO_CTX','')
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PostToolUseFailure','additionalContext':ctx}},ensure_ascii=False))
"
else
  ESC=$(echo "$CONTEXT" | sed 's/\\/\\\\/g;s/"/\\"/g' | tr '\n' ' ')
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PostToolUseFailure\",\"additionalContext\":\"${ESC}\"}}"
fi

exit 0
