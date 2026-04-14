#!/usr/bin/env python3
"""
Evolution Engine v2 — 跨平台后台进程启动器
替代 nohup bash -c "..." &，在 Windows 上使用 DETACHED_PROCESS 确保子进程独立存活。

用法：
  python bg_run.py "bash -c 'echo hello'"
  python bg_run.py --shell "export PYTHONUTF8=1 && claude -p --model sonnet < /tmp/prompt.txt"
"""
import subprocess
import sys
import os


def run_detached(cmd, shell=False):
    kwargs = {
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "stdin": subprocess.DEVNULL,
    }

    if sys.platform == "win32":
        DETACHED_PROCESS = 0x00000008
        CREATE_NO_WINDOW = 0x08000000
        kwargs["creationflags"] = DETACHED_PROCESS | CREATE_NO_WINDOW
    else:
        kwargs["start_new_session"] = True

    if shell:
        kwargs["shell"] = True
        subprocess.Popen(cmd, **kwargs)
    else:
        subprocess.Popen(cmd, **kwargs)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(1)

    if sys.argv[1] == "--shell":
        run_detached(" ".join(sys.argv[2:]), shell=True)
    else:
        run_detached(sys.argv[1:])
