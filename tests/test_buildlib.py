"""Tests of scripts/buildlib.py: configuration, release inputs, and package inputs."""

from __future__ import annotations

import hashlib
from pathlib import Path

import buildlib


class DictTree(buildlib.Tree):
    def __init__(self, files: dict[str, bytes]) -> None:
        self.data = dict(files)

    def files(self) -> list[str]:
        return list(self.data)

    def read(self, path: str) -> bytes | None:
        return self.data.get(path)

    def replace(self, path: str, old: str, new: str) -> None:
        text = self.data[path].decode()
        assert old in text
        self.data[path] = text.replace(old, new).encode()


SIGNER_DIGEST = "IMAGE_ALPINE_3_24=alpine:3.24@sha256:"


def real_tree() -> DictTree:
    work = buildlib.WorkTree()
    return DictTree({f: work.read(f) or b"" for f in work.files()})


def hashes(tree: buildlib.Tree) -> dict[tuple[str, tuple[str, ...]], str]:
    return {(p.kind, p.key): p.input_hash() for p in buildlib.packages(tree)}


def changed_packages(old: buildlib.Tree, new: buildlib.Tree) -> set[tuple[str, tuple[str, ...]]]:
    a, b = hashes(old), hashes(new)
    return {k for k in a if a[k] != b[k]}


def test_read_env_removes_quotes_and_comments() -> None:
    env = buildlib.read_env('A=1\nB="two words"\nC=x # comment\n# D=4\nE=\n')
    assert env == {"A": "1", "B": "two words", "C": "x", "E": ""}


def test_write_env_keeps_other_lines(tmp_path: Path) -> None:
    path = tmp_path / "x.env"
    path.write_text("# comment\nA=1\nB=2\n")
    buildlib.write_env(path, {"B": "two words"})
    assert path.read_text() == "# comment\nA=1\nB='two words'\n"
    assert buildlib.read_env(path.read_text())["B"] == "two words"


def test_package_kinds() -> None:
    assert buildlib.package_kinds("scripts/lib.sh") == {"apk", "deb", "keys"}
    assert buildlib.package_kinds("debian/copyright") == {"deb", "keys"}
    assert buildlib.package_kinds("alpine/APKBUILD.in") == {"apk"}
    assert buildlib.package_kinds("README.md") == set()
    # A file that buildlib.py does not classify is an input of all packages.
    assert buildlib.package_kinds("scripts/new-helper.sh") == {"apk", "deb", "keys"}


def test_release_files_exclude_tests_and_checks() -> None:
    files = buildlib.release_files(buildlib.WorkTree())
    assert "scripts/lib.sh" in files
    assert "README.md" in files
    assert not [f for f in files if f.startswith("scripts/test/") or "__pycache__" in f]
    assert "scripts/check-version-bump.py" not in files
    assert files == sorted(files)


def test_release_hash_has_the_sha256sum_format() -> None:
    tree = DictTree({"scripts/a.sh": b"a\n", "README.md": b"r\n", "scripts/test/t.sh": b"t\n"})
    lines = (
        f"{hashlib.sha256(b'r\n').hexdigest()}  README.md\n"
        f"{hashlib.sha256(b'a\n').hexdigest()}  scripts/a.sh\n"
    )
    assert buildlib.release_hash(tree) == hashlib.sha256(lines.encode()).hexdigest()


def test_image_ref_uses_the_container_names() -> None:
    env = {"IMAGE_ALPINE_3_24": "alpine:3.24@sha256:1", "IMAGE_DEBIAN_TRIXIE": "debian:trixie@sha256:2"}
    assert buildlib.image_ref(env, "alpine-3.24") == "alpine:3.24@sha256:1"
    assert buildlib.image_ref(env, "debian-trixie") == "debian:trixie@sha256:2"


def test_signer_image_is_an_input_of_the_keyring_packages() -> None:
    old, new = real_tree(), real_tree()
    new.replace("versions/build.env", SIGNER_DIGEST, SIGNER_DIGEST + "0")
    changed = changed_packages(old, new)
    assert ("keys", ()) in changed
    assert ("deb", ()) not in changed
    assert {k for k in changed if k[0] == "apk"} == {
        k for k in hashes(old) if k[0] == "apk" and k[1][0] == "3.24"
    }


def test_readme_is_not_a_package_input() -> None:
    old, new = real_tree(), real_tree()
    new.data["README.md"] += b"More text.\n"
    assert changed_packages(old, new) == set()
    assert buildlib.release_hash(old) != buildlib.release_hash(new)


def test_debian_snapshot_is_an_input_of_the_debian_package_only() -> None:
    old, new = real_tree(), real_tree()
    new.replace("versions/build.env", "DEBIAN_SNAPSHOT=", "DEBIAN_SNAPSHOT=1")
    assert changed_packages(old, new) == {("deb", ())}


def test_newest_first_uses_the_debian_version_order() -> None:
    assert buildlib.newest_first(["1.2-9", "1.10-1", "1.2-10", "1.2~rc1-1"]) == [
        "1.10-1", "1.2-10", "1.2-9", "1.2~rc1-1",
    ]
