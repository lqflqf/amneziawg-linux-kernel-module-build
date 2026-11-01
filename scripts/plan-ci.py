#!/usr/bin/env python3
"""Decide if a pull request must build and test the packages.

Usage: scripts/plan-ci.py <base-git-ref>

The script compares HEAD with <base-git-ref>. It prints "build=true" or "build=false".
In GitHub Actions, it also writes the value to GITHUB_OUTPUT.

The build and the tests are not necessary only if all changed files agree with NO_BUILD and
no changed file is a release input (release_input_files in scripts/lib.sh).
All other changes, also new or unknown files, build and test all targets.
The "lint" job always runs.
"""

import os
import subprocess
import sys

# Files that do not change the packages, the package repository, or the build and test jobs.
# A directory entry ends with "/".
NO_BUILD = (
    "docs/",
    ".github/copilot-instructions.md",
    ".github/workflows/track-updates.yml",
    ".github/workflows/refresh-metadata.yml",
    "scripts/check-updates.py",
    "scripts/check-version-bump.py",
    "scripts/lint-docs.py",
    ".gitignore",
)


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def release_inputs():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = subprocess.run(
        ["bash", "-c", '. scripts/lib.sh && release_input_files'],
        cwd=root, check=True, capture_output=True, text=True,
    ).stdout
    return set(out.splitlines())


def no_build(path):
    return any(path.startswith(p) if p.endswith("/") else path == p for p in NO_BUILD)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    # --no-renames: a renamed file shows the old and the new name.
    diff = git("diff", "--name-only", "--no-renames", sys.argv[1], "HEAD")
    changed = sorted({f for f in diff.splitlines() if f})
    inputs = release_inputs()
    reasons = [f for f in changed if f in inputs or not no_build(f)]

    if not changed:
        print("No file changed.")
    for f in changed:
        print(f"{'build' if f in reasons else 'no build'}: {f}")
    build = "true" if reasons else "false"
    print(f"build={build}")
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"build={build}\n")


if __name__ == "__main__":
    main()
