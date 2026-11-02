#!/usr/bin/env bash
# Signing keys and public keys.
#
# A "trusted key directory" has this layout:
#   apk/<name>.rsa.pub   Alpine public keys (PEM)
#   apt/<name>.asc       APT public keys (armored OpenPGP)
# For a release, the trusted key directory is keys/ in this repository. Users can compare the
# fingerprints in keys/FINGERPRINTS.md. For test runs, it is out/ci-keys/public.
#
# Usage:
#   scripts/keys.sh generate <dir>              Make temporary test keys in <dir> (not for release).
#   scripts/keys.sh apk-setup                   Install the APK private key for abuild.
#   scripts/keys.sh gpg-import                  Import the APT private key into GNUPGHOME.
#   scripts/keys.sh check-signing <trusted-dir> Make sure that the private keys agree with
#                                               public keys in <trusted-dir>.
#   scripts/keys.sh keyring <trusted-dir> <file>  Write all APT keys to a binary keyring file.
#   scripts/keys.sh export-public <trusted-dir> <out-dir>
#                                               Write the public keys for the package repository.
#   scripts/keys.sh fingerprints <trusted-dir>  Print keys/FINGERPRINTS.md.
#
# Environment:
#   APK_KEY_NAME     Key file name, for example "amneziawg-packages.rsa".
#   APK_PRIVATE_KEY  RSA private key (PEM).
#   GPG_PRIVATE_KEY  Armored OpenPGP private key for the APT repository.
. "$(dirname "$0")/lib.sh"
load_config

generate() {
	local dir="$1" name gnupg
	mkdir -p "$dir/public/apk" "$dir/public/apt"
	name="amneziawg-ci-test-$(date +%s).rsa"
	(umask 077 && openssl genrsa -out "$dir/apk-private-key" 2048 2>/dev/null)
	echo "$name" >"$dir/apk-key-name"
	openssl rsa -in "$dir/apk-private-key" -pubout -out "$dir/public/apk/$name.pub" 2>/dev/null

	gnupg="$(mktemp -d)"
	GNUPGHOME="$gnupg" gpg --batch --quiet --pinentry-mode loopback --passphrase '' \
		--quick-gen-key "AmneziaWG CI test key (not for release)" rsa3072 sign 2d
	GNUPGHOME="$gnupg" gpg --batch --armor --export-secret-keys >"$dir/gpg-private-key"
	GNUPGHOME="$gnupg" gpg --batch --armor --export >"$dir/public/apt/ci-test.asc"
	rm -rf "$gnupg"
	log "Wrote temporary test keys to $dir"
}

require_apk_key() {
	[ -n "${APK_KEY_NAME:-}" ] || die "APK_KEY_NAME is not set"
	[ -n "${APK_PRIVATE_KEY:-}" ] || die "APK_PRIVATE_KEY is not set"
	case "$APK_KEY_NAME" in
	*/* | *' '* | '') die "APK_KEY_NAME is not a valid file name" ;;
	*.rsa) ;;
	*) die "APK_KEY_NAME must end with .rsa" ;;
	esac
}

apk_setup() {
	require_apk_key
	local dir="$HOME/.abuild"
	mkdir -p "$dir"
	(umask 077 && printf '%s\n' "$APK_PRIVATE_KEY" >"$dir/$APK_KEY_NAME")
	openssl rsa -in "$dir/$APK_KEY_NAME" -pubout -out "$dir/$APK_KEY_NAME.pub" 2>/dev/null
	echo "PACKAGER_PRIVKEY=\"$dir/$APK_KEY_NAME\"" >"$dir/abuild.conf"
	if [ -d /etc/apk/keys ]; then
		cp "$dir/$APK_KEY_NAME.pub" /etc/apk/keys/
	fi
	log "APK signing key: $APK_KEY_NAME"
}

gpg_import() {
	[ -n "${GPG_PRIVATE_KEY:-}" ] || die "GPG_PRIVATE_KEY is not set"
	: "${GNUPGHOME:?GNUPGHOME must be set}"
	mkdir -p "$GNUPGHOME"
	chmod 700 "$GNUPGHOME"
	printf '%s\n' "$GPG_PRIVATE_KEY" | gpg --batch --quiet --import
	gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}'
}

# Write all APT keys of <trusted-dir> to a binary keyring. The output is the same for the same input.
keyring() {
	local dir="$1" out="$2" f found=0
	: >"$out"
	for f in "$dir"/apt/*.asc; do
		[ -f "$f" ] || continue
		gpg --dearmor <"$f" >>"$out"
		found=1
	done
	[ "$found" = 1 ] || die "No APT keys in $dir/apt"
}

# Print the fingerprints of the primary keys in a keyring file.
keyring_fingerprints() {
	gpg --batch --show-keys --with-colons "$1" 2>/dev/null | awk -F: '/^pub/ {p=1; next} p && /^fpr/ {print $10; p=0}'
}

check_signing() {
	local dir="$1" tmp fpr
	require_apk_key
	[ -f "$dir/apk/$APK_KEY_NAME.pub" ] ||
		die "$dir/apk/$APK_KEY_NAME.pub is missing. Add the public key of the APK signing key."
	cmp -s <(printf '%s\n' "$APK_PRIVATE_KEY" | openssl rsa -pubout 2>/dev/null) "$dir/apk/$APK_KEY_NAME.pub" ||
		die "APK_PRIVATE_KEY does not agree with $dir/apk/$APK_KEY_NAME.pub"

	tmp="$(mktemp -d)"
	fpr="$(GNUPGHOME="$tmp/gnupg" gpg_import)"
	keyring "$dir" "$tmp/keyring.gpg"
	if ! keyring_fingerprints "$tmp/keyring.gpg" | grep -qx "$fpr"; then
		rm -rf "$tmp"
		die "The APT signing key $fpr is not in $dir/apt"
	fi
	rm -rf "$tmp"
	log "The signing keys agree with $dir"
}

export_public() {
	local dir="$1" out="$2" f found=0
	mkdir -p "$out"
	for f in "$dir"/apk/*.rsa.pub; do
		[ -f "$f" ] || continue
		cp "$f" "$out/"
		found=1
	done
	[ "$found" = 1 ] || die "No Alpine keys in $dir/apk"
	keyring "$dir" "$out/$APT_KEYRING_NAME.gpg"
	cat "$dir"/apt/*.asc >"$out/$APT_KEYRING_NAME.asc"
	log "Wrote the public keys of $dir to $out"
}

fingerprints() {
	local dir="$1" f tmp
	tmp="$(mktemp -d)"
	cat <<'EOF'
# Public key fingerprints

These are the public keys of the AmneziaWG package repository. Compare the keys that you
download from the package repository with the values in this file. This file is in the build
repository. Thus, a person who changes the package repository cannot also change this file.

Do not edit this file. Make it with `scripts/keys.sh fingerprints keys > keys/FINGERPRINTS.md`.

## APT keys (OpenPGP)

To show the fingerprints of the keyring on your system, run
`gpg --show-keys /usr/share/keyrings/amneziawg-archive-keyring.gpg`.

| File | Fingerprint | Expiry date |
|---|---|---|
EOF
	for f in "$dir"/apt/*.asc; do
		[ -f "$f" ] || continue
		gpg --dearmor <"$f" >"$tmp/k.gpg"
		gpg --batch --show-keys --with-colons "$tmp/k.gpg" 2>/dev/null |
			awk -F: '/^pub/ {e = $7; p = 1; next} p && /^fpr/ {print $10, (e == "" ? 0 : e); p = 0}' |
			while read -r fpr expiry; do
				if [ "$expiry" = 0 ]; then expiry=none; else expiry="$(date -u -d "@$expiry" +%Y-%m-%d)"; fi
				# shellcheck disable=SC2016 # The backquotes are Markdown code, not a command.
				printf '| `apt/%s` | `%s` | %s |\n' "$(basename "$f")" "$fpr" "$expiry"
			done
	done
	cat <<'EOF'

## Alpine keys (RSA)

To show the value on your system, run `sha256sum /etc/apk/keys/amneziawg-*.rsa.pub`.

| File | SHA-256 of the file |
|---|---|
EOF
	for f in "$dir"/apk/*.rsa.pub; do
		[ -f "$f" ] || continue
		# shellcheck disable=SC2016 # The backquotes are Markdown code, not a command.
		printf '| `apk/%s` | `%s` |\n' "$(basename "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
	done
	rm -rf "$tmp"
}

case "${1:-}" in
generate) generate "${2:?directory}" ;;
apk-setup) apk_setup ;;
gpg-import) gpg_import ;;
check-signing) check_signing "${2:?trusted key directory}" ;;
keyring) keyring "${2:?trusted key directory}" "${3:?output file}" ;;
export-public) export_public "${2:?trusted key directory}" "${3:?output directory}" ;;
fingerprints) fingerprints "${2:?trusted key directory}" ;;
*) die "Usage: see the comments at the top of $0" ;;
esac
