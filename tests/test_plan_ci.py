"""Tests of scripts/plan-ci.py in a temporary copy of the repository."""

from __future__ import annotations

import pytest
from conftest import Repo


@pytest.mark.parametrize(
    ("path", "build"),
    [
        ("docs/maintenance.md", "false"),
        ("tests/test_plan_ci.py", "false"),
        ("scripts/check-updates.py", "false"),
        ("README.md", "true"),
        ("scripts/lib.sh", "true"),
        ("scripts/test/tunnel-test.sh", "true"),
        ("new-file.txt", "true"),
    ],
)
def test_plan(repo: Repo, path: str, build: str) -> None:
    repo.append(path, "\nchange\n")
    repo.commit()
    proc = repo.run("plan-ci.py", "HEAD~1")
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.splitlines()[-1] == f"build={build}"
