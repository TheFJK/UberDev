#!/usr/bin/env python3
"""Canonical URL -> bare-host normalizer for the testers rate-limit machinery.

SINGLE SOURCE OF TRUTH for how a URL maps to a per-host rate bucket. Both consumers
MUST key on the SAME normalized host, or a host split across userinfo / ASCII-case /
:port / trailing-dot variants escapes the per-host RPS cap (issue #184) and slips past
the post-hoc audit meant to detect that bypass (issue #186):

  * lib/rate-limit-curl.sh -> calls this as a subprocess: ``python3 normalize_host.py URL``
  * lib/rate-cap-audit.sh  -> imports ``normalize_host`` (this dir is put on sys.path)

Do NOT reimplement host parsing in either consumer; change it here only.

Normalization leans on ``urllib.parse.urlsplit().hostname`` -- the hardened stdlib URL
parser, which already lowercases the host and strips userinfo and ``:port`` (and removes
the brackets from IPv6 literals) -- rather than a hand-rolled authority regex, which is
exactly the naive ``scheme://([^/?#]+)`` capture both issues are about. On top of that we
drop a single trailing FQDN dot and reject hosts that could escape per-host filesystem
scoping (a ``..`` segment or a ``/``).

CLI contract: ``normalize_host.py URL``
  * prints the normalized host and exits 0 when the URL yields a safe bare host
  * prints nothing and exits 3 when it cannot (no host, or scope-escape), so a shell
    caller can branch on the non-zero return code
"""
from __future__ import annotations  # lazy annotations so `str | None` is safe on py3.8/3.9

from urllib.parse import urlsplit


def normalize_host(url: str) -> str | None:
    """Return the canonical bare host for ``url`` to use as a per-host bucket key,
    or ``None`` if the URL has no parseable host or the host could escape per-host
    scoping (contains ``..`` or ``/``)."""
    if not isinstance(url, str) or not url:
        return None
    try:
        # hostname: lowercased, userinfo + :port stripped, IPv6 literal de-bracketed.
        host = urlsplit(url).hostname
    except ValueError:
        # Malformed authority (e.g. bad IPv6 literal / invalid port) -> not a usable host.
        return None
    if not host:
        return None
    # Scope-escape guard (mirrors the historic ``*..*|*/*`` reject). Check BEFORE the
    # trailing-dot strip so a trailing ``..`` is rejected, not silently halved to ``.``.
    if ".." in host or "/" in host:
        return None
    if host.endswith("."):
        # Drop the FQDN root label so "host." and "host" share one bucket.
        host = host[:-1]
    if not host:
        return None
    return host


def _main(argv):
    url = argv[1] if len(argv) > 1 else ""
    host = normalize_host(url)
    if host is None:
        return 3
    print(host)
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(_main(sys.argv))
