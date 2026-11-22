"""Check archive path rules before extracting a stack snapshot."""

import importlib.util
import io
from pathlib import Path
import tarfile
import unittest


path = Path(__file__).resolve().parents[1] / "aegis-config/scripts/stack-backup.py"
spec = importlib.util.spec_from_file_location("stack_backup", path)
backup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(backup)


def archive(*entries):
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode="w:gz") as output:
        for name, kind, link in entries:
            info = tarfile.TarInfo(name)
            info.type = kind
            info.linkname = link
            output.addfile(info)
    stream.seek(0)
    return stream


class ArchivePaths(unittest.TestCase):
    directory = ("aegis-data", tarfile.DIRTYPE, "")
    certificate = ("aegis-data/certs/archive/example.pem", tarfile.REGTYPE, "")
    live = "aegis-data/certs/live/example.pem"

    def test_certificate_link(self):
        good = archive(self.directory, self.certificate,
                       (self.live, tarfile.SYMTYPE, "../archive/example.pem"))
        backup.validate_archive(good, ["aegis-data"])
        self.assertEqual(good.tell(), 0)

    def test_escaped_link_and_files(self):
        for item in [
            (self.live, tarfile.SYMTYPE, "../../../../etc/example.pem"),
            (self.live, tarfile.SYMTYPE, "/etc/example.pem"),
            ("/tmp/example.pem", tarfile.REGTYPE, ""),
            ("aegis-data/../outside", tarfile.REGTYPE, ""),
            (self.live, tarfile.LNKTYPE, "aegis-data/nonexistent.pem"),
        ]:
            with self.subTest(item=item), self.assertRaises(ValueError):
                backup.validate_archive(archive(self.directory, item), ["aegis-data"])

    def test_reject_child_of_a_link(self):
        link = ("aegis-data/redirect", tarfile.SYMTYPE, "certs")
        child = ("aegis-data/redirect/example.pem", tarfile.REGTYPE, "")
        with self.assertRaises(ValueError):
            backup.validate_archive(archive(self.directory, link, child), ["aegis-data"])


if __name__ == "__main__":
    unittest.main()
