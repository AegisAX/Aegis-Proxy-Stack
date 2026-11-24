"""Apply a verified four-service release with a cold snapshot and durable recovery."""

import argparse
from copy import deepcopy
import fcntl
import importlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import uuid


backup = importlib.import_module("stack-backup")
BASE, STATE = backup.BASE, backup.STATE
JOURNAL = STATE / "stack-pending.json"
OVERRIDE = STATE / "images.json"
RELEASE = STATE / "release.json"
STEPS = backup.START
REQUIRED_HEALTH = {"db", "agent", "npm"}
SHA = re.compile(r"sha256:[0-9a-f]{64}")
REF = re.compile(r"[a-z0-9][a-z0-9./:_-]*@sha256:[0-9a-f]{64}")
require, docker = backup.require, backup.docker


def read_json(path):
    return json.loads(path.read_text())


def compose_config(command, *options):
    return docker(*command, "config", *options, capture_output=True).stdout


def model_command(model, project):
    return ["compose", "--project-directory", str(BASE), "-p", project, "-f", str(model)]


def work_dir(journal):
    name = journal["work"]
    require(re.fullmatch(r"stack-change\.[a-z0-9_]+", name), "전환 디렉터리 이름이 올바르지 않습니다.")
    path = STATE / name
    require(path.resolve() == path and path.is_dir() and path.stat().st_uid == os.getuid()
            and not path.stat().st_mode & 0o077, "전환 디렉터리를 확인하세요.")
    return path


def scoped_records(command):
    ids = docker(*command, "ps", "--all", "-q", capture_output=True).stdout.decode().split()
    if not ids:
        return {}
    records = backup.containers(ids)
    result = {row["Config"]["Labels"].get("com.docker.compose.service"): row for row in records}
    require(len(result) == len(records) and set(result) <= set(STEPS),
            "프로젝트에 예상하지 못한 컨테이너가 있습니다.")
    require(all(row["Config"]["Labels"].get("com.docker.compose.project.working_dir") == str(BASE)
                for row in records), "다른 설치 경로의 컨테이너가 있습니다.")
    return result


def start_stack(command, images, health):
    for service in STEPS:
        docker(*command, "up", "-d", "--no-deps", "--pull", "never", "--wait",
               "--wait-timeout", "75", service, timeout=110)
        records = scoped_records(command)
        require(service in records and records[service]["Image"] == images[service]
                and backup.healthy(records[service])
                and (service not in health or "Health" in records[service]["State"]),
                f"{service}의 이미지와 정상 상태를 확인하지 못했습니다.")
    verify_stack(command, images, health)


def verify_stack(command, images, health):
    records = scoped_records(command)
    require(set(records) == set(STEPS) and all(
        row["Image"] == images[service] and backup.healthy(row)
        and (service not in health or "Health" in row["State"])
        for service, row in records.items()), "배포 후 네 서비스의 이미지와 상태가 일치하지 않습니다.")

    npm = records["npm"]
    if npm["Config"]["Labels"].get("io.aegis.waf.scope") == "1":
        script = Path(__file__).with_name("wait-waf-ready.sh")
        docker("exec", "-i", npm["Id"], "sh", "-s", input=script.read_bytes(), timeout=140)


def config_state_paths(model):
    paths = {"aegis-data"}
    for settings in model["services"].values():
        for mount in settings.get("volumes", []):
            if mount["type"] != "bind":
                continue  # Any unexpected live volume has already been rejected by running_stack.
            source = Path(mount["source"])
            require(source == source.resolve() or source == Path("/etc/localtime"),
                    "Compose 바인드 경로에 심볼릭 링크가 있습니다.")
            if source.is_relative_to(BASE / "aegis-config") and not mount.get("read_only", False):
                require(source != BASE / "aegis-config" and source.exists(),
                        "설정 디렉터리 전체 또는 없는 경로를 쓸 수 있는 상태에서는 전환할 수 없습니다.")
                paths.add(str(source.relative_to(BASE)))
    selected = []
    for item in sorted(paths):
        if not any(Path(item).is_relative_to(Path(parent)) for parent in selected):
            selected.append(item)
    return selected


def fsync_dirs(*paths):
    for path in paths:
        fd = os.open(path, os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)


def rename(src, dst):
    os.rename(src, dst)
    fsync_dirs(src.parent, dst.parent)


def move_paths(work, paths, *, restore=False):
    for name in paths:
        live = BASE / name
        original = work / "original" / name
        candidate = work / "candidate" / name
        failed = work / "failed" / name
        if restore:
            if original.exists():
                if live.exists():
                    require(not failed.exists(), "보존할 후보 데이터와 기존 복구 파일이 충돌합니다.")
                    failed.parent.mkdir(parents=True, exist_ok=True)
                    rename(live, failed)
                rename(original, live)
        else:
            original.parent.mkdir(parents=True, exist_ok=True)
            rename(live, original)
            rename(candidate, live)


def check_override(work):
    previous = work / "override-before.json"
    existing = OVERRIDE.read_bytes() if OVERRIDE.is_file() else None
    require(not OVERRIDE.is_symlink()
            and existing in (previous.read_bytes() if previous.is_file() else None,
                             (work / "override-after.json").read_bytes()),
            "진행 중 이미지 오버라이드가 새로 수정되었습니다.")


def finish(journal, work, outcome):
    backup.write_json(work / "result.json", {**journal, "phase": outcome})
    JOURNAL.unlink()
    fsync_dirs(STATE)


def commit(journal, work):
    verify_stack(model_command(work / "next.json", journal["project"]), journal["target_ids"], set(STEPS))
    check_override(work)
    backup.write_json(OVERRIDE, read_json(work / "override-after.json"))
    version = journal.get("release")
    if version and re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", version):
        backup.write_json(RELEASE, {"version": version, "origin_commit": journal["origin_commit"]})
    finish(journal, work, "applied")
    print(f"스택 적용 완료 · 백업 {journal['snapshot']}", flush=True)


def recover(journal):
    work = work_dir(journal)
    check_override(work)
    if journal["phase"] == "committing":
        commit(journal, work)
        return
    if journal["phase"] == "stopping":
        backup.restart(journal, journal_path=None)
    else:
        require(journal["phase"] == "switching", "알 수 없는 복구 단계입니다.")
        command = model_command(work / "previous.json", journal["project"])
        paths = journal["paths"]
        require(paths == read_json(work / "paths.json"), "복구할 데이터 경로가 전환 기록과 다릅니다.")
        backup.stop_stack(scoped_records(command), strict=False)
        # Binding sources must exist again before Compose can start any service.
        move_paths(work, paths, restore=True)
        start_stack(command, journal["previous_ids"], REQUIRED_HEALTH)
    finish(journal, work, "rolled-back")
    print(f"이전 이미지와 전환 전 데이터를 복구했습니다 · 기록 {work}", flush=True)


def release_images(manifest, records):
    images = manifest["images"]
    require(manifest.get("strategy") == "stack-v1" and set(images) == set(STEPS),
            "stack-v1 릴리스에는 네 서비스가 필요합니다.")
    for service, row in images.items():
        require(REF.fullmatch(row["target"]) and SHA.fullmatch(row["target_id"])
                and row["from_id"] == records[service]["Image"], f"{service} 릴리스 이미지가 일치하지 않습니다.")
    return images


def runtime_hashes(command, model, records):
    result = compose_config(command, "--hash", "*")
    hashes = dict(line.split() for line in result.decode().splitlines())
    ipc = model["services"]["npm"].get("ipc")
    if ipc == "service:agent":
        # Compose hashes the concrete agent container namespace when creating NPM.
        expected = "container:" + records["agent"]["Id"]
        require(records["npm"]["HostConfig"]["IpcMode"] == expected,
                "NPM의 IPC가 실행 중인 에이전트와 연결되지 않았습니다.")
        with tempfile.TemporaryDirectory() as scratch:
            path = Path(scratch) / "runtime.json"
            backup.write_json(path, {"services": {"npm": {"ipc": expected}}})
            concrete = compose_config([*command, "-f", str(path)], "--hash", "npm")
            hashes.update(dict(line.split() for line in concrete.decode().splitlines()))
    return hashes


def preflight(manifest=None):
    records = backup.running_stack()
    images = release_images(manifest, records) if manifest is not None else {}
    command = backup.compose()
    raw_model = compose_config(command, "--format", "json")
    model = json.loads(raw_model)
    project = model["name"]
    require(set(model["services"]) == set(STEPS), "Compose 파일에 네 서비스 이외의 정의가 있습니다.")
    require(all("Health" in records[service]["State"] for service in REQUIRED_HEALTH),
            "DB·에이전트·NPM의 기존 헬스체크가 필요합니다.")
    hashes = runtime_hashes(command, model, records)
    require(all(records[service]["Config"]["Labels"].get("com.docker.compose.config-hash") == hashes.get(service)
                and records[service]["Config"]["Labels"].get("com.docker.compose.project") == project
                for service in STEPS), "현재 Compose 설정이 실행 컨테이너와 다릅니다. 실행 설정부터 대조하세요.")
    paths = config_state_paths(model)
    require(all((BASE / name).stat().st_dev == BASE.stat().st_dev for name in paths),
            "데이터와 업데이트 상태 디렉터리는 같은 파일시스템에 있어야 합니다.")
    for service, row in records.items():
        current_ref = model["services"][service]["image"]
        resolved_current = docker("image", "inspect", "--format", "{{.Id}}", current_ref,
                                  capture_output=True).stdout.decode().strip()
        require(resolved_current == row["Image"], f"{service}의 기존 이미지 참조가 실행 이미지와 다릅니다.")
    return records, images, command, raw_model, model, paths


def apply(manifest):
    records, images, command, raw_model, model, paths = preflight(manifest)
    project = model["name"]
    require(BASE.stat().st_dev == STATE.stat().st_dev,
            "데이터와 업데이트 상태 디렉터리는 같은 파일시스템에 있어야 합니다.")
    target_ids = {service: images[service]["target_id"] for service in STEPS}
    previous_ids = {service: records[service]["Image"] for service in STEPS}
    if target_ids == previous_ids:
        print("목표 이미지가 이미 실행 중입니다.")
        return
    for service in STEPS:
        target = images[service]["target"]
        docker("image", "pull", target, timeout=600)
        image = json.loads(docker("image", "inspect", target, capture_output=True).stdout)[0]
        require(image["Id"] == target_ids[service] and image["Os"] == "linux" and image["Architecture"] == "amd64",
                f"{service} 레지스트리 이미지가 검증된 Linux/amd64 ID와 다릅니다.")
        if service == "npm" and (image["Config"].get("Labels") or {}).get("io.aegis.waf.scope") == "1":
            # Exercise the candidate parser before taking the running stack offline.
            source = docker("exec", records["npm"]["Id"], "cat", "/ext/appsec/local_policy.yaml",
                            capture_output=True, timeout=15).stdout
            try:
                docker("run", "--rm", "-i", "--pull", "never", "--network", "none", "--read-only",
                       "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--entrypoint", "node",
                       target_ids["npm"], "/app/aegis-waf-scope.cjs", "validate-stdin",
                       input=source, capture_output=True, timeout=30)
            except subprocess.CalledProcessError as error:
                raise ValueError("설치된 WAF 정책을 선택한 릴리스에서 해석할 수 없습니다. "
                                 "서비스 중단 전에 업데이트를 중지했습니다.") from error
    for volume in model["services"]["log-rotator"].get("volumes", []):
        if volume["target"] == "/etc/logrotate.conf":
            baked = docker("run", "--rm", "--pull", "never", "--network", "none", "--read-only",
                           "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                           "--entrypoint", "cat", target_ids["log-rotator"],
                           "/usr/local/etc/aegis/logrotate.conf", capture_output=True, timeout=30).stdout
            require(Path(volume["source"]).read_bytes() == baked,
                    "기존 로그 순환 설정과 후보 이미지에 내장된 규칙이 다릅니다.")
    output, snapshot_paths = backup.prepare_snapshot(records, copies=2)
    require(output.stat().st_dev == STATE.stat().st_dev,
            "백업과 데이터가 같은 파일시스템에 있어야 여유 공간을 검증할 수 있습니다.")
    work = Path(tempfile.mkdtemp(prefix="stack-change.", dir=STATE))
    override = read_json(OVERRIDE) if OVERRIDE.is_file() else {}
    if OVERRIDE.is_file():
        backup.write_json(work / "override-before.json", override)
        # Compare verbatim bytes before replacing the persistent override.
        (work / "override-before.json").write_bytes(OVERRIDE.read_bytes())
    services = override.setdefault("services", {})
    for service in STEPS:
        services.setdefault(service, {}).update(image=images[service]["target"], pull_policy="never")
    services["log-rotator"].update(command=["crond", "-f", "-l", "8"],
        healthcheck={"test": ["CMD", "/usr/local/sbin/aegis-check-logrotate", "--health"],
                     "interval": "5s", "timeout": "8s", "retries": 5})
    backup.write_json(work / "override-after.json", override)
    require(compose_config(command, "--format", "json") == raw_model,
            "다운로드 중 Compose 구성이 바뀌었습니다.")
    # Rebuild the final override chain with the prepared file replacing the previous file.
    base_command = command[:-2] if OVERRIDE.is_file() else command
    target_model = json.loads(compose_config([*base_command, "-f", str(work / "override-after.json")],
                                             "--format", "json"))
    rollback_model = deepcopy(model)
    for service in STEPS:
        # Rollback uses immutable local IDs even if a previous tag gets retargeted.
        rollback_model["services"][service].update(image=previous_ids[service], pull_policy="never")
    backup.write_json(work / "paths.json", paths)
    for file, frozen in (("previous.json", rollback_model), ("next.json", target_model)):
        # Config JSON already escapes dollars for Compose interpolation on reload.
        backup.write_json(work / file, frozen)
        reload = json.loads(compose_config(model_command(work / file, project), "--format", "json"))
        require(reload == frozen, "Compose 재로딩 중 적용 또는 복구 구성이 변경되었습니다.")
    latest = backup.running_stack()
    require(all(latest[service]["Id"] == records[service]["Id"] for service in STEPS),
            "이미지 준비 중 컨테이너가 바뀌었습니다.")
    journal = dict(phase="stopping", work=work.name, project=project, paths=paths,
                   release=manifest["release"], origin_commit=manifest["from_commit"],
                   snapshot=str(output), token=uuid.uuid4().hex, previous_ids=previous_ids,
                   target_ids=target_ids, containers={name: row["Id"] for name, row in records.items()})
    backup.write_json(JOURNAL, journal)
    try:
        backup.stop_stack(latest)
        backup.write_archive(latest, output, snapshot_paths, journal["token"])
        backup.seal_snapshot(latest, output, snapshot_paths)
        backup.verify(output, work / "candidate", transaction=True)
        check_override(work)
        require(compose_config(command, "--format", "json") == raw_model,
                "서비스를 중지한 뒤 Compose 구성이 바뀌었습니다.")
        journal["phase"] = "switching"
        backup.write_json(JOURNAL, journal)
        move_paths(work, paths)
        start_stack(model_command(work / "next.json", project), target_ids, set(STEPS))
        journal["phase"] = "committing"
        backup.write_json(JOURNAL, journal)
        commit(journal, work)
    except (OSError, KeyError, ValueError, subprocess.SubprocessError):
        if JOURNAL.exists():
            recover(read_json(JOURNAL))
        raise


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("check")
    sub.add_parser("plan").add_argument("verified_manifest", type=Path)
    sub.add_parser("apply").add_argument("verified_manifest", type=Path)
    sub.add_parser("recover")
    args = parser.parse_args()
    if args.action == "check":
        preflight()
        return
    if args.action == "plan":
        preflight(read_json(args.verified_manifest))
        print("스택 사전 확인 완료 · 적용 전 이미지 검증 및 스냅샷 필요")
        return
    STATE.mkdir(mode=0o700, exist_ok=True)
    require(STATE.resolve() == STATE and STATE.stat().st_uid == os.getuid()
            and not STATE.stat().st_mode & 0o077, "업데이트 상태 디렉터리는 계정 전용이어야 합니다.")
    with (STATE / "lock").open("a") as lock:
        backup.LOCK_FD = lock.fileno()
        try:
            fcntl.flock(backup.LOCK_FD, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("다른 배포 또는 Docker 작업이 끝난 뒤 복구를 다시 실행하세요.") from error
        require(not backup.JOURNAL.exists() and not (STATE / "pending.json").exists(),
                "다른 업데이트의 복구를 먼저 완료하세요.")
        if args.action == "recover":
            recover(read_json(JOURNAL))
        else:
            require(not JOURNAL.exists(), "이전 전환 복구 기록이 있습니다.")
            apply(read_json(args.verified_manifest))


if __name__ == "__main__":
    def interrupted(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (OSError, KeyError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        remaining = f" · 복구 기록 {JOURNAL}" if JOURNAL.exists() else ""
        sys.exit(f"스택 업데이트 중단 · {error}{remaining}")
