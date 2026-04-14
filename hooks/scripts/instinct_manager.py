"""
Evolution Engine v2 — Instinct Manager (Embedding 版)

用 TF-IDF + 余弦相似度做语义检索，替代纯字符串匹配。
零外部模型依赖，纯 CPU 运行。

用法：
  python instinct_manager.py add --pattern "..." --category laziness --source user_correction
  python instinct_manager.py prune
  python instinct_manager.py relevant "用户的问题"
  python instinct_manager.py boost --id inst_001
"""

import json
import os
import sys
import re
from pathlib import Path

EVO_DIR = Path.home() / ".claude" / "evolution"
INSTINCTS_FILE = EVO_DIR / "instincts" / "index.json"
MAX_INSTINCTS = 50


def load_instincts():
    if not INSTINCTS_FILE.exists():
        return []
    with open(INSTINCTS_FILE, "r", encoding="utf-8") as f:
        return json.load(f)


def save_instincts(instincts):
    INSTINCTS_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = str(INSTINCTS_FILE) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(instincts, f, ensure_ascii=False, indent=2)
    os.replace(tmp, str(INSTINCTS_FILE))


def next_id(instincts):
    max_num = 0
    for inst in instincts:
        m = re.search(r'inst_(\d+)', inst.get("id", ""))
        if m:
            max_num = max(max_num, int(m.group(1)))
    return f"inst_{max_num + 1:03d}"


def tokenize_chinese(text):
    """简单的中文分字 + 英文分词"""
    tokens = []
    current_en = []
    for char in text:
        if '\u4e00' <= char <= '\u9fff':
            if current_en:
                tokens.append(''.join(current_en))
                current_en = []
            tokens.append(char)
        elif char.isalnum():
            current_en.append(char.lower())
        else:
            if current_en:
                tokens.append(''.join(current_en))
                current_en = []
    if current_en:
        tokens.append(''.join(current_en))
    # 加入双字词（bigram）提升中文检索质量
    bigrams = [text[i:i+2] for i in range(len(text)-1)
               if '\u4e00' <= text[i] <= '\u9fff' and '\u4e00' <= text[i+1] <= '\u9fff']
    return tokens + bigrams


def compute_similarity(query, documents):
    """用 TF-IDF + 余弦相似度计算语义相关性"""
    try:
        from sklearn.feature_extraction.text import TfidfVectorizer
        from sklearn.metrics.pairwise import cosine_similarity

        if not documents:
            return []

        all_texts = [query] + documents
        # 用自定义中文分词器
        vectorizer = TfidfVectorizer(
            analyzer=lambda x: tokenize_chinese(x),
            max_features=5000
        )
        tfidf_matrix = vectorizer.fit_transform(all_texts)
        similarities = cosine_similarity(tfidf_matrix[0:1], tfidf_matrix[1:])[0]
        return similarities.tolist()

    except ImportError:
        # sklearn 不可用，降级到字符串匹配
        from difflib import SequenceMatcher
        return [SequenceMatcher(None, query.lower(), doc.lower()).ratio() for doc in documents]


def add_instinct(pattern, category, source):
    instincts = load_instincts()

    # 用语义相似度检测重复
    if instincts:
        existing_patterns = [inst["pattern"] for inst in instincts]
        similarities = compute_similarity(pattern, existing_patterns)
        max_sim_idx = max(range(len(similarities)), key=lambda i: similarities[i])

        if similarities[max_sim_idx] > 0.6:
            # 语义相似，提升 evidence_count
            instincts[max_sim_idx]["evidence_count"] = instincts[max_sim_idx].get("evidence_count", 0) + 1
            save_instincts(instincts)
            print(f"SIMILAR: boosted {instincts[max_sim_idx]['id']} (sim={similarities[max_sim_idx]:.2f})")
            return

    from datetime import datetime
    new_inst = {
        "id": next_id(instincts),
        "pattern": pattern,
        "category": category,
        "source": source,
        "evidence_count": 1,
        "contradicted_count": 0,
        "created": datetime.now().strftime("%Y%m%d")
    }
    instincts.append(new_inst)

    if len(instincts) > MAX_INSTINCTS:
        instincts.sort(key=lambda x: x.get("evidence_count", 0))
        removed = instincts.pop(0)
        print(f"PRUNED: {removed['id']} (evidence={removed.get('evidence_count', 0)})")

    save_instincts(instincts)
    print(f"ADDED: {new_inst['id']} - {pattern[:50]}")


def prune_instincts():
    instincts = load_instincts()
    if len(instincts) <= MAX_INSTINCTS:
        print(f"OK: {len(instincts)}/{MAX_INSTINCTS}")
        return

    instincts.sort(key=lambda x: x.get("evidence_count", 0))
    while len(instincts) > MAX_INSTINCTS:
        removed = instincts.pop(0)
        print(f"PRUNED: {removed['id']}")

    save_instincts(instincts)


def boost_instinct(inst_id):
    instincts = load_instincts()
    for inst in instincts:
        if inst["id"] == inst_id:
            inst["evidence_count"] = inst.get("evidence_count", 0) + 1
            save_instincts(instincts)
            print(f"BOOSTED: {inst_id} to {inst['evidence_count']}")
            return
    print(f"NOT_FOUND: {inst_id}")


def relevant_instincts(query, top_n=8):
    """用 TF-IDF 语义相似度返回最相关的 Instinct"""
    instincts = load_instincts()
    if not instincts:
        print("")
        return

    patterns = [inst["pattern"] for inst in instincts]
    similarities = compute_similarity(query, patterns)

    # 综合评分：语义相似度 × 0.7 + evidence_count 权重 × 0.3
    scored = []
    for i, inst in enumerate(instincts):
        sem_sim = similarities[i] if i < len(similarities) else 0
        evidence_weight = min(inst.get("evidence_count", 1) / 10, 0.3)
        score = sem_sim * 0.7 + evidence_weight * 0.3
        scored.append((score, inst))

    scored.sort(key=lambda x: x[0], reverse=True)
    results = [inst["pattern"] for _, inst in scored[:top_n]]
    print("; ".join(results))


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: instinct_manager.py <add|prune|relevant|boost> [args]")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "add":
        import argparse
        parser = argparse.ArgumentParser()
        parser.add_argument("cmd")
        parser.add_argument("--pattern", required=True)
        parser.add_argument("--category", default="laziness")
        parser.add_argument("--source", default="auto")
        args = parser.parse_args()
        add_instinct(args.pattern, args.category, args.source)

    elif cmd == "add-file":
        # 从文件读取 pattern（安全，避免 shell 注入）
        if len(sys.argv) >= 5:
            pattern_file = sys.argv[2]
            try:
                with open(pattern_file, "r", encoding="utf-8") as f:
                    pattern = f.read().strip()
                if pattern:
                    add_instinct(pattern, sys.argv[3], sys.argv[4])
            finally:
                try:
                    os.unlink(pattern_file)
                except OSError:
                    pass
        else:
            print("Usage: instinct_manager.py add-file <pattern_file> <category> <source>")

    elif cmd == "prune":
        prune_instincts()

    elif cmd == "relevant":
        query = " ".join(sys.argv[2:]) if len(sys.argv) > 2 else ""
        relevant_instincts(query)

    elif cmd == "boost":
        if len(sys.argv) > 3 and sys.argv[2] == "--id":
            boost_instinct(sys.argv[3])
        else:
            print("Usage: instinct_manager.py boost --id inst_001")

    else:
        print(f"Unknown command: {cmd}")
        sys.exit(1)
