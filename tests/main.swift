import AppKit

let compactClaude = Provider(
    id: "claude", name: "Claude", kind: "percent", ok: true,
    pct: 2, value: "5h 2% /2.5h", detail: "7d 3% /6d · max 20x",
    tone: nil, wins: nil, cval: nil)
guard notchDetailName(compactClaude) == "Ant" else {
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
guard let planLabel = compactClaudeLabels.first(where: { $0.stringValue == "max 20x" }),
      let weeklyLabel = compactClaudeLabels.first(where: { $0.stringValue == "7d 3% 6d" }),
      planLabel.frame.maxX + 5 <= weeklyLabel.frame.minX else {
    fputs("FAIL: compact Claude plan and weekly reset should not overlap\n", stderr)
    exit(1)
}

let compactGLM = Provider(
    id: "glm", name: "GLM", kind: "percent", ok: true,
    pct: 0, value: "5h 0% /4.2h", detail: "", tone: nil, wins: nil, cval: nil)
guard notchDetailName(compactGLM) == "ZAI" else {
    fputs("FAIL: compact GLM name should be ZAI\n", stderr)
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

print("PASS: App uses exactly three panels")
print("PASS: collapsed notch wings stay within the menu bar")
