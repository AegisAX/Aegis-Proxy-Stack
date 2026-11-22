"""Report vulnerabilities for the exact local image ID used by a container."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from urllib.request import urlopen


TOOLKIT = Path(__file__).resolve().parents[2]
BASE = Path(os.environ.get("AEGIS_INSTALL_ROOT") or TOOLKIT).resolve()
BASELINE = TOOLKIT / "aegis-config/security/image-audits.json"
CACHE = BASE / ".aegis-update/audits"
KEV_URL = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}")


def timestamp(value):
    # Go timestamps can contain nanoseconds. Python 3.8–3.10 accept microseconds.
    value = re.sub(r"\.(\d+)(?=Z|[+-]\d\d:\d\d$)", lambda m: "." + m[1][:6].ljust(6, "0"), value)
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def summarize(image, report, catalog, database):
    if report["Metadata"]["ImageID"] != image:
        raise ValueError("스캔 이미지 ID 불일치")
    results = report["Results"]
    if not any(r.get("Class") == "os-pkgs" and r.get("Packages") for r in results):
        raise ValueError("OS 패키지 목록 누락")
    findings = set()
    ids = set()
    for result in results:
        for vuln in result.get("Vulnerabilities") or []:
            severity = vuln["Severity"]
            findings.add((result["Type"], vuln["PkgName"], vuln["VulnerabilityID"], severity))
            ids.add(vuln["VulnerabilityID"])
            ids.update(vuln.get("VendorIDs") or [])
            ids.update(vuln.get("Aliases") or [])
    known = {item["cveID"] for item in catalog["vulnerabilities"]} if catalog else None
    return dict(image=image, scanned=report["CreatedAt"], database=database,
                critical=sum(f[-1] == "CRITICAL" for f in findings),
                high=sum(f[-1] == "HIGH" for f in findings),
                medium=sum(f[-1] == "MEDIUM" for f in findings),
                low=sum(f[-1] == "LOW" for f in findings),
                unknown=sum(f[-1] == "UNKNOWN" for f in findings),
                kev=sorted(ids & known) if known is not None else None,
                catalog=catalog["catalogVersion"] if catalog else None,
                eol=bool(report["Metadata"].get("OS", {}).get("EOSL")))


def read_record(image):
    try:
        record = json.loads(BASELINE.read_text()).get(image)
    except (OSError, ValueError):
        record = None
    cached = CACHE / (image[7:] + ".json")
    try:
        newer = json.loads(cached.read_text())
        if newer["image"] == image and (not record or timestamp(newer["scanned"]) >= timestamp(record["scanned"])):
            record = newer
    except (KeyError, OSError, ValueError, TypeError):
        pass
    return record


def is_due(record):
    return (not record or record.get("kev") is None or
            datetime.now(timezone.utc) - timestamp(record["database"]) >= timedelta(hours=48))


def inspect(image, detail=False):
    record = read_record(image)
    if not record:
        return "미검사 · 실행 이미지에 일치하는 결과 없음"
    kev = record["kev"]
    flags = []
    if is_due(record):
        flags.append("재검사 필요")
    previous_kev = record.get("previous_kev")
    if kev is None and previous_kev:
        flags.append(f'이전 KEV {len(previous_kev["ids"])}건 ({previous_kev["catalog"]})')
    if record.get("eol"):
        flags.append("OS 지원 종료")
    checked = timestamp(record["database"]).astimezone().strftime("%Y-%m-%d %H:%M %Z")
    if detail:
        flags += [f'Medium {record["medium"]} / Low {record["low"]} / Unknown {record["unknown"]}',
                  f'KEV 목록 {record["catalog"] or "미확인"}', ", ".join(kev or (previous_kev or {}).get("ids", []))]
    summary = " · ".join(filter(None, [f'Critical {record["critical"]} / High {record["high"]}',
                       f"KEV {len(kev)}" if kev is not None else "KEV 미대조",
                       f"DB {checked}", *flags]))
    try:
        for row in json.loads(BASELINE.read_text()).values():
            if row.get("candidate_for") == image:
                summary += "\n" + " " * 22 + "후보  " + row["validation"]
    except (ValueError, OSError, KeyError):
        pass
    return summary


def scan(images, background=False):
    if background:
        images = [image for image in images if is_due(read_record(image))]
        if not images:
            return 0
    for directory in (CACHE.parent, CACHE):
        directory.mkdir(mode=0o700, exist_ok=True)
        if directory.is_symlink() or directory.stat().st_uid != os.geteuid():
            raise ValueError("감사 저장 경로의 소유자와 유형을 확인하세요.")
        directory.chmod(0o700)
    reserve = int(os.environ.get("AEGIS_SCAN_MIN_FREE_BYTES", "0"))
    if reserve and shutil.disk_usage(CACHE).free < reserve:
        print("  스테이징 관찰용 디스크를 보존하기 위해 이미지 재검사를 보류합니다.", file=sys.stderr)
        return 1
    with (CACHE / "scan.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print("  실행 이미지 취약점 검사 중")
            return 0
        if background:
            batch = hashlib.sha256(" ".join(sorted(set(images))).encode()).hexdigest()
            attempt = CACHE / ("attempt-" + batch)
            if attempt.exists() and time.time() - attempt.stat().st_mtime < 3600:
                print("  자동 재검사 대기 · 최근 시도 기록은 audits/auto-scan.log에서 확인")
                return 0
            attempt.touch(mode=0o600)
            # The child inherits the exclusive lock and can finish after the menu exits.
            if os.fork():
                print("  새로 등록되거나 검사 시각이 지난 이미지를 백그라운드에서 검사합니다.")
                return 0
            os.setsid()
            with open(os.devnull, "rb") as input_file, (CACHE / "auto-scan.log").open("w") as log:
                os.dup2(input_file.fileno(), 0)
                os.dup2(log.fileno(), 1)
                os.dup2(log.fileno(), 2)
        return refresh(images)


def refresh(images):
    scanner = os.environ.get("AEGIS_TRIVY_BIN") or "trivy"
    try:
        with urlopen(KEV_URL, timeout=15) as stream:
            catalog = json.load(stream)
        if not catalog.get("vulnerabilities") or catalog["count"] != len(catalog["vulnerabilities"]):
            raise ValueError("incomplete catalog")
    except (OSError, ValueError, KeyError) as exc:
        print(f"CISA KEV 조회 실패 ({exc}). 이번 결과에 미대조로 표시합니다.", file=sys.stderr)
        catalog = None
    failed = False
    with tempfile.TemporaryDirectory(dir=CACHE) as directory:
        report = Path(directory) / "scan.json"
        for image in dict.fromkeys(images):
            try:
                subprocess.run([scanner, "image", "--image-src", "docker", "--scanners", "vuln",
                                "--pkg-types", "os,library", "--list-all-pkgs", "--no-progress", "--parallel", "1",
                                "--ignorefile", "/dev/null", "--ignore-unfixed=false",
                                "--severity", "UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL",
                                "--format", "json", "--output", str(report), image],
                               check=True, timeout=900)
                metadata = json.loads(subprocess.check_output([scanner, "version", "--format", "json"], timeout=30))
                raw = report.read_bytes()
                result = summarize(image, json.loads(raw), catalog, metadata["VulnerabilityDB"]["UpdatedAt"])
                if catalog is None:
                    previous = read_record(image) or {}
                    if previous.get("kev") is not None:
                        result["previous_kev"] = {"ids": previous["kev"], "catalog": previous["catalog"]}
                    elif previous.get("previous_kev"):
                        result["previous_kev"] = previous["previous_kev"]
                result["scan_sha256"] = hashlib.sha256(raw).hexdigest()
                report.chmod(0o600)
                os.replace(report, CACHE / (image[7:] + ".trivy.json"))
                pending = Path(directory) / "summary.json"
                pending.write_text(json.dumps(result) + "\n")
                pending.chmod(0o600)
                os.replace(pending, CACHE / (image[7:] + ".json"))
            except (OSError, KeyError, ValueError, TypeError, subprocess.SubprocessError) as exc:
                failed = True
                print(f"{image[:19]} 스캔 실패 · {exc}", file=sys.stderr)
    return int(failed or catalog is None)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["show", "detail", "scan", "auto"])
    parser.add_argument("images", nargs="+")
    args = parser.parse_args()
    if not all(IMAGE_ID.fullmatch(image) for image in args.images):
        parser.error("실행 이미지의 전체 sha256 ID가 필요합니다.")
    if args.action in ("scan", "auto"):
        try:
            sys.exit(scan(args.images, background=args.action == "auto"))
        except (OSError, ValueError) as exc:
            sys.exit(str(exc))
    for image in args.images:
        print(inspect(image, args.action == "detail"))
