#!/bin/bash
# ================================================================
# Evolution Engine v2 — UserPromptSubmit Hook (终版)
# 修复：移除误判词、后台进程用bg_run.py、减少不必要Sonnet调用、
# 保存用户问题供Sonnet审查用
# ================================================================

EVO_DIR="$HOME/.claude/evolution"
SIGNALS_DIR="$EVO_DIR/signals"
INSTINCTS_FILE="$EVO_DIR/instincts/index.json"
ACTIVE_VARIANT="$EVO_DIR/active_variant.txt"
SCRIPTS_DIR="$HOME/.claude/hooks/scripts"
source "$SCRIPTS_DIR/find_python.sh"
INSTINCT_SCRIPT="$SCRIPTS_DIR/instinct_manager.py"
STATS_SCRIPT="$SCRIPTS_DIR/stats_rw.py"
BG_SCRIPT="$SCRIPTS_DIR/bg_run.py"

# 紧急关闭开关
[ -f "$EVO_DIR/.disabled" ] && exit 0

mkdir -p "$SIGNALS_DIR" 2>/dev/null
touch "$SIGNALS_DIR/corrections.jsonl" "$SIGNALS_DIR/approvals.jsonl" 2>/dev/null

INPUT=$(cat)
TS=$(date +%Y%m%d_%H%M%S)

# 提取用户消息（Claude Code 实际传入格式: {"prompt":"...","session_id":"...","hook_event_name":"UserPromptSubmit",...}）
USER_MSG=""
if [ -f "$PYTHON" ]; then
  USER_MSG=$("$PYTHON" -c "
import sys,json
try:
  d=json.load(sys.stdin)
  # Claude Code 实际格式：顶层 prompt 字段
  msg=d.get('prompt','')
  if msg:
    print(msg)
  else:
    # 兼容旧格式
    msgs=d.get('messages',[])
    if msgs:
      for c in msgs[-1].get('content',[]):
        if c.get('type')=='text':
          print(c.get('text',''))
          break
except: pass
" <<< "$INPUT" 2>/dev/null)
fi
if [ -z "$USER_MSG" ]; then
  # 正则 fallback：先试 prompt 字段，再试 text 字段
  USER_MSG=$(echo "$INPUT" | grep -o '"prompt":"[^"]*"' | sed 's/"prompt":"//;s/"$//' | head -1)
  [ -z "$USER_MSG" ] && USER_MSG=$(echo "$INPUT" | grep -o '"text":"[^"]*"' | sed 's/"text":"//;s/"$//' | head -1)
fi

VARIANT=$(cat "$ACTIVE_VARIANT" 2>/dev/null || echo "A")
MSG_LEN=${#USER_MSG}

# 修复#2：保存用户问题供 on-stop.sh 的 Sonnet 审查使用
# 保存最近 3 条用户消息，供 Sonnet 审查时理解上下文
echo "$USER_MSG" > "$EVO_DIR/.last_user_question" 2>/dev/null
HISTORY_FILE="$EVO_DIR/.recent_user_questions"
if [ -f "$HISTORY_FILE" ]; then
  # 保留最近 2 条旧消息 + 当前 1 条 = 3 条
  PREV=$(tail -2 "$HISTORY_FILE")
  printf '%s\n%s\n' "$PREV" "$USER_MSG" > "$HISTORY_FILE"
else
  echo "$USER_MSG" > "$HISTORY_FILE"
fi

# v2.3：工具调用累积已移除（改用 transcript_path），不再需要 reset

# ================================================================
# 信号检测（修复#7：移除"你确定"等误判词，只保留明确负面词）
# ================================================================

SIGNAL_CONTEXT=""

# 修复#7：更精准的负面信号检测
NEG_PATTERN='偷懒|敷衍|回避问题|糊弄|又在敷衍|还是在偷懒|不够全面|不准确|隐瞒|模棱两可|你在忽悠'
POS_PATTERN='^好的$|^对$|^可以$|^不错$|^没问题$|说得对|分析得好|这就对了|^继续$|^确实$'

DETECTED_SIGNAL=""

if [ "$MSG_LEN" -gt 2 ] && [ "$MSG_LEN" -lt 300 ]; then
  if echo "$USER_MSG" | grep -qE "$NEG_PATTERN"; then
    DETECTED_SIGNAL="negative"
  elif echo "$USER_MSG" | grep -qE "$POS_PATTERN"; then
    DETECTED_SIGNAL="positive"
  fi
fi

# 更新统计（通过统一的 stats_rw.py 模块，带锁）
update_variant_stat() {
  local variant=$1 field=$2
  if [ -f "$PYTHON" ] && [ -f "$STATS_SCRIPT" ]; then
    "$PYTHON" "$STATS_SCRIPT" increment "$variant" "$field" 2>>"$EVO_DIR/error.log" || true
  fi
}

if [ "$DETECTED_SIGNAL" = "negative" ]; then
  # 级联回声防护：如果消息本身是级联回声（包含"用户对AI回答不满"），不记录为新信号
  IS_CASCADE=$(echo "$USER_MSG" | grep -c '用户对AI回答不满' || true)
  if [ "$IS_CASCADE" -le 0 ] && [ -f "$PYTHON" ]; then
    PYTHONUTF8=1 _EVO_HINT="${USER_MSG:0:100}" "$PYTHON" -c "
import json,os
hint=os.environ.get('_EVO_HINT','')
entry={'time':'$TS','signal':'negative','hint':hint,'variant':'$VARIANT'}
cf=os.path.join(os.path.expanduser('~'),'.claude','evolution','signals','corrections.jsonl')
with open(cf,'a',encoding='utf-8') as f:
  f.write(json.dumps(entry,ensure_ascii=False)+'\n')
" 2>/dev/null
  elif [ "$IS_CASCADE" -le 0 ]; then
    ESC_MSG=$(echo "${USER_MSG:0:100}" | sed 's/\\/\\\\/g;s/"/\\"/g' | tr '\n' ' ')
    echo "{\"time\":\"$TS\",\"signal\":\"negative\",\"hint\":\"$ESC_MSG\",\"variant\":\"$VARIANT\"}" >> "$SIGNALS_DIR/corrections.jsonl"
  fi
  update_variant_stat "$VARIANT" "corrections"
  SIGNAL_CONTEXT="【负面信号】用户对上一条回答不满。回答当前问题时注意质量。"

  # Bug#3 修复：用 add-file 安全传递 pattern，避免 shell 注入
  # 级联回声修复：清洗用户消息，移除已有的"用户对AI回答不满"前缀，防止嵌套
  if command -v claude &>/dev/null && [ -f "$PYTHON" ] && [ -f "$INSTINCT_SCRIPT" ]; then
    SAFE_MSG=$(echo "$USER_MSG" | tr '\n' ' ' | head -c 100)
    # 移除级联前缀：去掉所有"用户对AI回答不满，说了："嵌套层
    CLEAN_MSG=$(echo "$SAFE_MSG" | sed 's/用户对AI回答不满，说了：//g' | sed 's/^[[:space:]]*//')
    # 如果清洗后为空或太短，跳过 Sonnet 调用
    if [ ${#CLEAN_MSG} -gt 5 ]; then
      TMPFILE=$(mktemp)
      echo "用户纠正了AI的行为：$CLEAN_MSG。用一句话总结AI应该避免什么行为（不超过30字，只输出规则本身）" > "$TMPFILE"
      "$PYTHON" "$BG_SCRIPT" bash -c "
        export PYTHONUTF8=1
        LESSON=\$(claude -p --model sonnet < '$TMPFILE' 2>/dev/null)
        rm -f '$TMPFILE'
        if [ -n \"\$LESSON\" ] && [ \${#LESSON} -gt 5 ] && [ \${#LESSON} -lt 80 ]; then
          LESSON_FILE=\$(mktemp)
          printf '%s' \"\$LESSON\" > \"\$LESSON_FILE\"
          '$PYTHON' '$INSTINCT_SCRIPT' add-file \"\$LESSON_FILE\" laziness user_correction 2>/dev/null
        fi
      "
    fi
  fi

elif [ "$DETECTED_SIGNAL" = "positive" ]; then
  echo "{\"time\":\"$TS\",\"signal\":\"positive\",\"variant\":\"$VARIANT\"}" >> "$SIGNALS_DIR/approvals.jsonl"
  update_variant_stat "$VARIANT" "approvals"
  SIGNAL_CONTEXT="【正面信号】用户认可了上一条回答。继续保持。"

  if command -v claude &>/dev/null && [ -f "$PYTHON" ] && [ -f "$INSTINCT_SCRIPT" ]; then
    TMPFILE=$(mktemp)
    echo "用户认可了AI回答。用一句话总结AI做对了什么（不超过30字，写成行为规则）" > "$TMPFILE"
    "$PYTHON" "$BG_SCRIPT" bash -c "
      export PYTHONUTF8=1
      LESSON=\$(claude -p --model sonnet < '$TMPFILE' 2>/dev/null)
      rm -f '$TMPFILE'
      if [ -n \"\$LESSON\" ] && [ \${#LESSON} -gt 5 ] && [ \${#LESSON} -lt 80 ]; then
        LESSON_FILE=\$(mktemp)
        printf '%s' \"\$LESSON\" > \"\$LESSON_FILE\"
        '$PYTHON' '$INSTINCT_SCRIPT' add-file \"\$LESSON_FILE\" initiative user_approval 2>/dev/null
      fi
    "
  fi
fi

# 修复#6：不对每条中性消息都异步调 Sonnet，只在明确检测不到信号且消息较长时才调
# 移除这个功能——正则+Sonnet异步的收益不值得每条消息一个Sonnet进程的成本

# ================================================================
# 输出构建
# ================================================================

QUIET_MODE=$(grep -o '"quiet_mode": *true' "$EVO_DIR/config.json" 2>/dev/null)

if [ -n "$QUIET_MODE" ]; then
  # ============================================================
  # quiet_mode（方案C）：规则已通过 .claude/rules/evolution-active.md 加载
  # hook 只输出变体标记 + 信号，不注入规则/instinct/范例
  # ============================================================
  FULL_CTX="V=${VARIANT}"
  [ -n "$SIGNAL_CONTEXT" ] && FULL_CTX="${FULL_CTX} ${SIGNAL_CONTEXT}"

else
  # ============================================================
  # 非 quiet_mode：完整注入（兼容未使用 rules 文件的用户）
  # ============================================================

  PROACTIVE_SCRIPT="$HOME/.claude/hooks/scripts/proactive_generator.py"
  PROACTIVE_TEXT=""
  if [ -f "$PROACTIVE_SCRIPT" ] && [ -f "$PYTHON" ] && [ "$MSG_LEN" -gt 5 ]; then
    PROACTIVE_TEXT=$(PYTHONUTF8=1 "$PYTHON" "$PROACTIVE_SCRIPT" generate "$USER_MSG" 2>/dev/null)
    [ -n "$PROACTIVE_TEXT" ] && PROACTIVE_TEXT="【主动思考清单】${PROACTIVE_TEXT}"
  fi

  VARIANT_RULES=""
  VARIANT_FILE="$EVO_DIR/variants/${VARIANT}.md"
  [ -f "$VARIANT_FILE" ] && VARIANT_RULES=$(cat "$VARIANT_FILE" | tr '\n' ' ' | head -c 1500)

  INSTINCT_TEXT=""
  if [ -f "$INSTINCT_SCRIPT" ] && [ -f "$PYTHON" ]; then
    QUERY_TEXT=$(echo "$USER_MSG" | head -c 200)
    INSTINCT_TEXT=$(PYTHONUTF8=1 "$PYTHON" "$INSTINCT_SCRIPT" relevant "$QUERY_TEXT" 2>/dev/null)
  fi
  if [ -z "$INSTINCT_TEXT" ] && [ -f "$INSTINCTS_FILE" ]; then
    INSTINCT_TEXT=$(grep '"pattern"' "$INSTINCTS_FILE" | sed 's/.*"pattern":"//;s/".*//' | head -8 | tr '\n' '; ')
  fi

  EXAMPLES_FILE="$EVO_DIR/initiative_examples.jsonl"
  EXAMPLES_TEXT=""
  if [ -f "$EXAMPLES_FILE" ] && [ -s "$EXAMPLES_FILE" ]; then
    EXAMPLES_TEXT=$(tail -3 "$EXAMPLES_FILE" | grep -o '"pattern":"[^"]*"' | sed 's/"pattern":"//;s/"$//' | tr '\n' '; ')
    [ -n "$EXAMPLES_TEXT" ] && EXAMPLES_TEXT="【高主动性模式】${EXAMPLES_TEXT}"
  fi

  FULL_CTX="【EvoEngine·${VARIANT}】${PROACTIVE_TEXT} ${VARIANT_RULES} Instinct:${INSTINCT_TEXT} ${EXAMPLES_TEXT} ${SIGNAL_CONTEXT}"
fi

if [ -f "$PYTHON" ]; then
  PYTHONUTF8=1 _EVO_CTX="$FULL_CTX" "$PYTHON" -c "
import json,os
ctx=os.environ.get('_EVO_CTX','')
print(json.dumps({'hookSpecificOutput':{'hookEventName':'UserPromptSubmit','additionalContext':ctx}},ensure_ascii=False))
"
else
  ESC=$(echo "$FULL_CTX" | sed 's/"/\\"/g' | tr '\n' ' ')
  cat <<HOOKEOF
{
  "hookSpecificOutput": {
    "hookEventName": "UserPromptSubmit",
    "additionalContext": "${ESC}"
  }
}
HOOKEOF
fi
exit 0
