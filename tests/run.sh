#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests/test_providers.py

SDK15="$(xcrun --sdk macosx15.4 --show-sdk-path 2>/dev/null || true)"
sed '/^let app = NSApplication.shared/,$d' UsageMonitor.swift \
    > /tmp/UsageMonitorUnderTest.swift
if [[ -n "$SDK15" ]]; then
    xcrun swiftc -DTESTING -sdk "$SDK15" \
        -module-cache-path /tmp/usage-monitor-swift-module-cache \
        -o /tmp/usage-monitor-regression \
        /tmp/UsageMonitorUnderTest.swift tests/main.swift
else
    xcrun swiftc -DTESTING \
        -module-cache-path /tmp/usage-monitor-swift-module-cache \
        -o /tmp/usage-monitor-regression \
        /tmp/UsageMonitorUnderTest.swift tests/main.swift
fi

/tmp/usage-monitor-regression
