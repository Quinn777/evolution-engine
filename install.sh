#!/bin/bash
# ================================================================
# Evolution Engine v2 — One-click Installer
# Installs the anti-laziness system for Claude Code
# Supports: Windows (Git Bash), macOS, Linux
# ================================================================

set -e

CLAUDE_DIR="$HOME/.claude"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SCRIPTS_DIR="$HOOKS_DIR/scripts"
EVO_DIR="$CLAUDE_DIR/evolution"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "================================================"
echo "  Evolution Engine v2 — Installer"
echo "================================================"
echo ""

# Check prerequisites
echo "[1/5] Checking prerequisites..."

# Check Claude Code
if ! command -v claude &>/dev/null; then
  echo "ERROR: Claude Code CLI not found. Install it first:"
  echo "  npm install -g @anthropic-ai/claude-code"
  exit 1
fi
CLAUDE_VER=$(claude --version 2>/dev/null || echo "unknown")
echo "  Claude Code: $CLAUDE_VER"

# Check Python
PYTHON=""
for cmd in python3 python; do
  p=$(command -v "$cmd" 2>/dev/null)
  if [ -n "$p" ] && "$p" -c "pass" 2>/dev/null; then
    PYTHON="$p"
    break
  fi
done
# Windows-specific search
if [ -z "$PYTHON" ]; then
  for ver in 313 312 311 310 39; do
    for base in "$LOCALAPPDATA/Programs/Python/Python${ver}" "$HOME/AppData/Local/Programs/Python/Python${ver}"; do
      if [ -f "$base/python.exe" ] && "$base/python.exe" -c "pass" 2>/dev/null; then
        PYTHON="$base/python.exe"
        break 2
      fi
    done
  done
fi
if [ -z "$PYTHON" ]; then
  echo "ERROR: Python 3 not found. Install Python 3.9+ first."
  exit 1
fi
echo "  Python: $($PYTHON --version 2>&1)"

# Check bash
echo "  Bash: $(bash --version | head -1)"
echo ""

# Create directories
echo "[2/5] Creating directories..."
mkdir -p "$HOOKS_DIR" "$SCRIPTS_DIR" "$EVO_DIR/variants" "$EVO_DIR/instincts" "$EVO_DIR/signals" "$CLAUDE_DIR/rules"
echo "  Done."
echo ""

# Copy files
echo "[3/5] Copying files..."
cp "$SCRIPT_DIR/hooks/"*.sh "$HOOKS_DIR/"
cp "$SCRIPT_DIR/hooks/scripts/"*.py "$SCRIPT_DIR/hooks/scripts/"*.sh "$SCRIPTS_DIR/"
cp "$SCRIPT_DIR/evolution/variants/"*.md "$EVO_DIR/variants/"
cp "$SCRIPT_DIR/evolution/config.json" "$EVO_DIR/"
# Initialize state files (create if not existing)
[ ! -f "$EVO_DIR/session_counter.txt" ] && echo "0" > "$EVO_DIR/session_counter.txt"
[ ! -f "$EVO_DIR/.block_count" ] && echo "0" > "$EVO_DIR/.block_count"
[ ! -f "$EVO_DIR/.rewrite_count" ] && echo "0" > "$EVO_DIR/.rewrite_count"
[ ! -f "$EVO_DIR/active_variant.txt" ] && echo "A" > "$EVO_DIR/active_variant.txt"
[ ! -f "$EVO_DIR/instincts/index.json" ] && cp "$SCRIPT_DIR/evolution/instincts/index.json" "$EVO_DIR/instincts/index.json"

# Initialize variant stats
if [ ! -f "$EVO_DIR/variant_stats.json" ]; then
  cat > "$EVO_DIR/variant_stats.json" << 'STATEOF'
{
  "A": {"sessions": 0, "blocks": 0, "corrections": 0, "approvals": 0},
  "B": {"sessions": 0, "blocks": 0, "corrections": 0, "approvals": 0},
  "C": {"sessions": 0, "blocks": 0, "corrections": 0, "approvals": 0}
}
STATEOF
fi

# Initialize signal files
for f in corrections.jsonl approvals.jsonl blocks.jsonl sonnet_reviews.jsonl task_reviews.jsonl; do
  [ ! -f "$EVO_DIR/signals/$f" ] && touch "$EVO_DIR/signals/$f"
done

echo "  Copied $(find "$SCRIPT_DIR" -type f -name "*.sh" -o -name "*.py" -o -name "*.md" -o -name "*.json" | wc -l | tr -d ' ') files."
echo ""

# Fix paths in hooks based on OS
echo "[4/5] Configuring hooks..."

# Detect home path format for settings.json
if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OS" == "Windows_NT" ]]; then
  # Windows: use forward slashes with drive letter
  WIN_HOME=$(cygpath -m "$HOME" 2>/dev/null || echo "$HOME" | sed 's|\\|/|g')
  HOOK_PREFIX="bash ${WIN_HOME}/.claude/hooks"
else
  # macOS/Linux
  HOOK_PREFIX="bash \$HOME/.claude/hooks"
fi

# Generate settings.json hooks section
HOOKS_JSON=$(cat << ENDJSON
{
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${HOOK_PREFIX}/on-prompt.sh",
            "timeout": 15
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${HOOK_PREFIX}/on-stop.sh",
            "timeout": 60,
            "statusMessage": "Quality review..."
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${HOOK_PREFIX}/on-session-start.sh",
            "timeout": 30
          }
        ]
      }
    ],
    "PostCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${HOOK_PREFIX}/on-compact.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${HOOK_PREFIX}/on-task-completed.sh",
            "timeout": 30
          }
        ]
      }
    ],
    "PostToolUseFailure": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${HOOK_PREFIX}/on-tool-failure.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Agent",
        "hooks": [
          {
            "type": "command",
            "command": "${HOOK_PREFIX}/on-post-tool.sh",
            "timeout": 120,
            "statusMessage": "Reviewing agent work..."
          }
        ]
      }
    ]
  }
ENDJSON
)

# Merge hooks into existing settings.json
if [ -f "$SETTINGS_FILE" ]; then
  if "$PYTHON" -c "
import json, sys
settings = json.load(open('$SETTINGS_FILE', encoding='utf-8'))
hooks = json.loads('''$HOOKS_JSON''')
settings['hooks'] = hooks
with open('$SETTINGS_FILE', 'w', encoding='utf-8') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
print('Merged hooks into existing settings.json')
" 2>/dev/null; then
    :
  else
    echo "  WARNING: Could not merge into existing settings.json."
    echo "  You may need to manually add the hooks configuration."
  fi
else
  "$PYTHON" -c "
import json
hooks = json.loads('''$HOOKS_JSON''')
settings = {'hooks': hooks}
with open('$SETTINGS_FILE', 'w', encoding='utf-8') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
print('Created new settings.json')
"
fi
echo ""

# Verify
echo "[5/5] Verifying installation..."
ERRORS=0

for f in on-prompt.sh on-stop.sh on-post-tool.sh on-session-start.sh on-compact.sh on-task-completed.sh on-tool-failure.sh; do
  if [ ! -f "$HOOKS_DIR/$f" ]; then
    echo "  MISSING: $f"
    ERRORS=$((ERRORS + 1))
  fi
done

for f in bg_run.py instinct_manager.py stats_rw.py proactive_generator.py task_reviewer.py find_python.sh; do
  if [ ! -f "$SCRIPTS_DIR/$f" ]; then
    echo "  MISSING: $f"
    ERRORS=$((ERRORS + 1))
  fi
done

if [ "$ERRORS" -eq 0 ]; then
  echo "  All files OK."
  echo ""
  echo "================================================"
  echo "  Installation complete!"
  echo "  Start a new Claude Code session to activate."
  echo ""
  echo "  To disable: touch ~/.claude/evolution/.disabled"
  echo "  To re-enable: rm ~/.claude/evolution/.disabled"
  echo "================================================"
else
  echo ""
  echo "  ERROR: $ERRORS files missing. Installation may be incomplete."
  exit 1
fi
