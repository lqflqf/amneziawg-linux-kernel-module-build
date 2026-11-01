#!/usr/bin/env python3
"""Verify the APT pool of the published package repository.

The script trusts only the APT keys in a trusted key directory (keys/apt/*.asc of the build
repository). For each suite it verifies InRelease, then the Packages files with the SHA-256
values in InRelease, then each .deb file with the SHA-256 value in Packages.

Usage: verify-apt-pool.py <published-debian-dir> <trusted-key-dir> <output-json>

The output is a JSON list of the verified files:
  [{"path": "pool/main/...deb", "package": "...", "version": "...", "sha256": "..."}]
Files in the pool that no signed index lists are not in the output (a warning is shown).
The script stops with an error if a signature or a hash is not correct.
"""

import hashlib
import json
import os
import subprocess
import sys
import tempfile

ALLOWED_PACKAGES = {"amneziawg-dkms", "amneziawg-archive-keyring"}


def fail(msg):
    sys.exit(f"ERROR: {msg}")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def paragraphs(text):
    for block in text.split("\n\n"):
        fields = {}
        key = None
        for line in block.splitlines():
            if line.startswith((" ", "\t")) and key:
                fields[key] += "\n" + line.strip()
            elif ":" in line:
                key, value = line.split(":", 1)
                fields[key] = value.strip()
        if fields:
            yield fields


def make_keyring(trusted_dir, out):
    files = sorted(
        os.path.join(trusted_dir, "apt", f)
        for f in os.listdir(os.path.join(trusted_dir, "apt"))
        if f.endswith(".asc")
    )
    if not files:
        fail(f"No APT keys in {trusted_dir}/apt")
    with open(out, "wb") as keyring:
        for f in files:
            with open(f, "rb") as asc:
                keyring.write(subprocess.run(["gpg", "--dearmor"], input=asc.read(), check=True,
                                             capture_output=True).stdout)


def verified_release(inrelease, keyring):
    """Return the text of InRelease after gpgv verified it."""
    result = subprocess.run(
        ["gpgv", "--keyring", keyring, "--output", "-", inrelease], capture_output=True
    )
    if result.returncode != 0:
        fail(f"Signature of {inrelease} is not correct, or the key is not trusted:\n"
             + result.stderr.decode())
    return result.stdout.decode()


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    repo, trusted_dir, output = sys.argv[1:]
    verified = {}
    dists = os.path.join(repo, "dists")

    with tempfile.TemporaryDirectory() as tmp:
        keyring = os.path.join(tmp, "trusted.gpg")
        make_keyring(trusted_dir, keyring)

        for suite in sorted(os.listdir(dists)) if os.path.isdir(dists) else []:
            inrelease = os.path.join(dists, suite, "InRelease")
            if not os.path.isfile(inrelease):
                fail(f"{inrelease} is missing")
            release = next(paragraphs(verified_release(inrelease, keyring)))
            hashes = {}
            for line in release.get("SHA256", "").splitlines():
                parts = line.split()
                if len(parts) == 3:
                    hashes[parts[2]] = (parts[0], int(parts[1]))
            for name, (digest, size) in hashes.items():
                if not name.endswith("/Packages"):
                    continue
                path = os.path.join(dists, suite, name)
                if not os.path.isfile(path) or os.path.getsize(path) != size or sha256(path) != digest:
                    fail(f"{path} does not agree with the signed InRelease")
                with open(path) as f:
                    entries = list(paragraphs(f.read()))
                for entry in entries:
                    pkg, filename, digest = entry.get("Package"), entry.get("Filename"), entry.get("SHA256")
                    if pkg not in ALLOWED_PACKAGES:
                        fail(f"{path} lists the package '{pkg}', which is not permitted")
                    if not filename or not filename.startswith("pool/") or ".." in filename.split("/"):
                        fail(f"{path} has a file name that is not permitted: {filename}")
                    deb = os.path.join(repo, filename)
                    if not os.path.isfile(deb) or sha256(deb) != digest:
                        fail(f"{deb} does not agree with the signed {path}")
                    previous = verified.get(filename)
                    if previous and previous["sha256"] != digest:
                        fail(f"Two signed indexes have different hashes for {filename}")
                    verified[filename] = {
                        "path": filename,
                        "package": pkg,
                        "version": entry.get("Version"),
                        "sha256": digest,
                    }

    pool = os.path.join(repo, "pool")
    for root, _, files in os.walk(pool) if os.path.isdir(pool) else []:
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), repo)
            if rel not in verified:
                print(f"WARNING: {rel} is not in a signed index. It is not kept.", file=sys.stderr)

    with open(output, "w") as f:
        json.dump(sorted(verified.values(), key=lambda e: e["path"]), f, indent=1)
    print(f"Verified {len(verified)} files in {repo}", file=sys.stderr)


if __name__ == "__main__":
    main()
