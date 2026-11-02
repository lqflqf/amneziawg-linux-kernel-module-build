#!/usr/bin/env python3
"""Find new upstream versions and new kernel versions. Update the version lock files.

Usage: scripts/check-updates.py [--summary FILE] [--dry-run]

Rules:
  * New upstream AmneziaWG tag: set AWG_TAG, AWG_COMMIT, AWG_VERSION. Set DEB_REVISION to 1.
    Increase the "rebuild" counter of each Alpine target.
  * New amneziawg-tools tag: set AWG_TOOLS_TAG and AWG_TOOLS_COMMIT (tests only).
  * New Alpine linux-<flavor> package: set "kver" and "krel". Set "rebuild" to 0.
  * New Debian linux-headers-<arch> package: set "headers". This starts the tests again.
    The Debian package does not change.

If something changed, the script writes "changed=true" to $GITHUB_OUTPUT.
"""

from __future__ import annotations

import argparse
import functools
import gzip
import io
import json
import lzma
import os
import re
import subprocess
import sys
import tarfile
from pathlib import Path

import buildlib

ROOT = buildlib.ROOT
UPSTREAM_ENV = ROOT / "versions" / "upstream.env"
TARGETS = Path(os.environ.get("TARGETS_FILE", ROOT / "versions" / "targets.json"))

ALPINE_MIRROR = "https://dl-cdn.alpinelinux.org/alpine"
DEBIAN_ARCHIVES = [
    ("https://deb.debian.org/debian", "{suite}"),
    ("https://deb.debian.org/debian", "{suite}-updates"),
    ("https://security.debian.org/debian-security", "{suite}-security"),
]
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:-(\d+))?$")


class NotFound(Exception):
    pass


def fetch(url: str) -> bytes:
    print(f"GET {url}", file=sys.stderr)
    proc = subprocess.run(
        ["curl", "-fsSL", "--retry", "3", "--connect-timeout", "30", "--max-time", "300",
         "-w", "%{http_code}", "-o", "-", url],
        capture_output=True,
    )
    if proc.returncode == 22 and proc.stdout.endswith(b"404"):
        raise NotFound(url)
    if proc.returncode != 0:
        raise SystemExit(f"Cannot download {url}: {proc.stderr.decode().strip()}")
    return proc.stdout[:-3]


def latest_tag(repo: str) -> tuple[str, str]:
    """Return (tag, commit) of the newest release tag of a git repository."""
    text = subprocess.run(
        ["git", "ls-remote", "--tags", repo], check=True, capture_output=True, text=True
    ).stdout
    commits: dict[str, str] = {}
    for line in text.splitlines():
        sha, ref = line.split("\t")
        name = ref.removeprefix("refs/tags/")
        if name.endswith("^{}"):
            commits[name[:-3]] = sha  # Annotated tag: use the commit.
        else:
            commits.setdefault(name, sha)
    tags = []
    for name in commits:
        m = TAG_RE.match(name)
        if m:
            key = tuple(int(x) if x else 0 for x in m.groups())
            tags.append((key, name))
    if not tags:
        raise SystemExit(f"No release tags in {repo}")
    tag = max(tags)[1]
    return tag, commits[tag]


def tag_to_version(tag: str) -> str:
    # "v3.0.20260731-04" -> "3.0.20260731.04". Debian and DKMS sort this version correctly.
    return tag[1:].replace("-", ".")


@functools.lru_cache(maxsize=None)
def alpine_index(release: str, arch: str) -> str:
    data = fetch(f"{ALPINE_MIRROR}/v{release}/main/{arch}/APKINDEX.tar.gz")
    # The file has a signature gzip stream and then the index gzip stream.
    raw = gzip.GzipFile(fileobj=io.BytesIO(data)).read()
    with tarfile.open(fileobj=io.BytesIO(raw)) as tar:
        member = tar.extractfile("APKINDEX")
        if member is None:
            raise SystemExit(f"No APKINDEX in Alpine {release}/{arch}")
        return member.read().decode()


def alpine_kernel(release: str, flavor: str, arch: str) -> tuple[str, int]:
    name = f"linux-{flavor}-dev"
    for block in alpine_index(release, arch).split("\n\n"):
        fields = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
        if fields.get("P") == name:
            m = re.match(r"^(.+)-r(\d+)$", fields["V"])
            if not m:
                raise SystemExit(f"Unknown version {fields['V']} of {name}")
            return m.group(1), int(m.group(2))
    raise SystemExit(f"No {name} in Alpine {release}/{arch}")


def debian_package_version(base: str, dist: str, arch: str, name: str) -> str | None:
    try:
        data = lzma.decompress(fetch(f"{base}/dists/{dist}/main/binary-{arch}/Packages.xz"))
    except NotFound:
        return None
    m = re.search(
        rb"^Package: " + re.escape(name.encode()) + rb"\n(?:[^\n]+\n)*?Version: (\S+)$", data, re.M
    )
    return m.group(1).decode() if m else None


def debian_headers(suite: str, arch: str) -> str:
    name = f"linux-headers-{arch}"
    versions = []
    for base, dist in DEBIAN_ARCHIVES:
        version = debian_package_version(base, dist.format(suite=suite), arch, name)
        if version:
            versions.append(version)
    if not versions:
        raise SystemExit(f"No {name} in Debian {suite}")
    return max(versions, key=functools.cmp_to_key(buildlib.deb_compare))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--summary", help="Write a Markdown summary of the changes to this file")
    parser.add_argument("--dry-run", action="store_true", help="Do not change the files")
    args = parser.parse_args()

    env = buildlib.read_env(UPSTREAM_ENV.read_text())
    targets = json.loads(TARGETS.read_text())
    changes: list[str] = []
    env_updates: dict[str, str] = {}

    tag, commit = latest_tag(env["AWG_REPO"])
    upstream_changed = tag != env["AWG_TAG"] or commit != env["AWG_COMMIT"]
    if upstream_changed:
        version = tag_to_version(tag)
        env_updates.update(AWG_TAG=tag, AWG_COMMIT=commit, AWG_VERSION=version, DEB_REVISION="1")
        changes.append(f"AmneziaWG module: `{env['AWG_TAG']}` -> `{tag}` ({commit[:12]})")

    tools_tag, tools_commit = latest_tag(env["AWG_TOOLS_REPO"])
    if tools_tag != env["AWG_TOOLS_TAG"] or tools_commit != env["AWG_TOOLS_COMMIT"]:
        env_updates.update(AWG_TOOLS_TAG=tools_tag, AWG_TOOLS_COMMIT=tools_commit)
        changes.append(f"amneziawg-tools (tests only): `{env['AWG_TOOLS_TAG']}` -> `{tools_tag}`")

    for t in targets["alpine"]:
        kver, krel = alpine_kernel(t["release"], t["flavor"], t["arch"])
        label = f"Alpine {t['release']} linux-{t['flavor']} {t['arch']}"
        if (kver, krel) != (t["kver"], t["krel"]):
            changes.append(f"{label}: `{t['kver']}-r{t['krel']}` -> `{kver}-r{krel}`")
            t.update(kver=kver, krel=krel, rebuild=0)
        elif upstream_changed:
            t["rebuild"] += 1
            if t["rebuild"] >= 100:
                raise SystemExit(f"{label}: the rebuild counter is too large")

    for t in targets["debian"]:
        headers = debian_headers(t["suite"], t["arch"])
        if headers != t["headers"]:
            changes.append(
                f"Debian {t['suite']} linux-headers-{t['arch']}: `{t['headers']}` -> `{headers}`"
            )
            t["headers"] = headers

    if changes:
        print("Changes:")
        for c in changes:
            print(f"  - {c}")
    else:
        print("No changes.")

    if changes and not args.dry_run:
        if env_updates:
            buildlib.write_env(UPSTREAM_ENV, env_updates)
        TARGETS.write_text(format_targets(targets))

    if args.summary:
        with open(args.summary, "w") as f:
            f.write("Automatic update of the version lock files.\n\n")
            f.writelines(f"- {c}\n" for c in changes)
            f.write("\nThe build workflow builds and tests all targets. ")
            f.write("Merge this pull request to publish the packages.\n")

    gh_output = os.environ.get("GITHUB_OUTPUT")
    if gh_output:
        with open(gh_output, "a") as f:
            f.write(f"changed={'true' if changes else 'false'}\n")
    return 0


def format_targets(targets: dict[str, list[dict]]) -> str:
    """Write one target on each line, as in the file in the repository."""
    out = ["{"]
    sections = list(targets.items())
    for i, (key, items) in enumerate(sections):
        out.append(f'  "{key}": [')
        for j, item in enumerate(items):
            comma = "," if j < len(items) - 1 else ""
            out.append("    " + json.dumps(item, separators=(", ", ": ")) + comma)
        out.append("  ]" + ("," if i < len(sections) - 1 else ""))
    out.append("}")
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    sys.exit(main())
