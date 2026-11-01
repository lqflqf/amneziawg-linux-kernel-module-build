#!/usr/bin/env python3
"""Make sure that a change to a package input also increases the package version.

Usage: scripts/check-version-bump.py <base-git-ref>

The script compares the working tree with <base-git-ref> (for example origin/main).

Rules:
  * Alpine module packages: if an input changed (alpine/, patches/, scripts/build-apk.sh,
    scripts/fetch-upstream.sh, the Alpine images, or the upstream commit), the "rebuild" counter
    of each Alpine target with the same kernel must increase.
  * Debian package: if an input changed (debian/, patches/, scripts/build-deb.sh,
    scripts/fetch-upstream.sh, the Debian image, DEBIAN_SNAPSHOT, or the upstream commit),
    the version <AWG_VERSION>-<DEB_REVISION> must increase.
  * Keyring packages: if keys/, alpine/keys/, scripts/build-keyring-packages.sh,
    scripts/keys.sh, debian/copyright, APT_KEYRING_NAME, or KEYS_EPOCH changed,
    KEYS_VERSION must increase.
  * No version can decrease.
"""

import json
import re
import subprocess
import sys

COMMON = ("patches/", "scripts/fetch-upstream.sh")
APK_INPUTS = ("alpine/APKBUILD.in", "alpine/depmod.sh.in", "scripts/build-apk.sh") + COMMON
DEB_INPUTS = ("debian/", "scripts/build-deb.sh") + COMMON
KEYS_INPUTS = (
    "keys/apk/",
    "keys/apt/",
    "alpine/keys/",
    "scripts/build-keyring-packages.sh",
    "scripts/keys.sh",
    "debian/copyright",
)


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def read_env(text):
    return dict(re.findall(r"^([A-Z0-9_]+)=(.*)$", text, re.M))


def base_file(ref, path):
    try:
        return git("show", f"{ref}:{path}")
    except subprocess.CalledProcessError:
        return None


def deb_lt(a, b):
    return subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    base = git("merge-base", sys.argv[1], "HEAD").strip()
    changed = git("diff", "--name-only", base).splitlines()
    changed += git("ls-files", "--others", "--exclude-standard").splitlines()
    changed = [f for f in changed if f]
    errors = []

    def touched(prefixes):
        return sorted({f for f in changed if f.startswith(prefixes)})

    old_env, new_env = {}, {}
    for path in ("versions/upstream.env", "versions/build.env", "config.env"):
        old_env.update(read_env(base_file(base, path) or ""))
        with open(path) as f:
            new_env.update(read_env(f.read()))
    old_targets = json.loads(base_file(base, "versions/targets.json") or '{"alpine": [], "debian": []}')
    with open("versions/targets.json") as f:
        new_targets = json.load(f)

    def env_changed(*names):
        return [n for n in names if old_env.get(n) != new_env.get(n)]

    upstream = env_changed("AWG_REPO", "AWG_COMMIT", "AWG_VERSION")
    alpine_images = sorted(k for k in old_env.keys() | new_env.keys() if k.startswith("IMAGE_ALPINE_"))
    apk_reasons = touched(APK_INPUTS) + upstream + env_changed(*alpine_images)
    deb_reasons = touched(DEB_INPUTS) + upstream + env_changed("IMAGE_DEBIAN_TRIXIE", "DEBIAN_SNAPSHOT")
    keys_reasons = touched(KEYS_INPUTS) + env_changed("APT_KEYRING_NAME", "KEYS_EPOCH")

    # Alpine
    old_alpine = {(t["release"], t["flavor"], t["arch"]): t for t in old_targets["alpine"]}
    for t in new_targets["alpine"]:
        key = (t["release"], t["flavor"], t["arch"])
        old = old_alpine.get(key)
        if not old:
            continue
        label = "Alpine {} {} {}".format(*key)
        same_kernel = (old["kver"], old["krel"]) == (t["kver"], t["krel"])
        if same_kernel and t["rebuild"] < old["rebuild"]:
            errors.append(f"{label}: the rebuild counter decreased")
        if same_kernel and apk_reasons and t["rebuild"] <= old["rebuild"]:
            errors.append(f"{label}: increase \"rebuild\" (changed: {', '.join(apk_reasons)})")

    # Debian
    if old_env.get("AWG_VERSION"):
        old_deb = f"{old_env['AWG_VERSION']}-{old_env['DEB_REVISION']}"
        new_deb = f"{new_env['AWG_VERSION']}-{new_env['DEB_REVISION']}"
        if deb_lt(new_deb, old_deb):
            errors.append(f"Debian: the version decreased ({old_deb} -> {new_deb})")
        elif deb_reasons and not deb_lt(old_deb, new_deb):
            errors.append(f"Debian: increase DEB_REVISION (changed: {', '.join(deb_reasons)})")

    # Keyring packages
    if old_env.get("KEYS_VERSION"):
        old_k, new_k = int(old_env["KEYS_VERSION"]), int(new_env["KEYS_VERSION"])
        if new_k < old_k:
            errors.append("KEYS_VERSION decreased")
        elif keys_reasons and new_k <= old_k:
            errors.append(f"Increase KEYS_VERSION in versions/build.env (changed: {', '.join(keys_reasons)})")

    if errors:
        for e in errors:
            print(f"::error::{e}")
        sys.exit(1)
    print("The package versions agree with the changes.")


if __name__ == "__main__":
    main()
