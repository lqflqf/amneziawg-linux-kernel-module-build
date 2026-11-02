"""Shared fixtures. The tests import the modules in scripts/."""

from __future__ import annotations

import importlib.util
import os
import shutil
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))


def load_script(name: str) -> ModuleType:
    """Import a script with a "-" in its file name, for example check-metadata-expiry.py."""
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), ROOT / "scripts" / name)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Repo:
    """A copy of this repository in a temporary Git repository with one commit."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-c", "user.name=test", "-c", "user.email=test@example.com", *args],
            cwd=self.path, check=True, capture_output=True, text=True,
        ).stdout

    def commit(self, message: str = "change") -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "--allow-empty", "-m", message)

    def write(self, path: str, text: str) -> None:
        (self.path / path).parent.mkdir(parents=True, exist_ok=True)
        (self.path / path).write_text(text)

    def append(self, path: str, text: str) -> None:
        with open(self.path / path, "a") as f:
            f.write(text)

    def replace(self, path: str, old: str, new: str) -> None:
        text = (self.path / path).read_text()
        assert old in text, f"{old!r} is not in {path}"
        (self.path / path).write_text(text.replace(old, new))

    def run(self, script: str, *args: str) -> subprocess.CompletedProcess[str]:
        env = {k: v for k, v in os.environ.items() if k != "GITHUB_OUTPUT"}
        return subprocess.run(
            [sys.executable, f"scripts/{script}", *args],
            cwd=self.path, capture_output=True, text=True, env=env,
        )


@pytest.fixture
def repo(tmp_path: Path) -> Repo:
    files = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT, check=True, capture_output=True, text=True,
    ).stdout.split("\0")
    for f in filter(None, files):
        src = ROOT / f
        if src.is_file():
            (tmp_path / f).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, tmp_path / f)
    r = Repo(tmp_path)
    r.git("init", "-q", "-b", "main")
    r.commit("base")
    return r
