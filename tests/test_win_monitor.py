import unittest
from unittest import mock

import providers
import win_monitor


class PctColorTests(unittest.TestCase):
    """着色阈值对齐 UsageMonitor.swift pctColor: 50/70/90 三档。"""

    def test_green_below_50(self):
        self.assertEqual(win_monitor.pct_color(0), win_monitor.GREEN)
        self.assertEqual(win_monitor.pct_color(49), win_monitor.GREEN)

    def test_yellow_from_50(self):
        self.assertEqual(win_monitor.pct_color(50), win_monitor.YELLOW)
        self.assertEqual(win_monitor.pct_color(69), win_monitor.YELLOW)

    def test_orange_from_70(self):
        self.assertEqual(win_monitor.pct_color(70), win_monitor.ORANGE)
        self.assertEqual(win_monitor.pct_color(89), win_monitor.ORANGE)

    def test_red_from_90(self):
        self.assertEqual(win_monitor.pct_color(90), win_monitor.RED)
        self.assertEqual(win_monitor.pct_color(100), win_monitor.RED)

    def test_none_is_gray(self):
        self.assertEqual(win_monitor.pct_color(None), win_monitor.GRAY)


class CompactNameTests(unittest.TestCase):
    """短名对齐 UsageMonitor.swift notchCompactName: 仅 claude/glm 缩写。"""

    def test_claude_is_ant(self):
        self.assertEqual(win_monitor.compact("claude", "Claude"), "Ant")

    def test_glm_is_zai(self):
        self.assertEqual(win_monitor.compact("glm", "GLM"), "ZAI")

    def test_others_keep_formal_name(self):
        self.assertEqual(win_monitor.compact("codex", "Codex"), "Codex")
        self.assertEqual(win_monitor.compact("spark", "Spark"), "Spark")
        self.assertEqual(win_monitor.compact("grok", "Grok"), "Grok")


class UiRowTests(unittest.TestCase):
    def test_percent_row_rounds_and_colors(self):
        r = win_monitor.ui_row({"id": "claude", "name": "Claude", "kind": "percent",
                                "ok": True, "pct": 12.4, "value": "5h 12% /2.5h",
                                "detail": "7d 3% /6d · max 20x"})
        self.assertEqual(r["name"], "Ant")
        self.assertEqual(r["text"], "12%")
        self.assertEqual(r["color"], win_monitor.GREEN)
        self.assertIn("max 20x", r["tip"])

    def test_balance_row_prefers_today_spend_cval(self):
        r = win_monitor.ui_row({"id": "deepseek", "name": "DeepSeek",
                                "kind": "balance", "ok": True, "pct": None,
                                "value": "¥88.20", "detail": "today -¥1.20",
                                "cval": "-¥1.20"})
        self.assertEqual(r["text"], "-¥1.20")
        self.assertEqual(r["pct"], None)

    def test_error_row_shows_dash_and_keeps_detail(self):
        r = win_monitor.ui_row({"id": "gemini", "name": "Gemini", "kind": "percent",
                                "ok": False, "pct": None, "value": "—",
                                "detail": "err: HTTPError"})
        self.assertEqual(r["text"], "—")
        self.assertEqual(r["color"], win_monitor.GRAY)
        self.assertIn("err: HTTPError", r["tip"])

    def test_ui_rows_passes_through_ordered_providers(self):
        payload = {"updated": "12:00", "providers": [
            {"id": "codex", "name": "Codex", "kind": "percent", "ok": True,
             "pct": 40, "value": "5h 40%", "detail": ""},
            {"id": "glm", "name": "GLM", "kind": "percent", "ok": True,
             "pct": 95, "value": "5h 95%", "detail": ""},
        ]}
        rows = win_monitor.ui_rows(payload)
        self.assertEqual([r["id"] for r in rows], ["codex", "glm"])
        self.assertEqual(rows[1]["color"], win_monitor.RED)


class ClaudeOauthPlatformDispatchTests(unittest.TestCase):
    """macOS 走钥匙串; Windows/Linux 读 ~/.claude/.credentials.json。"""

    def test_windows_reads_credentials_file(self):
        oauth = {"claudeAiOauth": {"accessToken": "t"}}
        with mock.patch("sys.platform", "win32"), \
             mock.patch.object(providers, "_json_file", return_value=oauth):
            self.assertEqual(providers.claude_oauth(), {"accessToken": "t"})

    def test_windows_missing_file_raises_missing_cred(self):
        with mock.patch("sys.platform", "win32"), \
             mock.patch.object(providers, "_json_file", return_value={}):
            with self.assertRaises(providers.MissingCred):
                providers.claude_oauth()

    def test_darwin_uses_keychain(self):
        with mock.patch("sys.platform", "darwin"), \
             mock.patch.object(providers, "keychain",
                               return_value={"claudeAiOauth": {"accessToken": "k"}}):
            self.assertEqual(providers.claude_oauth(), {"accessToken": "k"})


class CollectTests(unittest.TestCase):
    def _row(self, pid, kind="percent", ok=True):
        return providers.row(pid, pid.title(), kind=kind, ok=ok, pct=10,
                             value="x", detail="" if ok else "err")

    def test_collect_filters_missing_and_sorts_canonical_order(self):
        fakes = {
            "deepseek": lambda: self._row("deepseek", "balance"),
            "glm": lambda: self._row("glm"),
            "claude": lambda: providers.row("claude", "Claude", kind="missing"),
        }
        with mock.patch.object(providers, "PROVIDERS",
                               list(fakes.values())):
            payload = providers.collect()
        self.assertEqual([r["id"] for r in payload["providers"]], ["glm", "deepseek"])
        self.assertIn("updated", payload)
