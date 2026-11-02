#!/usr/bin/env python3
"""Shared helpers: configuration, release inputs, and package inputs.

The Python scripts import this module. scripts/lib.sh uses the command-line interface.

Usage:
  buildlib.py release-files                       Print the release input files.
  buildlib.py release-hash                        Print the hash of the release input files.
  buildlib.py input-hash apk <release> <flavor> <arch>
  buildlib.py input-hash deb
  buildlib.py input-hash keys                     Print the input hash of one package.
  buildlib.py newest-first <version>...           Sort Debian versions, the newest first.

Release inputs: the files that change the published packages, metadata, or start page.
A change to a release input publishes again (see "Publish decision" in docs/maintenance.md).

Package inputs: the files and values that change the content of one package. If they change,
the package version must increase (scripts/check-version-bump.py). A release keeps a
published package if its inputs did not change (scripts/assemble-site.sh).
"""

from __future__ import annotations

import functools
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV_FILES = ("versions/upstream.env", "versions/build.env", "config.env")
TARGETS_FILE = "versions/targets.json"

# Directories and files that can contain release inputs.
RELEASE_PATHS = ("versions", "config.env", "alpine", "debian", "patches", "keys", "README.md", "scripts")
# Files in RELEASE_PATHS that are not release inputs: the tests, the tracker, and the CI checks.
NOT_RELEASE = (
    "scripts/test/",
    "scripts/check-metadata-expiry.py",
    "scripts/check-updates.py",
    "scripts/check-version-bump.py",
    "scripts/lint-code.sh",
    "scripts/lint-docs.py",
    "scripts/plan-ci.py",
)

# Package input files. An entry that ends with "/" is a directory.
SHARED = ("scripts/lib.sh", "scripts/container.sh")
SOURCE = ("patches/", "scripts/fetch-upstream.sh")
PACKAGE_FILES = {
    "apk": ("alpine/APKBUILD.in", "alpine/depmod.sh.in", "scripts/build-apk.sh", *SOURCE, *SHARED),
    "deb": ("debian/", "scripts/build-deb.sh", *SOURCE, *SHARED),
    "keys": (
        "keys/apk/",
        "keys/apt/",
        "alpine/keys/",
        "debian/copyright",
        "scripts/build-keyring-packages.sh",
        "scripts/keys.sh",
        *SHARED,
    ),
}
# Release inputs that do not change the content of a package. The values in versions/ and
# config.env that change a package are package inputs (see packages()).
# A release input that is not in PACKAGE_FILES and not in NO_PACKAGE is an input of all packages.
NO_PACKAGE = (
    "versions/",
    "config.env",
    "README.md",
    "keys/FINGERPRINTS.md",
    "scripts/buildlib.py",
    "scripts/assemble-site.sh",
    "scripts/apk-tool.py",
    "scripts/sign-apks.sh",
    "scripts/repo-alpine.sh",
    "scripts/repo-apt.sh",
    "scripts/make-index.sh",
    "scripts/push-site.sh",
    "scripts/refresh-site.sh",
    "scripts/verify-apt-pool.py",
    "scripts/release-hash.sh",
    "scripts/ci-keys-env.sh",
    "scripts/check-key-expiry.sh",
    "scripts/dkms-check.sh",
)
KINDS = tuple(PACKAGE_FILES)

# Values for old trees that do not set these names in versions/build.env.
ENV_DEFAULTS = {"SIGNER_BASE": "alpine-3.24", "DEB_BUILD_IMAGE": "debian-trixie"}


def matches(path: str, entries: tuple[str, ...]) -> bool:
    return any(path.startswith(e) if e.endswith("/") else path == e for e in entries)


def package_kinds(path: str) -> set[str]:
    """Return the package kinds that have <path> as an input file."""
    kinds = {kind for kind, entries in PACKAGE_FILES.items() if matches(path, entries)}
    if kinds or matches(path, NO_PACKAGE):
        return kinds
    return set(KINDS)


# ---------------------------------------------------------------- trees


class Tree:
    """Files of the repository: the working tree or a Git commit."""

    def files(self) -> list[str]:
        raise NotImplementedError

    def read(self, path: str) -> bytes | None:
        raise NotImplementedError

    def text(self, path: str) -> str:
        data = self.read(path)
        return "" if data is None else data.decode()


class WorkTree(Tree):
    """The files in a directory. Untracked files are included."""

    def __init__(self, root: Path = ROOT) -> None:
        self.root = root

    def files(self) -> list[str]:
        out = []
        for top in RELEASE_PATHS:
            path = self.root / top
            if path.is_file():
                out.append(top)
            for dirpath, dirnames, filenames in os.walk(path):
                dirnames[:] = [d for d in dirnames if d != "__pycache__"]
                rel = Path(dirpath).relative_to(self.root)
                out += [(rel / f).as_posix() for f in filenames]
        return out

    def read(self, path: str) -> bytes | None:
        try:
            return (self.root / path).read_bytes()
        except FileNotFoundError:
            return None


class GitTree(Tree):
    """The files of a Git commit."""

    def __init__(self, ref: str, cwd: Path | None = None) -> None:
        self.ref = ref
        self.cwd = cwd

    def files(self) -> list[str]:
        out = subprocess.run(
            ["git", "ls-tree", "-r", "-z", "--name-only", self.ref, "--", *RELEASE_PATHS],
            cwd=self.cwd, check=True, capture_output=True,
        ).stdout.decode()
        return [f for f in out.split("\0") if f]

    def read(self, path: str) -> bytes | None:
        proc = subprocess.run(["git", "show", f"{self.ref}:{path}"], cwd=self.cwd, capture_output=True)
        return proc.stdout if proc.returncode == 0 else None


# ---------------------------------------------------------------- configuration


def read_env(text: str) -> dict[str, str]:
    """Read NAME=value lines like the shell. Quotes and comments are removed."""
    values = {}
    for line in text.splitlines():
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line)
        if m:
            values[m.group(1)] = " ".join(shlex.split(m.group(2), comments=True))
    return values


def write_env(path: Path, updates: dict[str, str]) -> None:
    """Set the values of existing NAME=value lines. Keep all other lines."""
    out = []
    for line in path.read_text().splitlines():
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=", line)
        if m and m.group(1) in updates:
            line = f"{m.group(1)}={shlex.quote(updates[m.group(1)])}"
        out.append(line)
    path.write_text("\n".join(out) + "\n")


def load_env(tree: Tree) -> dict[str, str]:
    """Return the values of versions/upstream.env, versions/build.env, and config.env."""
    env = dict(ENV_DEFAULTS)
    for path in ENV_FILES:
        env.update(read_env(tree.text(path)))
    return env


def load_targets(tree: Tree) -> dict[str, list[dict]]:
    text = tree.text(TARGETS_FILE)
    return json.loads(text) if text else {"alpine": [], "debian": []}


def image_ref(env: dict[str, str], image: str) -> str:
    """Return the pinned reference of <image> (alpine-<release> or debian-<suite>).

    scripts/container.sh uses the same names.
    """
    var = "IMAGE_" + image.replace(".", "_").replace("-", "_", 1).upper()
    return env.get(var, "")


def alpine_pkgrel(target: dict) -> int:
    """Alpine package release number. scripts/lib.sh (alpine_pkgrel) uses the same rule."""
    return int(target["krel"]) * 100 + int(target["rebuild"])


# ---------------------------------------------------------------- versions


def deb_compare(a: str, b: str) -> int:
    """Compare two Debian versions with dpkg. Return -1, 0, or 1."""
    if a == b:
        return 0
    lt = subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0
    return -1 if lt else 1


def newest_first(versions: list[str]) -> list[str]:
    return sorted(versions, key=functools.cmp_to_key(deb_compare), reverse=True)


# ---------------------------------------------------------------- packages


@dataclass
class Package:
    kind: str
    key: tuple[str, ...]
    label: str
    version: str
    version_name: str
    inputs: dict[str, str] = field(default_factory=dict)

    def input_hash(self) -> str:
        data = json.dumps(self.inputs, sort_keys=True).encode()
        return hashlib.sha256(data).hexdigest()

    def compare_version(self, other: Package) -> int:
        """Compare the version of this package with <other>. Return -1, 0, or 1."""
        if self.kind == "keys":
            a, b = int(self.version), int(other.version)
            return (a > b) - (a < b)
        return deb_compare(self.version, other.version)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_inputs(tree: Tree, files: list[str], kind: str) -> dict[str, str]:
    out = {}
    for f in files:
        if kind in package_kinds(f):
            out[f] = sha256(tree.read(f) or b"")
    return out


def packages(tree: Tree) -> list[Package]:
    """Return the packages of a tree with their versions and inputs."""
    env = load_env(tree)
    targets = load_targets(tree)
    files = release_files(tree)

    def values(*names: str) -> dict[str, str]:
        return {n: env.get(n, "") for n in names}

    upstream = values("AWG_REPO", "AWG_COMMIT", "AWG_VERSION")
    out = []
    for t in targets.get("alpine", []):
        key = (t["release"], t["flavor"], t["arch"])
        image = f"alpine-{t['release']}"
        inputs = file_inputs(tree, files, "apk") | upstream
        inputs |= {f"image {image}": image_ref(env, image)}
        inputs |= {f"target {k}": str(t[k]) for k in ("release", "flavor", "arch", "kver", "krel")}
        out.append(Package(
            kind="apk", key=key, label="Alpine {} {} {}".format(*key),
            version=f"{t['kver']}-{alpine_pkgrel(t)}",
            version_name='the "rebuild" counter in versions/targets.json',
            inputs=inputs,
        ))

    deb_image = env["DEB_BUILD_IMAGE"]
    inputs = file_inputs(tree, files, "deb") | upstream | values("DEBIAN_SNAPSHOT")
    inputs |= {f"image {deb_image}": image_ref(env, deb_image)}
    out.append(Package(
        kind="deb", key=(), label="Debian amneziawg-dkms",
        version=f"{env.get('AWG_VERSION', '')}-{env.get('DEB_REVISION', '')}",
        version_name="DEB_REVISION in versions/upstream.env",
        inputs=inputs,
    ))

    signer = env["SIGNER_BASE"]
    inputs = file_inputs(tree, files, "keys") | values("APT_KEYRING_NAME", "KEYS_EPOCH")
    inputs |= {f"image {signer}": image_ref(env, signer), f"image {deb_image}": image_ref(env, deb_image)}
    out.append(Package(
        kind="keys", key=(), label="Keyring packages",
        version=env.get("KEYS_VERSION", "0"),
        version_name="KEYS_VERSION in versions/build.env",
        inputs=inputs,
    ))
    return out


def find_package(tree: Tree, kind: str, key: tuple[str, ...]) -> Package:
    for p in packages(tree):
        if p.kind == kind and p.key == key:
            return p
    raise SystemExit(f"No {kind} package {' '.join(key)} in {TARGETS_FILE}")


def changed_inputs(old: Package, new: Package) -> list[str]:
    names = old.inputs.keys() | new.inputs.keys()
    return sorted(n for n in names if old.inputs.get(n) != new.inputs.get(n))


# ---------------------------------------------------------------- release inputs


def release_files(tree: Tree) -> list[str]:
    files = (f for f in tree.files() if not matches(f, NOT_RELEASE) and "__pycache__" not in f)
    return sorted(files)


def release_hash(tree: Tree) -> str:
    """Same value as: release_files | xargs sha256sum | sha256sum."""
    lines = "".join(f"{sha256(tree.read(f) or b'')}  {f}\n" for f in release_files(tree))
    return sha256(lines.encode())


def main(argv: list[str]) -> int:
    tree = WorkTree()
    match argv[1:]:
        case ["release-files"]:
            print("\n".join(release_files(tree)))
        case ["release-hash"]:
            print(release_hash(tree))
        case ["input-hash", "apk", release, flavor, arch]:
            print(find_package(tree, "apk", (release, flavor, arch)).input_hash())
        case ["input-hash", "deb" | "keys" as kind]:
            print(find_package(tree, kind, ()).input_hash())
        case ["newest-first", *versions]:
            print("\n".join(newest_first(versions)))
        case _:
            sys.exit(__doc__)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
