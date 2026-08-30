import unittest

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


if __name__ == "__main__":
    unittest.main()
