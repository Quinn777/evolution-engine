#!/bin/bash
# Evolution Engine v2 — Python 路径自动检测
# 所有 hook 脚本 source 此文件来获取 $PYTHON 变量
# 优先级：Windows 安装路径 > python3 (PATH) > python (PATH)
# 会验证找到的 Python 确实能执行（排除 Windows Store 存根）

if [ -n "$PYTHON" ] && [ -f "$PYTHON" ]; then
  # 验证已设置的 PYTHON 能工作
  "$PYTHON" -c "pass" 2>/dev/null && { return 0 2>/dev/null || exit 0; }
  PYTHON=""
fi

_test_python() {
  local p="$1"
  [ -z "$p" ] && return 1
  [ ! -f "$p" ] && return 1
  "$p" -c "pass" 2>/dev/null || return 1
  PYTHON="$p"
  return 0
}

# Windows 常见安装路径（优先，避免 WindowsApps 存根）
for ver in 313 312 311 310 39; do
  for base in "$LOCALAPPDATA/Programs/Python/Python${ver}" "$HOME/AppData/Local/Programs/Python/Python${ver}" "/c/Python${ver}"; do
    _test_python "$base/python.exe" && { return 0 2>/dev/null || exit 0; }
  done
done

# PATH 中的 python（需要验证排除存根）
for cmd in python3 python; do
  p=$(command -v "$cmd" 2>/dev/null)
  _test_python "$p" && { return 0 2>/dev/null || exit 0; }
done

PYTHON=""
