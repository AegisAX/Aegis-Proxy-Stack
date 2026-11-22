"""Render a local QA report for the exact agent, NPM and upstream image combination."""
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

DIGEST = re.compile(r"sha256:[0-9a-f]{64}")
VERSION = re.compile(r"[0-9]+(?:\.[0-9]+){1,3}(?:-r[0-9]+)?")
LABELS = {
    "initial": "15분 관찰 중", "long": "48시간 관찰 중",
    "finalizing": "관찰 종료 · 최종 보안 점검 중",
    "rehearsing": "48시간 관찰 통과 · 최종 메뉴 전환 시험 중",
    "passed": "48시간 관찰·최종 점검·메뉴 전환 시험 통과",
    "failed": "검증 실패", "interrupted": "관찰 중단",
    "review": "추가 검토 필요",
}
REASONS = {
    "health": "정상 요청 또는 작업자 연속성 확인 필요",
    "scan": "최종 패키지 검사 결과 확인 필요",
    "menu": "메뉴 전환 시험 기록 확인 필요",
    "archive": "후보 이미지와 보관 파일의 무결성 확인 필요",
    "source": "공급자 이미지가 변경되어 재검증 필요",
    "record": "시험 기록 확인 필요",
    "interrupted": "연속 관찰 기록이 끊어짐",
    "cleanup": "시험 환경 정리 확인 필요",
}

def timestamp(value):
    value = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if value.utcoffset() is None:
        raise ValueError("timezone missing")
    return value

def render(report, current, npm, upstream, now):
    if report.get("schema") != 1 or report.get("kind") != "agent-security-observation":
        raise ValueError("schema")
    ids = [report[key] for key in ("current_id", "candidate_id", "npm_id", "upstream_digest")]
    allowed_current = ids[:2]
    parent = report.get("parent_id")
    if report.get("profile") == "geo-cache" and isinstance(parent, str) and DIGEST.fullmatch(parent):
        allowed_current.append(parent)
    if not all(DIGEST.fullmatch(v) for v in ids) or current not in allowed_current or npm != ids[2] or upstream not in (ids[3], "-"):
        raise ValueError("image combination")
    phase = report["phase"]
    detail = LABELS[phase]
    ok, bad = report["http_ok"], report["http_bad"]
    if any(type(v) is not int or v < 0 for v in (ok, bad)):
        raise ValueError("request counts")
    age = (now - timestamp(report["observed_at"])).total_seconds()
    if phase in ("initial", "long") and not 0 <= age <= 120:
        phase, detail = "review", "관찰 기록 갱신 중단"
    elif phase == "finalizing" and (now - timestamp(report["reported_at"])).total_seconds() > 1200:
        phase, detail = "review", "최종 보안 점검 기록 갱신 중단"
    elif phase == "rehearsing" and not 0 <= (now - timestamp(report["reported_at"])).total_seconds() <= 3000:
        phase, detail = "review", "메뉴 전환 시험 기록 갱신 중단"
    elif phase in ("initial", "long", "passed") and bad:
        phase, detail = "review", "관찰 중 요청 실패"
    reason = REASONS.get(report.get("reason"))
    if phase in ("review", "failed", "interrupted") and reason and reason != detail:
        detail += " · " + reason
    profile = report.get("profile", "parsers")
    components = {
        "parsers": (("PCRE2", "pcre2"), ("libxml2", "libxml2")),
        "geo-cache": (("Hiredis", "hiredis"), ("libmaxminddb", "maxminddb")),
    }[profile]
    parts = []
    for name, key in components:
        version = report["runtime"][key]
        if not VERSION.fullmatch(version):
            raise ValueError("package version")
        parts.append(f"{name} {version}")
    heading = "실행 중인 보안 후보" if current == ids[1] else "에이전트 보안 후보"
    if profile == "geo-cache" and current != ids[1]:
        heading = "후속 에이전트 후보"
    state = "REVIEW"
    if phase in ("initial", "long", "finalizing", "rehearsing"):
        state = "TESTING"
    elif phase == "passed":
        state = "OBSERVED"
    if "from_version" in report and "to_version" in report:
        before, after = report["from_version"], report["to_version"]
        if not VERSION.fullmatch(before) or not VERSION.fullmatch(after):
            raise ValueError("agent version")
        if current == ids[1] or current == parent:
            heading = f"{heading} {after}"
        else:
            heading = f"{heading} {before} → {after}"
    if upstream == "-":
        state = "REVIEW"
        detail += " · 현재 공급자 조회 실패"
    lines = [state, f"{heading} · {detail}", " · ".join(parts)]
    counts = f"관찰 요청 {ok:,}건 성공 · {bad:,}건 실패"
    if phase in ("initial", "long"):
        finish = timestamp(report["expected_finish_at"]).astimezone()
        counts += " · 종료 예정 " + finish.strftime("%m/%d %H:%M %Z")
    lines.append(counts)
    runtime = report["runtime"]
    if profile == "parsers" and all(key in runtime for key in ("zlib", "brotli", "openssl", "curl")):
        inherited = []
        for key, name in (("zlib","zlib"), ("brotli","Brotli"), ("openssl","OpenSSL"), ("curl","libcurl")):
            if not VERSION.fullmatch(runtime[key]):
                raise ValueError("runtime version")
            inherited.append(f"{name} {runtime[key]}")
        lines.append(" · ".join(inherited))
    compat = report.get("compatibility", {})
    missing = [name for key, name in (("ntlm","NTLM"),("tls_srp","TLS-SRP"),("smb","SMB/SMBS"))
               if compat.get(key) is False]
    if profile == "parsers" and missing:
        lines.append("이 후보에서 미지원 · " + " · ".join(missing))
    history = []
    phases = {"initial":"관찰 중", "long":"관찰 중", "complete":"완료", "failed":"실패", "interrupted":"중단", "stale":"갱신 중단", "unknown":"미확인"}
    for item in report.get("previous", []):
        if item.get("name") in ("Brotli", "TLS", "zlib") and item.get("phase") in phases:
            history.append(f'{item["name"]} {phases[item["phase"]]}')
    if history:
        lines.append("이전 후보 · " + " / ".join(history))
    return lines

def main():
    report_file, current, npm, upstream = sys.argv[1:]
    try:
        with Path(report_file).open("rb") as stream:
            data = stream.read(32769)
        if len(data) > 32768:
            return 1
        lines = render(json.loads(data), current, npm, upstream, datetime.now(timezone.utc))
    except (OSError, ValueError, KeyError, TypeError, AttributeError, OverflowError):
        return 1
    print("\n".join(lines))
    return 0

if __name__ == "__main__":
    sys.exit(main())
