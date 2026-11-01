#!/usr/bin/env bash
# Make and sign the APT repository metadata.
# Run this script on Debian or Ubuntu. It needs apt-ftparchive (apt-utils), gpg, jq.
#
# Usage: scripts/repo-apt.sh <site-dir>
#   Input : <site-dir>/debian/pool/main/a/<package>/*.deb
#   Output: <site-dir>/debian/dists/<suite>/{Release,InRelease,Release.gpg}
#           <site-dir>/debian/dists/<suite>/main/binary-<arch>/Packages(.gz)
#   The suites and the architectures come from versions/targets.json.
# Environment: GPG_PRIVATE_KEY, GPG_PASSPHRASE (optional)
. "$(dirname "$0")/lib.sh"
load_config

site="${1:?Usage: $0 <site-dir>}"
repo="$site/debian"
[ -d "$repo/pool" ] || die "$repo/pool is missing"
command -v apt-ftparchive >/dev/null || die "apt-ftparchive is missing. Install apt-utils."

GNUPGHOME="$(mktemp -d)"
export GNUPGHOME
trap 'rm -rf "$GNUPGHOME"' EXIT
fpr="$("$ROOT_DIR/scripts/keys.sh" gpg-import)"
[ -n "$fpr" ] || die "Cannot import the GPG key"
log "APT signing key: $fpr"

gpg_sign() {
	if [ -n "${GPG_PASSPHRASE:-}" ]; then
		printf '%s' "$GPG_PASSPHRASE" | gpg --batch --yes --pinentry-mode loopback \
			--passphrase-fd 0 --local-user "$fpr" "$@"
	else
		gpg --batch --yes --local-user "$fpr" "$@"
	fi
}

suites="$(jq -r '[.debian[].suite] | unique | .[]' "$TARGETS_FILE")"

# Remove the suites that are not supported now.
if [ -d "$repo/dists" ]; then
	for dir in "$repo"/dists/*/; do
		name="$(basename "$dir")"
		if ! grep -qx "$name" <<<"$suites"; then
			log "Remove unsupported suite $name"
			rm -rf "$dir"
		fi
	done
fi

for suite in $suites; do
	archs="$(jq -r --arg s "$suite" '[.debian[] | select(.suite == $s) | .arch] | unique | join(" ")' \
		"$TARGETS_FILE")"
	dist="$repo/dists/$suite"
	rm -rf "$dist"
	for arch in $archs; do
		mkdir -p "$dist/main/binary-$arch"
		(cd "$repo" && apt-ftparchive --arch "$arch" packages pool/main) >"$dist/main/binary-$arch/Packages"
		gzip -9nk "$dist/main/binary-$arch/Packages"
		grep -q '^Package: amneziawg-dkms$' "$dist/main/binary-$arch/Packages" ||
			die "No amneziawg-dkms in $suite/$arch Packages"
	done
	apt-ftparchive \
		-o "APT::FTPArchive::Release::Origin=$REPO_ORIGIN" \
		-o "APT::FTPArchive::Release::Label=$REPO_LABEL" \
		-o "APT::FTPArchive::Release::Suite=$suite" \
		-o "APT::FTPArchive::Release::Codename=$suite" \
		-o "APT::FTPArchive::Release::Architectures=$archs" \
		-o "APT::FTPArchive::Release::Components=main" \
		-o "APT::FTPArchive::Release::Description=$REPO_LABEL for Debian $suite" \
		-o "APT::FTPArchive::Release::ValidTime=$((APT_VALID_DAYS * 86400))" \
		release "$dist" >"$dist/Release.tmp"
	mv "$dist/Release.tmp" "$dist/Release"
	gpg_sign --clearsign -o "$dist/InRelease" "$dist/Release"
	gpg_sign --armor --detach-sign -o "$dist/Release.gpg" "$dist/Release"
	gpg --batch --verify "$dist/InRelease" 2>/dev/null || die "InRelease signature check failed"
	log "Signed $suite ($archs)"
done
