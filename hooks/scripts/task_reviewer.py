"""
Evolution Engine v2 -- Task Reviewer (v2.0)

v2.0 改造：从 transcript_path (JSONL) 读取完整对话历史，
不再需要 tool_use 时手动累积。classify 和 build_prompt 都从
transcript 中提取工具调用和结果。

用法：
  python task_reviewer.py classify <transcript_path>          -- 从 transcript 分类任务
  python task_reviewer.py build_prompt <transcript_path> <user_q> <response_preview>
  python task_reviewer.py record <variant> <verdict> <gaps> <tool_count>
"""

import json
import os
import sys
from pathlib import Path
from datetime import datetime

EVO_DIR = Path.home() / ".claude" / "evolution"
TASK_REVIEW_LOG = EVO_DIR / "signals" / "task_reviews.jsonl"

# 工具分类映射
TOOL_CATEGORIES = {
    "Read": "inspect",
    "Glob": "inspect",
    "Grep": "inspect",
    "Bash": "execute",
    "Edit": "modify",
    "Write": "modify",
    "WebSearch": "external",
    "WebFetch": "external",
    "ToolSearch": "meta",
    "Skill": "meta",
    "NotebookEdit": "modify",
}


def _parse_transcript(transcript_path):
    """从 transcript JSONL 文件中提取所有工具调用及其结果。

    返回列表: [{"name": str, "input_summary": str, "result_summary": str}, ...]
    """
    tools = []
    if not transcript_path or not Path(transcript_path).exists():
        return tools

    # 先收集所有 tool_use 和 tool_result，然后匹配
    tool_uses = {}  # tool_use_id -> {name, input_summary}

    try:
        with open(transcript_path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue

                # assistant 消息中的 tool_use
                if entry.get("role") == "assistant":
                    for block in entry.get("content", []):
                        if block.get("type") == "tool_use":
                            tid = block.get("id", "")
                            name = block.get("name", "unknown")
                            inp = block.get("input", {})
                            summary = _summarize_input(name, inp)
                            tool_uses[tid] = {"name": name, "input_summary": summary}
                            tools.append({
                                "name": name,
                                "input_summary": summary,
                                "result_summary": "",
                                "tool_use_id": tid,
                            })

                # user 消息中的 tool_result
                if entry.get("role") == "user":
                    for block in entry.get("content", []):
                        if block.get("type") == "tool_result":
                            tid = block.get("tool_use_id", "")
                            result_content = block.get("content", "")
                            if isinstance(result_content, list):
                                parts = []
                                for part in result_content:
                                    if isinstance(part, dict) and part.get("type") == "text":
                                        parts.append(part.get("text", ""))
                                result_content = "\n".join(parts)
                            result_str = str(result_content)[:200]
                            is_error = block.get("is_error", False)
                            if is_error:
                                result_str = "[ERROR] " + result_str
                            # 匹配回 tools 列表
                            for t in tools:
                                if t.get("tool_use_id") == tid and not t["result_summary"]:
                                    t["result_summary"] = result_str
                                    break
    except (IOError, OSError):
        pass

    return tools


def _summarize_input(tool_name, inp):
    """提取工具调用的关键信息（截断到合理长度）"""
    if tool_name == "Read":
        return inp.get("file_path", "")[:120]
    elif tool_name == "Glob":
        return inp.get("pattern", "")[:80]
    elif tool_name == "Grep":
        pattern = inp.get("pattern", "")[:60]
        path = inp.get("path", "")[:60]
        return f"pattern={pattern} path={path}"
    elif tool_name == "Bash":
        cmd = inp.get("command", "")[:150]
        return cmd
    elif tool_name == "Edit":
        fp = inp.get("file_path", "")[:100]
        old = (inp.get("old_string", "") or "")[:50]
        return f"{fp} old={old}..."
    elif tool_name == "Write":
        fp = inp.get("file_path", "")[:100]
        content_len = len(inp.get("content", ""))
        return f"{fp} ({content_len} chars)"
    elif tool_name in ("WebSearch", "WebFetch"):
        return (inp.get("query", "") or inp.get("url", ""))[:100]
    else:
        return str(inp)[:100]


def classify(transcript_path):
    """从 transcript 分类当前任务类型，返回 JSON"""
    tools = _parse_transcript(transcript_path)

    if not tools:
        print(json.dumps({"type": "no_tools", "tool_count": 0}))
        return

    # 统计工具使用情况
    tool_counts = {}
    category_counts = {"inspect": 0, "execute": 0, "modify": 0, "external": 0, "meta": 0}
    total_tools = len(tools)
    has_errors = 0

    for t in tools:
        name = t["name"]
        tool_counts[name] = tool_counts.get(name, 0) + 1
        cat = TOOL_CATEGORIES.get(name, "other")
        category_counts[cat] = category_counts.get(cat, 0) + 1
        if t.get("result_summary", "").startswith("[ERROR]"):
            has_errors += 1

    # 分类逻辑
    has_execute = category_counts["execute"] > 0
    has_modify = category_counts["modify"] > 0
    has_inspect = category_counts["inspect"] > 0
    only_inspect = has_inspect and not has_execute and not has_modify

    if total_tools >= 3 and (has_execute or has_modify):
        task_type = "action"
    elif total_tools >= 5 and only_inspect:
        task_type = "investigation"
    elif total_tools >= 2 and has_inspect:
        task_type = "light_action"
    else:
        task_type = "trivial"

    result = {
        "type": task_type,
        "tool_count": total_tools,
        "tool_counts": tool_counts,
        "category_counts": category_counts,
        "error_count": has_errors,
    }
    print(json.dumps(result, ensure_ascii=False))


def build_prompt(transcript_path, user_question, response_preview):
    """构建做事型任务的 Sonnet 审查 prompt，包含工具结果摘要"""
    tool_summary = _build_tool_summary(transcript_path)

    prompt = f"""你是"做事质量"审查员。AI 刚完成了一个工具调用密集型任务。
你的职责不是审查文字质量，而是审查：AI 做的事是否全面、是否遗漏了重要步骤。

用户要求: {user_question[:300]}

AI 使用的工具（按时间顺序，含执行结果摘要）:
{tool_summary}

AI 的最终回答摘要:
{response_preview[:1500]}

严格按以下格式回复（每行一个字段）:
THOROUGH:true或false（AI做事是否全面）
GAPS:遗漏了哪些应该做的步骤（用分号分隔，没有则写"无"）
VERIFIED:AI是否验证了自己做的事的结果（true/false）
PROACTIVE_TASKS:AI有没有主动做用户没明确要求但应该做的事（YES/NO+说明）
VERDICT:THOROUGH或INCOMPLETE或SUPERFICIAL

判定标准:
- THOROUGH: 覆盖了任务的所有合理步骤，验证了结果，主动想到了相关的事
- INCOMPLETE: 做了核心步骤但遗漏了 1-2 个重要步骤（如：修了 bug 但没测试）
- SUPERFICIAL: 明显偷懒——只做了最表面的部分，遗漏了多个重要步骤

重要：不要因为 AI 做的步骤少就判 SUPERFICIAL。关键是看任务本身需要多少步骤。
如果任务只需要 2 步而 AI 做了 2 步，那就是 THOROUGH。
但如果任务需要 10 步而 AI 只做了 3 步就说"完成了"，那是 SUPERFICIAL。"""

    print(prompt)


def _build_tool_summary(transcript_path):
    """从 transcript 构建可读的工具调用摘要（含结果）"""
    tools = _parse_transcript(transcript_path)

    if not tools:
        return "(无工具调用记录)"

    lines = []
    for step, t in enumerate(tools, 1):
        name = t["name"]
        inp_summary = t.get("input_summary", "")
        result_summary = t.get("result_summary", "")

        if len(inp_summary) > 120:
            inp_summary = inp_summary[:117] + "..."
        if len(result_summary) > 120:
            result_summary = result_summary[:117] + "..."

        line = f"  {step}. [{name}] {inp_summary}"
        if result_summary:
            line += f"\n      -> {result_summary}"
        lines.append(line)

    # 如果步骤太多，只保留前15和后5，中间摘要
    if len(lines) > 25:
        kept = lines[:15] + [f"  ... (省略 {len(lines) - 20} 步) ..."] + lines[-5:]
        lines = kept

    return "\n".join(lines) if lines else "(无工具调用记录)"


def record_review(variant, verdict, gaps, tool_count):
    """记录做事型审查结果"""
    TASK_REVIEW_LOG.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        "time": datetime.now().strftime("%Y%m%d_%H%M%S"),
        "variant": variant,
        "verdict": verdict,
        "gaps": gaps,
        "tool_count": tool_count,
    }
    with open(TASK_REVIEW_LOG, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    # 只保留最近 100 条
    try:
        all_lines = open(TASK_REVIEW_LOG, "r", encoding="utf-8").readlines()
        if len(all_lines) > 100:
            with open(TASK_REVIEW_LOG, "w", encoding="utf-8") as f:
                f.writelines(all_lines[-100:])
    except IOError:
        pass


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage:")
        print("  task_reviewer.py classify <transcript_path>")
        print("  task_reviewer.py build_prompt <transcript_path> <user_q> <response_preview>")
        print("  task_reviewer.py record <variant> <verdict> <gaps> <tool_count>")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "classify":
        tp = sys.argv[2] if len(sys.argv) > 2 else ""
        classify(tp)

    elif cmd == "build_prompt":
        tp = sys.argv[2] if len(sys.argv) > 2 else ""
        user_q = sys.argv[3] if len(sys.argv) > 3 else ""
        preview = sys.argv[4] if len(sys.argv) > 4 else ""
        build_prompt(tp, user_q, preview)

    elif cmd == "record":
        if len(sys.argv) >= 6:
            record_review(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]))
        else:
            print("Usage: task_reviewer.py record <variant> <verdict> <gaps> <tool_count>")

    else:
        print(f"Unknown: {cmd}")
        sys.exit(1)
