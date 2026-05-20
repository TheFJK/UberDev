#!/usr/bin/env python3
"""Aggregate per-agent YAML outputs in a scratch dir into wave-N.yaml.

Run:
    aggregate.py --run-id <id> --wave <N> --scratch-dir <path>
                 --invariants <path> --out <path>

Drops findings without invariant_violated or without any evidence anchor.
"""
import argparse
import glob
import hashlib
import os
import sys
import yaml


def stable_id(persona: str, invariant: str, location: str) -> str:
    return hashlib.sha256(f"{persona}::{invariant}::{location}".encode()).hexdigest()[:16]


def has_evidence(ev: dict) -> bool:
    if not isinstance(ev, dict):
        return False
    if ev.get("screenshot") or ev.get("dom_hash"):
        return True
    nr = ev.get("network_request") or {}
    if isinstance(nr, dict) and nr.get("url"):
        return True
    rs = ev.get("repro_steps") or []
    return isinstance(rs, list) and len(rs) > 0


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--run-id", required=True)
    p.add_argument("--wave", required=True, type=int)
    p.add_argument("--scratch-dir", required=True)
    p.add_argument("--invariants", required=True)
    p.add_argument("--out", required=True)
    args = p.parse_args()

    invariants = {i["id"] for i in yaml.safe_load(open(args.invariants))["invariants"]}

    findings = []
    cross_refs_in = []
    follow_ups = {}
    dispositions = []

    for path in sorted(glob.glob(os.path.join(args.scratch_dir, "*/*.yaml"))):
        try:
            doc = yaml.safe_load(open(path)) or {}
        except yaml.YAMLError as e:
            print(f"warning: skipping malformed {path}: {e}", file=sys.stderr)
            continue
        for f in doc.get("findings") or []:
            inv = f.get("invariant_violated")
            if inv not in invariants:
                continue
            if not has_evidence(f.get("evidence") or {}):
                continue
            persona = f.get("persona") or "unknown"
            location = f.get("location") or ""
            f["id"] = stable_id(persona, inv, location)
            findings.append(f)
        for cr in doc.get("cross_refs") or []:
            cross_refs_in.append(cr)
        for k, v in (doc.get("follow_ups_for_next_wave") or {}).items():
            follow_ups.setdefault(k, []).extend(v or [])
        for d in doc.get("dispositions") or []:
            dispositions.append(d)

    out = {
        "schema_version": 1,
        "wave": args.wave,
        "run_id": args.run_id,
        "findings": findings,
        "cross_refs": cross_refs_in,
        "follow_ups_for_next_wave": follow_ups,
        "dispositions": dispositions,
    }
    yaml.safe_dump(out, open(args.out, "w"), default_flow_style=False, sort_keys=False)
    print(f"aggregated {len(findings)} findings into {args.out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
