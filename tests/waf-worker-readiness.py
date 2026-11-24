"""Exercise the updater's actual worker checks against synthetic procfs records."""
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "aegis-config/scripts/wait-waf-ready.sh"


class WorkerReadiness(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.proc = self.root / "proc"
        self.children = self.proc / "10/task/10/children"
        self.children.parent.mkdir(parents=True)
        self.children.write_text("11 12 13 14")
        (self.root / "nginx.pid").write_text("10")
        self.worker(11, "nginx: worker process is shutting down", 1)
        self.worker(12, "nginx: worker process", 1)
        self.worker(13, "nginx: worker process", 2)
        self.worker(14, "nginx: cache manager process", None)

    def worker(self, pid, title, channel):
        path = self.proc / str(pid)
        path.mkdir(exist_ok=True)
        (path / "cmdline").write_bytes(title.encode() + b"\0")
        (path / "maps").write_text("".join(
            f"1000-2000 rw-s 00000000 00:01 1 /dev/shm/__cp_nano_{direction}_shared_memory_{channel}__\n"
            for direction in ("tx", "rx") if channel is not None))

    def ready(self):
        script = SCRIPT.read_text().split("connected_workers() {", 1)[1].split("\n}", 1)[0]
        script = script.replace("/proc/", str(self.proc) + "/").replace("/run/nginx/nginx.pid", str(self.root / "nginx.pid"))
        run = subprocess.run(["sh", "-c", "workers=2\nconnected_workers() {" + script + "\n}\nconnected_workers"])
        return run.returncode == 0

    def test_draining_worker_can_keep_the_pending_api_connection(self):
        self.assertTrue(self.ready())

    def test_two_accepting_workers_cannot_share_a_channel(self):
        self.worker(13, "nginx: worker process", 1)
        self.assertFalse(self.ready())

    def test_a_draining_worker_cannot_supply_a_missing_live_channel(self):
        self.worker(12, "nginx: worker process", None)
        self.assertFalse(self.ready())


if __name__ == "__main__":
    unittest.main()
