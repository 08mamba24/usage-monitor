import AppKit

do {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("usage-monitor-lock-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("nested/instance.lock")
    var owner = try? InstanceLock(at: url)
    guard owner != nil else {
        fputs("FAIL: instance lock should create its parent directory\n", stderr)
        exit(1)
    }
    do {
        _ = try InstanceLock(at: url)
        fputs("FAIL: a second instance must not acquire the same lock\n", stderr)
        exit(1)
    } catch let error as NSError {
        guard error.domain == NSPOSIXErrorDomain && error.code == Int(EWOULDBLOCK) else {
            fputs("FAIL: lock contention must report EWOULDBLOCK\n", stderr)
            exit(1)
        }
    }
    owner = nil
    guard let newOwner = try? InstanceLock(at: url) else {
        fputs("FAIL: instance lock should be released with its owner\n", stderr)
        exit(1)
    }
    withExtendedLifetime(newOwner) {}
}
print("PASS: instance lock creates its directory, rejects duplicates and releases")

func waitMain(_ seconds: TimeInterval) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until {
        RunLoop.current.run(mode: .default, before: until)
    }
}

do {
    let dwell = HoverDwell(delay: 0.08)
    var fired = false
    dwell.arm { fired = true }
    guard !fired else {
        fputs("FAIL: hover dwell should not fire immediately\n", stderr)
        exit(1)
    }
    waitMain(0.2)
    guard fired else {
        fputs("FAIL: hover dwell should fire after the delay\n", stderr)
        exit(1)
    }
}

do {
    let dwell = HoverDwell(delay: 0.08)
    var fired = false
    dwell.arm { fired = true }
    dwell.cancel()
    waitMain(0.2)
    guard !fired else {
        fputs("FAIL: cancelled hover dwell should not fire\n", stderr)
        exit(1)
    }
}

let compactClaude = Provider(
    id: "claude", name: "Claude", kind: "percent", ok: true,
    pct: 2, value: "5h 2% /2.5h", detail: "7d 3% /6d · max 20x",
    tone: nil, wins: [Win(label: "5h", pct: 2, reset: "2.5h", tone: nil),
                      Win(label: "7d", pct: 3, reset: "6d", tone: nil)], cval: nil)
guard notchCompactName(compactClaude) == "Ant" else {
    fputs("FAIL: compact Claude name should be Ant\n", stderr)
    exit(1)
}
guard notchDetailValue(compactClaude) == "5h 98% 2.5h" else {
    fputs("FAIL: compact percentage should show remaining quota and omit reset slash\n", stderr)
    exit(1)
}
let compactClaudeSecondary = notchDetailSecondary(compactClaude)
guard compactClaudeSecondary.leading == "max 20x" else {
    fputs("FAIL: compact Claude plan should be left aligned\n", stderr)
    exit(1)
}
guard compactClaudeSecondary.trailing == "7d 97% 6d" else {
    fputs("FAIL: compact Claude weekly reset should be right aligned\n", stderr)
    exit(1)
}
let compactClaudeCell = NotchDetailCell(
    frame: NSRect(x: 0, y: 0, width: 103.5, height: 46))
compactClaudeCell.apply(compactClaude, width: 103.5, balanceOnly: false)
compactClaudeCell.layoutSubtreeIfNeeded()
let compactClaudeLabels = compactClaudeCell.subviews.compactMap { $0 as? NSTextField }
guard compactClaudeLabels.contains(where: { $0.stringValue == "Ant" }) else {
    fputs("FAIL: compact Claude cell should show the short name (Ant)\n", stderr)
    exit(1)
}
guard let mainLabel = compactClaudeLabels.first(where: { $0.stringValue == "5h 98% 2.5h" }),
      let nameLabel = compactClaudeLabels.first(where: { $0.stringValue == "Ant" }),
      mainLabel.frame.minX >= nameLabel.frame.maxX + 0.5,
      mainLabel.frame.width + 0.5 >= mainLabel.stringValue.size(
        withAttributes: [.font: mainLabel.font!]).width else {
    fputs("FAIL: narrow notch must keep its remaining percentage readable beside the provider name\n", stderr)
    exit(1)
}
guard let planLabel = compactClaudeLabels.first(where: { $0.stringValue == "max 20x" }),
      let weeklyLabel = compactClaudeLabels.first(where: { $0.stringValue == "7d 97% 6d" }),
      planLabel.frame.maxX + 5 <= weeklyLabel.frame.minX,
      planLabel.frame.width + 0.5 >= planLabel.stringValue.size(
        withAttributes: [.font: planLabel.font!]).width,
      weeklyLabel.frame.width + 0.5 >= weeklyLabel.stringValue.size(
        withAttributes: [.font: weeklyLabel.font!]).width else {
    fputs("FAIL: compact Claude plan and weekly reset should not overlap\n", stderr)
    exit(1)
}

let compactGLM = Provider(
    id: "glm", name: "GLM", kind: "percent", ok: true,
    pct: 0, value: "5h 0% /4.2h", detail: "", tone: nil,
    wins: [Win(label: "5h", pct: 0, reset: "4.2h", tone: nil)], cval: nil)
guard notchCompactName(compactGLM) == "ZAI" else {
    fputs("FAIL: compact GLM name should be ZAI\n", stderr)
    exit(1)
}
let compactGLMCell = NotchDetailCell(
    frame: NSRect(x: 0, y: 0, width: 103.5, height: 46))
compactGLMCell.apply(compactGLM, width: 103.5, balanceOnly: false)
compactGLMCell.layoutSubtreeIfNeeded()
guard compactGLMCell.subviews.compactMap({ $0 as? NSTextField })
    .contains(where: { $0.stringValue == "ZAI" }) else {
    fputs("FAIL: compact GLM cell should show the short name (ZAI)\n", stderr)
    exit(1)
}

let compactCodex = Provider(
    id: "codex", name: "Codex", kind: "percent", ok: true,
    pct: 4, value: "5h 4% /2.5h", detail: "7d 4% /6d · plus",
    tone: nil, wins: [Win(label: "5h", pct: 4, reset: "2.5h", tone: nil),
                      Win(label: "7d", pct: 4, reset: "6d", tone: nil)], cval: nil)
guard notchDetailSecondary(compactCodex).leading == "7d 96% 6d" else {
    fputs("FAIL: compact non-Claude reset time should not include a slash\n", stderr)
    exit(1)
}

let compactSpark = Provider(
    id: "spark", name: "Spark", kind: "percent", ok: true,
    pct: 15, value: "5h 15% /2.5h", detail: "7d 7% /6d",
    tone: nil, wins: [Win(label: "5h", pct: 15, reset: "2.5h", tone: nil),
                      Win(label: "7d", pct: 7, reset: "6d", tone: nil)], cval: nil)
guard notchCompactName(compactSpark) == "Spark" else {
    fputs("FAIL: compact Spark name should stay Spark\n", stderr)
    exit(1)
}
guard notchDetailSecondary(compactSpark).leading == "7d 93% 6d" else {
    fputs("FAIL: compact Spark reset time should not include a slash\n", stderr)
    exit(1)
}

let ringProbe = RingCell(frame: .zero)
ringProbe.translatesAutoresizingMaskIntoConstraints = false
ringProbe.layoutSubtreeIfNeeded()
guard ringProbe.fittingSize.height == MiniRingView.Metrics.size else {
    fputs(
        "FAIL: ring cell height should match MiniRingView.Metrics.size " +
        "(got \(ringProbe.fittingSize.height))\n",
        stderr
    )
    exit(1)
}

// Exercise the real RingCell binding: pct remains used; both arcs show quota left.
let remainingCell = RingCell(frame: .zero)
let remainingRing = remainingCell.subviews.compactMap { $0 as? MiniRingView }.first!
for (used, expected) in [(0.0, 1.0), (25, 0.75), (100, 0), (-5, 1), (130, 0)] {
    let provider = Provider(
        id: "glm", name: "GLM", kind: "percent", ok: true,
        pct: used, value: "5h \(used)% /2h", detail: "MCP 60%",
        tone: "red", wins: [
            Win(label: "5h", pct: used, reset: "2h", tone: "red"),
            Win(label: "MCP", pct: 60, reset: nil, tone: nil)], cval: nil)
    remainingCell.apply(provider)
    guard remainingRing.arcs.count == 2,
          abs(remainingRing.arcs[0].frac - expected) < 0.0001,
          abs(remainingRing.arcs[1].frac - 0.4) < 0.0001,
          remainingRing.arcs[1].dashed,
          remainingRing.arcs[0].color.isEqual(NSColor.systemRed) else {
        fputs("FAIL: ring arcs should show remaining quota with original pace colors (used=\(used))\n", stderr)
        exit(1)
    }
    let percentLeft = Int(round(expected * 100))
    guard remainingCell.toolTip?.contains("5h \(percentLeft)%") == true,
          remainingCell.toolTip?.contains("MCP 40%") == true,
          remainingCell.toolTip?.contains("Used:") == false else {
        fputs("FAIL: ring tooltip should label both windows as remaining\n", stderr)
        exit(1)
    }
}
let unavailable = Provider(
    id: "glm", name: "GLM", kind: "percent", ok: false,
    pct: nil, value: "—", detail: "unavailable", tone: nil,
    wins: [Win(label: "5h", pct: 0, reset: nil, tone: nil)], cval: nil)
remainingCell.apply(unavailable)
guard remainingRing.arcs.allSatisfy({ $0.frac == 0 }) else {
    fputs("FAIL: unavailable quota must not appear as a full remaining ring\n", stderr)
    exit(1)
}
print("PASS: ring arcs and tooltip show remaining quota, including zero and unavailable")

func renderedMeter(_ view: NSView) -> NSBitmapImageRep {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        fatalError("meter should provide a bitmap for visual regression checks")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return bitmap
}

func colorfulness(_ color: NSColor) -> CGFloat {
    guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
    return max(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
        - min(rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
}

func meterPixel(_ bitmap: NSBitmapImageRep, x: CGFloat, y: CGFloat) -> NSColor {
    // AppKit coordinates start at the lower left; bitmap rows start at the top.
    bitmap.colorAt(x: Int(x * CGFloat(bitmap.pixelsWide)),
                   y: Int((1 - y) * CGFloat(bitmap.pixelsHigh)))!
}

do {
    let cell = RingCell(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
    let ring = cell.subviews.compactMap { $0 as? MiniRingView }.first!
    cell.apply(Provider(
        id: "claude", name: "Claude", kind: "percent", ok: true,
        pct: 25, value: "5h 25% /2h", detail: "", tone: "green",
        wins: [Win(label: "5h", pct: 25, reset: "2h", tone: "green")], cval: nil))
    ring.frame = NSRect(x: 0, y: 0, width: 22, height: 22)
    let bitmap = renderedMeter(ring)
    let upperRight = meterPixel(bitmap, x: 0.8, y: 0.8)
    let upperLeft = meterPixel(bitmap, x: 0.2, y: 0.8)
    guard colorfulness(upperRight) < 0.12, colorfulness(upperLeft) > 0.2 else {
        fputs("FAIL: 25% used ring should consume gray clockwise from noon (upper-right gray, upper-left bright)\n", stderr)
        exit(1)
    }
}
print("PASS: ring consumption grows clockwise from noon")

func checkMeter(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func closeColor(_ actual: NSColor?, _ expected: NSColor) -> Bool {
    guard let actual = actual?.usingColorSpace(.deviceRGB),
          let expected = expected.usingColorSpace(.deviceRGB) else { return false }
    return abs(actual.redComponent - expected.redComponent) < 0.02
        && abs(actual.greenComponent - expected.greenComponent) < 0.02
        && abs(actual.blueComponent - expected.blueComponent) < 0.02
        && abs(actual.alphaComponent - expected.alphaComponent) < 0.02
}

func layerColor(_ view: NSView) -> NSColor? {
    view.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }
}

func meterProvider(_ used: Double, tone: String? = nil,
                   secondary: Win? = nil) -> Provider {
    Provider(id: "claude", name: "Claude", kind: "percent", ok: true,
             pct: used, value: "5h \(Int(used))% /2h",
             detail: secondary.map { "\($0.label) \(Int($0.pct))% /6d" } ?? "",
             tone: tone,
             wins: [Win(label: "5h", pct: used, reset: "2h", tone: "green")]
                + (secondary.map { [$0] } ?? []), cval: nil)
}

do {
    let compact = BarCell(frame: NSRect(x: 0, y: 0, width: 124, height: 30))
    let meter = compact.subviews.compactMap { $0 as? BarMeterView }.first!
    let row = RowView(frame: NSRect(x: 0, y: 0, width: 240, height: 50))
    let rowMeters = row.subviews.filter { !($0 is NSTextField) }
    let notch = NotchDetailCell(frame: NSRect(x: 0, y: 0, width: 112, height: 46))
    let notchMeters = notch.subviews.filter { !($0 is NSTextField) }
    checkMeter(rowMeters.count == 2 && notchMeters.count == 4,
               "detail views should expose their actual track and fill subviews")

    for (used, remaining, rowWidth, notchWidth) in [
        (0.0, 1.0, 240.0, 96.0), (25, 0.75, 180, 72), (100, 0, 0, 0)
    ] {
        let provider = meterProvider(used)
        compact.apply(provider)
        row.apply(provider, totalWidth: 240)
        notch.apply(provider, width: 112, balanceOnly: false)
        row.layoutSubtreeIfNeeded()
        notch.layoutSubtreeIfNeeded()
        checkMeter(abs(meter.lanes[0].frac - remaining) < 0.0001,
                   "compact bar should bind remaining quota (used=\(used))")
        for (track, fill, expectedWidth) in [
            (rowMeters[0], rowMeters[1], rowWidth),
            (notchMeters[0], notchMeters[1], notchWidth)
        ] {
            checkMeter(abs(fill.frame.width - expectedWidth) < 0.01
                       && abs(fill.frame.maxX - track.frame.maxX) < 0.01,
                       "detail bar should leave consumed space gray on the left (used=\(used))")
        }
        let bitmap = renderedMeter(meter)
        let left = colorfulness(meterPixel(bitmap, x: 0.1, y: 3.5 / 13))
        let right = colorfulness(meterPixel(bitmap, x: 0.8, y: 3.5 / 13))
        checkMeter((used == 0 ? left > 0.2 : left < 0.12)
                   && (used == 100 ? right < 0.12 : right > 0.2),
                   "compact bar should paint gray consumption from left to right (used=\(used))")
        checkMeter(row.subviews.compactMap { $0 as? NSTextField }
                    .contains { $0.stringValue == "5h \(Int(remaining * 100))% /2h" },
                   "list percentage should agree with the remaining bar")
        checkMeter(notch.subviews.compactMap { $0 as? NSTextField }
                    .contains { $0.stringValue == "5h \(Int(remaining * 100))% 2h" },
                   "notch percentage should agree with the remaining bar")
    }

    row.apply(unavailable, totalWidth: 240)
    notch.apply(unavailable, width: 112, balanceOnly: false)
    compact.apply(unavailable)
    row.layoutSubtreeIfNeeded()
    notch.layoutSubtreeIfNeeded()
    checkMeter(rowMeters[1].isHidden || rowMeters[1].frame.width == 0,
               "unavailable list quota must not paint a bright remaining bar")
    checkMeter(notchMeters[1].isHidden || notchMeters[1].frame.width == 0,
               "unavailable notch quota must not paint a bright remaining bar")
    checkMeter(meter.lanes.allSatisfy { $0.frac == 0 },
               "unavailable compact quota must not paint a bright remaining bar")
}
print("PASS: all horizontal meter views show right-aligned remaining quota")

do {
    let ringCell = RingCell(frame: .zero)
    let ring = ringCell.subviews.compactMap { $0 as? MiniRingView }.first!
    let bar = BarCell(frame: .zero)
    let meter = bar.subviews.compactMap { $0 as? BarMeterView }.first!
    let row = RowView(frame: NSRect(x: 0, y: 0, width: 240, height: 50))
    let rowFill = row.subviews.filter { !($0 is NSTextField) }[1]
    let notch = NotchDetailCell(frame: NSRect(x: 0, y: 0, width: 112, height: 46))
    let notchMeters = notch.subviews.filter { !($0 is NSTextField) }
    let cases: [(Double, String?, NSColor)] = [
        (25, "red", .systemRed), (15, nil, .systemGreen),
        (55, nil, .systemYellow), (75, nil, .systemOrange), (95, nil, .systemRed)
    ]
    for (used, tone, expected) in cases {
        let provider = meterProvider(used, tone: tone)
        ringCell.apply(provider)
        bar.apply(provider)
        row.apply(provider, totalWidth: 240)
        notch.apply(provider, width: 112, balanceOnly: false)
        checkMeter(closeColor(ring.arcs[0].color, expected)
                   && closeColor(meter.lanes[0].color, expected)
                   && closeColor(layerColor(rowFill), expected)
                   && closeColor(layerColor(notchMeters[1]), expected),
                   "all primary bars should match ring pace override and fallback palette (used=\(used))")
    }
    for (secondary, expectedColor) in [
        (Win(label: "7d", pct: 80, reset: "6d", tone: "yellow"),
         NSColor.systemYellow.withAlphaComponent(0.75)),
        (Win(label: "MCP", pct: 80, reset: nil, tone: nil),
         NSColor.systemOrange.withAlphaComponent(0.6))
    ] {
        let provider = meterProvider(25, secondary: secondary)
        ringCell.apply(provider)
        bar.apply(provider)
        notch.apply(provider, width: 112, balanceOnly: false)
        notch.layoutSubtreeIfNeeded()
        checkMeter(closeColor(ring.arcs[1].color, expectedColor)
                   && closeColor(meter.lanes[1].color, expectedColor)
                   && closeColor(layerColor(notchMeters[3]), expectedColor),
                   "secondary bars should preserve ring weekly/MCP palette and opacity")
        checkMeter(abs(meter.lanes[1].frac - 0.2) < 0.0001
                   && abs(notchMeters[3].frame.width - 19.2) <= 0.5
                   && abs(notchMeters[3].frame.maxX - notchMeters[2].frame.maxX) < 0.01,
                   "secondary bars should also consume left-to-right and retain quota on the right (lane=\(meter.lanes[1].frac), track=\(notchMeters[2].frame), fill=\(notchMeters[3].frame))")
    }
}
print("PASS: primary and secondary meters share ring pace colors and quota opacity")

func visibleMeterLabels(_ view: NSView) -> [String] {
    view.subviews.filter { !$0.isHidden }.compactMap { ($0 as? NSTextField)?.stringValue }
}

do {
    // Real window layout includes NSTextField alignment insets absent from frame-only probes.
    for (id, name, alias) in [("claude", "Claude", "Ant"), ("glm", "GLM", "ZAI"),
                              ("codex", "Codex", "Codex")] {
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 103.5, height: 46),
                            styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 103.5, height: 46))
        host.contentView = content
        let cell = NotchDetailCell(frame: .zero)
        cell.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(cell)
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            cell.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        cell.apply(Provider(
            id: id, name: name, kind: "percent", ok: true,
            pct: 14, value: "5h 14% /2.5h", detail: "7d 3% /6d · max 20x",
            tone: nil, wins: [Win(label: "5h", pct: 14, reset: "2.5h", tone: nil),
                              Win(label: "7d", pct: 3, reset: "6d", tone: nil)], cval: nil),
            width: 103.5, balanceOnly: false)
        content.layoutSubtreeIfNeeded()
        let labels = cell.subviews.compactMap { $0 as? NSTextField }
        let nameField = labels.first { $0.stringValue == alias }!
        let valueField = labels.first { $0.stringValue == "5h 86% 2.5h" }!
        for field in [nameField, valueField] {
            let textWidth = field.stringValue.size(withAttributes: [.font: field.font!]).width
            checkMeter(field.alignmentRect(forFrame: field.frame).width + 0.5 >= textWidth,
                       "hosted 103.5pt notch must fit the complete \(alias) name, remaining percentage and reset")
        }
        checkMeter(valueField.alignmentRect(forFrame: valueField.frame).minX
                   >= nameField.alignmentRect(forFrame: nameField.frame).maxX + 4.5,
                   "hosted notch name and remaining value must retain their logical gap")
        host.close()
    }
}
print("PASS: hosted narrow notch preserves full names, remaining percentages and reset times")

do {
    let row = RowView(frame: NSRect(x: 0, y: 0, width: 240, height: 50))
    let notch = NotchDetailCell(frame: NSRect(x: 0, y: 0, width: 112, height: 46))
    let compact = BarCell(frame: .zero)
    let ring = RingCell(frame: .zero)
    for (used, left) in [(0.0, 100), (25, 75), (100, 0)] {
        let provider = meterProvider(
            used, secondary: Win(label: "7d", pct: used, reset: "6d", tone: "orange"))
        row.apply(provider, totalWidth: 240)
        notch.apply(provider, width: 112, balanceOnly: false)
        compact.apply(provider)
        ring.apply(provider)
        checkMeter(visibleMeterLabels(row).contains("5h \(left)% /2h")
                   && visibleMeterLabels(row).contains("7d \(left)% /6d"),
                   "list main and weekly labels should both report remaining quota")
        checkMeter(visibleMeterLabels(notch).contains("5h \(left)% 2h")
                   && visibleMeterLabels(notch).contains("7d \(left)% 6d"),
                   "expanded notch main and weekly labels should both report remaining quota")
        for view in [row, notch, compact, ring] as [NSView] {
            let tip = view.toolTip ?? ""
            checkMeter(tip.contains("\(left)%") && !tip.contains("Used:")
                       && !tip.contains("5h \(Int(used))%")
                       && !tip.contains("7d \(Int(used))%")
                       && !tip.contains("余") && !tip.contains("left"),
                       "native quota tooltips should contain remaining values without contradictory used percentages")
        }
        checkMeter(provider.pct == used && provider.wins?.first?.pct == used
                   && provider.wins?.last?.pct == used
                   && provider.value == "5h \(Int(used))% /2h",
                   "UI formatting must preserve backend used values for pace and history")
    }

    let mcp = Provider(
        id: "glm", name: "GLM", kind: "percent", ok: true,
        pct: 14, value: "5h 14% /2.5h", detail: "MCP 60% · pro",
        tone: nil, wins: [Win(label: "5h", pct: 14, reset: "2.5h", tone: nil),
                          Win(label: "MCP", pct: 60, reset: nil, tone: nil)], cval: nil)
    row.apply(mcp, totalWidth: 240)
    notch.apply(mcp, width: 112, balanceOnly: false)
    compact.apply(mcp)
    ring.apply(mcp)
    checkMeter(visibleMeterLabels(row).contains("5h 86% /2.5h")
               && visibleMeterLabels(row).contains { $0.contains("MCP 40%") }
               && visibleMeterLabels(notch).contains("5h 86% 2.5h")
               && visibleMeterLabels(notch).contains("MCP 40%"),
               "MCP and main percentages should consistently show remaining quota")
    for view in [row, notch, compact, ring] as [NSView] {
        let tip = view.toolTip ?? ""
        checkMeter(tip.contains("86%") && tip.contains("40%")
                   && !tip.contains("14%") && !tip.contains("60%"),
                   "MCP native tooltips should not retain used percentages")
    }

    let credits = Provider(
        id: "qoder", name: "Qoder", kind: "percent", ok: true,
        pct: 25, value: "cr 25%", detail: "153/400 left · pro · exp 2d · promo 10%",
        tone: nil, wins: [Win(label: "cr", pct: 25, reset: nil, tone: nil)], cval: nil)
    row.apply(credits, totalWidth: 240)
    notch.apply(credits, width: 112, balanceOnly: false)
    compact.apply(credits)
    ring.apply(credits)
    checkMeter(visibleMeterLabels(row).contains("75%")
               && visibleMeterLabels(notch).contains("75%")
               && visibleMeterLabels(row).contains(credits.detail)
               && visibleMeterLabels(notch).contains("153/400 left"),
               "remaining credit counts, plan, expiry and unrelated percentages should be preserved")
    for view in [row, notch, compact, ring] as [NSView] {
        let tip = view.toolTip ?? ""
        checkMeter(tip.contains("153/400 left") && tip.contains("pro")
                   && tip.contains("exp 2d") && tip.contains("promo 10%")
                   && tip.contains("75%") && !tip.contains("cr "),
                   "formatting must not invert unrelated metadata percentages or remaining counts")
    }

    let errorWithPercent = Provider(
        id: "glm", name: "GLM", kind: "percent", ok: false,
        pct: 0, value: "—", detail: "error: quota check 75% unavailable", tone: nil,
        wins: [Win(label: "5h", pct: 0, reset: nil, tone: nil)], cval: nil)
    for provider in [unavailable, errorWithPercent, Provider(
        id: "glm", name: "GLM", kind: "percent", ok: true,
        pct: nil, value: "—", detail: "no quota data", tone: nil, wins: nil, cval: nil)] {
        row.apply(provider, totalWidth: 240)
        notch.apply(provider, width: 112, balanceOnly: false)
        compact.apply(provider)
        ring.apply(provider)
        for view in [row, notch, compact, ring] as [NSView] {
            let text = (visibleMeterLabels(view) + [view.toolTip ?? ""]).joined(separator: " ")
            checkMeter(!text.contains("100%") && !text.contains("5h 0%")
                       && text.contains(provider.detail),
                       "failed or missing quota must retain its message without fabricating availability")
        }
    }
    let balance = Provider(
        id: "deepseek", name: "DeepSeek", kind: "balance", ok: true,
        pct: nil, value: "¥32.50", detail: "today ¥1.25", tone: nil, wins: nil, cval: "-¥1.25")
    row.apply(balance, totalWidth: 240)
    notch.apply(balance, width: 112, balanceOnly: true)
    checkMeter(visibleMeterLabels(row).contains("¥32.50")
               && visibleMeterLabels(row).contains("today ¥1.25")
               && visibleMeterLabels(notch).contains("¥32.50")
               && visibleMeterLabels(notch).contains("¥1.25"),
               "balance and daily spend must remain money values")
}
print("PASS: quota text and native tooltips consistently show remaining values without changing metadata")

let initialWindowCount = NSApplication.shared.windows.count
let subject = App()
let createdWindowCount = NSApplication.shared.windows.count - initialWindowCount
guard createdWindowCount == 3 else {
    fputs(
        "FAIL: App should create only main + left wing + right wing panels " +
        "(created=\(createdWindowCount))\n",
        stderr
    )
    exit(1)
}

let insightClaude = Provider(
    id: "claude", name: "Claude", kind: "percent", ok: true,
    pct: 2, value: "5h 2% /2.5h", detail: "7d 3% /6d · max 20x",
    tone: "green",
    wins: [Win(label: "5h", pct: 2, reset: "2.5h", tone: "green")],
    cval: nil)
let insightPayload = Payload(updated: "12:00", providers: [insightClaude])
subject.usageHistory = [UsageSample(
    timestamp: Date().timeIntervalSince1970 - 3600,
    percentages: ["claude": 0])]
guard subject.recentUsageInsight(insightPayload).rightTitle == "Ant +2pt" else {
    fputs("FAIL: recent usage insight should use the compact Claude name\n", stderr)
    exit(1)
}

let fastClaude = Provider(
    id: "claude", name: "Claude", kind: "percent", ok: true,
    pct: 80, value: "5h 80% /2.5h", detail: "7d 3% /6d · max 20x",
    tone: "orange",
    wins: [Win(label: "5h", pct: 80, reset: "2.5h", tone: "orange")],
    cval: nil)
subject.usageHistory = []
guard subject.recentUsageInsight(
    Payload(updated: "12:00", providers: [fastClaude])).rightTitle == "Ant偏快" else {
    fputs("FAIL: pace insight should use the compact Claude name\n", stderr)
    exit(1)
}

guard let target = subject.notchTarget() else {
    fputs("SKIP: no notched display detected\n", stderr)
    exit(0)
}

subject.snapPanelToNotch()

let menuBarBottom = min(target.leftArea.minY, target.rightArea.minY)
let wingBottom = min(subject.notchLeftPanel.frame.minY, subject.notchRightPanel.frame.minY)
guard wingBottom >= menuBarBottom else {
    fputs(
        "FAIL: collapsed notch wing protrudes below menu bar " +
        "(wing=\(wingBottom), menuBar=\(menuBarBottom))\n",
        stderr
    )
    exit(1)
}

subject.last = insightPayload
subject.notchExpandDwell.delay = 0.08
subject.notchHoverChanged(true)
guard !subject.notchExpanded else {
    fputs("FAIL: notch details should not expand immediately on hover\n", stderr)
    exit(1)
}
subject.notchHoverChanged(false)
waitMain(0.2)
guard !subject.notchExpanded else {
    fputs("FAIL: leaving before dwell should cancel notch expand\n", stderr)
    exit(1)
}

print("PASS: App uses exactly three panels")
print("PASS: collapsed notch wings stay within the menu bar")
print("PASS: notch expand waits for hover dwell")
