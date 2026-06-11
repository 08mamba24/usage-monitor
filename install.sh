#!/usr/bin/env bash
# usage-monitor 安装/卸载: 编译 + launchd 登录自启 + 立即运行
# 用法: ./install.sh           安装 (重复执行 = 重新编译并重启)
#       ./install.sh --uninstall
set -euo pipefail
cd "$(dirname "$0")"
LABEL=com.usage-monitor
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
GUI="gui/$(id -u)"

if [[ "${1:-}" == "--uninstall" ]]; then
    launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "✓ uninstalled (credentials & ~/.config/usage-monitor left untouched)"
    exit 0
fi

command -v swiftc >/dev/null || {
    echo "Xcode Command Line Tools required: xcode-select --install"; exit 1; }
swiftc -O -o usage-monitor UsageMonitor.swift
mkdir -p "$HOME/.config/usage-monitor"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$PWD/usage-monitor</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOF
launchctl bootout "$GUI/$LABEL" 2>/dev/null || true
launchctl bootstrap "$GUI" "$PLIST"
echo "✓ running — login autostart enabled. Uninstall: ./install.sh --uninstall"
