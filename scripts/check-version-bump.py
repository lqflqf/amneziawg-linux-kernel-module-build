#!/usr/bin/env python3
"""Make sure that a change to a package input also increases the package version.

Usage: scripts/check-version-bump.py <base-git-ref>

The script compares the working tree with the merge base of <base-git-ref> and HEAD (for
example origin/main). scripts/buildlib.py defines the inputs of each package:

  * Alpine module packages (one for each target): if an input changed, increase the
    "rebuild" counter of the target.
  * Debian package: if an input changed, increase DEB_REVISION (or AWG_VERSION).
  * Keyring packages: if an input changed, increase KEYS_VERSION.
  * No version can decrease.

A release input that buildlib.py does not classify is an input of all packages.
"""

from __future__ import annotations

import subprocess
import sys

import buildlib


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.exit(__doc__)
    base = subprocess.run(
        ["git", "merge-base", argv[1], "HEAD"], check=True, capture_output=True, text=True
    ).stdout.strip()
    old = {(p.kind, p.key): p for p in buildlib.packages(buildlib.GitTree(base))}
    errors = []
    for new in buildlib.packages(buildlib.WorkTree()):
        prev = old.get((new.kind, new.key))
        if prev is None:
            continue
        order = new.compare_version(prev)
        if order < 0:
            errors.append(f"{new.label}: the version decreased ({prev.version} -> {new.version})")
        elif order == 0 and (changed := buildlib.changed_inputs(prev, new)):
            errors.append(f"{new.label}: increase {new.version_name} (changed: {', '.join(changed)})")

    if errors:
        for e in errors:
            print(f"::error::{e}")
        return 1
    print("The package versions agree with the changes.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
