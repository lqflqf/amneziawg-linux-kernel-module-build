#!/usr/bin/env bash
# Sign the built packages and make the complete package repository tree (GitHub Pages site).
# This step does not run upstream build code. The private keys are used only here and in the
# offline signer container.
#
# Usage: scripts/assemble-site.sh --out <site-dir> --trusted-keys <dir> [--published <dir>] [--release]
#                                [--distrust-published]
#   --trusted-keys <dir> Public keys to publish and to put in the keyring packages
#                        (keys/ for a release, out/ci-keys/public for a test run).
#   --published <dir>    Clone of the packages repository (the current published tree).
#                        Old Debian packages are kept only if a signed index of a trusted key
#                        (keys/apt in this repository) lists them with the same SHA-256.
#   --release            A package with the same file name as a published package must have the
#                        same content. If not, stop. Without --release, show a warning.
#                        If the published Debian packages cannot be verified, stop. Without
#                        --release, show a warning and do not keep them.
#   --distrust-published Do not keep any published file. Use this only for an emergency key
#                        change (see docs/maintenance.md).
# Input : out/apk-unsigned/v<release>/<arch>/*.apk, out/deb/amneziawg-dkms_*.deb
# Environment: APK_KEY_NAME, APK_PRIVATE_KEY, GPG_PRIVATE_KEY, GPG_PASSPHRASE (optional)
. "$(dirname "$0")/lib.sh"
load_config

site="" published="" trusted="" release=0 distrust=0
while [ $# -gt 0 ]; do
	case "$1" in
	--out) site="$2" && shift 2 ;;
	--published) published="$2" && shift 2 ;;
	--trusted-keys) trusted="$2" && shift 2 ;;
	--release) release=1 && shift ;;
	--distrust-published) distrust=1 && shift ;;
	*) die "Unknown option $1" ;;
	esac
done
[ -n "$site" ] || die "--out is necessary"
[ -n "$trusted" ] || die "--trusted-keys is necessary"
[ "$release" = 0 ] || [ "$(cd "$trusted" && pwd)" = "$ROOT_DIR/keys" ] ||
	die "A release must use --trusted-keys keys"
if [ "$distrust" = 1 ] && [ -n "$published" ]; then
	warn "--distrust-published: no published file is kept."
	published=""
fi
mkdir -p "$site"
site="$(cd "$site" && pwd)"
case "$site" in
"$ROOT_DIR"/*) site_in_container="/w/${site#"$ROOT_DIR"/}" ;;
*) die "--out must be in $ROOT_DIR" ;;
esac

# Stop for a release. Show a warning for a test run.
mismatch() {
	if [ "$release" = 1 ]; then die "$*"; else warn "$*"; fi
}

"$ROOT_DIR/scripts/keys.sh" check-signing "$trusted"
docker image inspect amneziawg-signer:local >/dev/null 2>&1 || "$ROOT_DIR/scripts/container.sh" --make-signer

log "Sign the Alpine packages"
"$ROOT_DIR/scripts/sign-apks.sh" "$OUT_DIR/apk-unsigned" "$OUT_DIR/apk"

log "Build the keyring packages"
"$ROOT_DIR/scripts/build-keyring-packages.sh" "$trusted"

rm -rf "${site:?}"/* "$site/.nojekyll"

# ---------------------------------------------------------------- Alpine
# The tree contains only the current packages of the targets in versions/targets.json.
# Usage: add_apk <file> <relative-dir> <compare: yes|no> <version field>
add_apk() {
	local file="$1" dir="$2" compare="$3" field="$4" name old
	name="$(basename "$file")"
	mkdir -p "$site/$dir"
	old="${published:+$published/$dir/$name}"
	if [ -n "$old" ] && [ -f "$old" ] && [ "$compare" = yes ]; then
		if [ "$(python3 "$ROOT_DIR/scripts/apk-tool.py" content-hash "$old")" = \
			"$(python3 "$ROOT_DIR/scripts/apk-tool.py" content-hash "$file")" ]; then
			if [ "$release" = 1 ]; then
				# Keep the published file. Then the checksums that users have do not change.
				python3 "$ROOT_DIR/scripts/apk-tool.py" verify "$old" "$ROOT_DIR/keys/apk" >/dev/null ||
					die "$dir/$name in the published tree has no valid signature of a key in keys/apk"
				cp "$old" "$site/$dir/$name"
				return
			fi
		else
			mismatch "$dir/$name: the new build is different from the published package with the same version." \
				"Increase $field."
		fi
	fi
	cp "$file" "$site/$dir/$name"
}

compare_keys=no
[ "$release" = 1 ] && compare_keys=yes
keys_apk="$(ls "$OUT_DIR"/keyring/apk/amneziawg-keys-*.apk)"
while read -r rel flavor arch kver; do
	pkgrel="$(alpine_pkgrel "$rel" "$flavor" "$arch")"
	file="$OUT_DIR/apk/v$rel/$arch/amneziawg-$flavor-$kver-r$pkgrel.apk"
	[ -f "$file" ] || die "$file is missing"
	add_apk "$file" "alpine/v$rel/main/$arch" yes "the \"rebuild\" counter in versions/targets.json"
	# The keyring package is the same for all releases and architectures. In a test run it has
	# the temporary keys, thus it is not compared with the published package.
	add_apk "$keys_apk" "alpine/v$rel/main/$arch" "$compare_keys" "KEYS_VERSION in versions/build.env"
done < <(jq -r '.alpine[] | "\(.release) \(.flavor) \(.arch) \(.kver)"' "$TARGETS_FILE")

# ---------------------------------------------------------------- Debian
pool="$site/debian/pool/main/a"
mkdir -p "$pool"

# Keep the verified old packages only.
if [ -n "$published" ] && [ -d "$published/debian/dists" ]; then
	if ! ls "$ROOT_DIR"/keys/apt/*.asc >/dev/null 2>&1; then
		mismatch "keys/apt has no trusted keys. Cannot verify the published Debian packages. They are not kept."
	else
		log "Verify the published Debian packages with keys/apt"
		if ! python3 "$ROOT_DIR/scripts/verify-apt-pool.py" "$published/debian" "$ROOT_DIR/keys" "$OUT_DIR/work/verified.json"; then
			mismatch "The published Debian packages cannot be verified with keys/apt. They are not kept." \
				"After an emergency key change, use the option distrust_published (docs/maintenance.md)."
			echo '[]' >"$OUT_DIR/work/verified.json"
		fi
		while read -r path; do
			mkdir -p "$(dirname "$site/debian/$path")"
			cp "$published/debian/$path" "$site/debian/$path"
		done < <(jq -r '.[].path' "$OUT_DIR/work/verified.json")
	fi
fi

# Usage: add_deb <file> <package> <compare: yes|no>
add_deb() {
	local file="$1" pkg="$2" compare="$3" dest
	dest="$pool/$pkg/$(basename "$file")"
	mkdir -p "$(dirname "$dest")"
	if [ -f "$dest" ] && [ "$compare" = yes ] && ! cmp -s "$file" "$dest"; then
		mismatch "$(basename "$file"): the new build is different from the published package with the same version." \
			"Increase DEB_REVISION (or KEYS_VERSION) in versions/."
	fi
	cp "$file" "$dest"
}

deb="$OUT_DIR/deb/amneziawg-dkms_${DEB_VERSION}_all.deb"
[ -f "$deb" ] || die "$deb is missing"
add_deb "$deb" amneziawg-dkms yes
add_deb "$(ls "$OUT_DIR"/keyring/deb/amneziawg-archive-keyring_*_all.deb)" amneziawg-archive-keyring "$compare_keys"

# Retention: keep the newest DEB_KEEP_VERSIONS versions of each package.
for dir in "$pool"/*/; do
	pkg="$(basename "$dir")"
	mapfile -t old < <(find "$dir" -name "${pkg}_*_all.deb" -printf '%f\n' |
		sed -E "s/^${pkg}_(.*)_all\.deb$/\1/" | sort -V -r | tail -n +"$((DEB_KEEP_VERSIONS + 1))")
	for version in "${old[@]}"; do
		log "Remove old $pkg $version"
		rm -f "$dir/${pkg}_${version}_all.deb"
	done
done

# ---------------------------------------------------------------- keys and indexes
"$ROOT_DIR/scripts/keys.sh" export-public "$trusted" "$site/keys"

log "Make the Alpine indexes (offline signer container)"
"$ROOT_DIR/scripts/container.sh" -e APK_KEY_NAME -e APK_PRIVATE_KEY signer \
	bash -c 'scripts/repo-alpine.sh "$1" && chmod -R a+rwX "$1/alpine"' sh "$site_in_container"

log "Make the APT metadata"
"$ROOT_DIR/scripts/repo-apt.sh" "$site"

log "Write build-info.txt"
cat >"$site/build-info.txt" <<INFO
release_inputs_hash=$(release_inputs_hash)
awg_version=$AWG_VERSION
awg_tag=$AWG_TAG
awg_commit=$AWG_COMMIT
deb_version=$DEB_VERSION
keys_version=$KEYS_VERSION
source_commit=${GITHUB_SHA:-local}
INFO

log "Make the start page"
cp "$ROOT_DIR/README.md" "$site/README.md"
touch "$site/.nojekyll"
"$ROOT_DIR/scripts/make-index.sh" "$site" >"$site/index.html"

log "Site tree:"
(cd "$site" && find . -type f | LC_ALL=C sort)
