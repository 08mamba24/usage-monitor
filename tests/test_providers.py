import json
import os
import unittest
from unittest import mock

import providers


class FormatResetTimeTests(unittest.TestCase):
    def test_uses_decimal_hours_during_last_six_hours(self):
        self.assertEqual(providers.fmt_ms(91 * 60 * 1000), "1.5h")
        self.assertEqual(providers.fmt_ms(147 * 60 * 1000), "2.5h")
        self.assertEqual(providers.fmt_ms(180 * 60 * 1000), "3h")

    def test_keeps_minutes_below_one_hour(self):
        self.assertEqual(providers.fmt_ms(59 * 60 * 1000), "59m")

    def test_keeps_whole_hours_from_six_hours(self):
        self.assertEqual(providers.fmt_ms(6 * 60 * 60 * 1000), "6h")


class GrokCreditsMappingTests(unittest.TestCase):
    """Map Grok CLI-proxy /v1/billing?format=credits onto the existing pct_row contract.

    Ground truth is Grok Build /usage → Usage limit: Weekly limit (SuperGrok Heavy).
    Session token/cost from that screen is out of scope.
    """

    WEEKLY = {
        "config": {
            "creditUsagePercent": 0,
            "currentPeriod": {
                "start": "2026-08-23T03:47:00Z",
                "end": "2026-08-30T03:47:00Z",
            },
            "subscriptionTier": "supergrok",
        }
    }

    def test_weekly_zero_matches_usage_limit_screen(self):
        row = providers.grok_from_credits(
            self.WEEKLY, {"subscription_tier_display": "SuperGrok Heavy"})
        self.assertEqual(row["id"], "grok")
        self.assertEqual(row["kind"], "percent")
        self.assertTrue(row["ok"])
        self.assertEqual(row["pct"], 0)
        self.assertEqual(row["wins"][0]["label"], "7d")
        self.assertTrue(row["value"].startswith("7d 0%"))
        self.assertIn("SuperGrok Heavy", row["detail"])

    def test_omitted_percent_with_period_is_zero_not_missing(self):
        billing = {
            "config": {
                "currentPeriod": {
                    "start": "2026-08-23T03:47:00Z",
                    "end": "2026-08-30T03:47:00Z",
                }
            }
        }
        row = providers.grok_from_credits(billing)
        self.assertEqual(row["pct"], 0)
        self.assertEqual(row["wins"][0]["label"], "7d")

    def test_on_demand_ratio_when_percent_absent(self):
        billing = {
            "config": {
                "onDemandCap": {"val": 200},
                "onDemandUsed": {"val": 50},
                "currentPeriod": {"end": "2026-09-01T00:00:00Z"},
            }
        }
        row = providers.grok_from_credits(billing)
        self.assertEqual(row["pct"], 25)

    def test_plan_prefers_settings_display_name(self):
        row = providers.grok_from_credits(
            self.WEEKLY, {"subscription_tier_display": "heavy"})
        self.assertIn("SuperGrok Heavy", row["detail"])

    def test_monthly_window_label(self):
        billing = {
            "config": {
                "creditUsagePercent": 12.4,
                "currentPeriod": {
                    "start": "2026-08-01T00:00:00Z",
                    "end": "2026-08-31T00:00:00Z",
                },
            }
        }
        row = providers.grok_from_credits(billing)
        self.assertEqual(row["pct"], 12)
        self.assertEqual(row["wins"][0]["label"], "mo")

    def test_missing_config_is_not_ok(self):
        row = providers.grok_from_credits({})
        self.assertFalse(row["ok"])
        self.assertEqual(row["detail"], "no quota data")

    def test_prefers_auth_xai_oidc_slot(self):
        auth = {
            "https://accounts.x.ai/sign-in": {"key": "legacy-token"},
            "https://auth.x.ai::client": {"key": "oidc-token", "oidc_client_id": "client"},
        }
        _, entry = providers.grok_cred_slot(auth)
        self.assertEqual(entry["key"], "oidc-token")


class CustomEndpointTests(unittest.TestCase):
    """CUSTOM_USAGE_URL 通用接口: 数字当百分比, used/total 换算, 缺配置隐藏。"""

    def _env(self, extra=None):
        base = {"CUSTOM_USAGE_URL": "https://gw.local/api/usage"}
        base.update(extra or {})
        return base

    def test_no_url_configured_is_hidden(self):
        with mock.patch.object(providers, "ENV", {}):
            self.assertEqual(providers.p_custom()["kind"], "missing")

    def test_nested_number_is_percentage(self):
        with mock.patch.object(providers, "ENV", self._env(
                {"CUSTOM_USAGE_PATH": "data.percent", "CUSTOM_NAME": "OneAPI"})), \
             mock.patch.object(providers, "http_json",
                               return_value={"data": {"percent": 37.5}}):
            r = providers.p_custom()
        self.assertEqual(r["name"], "OneAPI")
        self.assertEqual(r["pct"], 38)
        self.assertEqual(r["wins"][0]["label"], "api")
        self.assertTrue(r["ok"])

    def test_used_total_dict_is_converted(self):
        with mock.patch.object(providers, "ENV", self._env(
                {"CUSTOM_USAGE_PATH": "quota"})), \
             mock.patch.object(providers, "http_json",
                               return_value={"quota": {"used": 30, "total": 200}}):
            r = providers.p_custom()
        self.assertEqual(r["pct"], 15)
        self.assertIn("30 / 200", r["detail"])

    def test_zero_total_is_not_ok(self):
        with mock.patch.object(providers, "ENV", self._env()), \
             mock.patch.object(providers, "http_json",
                               return_value={"pct": {"used": 0, "total": 0}}):
            r = providers.p_custom()
        self.assertFalse(r["ok"])

    def test_missing_path_is_error_row(self):
        with mock.patch.object(providers, "ENV", self._env(
                {"CUSTOM_USAGE_PATH": "nope.deep"})), \
             mock.patch.object(providers, "http_json", return_value={"data": 5}):
            r = providers.p_custom()
        self.assertEqual(r["detail"], "err: KeyError")

    def test_bearer_token_is_sent_when_configured(self):
        with mock.patch.object(providers, "ENV", self._env(
                {"CUSTOM_USAGE_TOKEN": "sk-test"})), \
             mock.patch.object(providers, "http_json",
                               return_value={"pct": 10}) as hj:
            providers.p_custom()
            headers = hj.call_args[0][1]
        self.assertEqual(headers["Authorization"], "Bearer sk-test")


class CodexSparkPoolTests(unittest.TestCase):
    """Spark is a separate quota pool on the same wham/usage payload."""

    WHAM = {
        "plan_type": "prolite",
        "rate_limit": {
            "primary_window": {
                "used_percent": 51,
                "limit_window_seconds": 604800,
                "reset_at": 1789437107,
            },
            "secondary_window": None,
        },
        "additional_rate_limits": [{
            "limit_name": "GPT-5.3-Codex-Spark",
            "metered_feature": "codex_bengalfox",
            "rate_limit": {
                "primary_window": {
                    "used_percent": 15,
                    "limit_window_seconds": 18000,
                    "reset_at": 1789046509,
                },
                "secondary_window": {
                    "used_percent": 7,
                    "limit_window_seconds": 604800,
                    "reset_at": 1789633309,
                },
            },
        }],
    }

    def setUp(self):
        providers.clear_codex_usage_cache()

    def tearDown(self):
        providers.clear_codex_usage_cache()

    def test_spark_row_is_not_the_codex_row(self):
        with mock.patch.object(providers, "fetch_codex_usage", return_value=self.WHAM):
            spark = providers.p_spark()
            codex = providers.p_codex()
        self.assertEqual(spark["id"], "spark")
        self.assertEqual(spark["name"], "Spark")
        self.assertTrue(spark["ok"])
        self.assertEqual(spark["pct"], 15)
        self.assertEqual(spark["wins"][0]["label"], "5h")
        self.assertEqual(spark["wins"][1]["label"], "7d")
        self.assertEqual(spark["wins"][1]["pct"], 7)
        self.assertEqual(codex["id"], "codex")
        self.assertEqual(codex["pct"], 51)
        self.assertEqual(codex["wins"][0]["label"], "7d")
        self.assertNotEqual(spark["pct"], codex["pct"])

    def test_codex_and_spark_share_one_fetch(self):
        with mock.patch.object(providers, "fetch_codex_usage",
                               return_value=self.WHAM) as fetch:
            providers.p_codex()
            providers.p_spark()
        self.assertEqual(fetch.call_count, 1)

    def test_missing_spark_quota_is_hidden(self):
        d = {"plan_type": "plus", "rate_limit": {"primary_window": {"used_percent": 1}},
             "additional_rate_limits": []}
        with mock.patch.object(providers, "fetch_codex_usage", return_value=d):
            r = providers.p_spark()
        self.assertEqual(r["kind"], "missing")

    def test_gpt_reserve_is_not_spark(self):
        d = {
            "plan_type": "prolite",
            "rate_limit": {"primary_window": {"used_percent": 1}},
            "additional_rate_limits": [{
                "limit_name": "gpt-reserve",
                "rate_limit": {
                    "primary_window": {
                        "used_percent": 3,
                        "limit_window_seconds": 18000,
                    },
                },
            }],
        }
        with mock.patch.object(providers, "fetch_codex_usage", return_value=d):
            r = providers.p_spark()
        self.assertEqual(r["kind"], "missing")

    def test_flattened_spark_windows_without_nested_rate_limit(self):
        d = {
            "plan_type": "prolite",
            "rate_limit": {"primary_window": {"used_percent": 1}},
            "additional_rate_limits": [{
                "id": "codex-spark",
                "name": "GPT-5.3-Codex-Spark",
                "primary_window": {
                    "used_percent": 12,
                    "limit_window_seconds": 18000,
                    "reset_at": 1789046509,
                },
                "secondary_window": {
                    "used_percent": 8,
                    "limit_window_seconds": 604800,
                    "reset_at": 1789633309,
                },
            }],
        }
        with mock.patch.object(providers, "fetch_codex_usage", return_value=d):
            r = providers.p_spark()
        self.assertEqual(r["pct"], 12)
        self.assertEqual(r["wins"][1]["pct"], 8)

    def test_spark_weekly_only_promotes_to_main(self):
        d = {
            "plan_type": "prolite",
            "rate_limit": {"primary_window": {"used_percent": 1}},
            "additional_rate_limits": [{
                "limit_name": "GPT-5.3-Codex-Spark",
                "rate_limit": {
                    "primary_window": None,
                    "secondary_window": {
                        "used_percent": 9,
                        "limit_window_seconds": 604800,
                        "reset_at": 1789633309,
                    },
                },
            }],
        }
        with mock.patch.object(providers, "fetch_codex_usage", return_value=d):
            r = providers.p_spark()
        self.assertTrue(r["ok"])
        self.assertEqual(r["pct"], 9)
        self.assertEqual(r["wins"][0]["label"], "7d")


class QoderCreditPoolTests(unittest.TestCase):
    """qodercn openapi /api/v2/quota/usage → credit 池行。

    Ground truth: 2026-09-15 本机 qodercn 1.1.51 日志里的真实响应
    (userQuota total=300 used=14, userType=personal_professional_trial, expiresAt epoch ms)。
    """

    QUOTA = {
        "userId": "01a0974d-6ffb-7d10-8cee-155a404d3641",
        "userType": "personal_professional_trial",
        "usageType": "credits",
        "totalUsagePercentage": 0.62,
        "isQuotaExceeded": False,
        "expiresAt": 1790454429999,
        "userQuota": {"total": 300.0, "used": 247.0, "remaining": 53.0,
                      "percentage": 0.83, "unit": "credits"},
        "addOnQuota": {"total": 100.0, "used": 0.0, "remaining": 100.0,
                       "percentage": 0.0, "unit": "credits"},
    }

    def test_credit_pool_percent_and_expiry(self):
        r = providers.qoder_from_quota(self.QUOTA)
        self.assertEqual(r["id"], "qoder")
        self.assertTrue(r["ok"])
        # 官方口径: (247+0)/(300+100) = 61.75% → 62, 与 totalUsagePercentage 0.62 一致
        self.assertEqual(r["pct"], 62)
        self.assertTrue(r["value"].startswith("cr 62%"))
        self.assertIn("53/300 + 100/100 left", r["detail"])
        self.assertIn("personal_professional_trial", r["detail"])
        self.assertIn("exp ", r["detail"])

    def test_addon_partially_used_merges_into_pct(self):
        r = providers.qoder_from_quota({
            "expiresAt": 1790454429999,
            "userQuota": {"total": 300, "used": 300, "unit": "credits"},
            "addOnQuota": {"total": 100, "used": 40, "unit": "credits"}})
        self.assertEqual(r["pct"], 85)            # (300+40)/400
        self.assertIn("0/300 + 60/100 left", r["detail"])

    def test_snake_case_aliases(self):
        r = providers.qoder_from_quota({
            "user_type": "personal", "expires_at": 1790454429999,
            "user_quota": {"total": 100, "used": 100, "unit": "credits"},
            "is_quota_exceeded": True})
        self.assertEqual(r["pct"], 100)
        self.assertIn("quota exceeded", r["detail"])
        self.assertIn("0/100 left", r["detail"])

    def test_shared_quota_cap_fallback(self):
        r = providers.qoder_from_quota({
            "shared_quota": {"used": 30, "cap": 200, "unit": "credits"}})
        self.assertEqual(r["pct"], 15)

    def test_no_quota_data_is_not_ok(self):
        r = providers.qoder_from_quota({})
        self.assertFalse(r["ok"])
        self.assertEqual(r["detail"], "no quota data")


class QoderTokenTests(unittest.TestCase):
    """PAT → jobToken/exchange → Bearer; state 缓存 + 临期 refresh。"""

    def setUp(self):
        import tempfile
        self._tmp = tempfile.NamedTemporaryFile(suffix=".json", delete=False)
        self._tmp.close()
        self._state_patch = mock.patch.object(providers, "STATE", self._tmp.name)
        self._state_patch.start()
        self._env_patch = mock.patch.object(providers, "ENV", {"QODER_PAT": "pat-1"})
        self._env_patch.start()

    def tearDown(self):
        self._state_patch.stop()
        self._env_patch.stop()
        os.unlink(self._tmp.name)

    def test_exchange_then_cache(self):
        with mock.patch.object(providers, "http_json",
                               return_value={"token": "bearer-1", "refresh_token": "r1",
                                             "expire_time": 9999999999}) as hj:
            self.assertEqual(providers.qoder_token("https://api.local"), "bearer-1")
            self.assertEqual(providers.qoder_token("https://api.local"), "bearer-1")
        self.assertEqual(hj.call_count, 1)   # 第二次走缓存
        self.assertIn("exchange", hj.call_args[0][0])
        self.assertEqual(json.loads(hj.call_args.kwargs["data"])["personal_token"], "pat-1")

    def test_stale_token_refreshes_with_refresh_token(self):
        import time
        s = {"qoder_token": {"token": "old", "refresh_token": "r1", "expire": time.time() - 1}}
        json.dump(s, open(self._tmp.name, "w"))
        with mock.patch.object(providers, "http_json",
                               return_value={"token": "bearer-2", "expire_time": 9999999999}) as hj:
            self.assertEqual(providers.qoder_token("https://api.local"), "bearer-2")
        self.assertIn("jobToken/refresh", hj.call_args[0][0])
        self.assertEqual(json.loads(hj.call_args.kwargs["data"])["refresh_token"], "r1")

    def test_failed_refresh_falls_back_to_exchange(self):
        import time
        s = {"qoder_token": {"token": "old", "refresh_token": "r1", "expire": time.time() - 1}}
        json.dump(s, open(self._tmp.name, "w"))
        calls = []
        def fake_hj(url, headers=None, data=None, timeout=None):
            calls.append(url)
            if "refresh" in url:
                raise RuntimeError("refresh dead")
            return {"token": "bearer-3", "expire_time": 9999999999}
        with mock.patch.object(providers, "http_json", fake_hj):
            self.assertEqual(providers.qoder_token("https://api.local"), "bearer-3")
        self.assertTrue(any("refresh" in u for u in calls))
        self.assertTrue(any("exchange" in u for u in calls))

    def test_missing_pat_is_hidden(self):
        with mock.patch.object(providers, "ENV", {}), \
             mock.patch.dict(os.environ, clear=False):
            for k in ("QODERCN_PERSONAL_ACCESS_TOKEN", "QODER_PERSONAL_ACCESS_TOKEN"):
                os.environ.pop(k, None)
            r = providers.p_qoder()
        self.assertEqual(r["kind"], "missing")

    def test_expires_in_relative_seconds(self):
        import time
        with mock.patch.object(providers, "http_json",
                               return_value={"token": "t", "expires_in": 3600}):
            providers.qoder_token("https://api.local")
        e = json.load(open(self._tmp.name))["qoder_token"]
        self.assertAlmostEqual(e["expire"], time.time() + 3600, delta=5)

    def test_real_exchange_shape_iso_and_ms(self):
        """实测 exchange 响应: expires_at 是 ISO 串, expires_in 是毫秒 (86400000=24h)"""
        import time
        with mock.patch.object(providers, "http_json",
                               return_value={"token": "jt-x", "refresh_token": "jrt-x",
                                             "expires_at": "2026-09-17T00:37:35Z",
                                             "expires_in": 86400000}):
            providers.qoder_token("https://api.local")
        e = json.load(open(self._tmp.name))["qoder_token"]
        self.assertEqual(e["refresh_token"], "jrt-x")
        self.assertAlmostEqual(e["expire"], 1789605455, delta=5)   # 2026-09-17T00:37:35Z
        # ISO 串与毫秒时长两种表达解析等价 (86400000ms = 24h 前的 now 起算)
        iso = providers._tok_exp("2026-09-17T00:37:35Z", 0)
        ms = providers._tok_exp(86400000, 1789605455 - 86400)
        self.assertAlmostEqual(iso, ms, delta=1)


if __name__ == "__main__":
    unittest.main()
