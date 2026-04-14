# Evolution Engine v2

**让 Claude 审 Claude——Claude Code 防偷懒 & 规则自进化系统**

基于 Claude Code Hooks API。Sonnet 实时审查主模型输出，三层拦截偷懒回答（正则 → 跨模型审查 → 对抗式辩论），从用户纠正中自动学习行为规则，PromptBreeder 驱动三套规则变体竞争进化。装完即用，quiet_mode 全程静默。

**Let Claude review Claude — anti-laziness system with cross-model review & self-evolving rules.**

Built on Claude Code Hooks API. Sonnet reviews every response in real-time with 3-layer blocking (regex → cross-model audit → adversarial debate). Learns behavioral rules from your corrections. Three competing rule variants evolve automatically via PromptBreeder. One-command install, runs silently.

### Demo

```
You: 帮我分析用 Python 做 Web 开发的技术选型

Claude: 大约有几种方案，一般来说差不多都能满足需求...
```
> ⛔ **Stop hook → `正则拦截: 模糊用词: 大约 一般来说 差不多`**
```
Claude (corrected):
---
具体有 3 种方案：

1. Django — 全栈框架，内置 ORM/Admin/Auth，适合快速搭建完整 Web 应用
   - 优势：生态成熟，文档完善，适合中大型项目
   - 劣势：框架较重，异步支持不如 FastAPI

2. FastAPI — 基于 Starlette + Pydantic，原生异步
   - 优势：性能高，自动生成 OpenAPI 文档，类型安全
   - 劣势：全栈能力弱，需自行集成 ORM/模板

3. Flask — 微框架，核心精简，扩展灵活
   - 优势：学习成本低，自由度高
   - 劣势：大型项目需要大量手动集成

推荐：API 服务选 FastAPI，全栈 Web 应用选 Django，轻量原型选 Flask。
【已修正】
```

---

## Features | 功能

### Real-time Quality Enforcement | 实时质量拦截

| Feature | Description |
|---------|-------------|
| **Fuzzy word blocking** | Detects vague language ("approximately", "generally speaking") and forces rewrite. 检测模糊用词并强制重写 |
| **Sonnet cross-model review** | Calls Sonnet to judge laziness, initiative, and completeness after each response (400+ chars). 每次回答后调用 Sonnet 跨模型审查 |
| **Debate review** | For long responses (800+ chars), adversarial review that attacks logical flaws. 对长回答进行对抗式辩论审查 |
| **Sub-agent review** | Reviews whether delegated sub-agent work was thorough or superficial. 审查子 Agent 工作是否全面 |
| **Task completion check** | Verifies the AI actually tested/validated its changes. 检查 AI 是否验证了自己的改动 |

### Behavioral Learning | 行为学习

| Feature | Description |
|---------|-------------|
| **Instinct system** | Extracts rules from corrections and reviews (e.g., "don't fabricate numbers"). Uses TF-IDF similarity for dedup and retrieval. Persists across sessions. 从用户纠正中提炼行为规则，用 TF-IDF 语义去重和检索，跨 session 持久化 |
| **Signal detection** | Detects positive/negative feedback from user messages via keyword matching. 从用户消息中检测正面/负面信号 |
| **Proactive checklist** | Generates context-aware reminders (project stage, priorities, past mistakes, task completion criteria). 生成上下文感知的主动思考清单 |

### PromptBreeder Evolution | 行为进化

| Feature | Description |
|---------|-------------|
| **3 competing variants** | A (baseline), B (balanced), C (proactive) — selected by weighted random per session. 三套行为规则变体加权竞争 |
| **Performance tracking** | Tracks blocks, corrections, approvals per variant. Score = `50 + (approvals*10 - corrections*20 - blocks*30) / sessions`. 追踪每个变体的拦截/纠正/认可数据 |
| **Auto mutation** | Every 30 sessions, worst variant replaced by Sonnet-mutated copy of best. 每 30 个 session，最差变体被最优变体的 Sonnet 变异副本替换 |

## Architecture | 架构

```
Session start
    │
    ▼
[SessionStart Hook]
    Weighted variant selection → write rules to ~/.claude/rules/evolution-active.md
    │
    ▼
User sends message
    │
    ▼
[UserPromptSubmit Hook]
    Signal detection (positive/negative) → output: "V=A" (quiet_mode)
    │
    ▼
AI generates response (streamed to user)
    │
    ▼
[Stop Hook] ── regex check ── Sonnet review ── debate review ── task review
    │                                │
    pass                          block → AI forced to rewrite with reason
    │
    ▼
[PostToolUse Hook] (Agent tools only)
    Sub-agent quality review via Sonnet
    │
    ▼
[PostCompact Hook] (on context compression)
    Refresh rules file with latest instincts
```

### quiet_mode (default)

Rules and instincts are loaded via `~/.claude/rules/evolution-active.md` (silent, no visible output). Hook output is minimized to `V=A` per turn. Block messages show only the reason (e.g., `正则拦截: 模糊用词: 大约`), correction format instructions are pre-loaded in the rules file.

规则和 instinct 通过 rules 文件静默加载，hook 输出压缩到 `V=A`。拦截消息只显示原因，修正格式指令预加载在 rules 文件中。

## Requirements | 环境要求

- **[Claude Code](https://docs.anthropic.com/en/docs/claude-code)** (CLI, desktop app, or IDE extension)
- **Python** 3.9+
- **Bash** (Git Bash on Windows, native on macOS/Linux)
- Optional: `scikit-learn` for better TF-IDF instinct matching (falls back to `difflib`)

## Quick Start | 快速开始

```bash
git clone https://github.com/Quinn777/evolution-engine.git
cd evolution-engine
bash install.sh
```

The installer automatically:
1. Checks prerequisites (Claude Code, Python, Bash)
2. Copies hooks and scripts to `~/.claude/`
3. Creates `~/.claude/rules/` for silent rule loading
4. Configures hooks in `~/.claude/settings.json` (backs up existing)
5. Initializes state files

安装脚本自动完成环境检查、文件复制、rules 目录创建、hooks 配置（备份现有配置）。安装后开启新 Claude Code session 即生效。

```bash
bash uninstall.sh    # Uninstall | 卸载
```

## Configuration | 配置

Edit `~/.claude/evolution/config.json`:

```json
{
  "sonnet_review_enabled": true,
  "sonnet_review_min_length": 400,
  "task_review_enabled": true,
  "breed_interval": 30,
  "min_sessions_per_variant": 5,
  "max_instincts": 50,
  "variant_count": 3,
  "regex_block_enabled": true,
  "quiet_mode": true
}
```

| Key | Description | Default |
|-----|-------------|---------|
| `sonnet_review_enabled` | Enable Sonnet cross-model review. 启用 Sonnet 审查 | `true` |
| `sonnet_review_min_length` | Min response length (chars) to trigger review. 触发审查的最小字符数 | `400` |
| `task_review_enabled` | Review task/sub-agent completeness. 审查做事完成度 | `true` |
| `breed_interval` | Sessions between evolution cycles. 进化间隔（session 数） | `30` |
| `min_sessions_per_variant` | Min sessions per variant before evolution. 进化前每变体最少 session 数 | `5` |
| `max_instincts` | Max learned behavior patterns. 最大 instinct 条数 | `50` |
| `variant_count` | Number of competing variants. 竞争变体数量 | `3` |
| `regex_block_enabled` | Block fuzzy/vague wording via regex. 正则拦截模糊用词 | `true` |
| `quiet_mode` | Load rules via file (silent), minimize hook output. 通过 rules 文件静默加载规则，最小化 hook 可见输出 | `true` |

### Emergency Disable | 紧急关闭

```bash
touch ~/.claude/evolution/.disabled    # Disable instantly | 立即关闭
rm ~/.claude/evolution/.disabled       # Re-enable | 重新启用
```

## How Blocking Works | 拦截机制

When a response is blocked, Claude Code's `decision: block` prevents the AI from stopping and forces a corrected continuation:

拦截时 Claude Code 阻止 AI 停止，强制续写修正：

```
[Original response]
[Spinner: "Quality review..."]
---
[Corrected response ending with 【已修正】]
```

Safety valve: after 3 consecutive blocks in one turn, the system forces a pass to prevent infinite loops.

安全阀：同一轮连续拦截 3 次后强制放行，防止死循环。

> **Note**: The original response is streamed before the review completes. This is a Claude Code hooks architecture limitation — no pre-display hook exists. The system forces correction, not prevention.
>
> 原始回答在审查前已流式展示。这是 Claude Code hooks 架构限制——没有展示前拦截事件。系统强制修正，而非阻止展示。

## File Structure | 文件结构

```
~/.claude/
├── rules/
│   └── evolution-active.md        # Auto-generated: variant rules + instincts + correction format
├── hooks/
│   ├── on-prompt.sh               # Signal detection, minimal output (V=X)
│   ├── on-stop.sh                 # Regex + Sonnet + debate + task review
│   ├── on-post-tool.sh            # Sub-agent quality review
│   ├── on-session-start.sh        # Variant selection + rules file generation
│   ├── on-compact.sh              # Rules file refresh after compression
│   ├── on-task-completed.sh       # Completion verification
│   ├── on-tool-failure.sh         # Error awareness injection
│   └── scripts/
│       ├── find_python.sh         # Cross-platform Python auto-detection
│       ├── bg_run.py              # Cross-platform background process launcher
│       ├── instinct_manager.py    # TF-IDF behavioral rule storage & retrieval
│       ├── stats_rw.py            # Atomic variant_stats.json with file locking
│       ├── proactive_generator.py # Context-aware proactive checklist
│       ├── task_reviewer.py       # Transcript-based task quality analysis
│       └── evo_status.sh          # Status display utility
└── evolution/
    ├── config.json                # System configuration
    ├── active_variant.txt         # Currently active variant (A/B/C)
    ├── variant_stats.json         # Performance statistics per variant
    ├── session_counter.txt        # Total session count
    ├── variants/
    │   ├── A.md                   # Variant A rules (baseline)
    │   ├── B.md                   # Variant B rules (balanced)
    │   └── C.md                   # Variant C rules (proactive-focused)
    ├── instincts/
    │   └── index.json             # Learned behavioral patterns (max 50)
    └── signals/
        ├── corrections.jsonl      # Negative feedback events
        ├── approvals.jsonl        # Positive feedback events
        ├── blocks.jsonl           # Block events (regex, sonnet, debate)
        ├── sonnet_reviews.jsonl   # Sonnet review scores
        ├── task_reviews.jsonl     # Task completion verdicts
        └── missed_proactive.jsonl # Missed proactive thinking opportunities
```

## Check Status | 查看状态

```bash
bash ~/.claude/hooks/scripts/evo_status.sh
```

## Known Limitations | 已知限制

1. **No pre-display interception** — Responses stream before review. Blocked responses show original + correction.
2. **Partial context** — Sonnet sees last 3 user messages + first 2000 chars of response. May misjudge complex conversations.
3. **Soft enforcement** — Rule injection is advisory. The system raises the cost of laziness, not physically prevents it.
4. **API cost** — Each Sonnet review = 1 API call. With default config, expect 1-3 Sonnet calls per response (quality review + optional task review + optional instinct learning).
5. **Session restart required** — Rules file is generated at session start. Config changes take effect on next session.

## License

[CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/) — Free to use and modify, **no commercial use**.
