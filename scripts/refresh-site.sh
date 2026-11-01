#!/usr/bin/env bash
# Sign the APT metadata of the published tree again. Then the Valid-Until date moves forward.
# The packages do not change. Only Debian packages that a signed index of a trusted key
# (keys/apt) lists are kept.
#
# Usage: scripts/refresh-site.sh --published <dir> --out <site-dir>
# Environment: GPG_PRIVATE_KEY, GPG_PASSPHRASE (optional)
. "$(dirname "$0")/lib.sh"
load_config

published="" site=""
while [ $# -gt 0 ]; do
	case "$1" in
	--published) published="$2" && shift 2 ;;
	--out) site="$2" && shift 2 ;;
	*) die "Unknown option $1" ;;
	esac
done
[ -d "$published/debian/dists" ] || die "$published has no APT repository"
[ -n "$site" ] || die "--out is necessary"

# The APT signing key must be a trusted key.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fpr="$(GNUPGHOME="$tmp/gnupg" "$ROOT_DIR/scripts/keys.sh" gpg-import)"
"$ROOT_DIR/scripts/keys.sh" keyring "$ROOT_DIR/keys" "$tmp/trusted.gpg"
gpg --batch --show-keys --with-colons "$tmp/trusted.gpg" 2>/dev/null | grep -q "^fpr:*$fpr:" ||
	die "The APT signing key $fpr is not in keys/apt"

log "Verify the published Debian packages with keys/apt"
python3 "$ROOT_DIR/scripts/verify-apt-pool.py" "$published/debian" "$ROOT_DIR/keys" "$tmp/verified.json"

rm -rf "$site"
mkdir -p "$site"
tar -C "$published" --exclude=.git --exclude=./debian -cf - . | tar -C "$site" -xf -
while read -r path; do
	mkdir -p "$(dirname "$site/debian/$path")"
	cp "$published/debian/$path" "$site/debian/$path"
done < <(jq -r '.[].path' "$tmp/verified.json")

"$ROOT_DIR/scripts/repo-apt.sh" "$site"
log "Signed the APT metadata again"
