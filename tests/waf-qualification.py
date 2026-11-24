#!/usr/bin/env python3
"""Check that both publication workflows reject missing or mismatched WAF evidence."""
import copy
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
IDS = {s: f"sha256:{i:064x}" for i, s in enumerate(("npm", "agent", "db", "log"), 1)}

def sample(phase):
    rows = []
    for host in ("prevent", "detect", "off"):
        held = host == "prevent" and phase in {"cold", "unavailable"}
        for method in ("GET", "POST"):
            rows.append(dict(host=host, method=method, path="/health-probe",
                             status=503 if held else 200, visits=0 if held else 1))
    if phase != "cold":
        rows.append(dict(host="prevent", method="GET", path="/policy-deny-probe",
                         status=503 if phase == "unavailable" else 403, visits=0))
    return {"scenario": phase, "rows": rows}

def main():
    manifest = {"images": {("log-rotator" if k == "log" else k): {"target_id": v}
                           for k, v in IDS.items()}}
    baseline = dict(phase="complete", cleanup="complete", samples=241, images=IDS,
                    started_at="2026-11-24T00:00:00Z", ended_at="2026-11-24T04:00:00Z",
                    scheduled_archives={"npm": 1, "waf": 1})
    evidence = dict(schema=1, policy_source="installed",
                    images={k: IDS[k] for k in ("agent", "npm")},
                    body_interruption={"status":503, "visits":0},
                    policy_change=dict(prevent=201,detect=200,pending_checked=True,restored=True,
                                       connected_workers=16,rechecks=[dict(prevent=200,detect=200)]),
                    samples=[sample(p) for p in ("cold","ready","unavailable","recovered","recovered")])
    with tempfile.TemporaryDirectory() as directory:
        manifest_file = Path(directory) / "manifest.json"
        manifest_file.write_text(json.dumps(manifest))
        def accepted(receipt):
            result = subprocess.run(["jq", "-e", "--slurpfile", "manifest", str(manifest_file),
                                     "-f", str(ROOT/"aegis-config/scripts/qualify-release.jq")],
                                    input=json.dumps(receipt), text=True, capture_output=True)
            return result.returncode == 0
        assert not accepted(baseline)
        assert accepted(dict(baseline,waf_availability=evidence))
        for mutate in (
            lambda e: e.update(policy_source="manual"),
            lambda e: e["body_interruption"].update(visits=1),
            lambda e: e["policy_change"].update(pending_checked=False),
            lambda e: e["policy_change"].update(connected_workers=0),
            lambda e: e["policy_change"].update(rechecks=[]),
            lambda e: e["policy_change"]["rechecks"][0].update(detect=503),
            lambda e: e["images"].update(npm=IDS["db"]),
            lambda e: e["samples"].pop(),
            lambda e: e["samples"][2]["rows"].pop(),
            lambda e: e["samples"][0]["rows"][0].update(visits=1),
            lambda e: e["samples"][2]["rows"][1].update(status=200),
            lambda e: e["samples"][3]["rows"][0].update(status=503),
            lambda e: e["samples"][1]["rows"][-1].update(status=503),
        ):
            invalid = copy.deepcopy(evidence)
            mutate(invalid)
            assert not accepted(dict(baseline,waf_availability=invalid))
    print("WAF qualification checks passed")

if __name__ == "__main__":
    main()
