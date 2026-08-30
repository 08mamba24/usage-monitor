#!/usr/bin/env python3
"""CI 冒烟 (windows-latest): tkinter 可创建窗口 + win_monitor 导入与行映射。

不是 unittest: 它验证的是环境能力 (runner 桌面会话 / tkinter 可用),
随 .github/workflows/windows.yml 的 smoke 步骤运行。
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import tkinter  # noqa: E402

t = tkinter.Tk()
t.destroy()
print("tkinter ok")

import win_monitor  # noqa: E402

r = win_monitor.ui_row({"id": "claude", "name": "Claude", "kind": "percent",
                        "ok": True, "pct": 12.4, "value": "5h 12%", "detail": ""})
assert r["name"] == "Ant" and r["text"] == "12%", r
print("win_monitor ok")
