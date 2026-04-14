"""
Evolution Engine v2 — 统一的 variant_stats.json 读写模块

解决的问题：
- P1: bash grep 正则不匹配 JSON 格式中的空格
- P2: Python indent=2 多行格式与 bash 单行 grep 不兼容
- P4: 三个 hook 用不同的锁保护同一文件
- P13: bash 拼接 Python 代码的路径注入风险

所有对 variant_stats.json 的操作都通过此模块，使用 O_CREAT|O_EXCL 原子文件锁。
"""

import json
import os
import sys
import time
from pathlib import Path

EVO_DIR = Path.home() / ".claude" / "evolution"
STATS_FILE = EVO_DIR / "variant_stats.json"
LOCK_FILE = EVO_DIR / ".stats_lock"

DEFAULT_STATS = {
    "A": {"sessions": 0, "blocks": 0, "corrections": 0, "approvals": 0},
    "B": {"sessions": 0, "blocks": 0, "corrections": 0, "approvals": 0},
    "C": {"sessions": 0, "blocks": 0, "corrections": 0, "approvals": 0},
}


def _acquire_lock(timeout=5):
    """跨平台文件锁（Windows 无 fcntl，用 lockfile 轮询）"""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            fd = os.open(str(LOCK_FILE), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            os.write(fd, str(os.getpid()).encode())
            os.close(fd)
            return True
        except FileExistsError:
            # 检查锁是否过期（超过 30 秒认为死锁）
            try:
                age = time.time() - os.path.getmtime(str(LOCK_FILE))
                if age > 30:
                    os.unlink(str(LOCK_FILE))
                    continue
            except OSError:
                pass
            time.sleep(0.05)
    return False


def _release_lock():
    try:
        os.unlink(str(LOCK_FILE))
    except OSError:
        pass


def load_stats():
    if not STATS_FILE.exists():
        return json.loads(json.dumps(DEFAULT_STATS))
    try:
        with open(STATS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except (json.JSONDecodeError, IOError):
        return json.loads(json.dumps(DEFAULT_STATS))


def save_stats(data):
    tmp = str(STATS_FILE) + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, str(STATS_FILE))


def read_stat(variant, field):
    """读取单个统计值"""
    data = load_stats()
    return data.get(variant, {}).get(field, 0)


def read_all():
    """读取所有统计，返回 JSON 字符串"""
    data = load_stats()
    print(json.dumps(data, ensure_ascii=False))


def increment(variant, field):
    """原子递增：加锁 → 读 → +1 → 写 → 解锁"""
    if not _acquire_lock():
        return
    try:
        data = load_stats()
        if variant in data:
            data[variant][field] = data[variant].get(field, 0) + 1
        save_stats(data)
    finally:
        _release_lock()


def breed_reset(variant):
    """繁殖后重置指定变体的统计"""
    if not _acquire_lock():
        return
    try:
        data = load_stats()
        if variant in data:
            data[variant] = {"sessions": 0, "blocks": 0, "corrections": 0, "approvals": 0}
        save_stats(data)
    finally:
        _release_lock()


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: stats_rw.py <read|read_all|increment|breed_reset> [args]")
        sys.exit(1)

    cmd = sys.argv[1]

    if cmd == "read" and len(sys.argv) >= 4:
        print(read_stat(sys.argv[2], sys.argv[3]))

    elif cmd == "read_all":
        read_all()

    elif cmd == "increment" and len(sys.argv) >= 4:
        increment(sys.argv[2], sys.argv[3])

    elif cmd == "breed_reset" and len(sys.argv) >= 3:
        breed_reset(sys.argv[2])

    else:
        print(f"Unknown: {cmd} {sys.argv[2:]}")
        sys.exit(1)
