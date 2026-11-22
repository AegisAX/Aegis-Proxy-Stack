"""Create and verify an offline snapshot of the four-service Aegis deployment."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
from datetime import datetime, timezone


BASE = Path(os.environ.get("AEGIS_INSTALL_ROOT") or Path(__file__).resolve().parents[2]).resolve()
COMPOSE_FILE = Path(os.environ.get("AEGIS_COMPOSE_FILE") or BASE / "docker-compose.yml")
STATE = BASE / ".aegis-update"
JOURNAL = STATE / "backup-pending.json"
ROOTS = ("aegis-data", "aegis-config", ".env", "docker-compose.yml")
OVERRIDES = ("docker-compose.override.yml", ".aegis-update/images.json")
OPTIONAL = (*OVERRIDES, ".aegis-update/release.json")
START = ("db", "agent", "npm", "log-rotator")
STOP = ("log-rotator", "npm", "agent", "db")
ID = re.compile(r"[0-9a-f]{64}")
TAR = ("--numeric-owner", "--acls", "--xattrs")
LOCK_FD = None


def require(condition, message):
    if not condition:
        raise ValueError(message)


def docker(*args, **kwargs):
    if LOCK_FD is not None:
        kwargs["pass_fds"] = (LOCK_FD,)
    return subprocess.run(["docker", *args], check=True, **kwargs)


def compose():
    command = ["compose", "--project-directory", str(BASE), "--env-file", str(BASE / ".env"),
               "-f", str(COMPOSE_FILE)]
    for extra in OVERRIDES:
        if (BASE / extra).is_file():
            command.extend(("-f", str(BASE / extra)))
    return command


def containers(ids):
    return json.loads(docker("inspect", "--type", "container", *ids, capture_output=True).stdout)


def running_stack():
    ids = docker(*compose(), "ps", "--all", "-q", capture_output=True).stdout.decode().split()
    require(len(ids) == len(START), "이 백업은 NPM·DB·에이전트·log 네 서비스에 적용됩니다.")
    records = containers(ids)
    records = {r["Config"]["Labels"]["com.docker.compose.service"]: r for r in records}
    require(set(records) == set(START), "Compose 서비스 구성이 다릅니다.")
    require(all(r["State"]["Running"] and r["State"].get("Health", {}).get("Status") in (None, "healthy")
                for r in records.values()), "서비스가 모두 정상인 상태에서 백업을 시작하세요.")
    for record in records.values():
        for mount in record["Mounts"]:
            source = Path(mount.get("Source", "")).resolve()
            if mount["Type"] == "tmpfs" or (source == Path("/etc/localtime").resolve()
                                            and mount["Destination"] == "/etc/localtime"):
                continue
            require(mount["Type"] == "bind" and
                    any(source.is_relative_to(BASE / name) for name in (*ROOTS[:2], "aegis-logs")),
                    "프로젝트 밖 경로 또는 볼륨이 연결되어 있습니다. 별도 백업을 준비하세요.")
    require(any(m["Destination"] == "/var/lib/mysql"
                and Path(m["Source"]).resolve() == BASE / "aegis-data/db"
                for m in records["db"]["Mounts"]), "기존 MariaDB 데이터 경로를 확인하세요.")
    for mount in records["log-rotator"]["Mounts"]:
        if mount["Type"] == "bind" and mount["RW"]:
            source = Path(mount["Source"]).resolve()
            require(source.is_relative_to(BASE / "aegis-logs")
                    or source == BASE / "aegis-config/logrotate/aegis-rotate.conf",
                    "log 서비스에 추가 쓰기 경로가 있어 안전한 정지를 확인할 수 없습니다.")
    protected = [BASE / name for name in ROOTS[:2]]
    all_running = docker("ps", "-q", "--no-trunc", capture_output=True).stdout.decode().split()
    outside = set(all_running) - {row["Id"] for row in records.values()}
    for other in containers(sorted(outside)) if outside else ():
        for mount in other["Mounts"]:
            if mount["Type"] == "bind" and mount["RW"]:
                source = Path(mount["Source"]).resolve()
                require(not any(root.is_relative_to(source) or source.is_relative_to(root) for root in protected),
                        "다른 실행 컨테이너에 백업 경로의 쓰기 권한이 있습니다.")
    return records


def write_json(path, data):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as tmp:
        json.dump(data, tmp, indent=2)
        tmp.write("\n")
        tmp.flush()
        os.fsync(tmp.fileno())
    os.replace(tmp.name, path)
    fd = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def healthy(record):
    state = record["State"]
    return state["Running"] and state.get("Health", {}).get("Status") in (None, "healthy")


def restart(journal, journal_path=JOURNAL):
    ids = journal["containers"]
    require(set(ids) == set(START) and all(ID.fullmatch(value) for value in ids.values()),
            "복구 기록의 컨테이너 ID가 유효하지 않습니다.")
    snapshot = {r["Id"]: r for r in containers(list(ids.values()))}
    for service in START:
        record = snapshot[ids[service]]
        require(record["Config"]["Labels"].get("com.docker.compose.service") == service and
                record["Config"]["Labels"].get("com.docker.compose.project.working_dir") == str(BASE),
                "복구 기록이 이 설치의 컨테이너와 일치하지 않습니다.")
    helpers = docker("ps", "--all", "-q", "--filter", "label=aegis.backup=" + journal["token"],
                     capture_output=True).stdout
    require(not helpers.strip(), "백업 프로세스가 아직 종료되지 않았습니다.")
    for service in START:
        ident = ids[service]
        if not snapshot[ident]["State"]["Running"]:
            docker("start", ident, stdout=subprocess.DEVNULL, timeout=60)
        deadline = time.monotonic() + 120
        while not healthy(containers([ident])[0]):
            require(time.monotonic() < deadline, f"{service}가 복구 후 정상 상태에 도달하지 못했습니다.")
            time.sleep(1)
    if journal_path is not None:
        journal_path.unlink()


def tar_command(image, directory, mount_mode):
    require(image.startswith("sha256:") and ID.fullmatch(image[7:]), "보관 도구 이미지 ID가 유효하지 않습니다.")
    require("," not in str(directory) and "\n" not in str(directory), "백업 경로에 쉼표 또는 줄바꿈을 사용할 수 없습니다.")
    return ["run", "--rm", "--pull", "never", "--network", "none", "--read-only",
            "--security-opt", "no-new-privileges", "--cap-drop", "ALL", "--cap-add", "DAC_OVERRIDE",
            "--cap-add", "CHOWN", "--cap-add", "FOWNER", "--cap-add", "FSETID", "--entrypoint", "/bin/tar",
            "--mount", f"type=bind,source={directory},target=/snapshot{mount_mode}",
            "--user", "0:0"]


def digest(stream):
    stream.seek(0)
    value = hashlib.sha256()
    for block in iter(lambda: stream.read(1024 * 1024), b""):
        value.update(block)
    stream.seek(0)
    return value.hexdigest()


def validate_archive(stream, paths):
    seen = set()
    links = set()
    with tarfile.open(fileobj=stream, mode="r|gz") as archive:
        for item in archive:
            name = PurePosixPath(item.name)
            require(not name.is_absolute() and ".." not in name.parts and name not in seen
                    and any(name.is_relative_to(PurePosixPath(root)) for root in paths)
                    and not any(parent in links for parent in name.parents)
                    and (item.isfile() or item.isdir() or item.issym() or item.islnk()),
                    "백업 파일에 허용되지 않는 경로 또는 유형이 있습니다.")
            if item.islnk() or item.issym():
                target = item.linkname if item.islnk() else f"{name.parent}/{item.linkname}"
                resolved = PurePosixPath(posixpath.normpath(target))
                require(not item.linkname.startswith("/")
                        and any(resolved.is_relative_to(PurePosixPath(root)) for root in paths)
                        and (not item.islnk() or (resolved in seen and resolved not in links)),
                        "백업 파일의 링크가 허용된 경로를 벗어납니다.")
                links.add(name)
            seen.add(name)
    require(all(PurePosixPath(path) in seen for path in paths), "백업 파일에 필수 경로가 없습니다.")
    stream.seek(0)


def prepare_snapshot(records, copies=1):
    paths = [*ROOTS, *(name for name in OPTIONAL if (BASE / name).is_file())]
    require(all((BASE / name).exists() and (BASE / name).resolve() == BASE / name for name in paths),
            "백업 대상이 없거나 심볼릭 링크를 사용합니다.")
    image = records["npm"]["Image"]
    version = docker("run", "--rm", "--pull", "never", "--network", "none", "--entrypoint", "/bin/tar",
                     image, "--version", capture_output=True, timeout=30).stdout
    require(b"GNU tar" in version, "기존 NPM 이미지에 GNU tar가 필요합니다.")
    root = BASE / "backups"
    root.mkdir(mode=0o700, exist_ok=True)
    require(root.resolve() == root and root.stat().st_uid == os.getuid()
            and not root.stat().st_mode & 0o077, "backups는 현재 계정의 전용 디렉터리(0700)여야 합니다.")
    size_command = tar_command(image, BASE, ",readonly")
    size_command[size_command.index("/bin/tar")] = "/usr/bin/du"
    disk_size = docker(*size_command, image, "--apparent-size", "--summarize", "--total",
                       "--block-size=1", *(f"/snapshot/{name}" for name in paths),
                       capture_output=True, timeout=120).stdout.decode().splitlines()[-1].split()[0]
    minimum = int(disk_size) * copies * 11 // 10 + 128 * 1024**2
    require(shutil.disk_usage(root).free >= minimum, "중단 전 여유 공간 점검에 실패했습니다.")
    output = Path(tempfile.mkdtemp(prefix=datetime.now(timezone.utc).strftime("stack-%Y%m%dT%H%M%SZ-"), dir=root))
    return output, paths


def stop_stack(records, strict=True):
    for service in STOP:
        if service not in records:
            continue
        ident = records[service]["Id"]
        if not records[service]["State"]["Running"]:
            continue
        # BusyBox crond can ignore SIGTERM as PID 1. Its writes are to excluded logs.
        grace = "3" if service == "log-rotator" else "30"
        docker("stop", "--time", grace, ident, stdout=subprocess.DEVNULL, timeout=60)
        state = containers([ident])[0]["State"]
        clean = not state["OOMKilled"] and (service == "log-rotator" or state["ExitCode"] != 137)
        require(not state["Running"] and (not strict or (clean and (service != "db" or state["ExitCode"] == 0))),
                f"{service} 정상 종료를 확인하지 못했습니다.")


def write_archive(records, output, paths, token):
    archive_path = output / "data.tar.gz"
    with archive_path.open("xb") as stream:
        docker(*tar_command(records["npm"]["Image"], BASE, ",readonly"), "--label", "aegis.backup=" + token,
               records["npm"]["Image"], *TAR, "-czf", "-", "-C", "/snapshot", *(f"./{name}" for name in paths),
               stdout=stream)
        stream.flush()
        os.fsync(stream.fileno())


def seal_snapshot(records, output, paths, downtime=None):
    archive_path = output / "data.tar.gz"
    with archive_path.open("rb") as stream:
        checksum = digest(stream)
        validate_archive(stream, paths)
    metadata = {"schema": 1, "files": paths, "sha256": checksum, "bytes": archive_path.stat().st_size,
                "images": {name: records[name]["Image"] for name in START}, "stop_to_healthy_seconds": downtime}
    if COMPOSE_FILE != BASE / "docker-compose.yml":
        effective = COMPOSE_FILE.read_bytes()
        (output / "compose-baseline.yml").write_bytes(effective)
        metadata["compose_baseline_sha256"] = hashlib.sha256(effective).hexdigest()
    write_json(output / "snapshot.json", metadata)


def backup():
    records = running_stack()
    output, paths = prepare_snapshot(records)
    token = uuid.uuid4().hex
    journal = {"token": token, "containers": {name: records[name]["Id"] for name in START}}
    write_json(JOURNAL, journal)
    started = time.monotonic()
    try:
        stop_stack(records)
        write_archive(records, output, paths, token)
    finally:
        restart(journal)
    downtime = round(time.monotonic() - started, 2)
    # The services can accept traffic before the saved archive is checked and published.
    seal_snapshot(records, output, paths, downtime)
    print(f"백업 검증 완료 · 서비스 중단부터 정상 상태까지 {downtime:.2f}초 · {output}")


def verify(directory, destination=None, *, transaction=False):
    directory = directory.resolve()
    require(directory.is_dir() and directory.stat().st_uid == os.getuid()
            and not directory.stat().st_mode & 0o077, "백업 디렉터리는 현재 계정 전용이어야 합니다.")
    metadata = json.loads((directory / "snapshot.json").read_text())
    paths = metadata["files"]
    require(metadata["schema"] == 1 and paths[:len(ROOTS)] == list(ROOTS)
            and len(paths) == len(set(paths)) and all(path in (*ROOTS, *OPTIONAL) for path in paths),
            "백업 메타데이터가 올바르지 않습니다.")
    effective = None
    if "compose_baseline_sha256" in metadata:
        effective = (directory / "compose-baseline.yml").read_bytes()
        require(hashlib.sha256(effective).hexdigest() == metadata["compose_baseline_sha256"],
                "백업에 기록한 Compose 기준 파일의 SHA-256이 일치하지 않습니다.")
    with (directory / "data.tar.gz").open("rb") as stream:
        require(os.fstat(stream.fileno()).st_size == metadata["bytes"]
                and digest(stream) == metadata["sha256"], "보관 파일 크기 또는 SHA-256 불일치")
        validate_archive(stream, paths)
        if destination:
            target = destination.resolve()
            require(transaction or not target.is_relative_to(BASE), "실행 중인 설치와 분리된 새 복원 경로를 지정하세요.")
            target.mkdir(mode=0o700)
            image = metadata["images"]["npm"]
            docker(*tar_command(image, target, ""), "-i", image, *TAR, "--same-owner",
                   "--same-permissions", "-xzf", "-", "-C", "/snapshot", stdin=stream)
            if effective is not None:
                (target / "docker-compose.yml").write_bytes(effective)
            print(f"격리 경로에 복원 완료 · {target}")
        else:
            print(f"백업 무결성 확인 · {directory}")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("check")
    sub.add_parser("backup")
    sub.add_parser("resume")
    sub.add_parser("verify").add_argument("snapshot", type=Path)
    extract = sub.add_parser("extract")
    extract.add_argument("snapshot", type=Path)
    extract.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.action == "check":
        running_stack()
        return
    if args.action in ("verify", "extract"):
        verify(args.snapshot, getattr(args, "destination", None))
        return
    STATE.mkdir(mode=0o700, exist_ok=True)
    require(STATE.resolve() == STATE and STATE.stat().st_uid == os.getuid(),
            "배포 상태 경로를 확인하세요.")
    with (STATE / "lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == "resume":
            restart(json.loads(JOURNAL.read_text()))
            print("백업 전 컨테이너 재시작 및 정상 상태 확인 완료")
        else:
            require(not JOURNAL.exists() and not (STATE / "pending.json").exists()
                    and not (STATE / "stack-pending.json").exists(),
                    "중단된 백업 또는 업데이트의 복구 기록을 먼저 확인하세요.")
            backup()


if __name__ == "__main__":
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (OSError, KeyError, ValueError, tarfile.TarError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        sys.exit(f"스택 백업 작업 중단 · {error}" +
                 (f" · 복구 기록 {JOURNAL}" if JOURNAL.exists() else ""))
