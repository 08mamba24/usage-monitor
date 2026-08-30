---
feature_ids: [F002]
related_features: [F001]
topics: [windows, ui, acrylic, tauri]
doc_kind: spec
created: 2026-08-30
---

# F002: Windows 磨砂壳 — Tauri + Acrylic

> Status: idea | Owner: TBD (待 F001 AC-5 真机验收后决策)

## Why
F001 的 tkinter 悬浮条拿不到 Win11 真 Acrylic: Acrylic 由 DWM 在客户区后方合成,
要求逐像素 alpha; tkinter 是 GDI 不透明位图, `-transparentcolor` 只是全有全无的
key 色挖洞。深色纯色 + 微 alpha 是 tkinter 的上限。要 macOS vibrancy 级玻璃感
(实时模糊背后 + 噪点), 需要换壳。

## What
- Tauri 壳 + `window-vibrancy` crate: `effects: ["acrylic"]` (Win11 22H2+),
  失焦降级由系统处理。
- 数据层零改动: `providers.collect()` 原样复用 — Tauri sidecar 起
  `python3 -c "import providers, json; json.dump(providers.collect(), ...)"`
  定时拉取, 或 Rust 侧 spawn python 子进程读 stdout。
- UI 逻辑平移 `win_monitor.py` 现有纯函数: `compact` 短名 / `pct_color` 阈值 /
  `ui_row` 行映射直接照抄成 TS, 单测同契约。
- 交互对齐 F001: 拖动 + 位置记忆 + hover 明细 + 右键 Refresh/Quit + 5min 自动刷新。

## Acceptance Criteria
- [ ] AC-1: Acrylic 材质生效 (真机截图: 悬浮条背后窗口被模糊透出)
- [ ] AC-2: 数据/着色/短名与 F001 tkinter 版逐项一致 (复用现有单测契约)
- [ ] AC-3: 打包单 exe 可分发, 不要求目标机预装 Python (sidecar 打包) 或明确声明依赖
- [ ] AC-4: 非 Win11 22H2 环境降级为纯深色, 不崩

## Dependencies
- F001 AC-5 (真机验收) 结论: 若 tkinter 深色条观感已可接受, 本 feature 降级/关闭

## Risk
- Tauri/Rust 工具链引入 (构建复杂度从 "纯 Python" 升级)
- sidecar 打包体积 (~10MB 级) vs tkinter 零依赖

## Open Questions
- Electron 备选 (backgroundMaterial 更省事但体积更大) — 选型在 kickoff 时定
- 是否顺便支持 Mica 切换 (有些用户偏好不透明省电)
