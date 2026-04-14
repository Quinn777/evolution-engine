#!/bin/bash
# Evolution Engine v2 状态查看
# 用法：! bash ~/.claude/hooks/scripts/evo_status.sh

EVO_DIR="$HOME/.claude/evolution"
SCRIPTS_DIR="$HOME/.claude/hooks/scripts"
source "$SCRIPTS_DIR/find_python.sh"

echo "=== Evolution Engine v2 状态 ==="
echo ""

# 开关状态
if [ -f "$EVO_DIR/.disabled" ]; then
  echo "状态: ❌ 已禁用（删除 $EVO_DIR/.disabled 重新启用）"
else
  echo "状态: ✅ 运行中"
fi
echo ""

# 当前变体
echo "当前变体: $(cat $EVO_DIR/active_variant.txt 2>/dev/null || echo '未知')"
echo ""

# 变体统计
echo "--- 变体统计 ---"
if [ -n "$PYTHON" ]; then
  "$PYTHON" -c "
import json,os,sys
sf=os.path.join(os.path.expanduser('~'),'.claude','evolution','variant_stats.json')
d=json.load(open(sf,encoding='utf-8'))
for v in ['A','B','C']:
  s=d.get(v,{})
  ses=s.get('sessions',0)
  blk=s.get('blocks',0)
  cor=s.get('corrections',0)
  apr=s.get('approvals',0)
  score=50+((apr*10-cor*20-blk*30)//ses) if ses>0 else 50
  print(f'  {v}: {ses}次会话, {blk}拦截, {cor}纠正, {apr}认可, score={score}')
" 2>/dev/null
else
  cat "$EVO_DIR/variant_stats.json" 2>/dev/null
fi
echo ""

# Instinct
echo "--- Instinct ---"
INST_COUNT=$(grep -c '"id"' "$EVO_DIR/instincts/index.json" 2>/dev/null || echo 0)
echo "  总数: $INST_COUNT / 50"
echo ""

# 信号统计
echo "--- 信号统计 ---"
BLOCKS=$(wc -l < "$EVO_DIR/signals/blocks.jsonl" 2>/dev/null || echo 0)
CORRECTIONS=$(wc -l < "$EVO_DIR/signals/corrections.jsonl" 2>/dev/null || echo 0)
APPROVALS=$(wc -l < "$EVO_DIR/signals/approvals.jsonl" 2>/dev/null || echo 0)
echo "  拦截: $BLOCKS  纠正: $CORRECTIONS  认可: $APPROVALS"
echo ""

# 会话计数
echo "会话总数: $(cat $EVO_DIR/session_counter.txt 2>/dev/null || echo 0)"

# 进化日志
EVO_COUNT=$(wc -l < "$EVO_DIR/evolution_log.jsonl" 2>/dev/null || echo 0)
echo "进化次数: $EVO_COUNT"

# 范例数
EX_COUNT=$(wc -l < "$EVO_DIR/initiative_examples.jsonl" 2>/dev/null || echo 0)
echo "高主动性范例: $EX_COUNT / 10"

echo ""
echo "命令："
echo "  禁用: touch ~/.claude/evolution/.disabled"
echo "  启用: rm ~/.claude/evolution/.disabled"
echo "  查看Instinct: cat ~/.claude/evolution/instincts/index.json"
echo "  查看进化日志: cat ~/.claude/evolution/evolution_log.jsonl"
