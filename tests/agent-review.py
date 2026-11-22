"""Regression checks for pairing a QA status with the installed images."""
import importlib.util
from datetime import datetime, timezone
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[1] / "aegis-config/scripts/agent-review.py"
spec = importlib.util.spec_from_file_location("agent_review", path)
review = importlib.util.module_from_spec(spec)
spec.loader.exec_module(review)

class AgentReviewTest(unittest.TestCase):
    def setUp(self):
        self.ids = ["sha256:" + digit * 64 for digit in "1234"]
        self.now = datetime(2026, 11, 21, tzinfo=timezone.utc)
        self.report = dict(schema=1, kind="agent-security-observation",
                           current_id=self.ids[0], candidate_id=self.ids[1], npm_id=self.ids[2],
                           upstream_digest=self.ids[3], runtime={"pcre2": "10.49-r0", "libxml2": "2.13.9-r3"},
                           observed_at=self.now.isoformat(), expected_finish_at="2026-11-23T00:00:00Z",
                           phase="long", http_ok=448, http_bad=0)
    def output(self):
        return review.render(self.report, self.ids[0], self.ids[2], self.ids[3], self.now)

    def test_matching_pair_and_sample(self):
        state, message, versions, counts = self.output()
        self.assertEqual(state, "TESTING")
        self.assertIn("48시간", message)
        self.assertIn("2.13.9-r3", versions)
        self.assertIn("448건 성공", counts)

    def test_independent_followup(self):
        self.report.update(profile="geo-cache", runtime={"hiredis":"1.2.1", "maxminddb":"1.14.1"})
        state, message, versions, _ = self.output()
        self.assertEqual(state, "TESTING")
        self.assertIn("후속", message)
        self.assertIn("Hiredis 1.2.1", versions)

    def test_followup_visible_on_its_parent_image(self):
        parent = "sha256:" + "e" * 64
        self.report.update(profile="geo-cache", parent_id=parent, from_version="1.1.33", to_version="1.1.36",
                           runtime={"hiredis": "1.2.1", "maxminddb": "1.14.1"})
        state, message, *_ = review.render(self.report, parent, self.ids[2], self.ids[3], self.now)
        self.assertEqual(state, "TESTING")
        self.assertIn("후속 에이전트 후보 1.1.36", message)

    def test_rehearsal_freshness(self):
        self.report.update(phase="rehearsing", reported_at=self.now.isoformat())
        self.assertEqual(self.output()[0], "TESTING")
        self.report["reported_at"] = "2026-11-20T23:00:00Z"
        self.assertEqual(self.output()[0], "REVIEW")

    def test_changed_upstream_or_npm(self):
        for key in ("current_id", "npm_id", "upstream_digest"):
            with self.subTest(key=key):
                saved = self.report[key]
                self.report[key] = "sha256:" + "a"*64
                with self.assertRaises(ValueError):
                    self.output()
                self.report[key] = saved

    def test_offline_report_shows_last_review_and_versions(self):
        self.report.update(from_version="1.1.33", to_version="1.1.36")
        state, message, *_ = review.render(self.report, self.ids[0], self.ids[2], "-", self.now)
        self.assertEqual(state, "REVIEW")
        self.assertIn("1.1.33 → 1.1.36", message)
        self.assertIn("공급자 조회 실패", message)

    def test_stale_or_future_sample(self):
        for date in ("2026-11-20T23:57:00Z", "2026-11-22T00:00:00Z"):
            self.report["observed_at"] = date
            self.assertEqual(self.output()[0], "REVIEW")

    def test_qualification_and_contaminated_data(self):
        self.report["phase"] = "passed"
        self.assertEqual(self.output()[0], "OBSERVED")
        self.report["http_bad"] = 1
        self.assertEqual(self.output()[0], "REVIEW")
        self.report["runtime"]["pcre2"] = "10.49\ninvalid"
        with self.assertRaises(ValueError):
            self.output()

if __name__ == "__main__":
    unittest.main()
