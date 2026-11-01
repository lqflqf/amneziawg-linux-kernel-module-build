#!/usr/bin/env bash
# Make and sign the APKINDEX.tar.gz file in each Alpine repository directory.
# Run this script in the offline signer container (scripts/container.sh signer).
#
# Usage: scripts/repo-alpine.sh <site-dir>
#   Each <site-dir>/alpine/v<release>/main/<arch>/ directory gets a new signed index.
# Environment: APK_KEY_NAME, APK_PRIVATE_KEY (see scripts/keys.sh)
. "$(dirname "$0")/lib.sh"
load_config

site="${1:?Usage: $0 <site-dir>}"
[ -f /etc/alpine-release ] || die "Run this script in an Alpine container"
command -v abuild-sign >/dev/null || die "abuild-sign is missing. Use the signer container."

"$ROOT_DIR/scripts/keys.sh" apk-setup

found=0
for dir in "$site"/alpine/v*/main/*/; do
	[ -d "$dir" ] || continue
	dir="${dir%/}"
	arch="$(basename "$dir")"
	release="$(basename "$(dirname "$(dirname "$dir")")")"
	rm -f "$dir/APKINDEX.tar.gz"
	set -- "$dir"/*.apk
	[ -e "$1" ] || die "$dir has no packages"
	log "Index $release/$arch: $(cd "$dir" && echo *.apk)"
	(cd "$dir" && apk index --quiet --allow-untrusted --rewrite-arch "$arch" \
		--description "$REPO_ORIGIN $release main" -o APKINDEX.tar.gz -- *.apk)
	abuild-sign -q -k "$HOME/.abuild/$APK_KEY_NAME" "$dir/APKINDEX.tar.gz"
	found=1
done
[ "$found" = 1 ] || die "No Alpine repository directories in $site/alpine"
