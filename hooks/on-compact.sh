#!/bin/bash
# PostCompact hook：上下文压缩后重新刷新 rules 文件
# 确保长对话压缩后 rules 文件仍包含最新的 Instinct

EVO_DIR="$HOME/.claude/evolution"

# 紧急关闭开关
[ -f "$EVO_DIR/.disabled" ] && exit 0

SCRIPTS_DIR="$HOME/.claude/hooks/scripts"
source "$SCRIPTS_DIR/find_python.sh"
INSTINCT_SCRIPT="$SCRIPTS_DIR/instinct_manager.py"
INSTINCTS_FILE="$EVO_DIR/instincts/index.json"
ACTIVE_VARIANT="$EVO_DIR/active_variant.txt"
CONFIG="$EVO_DIR/config.json"
RULES_FILE="$HOME/.claude/rules/evolution-active.md"

QUIET_MODE=$(grep -o '"quiet_mode": *true' "$CONFIG" 2>/dev/null)
VARIANT=$(cat "$ACTIVE_VARIANT" 2>/dev/null || echo "A")

if [ -n "$QUIET_MODE" ]; then
  # quiet_mode：刷新 rules 文件即可，不注入 additionalContext
  VARIANT_FILE="$EVO_DIR/variants/${VARIANT}.md"
  VARIANT_CONTENT=""
  [ -f "$VARIANT_FILE" ] && VARIANT_CONTENT=$(cat "$VARIANT_FILE")

  INSTINCT_CONTENT=""
  if [ -f "$INSTINCT_SCRIPT" ] && [ -f "$PYTHON" ]; then
    INSTINCT_CONTENT=$(PYTHONUTF8=1 "$PYTHON" "$INSTINCT_SCRIPT" relevant "通用规则" 2>/dev/null)
  fi
  if [ -z "$INSTINCT_CONTENT" ] && [ -f "$INSTINCTS_FILE" ]; then
    INSTINCT_CONTENT=$(grep '"pattern"' "$INSTINCTS_FILE" | sed 's/.*"pattern":"//;s/".*//' | head -10 | tr '\n' '; ')
  fi

  mkdir -p "$(dirname "$RULES_FILE")" 2>/dev/null
  if [ -f "$PYTHON" ]; then
    PYTHONUTF8=1 _V="$VARIANT" _VC="$VARIANT_CONTENT" _IC="$INSTINCT_CONTENT" "$PYTHON" -c "
import os
v = os.environ.get('_V', 'A')
vc = os.environ.get('_VC', '')
ic = os.environ.get('_IC', '')
rules_file = os.path.join(os.path.expanduser('~'), '.claude', 'rules', 'evolution-active.md')
lines = ['# Evolution Engine v2 - Active Rules', '', f'Current variant: {v}', '']
if vc:
    lines.append(vc)
    lines.append('')
if ic:
    lines.append('## Learned Instincts')
    lines.append('')
    for item in ic.split(';'):
        item = item.strip()
        if item:
            lines.append(f'- {item}')
    lines.append('')
lines.append('## Block Correction Format')
lines.append('')
lines.append('When blocked by Evolution Engine (you will see a reason in Stop hook feedback),')
lines.append('output a --- separator then provide the corrected response ending with 【已修正】.')
lines.append('')
tmp = rules_file + '.tmp'
with open(tmp, 'w', encoding='utf-8') as f:
    f.write('\n'.join(lines))
os.replace(tmp, rules_file)
" 2>/dev/null
  fi
  # quiet_mode 下不输出 additionalContext
  exit 0
fi

# 非 quiet_mode：保持原有行为，通过 additionalContext 注入
INSTINCT_TEXT=""
if [ -f "$INSTINCT_SCRIPT" ] && [ -f "$PYTHON" ]; then
  INSTINCT_TEXT=$(PYTHONUTF8=1 "$PYTHON" "$INSTINCT_SCRIPT" relevant "通用规则" 2>/dev/null)
fi
if [ -z "$INSTINCT_TEXT" ] && [ -f "$INSTINCTS_FILE" ]; then
  INSTINCT_TEXT=$(grep '"pattern"' "$INSTINCTS_FILE" | sed 's/.*"pattern":"//;s/".*//' | head -8 | tr '\n' '; ')
fi

FULL_CTX="【压缩后规则重载】Instinct:${INSTINCT_TEXT}"

if [ -f "$PYTHON" ]; then
  PYTHONUTF8=1 _EVO_CTX="$FULL_CTX" "$PYTHON" -c "
import json,os
ctx=os.environ.get('_EVO_CTX','')
print(json.dumps({'hookSpecificOutput':{'hookEventName':'PostCompact','additionalContext':ctx}},ensure_ascii=False))
"
else
  ESC=$(echo "$FULL_CTX" | sed 's/"/\\"/g' | tr '\n' ' ')
  echo "{\"hookSpecificOutput\":{\"hookEventName\":\"PostCompact\",\"additionalContext\":\"${ESC}\"}}"
fi
exit 0
