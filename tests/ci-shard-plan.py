#!/usr/bin/env python3
"""Deterministic LPT bin-pack: which fixtures belong to which CI shard.

`.github/workflows/test.yml` runs one sequential loop over ~130 fixtures per
job. Split naively — round-robin, or alphabetically — the shards do NOT even
out, because the cost distribution is extremely skewed: the top 5 fixtures are
44% of the wall time and the slowest single one is 16%. This packs by measured
weight instead, longest-processing-time-first, which is the standard 4/3-optimal
greedy for makespan.

CONTRACT

  stdin   the job's fixture list, one `<name>.test.sh` per line, in any order
  args    --shards N --shard K   (K is 1-based)
  stdout  the fixtures assigned to shard K, one per line, in stdin order

Determinism is the whole point: every shard of a run computes the SAME pack from
the SAME inputs, so their union is the input set and their intersection is empty
without any shard having to coordinate with another. Ties break on the fixture
name, so an unmeasured fixture cannot make the pack depend on stdin ordering.

The weights file is a HINT and never a gate. A fixture absent from it packs at
DEFAULT_WEIGHT and still runs. Completeness is asserted against the workflow's
own list by tests/ci-wiring.test.sh W13 — never against the weights, which would
make a stale weights file silently drop a test.

Exits non-zero on anything it cannot do. The caller must NOT paper over that:
a shard that cannot compute its plan has to fail loudly, because the fail-open
direction (run everything) turns a broken pack into a silent 6x cost, and the
fail-closed direction (run nothing) turns it into a silent green.
"""

import argparse
import os
import sys

# What an unmeasured fixture is assumed to cost. Deliberately above the median
# (2s) and below the mean (10s): a new fixture is more likely to be cheap than
# expensive, but assuming it is free would let a slow newcomer land entirely in
# one shard and unbalance the pack until someone refreshed the weights.
DEFAULT_WEIGHT = 5

WEIGHTS_FILENAME = "ci-shard-weights.tsv"


def load_weights(path):
    """`seconds<TAB>fixture` rows; blank lines and `#` comments ignored.

    A malformed row is a refusal rather than a skip. This file is generated from
    a CI log, so a row this parser cannot read means the generator changed shape
    — and silently ignoring it would quietly move a fixture to DEFAULT_WEIGHT
    and unbalance the pack with nothing to point at.
    """
    weights = {}
    if not os.path.exists(path):
        return weights
    with open(path, encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, start=1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) != 2 or not parts[1].strip():
                sys.exit(f"ci-shard-plan: {path}:{lineno}: expected 'seconds<TAB>fixture'")
            try:
                seconds = int(parts[0].strip())
            except ValueError:
                sys.exit(f"ci-shard-plan: {path}:{lineno}: weight is not an integer: {parts[0]!r}")
            if seconds < 0:
                sys.exit(f"ci-shard-plan: {path}:{lineno}: negative weight")
            weights[parts[1].strip()] = seconds
    return weights


def pack(fixtures, weights, shards):
    """LPT: heaviest first into whichever bin is currently lightest.

    Returns a list of `shards` sets. Ties on weight break on the NAME, so the
    result does not depend on the order stdin happened to arrive in — two shards
    reading the same list in different orders must agree, and nothing forces the
    workflow to keep its list sorted.
    """
    order = sorted(fixtures, key=lambda name: (-weights.get(name, DEFAULT_WEIGHT), name))
    bins = [set() for _ in range(shards)]
    loads = [0] * shards
    for name in order:
        target = loads.index(min(loads))
        bins[target].add(name)
        loads[target] += weights.get(name, DEFAULT_WEIGHT)
    return bins, loads


def main(argv):
    parser = argparse.ArgumentParser(prog="ci-shard-plan.py", add_help=True)
    parser.add_argument("--shards", type=int, required=True)
    parser.add_argument("--shard", type=int, required=True, help="1-based")
    parser.add_argument("--weights", default=None)
    parser.add_argument(
        "--explain",
        action="store_true",
        help="print the per-shard totals to stderr (balance diagnostics)",
    )
    args = parser.parse_args(argv)

    if args.shards < 1:
        sys.exit("ci-shard-plan: --shards must be >= 1")
    if not 1 <= args.shard <= args.shards:
        sys.exit(f"ci-shard-plan: --shard must be 1..{args.shards}, got {args.shard}")

    weights_path = args.weights or os.path.join(os.path.dirname(os.path.abspath(__file__)), WEIGHTS_FILENAME)
    weights = load_weights(weights_path)

    seen = set()
    fixtures = []
    for raw in sys.stdin:
        name = raw.strip()
        if not name or name.startswith("#"):
            continue
        # A duplicate on stdin is the caller's bug, not something to dedupe
        # quietly: the workflow listing one fixture twice means it runs twice,
        # and a pack that silently collapsed them would hide that.
        if name in seen:
            sys.exit(f"ci-shard-plan: {name} appears more than once on stdin")
        seen.add(name)
        fixtures.append(name)

    if not fixtures:
        sys.exit("ci-shard-plan: no fixtures on stdin")

    bins, loads = pack(fixtures, weights, args.shards)

    if args.explain:
        unmeasured = [f for f in fixtures if f not in weights]
        for index, load in enumerate(loads, start=1):
            print(f"shard {index}/{args.shards}: {len(bins[index - 1])} fixtures, ~{load}s", file=sys.stderr)
        print(
            f"total ~{sum(loads)}s; slowest shard ~{max(loads)}s; "
            f"{len(unmeasured)} fixture(s) at DEFAULT_WEIGHT={DEFAULT_WEIGHT}",
            file=sys.stderr,
        )

    chosen = bins[args.shard - 1]
    # stdin order, not pack order: the log then reads in the same sequence the
    # workflow declares, which is what someone comparing a sharded run to an
    # unsharded one is looking for.
    for name in fixtures:
        if name in chosen:
            print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
