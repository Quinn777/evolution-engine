"""
Evolution Engine v2 — 主动思考清单生成器

根据用户当前问题 + 积累的 Instinct + 项目上下文，
生成"你应该额外主动想到的 3 件事"。

由 on-prompt.sh 调用，结果注入 additionalContext。
零 AI 调用成本——纯本地逻辑。
"""

import json
import sys
import os
from pathlib import Path

EVO_DIR = Path.home() / ".claude" / "evolution"
INSTINCTS_FILE = EVO_DIR / "instincts" / "index.json"
PROACTIVE_CONTEXT_FILE = EVO_DIR / "proactive_context.json"
MISSED_OPPORTUNITIES_FILE = EVO_DIR / "signals" / "missed_proactive.jsonl"

def load_json(path, default=None):
    if default is None:
        default = []
    if not path.exists():
        return default
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except:
        return default

def generate_proactive_checklist(user_question):
    """根据用户问题和积累的知识，生成主动思考清单"""

    instincts = load_json(INSTINCTS_FILE, [])
    context = load_json(PROACTIVE_CONTEXT_FILE, {})

    # 从错失的主动思考机会中学习
    missed = []
    if MISSED_OPPORTUNITIES_FILE.exists():
        try:
            with open(MISSED_OPPORTUNITIES_FILE, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            missed.append(json.loads(line))
                        except:
                            pass
        except:
            pass

    checklist = []
    q_lower = user_question.lower()

    # ============================================================
    # 规则 1：从用户纠正类 Instinct 推导主动检查项
    # ============================================================

    correction_instincts = [i for i in instincts if i.get("source") in ("user_correction", "block_rewrite")]
    if correction_instincts and len(user_question) > 3:
        # Bug#12 修复：用 TF-IDF 语义相似度替代字符集重叠
        try:
            from instinct_manager import compute_similarity
            patterns = [inst["pattern"] for inst in correction_instincts]
            similarities = compute_similarity(user_question, patterns)
            scored = sorted(zip(similarities, correction_instincts), key=lambda x: x[0], reverse=True)
            for sim, inst in scored[:2]:
                if sim > 0.15:  # 低门槛：宁可多提醒也不遗漏
                    checklist.append(f"[历史教训] {inst['pattern']}")
        except ImportError:
            # 降级：用简单的双字词重叠
            for inst in correction_instincts[:2]:
                pattern = inst["pattern"]
                bigrams_p = set(pattern[i:i+2] for i in range(len(pattern)-1))
                bigrams_q = set(user_question[i:i+2] for i in range(len(user_question)-1))
                if len(bigrams_p & bigrams_q) > 2:
                    checklist.append(f"[历史教训] {pattern}")
                    if len(checklist) >= 2:
                        break

    # ============================================================
    # 规则 2：从项目上下文推导
    # ============================================================

    project_stage = context.get("current_stage", "")
    user_priorities = context.get("priorities", [])
    known_risks = context.get("known_risks", [])
    pending_items = context.get("pending_items", [])

    if project_stage:
        checklist.append(f"[项目阶段] 当前处于{project_stage}阶段，这个回答是否需要考虑阶段约束？")

    for priority in user_priorities[:1]:
        checklist.append(f"[用户重点] 用户特别在意：{priority}，这个回答覆盖了吗？")

    for risk in known_risks[:1]:
        if any(kw in user_question for kw in risk.get("keywords", [])):
            checklist.append(f"[已知风险] {risk.get('description', '')}")

    for item in pending_items[:1]:
        checklist.append(f"[待办] 用户提过但未完成：{item}")

    # ============================================================
    # 规则 3：从错失的主动思考机会中学习
    # ============================================================

    recent_missed = missed[-5:] if missed else []
    for m in recent_missed:
        should_have = m.get("should_have_thought", "")
        if should_have and len(checklist) < 5:
            checklist.append(f"[曾错失] 类似场景你应该想到：{should_have}")

    # ============================================================
    # 规则 4：通用主动思考触发（当上面规则没有生成足够项时）
    # ============================================================

    universal_triggers = [
        "这个回答的前提假设是否成立？有没有可能假设本身就是错的？",
        "有没有比当前方案更简单、更直接的解决办法？",
        "这个问题背后，用户真正想解决的是什么？字面意思和真实需求一样吗？",
        "这个回答涉及的数字/结论，有没有需要验证的？",
        "用户接下来可能会问什么？能不能提前回答？",
        "如果要建议下一步行动，当前阶段的产出物检查完了吗？不要跳过检查直接推进。",
        "有没有因为步骤繁琐就想建议跳过的？繁琐不是跳过的理由。",
    ]

    used_triggers = {item.replace("[主动思考] ", "") for item in checklist}
    for trigger in universal_triggers:
        if len(checklist) >= 3:
            break
        if trigger not in used_triggers:
            used_triggers.add(trigger)
            checklist.append(f"[主动思考] {trigger}")

    # ============================================================
    # 规则 5：任务类型识别 + 完成标准注入（v2.2 新增）
    # 在 AI 开始做事之前就告诉它"做完"意味着什么
    # ============================================================

    task_completion = _get_task_completion_criteria(user_question)
    if task_completion:
        checklist.append(task_completion)

    return checklist[:7]  # 最多 7 条（增加了完成标准）


def _get_task_completion_criteria(question):
    """根据问题类型返回具体的完成标准，在 AI 做事之前注入"""
    q = question.lower()

    # 检查/审查/诊断型
    inspect_kw = ["检查", "审查", "查一下", "看看", "诊断", "排查", "有没有问题", "有没有bug"]
    if any(kw in q for kw in inspect_kw):
        return ("[完成标准] 这是检查型任务。做完前必须确认："
                "1)检查范围是否完整（不只查了一部分就说没问题）"
                "2)发现的每个问题都有具体证据 "
                "3)对发现的问题给出严重程度判断 "
                "4)如果说'没问题'，要说明检查了哪些方面")

    # 修复/修改/解决型
    fix_kw = ["修复", "修改", "修一下", "解决", "修好", "fix", "改一下", "处理"]
    if any(kw in q for kw in fix_kw):
        return ("[完成标准] 这是修复型任务。做完前必须确认："
                "1)修复后重新运行测试/验证，确认修复有效 "
                "2)检查修复有没有引入新问题 "
                "3)如果改了多处，每处都要验证 "
                "4)列出改了什么、为什么这么改")

    # 搭建/创建/实现型
    build_kw = ["搭建", "创建", "实现", "开发", "写一个", "做一个", "部署", "安装", "配置"]
    if any(kw in q for kw in build_kw):
        return ("[完成标准] 这是搭建型任务。做完前必须确认："
                "1)创建的东西能正常运行（要实际测试） "
                "2)边界情况和错误处理已考虑 "
                "3)依赖和配置完整 "
                "4)给出使用/验证方法")

    # 分析/方案/评估型
    analyze_kw = ["分析", "方案", "评估", "对比", "选型", "定价", "成本", "规划"]
    if any(kw in q for kw in analyze_kw):
        return ("[完成标准] 这是分析型任务。做完前必须确认："
                "1)所有关键维度都覆盖了，没有遗漏重要因素 "
                "2)每个结论有依据支撑 "
                "3)考虑了反面观点和风险 "
                "4)给出明确推荐，不是列完选项就结束")

    return None


def record_missed_opportunity(description):
    """记录一次错失的主动思考机会（由 Sonnet 审查后调用）"""
    MISSED_OPPORTUNITIES_FILE.parent.mkdir(parents=True, exist_ok=True)
    from datetime import datetime
    entry = {
        "time": datetime.now().strftime("%Y%m%d_%H%M%S"),
        "should_have_thought": description
    }
    with open(MISSED_OPPORTUNITIES_FILE, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    # 只保留最近 30 条
    try:
        lines = open(MISSED_OPPORTUNITIES_FILE, "r", encoding="utf-8").readlines()
        if len(lines) > 30:
            with open(MISSED_OPPORTUNITIES_FILE, "w", encoding="utf-8") as f:
                f.writelines(lines[-30:])
    except:
        pass
    print(f"RECORDED: {description[:50]}")


def update_context(key, value):
    """更新项目上下文"""
    ctx = load_json(PROACTIVE_CONTEXT_FILE, {})
    if key in ("priorities", "known_risks", "pending_items"):
        if key not in ctx:
            ctx[key] = []
        if isinstance(value, str) and value not in ctx[key]:
            ctx[key].append(value)
            # 保留最近 10 条
            ctx[key] = ctx[key][-10:]
    else:
        ctx[key] = value

    tmp = str(PROACTIVE_CONTEXT_FILE) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(ctx, f, ensure_ascii=False, indent=2)
    os.replace(tmp, str(PROACTIVE_CONTEXT_FILE))
    print(f"UPDATED: {key} = {str(value)[:50]}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage:")
        print("  proactive_generator.py generate \"用户的问题\"")
        print("  proactive_generator.py missed \"应该想到的内容\"")
        print("  proactive_generator.py context <key> <value>")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "generate":
        question = " ".join(sys.argv[2:]) if len(sys.argv) > 2 else ""
        items = generate_proactive_checklist(question)
        print("; ".join(items))

    elif cmd == "missed":
        desc = " ".join(sys.argv[2:]) if len(sys.argv) > 2 else ""
        if desc:
            record_missed_opportunity(desc)

    elif cmd == "context":
        if len(sys.argv) >= 4:
            update_context(sys.argv[2], " ".join(sys.argv[3:]))
        else:
            print("Usage: proactive_generator.py context <key> <value>")

    else:
        print(f"Unknown: {cmd}")
