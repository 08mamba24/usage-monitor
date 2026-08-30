---
feature_ids: [F001]
related_features: []
topics: [windows, cross-platform, ui, ci]
doc_kind: spec
created: 2026-08-30
---

# F001: Windows 适配 — 悬浮条 + Windows CI

> Status: in-progress | Owner: 08mamba24

## Why
主力机器是 Mac,但同样的问题(哪个订阅还有余量)在 Windows 工作机上一样存在。
数据层(providers.py)本就是纯 HTTP+文件,跨平台成本集中在 UI 与 Claude 凭据两处;
选 tkinter 悬浮条方案,零第三方依赖、与数据层同进程,CI 可在真实 Windows runner 上闭环验证。

## What
- `providers.py`: 抽出 `collect()` 供 UI 直接调用; 新增 `claude_oauth()` 平台分派
  (macOS 走钥匙串, Windows/Linux 读 `~/.claude/.credentials.json`)。
- `win_monitor.py`: 简洁置顶悬浮条 — 每 provider 一格(短名 + 用量大字 + 细进度条),
  着色阈值/短名(Ant/ZAI)与 `UsageMonitor.swift` 的 `pctColor`/`notchCompactName` 对齐;
  可拖动且位置记忆、悬停看明细、右键 Refresh/Quit、5 分钟自动刷新(后台线程 + 队列回主线程)。
  tkinter 仅在 `run()` 内导入,纯逻辑部分任意平台可单测。
- `tests/test_win_monitor.py`: 着色阈值/短名/行映射/Claude 凭据分派/collect 过滤排序。
- `.github/workflows/windows.yml`: windows-latest 跑单测 + tkinter 冒烟 + 模块导入冒烟。

## Acceptance Criteria
- [x] AC-1: Windows/Linux 下 Claude 凭据从 `~/.claude/.credentials.json` 读取,缺失时该 provider 隐藏(不报错)
- [x] AC-2: 悬浮条渲染所有有凭据的 provider,短名与着色和 macOS 版一致(单测锁定)
- [x] AC-3: 交互:拖动、位置记忆、tooltip、右键菜单、自动刷新
- [x] AC-4: GitHub Actions 在真实 Windows runner 上跑全部 Python 单测并通过
- [ ] AC-5: 真实 Windows 机器人工验收(视觉/拖动/凭据拉通)— 待用户在 Windows 侧执行

## Dependencies
- Claude Code Windows 版将 OAuth 落盘为 `~/.claude/.credentials.json`(与 Linux 一致)

## Risk
- tkinter 在高 DPI 下的渲染锐度一般(已设 DPI awareness,不追求像素级与 macOS 版一致)
- `ctypes.windll` 仅 Windows 存在,其他平台静默跳过
- macOS 上 overrideredirect 窗口尺寸需显式 geometry(render 内已同时设 canvas 与窗口尺寸)

## Open Questions
- 是否需要开机自启(任务计划程序)对齐 macOS launchd 自愈?等真实使用反馈再定
