"""Exercise directory recovery across a partially completed data switch."""

import importlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "aegis-config/scripts"))
update = importlib.import_module("stack-update")


class RecoveryPaths(unittest.TestCase):
    def test_resume_after_original_data_was_moved(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            work = base / ".aegis-update" / "stack-change.test"
            original = work / "original" / "aegis-data"
            original.mkdir(parents=True)
            (original / "old").write_text("preserved")
            with patch.object(update, "BASE", base):
                update.move_paths(work, ["aegis-data"], restore=True)
                update.move_paths(work, ["aegis-data"], restore=True)
            self.assertEqual((base / "aegis-data/old").read_text(), "preserved")
            self.assertFalse(original.exists())

    def test_keep_candidate_writes_separate_on_rollback(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            work = base / ".aegis-update" / "stack-change.test"
            current = base / "aegis-data"
            candidate = work / "candidate" / "aegis-data"
            current.mkdir()
            candidate.mkdir(parents=True)
            (current / "previous").write_text("existing")
            (candidate / "previous").write_text("existing")
            with patch.object(update, "BASE", base):
                update.move_paths(work, ["aegis-data"])
                (current / "target-change").write_text("new")
                update.move_paths(work, ["aegis-data"], restore=True)
                update.move_paths(work, ["aegis-data"], restore=True)
            self.assertEqual((current / "previous").read_text(), "existing")
            self.assertFalse((current / "target-change").exists())
            self.assertEqual((work / "failed/aegis-data/target-change").read_text(), "new")


class ReleaseSchema(unittest.TestCase):
    def valid(self, manifest):
        schema = Path(update.__file__).with_name("release-manifest.jq")
        command = ["jq", "-es", "--arg", "channel", "security", "--arg", "version", "v0.4.1",
                   "--arg", "revision", "a" * 40, "-f", str(schema)]
        return subprocess.run(command, input=json.dumps(manifest), text=True,
                              capture_output=True).returncode == 0

    def test_stack_manifest_requires_exact_services_and_ids(self):
        item = {"from_id": "sha256:" + "a" * 64, "target": "fixture/image@sha256:" + "b" * 64}
        manifest = {"schema_version": 1, "from_version": "v0.4.1", "from_commit": "a" * 40,
                    "channel": "security", "release": "distribution", "resolved_cves": ["CVE-2000-0000"],
                    "images": {"npm": item}}
        self.assertTrue(self.valid(manifest))
        manifest["strategy"] = "stack-v1"
        self.assertFalse(self.valid(manifest))
        manifest["images"] = {name: item.copy() for name in update.STEPS}
        self.assertFalse(self.valid(manifest))
        for spec in manifest["images"].values():
            spec["target_id"] = "sha256:" + "c" * 64
        self.assertTrue(self.valid(manifest))
        manifest["images"]["db"]["target_id"] = "latest"
        self.assertFalse(self.valid(manifest))


if __name__ == "__main__":
    unittest.main()
