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

struct UsageSample: Codable {
    let timestamp: TimeInterval
    let percentages: [String: Double]
}

struct NotchInspiration {
    let pattern: String
    let theme: String
    let phrase: String
    let credit: String
}

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
            .font: NSFont.systemFont(ofSize: 6.5, weight: .semibold),
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
    var showsPopover = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        configurePopover()
        ring.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ring)
        NSLayoutConstraint.activate([
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.centerXAnchor.constraint(equalTo: centerXAnchor),
            ring.widthAnchor.constraint(equalToConstant: 22),
            ring.heightAnchor.constraint(equalToConstant: 22),
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
            ring.arcs = [MiniRingView.Arc(frac: 0, color: .clear, width: 3.2, inset: 0, dashed: false)]
            ring.label = normalLabel
            return
        }
        var hoverRows = [winAbbrev(w)]
        var arcs = [MiniRingView.Arc(frac: w.pct / 100,
                                     color: p.toneColor ?? pctColor(w.pct),
                                     width: 3.2, inset: 0, dashed: false)]
        if let w2 = (p.wins ?? []).dropFirst().first {
            let quota = w2.label.hasPrefix("MCP")
            let color = (paceColor(w2.tone) ?? pctColor(w2.pct)).withAlphaComponent(quota ? 0.6 : 0.75)
            arcs.append(MiniRingView.Arc(frac: w2.pct / 100, color: color,
                                         width: 2, inset: 5.5, dashed: quota))
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
        if showsPopover && inside && !hoverText.isEmpty {
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

// ── 刘海展开态微报告：利用刘海左右空间显示近期趋势，不重复下方当前值 ─────
final class NotchInsightCell: NSView {
    private let headline = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint!
    private var headlineTop: NSLayoutConstraint!
    private var headlineCenterY: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        headline.font = .monospacedDigitSystemFont(ofSize: 8.5, weight: .semibold)
        headline.textColor = .labelColor
        headline.alignment = .center
        headline.lineBreakMode = .byTruncatingTail
        caption.font = .systemFont(ofSize: 6.5, weight: .medium)
        caption.textColor = .tertiaryLabelColor
        caption.alignment = .center
        caption.lineBreakMode = .byTruncatingTail
        for label in [headline, caption] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        widthConstraint = widthAnchor.constraint(equalToConstant: 60)
        headlineTop = headline.topAnchor.constraint(equalTo: topAnchor, constant: 1)
        headlineCenterY = headline.centerYAnchor.constraint(equalTo: centerYAnchor)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: 22),
            headlineTop,
            headline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            headline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            caption.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: -1),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(title: String, subtitle: String, width: CGFloat, accent: NSColor? = nil) {
        let singleLine = subtitle.isEmpty
        headline.stringValue = title
        caption.stringValue = subtitle
        caption.isHidden = singleLine
        headlineTop.isActive = !singleLine
        headlineCenterY.isActive = singleLine
        headline.font = .monospacedDigitSystemFont(
            ofSize: singleLine ? 10.5 : 8.5, weight: .semibold)
        widthConstraint.constant = max(36, width)
        headline.textColor = accent ?? .labelColor
        toolTip = singleLine ? title : "\(title) · \(subtitle)"
    }
}

// 空旷展开态使用整块面板承载名言，避免把完整句子挤进刘海单侧。
final class NotchHeroQuoteView: NSView {
    private let phrase = NSTextField(labelWithString: "")
    private let credit = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint!
    private var heightConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        phrase.font = .systemFont(ofSize: 14, weight: .semibold)
        phrase.textColor = .labelColor
        phrase.alignment = .center
        phrase.lineBreakMode = .byTruncatingTail
        credit.font = .systemFont(ofSize: 8, weight: .medium)
        credit.textColor = NSColor.secondaryLabelColor.withAlphaComponent(0.82)
        credit.alignment = .center
        for label in [phrase, credit] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        widthConstraint = widthAnchor.constraint(equalToConstant: 260)
        heightConstraint = heightAnchor.constraint(equalToConstant: 38)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightConstraint,
            phrase.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            phrase.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            phrase.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            credit.topAnchor.constraint(equalTo: phrase.bottomAnchor, constant: 1),
            credit.centerXAnchor.constraint(equalTo: centerXAnchor),
            credit.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -3),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ inspiration: NotchInspiration, width: CGFloat) {
        let length = inspiration.phrase.replacingOccurrences(of: " ", with: "").count
        let fontSize: CGFloat
        switch length {
        case ...4: fontSize = 20
        case 5...7: fontSize = 18
        case 8...11: fontSize = 16
        default: fontSize = 14
        }
        apply(title: inspiration.phrase, subtitle: inspiration.credit,
              width: width, fontSize: fontSize)
    }

    func apply(title: String, subtitle: String, width: CGFloat, fontSize: CGFloat = 14) {
        phrase.stringValue = title
        credit.stringValue = subtitle
        phrase.font = .systemFont(ofSize: fontSize, weight: .semibold)
        widthConstraint.constant = width
        heightConstraint.constant = fontSize >= 19 ? 44 : (fontSize >= 17 ? 42 : 38)
        toolTip = "\(title) · \(subtitle)"
    }
}

// ── 刘海展开态卡片：2×2 紧凑仪表盘，避免沿用列表模式造成纵向过长 ─────────
final class NotchDetailCell: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let primaryTrack = NSView()
    private let primaryFill = NSView()
    private let secondaryTrack = NSView()
    private let secondaryFill = NSView()
    private var cellWidth: NSLayoutConstraint!
    private var primaryTrackWidth: NSLayoutConstraint!
    private var secondaryTrackWidth: NSLayoutConstraint!
    private var primaryWidth: NSLayoutConstraint!
    private var secondaryWidth: NSLayoutConstraint!
    private var valueNameGap: NSLayoutConstraint!
    private var valueNormalCenterY: NSLayoutConstraint!
    private var valueBalanceLeading: NSLayoutConstraint!
    private var valueBalanceCenterY: NSLayoutConstraint!
    private var valueDetailBaseline: NSLayoutConstraint!
    private var meterW: CGFloat = 96

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        nameLabel.font = .systemFont(ofSize: 9.5, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 7.5)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail

        for track in [primaryTrack, secondaryTrack] {
            track.wantsLayer = true
            track.layer?.cornerRadius = 1.5
            track.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
        }
        for fill in [primaryFill, secondaryFill] {
            fill.wantsLayer = true
            fill.layer?.cornerRadius = 1.5
        }
        for v in [nameLabel, valueLabel, detailLabel, primaryTrack, primaryFill,
                  secondaryTrack, secondaryFill] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }

        cellWidth = widthAnchor.constraint(equalToConstant: 112)
        primaryTrackWidth = primaryTrack.widthAnchor.constraint(equalToConstant: meterW)
        secondaryTrackWidth = secondaryTrack.widthAnchor.constraint(equalToConstant: meterW)
        primaryWidth = primaryFill.widthAnchor.constraint(equalToConstant: 0)
        secondaryWidth = secondaryFill.widthAnchor.constraint(equalToConstant: 0)
        valueNameGap = valueLabel.leadingAnchor.constraint(
            greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 5)
        valueNormalCenterY = valueLabel.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor)
        valueBalanceLeading = valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8)
        valueBalanceCenterY = valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        valueDetailBaseline = valueLabel.centerYAnchor.constraint(equalTo: detailLabel.centerYAnchor)
        NSLayoutConstraint.activate([
            cellWidth,
            heightAnchor.constraint(equalToConstant: 46),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            valueNormalCenterY,
            valueNameGap,
            primaryTrack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            primaryTrack.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            primaryTrackWidth,
            primaryTrack.heightAnchor.constraint(equalToConstant: 3),
            primaryFill.leadingAnchor.constraint(equalTo: primaryTrack.leadingAnchor),
            primaryFill.centerYAnchor.constraint(equalTo: primaryTrack.centerYAnchor),
            primaryFill.heightAnchor.constraint(equalToConstant: 3),
            primaryWidth,
            secondaryTrack.leadingAnchor.constraint(equalTo: primaryTrack.leadingAnchor),
            secondaryTrack.topAnchor.constraint(equalTo: primaryTrack.bottomAnchor, constant: 3),
            secondaryTrackWidth,
            secondaryTrack.heightAnchor.constraint(equalToConstant: 2),
            secondaryFill.leadingAnchor.constraint(equalTo: secondaryTrack.leadingAnchor),
            secondaryFill.centerYAnchor.constraint(equalTo: secondaryTrack.centerYAnchor),
            secondaryFill.heightAnchor.constraint(equalToConstant: 2),
            secondaryWidth,
            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ p: Provider, width: CGFloat, balanceOnly: Bool) {
        cellWidth.constant = width
        meterW = max(0, width - 16)
        primaryTrackWidth.constant = meterW
        secondaryTrackWidth.constant = meterW
        let compactBalanceDetail = p.detail
            .components(separatedBy: " · ").first?
            .replacingOccurrences(of: "today ", with: "") ?? ""
        nameLabel.stringValue = p.name
        nameLabel.font = .systemFont(
            ofSize: balanceOnly ? 8.5 : 9.5, weight: .semibold)
        valueLabel.stringValue = p.value
        detailLabel.stringValue = balanceOnly
            ? compactBalanceDetail
            : (p.detail.components(separatedBy: " · ").first ?? "")
        toolTip = "\(p.name)  \(p.value)" + (p.detail.isEmpty ? "" : " · \(p.detail)")

        nameLabel.isHidden = false
        detailLabel.isHidden = balanceOnly && compactBalanceDetail.isEmpty
        detailLabel.alignment = balanceOnly ? .right : .left
        detailLabel.textColor = balanceOnly ? .secondaryLabelColor : .tertiaryLabelColor
        primaryTrack.isHidden = balanceOnly
        primaryFill.isHidden = balanceOnly
        valueLabel.alignment = balanceOnly ? .left : .right
        valueLabel.font = .monospacedDigitSystemFont(
            ofSize: balanceOnly ? 9.5 : 9, weight: .semibold)
        if balanceOnly {
            valueBalanceLeading.isActive = true
            valueDetailBaseline.isActive = true
            valueBalanceCenterY.isActive = false
            valueNameGap.isActive = false
            valueNormalCenterY.isActive = false
            secondaryTrack.isHidden = true
            secondaryFill.isHidden = true
            primaryWidth.constant = 0
            secondaryWidth.constant = 0
            return
        }
        valueBalanceLeading.isActive = false
        valueBalanceCenterY.isActive = false
        valueDetailBaseline.isActive = false
        valueNameGap.isActive = true
        valueNormalCenterY.isActive = true

        guard p.ok, let main = p.wins?.first else {
            primaryTrack.isHidden = false
            primaryFill.isHidden = false
            primaryWidth.constant = 0
            secondaryWidth.constant = 0
            primaryFill.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            secondaryTrack.isHidden = true
            secondaryFill.isHidden = true
            return
        }
        primaryTrack.isHidden = false
        primaryFill.isHidden = false
        primaryWidth.constant = meterW * CGFloat(min(max(main.pct, 0), 100)) / 100
        primaryFill.layer?.backgroundColor = (paceColor(main.tone) ?? pctColor(main.pct)).cgColor
        if let secondary = p.wins?.dropFirst().first {
            secondaryTrack.isHidden = false
            secondaryFill.isHidden = false
            secondaryWidth.constant = meterW * CGFloat(min(max(secondary.pct, 0), 100)) / 100
            secondaryFill.layer?.backgroundColor =
                (paceColor(secondary.tone) ?? pctColor(secondary.pct)).withAlphaComponent(0.72).cgColor
        } else {
            secondaryTrack.isHidden = true
            secondaryFill.isHidden = true
            secondaryWidth.constant = 0
        }
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
    let notchLeftPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 78, height: 30),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
    let notchRightPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 78, height: 30),
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
    let notchBackdropPanel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 30),
                                     styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
    let notchLeftStack = NSStackView()
    let notchRightStack = NSStackView()
    let notchLeftInsight = NotchInsightCell()
    let notchHeroQuote = NotchHeroQuoteView()
    let stack = NSStackView()
    let listStack = NSStackView()   // 列表模式容器
    let ringStack = NSStackView()   // 圆环/条状紧凑模式容器 (4 格单行)
    let notchDetailStack = NSStackView() // 刘海展开态 2×2 仪表盘
    let titleLabel = NSTextField(labelWithString: "AI Usage")
    let updatedLabel = NSTextField(labelWithString: "")
    var header: NSStackView!
    var hovered = false
    var headerGrewDown = false   // 本次标题栏展开是否被迫向下 (收起时按原方向回退)
    var modeBtn: NSButton!
    var configBtn: NSButton!
    var notchRefreshBtn: NSButton!
    var notchConfigBtn: NSButton!
    var notchHideBtn: NSButton!
    var statusItem: NSStatusItem!   // 菜单栏图标: 面板隐藏后唯一的找回入口
    var rows: [String: RowView] = [:]
    var ringCells: [String: RingCell] = [:]
    var barCells: [String: BarCell] = [:]
    var balanceCells: [String: BalanceCell] = [:]
    var notchDetailCells: [String: NotchDetailCell] = [:]
    var last: Payload?
    var lastGood: [String: Provider] = [:]   // 每家最近一次成功数据 (取数失败时兜底)
    var staleIDs = Set<String>()              // 本轮取数失败、靠缓存兜底的 provider (渲染变灰)
    var usageHistory: [UsageSample] = []
    let usageHistoryKey = "notchUsageHistoryV1"
    var expandedWingShowsInspiration = true
    var inspirationIndex = 0
    let notchInspirations = [
        NotchInspiration(pattern: "✦  ·  ✦", theme: "保持好奇",
                         phrase: "求知若饥", credit: "Jobs · Stanford"),
        NotchInspiration(pattern: "◉  ◌  ◉", theme: "换个视角",
                         phrase: "第一性原理", credit: "Musk · 思考法"),
        NotchInspiration(pattern: "▰  ▱  ▰", theme: "主动创造",
                         phrase: "创造未来", credit: "Alan Kay"),
        NotchInspiration(pattern: "⌁  ✦  ⌁", theme: "保持专注",
                         phrase: "少而更好", credit: "Dieter Rams"),
    ]
    var isRefreshing = false   // 单飞标志: 防止定时器/↻ 重入堆积 python 子进程
    var mode = UserDefaults.standard.string(forKey: "viewMode") ?? "list"
    // providers.py 跟二进制同目录 (克隆到任意路径都能跑)
    let script = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().appendingPathComponent("providers.py").path
    let contentW: CGFloat = 220   // 列表模式内容宽
    let ringCellW: CGFloat = 34   // 刘海旁圆环单格宽
    let barCellW: CGFloat = 45    // 条状模式单格宽
    let balanceCellW: CGFloat = 64 // 余额 pill 单格宽
    let notchDetailCellW: CGFloat = 112
    let notchBalanceDetailW: CGFloat = 96
    let notchBackdropBleed: CGFloat = 2
    let notchWingInset: CGFloat = 3
    let headerMinW: CGFloat = 138 // 时间 + 操作按钮的最低可用宽度
    let defaultCompactIDs = ["claude", "codex", "glm", "minimax"]
    var headerW: NSLayoutConstraint!
    var insets: [NSLayoutConstraint] = []   // [top, leading, trailing, bottom]
    var snappingToNotch = false
    var notchExpanded = false
    var notchUIVisible = true
    var notchCollapseWork: DispatchWorkItem?

    // 刘海左右两侧是 macOS 明确暴露的可用区域。优先使用内建屏幕的右侧区域，
    // 没有刘海（外接显示器）时返回 nil，继续沿用普通悬浮窗行为。
    func notchTarget() -> (screen: NSScreen, leftArea: NSRect, rightArea: NSRect)? {
        var ordered = NSScreen.screens
        if let main = NSScreen.main {
            ordered.removeAll { $0 === main }
            ordered.insert(main, at: 0)
        }
        for screen in ordered {
            if let left = screen.auxiliaryTopLeftArea,
               let right = screen.auxiliaryTopRightArea,
               !left.isEmpty, !right.isEmpty, screen.safeAreaInsets.top > 0 {
                return (screen, left, right)
            }
        }
        return nil
    }

    var isNotchPinned: Bool { notchTarget() != nil }

    func applicationDidFinishLaunching(_ n: Notification) {
        loadUsageHistory()
        panel.level = isNotchPinned ? .statusBar : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovableByWindowBackground = !isNotchPinned
        panel.hidesOnDeactivate = false
        panel.hasShadow = !isNotchPinned
        configureNotchPanels()

        let container = PanelBackground()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        if isNotchPinned {
            container.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        }
        container.layer?.borderWidth = isNotchPinned ? 0 : 0.5
        container.layer?.borderColor = isNotchPinned ? nil : NSColor.separatorColor.cgColor
        if isNotchPinned {
            panel.appearance = NSAppearance(named: .darkAqua)
        }
        container.layer?.masksToBounds = true
        let effect = NSVisualEffectView()
        effect.material = isNotchPinned ? .menu : .hudWindow
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.alphaValue = isNotchPinned ? 1.0 : 0.6
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
        // 刘海模式的静止态固定使用双翼圆环，展开态固定显示完整列表。
        if isNotchPinned {
            mode = "list"
        }
        modeBtn = NSButton(title: modeIcon(), target: self, action: #selector(toggleMode))
        modeBtn.isBordered = false
        modeBtn.font = .systemFont(ofSize: 11)
        modeBtn.isHidden = isNotchPinned
        configBtn = NSButton(title: "⚙", target: self, action: #selector(showProviderMenu))
        configBtn.isBordered = false
        configBtn.font = .systemFont(ofSize: 11)
        let refreshBtn = NSButton(title: "↻", target: self, action: #selector(doRefresh))
        refreshBtn.isBordered = false
        refreshBtn.font = .systemFont(ofSize: 11)
        let quit = NSButton(title: "✕", target: self, action: #selector(hidePanel))
        quit.isBordered = false
        quit.font = .systemFont(ofSize: 10)
        notchRefreshBtn = notchToolbarButton(
            "↻", action: #selector(doRefresh), toolTip: "立即刷新")
        notchConfigBtn = notchToolbarButton(
            "⚙", action: #selector(showProviderMenu), toolTip: "选择显示来源")
        notchHideBtn = notchToolbarButton(
            "×", action: #selector(hidePanel), toolTip: "隐藏监控")
        // 标题栏平时整体隐藏 (毛玻璃只包住内容), 悬停时窗口向上长出一截放标题:
        // 内容在屏幕上原地不动, 毛玻璃随窗口一起延伸, 标题文字淡入
        header = NSStackView(views: [updatedLabel, modeBtn, configBtn, refreshBtn, quit])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .gravityAreas
        header.isHidden = true
        header.alphaValue = 0
        container.onHover = { [weak self] inside in
            guard let self else { return }
            if self.isNotchPinned { self.notchHoverChanged(inside) }
            else { self.setHovered(inside) }
        }

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
        notchDetailStack.orientation = .vertical
        notchDetailStack.alignment = .leading
        notchDetailStack.spacing = 0
        notchDetailStack.isHidden = true
        for v in [listStack, ringStack, notchDetailStack] {
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

        // 刘海屏由系统安全区决定位置；普通屏幕才恢复用户拖动的位置。
        if isNotchPinned {
            snapPanelToNotch()
        } else if !panel.setFrameUsingName("UsageMonitor"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - 280, y: f.maxY - 12))
        }
        // 不用 setFrameAutosaveName: 它会把悬停展开的高 frame 也自动存盘,
        // kickstart/被杀时若正展开就存下展开态 → 重启后折叠面板逐次上移。
        // 改为只在折叠态手动存盘 (panelMoved), 展开态绝不持久化。
        NotificationCenter.default.addObserver(self, selector: #selector(panelMoved),
                                               name: NSWindow.didMoveNotification, object: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        if isNotchPinned {
            panel.orderOut(nil)
            updateNotchWingVisibility()
        } else {
            panel.orderFrontRegardless()
        }

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
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func notchToolbarButton(_ title: String, action: Selector, toolTip: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = .systemFont(ofSize: 10, weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = toolTip
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return button
    }

    @objc func doRefresh() { refresh() }

    // ✕ = 隐藏面板 (不再退出进程; 进程由 launchd KeepAlive=true 常驻自愈).
    // 先收起标题栏再隐藏: 收起的重排会触发 panelMoved 存下折叠态位置,
    // 保证下次调回来是折叠态、位置不漂移.
    @objc func hidePanel() {
        notchUIVisible = false
        notchExpanded = false
        notchCollapseWork?.cancel()
        if let last { renderNotchWings(last) }
        notchLeftStack.alphaValue = 1
        notchRightStack.alphaValue = 1
        if !header.isHidden {
            header.isHidden = true
            layoutPanel(anchorTop: false)   // 按 headerGrewDown 原方向对称回退
        }
        hovered = false   // 重置悬停态, 否则下次调回来时 hover-in 被 (inside==hovered) 吞掉, 标题栏再也展不开
        notchBackdropPanel.orderOut(nil)
        notchLeftPanel.orderOut(nil)
        notchRightPanel.orderOut(nil)
        panel.orderOut(nil)
    }

    // 菜单栏图标点击: 面板可见→隐藏, 不可见→调回 (复用上次保存的位置)
    @objc func togglePanel() {
        if isNotchPinned {
            if notchUIVisible {
                hidePanel()
            } else {
                notchUIVisible = true
                snapPanelToNotch()
                updateNotchWingVisibility()
            }
            return
        }
        if panel.isVisible {
            hidePanel()
        } else {
            snapPanelToNotch()
            panel.orderFrontRegardless()
        }
    }

    // 面板移动时存盘, 但只在折叠态: 拖动(折叠态)、数据刷新/收起的重排都会落到这里;
    // 悬停展开态 (header 可见) 时跳过, 保证持久化的永远是折叠 frame → 杜绝重启上移.
    @objc func panelMoved() {
        if snappingToNotch || isNotchPinned { return }
        if header != nil, header.isHidden { panel.saveFrame(usingName: "UsageMonitor") }
    }

    @objc func screenParametersChanged() {
        panel.level = isNotchPinned ? .statusBar : .floating
        panel.isMovableByWindowBackground = !isNotchPinned
        notchBackdropPanel.level = isNotchPinned ? .statusBar : .floating
        notchLeftPanel.level = isNotchPinned ? .statusBar : .floating
        notchRightPanel.level = isNotchPinned ? .statusBar : .floating
        snapPanelToNotch()
        updateNotchWingVisibility()
    }

    func configureNotchPanels() {
        notchBackdropPanel.level = .statusBar
        notchBackdropPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        notchBackdropPanel.isOpaque = false
        notchBackdropPanel.backgroundColor = .clear
        notchBackdropPanel.isMovableByWindowBackground = false
        notchBackdropPanel.hidesOnDeactivate = false
        notchBackdropPanel.hasShadow = false
        notchBackdropPanel.ignoresMouseEvents = true
        let backdrop = NSView()
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor.black.cgColor
        backdrop.layer?.masksToBounds = true
        notchBackdropPanel.contentView = backdrop

        configureNotchWing(notchLeftPanel, stack: notchLeftStack, isLeft: true)
        configureNotchWing(notchRightPanel, stack: notchRightStack, isLeft: false)
    }

    func configureNotchWing(_ wingPanel: NSPanel, stack wingStack: NSStackView, isLeft: Bool) {
        wingPanel.level = .statusBar
        wingPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        wingPanel.isOpaque = false
        wingPanel.backgroundColor = .clear
        wingPanel.isMovableByWindowBackground = false
        wingPanel.hidesOnDeactivate = false
        wingPanel.hasShadow = false
        wingPanel.appearance = NSAppearance(named: .darkAqua)

        let wing = PanelBackground()
        wing.wantsLayer = true
        wing.layer?.cornerRadius = 8
        wing.layer?.masksToBounds = true
        wing.onHover = { [weak self] inside in self?.notchHoverChanged(inside) }
        wingPanel.contentView = wing

        let effect = NSVisualEffectView()
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        effect.material = .menu
        effect.state = .active
        effect.blendingMode = .behindWindow
        effect.translatesAutoresizingMaskIntoConstraints = false
        wing.addSubview(effect)
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: wing.topAnchor),
            effect.bottomAnchor.constraint(equalTo: wing.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: wing.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: wing.trailingAnchor),
        ])

        wingStack.orientation = .horizontal
        wingStack.alignment = .centerY
        wingStack.distribution = .fill
        wingStack.spacing = 0
        wingStack.translatesAutoresizingMaskIntoConstraints = false
        wing.addSubview(wingStack)
        NSLayoutConstraint.activate([
            wingStack.topAnchor.constraint(equalTo: wing.topAnchor, constant: 2),
            wingStack.leadingAnchor.constraint(equalTo: wing.leadingAnchor, constant: 5),
            wingStack.trailingAnchor.constraint(equalTo: wing.trailingAnchor, constant: -5),
            wingStack.bottomAnchor.constraint(equalTo: wing.bottomAnchor, constant: -2),
        ])
    }

    // 静止态两个黑色双翼贴住硬件刘海，展开面板则居中接在刘海下缘。
    // 独立底板始终比前景轮廓略大，展开时延伸到内容面板底部，
    // 用纯黑底色吃掉多个无边框窗口之间可能出现的 1px 合成缝。
    func snapPanelToNotch() {
        guard let target = notchTarget() else { return }
        let seamOverlap: CGFloat = 2
        snappingToNotch = true

        var lf = notchLeftPanel.frame
        lf.size.height = target.leftArea.height - notchWingInset * 2
        lf.origin.x = target.leftArea.maxX - lf.width + seamOverlap
        lf.origin.y = target.leftArea.minY + notchWingInset
        if lf.minX < target.leftArea.minX {
            lf.size.width = target.leftArea.width
            lf.origin.x = target.leftArea.minX
        }
        notchLeftPanel.setFrame(lf, display: true)

        var rf = notchRightPanel.frame
        rf.size.height = target.rightArea.height - notchWingInset * 2
        rf.origin.x = target.rightArea.minX - seamOverlap
        rf.origin.y = target.rightArea.minY + notchWingInset
        if rf.maxX > target.rightArea.maxX {
            rf.size.width = target.rightArea.width
        }
        notchRightPanel.setFrame(rf, display: true)

        positionExpandedPanel()
        let centerStripe = NSRect(x: lf.maxX, y: min(lf.minY, rf.minY),
                                  width: rf.minX - lf.maxX,
                                  height: max(lf.maxY, rf.maxY) - min(lf.minY, rf.minY))
        let covered = centerStripe
        let bleed = notchBackdropBleed
        let backdrop = NSRect(x: covered.minX - bleed,
                              y: covered.minY - bleed,
                              width: covered.width + bleed * 2,
                              height: covered.height + bleed)
        notchBackdropPanel.setFrame(backdrop, display: true)
        snappingToNotch = false
    }

    func positionExpandedPanel() {
        guard let target = notchTarget() else { return }
        let leftFrame = notchLeftPanel.frame
        let rightFrame = notchRightPanel.frame
        var f = panel.frame
        f.origin.x = leftFrame.minX
        f.size.width = rightFrame.maxX - leftFrame.minX
        f.origin.y = target.leftArea.minY - f.height
        panel.setFrame(f, display: true)
    }

    func updateNotchWingVisibility() {
        guard isNotchPinned, notchUIVisible else {
            notchBackdropPanel.orderOut(nil)
            notchLeftPanel.orderOut(nil)
            notchRightPanel.orderOut(nil)
            return
        }
        notchBackdropPanel.orderFrontRegardless()
        // 背板覆盖展开区来消除接缝，但只能位于内容面板下方。
        // 双翼异步切换完成后会再次进入这里；若不重新提升 panel，
        // orderFrontRegardless() 会把整块黑背板盖到详情内容上。
        if notchExpanded {
            panel.orderFrontRegardless()
        }
        if notchLeftStack.arrangedSubviews.isEmpty { notchLeftPanel.orderOut(nil) }
        else { notchLeftPanel.orderFrontRegardless() }
        if notchRightStack.arrangedSubviews.isEmpty { notchRightPanel.orderOut(nil) }
        else { notchRightPanel.orderFrontRegardless() }
    }

    func notchHoverChanged(_ inside: Bool) {
        guard isNotchPinned, notchUIVisible, last != nil else { return }
        if inside {
            notchCollapseWork?.cancel()
            showNotchDetails()
        } else {
            scheduleNotchCollapse()
        }
    }

    func showNotchDetails() {
        guard !notchExpanded else { return }
        notchExpanded = true
        prepareExpandedWingContent()
        if let last { renderNotchDetails(last) }
        // 展开态双翼变成工具栏；阅读型内容全部使用下方完整宽度。
        transitionNotchWingContent()
        header.isHidden = true
        header.alphaValue = 0
        layoutPanel(anchorTop: true)
        positionExpandedPanel()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            self.panel.animator().alphaValue = 1
        }
    }

    func scheduleNotchCollapse() {
        notchCollapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.pointerInsideNotchUI() else { return }
            self.hideNotchDetails()
        }
        notchCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    func pointerInsideNotchUI() -> Bool {
        let p = NSEvent.mouseLocation
        return notchLeftPanel.frame.contains(p)
            || notchRightPanel.frame.contains(p)
            || (notchExpanded && panel.frame.contains(p))
    }

    func hideNotchDetails() {
        guard notchExpanded else { return }
        notchExpanded = false
        transitionNotchWingContent()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            self.panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.notchExpanded else { return }
            self.panel.orderOut(nil)
            self.header.isHidden = true
            self.header.alphaValue = 0
            self.panel.alphaValue = 1
            self.layoutPanel(anchorTop: true)
        })
    }

    func prepareExpandedWingContent() {
        let now = Date().timeIntervalSince1970
        let hasRecentTrend = usageHistory.contains { now - $0.timestamp >= 5 * 60 }
        // 有历史后每次展开在分析与灵感之间交替；采样不足时用灵感代替空占位。
        if hasRecentTrend {
            expandedWingShowsInspiration.toggle()
        } else {
            expandedWingShowsInspiration = true
        }
        guard !notchInspirations.isEmpty else { return }
        if notchInspirations.count == 1 {
            inspirationIndex = 0
            return
        }
        var next = Int.random(in: 0..<notchInspirations.count)
        if next == inspirationIndex {
            next = (next + 1) % notchInspirations.count
        }
        inspirationIndex = next
    }

    func transitionNotchWingContent() {
        guard last != nil else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            notchLeftStack.animator().alphaValue = 0
            notchRightStack.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, let payload = self.last else { return }
            self.renderNotchWings(payload)
            self.notchLeftStack.alphaValue = 0
            self.notchRightStack.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                self.notchLeftStack.animator().alphaValue = 1
                self.notchRightStack.animator().alphaValue = 1
            }
        })
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
        updateNotchWingVisibility()
    }

    func modeIcon() -> String {
        mode == "list" ? "◔" : mode == "ring" ? "▤" : "☰"
    }

    @objc func showProviderMenu() {
        guard let payload = last else { return }
        let providers = compactProviders(payload, applyingSelection: false)
        let selected = Set(compactSelection())
        let menu = NSMenu()
        // 用勾选框控件当菜单项 view: 普通 target/action 菜单项一点就整菜单关闭,
        // 多选场景每勾一个都被迫重开; 带控件的 view 会自己吃掉点击, 菜单保持
        // 打开 → 可连续勾选/取消。
        let boxes: [NSButton] = providers.map { p in
            let b = NSButton(checkboxWithTitle: p.name, target: self,
                             action: #selector(toggleProvider(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(p.id)
            b.state = selected.contains(p.id) ? .on : .off
            b.sizeToFit()
            return b
        }
        let itemW = (boxes.map { $0.frame.width }.max() ?? 120) + 32
        for (p, box) in zip(providers, boxes) {
            let item = NSMenuItem()
            item.representedObject = p.id
            let host = NSView(frame: NSRect(x: 0, y: 0, width: itemW, height: 22))
            box.setFrameOrigin(NSPoint(x: 20, y: (22 - box.frame.height) / 2))
            host.addSubview(box)
            item.view = host
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

    @objc func toggleProvider(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue, let payload = last else { return }
        let available = compactProviders(payload, applyingSelection: false).map(\.id)
        var chosen = Set(compactSelection().filter { available.contains($0) })
        // 勾选框点击时已先翻转自身状态, 直接按新状态增删
        if sender.state == .on {
            // 已选满 4 个: 不静默挤掉别人, 直接拒绝本次勾选 (想换先取消一个), NSBeep 提示
            if chosen.count >= 4 { sender.state = .off; NSSound.beep(); return }
            chosen.insert(id)
        } else {
            chosen.remove(id)
        }
        // 显示顺序 = provider 自然顺序 (菜单顺序), 与勾选先后无关
        var selected = available.filter { chosen.contains($0) }
        if selected.isEmpty { selected = defaultCompactIDs.filter { available.contains($0) } }
        UserDefaults.standard.set(selected, forKey: "compactProviderIDs")
        // 菜单不关闭, 回同步所有勾选框 (处理 空→默认 回填)
        let shown = Set(selected)
        for it in sender.enclosingMenuItem?.menu?.items ?? [] {
            guard let b = it.view?.subviews.first(where: { $0 is NSButton }) as? NSButton,
                  let bid = b.identifier?.rawValue else { continue }
            b.state = shown.contains(bid) ? .on : .off
        }
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
        recordUsageSample(payload)
        // 成功的 provider 更新缓存; 失败的用缓存兜底 (变灰显示旧数据而非消失)
        for p in payload.providers where p.ok { lastGood[p.id] = p }
        staleIDs.removeAll()
        let merged = payload.providers.map { p -> Provider in
            if !p.ok, let cached = lastGood[p.id] { staleIDs.insert(p.id); return cached }
            return p
        }
        let mergedPayload = Payload(updated: payload.updated, providers: merged)
        last = mergedPayload
        updatedLabel.stringValue = payload.updated
        if isNotchPinned {
            renderNotchWings(mergedPayload)
            renderNotchDetails(mergedPayload)
            listStack.isHidden = true
            ringStack.isHidden = true
            notchDetailStack.isHidden = false
            layoutPanel(anchorTop: true)
            if notchExpanded {
                positionExpandedPanel()
                panel.orderFrontRegardless()
            } else {
                panel.orderOut(nil)
            }
            updateNotchWingVisibility()
            return
        }
        let compact = mode == "ring" || mode == "bar"
        if mode == "ring" { renderRings(mergedPayload) }
        else if mode == "bar" { renderBars(mergedPayload) }
        else { renderList(mergedPayload) }
        // NSStackView 自动把 hidden 的 arranged subview 移出布局
        listStack.isHidden = compact
        ringStack.isHidden = !compact
        notchDetailStack.isHidden = true
        layoutPanel(anchorTop: true)
    }

    func loadUsageHistory() {
        guard let data = UserDefaults.standard.data(forKey: usageHistoryKey),
              let decoded = try? JSONDecoder().decode([UsageSample].self, from: data)
        else { return }
        let cutoff = Date().timeIntervalSince1970 - 6 * 3600
        usageHistory = decoded.filter { $0.timestamp >= cutoff }
    }

    func recordUsageSample(_ payload: Payload) {
        let percentages = Dictionary(uniqueKeysWithValues: payload.providers.compactMap {
            provider -> (String, Double)? in
            guard provider.ok, let pct = provider.wins?.first?.pct else { return nil }
            return (provider.id, pct)
        })
        guard !percentages.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        // refresh 为 60 秒；45 秒内的重复 render 不重复记样本。
        if let lastSample = usageHistory.last, now - lastSample.timestamp < 45 { return }
        usageHistory.append(UsageSample(timestamp: now, percentages: percentages))
        let cutoff = now - 6 * 3600
        usageHistory.removeAll { $0.timestamp < cutoff }
        if let data = try? JSONEncoder().encode(usageHistory) {
            UserDefaults.standard.set(data, forKey: usageHistoryKey)
        }
    }

    // 旧数据兜底: apply() 正常渲染后, 整体降低 alpha + tooltip 标注 (apply 每轮重置 tooltip, 不会重复累积)
    func applyStale(_ cell: NSView, id: String) {
        if staleIDs.contains(id) {
            cell.alphaValue = 0.32
            if let tip = cell.toolTip, !tip.isEmpty, !tip.contains("⚠") {
                cell.toolTip = tip + "  · ⚠旧数据"
            }
        } else {
            cell.alphaValue = 1
        }
    }

    // 按当前模式与标题栏显隐重算面板尺寸.
    // anchorTop=true: 顶边固定向下伸缩 (切换视图/数据更新, 历史行为);
    // anchorTop=false: 底边固定向上伸缩 (悬停标题栏, 内容在屏幕上原地不动),
    //                  上方空间不足时退回顶边固定向下展开, 收起按原方向回退
    func layoutPanel(anchorTop: Bool) {
        if isNotchPinned { snapPanelToNotch() }
        let compact = mode == "ring" || mode == "bar"
        let notchCompact = compact && isNotchPinned
        stack.spacing = isNotchPinned ? 5 : 10
        let compactW = currentCompactWidth()
        let contentWidth = isNotchPinned ? currentNotchDetailWidth() : compact ? compactW : contentW
        let panelContentW = header.isHidden ? contentWidth : max(contentWidth, headerMinW)
        // 紧凑模式 = 单行小组件: 内容更窄, 边距收紧
        headerW.constant = panelContentW
        insets[0].constant = isNotchPinned ? 7 : notchCompact ? 4 : compact ? 8 : 12
        insets[1].constant = isNotchPinned ? 8 : notchCompact ? 5 : compact ? 12 : 16
        insets[2].constant = isNotchPinned ? -8 : notchCompact ? -5 : compact ? -12 : -16
        insets[3].constant = isNotchPinned ? -7 : notchCompact ? -4 : compact ? -8 : -12
        // 注意: 不能先 layoutIfNeeded —— 约束变化会让 AutoLayout 抢先隐式改窗口
        // 尺寸 (锚点不可控), 再读 frame 就错了, 表现为悬停一次窗口下移一截;
        // 必须 读旧 frame → fittingSize 纯测量 → 显式 setFrame → 最后布局
        var f = panel.frame
        let top = f.maxY
        let newH = stack.fittingSize.height + (isNotchPinned ? 14 : notchCompact ? 8 : compact ? 16 : 24)
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
        f.size.width = panelContentW + (isNotchPinned ? 16 : notchCompact ? 10 : compact ? 24 : 32)
        if keepTop { f.origin.y = top - newH }
        if let vis = (panel.screen ?? NSScreen.main)?.visibleFrame {
            // 上下都放不下时兜底: 底边别压进 Dock; 切换视图变宽时右缘不出屏
            if !anchorTop, f.origin.y < vis.minY { f.origin.y = vis.minY }
            if f.maxX > vis.maxX { f.origin.x = vis.maxX - f.width }
        }
        panel.setFrame(f, display: true)
        snapPanelToNotch()
        panel.layoutIfNeeded()
    }

    func renderNotchDetails(_ payload: Payload) {
        for v in notchDetailStack.arrangedSubviews {
            notchDetailStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        let providers = compactProviders(payload)
        let columns = providers.count == 3 ? 3 : max(1, min(2, providers.count))
        let detailW = notchDetailWidth(providerCount: providers.count)
        let showsHero = notchExpanded && providers.count <= 3
        if showsHero {
            if expandedWingShowsInspiration, !notchInspirations.isEmpty {
                let item = notchInspirations[inspirationIndex % notchInspirations.count]
                notchHeroQuote.apply(item, width: detailW)
            } else {
                let insight = recentUsageInsight(payload)
                notchHeroQuote.apply(
                    title: "\(insight.leftTitle) · \(insight.rightTitle)",
                    subtitle: "近期用量分析",
                    width: detailW)
            }
            notchDetailStack.addArrangedSubview(notchHeroQuote)
            let divider = NSView()
            divider.wantsLayer = true
            divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
            divider.translatesAutoresizingMaskIntoConstraints = false
            divider.widthAnchor.constraint(equalToConstant: detailW).isActive = true
            divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
            notchDetailStack.addArrangedSubview(divider)
        }
        for start in stride(from: 0, to: providers.count, by: columns) {
            if start > 0 {
                let divider = NSView()
                divider.wantsLayer = true
                divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
                divider.translatesAutoresizingMaskIntoConstraints = false
                divider.widthAnchor.constraint(equalToConstant: detailW).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
                notchDetailStack.addArrangedSubview(divider)
            }
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fill
            row.spacing = 0
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: detailW).isActive = true
            notchDetailStack.addArrangedSubview(row)

            let end = min(start + columns, providers.count)
            let rowProviders = Array(providers[start..<end])
            let cellWidths = notchDetailCellWidths(
                providers: rowProviders, columns: columns, totalWidth: detailW)
            for column in 0..<columns {
                if column > 0 {
                    let divider = NSView()
                    divider.wantsLayer = true
                    divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.09).cgColor
                    divider.translatesAutoresizingMaskIntoConstraints = false
                    divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                    divider.heightAnchor.constraint(equalToConstant: 34).isActive = true
                    row.addArrangedSubview(divider)
                }
                let index = start + column
                if index < end {
                    let p = providers[index]
                    let cell = notchDetailCells[p.id] ?? {
                        let c = NotchDetailCell()
                        c.translatesAutoresizingMaskIntoConstraints = false
                        notchDetailCells[p.id] = c
                        return c
                    }()
                    cell.apply(p, width: cellWidths[column], balanceOnly: isBalanceOnly(p))
                    applyStale(cell, id: p.id)
                    row.addArrangedSubview(cell)
                } else {
                    let spacer = NSView()
                    spacer.translatesAutoresizingMaskIntoConstraints = false
                    spacer.widthAnchor.constraint(equalToConstant: cellWidths[column]).isActive = true
                    spacer.heightAnchor.constraint(equalToConstant: 46).isActive = true
                    row.addArrangedSubview(spacer)
                }
            }
        }
    }

    func notchDetailWidth(providerCount: Int) -> CGFloat {
        // 展开层的外宽始终与上方整块黑色刘海区域一致；减去左右 8pt 内边距。
        // 这里读取前景双翼的固定跨度，不能读取会随展开态外扩的底板宽度。
        let notchWidth = notchRightPanel.frame.maxX - notchLeftPanel.frame.minX
        if notchWidth > 16 { return notchWidth - 16 }
        let columns = providerCount == 3 ? 3 : max(1, min(2, providerCount))
        return CGFloat(columns) * notchDetailCellW + CGFloat(max(columns - 1, 0))
    }

    func currentNotchDetailWidth() -> CGFloat {
        guard let last else { return notchDetailWidth(providerCount: 2) }
        return notchDetailWidth(providerCount: compactProviders(last).count)
    }

    func isBalanceOnly(_ provider: Provider) -> Bool {
        provider.id == "deepseek" || (provider.wins ?? []).isEmpty
    }

    func notchDetailCellWidths(
        providers: [Provider], columns: Int, totalWidth: CGFloat
    ) -> [CGFloat] {
        let dividerWidth = CGFloat(max(columns - 1, 0))
        let usableWidth = max(0, totalWidth - dividerWidth)
        // 三项单排时，余额项只占一个金额标签的宽度，其余空间平分给进度项。
        if providers.count == 3 {
            let balanceCount = providers.filter(isBalanceOnly).count
            let progressCount = providers.count - balanceCount
            if balanceCount > 0, progressCount > 0 {
                let balanceWidth = min(notchBalanceDetailW,
                                       usableWidth / CGFloat(providers.count))
                let progressWidth =
                    (usableWidth - CGFloat(balanceCount) * balanceWidth)
                    / CGFloat(progressCount)
                return providers.map { isBalanceOnly($0) ? balanceWidth : progressWidth }
            }
        }
        let equalWidth = usableWidth / CGFloat(max(columns, 1))
        return Array(repeating: equalWidth, count: columns)
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
            applyStale(r, id: p.id)
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
        let providers = compactProviders(last)
        return max(providers.reduce(CGFloat(0)) {
            $0 + (($1.wins ?? []).isEmpty ? balanceCellW : (mode == "bar" ? barCellW : ringCellW))
        }, mode == "bar" ? barCellW : ringCellW)
    }

    func notchSplit(_ providers: [Provider]) -> (left: [Provider], right: [Provider]) {
        guard isNotchPinned, providers.count > 1 else { return ([], providers) }
        let leftCount = min(2, providers.count - 1)
        return (Array(providers.prefix(leftCount)), Array(providers.dropFirst(leftCount)))
    }

    func renderRings(_ payload: Payload) {
        // 单行迷你圆环: 默认取 Claude/Codex/GLM/MiniMax，可在配置菜单调整
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
        for p in ringable { addRingProvider(p, to: rs) }
    }

    func renderNotchWings(_ payload: Payload) {
        for v in notchLeftStack.arrangedSubviews {
            notchLeftStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for v in notchRightStack.arrangedSubviews {
            notchRightStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        if notchExpanded {
            renderNotchInsights(payload)
            snapPanelToNotch()
            updateNotchWingVisibility()
            return
        }

        let split = notchSplit(compactProviders(payload))
        notchLeftStack.distribution = .fill
        notchRightStack.distribution = .fill
        for p in split.left { addNotchProvider(p, to: notchLeftStack) }
        for p in split.right { addNotchProvider(p, to: notchRightStack) }
        if !split.left.isEmpty {
            notchLeftPanel.setContentSize(NSSize(
                width: compactWidth(split.left, progressW: ringCellW) + 10,
                height: 30))
        }
        if !split.right.isEmpty {
            notchRightPanel.setContentSize(NSSize(
                width: compactWidth(split.right, progressW: ringCellW) + 10,
                height: 30))
        }
        snapPanelToNotch()
        updateNotchWingVisibility()
    }

    func renderNotchInsights(_ payload: Payload) {
        let leftWidth = max(36, notchLeftPanel.frame.width - 10)
        notchLeftInsight.apply(title: payload.updated,
                               subtitle: "",
                               width: leftWidth)
        notchLeftStack.addArrangedSubview(notchLeftInsight)
        let rightWidth = max(0, notchRightPanel.frame.width - 10)
        let buttons: [NSButton] = rightWidth >= 54
            ? [notchRefreshBtn, notchConfigBtn, notchHideBtn]
            : [notchRefreshBtn, notchConfigBtn]
        notchRightStack.distribution = .fillEqually
        for button in buttons {
            notchRightStack.addArrangedSubview(button)
        }
    }

    func recentUsageInsight(_ payload: Payload) -> (
        leftTitle: String, leftSubtitle: String, leftAccent: NSColor?,
        rightTitle: String, rightSubtitle: String, rightAccent: NSColor?
    ) {
        let providers = compactProviders(payload)
        let current = Dictionary(uniqueKeysWithValues: providers.compactMap {
            provider -> (String, Double)? in
            guard let pct = provider.wins?.first?.pct else { return nil }
            return (provider.id, pct)
        })
        let now = Date().timeIntervalSince1970
        let candidates = usageHistory.filter { now - $0.timestamp >= 5 * 60 }
        if !current.isEmpty,
           let baseline = candidates.min(by: {
               abs($0.timestamp - (now - 3600)) < abs($1.timestamp - (now - 3600))
           }) {
            let deltas = providers.compactMap { provider -> (Provider, Double)? in
                guard let latest = current[provider.id],
                      let earlier = baseline.percentages[provider.id]
                else { return nil }
                // 窗口重置会让百分比下降；这种情况不把负数误报为“负消耗”。
                return (provider, max(0, latest - earlier))
            }
            if !deltas.isEmpty {
                let minutes = max(5, Int(round((now - baseline.timestamp) / 60)))
                let period = minutes >= 50 && minutes <= 90
                    ? "近1h"
                    : (minutes < 60 ? "近\(minutes)m" : "近\(max(1, minutes / 60))h")
                let total = deltas.reduce(0) { $0 + $1.1 }
                let active = deltas.max { $0.1 < $1.1 }
                let leftTitle = total < 0.5 ? "\(period) 平稳" : "\(period) +\(Int(round(total)))pt"
                let rightTitle = active.map {
                    $0.1 < 0.5 ? "无明显增长" : "\($0.0.name) +\(Int(round($0.1)))pt"
                } ?? "无明显增长"
                return (leftTitle, "总用量变化", total >= 20 ? .systemOrange : nil,
                        rightTitle, "最近最活跃",
                        active.flatMap { paceColor($0.0.tone) })
            }
        }

        let rankedTone = ["red": 4, "orange": 3, "yellow": 2, "green": 1]
        let focus = providers.max {
            rankedTone[$0.tone ?? ""] ?? 0 < rankedTone[$1.tone ?? ""] ?? 0
        }
        if let focus, let tone = focus.tone, tone == "red" || tone == "orange" {
            return ("趋势采集中", "本地轻量采样", nil,
                    "\(focus.name)偏快", "当前消耗速度", paceColor(tone))
        }
        return ("趋势采集中", "约 5 分钟后可用", nil,
                "当前较平稳", "持续观察中", .systemGreen)
    }

    func addNotchProvider(_ p: Provider, to stack: NSStackView) {
        if (p.wins ?? []).isEmpty {
            stack.addArrangedSubview(balanceCell(p))
            return
        }
        let cell = ringCells[p.id] ?? {
            let c = RingCell()
            c.translatesAutoresizingMaskIntoConstraints = false
            c.widthAnchor.constraint(equalToConstant: ringCellW).isActive = true
            ringCells[p.id] = c
            return c
        }()
        cell.showsPopover = false
        cell.apply(p)
        applyStale(cell, id: p.id)
        stack.addArrangedSubview(cell)
    }

    func addRingProvider(_ p: Provider, to stack: NSStackView) {
        if (p.wins ?? []).isEmpty {
            stack.addArrangedSubview(balanceCell(p))
            return
        }
        let cell = ringCells[p.id] ?? {
            let c = RingCell()
            c.translatesAutoresizingMaskIntoConstraints = false
            c.widthAnchor.constraint(equalToConstant: ringCellW).isActive = true
            ringCells[p.id] = c
            return c
        }()
        cell.showsPopover = true
        cell.apply(p)
        applyStale(cell, id: p.id)
        stack.addArrangedSubview(cell)
    }

    func renderBars(_ payload: Payload) {
        notchLeftPanel.orderOut(nil)
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
            applyStale(cell, id: p.id)
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
        applyStale(cell, id: p.id)
        return cell
    }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // 不占 Dock
app.run()
