import unittest
from check import newest_stable, newest_advisory, fixed_in

class T(unittest.TestCase):
    def test_stable_skips_odd_minor(self):
        listing = "wpewebkit-2.53.92.tar.xz wpewebkit-2.54.1.tar.xz wpewebkit-2.54.0.tar.xz wpewebkit-2.55.1.tar.xz"
        self.assertEqual(newest_stable(listing), "2.54.1")
    def test_advisory_newest(self):
        self.assertEqual(newest_advisory("WSA-2025-0009 WSA-2026-0005 WSA-2026-0006"), "WSA-2026-0006")
    def test_fixed_in(self):
        html = "<b>Versions affected:</b> WebKitGTK and WPE WebKit before 2.54.0 or earlier."
        self.assertEqual(fixed_in(html), "2.54.0")
        self.assertIsNone(fixed_in("nothing"))

unittest.main()
