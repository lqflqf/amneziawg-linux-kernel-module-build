#!/usr/bin/env python3
"""Find APT metadata in the published package repository that expires soon.

Usage: scripts/check-metadata-expiry.py [days]
  days: report a suite if its InRelease file expires in fewer days than this (default: 14).

The script reads the "Valid-Until" field of each published InRelease file
(<REPO_BASE_URL>/debian/dists/<suite>/InRelease). The suites come from versions/targets.json.
It does not verify the signatures. scripts/verify-apt-pool.py does that.

A suite that is not published (HTTP 404) is shown, but it is not "expiring". Before the first
release, no suite is published. Other download errors stop the script.

Output: one line for each suite. In GitHub Actions also "expiring=true|false" and
"report=<file>" in $GITHUB_OUTPUT.
"""

from __future__ import annotations

import datetime
import email.utils
import os
import sys
import tempfile
import urllib.error
import urllib.request

import buildlib


def valid_until(inrelease: str) -> datetime.datetime | None:
    """Return the Valid-Until time of an InRelease file, or None if it has no such field."""
    for line in inrelease.splitlines():
        if line.startswith("Valid-Until:"):
            return email.utils.parsedate_to_datetime(line.split(":", 1)[1].strip())
    return None


def days_left(until: datetime.datetime, now: datetime.datetime) -> int:
    return (until - now) // datetime.timedelta(days=1)


def fetch(url: str) -> str | None:
    """Return the content of <url>, or None for HTTP 404."""
    try:
        with urllib.request.urlopen(url, timeout=60) as response:
            return response.read().decode()
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise SystemExit(f"Cannot download {url}: {e}") from e
    except urllib.error.URLError as e:
        raise SystemExit(f"Cannot download {url}: {e}") from e


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        sys.exit(__doc__)
    limit = int(argv[1]) if len(argv) == 2 else 14
    tree = buildlib.WorkTree()
    base = buildlib.load_env(tree)["REPO_BASE_URL"].rstrip("/")
    suites = sorted({t["suite"] for t in buildlib.load_targets(tree)["debian"]})
    now = datetime.datetime.now(datetime.timezone.utc)

    expiring = False
    lines = []
    for suite in suites:
        url = f"{base}/debian/dists/{suite}/InRelease"
        text = fetch(url)
        if text is None:
            lines.append(f"{suite}: not published ({url})")
            continue
        until = valid_until(text)
        if until is None:
            lines.append(f"{suite}: no Valid-Until field")
            continue
        days = days_left(until, now)
        lines.append(f"{suite}: valid until {until:%Y-%m-%d %H:%M} UTC ({days} days)")
        if days < limit:
            expiring = True

    for line in lines:
        print(line)
    if expiring:
        print(f"WARNING: APT metadata expires in fewer than {limit} days. See docs/maintenance.md.")

    gh_output = os.environ.get("GITHUB_OUTPUT")
    if gh_output:
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".txt") as report:
            report.write("\n".join(lines) + "\n")
        with open(gh_output, "a") as f:
            f.write(f"expiring={'true' if expiring else 'false'}\n")
            f.write(f"report={report.name}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
