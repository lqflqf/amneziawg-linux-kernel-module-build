#!/usr/bin/env python3
"""Tools for APK v2 package files.

An APK v2 file is three gzip streams: signature, control (.PKGINFO), and data.
The signature is an RSA signature of the control gzip stream.

Usage:
  apk-tool.py split <apk> <dir>      Write control.tar.gz and data.tar.gz to <dir>.
  apk-tool.py content-hash <apk>     SHA-256 of the control and data streams (not the signature).
  apk-tool.py verify <apk> <keydir>  Verify the signature with a public key in <keydir>.
  apk-tool.py pkginfo <apk>          Print .PKGINFO.
"""

import hashlib
import os
import subprocess
import sys
import tempfile
import zlib


def gzip_members(data):
    """Return a list of (compressed bytes, uncompressed bytes) for each gzip stream."""
    members = []
    pos = 0
    while pos < len(data):
        dec = zlib.decompressobj(16 + zlib.MAX_WBITS)
        raw = dec.decompress(data[pos:])
        if not dec.eof:
            raise SystemExit("A gzip stream is not complete")
        size = len(data) - pos - len(dec.unused_data)
        members.append((data[pos : pos + size], raw))
        pos += size
    return members


def tar_entries(raw):
    """Return (name, content) for each file in a tar stream (end blocks are optional)."""
    entries = []
    pos = 0
    while pos + 512 <= len(raw):
        header = raw[pos : pos + 512]
        if header == b"\0" * 512:
            break
        name = header[0:100].rstrip(b"\0").decode()
        size = int(header[124:136].rstrip(b"\0 ").decode() or "0", 8)
        typeflag = header[156:157]
        pos += 512
        # Skip the PAX extended headers. GNU tar can add them before a file.
        if typeflag not in (b"x", b"g"):
            entries.append((name, raw[pos : pos + size]))
        pos += (size + 511) // 512 * 512
    return entries


def parse(path):
    """Return (signature entries or None, control bytes, data bytes, control raw tar)."""
    with open(path, "rb") as f:
        members = gzip_members(f.read())
    signature = None
    if members and any(n.startswith(".SIGN.") for n, _ in tar_entries(members[0][1])):
        signature = tar_entries(members[0][1])
        members = members[1:]
    if len(members) != 2:
        raise SystemExit(f"{path}: expected control and data streams, found {len(members)}")
    return signature, members[0][0], members[1][0], members[0][1]


def cmd_split(apk, outdir):
    _, control, data, _ = parse(apk)
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "control.tar.gz"), "wb") as f:
        f.write(control)
    with open(os.path.join(outdir, "data.tar.gz"), "wb") as f:
        f.write(data)


def cmd_content_hash(apk):
    _, control, data, _ = parse(apk)
    print(hashlib.sha256(control + data).hexdigest())


def cmd_verify(apk, keydir):
    signature, control, _, _ = parse(apk)
    if not signature:
        raise SystemExit(f"{apk}: no signature")
    name, sig = signature[0]
    if name.startswith(".SIGN.RSA256."):
        digest, key = "-sha256", name[len(".SIGN.RSA256.") :]
    elif name.startswith(".SIGN.RSA."):
        digest, key = "-sha1", name[len(".SIGN.RSA.") :]
    else:
        raise SystemExit(f"{apk}: unknown signature type {name}")
    keyfile = os.path.join(keydir, key)
    if "/" in key or not os.path.isfile(keyfile):
        raise SystemExit(f"{apk}: signed with {key}, which is not a trusted key")
    with tempfile.TemporaryDirectory() as tmp:
        sigfile = os.path.join(tmp, "sig")
        datafile = os.path.join(tmp, "control.tar.gz")
        with open(sigfile, "wb") as f:
            f.write(sig)
        with open(datafile, "wb") as f:
            f.write(control)
        result = subprocess.run(
            ["openssl", "dgst", digest, "-verify", keyfile, "-signature", sigfile, datafile],
            capture_output=True,
            text=True,
        )
    if result.returncode != 0:
        raise SystemExit(f"{apk}: signature verification failed ({key})")
    print(f"{apk}: signature OK ({key})")


def cmd_pkginfo(apk):
    _, _, _, control_raw = parse(apk)
    for name, content in tar_entries(control_raw):
        if name == ".PKGINFO":
            sys.stdout.write(content.decode())
            return
    raise SystemExit(f"{apk}: no .PKGINFO")


def main(argv):
    commands = {
        "split": (cmd_split, 2),
        "content-hash": (cmd_content_hash, 1),
        "verify": (cmd_verify, 2),
        "pkginfo": (cmd_pkginfo, 1),
    }
    if len(argv) < 2 or argv[1] not in commands or len(argv) - 2 != commands[argv[1]][1]:
        sys.exit(__doc__)
    func, _ = commands[argv[1]]
    func(*argv[2:])


if __name__ == "__main__":
    main(sys.argv)
