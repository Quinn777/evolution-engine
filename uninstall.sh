#!/bin/bash
# Evolution Engine v2 — Uninstaller
set -e

echo "Uninstalling Evolution Engine v2..."

# Remove hook scripts
rm -f "$HOME/.claude/hooks/on-prompt.sh"
rm -f "$HOME/.claude/hooks/on-stop.sh"
rm -f "$HOME/.claude/hooks/on-post-tool.sh"
rm -f "$HOME/.claude/hooks/on-session-start.sh"
rm -f "$HOME/.claude/hooks/on-compact.sh"
rm -f "$HOME/.claude/hooks/on-task-completed.sh"
rm -f "$HOME/.claude/hooks/on-tool-failure.sh"

# Remove scripts
rm -f "$HOME/.claude/hooks/scripts/bg_run.py"
rm -f "$HOME/.claude/hooks/scripts/instinct_manager.py"
rm -f "$HOME/.claude/hooks/scripts/stats_rw.py"
rm -f "$HOME/.claude/hooks/scripts/proactive_generator.py"
rm -f "$HOME/.claude/hooks/scripts/task_reviewer.py"
rm -f "$HOME/.claude/hooks/scripts/find_python.sh"
rm -f "$HOME/.claude/hooks/scripts/evo_status.sh"

# Remove evolution data
rm -rf "$HOME/.claude/evolution"

# Remove hooks from settings.json (keep other settings)
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ]; then
  python3 -c "
import json
f='$SETTINGS'
d=json.load(open(f,encoding='utf-8'))
d.pop('hooks',None)
json.dump(d,open(f,'w',encoding='utf-8'),indent=2,ensure_ascii=False)
print('Removed hooks from settings.json')
" 2>/dev/null || python -c "
import json
f='$SETTINGS'
d=json.load(open(f,encoding='utf-8'))
d.pop('hooks',None)
json.dump(d,open(f,'w',encoding='utf-8'),indent=2,ensure_ascii=False)
print('Removed hooks from settings.json')
" 2>/dev/null || echo "WARNING: Could not clean settings.json. Remove 'hooks' section manually."
fi

echo "Done. Evolution Engine v2 has been removed."
