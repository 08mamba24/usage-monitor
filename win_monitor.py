#!/usr/bin/env python3
"""usage-monitor Windows 悬浮窗 — 简洁置顶条, 复用 providers.py 数据层。

与 macOS 刘海面板的差异: Windows 没有菜单栏可用区域, 改为屏幕顶部居中的
可拖动置顶小条; 短名/着色阈值与 UsageMonitor.swift notchCompactName /
pctColor 对齐。tkinter 只在 run() 内导入, 纯逻辑部分任意平台可单测。

用法: python win_monitor.py   (需 Python 3.9+; 无第三方依赖)
"""
import json
import os
import queue
import threading
import time

import providers

REFRESH_SEC = 300
POS_FILE = os.path.join(os.path.dirname(providers.STATE), "win-pos.json")

# Apple 系统色, 与 Swift pctColor 一致 (green < 50 ≤ yellow < 70 ≤ orange < 90 ≤ red)
GREEN, YELLOW, ORANGE, RED = "#34C759", "#FFCC00", "#FF9500", "#FF3B30"
GRAY, BG, BAR_TRACK = "#98989D", "#1D1D22", "#3A3A40"


def compact(pid, name):
    """短品牌名, 对齐 UsageMonitor.swift notchCompactName。"""
    return {"claude": "Ant", "glm": "ZAI"}.get(pid, name)


def pct_color(pct):
    if pct is None:
        return GRAY
    return RED if pct >= 90 else ORANGE if pct >= 70 else YELLOW if pct >= 50 else GREEN


def ui_row(r):
    """providers row → 悬浮窗 cell: 大字 + 着色 + 进度 + tooltip 原文。"""
    if not r.get("ok"):
        return {"id": r["id"], "name": compact(r["id"], r["name"]), "text": "—",
                "pct": None, "color": GRAY,
                "tip": f"{r['name']}: {r.get('detail') or 'error'}"}
    if r.get("kind") == "percent":
        text = f"{round(r['pct'])}%"
    else:  # balance: 优先今日消耗 pill (cval), 无则总余额
        text = r.get("cval") or r.get("value") or "—"
    tip = " · ".join(p for p in (r.get("value"), r.get("detail")) if p)
    return {"id": r["id"], "name": compact(r["id"], r["name"]), "text": text,
            "pct": r.get("pct"), "color": pct_color(r.get("pct")),
            "tip": f"{r['name']}\n{tip}" if tip else r["name"]}


def ui_rows(payload):
    return [ui_row(r) for r in (payload or {}).get("providers", [])]


# ── 悬浮窗 (tkinter 仅在此以下使用) ──────────────────────────────────────────

CELL_W, CELL_H, PAD = 64, 34, 10


class FloatBar:
    """置顶深色小条: 每 provider 一格 (短名 + 用量 + 细进度条)。

    交互: 拖动移动 (位置记忆), 悬停看明细, 右键 Refresh/Quit,
    每 REFRESH_SEC 秒后台线程自动刷新。
    """

    def __init__(self, tk):
        import tkinter
        self.tk = tk
        self.rows, self.cell_rects = [], []
        self.q = queue.Queue()
        self.drag = None
        self.root = tk.Tk()
        self.root.title("usage-monitor")
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        try:  # Windows 半透明 (0=全透明不可用, 取最小可见值)
            self.root.attributes("-alpha", 0.96)
        except tkinter.TclError:
            pass
        self.canvas = tk.Canvas(self.root, highlightthickness=0, bg=BG,
                                 width=160, height=CELL_H)
        self.canvas.pack()
        self.tip = tkinter.Toplevel(self.root)
        self.tip.withdraw()
        self.tip.overrideredirect(True)
        self.tip_label = tkinter.Label(self.tip, bg="#2A2A30", fg="#E8E8EC",
                                       font=("Segoe UI", 9), justify="left",
                                       padx=8, pady=5)
        self.tip_label.pack()
        self.menu = tkinter.Menu(self.root, tearoff=0)
        self.menu.add_command(label="Refresh", command=self.refresh_now)
        self.menu.add_separator()
        self.menu.add_command(label="Quit", command=self.root.destroy)
        self._bind()
        self._place()
        self.root.after(50, self._drain)
        threading.Thread(target=self._poll, daemon=True).start()

    def _bind(self):
        c = self.canvas
        c.bind("<Button-1>", self._press)
        c.bind("<B1-Motion>", self._move)
        c.bind("<ButtonRelease-1>", self._release)
        c.bind("<Button-3>", lambda e: self.menu.tk_popup(e.x_root, e.y_root))
        c.bind("<Motion>", self._hover)
        c.bind("<Leave>", lambda e: self.tip.withdraw())

    def _place(self):
        self.root.update_idletasks()
        w = 160  # 空态占位宽; render 拿到数据后按格数加宽
        x, y = self._load_pos()
        if x is None:  # 首次: 屏幕顶部居中, 像一条伪菜单栏
            x = (self.root.winfo_screenwidth() - w) // 2
            y = 0
        self.root.geometry(f"{w}x{CELL_H}+{x}+{y}")

    @staticmethod
    def _load_pos():
        try:
            d = json.load(open(POS_FILE))
            return d.get("x"), d.get("y")
        except Exception:
            return None, None

    def _save_pos(self):
        if self.drag is None:
            return
        try:
            os.makedirs(os.path.dirname(POS_FILE), exist_ok=True)
            json.dump({"x": self.root.winfo_x(), "y": self.root.winfo_y()},
                      open(POS_FILE, "w"))
        except OSError:
            pass

    def _press(self, e):
        self.drag = (e.x_root - self.root.winfo_x(), e.y_root - self.root.winfo_y())

    def _move(self, e):
        if not self.drag:
            return
        dx, dy = self.drag
        self.root.geometry(f"+{e.x_root - dx}+{e.y_root - dy}")

    def _hover(self, e):
        for i, (x0, y0, x1, y1) in enumerate(self.cell_rects):
            if x0 <= e.x < x1 and y0 <= e.y < y1:
                self._show_tip(i, e)
                return
        self.tip.withdraw()

    def _show_tip(self, i, e):
        if i >= len(self.rows):
            return
        self.tip_label.config(text=self.rows[i]["tip"])
        self.tip.deiconify()
        self.tip.update_idletasks()
        x = min(e.x_root + 12, self.root.winfo_screenwidth()
                - self.tip.winfo_reqwidth() - 8)
        self.tip.geometry(f"+{x}+{e.y_root + 16}")

    def render(self, payload):
        self.rows = ui_rows(payload)
        c = self.canvas
        c.delete("all")
        self.cell_rects = []
        if not self.rows:
            c.create_text(PAD, CELL_H // 2, text="usage-monitor: no providers yet",
                          fill=GRAY, anchor="w", font=("Segoe UI", 9))
            return
        for i, r in enumerate(self.rows):
            x = PAD + i * CELL_W
            self.cell_rects.append((x, 0, x + CELL_W, CELL_H))
            c.create_text(x + 8, 7, text=r["name"], fill=GRAY, anchor="w",
                          font=("Segoe UI", 8))
            c.create_text(x + CELL_W - 8, 10, text=r["text"], fill=r["color"],
                          anchor="e", font=("Segoe UI", 12, "bold"))
            track_y = CELL_H - 5
            c.create_rectangle(x + 8, track_y, x + CELL_W - 8, track_y + 3,
                               fill=BAR_TRACK, width=0)
            pct = r["pct"]
            if pct is not None:  # balance 无百分比: 只留底轨
                w = (CELL_W - 16) * min(max(pct, 0), 100) / 100
                c.create_rectangle(x + 8, track_y, x + 8 + w, track_y + 3,
                                   fill=r["color"], width=0)
            if i:  # 格间分隔线
                c.create_line(x, 6, x, CELL_H - 6, fill=BAR_TRACK)
        w = PAD + len(self.rows) * CELL_W + PAD  # 数据到达后按格数加宽
        self.canvas.config(width=w)   # canvas 请求 (非 override 窗口走 pack 传播)
        self.root.geometry(f"{w}x{CELL_H}")  # override 窗口需显式设尺寸
        self.root.title(f"usage-monitor — updated {payload.get('updated', '')}")

    def _release(self, _e=None):
        if self.drag is not None:
            self.drag = None
            self._save_pos()

    # 刷新: 后台线程拉数据 → 队列 → 主线程消费渲染 (tkinter 非线程安全)

    def _fetch(self):
        try:
            self.q.put(providers.collect())
        except Exception:
            self.q.put(None)

    def _poll(self):
        while True:
            self._fetch()
            time.sleep(REFRESH_SEC)

    def refresh_now(self):
        threading.Thread(target=self._fetch, daemon=True).start()

    def _drain(self):
        try:
            while True:
                payload = self.q.get_nowait()
                if payload:
                    self.render(payload)
        except queue.Empty:
            pass
        self.root.after(200, self._drain)


def run():
    import tkinter
    try:  # Windows 高 DPI 模糊对策; 其他平台无此调用
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass
    bar = FloatBar(tkinter)
    bar.render({"updated": "", "providers": []})  # 先占位, 数据到了再填
    bar.root.mainloop()


if __name__ == "__main__":
    run()
