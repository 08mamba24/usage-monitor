import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import providers


class RoutingSnapshotTests(unittest.TestCase):
    def test_collection_emits_machine_time_without_changing_used_percentage(self):
        item = providers.pct_row("claude", "Claude", 100, 60000)
        with mock.patch.object(providers, "PROVIDERS", [lambda: item]):
            payload = providers.collect()
        self.assertEqual(payload["schemaVersion"], 2)
        self.assertIsInstance(payload["observedAt"], int)
        self.assertEqual(payload["providers"][0]["pct"], 100)
        self.assertGreater(item["wins"][0]["resetAt"], payload["observedAt"])

    def test_unrounded_usage_is_separate_from_display_percent(self):
        window = providers.win("5h", 99.6)
        self.assertEqual(window["pct"], 100)
        self.assertEqual(window["usedPercent"], 99.6)

    def test_claude_paid_overage_is_not_a_hard_subscription_limit(self):
        with mock.patch.object(providers, "claude_oauth", return_value={"accessToken": "test"}), \
             mock.patch.object(providers, "http_json", return_value={
                 "five_hour": {"utilization": 100}, "extra_usage": {"is_enabled": True}}):
            result = providers.p_claude()
        self.assertFalse(result["quotaEnforced"])

    def test_codex_paid_credits_keep_an_exhausted_subscription_advisory(self):
        with mock.patch.object(providers, "codex_usage", return_value={
                "rate_limit": {"primary_window": {"used_percent": 100}},
                "credits": {"has_credits": True}}):
            result = providers.p_codex()
        self.assertEqual(result["pct"], 100)
        self.assertFalse(result["quotaEnforced"])

    def test_actual_http_auth_is_fingerprinted_without_exposing_it(self):
        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self): return b'{}'
        with mock.patch.object(providers, "PROVIDERS", []):
            @providers.provider("fixture", "Fixture")
            def fetch():
                providers.http_json("https://provider.invalid/usage", {"Authorization": "Bearer private-token"})
                return providers.pct_row("fixture", "Fixture", 20)
            with mock.patch.object(providers.urllib.request, "urlopen", return_value=Response()):
                result = fetch()
        self.assertEqual(len(result["accountKey"]), 64)
        self.assertNotIn("private-token", json.dumps(result))

    def test_success_and_failure_have_distinct_observation_metadata(self):
        with mock.patch.object(providers, "PROVIDERS", []):
            @providers.provider("fixture", "Fixture")
            def success():
                providers.remember_account("fixture", "private-token")
                return providers.pct_row("fixture", "Fixture", 100)

            @providers.provider("broken", "Broken")
            def broken():
                raise TimeoutError("secret must never enter snapshot")

            good, bad = success(), broken()
        self.assertTrue(good["ok"])
        self.assertEqual(len(good["accountKey"]), 64)
        self.assertIsInstance(good["observedAt"], int)
        self.assertNotIn("private-token", json.dumps(good))
        self.assertFalse(bad["ok"])
        self.assertNotIn("accountKey", bad)
        self.assertIsInstance(bad["observedAt"], int)

    def test_gemini_retains_each_model_bucket(self):
        quota = {"buckets": [
            {"modelId": "pro", "remainingFraction": .8,
             "resetTime": "2030-01-01T00:00:00Z"},
            {"modelId": "flash", "remainingFraction": 0},
        ]}
        with mock.patch.object(providers, "_json_file", return_value={
                "refresh_token": "refresh", "access_token": "access",
                "expiry_date": 9999999999999}), \
             mock.patch.object(providers, "http_json", return_value=quota):
            item = providers.p_gemini()
        self.assertEqual(item["pct"], 100)  # display contract preserved
        self.assertEqual([w["label"] for w in item["quotaWindows"]], ["pro", "flash"])
        self.assertEqual([w["pct"] for w in item["quotaWindows"]], [20, 100])
        self.assertEqual(item["quotaWindows"][0]["resetAt"], 1893456000000)

    def test_codex_and_spark_reuse_account_identity_on_cached_fetch(self):
        providers.clear_codex_usage_cache()
        self.addCleanup(providers.clear_codex_usage_cache)
        def fetch():
            providers.remember_account("codex", "same-account")
            return {"rate_limit": {"primary_window": {"used_percent": 10}},
                    "additional_rate_limits": [{"name": "spark", "primary_window": {"used_percent": 90}}]}
        with mock.patch.object(providers, "fetch_codex_usage", side_effect=fetch):
            codex, spark = providers.p_codex(), providers.p_spark()
        self.assertEqual(codex["accountKey"], spark["accountKey"])

    def test_repeated_collection_fetches_a_new_sample_instead_of_redating_cached_usage(self):
        self.addCleanup(providers.clear_codex_usage_cache)
        responses = [{"rate_limit": {"primary_window": {"used_percent": used}}}
                     for used in (10, 20)]
        with mock.patch.object(providers, "PROVIDERS", [providers.p_codex]), \
             mock.patch.object(providers, "fetch_codex_usage", side_effect=responses) as fetch:
            first, second = providers.collect(), providers.collect()
        self.assertEqual(fetch.call_count, 2)
        self.assertEqual(first["providers"][0]["pct"], 10)
        self.assertEqual(second["providers"][0]["pct"], 20)

    def test_cache_replace_is_atomic_and_private(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "usage.json"
            path.write_text('{"old":true}')
            providers.write_usage_cache(path, '{"new":true}')
            self.assertEqual(json.loads(path.read_text()), {"new": True})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(Path(directory).iterdir()), [path])
