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
    let cval: String?   // 紧凑 pill 覆盖串 (余额类: 显示今日消耗而非总余额); nil=退回 value

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

// ── 迷你圆环视图：外环=5h 主窗口，内环=7d/wk；MCP 用虚线内环 ──────────────
final class MiniRingView: NSView {
    struct Arc {
        let frac: CGFloat
        let color: NSColor
        let width: CGFloat
        let inset: CGFloat
        let dashed: Bool
    }
    var arcs: [Arc] = [] { didSet { needsDisplay = true } }
    var label: String = "" { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        for a in arcs {
            let r = min(bounds.width, bounds.height) / 2 - a.inset - a.width / 2
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
            track.lineWidth = a.width
            if a.dashed {
                var dash: [CGFloat] = [1.6, 2.1]
                track.setLineDash(&dash, count: dash.count, phase: 0)
            }
            NSColor.quaternaryLabelColor.setStroke()
            track.stroke()
            guard a.frac > 0 else { continue }
            let p = NSBezierPath()
            p.appendArc(withCenter: c, radius: r, startAngle: 90,
                        endAngle: 90 - 360 * min(max(a.frac, 0), 1), clockwise: true)
            p.lineWidth = a.width
            p.lineCapStyle = .round
            if a.dashed {
                var dash: [CGFloat] = [1.6, 2.1]
                p.setLineDash(&dash, count: dash.count, phase: 0)
            }
            a.color.setStroke()
            p.stroke()
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 8, weight: .semibold),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let s = label as NSString
        let size = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: c.x - size.width / 2, y: c.y - size.height / 2), withAttributes: attrs)
    }
}

// ── 单格视图：迷你圆环 (精确数字看列表或悬停 tooltip) ───────────────────────
final class RingCell: NSView {
    private let ring = MiniRingView()
    private let popover = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 112, height: 56),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
    private let popoverLabel = NSTextField(labelWithString: "")
    private var normalLabel = ""
    private var hoverText = ""
    private var hoveringRing = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        configurePopover()
        ring.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ring)
        NSLayoutConstraint.activate([
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.widthAnchor.constraint(equalToConstant: 30),
            ring.heightAnchor.constraint(equalToConstant: 30),
            ring.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func configurePopover() {
        popover.isOpaque = false
        popover.backgroundColor = .clear
        popover.hasShadow = true
        popover.hidesOnDeactivate = false
        popover.ignoresMouseEvents = true
        popover.level = .floating

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.blendingMode = .withinWindow
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        effect.layer?.masksToBounds = true
        effect.translatesAutoresizingMaskIntoConstraints = false

        popoverLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        popoverLabel.textColor = .labelColor
        popoverLabel.alignment = .center
        popoverLabel.lineBreakMode = .byClipping
        popoverLabel.maximumNumberOfLines = 3
        popoverLabel.translatesAutoresizingMaskIntoConstraints = false

        effect.addSubview(popoverLabel)
        popover.contentView = effect
        NSLayoutConstraint.activate([
            popoverLabel.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
            popoverLabel.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 8),
            popoverLabel.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -8),
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { updateHover(event) }
    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { setRingHover(false) }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { popover.orderOut(nil) }
    }

    func apply(_ p: Provider) {
        normalLabel = shortLabel(p)
        hoverText = ""
        toolTip = "\(p.name)  \(p.value)" + (p.detail.isEmpty ? "" : " · \(p.detail)")
        guard p.ok, let w = p.wins?.first else {
            ring.arcs = [MiniRingView.Arc(frac: 0, color: .clear, width: 4, inset: 0, dashed: false)]
            ring.label = normalLabel
            return
        }
        var hoverRows = [winAbbrev(w)]
        var arcs = [MiniRingView.Arc(frac: w.pct / 100,
                                     color: p.toneColor ?? pctColor(w.pct),
                                     width: 4, inset: 0, dashed: false)]
        if let w2 = (p.wins ?? []).dropFirst().first {
            let quota = w2.label.hasPrefix("MCP")
            let color = (paceColor(w2.tone) ?? pctColor(w2.pct)).withAlphaComponent(quota ? 0.6 : 0.75)
            arcs.append(MiniRingView.Arc(frac: w2.pct / 100, color: color,
                                         width: 2.8, inset: 7, dashed: quota))
            hoverRows.append(winAbbrev(w2))
        }
        // 紧凑悬停框追加补充行 (如 Claude 的美元超额 $6.1k/20k)
        if let cv = p.cval, !cv.isEmpty { hoverRows.append(cv) }
        hoverText = hoverRows.joined(separator: "\n")
        ring.arcs = arcs
        setRingHover(hoveringRing)
    }

    private func updateHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let c = NSPoint(x: ring.frame.midX, y: ring.frame.midY)
        let r = min(ring.frame.width, ring.frame.height) / 2
        setRingHover(hypot(p.x - c.x, p.y - c.y) <= r)
    }

    private func setRingHover(_ inside: Bool) {
        hoveringRing = inside
        ring.label = normalLabel
        if inside && !hoverText.isEmpty {
            showPopover()
        } else {
            popover.orderOut(nil)
        }
    }

    private func showPopover() {
        guard let win = window else { return }
        popoverLabel.stringValue = hoverText
        let ringInWindow = ring.convert(ring.bounds, to: nil)
        let screenRect = win.convertToScreen(ringInWindow)
        var frame = popover.frame
        frame.origin.x = screenRect.midX - frame.width / 2
        frame.origin.y = screenRect.maxY + 6
        if let vis = win.screen?.visibleFrame, frame.maxY > vis.maxY {
            frame.origin.y = screenRect.minY - frame.height - 6
        }
        popover.setFrame(frame, display: true)
        popover.orderFrontRegardless()
    }

    private func winAbbrev(_ w: Win) -> String {
        "\(w.label) \(Int(round(w.pct)))%" + (w.reset.map { " /\($0)" } ?? "")
    }

    private func shortLabel(_ p: Provider) -> String {
        switch p.id {
        case "claude": "A"
        case "codex": "O"
        case "gemini": "G"
        case "glm": "Z"
        case "minimax": "M"
        case "deepseek": "D"
        default: String(p.name.prefix(1))
        }
    }
}

// ── 余额格：DeepSeek 等非百分比 provider，用 pill 表达余额而非进度 ───────────
final class BalanceCell: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.45).cgColor
        label.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ p: Provider) {
        // 余额类紧凑 pill: 有 cval (今日消耗) 优先, 否则退回总余额
        label.stringValue = "\(shortLabel(p)) \(p.cval ?? compactValue(p.value))"
        toolTip = "\(p.name)  \(p.value)" + (p.detail.isEmpty ? "" : " · \(p.detail)")
    }

    private func compactValue(_ s: String) -> String {
        if s.hasPrefix("¥"), let n = Double(s.dropFirst()) { return "¥\(Int(round(n)))" }
        return s
    }

    private func shortLabel(_ p: Provider) -> String {
        p.id == "deepseek" ? "D" : String(p.name.prefix(1))
    }
}

// ── 条状视图：第三种展示形式，粗条=5h，细条=7d/wk/MCP ───────────────────
final class BarMeterView: NSView {
    struct Lane { let frac: CGFloat; let color: NSColor; let height: CGFloat }
    var lanes: [Lane] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        var y: CGFloat = 1
        for lane in lanes.reversed() {
            let rect = NSRect(x: 3, y: y, width: bounds.width - 6, height: lane.height)
            let track = NSBezierPath(roundedRect: rect, xRadius: lane.height / 2, yRadius: lane.height / 2)
            NSColor.quaternaryLabelColor.setFill()
            track.fill()
            let fillW = max(0, rect.width * min(max(lane.frac, 0), 1))
            if fillW > 0 {
                let fill = NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY,
                                                            width: fillW, height: rect.height),
                                        xRadius: lane.height / 2, yRadius: lane.height / 2)
                lane.color.setFill()
                fill.fill()
            }
            y += lane.height + 3
        }
    }
}

final class BarCell: NSView {
    private let meter = BarMeterView()
    private let nameLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        nameLabel.font = .systemFont(ofSize: 9, weight: .medium)
        nameLabel.alignment = .center
        nameLabel.lineBreakMode = .byTruncatingTail
        for v in [meter, nameLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            meter.topAnchor.constraint(equalTo: topAnchor),
            meter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            meter.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            meter.heightAnchor.constraint(equalToConstant: 13),
            nameLabel.topAnchor.constraint(equalTo: meter.bottomAnchor, constant: 2),
            nameLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor),
            nameLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ p: Provider) {
        nameLabel.stringValue = String(p.name.prefix(3))
        nameLabel.textColor = p.ok ? .labelColor : .tertiaryLabelColor
        toolTip = "\(p.name)  \(p.value)" + (p.detail.isEmpty ? "" : " · \(p.detail)")
        guard p.ok, let w = p.wins?.first else {
            meter.lanes = [BarMeterView.Lane(frac: p.ok ? 1 : 0,
                                             color: NSColor.secondaryLabelColor.withAlphaComponent(0.45),
                                             height: 5)]
            return
        }
        var lanes = [BarMeterView.Lane(frac: w.pct / 100,
                                       color: p.toneColor ?? pctColor(w.pct),
                                       height: 5)]
        if let w2 = (p.wins ?? []).dropFirst().first {
            let quota = w2.label.hasPrefix("MCP")
            lanes.append(BarMeterView.Lane(frac: w2.pct / 100,
                                           color: (paceColor(w2.tone) ?? pctColor(w2.pct))
                                               .withAlphaComponent(quota ? 0.6 : 0.75),
                                           height: quota ? 2 : 3))
        }
        meter.lanes = lanes
    }
}

// ── 主应用 ────────────────────────────────────────────────────────────────────
final class App: NSObject, NSApplicationDelegate {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 252, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
    let stack = NSStackView()
    let listStack = NSStackView()   // 列表模式容器
    let ringStack = NSStackView()   // 圆环/条状紧凑模式容器 (4 格单行)
    let titleLabel = NSTextField(labelWithString: "AI Usage")
    let updatedLabel = NSTextField(labelWithString: "")
    var header: NSStackView!
    var hovered = false
    var headerGrewDown = false   // 本次标题栏展开是否被迫向下 (收起时按原方向回退)
    var modeBtn: NSButton!
    var configBtn: NSButton!
    var statusItem: NSStatusItem!   // 菜单栏图标: 面板隐藏后唯一的找回入口
    var rows: [String: RowView] = [:]
    var ringCells: [String: RingCell] = [:]
    var barCells: [String: BarCell] = [:]
    var balanceCells: [String: BalanceCell] = [:]
    var last: Payload?
    var isRefreshing = false   // 单飞标志: 防止定时器/↻ 重入堆积 python 子进程
    var mode = UserDefaults.standard.string(forKey: "viewMode") ?? "list"
    // providers.py 跟二进制同目录 (克隆到任意路径都能跑)
    let script = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("providers.py").path
    let contentW: CGFloat = 220   // 列表模式内容宽
    let ringCellW: CGFloat = 42   // 圆环模式单格宽
    let barCellW: CGFloat = 45    // 条状模式单格宽
    let balanceCellW: CGFloat = 64 // 余额 pill 单格宽
    let headerMinW: CGFloat = 138 // 时间 + 操作按钮的最低可用宽度
    let defaultCompactIDs = ["claude", "codex", "glm", "minimax"]
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
        if !["list", "ring", "bar"].contains(mode) { mode = "list" }
        modeBtn = NSButton(title: modeIcon(), target: self, action: #selector(toggleMode))
        modeBtn.isBordered = false
        modeBtn.font = .systemFont(ofSize: 11)
        configBtn = NSButton(title: "⚙", target: self, action: #selector(showProviderMenu))
        configBtn.isBordered = false
        configBtn.font = .systemFont(ofSize: 11)
        let refreshBtn = NSButton(title: "↻", target: self, action: #selector(doRefresh))
        refreshBtn.isBordered = false
        refreshBtn.font = .systemFont(ofSize: 11)
        let quit = NSButton(title: "✕", target: self, action: #selector(hidePanel))
        quit.isBordered = false
        quit.font = .systemFont(ofSize: 10)
        // 标题栏平时整体隐藏 (毛玻璃只包住内容), 悬停时窗口向上长出一截放标题:
        // 内容在屏幕上原地不动, 毛玻璃随窗口一起延伸, 标题文字淡入
        header = NSStackView(views: [updatedLabel, modeBtn, configBtn, refreshBtn, quit])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .gravityAreas
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

        // 菜单栏图标: ✕ 隐藏面板后, 点这个图标把面板调回来 (显隐切换)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "AI Usage")
            if btn.image == nil { btn.title = "AI" }   // 老系统无此 SF Symbol 时退回文字
            btn.image?.isTemplate = true
            btn.target = self
            btn.action = #selector(togglePanel)
            btn.toolTip = "点按显示 / 隐藏 AI Usage 面板"
        }

        refresh()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in self.refresh() }
    }

    @objc func doRefresh() { refresh() }

    // ✕ = 隐藏面板 (不再退出进程; 进程由 launchd KeepAlive=true 常驻自愈).
    // ✕ 总是在悬停展开态被点到: 先收起标题栏再隐藏, 否则 autosave 存下展开 frame,
    // 下次显示按顶边收缩会让面板每次上移一截.
    @objc func hidePanel() {
        if !header.isHidden {
            header.isHidden = true
            layoutPanel(anchorTop: false)   // 按 headerGrewDown 原方向对称回退
        }
        hovered = false   // 重置悬停态, 否则下次调回来时 hover-in 被 (inside==hovered) 吞掉, 标题栏再也展不开
        panel.orderOut(nil)
    }

    // 菜单栏图标点击: 面板可见→隐藏, 不可见→调回 (复用上次保存的位置)
    @objc func togglePanel() {
        if panel.isVisible {
            hidePanel()
        } else {
            panel.orderFrontRegardless()
        }
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
        mode = mode == "list" ? "ring" : mode == "ring" ? "bar" : "list"
        UserDefaults.standard.set(mode, forKey: "viewMode")
        modeBtn.title = modeIcon()
        if let l = last { render(l) } else { refresh() }
    }

    func modeIcon() -> String {
        mode == "list" ? "◔" : mode == "ring" ? "▤" : "☰"
    }

    @objc func showProviderMenu() {
        guard let payload = last else { return }
        let providers = compactProviders(payload, applyingSelection: false)
        let selected = Set(compactSelection())
        let menu = NSMenu()
        for p in providers {
            let item = NSMenuItem(title: p.name, action: #selector(toggleProvider(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = p.id
            item.state = selected.contains(p.id) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let reset = NSMenuItem(title: "Reset Default", action: #selector(resetProviders), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: configBtn)
        }
    }

    @objc func toggleProvider(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        guard let payload = last else { return }
        let available = compactProviders(payload, applyingSelection: false).map(\.id)
        var selected = compactSelection().filter { available.contains($0) }
        if selected.contains(id) {
            selected.removeAll { $0 == id }
        } else {
            selected.append(id)
        }
        if selected.isEmpty { selected = defaultCompactIDs.filter { available.contains($0) } }
        UserDefaults.standard.set(Array(selected.prefix(4)), forKey: "compactProviderIDs")
        render(payload)
    }

    @objc func resetProviders() {
        UserDefaults.standard.removeObject(forKey: "compactProviderIDs")
        if let payload = last { render(payload) }
    }

    func refresh() {
        // 单飞: 上次取数还没回来就别再起一个 python。否则 python 一旦变慢/卡死,
        // 60s 定时器 + ↻ 会不断在新线程上堆子进程 (24h 常驻 → 进程/线程/fd 泄漏)。
        if isRefreshing { return }
        isRefreshing = true
        updatedLabel.stringValue = "…"
        DispatchQueue.global().async {
            defer { DispatchQueue.main.async { self.isRefreshing = false } }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            p.arguments = [self.script]
            let pipe = Pipe(); p.standardOutput = pipe
            do { try p.run() } catch {
                DispatchQueue.main.async { self.updatedLabel.stringValue = "spawn err" }
                return
            }
            // 看门狗: python 卡死 (DNS/socket 挂住, urlopen 超时兜不住) 时 30s 强杀,
            // 否则本后台线程 waitUntilExit 永久阻塞。必须在阻塞读之前武装:
            // terminate → python 关闭 stdout → 下面的 readDataToEndOfFile 才会返回。
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
            // 先读后等: 若改成先 waitUntilExit, 当 python 输出 >64KB 写满管道时,
            // python 阻塞在 write、父进程阻塞在 wait → 经典管道死锁。先读到 EOF 再 wait 可避免。
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
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
        let compact = mode == "ring" || mode == "bar"
        if mode == "ring" { renderRings(payload) }
        else if mode == "bar" { renderBars(payload) }
        else { renderList(payload) }
        // NSStackView 自动把 hidden 的 arranged subview 移出布局
        listStack.isHidden = compact
        ringStack.isHidden = !compact
        layoutPanel(anchorTop: true)
    }

    // 按当前模式与标题栏显隐重算面板尺寸.
    // anchorTop=true: 顶边固定向下伸缩 (切换视图/数据更新, 历史行为);
    // anchorTop=false: 底边固定向上伸缩 (悬停标题栏, 内容在屏幕上原地不动),
    //                  上方空间不足时退回顶边固定向下展开, 收起按原方向回退
    func layoutPanel(anchorTop: Bool) {
        let compact = mode == "ring" || mode == "bar"
        let compactW = currentCompactWidth()
        let contentWidth = compact ? compactW : contentW
        let panelContentW = header.isHidden ? contentWidth : max(contentWidth, headerMinW)
        // 紧凑模式 = 单行小组件: 内容更窄, 边距收紧
        headerW.constant = panelContentW
        insets[0].constant = compact ? 8 : 12
        insets[1].constant = compact ? 12 : 16
        insets[2].constant = compact ? -12 : -16
        insets[3].constant = compact ? -8 : -12
        // 注意: 不能先 layoutIfNeeded —— 约束变化会让 AutoLayout 抢先隐式改窗口
        // 尺寸 (锚点不可控), 再读 frame 就错了, 表现为悬停一次窗口下移一截;
        // 必须 读旧 frame → fittingSize 纯测量 → 显式 setFrame → 最后布局
        var f = panel.frame
        let top = f.maxY
        let newH = stack.fittingSize.height + (compact ? 16 : 24)
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
        f.size.width = panelContentW + (compact ? 24 : 32)
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

    func compactSelection() -> [String] {
        UserDefaults.standard.stringArray(forKey: "compactProviderIDs") ?? defaultCompactIDs
    }

    func compactProviders(_ payload: Payload, applyingSelection: Bool = true) -> [Provider] {
        let available = payload.providers.filter { $0.ok || !($0.wins ?? []).isEmpty }
        guard applyingSelection else { return available }
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        let selected = compactSelection()
        let picked = selected.compactMap { byID[$0] }
        return Array((picked.isEmpty ? available : picked).prefix(4))
    }

    func currentCompactWidth() -> CGFloat {
        guard let last else { return 4 * (mode == "bar" ? barCellW : ringCellW) }
        return max(compactProviders(last).reduce(CGFloat(0)) {
            $0 + (($1.wins ?? []).isEmpty ? balanceCellW : (mode == "bar" ? barCellW : ringCellW))
        }, mode == "bar" ? barCellW : ringCellW)
    }

    func renderRings(_ payload: Payload) {
        // 单行迷你圆环: 默认取 Claude/Codex/GLM/MiniMax，可在配置菜单调整
        // 余额类 (无进度语义, 如 DeepSeek) 只在列表视图显示
        let ringable = compactProviders(payload)
        for v in ringStack.arrangedSubviews { ringStack.removeArrangedSubview(v); v.removeFromSuperview() }
        let rs = NSStackView()
        rs.orientation = .horizontal
        rs.distribution = .fill
        rs.alignment = .centerY
        rs.spacing = 0
        rs.translatesAutoresizingMaskIntoConstraints = false
        ringStack.addArrangedSubview(rs)
        rs.widthAnchor.constraint(equalToConstant: compactWidth(ringable, progressW: ringCellW)).isActive = true
        for p in ringable {
            if (p.wins ?? []).isEmpty {
                rs.addArrangedSubview(balanceCell(p))
                continue
            }
            let cell = ringCells[p.id] ?? {
                let c = RingCell()
                c.translatesAutoresizingMaskIntoConstraints = false
                c.widthAnchor.constraint(equalToConstant: ringCellW).isActive = true
                ringCells[p.id] = c
                return c
            }()
            cell.apply(p)
            rs.addArrangedSubview(cell)
        }
    }

    func renderBars(_ payload: Payload) {
        let barable = compactProviders(payload)
        for v in ringStack.arrangedSubviews { ringStack.removeArrangedSubview(v); v.removeFromSuperview() }
        let rs = NSStackView()
        rs.orientation = .horizontal
        rs.distribution = .fill
        rs.alignment = .centerY
        rs.spacing = 0
        rs.translatesAutoresizingMaskIntoConstraints = false
        ringStack.addArrangedSubview(rs)
        rs.widthAnchor.constraint(equalToConstant: compactWidth(barable, progressW: barCellW)).isActive = true
        for p in barable {
            if (p.wins ?? []).isEmpty {
                rs.addArrangedSubview(balanceCell(p))
                continue
            }
            let cell = barCells[p.id] ?? {
                let c = BarCell()
                c.translatesAutoresizingMaskIntoConstraints = false
                c.widthAnchor.constraint(equalToConstant: barCellW).isActive = true
                barCells[p.id] = c
                return c
            }()
            cell.apply(p)
            rs.addArrangedSubview(cell)
        }
    }

    func compactWidth(_ providers: [Provider], progressW: CGFloat) -> CGFloat {
        max(providers.reduce(CGFloat(0)) { $0 + (($1.wins ?? []).isEmpty ? balanceCellW : progressW) },
            progressW)
    }

    func balanceCell(_ p: Provider) -> BalanceCell {
        let cell = balanceCells[p.id] ?? {
            let c = BalanceCell()
            c.translatesAutoresizingMaskIntoConstraints = false
            c.widthAnchor.constraint(equalToConstant: balanceCellW).isActive = true
            balanceCells[p.id] = c
            return c
        }()
        cell.apply(p)
        return cell
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不占 Dock
app.run()
