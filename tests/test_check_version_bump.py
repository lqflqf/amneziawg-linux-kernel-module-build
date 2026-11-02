"""Tests of scripts/check-version-bump.py in a temporary copy of the repository."""

from __future__ import annotations

import json

from conftest import Repo


SIGNER_DIGEST = "IMAGE_ALPINE_3_24=alpine:3.24@sha256:"


def bump_rebuild(repo: Repo, release: str | None = None) -> None:
    path = repo.path / "versions/targets.json"
    targets = json.loads(path.read_text())
    for t in targets["alpine"]:
        if release is None or t["release"] == release:
            t["rebuild"] += 1
    path.write_text(json.dumps(targets, indent=2) + "\n")


def bump_env(repo: Repo, path: str, name: str) -> None:
    lines = (repo.path / path).read_text().splitlines()
    for i, line in enumerate(lines):
        if line.startswith(f"{name}="):
            lines[i] = f"{name}={int(line.split('=', 1)[1]) + 1}"
    (repo.path / path).write_text("\n".join(lines) + "\n")


def check(repo: Repo) -> tuple[int, str]:
    proc = repo.run("check-version-bump.py", "HEAD")
    return proc.returncode, proc.stdout + proc.stderr


def test_no_change_passes(repo: Repo) -> None:
    assert check(repo)[0] == 0


def test_readme_change_needs_no_version(repo: Repo) -> None:
    repo.append("README.md", "\nMore text.\n")
    assert check(repo)[0] == 0


def test_apkbuild_change_needs_rebuild(repo: Repo) -> None:
    repo.append("alpine/APKBUILD.in", "\n# change\n")
    rc, out = check(repo)
    assert rc == 1
    assert 'Alpine 3.24 virt x86_64: increase the "rebuild" counter' in out
    assert "Debian" not in out and "Keyring" not in out
    bump_rebuild(repo)
    assert check(repo)[0] == 0


def test_signer_image_change_needs_keys_version(repo: Repo) -> None:
    repo.replace("versions/build.env", SIGNER_DIGEST, SIGNER_DIGEST + "0")
    bump_rebuild(repo, "3.24")
    rc, out = check(repo)
    assert rc == 1
    assert "Keyring packages: increase KEYS_VERSION" in out
    assert "Alpine" not in out
    bump_env(repo, "versions/build.env", "KEYS_VERSION")
    assert check(repo)[0] == 0


def test_shared_script_change_needs_all_versions(repo: Repo) -> None:
    repo.append("scripts/lib.sh", "\n# change\n")
    rc, out = check(repo)
    assert rc == 1
    assert "Alpine 3.23 lts aarch64" in out
    assert "Debian amneziawg-dkms: increase DEB_REVISION" in out
    assert "Keyring packages: increase KEYS_VERSION" in out
    bump_rebuild(repo)
    bump_env(repo, "versions/upstream.env", "DEB_REVISION")
    bump_env(repo, "versions/build.env", "KEYS_VERSION")
    assert check(repo)[0] == 0


def test_unknown_release_input_needs_all_versions(repo: Repo) -> None:
    repo.write("scripts/new-helper.sh", "#!/bin/sh\n")
    rc, out = check(repo)
    assert rc == 1
    assert "scripts/new-helper.sh" in out
    assert "Debian" in out and "Keyring" in out and "Alpine" in out


def test_version_cannot_decrease(repo: Repo) -> None:
    path = repo.path / "versions/targets.json"
    targets = json.loads(path.read_text())
    targets["alpine"][0]["rebuild"] -= 1
    path.write_text(json.dumps(targets))
    rc, out = check(repo)
    assert rc == 1
    assert "the version decreased" in out
