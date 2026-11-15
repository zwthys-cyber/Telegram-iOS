import unittest
from verify_by_truth_log import verify_truth_log

BANNERS = (
    "Test Case '-[submodules_TelegramCore_TelegramCoreTestsLib.TruthSessionTests testRandomSessionsLong]' passed (6826.540 seconds).\n"
    "Test Suite 'TruthSessionTests' passed at 2026-11-15 16:47:34.828.\n"
    "\t Executed 1 test, with 0 failures (0 unexpected) in 6826.540 (6826.546) seconds\n"
)
RECORDS = "TRUTH seed=751 steps=23 result=ok\nTRUTH seed=752 steps=30 result=ok\n"
SUMMARY = "TRUTH summary seeds=751-752 failing=0 kinds=[]\n"
VALID = RECORDS + SUMMARY + BANNERS


class TruthLogTests(unittest.TestCase):
    def test_regular_log(self):
        self.assertEqual(verify_truth_log(VALID, 751, 752, 0), SUMMARY.strip())

    def test_real_xctest_interleaving(self):
        text = RECORDS + "TRUTH summary seeds=75" + BANNERS + "1-752 failing=0 kinds=[]\n"
        self.assertEqual(verify_truth_log(text, 751, 752, 0), SUMMARY.strip())

    def test_incomplete_or_failing_evidence_is_rejected(self):
        bad = [
            VALID.replace("TRUTH seed=751 steps=23 result=ok\n", ""),
            VALID + "TRUTH seed=751 steps=23 result=ok\n",
            VALID.replace("seed=752", "seed=753"),
            VALID.replace("result=ok", "result=missing", 1),
            VALID.replace("failing=0", "failing=1"),
            VALID.replace("kinds=[]", 'kinds=[("missing", 1)]'),
            VALID.replace("with 0 failures", "with 1 failures"),
            VALID.replace("Executed 1 test", "Executed 0 tests"),
            VALID.replace(SUMMARY, ""),
            VALID.replace(BANNERS, ""),
            VALID.replace("seeds=751-752", "seeds=751-753"),
            VALID + SUMMARY,
            VALID.replace("passed (6826.540 seconds)", "failed (6826.540 seconds)"),
            RECORDS + "TRUTH summary seeds=75UNRECOGNIZED OUTPUT\n1-752 failing=0 kinds=[]\n" + BANNERS,
        ]
        for index, text in enumerate(bad):
            with self.subTest(case=index):
                with self.assertRaises(ValueError):
                    verify_truth_log(text, 751, 752, 0)

    def test_failed_process_is_rejected_even_with_successful_text(self):
        with self.assertRaises(ValueError):
            verify_truth_log(VALID, 751, 752, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
