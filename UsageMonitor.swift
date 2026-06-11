// usage-monitor — macOS 原生置顶悬浮窗，显示各 AI 订阅用量
// 编译: swiftc -O -o usage-monitor UsageMonitor.swift
// 数据: 定时运行 providers.py，解析其 stdout JSON
import AppKit

// ── 数据模型 ──────────────────────────────────────────────────────────────────
struct Win: Decodable {
    let label: String; let pct: Double; let reset: String?
    let tone: String?   // 本窗口的 pace 评级 (长窗口预热期/无重置时间为 nil)
    var hot: Bool { tone == "orange" || tone == "red" }
}

struct Provider: Decodable {
    let id: String, name: String, kind: String, ok: Bool
    let pct: Double?, value: String, detail: String
    let tone: String?   // 主窗口消耗速度评级: green/yellow/orange/red, nil=不评估
    let wins: [Win]?    // 结构化限额窗口 (圆环视图用): [0]=5h 主窗口, [1]=7d/wk 次窗口

    var toneColor: NSColor? { paceColor(tone) }
}
struct Payload: Decodable { let updated: String; let providers: [Provider] }

// pace 评级 → 颜色; 无评级返回 nil
func paceColor(_ tone: String?) -> NSColor? {
    switch tone {
    case "green": .systemGreen
    case "yellow": .systemYellow
    case "orange": .systemOrange
    case "red": .systemRed
    default: nil
    }
}

// 无消耗速度评级时按绝对百分比兜底配色 (列表进度条与圆环共用)
func pctColor(_ pct: Double) -> NSColor {
    pct >= 90 ? .systemRed : pct >= 70 ? .systemOrange : pct >= 50 ? .systemYellow : .systemGreen
}

// 容器: 强制箭头光标 (NSTextField 会显 I-beam) + 圆角裁切;
// 毛玻璃作为子层独立调透明度, 不影响其上的文字;
// 跟踪鼠标进出 (悬停时才显示标题栏按钮)
final class PanelBackground: NSView {
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // .inVisibleRect: 面板伸缩时跟踪区自动跟随 bounds
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
}

// ── 单行视图：名称 + 值 + 进度条/小字 ─────────────────────────────────────────
final class RowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSView()
    private let barBg = NSView()
    private var barWidth: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameLabel.font = .systemFont(ofSize: 12, weight: .medium)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueLabel.alignment = .right
        detailLabel.font = .systemFont(ofSize: 10)
        detailLabel.textColor = .tertiaryLabelColor
        barBg.wantsLayer = true; bar.wantsLayer = true
        barBg.layer?.cornerRadius = 2; bar.layer?.cornerRadius = 2
        barBg.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        for v in [nameLabel, valueLabel, detailLabel, barBg, bar] {
            v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v)
        }
        barWidth = bar.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: topAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 8),
            barBg.leadingAnchor.constraint(equalTo: leadingAnchor),
            barBg.trailingAnchor.constraint(equalTo: trailingAnchor),
            barBg.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 5),
            barBg.heightAnchor.constraint(equalToConstant: 4),
            bar.leadingAnchor.constraint(equalTo: barBg.leadingAnchor),
            bar.centerYAnchor.constraint(equalTo: barBg.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 4),
            barWidth,
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: barBg.bottomAnchor, constant: 3),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ p: Provider, totalWidth: CGFloat) {
        nameLabel.stringValue = p.name
        // 主值与倒计时分两种字体格式: 主值粗体, 倒计时小号浅色
        // 烧得快 (orange/red) 时主值文字也跟着变色
        var mainColor: NSColor = p.ok ? .labelColor : .tertiaryLabelColor
        if p.tone == "orange" || p.tone == "red", let c = p.toneColor { mainColor = c }
        if let r = p.value.range(of: " /") {
            let attr = NSMutableAttributedString()
            attr.append(NSAttributedString(string: String(p.value[..<r.lowerBound]), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: mainColor]))
            attr.append(NSAttributedString(string: String(p.value[r.lowerBound...]), attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor]))
            valueLabel.attributedStringValue = attr
        } else {
            valueLabel.stringValue = p.value
            valueLabel.textColor = mainColor
        }
        // 次行统一走 attributed 渲染 (vibrancy 下与 textColor 路径底色不同, 混用会深浅不一);
        // 次级窗口 (7d/wk) 烧得快时只点亮百分比 (染色+加粗), label 与重置时间保持灰色
        let hotWins = (p.wins ?? []).dropFirst().filter(\.hot)
        let attr = NSMutableAttributedString()
        let gray = { (s: String) in NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 10),
            .foregroundColor: NSColor.tertiaryLabelColor]) }
        for (i, seg) in p.detail.components(separatedBy: " · ").enumerated() {
            if i > 0 { attr.append(gray(" · ")) }
            let parts = seg.split(separator: " ", maxSplits: 2,
                                  omittingEmptySubsequences: false).map(String.init)
            if let w = hotWins.first(where: { seg.hasPrefix($0.label + " ") }),
               let c = paceColor(w.tone), parts.count >= 2 {
                attr.append(gray(parts[0] + " "))
                attr.append(NSAttributedString(string: parts[1], attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                    .foregroundColor: c]))
                if parts.count > 2 { attr.append(gray(" " + parts[2])) }
            } else {
                attr.append(gray(seg))
            }
        }
        detailLabel.attributedStringValue = attr
        if let pct = p.pct, p.ok {
            barBg.isHidden = false; bar.isHidden = false
            barWidth.constant = totalWidth * CGFloat(min(max(pct, 0), 100)) / 100.0
            // 优先按消耗速度配色; 无评级时退回绝对百分比阈值
            bar.layer?.backgroundColor = (p.toneColor ?? pctColor(pct)).cgColor
        } else {
            barBg.isHidden = true; bar.isHidden = true
        }
    }
}

// ── 圆环视图：同心圆弧表示消耗进度 (外环=5h 主窗口, 内环=7d/wk 次窗口) ─────────
final class RingView: NSView {
    struct Arc { let frac: CGFloat; let color: NSColor; let width: CGFloat; let inset: CGFloat }
    var arcs: [Arc] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        for a in arcs {
            let r = min(bounds.width, bounds.height) / 2 - a.inset - a.width / 2
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = a.width
            NSColor.quaternaryLabelColor.setStroke()
            track.stroke()
            guard a.frac > 0 else { continue }
            // 12 点方向起针, 顺时针走消耗量
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: r, startAngle: 90,
                        endAngle: 90 - 360 * min(a.frac, 1), clockwise: true)
            p.lineWidth = a.width
            p.lineCapStyle = .round
            a.color.setStroke()
            p.stroke()
        }
    }
}

// ── 单格视图：圆环 + 名称 (纯图形: 弧长+颜色表达, 数字看列表或悬停 tooltip) ───
final class RingCell: NSView {
    private let ring = RingView()
    private let nameLabel = NSTextField(labelWithString: "")
    static let ringSize: CGFloat = 48

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameLabel.font = .systemFont(ofSize: 10, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        for v in [ring, nameLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v)
        }
        NSLayoutConstraint.activate([
            ring.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.widthAnchor.constraint(equalToConstant: Self.ringSize),
            ring.heightAnchor.constraint(equalToConstant: Self.ringSize),
            nameLabel.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: 3),
            nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ p: Provider) {
        nameLabel.stringValue = p.name
        nameLabel.textColor = p.ok ? .labelColor : .tertiaryLabelColor
        toolTip = "\(p.name)  \(p.value)" + (p.detail.isEmpty ? "" : " · \(p.detail)")
        guard p.ok, let w = p.wins?.first else {
            // 出错的提供商: 空灰环 + 暗名字提示 (tooltip 有错误信息)
            ring.arcs = [RingView.Arc(frac: 0, color: .clear, width: 5, inset: 0)]
            return
        }
        var arcs = [RingView.Arc(frac: w.pct / 100, color: p.toneColor ?? pctColor(w.pct),
                                 width: 5, inset: 0)]
        for w2 in (p.wins ?? []).dropFirst() {
            // MCP 等配额类窗口: 更细更小的第三档环, 与时间窗口(7d/wk)区分
            let quota = w2.label.hasPrefix("MCP")
            arcs.append(RingView.Arc(frac: w2.pct / 100,
                                     color: (paceColor(w2.tone) ?? pctColor(w2.pct))
                                         .withAlphaComponent(quota ? 0.6 : 0.75),
                                     width: quota ? 2 : 3.5, inset: quota ? 13 : 8))
        }
        ring.arcs = arcs
    }
}

// ── 主应用 ────────────────────────────────────────────────────────────────────
final class App: NSObject, NSApplicationDelegate {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 252, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    let stack = NSStackView()
    let listStack = NSStackView()   // 列表模式容器
    let ringStack = NSStackView()   // 圆环模式容器 (3 列网格)
    let titleLabel = NSTextField(labelWithString: "AI Usage")
    let updatedLabel = NSTextField(labelWithString: "")
    var header: NSStackView!
    var hovered = false
    var headerGrewDown = false   // 本次标题栏展开是否被迫向下 (收起时按原方向回退)
    var modeBtn: NSButton!
    var rows: [String: RowView] = [:]
    var ringCells: [String: RingCell] = [:]
    var last: Payload?
    var mode = UserDefaults.standard.string(forKey: "viewMode") ?? "list"
    // providers.py 跟二进制同目录 (克隆到任意路径都能跑)
    let script = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("providers.py").path
    let contentW: CGFloat = 220   // 列表模式内容宽
    let ringW: CGFloat = 200      // 圆环模式内容宽 (4 cell × 50, 单行)
    var headerW: NSLayoutConstraint!
    var insets: [NSLayoutConstraint] = []   // [top, leading, trailing, bottom]

    func applicationDidFinishLaunching(_ n: Notification) {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false

        let container = PanelBackground()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.masksToBounds = true
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.alphaValue = 0.6   // 背板透明度 (只淡化毛玻璃, 文字不受影响)
        effect.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(effect)
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        panel.contentView = container

        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        updatedLabel.font = .systemFont(ofSize: 10)
        updatedLabel.textColor = .tertiaryLabelColor
        updatedLabel.alignment = .right
        modeBtn = NSButton(title: mode == "ring" ? "☰" : "◔", target: self, action: #selector(toggleMode))
        modeBtn.isBordered = false
        modeBtn.font = .systemFont(ofSize: 11)
        let refreshBtn = NSButton(title: "↻", target: self, action: #selector(doRefresh))
        refreshBtn.isBordered = false
        refreshBtn.font = .systemFont(ofSize: 11)
        let quit = NSButton(title: "✕", target: self, action: #selector(quitApp))
        quit.isBordered = false
        quit.font = .systemFont(ofSize: 10)
        // 标题栏平时整体隐藏 (毛玻璃只包住内容), 悬停时窗口向上长出一截放标题:
        // 内容在屏幕上原地不动, 毛玻璃随窗口一起延伸, 标题文字淡入
        header = NSStackView(views: [titleLabel, NSView(), updatedLabel, modeBtn, refreshBtn, quit])
        header.orientation = .horizontal
        header.isHidden = true
        header.alphaValue = 0
        container.onHover = { [weak self] inside in self?.setHovered(inside) }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(header)
        headerW = header.widthAnchor.constraint(equalToConstant: contentW)
        headerW.isActive = true

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 10
        ringStack.orientation = .vertical
        ringStack.alignment = .leading
        ringStack.spacing = 6
        for v in [listStack, ringStack] {
            v.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(v)
        }
        container.addSubview(stack)
        insets = [
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ]
        NSLayoutConstraint.activate(insets)

        // 初始位置：优先恢复上次位置 (拖动/缩放自动保存), 无记录则右上角
        if !panel.setFrameUsingName("UsageMonitor"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - 280, y: f.maxY - 12))
        }
        panel.setFrameAutosaveName("UsageMonitor")
        panel.orderFrontRegardless()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in self.refresh() }
    }

    @objc func doRefresh() { refresh() }

    // ✕ 总是在悬停展开态被点到: 先收起再退出, 否则 autosave 存下展开 frame,
    // 下次启动按顶边收缩会让面板每次重启上移一截
    @objc func quitApp() {
        if !header.isHidden {
            header.isHidden = true
            layoutPanel(anchorTop: false)   // 按 headerGrewDown 原方向对称回退
        }
        NSApp.terminate(nil)
    }

    // 悬停显隐标题栏: 窗口向上长出一截放标题 (内容原地不动, 不遮挡内容);
    // 窗口瞬时变尺寸 (无缩放动画 → 无重影), 标题文字淡入/淡出
    func setHovered(_ inside: Bool) {
        guard inside != hovered else { return }
        // 首批数据未到时面板还是恢复的旧尺寸 (空内容), 此时展开会按错误高度计算
        guard last != nil else { return }
        hovered = inside
        if inside {
            // 淡出中途重入: header 还可见、窗口仍展开着, 不能重复 layout
            // (否则等高情形会走收起分支把 headerGrewDown 清掉)
            if header.isHidden {
                header.isHidden = false
                layoutPanel(anchorTop: false)
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.header.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                self.header.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.hovered else { return }
                self.header.isHidden = true
                self.layoutPanel(anchorTop: false)
            })
        }
    }

    @objc func toggleMode() {
        mode = mode == "ring" ? "list" : "ring"
        UserDefaults.standard.set(mode, forKey: "viewMode")
        modeBtn.title = mode == "ring" ? "☰" : "◔"
        if let l = last { render(l) } else { refresh() }
    }

    func refresh() {
        updatedLabel.stringValue = "…"
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [self.script]
            let pipe = Pipe(); p.standardOutput = pipe
            try? p.run(); p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
                DispatchQueue.main.async { self.updatedLabel.stringValue = "parse err" }
                return
            }
            DispatchQueue.main.async { self.render(payload) }
        }
    }

    func render(_ payload: Payload) {
        last = payload
        updatedLabel.stringValue = payload.updated
        let ring = mode == "ring"
        if ring { renderRings(payload) } else { renderList(payload) }
        // NSStackView 自动把 hidden 的 arranged subview 移出布局
        listStack.isHidden = ring
        ringStack.isHidden = !ring
        layoutPanel(anchorTop: true)
    }

    // 按当前模式与标题栏显隐重算面板尺寸.
    // anchorTop=true: 顶边固定向下伸缩 (切换视图/数据更新, 历史行为);
    // anchorTop=false: 底边固定向上伸缩 (悬停标题栏, 内容在屏幕上原地不动),
    //                  上方空间不足时退回顶边固定向下展开, 收起按原方向回退
    func layoutPanel(anchorTop: Bool) {
        let ring = mode == "ring"
        // 圆环模式 = 单行迷你条: 内容更窄, 边距收紧
        headerW.constant = ring ? ringW : contentW
        insets[0].constant = ring ? 8 : 12
        insets[1].constant = ring ? 12 : 16
        insets[2].constant = ring ? -12 : -16
        insets[3].constant = ring ? -8 : -12
        // 注意: 不能先 layoutIfNeeded —— 约束变化会让 AutoLayout 抢先隐式改窗口
        // 尺寸 (锚点不可控), 再读 frame 就错了, 表现为悬停一次窗口下移一截;
        // 必须 读旧 frame → fittingSize 纯测量 → 显式 setFrame → 最后布局
        var f = panel.frame
        let top = f.maxY
        let newH = stack.fittingSize.height + (ring ? 16 : 24)
        var keepTop = anchorTop
        if !anchorTop {
            if newH > f.height {          // 展开: 上方放不下则向下
                let screenTop = (panel.screen ?? NSScreen.main)?.visibleFrame.maxY ?? f.maxY
                headerGrewDown = newH - f.height > screenTop - f.maxY
                keepTop = headerGrewDown
            } else if newH < f.height {   // 收起: 与展开方向对称
                keepTop = headerGrewDown
                headerGrewDown = false
            }                             // 等高 = 无操作, 保留方向标记
        }
        f.size.height = newH
        f.size.width = ring ? ringW + 24 : contentW + 32
        if keepTop { f.origin.y = top - newH }
        if let vis = (panel.screen ?? NSScreen.main)?.visibleFrame {
            // 上下都放不下时兜底: 底边别压进 Dock; 切换视图变宽时右缘不出屏
            if !anchorTop, f.origin.y < vis.minY { f.origin.y = vis.minY }
            if f.maxX > vis.maxX { f.origin.x = vis.maxX - f.width }
        }
        panel.setFrame(f, display: true)
        panel.layoutIfNeeded()
    }

    func renderList(_ payload: Payload) {
        let ids = Set(payload.providers.map { $0.id })
        for (id, r) in rows { r.isHidden = !ids.contains(id) }
        for p in payload.providers {
            let r = rows[p.id] ?? {
                let r = RowView()
                r.translatesAutoresizingMaskIntoConstraints = false
                rows[p.id] = r
                listStack.addArrangedSubview(r)
                r.widthAnchor.constraint(equalToConstant: contentW).isActive = true
                return r
            }()
            r.apply(p, totalWidth: contentW)
        }
    }

    func renderRings(_ payload: Payload) {
        // 单行迷你条: 只取优先级最高的 4 家 (claude/codex/glm/minimax);
        // 余额类 (无进度语义, 如 DeepSeek) 只在列表视图显示
        let ringable = payload.providers.filter { !($0.ok && ($0.wins ?? []).isEmpty) }.prefix(4)
        for v in ringStack.arrangedSubviews { ringStack.removeArrangedSubview(v); v.removeFromSuperview() }
        let rs = NSStackView()
        rs.orientation = .horizontal
        rs.distribution = .fillEqually
        rs.spacing = 0
        rs.translatesAutoresizingMaskIntoConstraints = false
        ringStack.addArrangedSubview(rs)
        rs.widthAnchor.constraint(equalToConstant: ringW).isActive = true
        for p in ringable {
            let cell = ringCells[p.id] ?? {
                let c = RingCell()
                c.translatesAutoresizingMaskIntoConstraints = false
                ringCells[p.id] = c
                return c
            }()
            cell.apply(p)
            rs.addArrangedSubview(cell)
        }
        while rs.arrangedSubviews.count < 4 { rs.addArrangedSubview(NSView()) }
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不占 Dock
app.run()
