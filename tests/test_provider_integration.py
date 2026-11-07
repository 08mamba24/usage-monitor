"""Provider entry-point regressions; all credentials and HTTP calls are mocked."""
import datetime
import gc
import json
import os
import tempfile
import unittest
import urllib.error
import warnings
from unittest import mock

import providers


class StatePersistenceTests(unittest.TestCase):
    def test_token_state_roundtrip_preserves_other_entries_without_resource_warnings(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "state.json")
            balance = {"baseline": 10, "date": "2030-01-01"}
            token = {"token": "test-token", "expire": 2000000000}
            with open(path, "w") as state_file:
                json.dump({"deepseek": balance}, state_file)
            with mock.patch.object(providers, "STATE", path), \
                 warnings.catch_warnings(record=True) as observed:
                warnings.simplefilter("always", ResourceWarning)
                providers._save_state("qoder_token", token)
                saved = providers._json_file(path)
                gc.collect()
            self.assertEqual(saved, {"deepseek": balance, "qoder_token": token})
            self.assertEqual([warning for warning in observed
                              if issubclass(warning.category, ResourceWarning)], [])


class QuotaBoundaryTests(unittest.TestCase):
    def test_qoder_addon_is_usable_without_a_base_pool(self):
        for quota in (
            {"userQuota": {"total": 0}, "addOnQuota": {"total": 100, "used": 25}},
            {"add_on_quota": {"total": 100, "used": 25}},
        ):
            with self.subTest(quota=quota):
                result = providers.qoder_from_quota(quota)
                self.assertTrue(result["ok"])
                self.assertEqual(result["pct"], 25)
                self.assertIn("75/100 left", result["detail"])

    def test_minimax_zero_remaining_means_exhausted(self):
        payload = {"model_remains": [{"current_interval_remaining_percent": 0,
                                     "current_weekly_remaining_percent": 0}]}
        with mock.patch.object(providers, "cred", return_value="test-key"), \
             mock.patch.object(providers, "http_json", return_value=payload):
            result = providers.p_minimax()
        self.assertEqual(result["pct"], 100)
        self.assertEqual([window["pct"] for window in result["wins"]], [100, 100])


class CodeBuddyEntryTests(unittest.TestCase):
    SUMMARY = {"code": 0, "data": {"Packages": [
        {"CycleTotalCapacity": "100", "CycleUsedCapacity": "25"}]}}

    def test_posts_summary_with_cli_bearer_and_waf_user_agent(self):
        with mock.patch.object(providers, "codebuddy_session", return_value="test-token"), \
             mock.patch.object(providers, "http_json", return_value=self.SUMMARY) as http:
            result = providers.p_codebuddy()
        self.assertTrue(result["ok"])
        self.assertEqual(result["pct"], 25)
        self.assertEqual(http.call_args.args[0],
                         "https://copilot.tencent.com/billing/meter/get-user-resource-summary")
        self.assertEqual(http.call_args.args[1]["Authorization"], "Bearer test-token")
        self.assertTrue(http.call_args.args[1]["User-Agent"])
        self.assertEqual(http.call_args.kwargs["data"], b"{}")

    def test_near_expiry_session_is_hidden_without_sending_token(self):
        now = datetime.datetime(2030, 1, 1)
        auth = {"auth": {"accessToken": "test-token",
                         "expiresAt": now.timestamp() * 1000 + 59000}}
        with mock.patch.object(providers.datetime, "datetime", wraps=datetime.datetime) as clock, \
             mock.patch.object(providers, "_json_file", return_value=auth), \
             mock.patch.object(providers, "http_json") as http:
            clock.now.return_value = now
            result = providers.p_codebuddy()
        self.assertEqual(result["kind"], "missing")
        http.assert_not_called()

    def test_http_error_is_not_success_and_does_not_expose_server_body(self):
        error = urllib.error.HTTPError("https://copilot.tencent.com", 401,
                                       "private diagnostic", {}, None)
        with mock.patch.object(providers, "codebuddy_session", return_value="test-token"), \
             mock.patch.object(providers, "http_json", side_effect=error):
            result = providers.p_codebuddy()
        self.assertFalse(result["ok"])
        self.assertEqual(result["detail"], "err: HTTPError")

    def test_business_error_does_not_render_cached_quota_as_current(self):
        payload = dict(self.SUMMARY, code=401, msg="private diagnostic")
        result = providers.codebuddy_from_summary(payload)
        self.assertFalse(result["ok"])
        self.assertEqual(result["detail"], "err: CodeBuddy API 401")


if __name__ == "__main__":
    unittest.main()
