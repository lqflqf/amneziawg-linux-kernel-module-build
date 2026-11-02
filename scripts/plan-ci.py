#!/usr/bin/env python3
"""Decide if a pull request must build and test the packages.

Usage: scripts/plan-ci.py <base-git-ref>

The script compares HEAD with <base-git-ref>. It prints "build=true" or "build=false".
In GitHub Actions, it also writes the value to GITHUB_OUTPUT.

The build and the tests are not necessary only if all changed files agree with NO_BUILD and
no changed file is a release input (release_files in scripts/buildlib.py).
All other changes, also new or unknown files, build and test all targets.
The "lint" job always runs.
"""

from __future__ import annotations

import os
import subprocess
import sys

import buildlib

# Files that do not change the packages, the package repository, or the build and test jobs.
# A directory entry ends with "/".
NO_BUILD = (
    "docs/",
    "tests/",
    ".github/copilot-instructions.md",
    ".github/dependabot.yml",
    ".github/workflows/track-updates.yml",
    ".github/workflows/refresh-metadata.yml",
    "scripts/check-metadata-expiry.py",
    "scripts/check-updates.py",
    "scripts/check-version-bump.py",
    "scripts/lint-code.sh",
    "scripts/lint-docs.py",
    ".gitignore",
    ".shellcheckrc",
    "LICENSE",
    "SECURITY.md",
    "pyproject.toml",
    "requirements-dev.txt",
)


def git(*args: str) -> str:
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        sys.exit(__doc__)
    # --no-renames: a renamed file shows the old and the new name.
    diff = git("diff", "--name-only", "--no-renames", argv[1], "HEAD")
    changed = sorted({f for f in diff.splitlines() if f})
    inputs = set(buildlib.release_files(buildlib.WorkTree()))
    reasons = [f for f in changed if f in inputs or not buildlib.matches(f, NO_BUILD)]

    if not changed:
        print("No file changed.")
    for f in changed:
        print(f"{'build' if f in reasons else 'no build'}: {f}")
    build = "true" if reasons else "false"
    print(f"build={build}")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"build={build}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
