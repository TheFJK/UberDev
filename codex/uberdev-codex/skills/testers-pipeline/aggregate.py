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
import subprocess
import sys
import yaml


def stable_id(persona: str, invariant: str, location: str) -> str:
    return hashlib.sha256(f"{persona}::{invariant}::{location}".encode()).hexdigest()[:16]


def has_evidence(ev) -> bool:
    # Explicit type guard: a persona returning evidence as a string or list
    # (instead of the documented dict shape) is a schema violation, not a
    # silent miss. Raise so the aggregator surfaces the bad input rather
    # than dropping the finding without a trace.
    if ev is None:
        return False
    if not isinstance(ev, dict):
        raise ValueError(
            f"evidence must be a dict per SKILL.md schema; got {type(ev).__name__}"
        )
    if ev.get("screenshot") or ev.get("dom_hash"):
        return True
    nr = ev.get("network_request") or {}
    if isinstance(nr, dict) and nr.get("url"):
        return True
    rs = ev.get("repro_steps") or []
    return isinstance(rs, list) and len(rs) > 0


def load_invariants(path: str) -> set:
    """Load the invariant-ID set from an invariants.yaml. Fails loud on any
    I/O, parse, or schema problem so a misconfigured run does not silently
    drop every finding."""
    try:
        with open(path) as fh:
            doc = yaml.safe_load(fh)
    except FileNotFoundError:
        print(f"error: invariants file not found: {path}", file=sys.stderr)
        sys.exit(2)
    except PermissionError as e:
        print(f"error: cannot read invariants file {path}: {e}", file=sys.stderr)
        sys.exit(2)
    except yaml.YAMLError as e:
        print(f"error: malformed invariants YAML {path}: {e}", file=sys.stderr)
        sys.exit(2)
    if not isinstance(doc, dict) or not isinstance(doc.get("invariants"), list):
        print(
            f"error: invariants file {path} missing top-level 'invariants:' list",
            file=sys.stderr,
        )
        sys.exit(2)
    try:
        return {i["id"] for i in doc["invariants"]}
    except (KeyError, TypeError) as e:
        print(
            f"error: invariants file {path} has entries without an 'id' field: {e}",
            file=sys.stderr,
        )
        sys.exit(2)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--run-id", required=True)
    p.add_argument("--wave", required=True, type=int)
    p.add_argument("--scratch-dir", required=True)
    p.add_argument("--invariants", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--rps-cap", required=True, type=int)
    # RFC 0012 §3.10: pass A of the per-wave double-aggregate runs WITHOUT the
    # politeness audit. The audit re-globs scratch and REBUILDS the wave file,
    # so an audited pass A's synthetic polite_rate_cap row would be regenerated
    # (not deduped) by pass B and the breach would double-fire. Pass B is the
    # SOLE authoritative audit; pass A passes --no-audit and exits 0 right after
    # writing the wave file. (Default off preserves the legacy single-pass
    # SKILL.md path and every existing test invocation unchanged.)
    p.add_argument("--no-audit", action="store_true",
                   help="skip the post-hoc politeness audit (pass A of the "
                        "RFC 0012 §3.10 double-aggregate; pass B is authoritative)")
    args = p.parse_args()

    invariants = load_invariants(args.invariants)

    findings = []
    cross_refs_in = []
    follow_ups = {}
    dispositions = []

    for path in sorted(glob.glob(os.path.join(args.scratch_dir, "*/*.yaml"))):
        try:
            with open(path) as fh:
                doc = yaml.safe_load(fh) or {}
        except yaml.YAMLError as e:
            print(f"warning: skipping malformed {path}: {e}", file=sys.stderr)
            continue
        for f in doc.get("findings") or []:
            inv = f.get("invariant_violated")
            if inv not in invariants:
                continue
            try:
                keep = has_evidence(f.get("evidence") or {})
            except ValueError as e:
                # Persona output is untrusted free-form agent YAML; a finding
                # emitting evidence as a truthy non-dict (string/list) is an
                # expected schema deviation, not a fatal condition. Mirror the
                # malformed-YAML skip-and-continue above: log this one offender
                # and drop it (per SKILL.md's drop-contract for evidence-less
                # findings) so a single bad agent can't crash the aggregation
                # and discard the valid findings from the rest of the wave.
                print(f"warning: skipping finding with non-dict evidence in {path} "
                      f"(location={f.get('location') or '?'}, invariant={inv}): {e}",
                      file=sys.stderr)
                continue
            if not keep:
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
    with open(args.out, "w") as fh:
        yaml.safe_dump(out, fh, default_flow_style=False, sort_keys=False)
    print(f"aggregated {len(findings)} findings into {args.out}", file=sys.stderr)

    if args.no_audit:
        # Pass A of the RFC 0012 §3.10 double-aggregate: wave file written, no
        # audit. The monitor wave then reads this file; pass B re-aggregates
        # WITH the audit and is the single source of truth for politeBreach.
        return 0

    plugin_root = os.environ.get("PLUGIN_ROOT")
    if not plugin_root:
        print("error: PLUGIN_ROOT unset; cannot source lib/rate-cap-audit.sh", file=sys.stderr)
        return 2
    audited_path = f"{args.out}.audited"
    audit_proc = subprocess.run(
        ["bash", "-c",
         f". \"{plugin_root}/lib/rate-cap-audit.sh\" && "
         f"uberdev_rate_cap_audit \"{args.out}\" \"{args.rps_cap}\" \"{audited_path}\""],
        capture_output=True, text=True,
    )
    if audit_proc.returncode == 1:
        # breach: replace wave file with audited version. The audit script always writes
        # before exiting 1 (see lib/rate-cap-audit.sh), so a missing .audited here means
        # the subprocess died before the write — surface that as exit 2 rather than crash.
        if not os.path.exists(audited_path):
            print(f"error: rate-cap-audit exited 1 but {audited_path} was not written; "
                  f"stderr: {audit_proc.stderr}", file=sys.stderr)
            return 2
        os.replace(audited_path, args.out)
        print(f"warning: --rps-cap={args.rps_cap} exceeded; polite_rate_cap finding added to {args.out}",
              file=sys.stderr)
        return 1
    elif audit_proc.returncode == 0:
        # no breach; cleanup the audited tmpfile if it was written
        if os.path.exists(audited_path):
            os.remove(audited_path)
        return 0
    else:
        print(f"error: rate-cap-audit failed: {audit_proc.stderr}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
