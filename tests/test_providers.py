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


if __name__ == "__main__":
    unittest.main()
