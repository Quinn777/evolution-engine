#!/bin/bash
# ================================================================
# Evolution Engine v2 — SessionStart Hook (v2.1 修复版)
# 修复：从信号文件重算 corrections/approvals (Bug#1)、
# breed 状态一致性 (Bug#9)、breed 异步化 (Bug#11)
# ================================================================

EVO_DIR="$HOME/.claude/evolution"
ACTIVE_VARIANT="$EVO_DIR/active_variant.txt"
SESSION_COUNTER="$EVO_DIR/session_counter.txt"
CONFIG="$EVO_DIR/config.json"
EVO_LOG="$EVO_DIR/evolution_log.jsonl"
INSTINCTS_FILE="$EVO_DIR/instincts/index.json"
SCRIPTS_DIR="$HOME/.claude/hooks/scripts"
source "$SCRIPTS_DIR/find_python.sh"
STATS_SCRIPT="$SCRIPTS_DIR/stats_rw.py"
BG_SCRIPT="$SCRIPTS_DIR/bg_run.py"
SIGNALS_DIR="$EVO_DIR/signals"

# 紧急关闭开关
[ -f "$EVO_DIR/.disabled" ] && exit 0

# 清理上个 session 的计数器
echo "0" > "$EVO_DIR/.rewrite_count" 2>/dev/null
echo "0" > "$EVO_DIR/.block_count" 2>/dev/null
rm -f "$EVO_DIR/.block_active" 2>/dev/null

# ================================================================
# Bug#1 修复：从信号文件重新计算 corrections/approvals 并同步到 stats
# 这是 on-prompt.sh 中 update_variant_stat 可能失败的兜底
# ================================================================

if [ -f "$PYTHON" ]; then
  PYTHONUTF8=1 "$PYTHON" -c "
import json,os
from pathlib import Path

evo=Path.home()/'.claude'/'evolution'
stats_file=evo/'variant_stats.json'
signals=evo/'signals'

try:
    stats=json.load(open(stats_file,'r',encoding='utf-8'))
except:
    stats={'A':{'sessions':0,'blocks':0,'corrections':0,'approvals':0},
           'B':{'sessions':0,'blocks':0,'corrections':0,'approvals':0},
           'C':{'sessions':0,'blocks':0,'corrections':0,'approvals':0}}

# 从信号文件重新计算 corrections 和 approvals
for variant in ['A','B','C']:
    cor_count=0
    apr_count=0

    cor_file=signals/'corrections.jsonl'
    if cor_file.exists():
        for line in open(cor_file,'r',encoding='utf-8'):
            line=line.strip()
            if not line: continue
            try:
                d=json.loads(line)
                if d.get('variant')==variant:
                    cor_count+=1
            except: pass

    apr_file=signals/'approvals.jsonl'
    if apr_file.exists():
        for line in open(apr_file,'r',encoding='utf-8'):
            line=line.strip()
            if not line: continue
            try:
                d=json.loads(line)
                if d.get('variant')==variant:
                    apr_count+=1
            except: pass

    if variant not in stats:
        stats[variant]={'sessions':0,'blocks':0,'corrections':0,'approvals':0}
    stats[variant]['corrections']=cor_count
    stats[variant]['approvals']=apr_count

tmp=str(stats_file)+'.tmp'
with open(tmp,'w',encoding='utf-8') as f:
    json.dump(stats,f,ensure_ascii=False,indent=2)
os.replace(tmp,str(stats_file))
" 2>/dev/null
fi

# ================================================================
# 计算 score 并加权随机选变体
# ================================================================

calc_score() {
  local ses=$1 blk=$2 cor=$3 apr=$4
  if [ "$ses" -eq 0 ]; then
    echo 50
  else
    local raw=$(( 50 + (apr * 10 - cor * 20 - blk * 30) / ses ))
    [ "$raw" -lt 1 ] && raw=1
    [ "$raw" -gt 100 ] && raw=100
    echo $raw
  fi
}

if [ -f "$PYTHON" ] && [ -f "$STATS_SCRIPT" ]; then
  STAT_LINE=$("$PYTHON" -c "
import json,sys
from pathlib import Path
f=Path.home()/'.claude'/'evolution'/'variant_stats.json'
try: d=json.load(open(f,encoding='utf-8'))
except: d={}
parts=[]
for v in ['A','B','C']:
  s=d.get(v,{})
  parts.extend([str(s.get('sessions',0)),str(s.get('blocks',0)),str(s.get('corrections',0)),str(s.get('approvals',0))])
print(' '.join(parts))
" 2>/dev/null)
  if [ -n "$STAT_LINE" ]; then
    read A_SES A_BLK A_COR A_APR B_SES B_BLK B_COR B_APR C_SES C_BLK C_COR C_APR <<< "$STAT_LINE"
  fi
fi

[ -z "$A_SES" ] && A_SES=0; [ -z "$A_BLK" ] && A_BLK=0; [ -z "$A_COR" ] && A_COR=0; [ -z "$A_APR" ] && A_APR=0
[ -z "$B_SES" ] && B_SES=0; [ -z "$B_BLK" ] && B_BLK=0; [ -z "$B_COR" ] && B_COR=0; [ -z "$B_APR" ] && B_APR=0
[ -z "$C_SES" ] && C_SES=0; [ -z "$C_BLK" ] && C_BLK=0; [ -z "$C_COR" ] && C_COR=0; [ -z "$C_APR" ] && C_APR=0

SCORE_A=$(calc_score $A_SES $A_BLK $A_COR $A_APR)
SCORE_B=$(calc_score $B_SES $B_BLK $B_COR $B_APR)
SCORE_C=$(calc_score $C_SES $C_BLK $C_COR $C_APR)

# 加权随机
TOTAL=$((SCORE_A + SCORE_B + SCORE_C))
RAND=$((RANDOM % TOTAL))

if [ "$RAND" -lt "$SCORE_A" ]; then
  VARIANT="A"
elif [ "$RAND" -lt $((SCORE_A + SCORE_B)) ]; then
  VARIANT="B"
else
  VARIANT="C"
fi

echo "$VARIANT" > "$ACTIVE_VARIANT"

# 通过 Python 统一模块原子递增 sessions
[ -f "$PYTHON" ] && "$PYTHON" "$STATS_SCRIPT" increment "$VARIANT" sessions 2>>"$EVO_DIR/error.log" || true

# ================================================================
# 方案C：将变体规则 + Instinct 写入 .claude/rules/ 文件
# 由 Claude Code 在 session 启动时自动加载，不经过 additionalContext
# ================================================================

RULES_DIR="$HOME/.claude/rules"
RULES_FILE="$RULES_DIR/evolution-active.md"
INSTINCT_SCRIPT="$SCRIPTS_DIR/instinct_manager.py"

mkdir -p "$RULES_DIR" 2>/dev/null

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

if [ -f "$PYTHON" ]; then
  PYTHONUTF8=1 _V="$VARIANT" _VC="$VARIANT_CONTENT" _IC="$INSTINCT_CONTENT" "$PYTHON" -c "
import os
v = os.environ.get('_V', 'A')
vc = os.environ.get('_VC', '')
ic = os.environ.get('_IC', '')

rules_file = os.path.join(os.path.expanduser('~'), '.claude', 'rules', 'evolution-active.md')
lines = []
lines.append('# Evolution Engine v2 - Active Rules')
lines.append('')
lines.append(f'Current variant: {v}')
lines.append('')
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
else
  # bash fallback
  {
    echo "# Evolution Engine v2 - Active Rules"
    echo ""
    echo "Current variant: $VARIANT"
    echo ""
    [ -n "$VARIANT_CONTENT" ] && echo "$VARIANT_CONTENT" && echo ""
    if [ -n "$INSTINCT_CONTENT" ]; then
      echo "## Learned Instincts"
      echo ""
      echo "$INSTINCT_CONTENT" | tr ';' '\n' | while read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//')
        [ -n "$line" ] && echo "- $line"
      done
      echo ""
    fi
  } > "$RULES_FILE"
fi

# ================================================================
# PromptBreeder 进化检查
# ================================================================

COUNT=$(cat "$SESSION_COUNTER" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$SESSION_COUNTER"

BREED_INTERVAL=$(grep -o '"breed_interval": *[0-9]*' "$CONFIG" 2>/dev/null | grep -o '[0-9]*')
[ -z "$BREED_INTERVAL" ] && BREED_INTERVAL=30
MIN_PER_VARIANT=$(grep -o '"min_sessions_per_variant": *[0-9]*' "$CONFIG" 2>/dev/null | grep -o '[0-9]*')
[ -z "$MIN_PER_VARIANT" ] && MIN_PER_VARIANT=5

if [ $((COUNT % BREED_INTERVAL)) -eq 0 ] && [ "$COUNT" -gt 0 ]; then
  A_SES=$("$PYTHON" "$STATS_SCRIPT" read A sessions 2>/dev/null); [ -z "$A_SES" ] && A_SES=0
  B_SES=$("$PYTHON" "$STATS_SCRIPT" read B sessions 2>/dev/null); [ -z "$B_SES" ] && B_SES=0
  C_SES=$("$PYTHON" "$STATS_SCRIPT" read C sessions 2>/dev/null); [ -z "$C_SES" ] && C_SES=0

  if [ "$A_SES" -ge "$MIN_PER_VARIANT" ] && [ "$B_SES" -ge "$MIN_PER_VARIANT" ] && [ "$C_SES" -ge "$MIN_PER_VARIANT" ]; then

    # 重新读取最新统计后重算分数
    A_BLK=$("$PYTHON" "$STATS_SCRIPT" read A blocks 2>/dev/null); [ -z "$A_BLK" ] && A_BLK=0
    A_COR=$("$PYTHON" "$STATS_SCRIPT" read A corrections 2>/dev/null); [ -z "$A_COR" ] && A_COR=0
    A_APR=$("$PYTHON" "$STATS_SCRIPT" read A approvals 2>/dev/null); [ -z "$A_APR" ] && A_APR=0
    B_BLK=$("$PYTHON" "$STATS_SCRIPT" read B blocks 2>/dev/null); [ -z "$B_BLK" ] && B_BLK=0
    B_COR=$("$PYTHON" "$STATS_SCRIPT" read B corrections 2>/dev/null); [ -z "$B_COR" ] && B_COR=0
    B_APR=$("$PYTHON" "$STATS_SCRIPT" read B approvals 2>/dev/null); [ -z "$B_APR" ] && B_APR=0
    C_BLK=$("$PYTHON" "$STATS_SCRIPT" read C blocks 2>/dev/null); [ -z "$C_BLK" ] && C_BLK=0
    C_COR=$("$PYTHON" "$STATS_SCRIPT" read C corrections 2>/dev/null); [ -z "$C_COR" ] && C_COR=0
    C_APR=$("$PYTHON" "$STATS_SCRIPT" read C approvals 2>/dev/null); [ -z "$C_APR" ] && C_APR=0

    SCORE_A=$(calc_score $A_SES $A_BLK $A_COR $A_APR)
    SCORE_B=$(calc_score $B_SES $B_BLK $B_COR $B_APR)
    SCORE_C=$(calc_score $C_SES $C_BLK $C_COR $C_APR)

    WORST="A"; WORST_SCORE=$SCORE_A
    BEST="A"; BEST_SCORE=$SCORE_A

    if [ "$SCORE_B" -lt "$WORST_SCORE" ]; then WORST="B"; WORST_SCORE=$SCORE_B; fi
    if [ "$SCORE_C" -lt "$WORST_SCORE" ]; then WORST="C"; WORST_SCORE=$SCORE_C; fi
    if [ "$SCORE_B" -gt "$BEST_SCORE" ]; then BEST="B"; BEST_SCORE=$SCORE_B; fi
    if [ "$SCORE_C" -gt "$BEST_SCORE" ]; then BEST="C"; BEST_SCORE=$SCORE_C; fi

    if [ "$WORST" != "$BEST" ]; then
      TS=$(date +%Y%m%d_%H%M%S)
      BEST_FILE="$EVO_DIR/variants/${BEST}.md"
      WORST_FILE="$EVO_DIR/variants/${WORST}.md"

      cp "$BEST_FILE" "$WORST_FILE"

      INSTINCT_DATA=""
      if [ -f "$INSTINCTS_FILE" ]; then
        INSTINCT_DATA=$(grep '"pattern"' "$INSTINCTS_FILE" | sed 's/.*"pattern":"//;s/".*//' | head -10 | tr '\n' '; ')
      fi
      BEST_CONTENT=$(cat "$BEST_FILE" | tr '\n' ' ' | head -c 1000)

      MUTATION_PROMPT=$(mktemp)
      cat > "$MUTATION_PROMPT" << MUTEOF
你是AI行为规则优化专家。基于以下行为模式数据，修改下面这套规则使其更有效。

行为模式数据（从实际使用中学到的）：
$INSTINCT_DATA

当前最佳规则：
$BEST_CONTENT

要求：
1. 保留有效的规则
2. 根据行为模式数据增加新规则或修改现有规则
3. 删除与行为模式矛盾的规则
4. 输出修改后的完整规则文件（markdown格式）
5. 只输出规则内容，不要解释
MUTEOF

      # 后台异步变异，用临时文件传递所有参数
      BREED_META=$(mktemp)
      cat > "$BREED_META" << METAEOF
WORST_FILE=$WORST_FILE
WORST=$WORST
BEST=$BEST
BEST_SCORE=$BEST_SCORE
WORST_SCORE=$WORST_SCORE
TS=$TS
PYTHON=$PYTHON
STATS_SCRIPT=$STATS_SCRIPT
EVO_LOG=$EVO_LOG
METAEOF

      "$PYTHON" "$BG_SCRIPT" bash -c '
        export PYTHONUTF8=1
        source "$1"
        MUTATED=$(claude -p --model sonnet < "$0" 2>/dev/null)
        rm -f "$0" "$1"
        if [ -n "$MUTATED" ] && [ ${#MUTATED} -gt 50 ]; then
          printf "%s" "$MUTATED" > "$WORST_FILE"
          "$PYTHON" "$STATS_SCRIPT" breed_reset "$WORST" 2>/dev/null
          printf "{\"time\":\"%s\",\"action\":\"breed\",\"best\":\"%s\",\"best_score\":%s,\"worst\":\"%s\",\"worst_score\":%s,\"status\":\"success\"}\n" "$TS" "$BEST" "$BEST_SCORE" "$WORST" "$WORST_SCORE" >> "$EVO_LOG"
        else
          printf "{\"time\":\"%s\",\"action\":\"breed\",\"best\":\"%s\",\"worst\":\"%s\",\"status\":\"sonnet_failed\"}\n" "$TS" "$BEST" "$WORST" >> "$EVO_LOG"
        fi
      ' "$MUTATION_PROMPT" "$BREED_META"
    fi
  fi
fi

exit 0
