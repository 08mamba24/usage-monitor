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
    tone: nil, wins: nil, cval: nil)
guard notchCompactName(compactClaude) == "Ant" else {
    fputs("FAIL: compact Claude name should be Ant\n", stderr)
    exit(1)
}
guard notchDetailValue(compactClaude) == "5h 2% 2.5h" else {
    fputs("FAIL: compact reset time should not include a slash\n", stderr)
    exit(1)
}
let compactClaudeSecondary = notchDetailSecondary(compactClaude)
guard compactClaudeSecondary.leading == "max 20x" else {
    fputs("FAIL: compact Claude plan should be left aligned\n", stderr)
    exit(1)
}
guard compactClaudeSecondary.trailing == "7d 3% 6d" else {
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
guard let planLabel = compactClaudeLabels.first(where: { $0.stringValue == "max 20x" }),
      let weeklyLabel = compactClaudeLabels.first(where: { $0.stringValue == "7d 3% 6d" }),
      planLabel.frame.maxX + 5 <= weeklyLabel.frame.minX else {
    fputs("FAIL: compact Claude plan and weekly reset should not overlap\n", stderr)
    exit(1)
}

let compactGLM = Provider(
    id: "glm", name: "GLM", kind: "percent", ok: true,
    pct: 0, value: "5h 0% /4.2h", detail: "", tone: nil, wins: nil, cval: nil)
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
    tone: nil, wins: nil, cval: nil)
guard notchDetailSecondary(compactCodex).leading == "7d 4% 6d" else {
    fputs("FAIL: compact non-Claude reset time should not include a slash\n", stderr)
    exit(1)
}

let compactSpark = Provider(
    id: "spark", name: "Spark", kind: "percent", ok: true,
    pct: 15, value: "5h 15% /2.5h", detail: "7d 7% /6d",
    tone: nil, wins: nil, cval: nil)
guard notchCompactName(compactSpark) == "Spark" else {
    fputs("FAIL: compact Spark name should stay Spark\n", stderr)
    exit(1)
}
guard notchDetailSecondary(compactSpark).leading == "7d 7% 6d" else {
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
    guard remainingCell.toolTip?.contains("5h \(percentLeft)% left") == true,
          remainingCell.toolTip?.contains("MCP 40% left") == true else {
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
