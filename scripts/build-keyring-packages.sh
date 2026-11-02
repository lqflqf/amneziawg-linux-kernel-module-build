#!/usr/bin/env bash
# Build the keyring packages from a trusted key directory (see scripts/keys.sh):
#   amneziawg-archive-keyring_<KEYS_VERSION>_all.deb  (/usr/share/keyrings/<APT_KEYRING_NAME>.gpg)
#   amneziawg-keys-<KEYS_VERSION>-r0.apk               (/etc/apk/keys/*.rsa.pub)
# The packages let users get new keys with a normal upgrade (key rotation).
#
# Usage: scripts/build-keyring-packages.sh <trusted-dir>
# Output: out/keyring/deb/*.deb, out/keyring/apk/*.apk
# Environment: APK_KEY_NAME, APK_PRIVATE_KEY (the APK is signed in the offline signer container)
# The DEB is built in the DEB_BUILD_IMAGE container, the APK in the signer container (both offline).
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
load_config

trusted="${1:?Usage: $0 <trusted-dir>}"
case "$trusted" in
"$ROOT_DIR"/*) ;;
/*) die "<trusted-dir> must be in $ROOT_DIR" ;;
*) trusted="$PWD/$trusted" ;;
esac
out="$OUT_DIR/keyring"
rm -rf "$out"
mkdir -p "$out/deb" "$out/apk"
export SOURCE_DATE_EPOCH="$KEYS_EPOCH"

# ---------------------------------------------------------------- Debian
work="$OUT_DIR/work/keyring-deb"
rm -rf "$work"
mkdir -p "$work/DEBIAN" "$work/usr/share/keyrings" "$work/usr/share/doc/amneziawg-archive-keyring"
"$ROOT_DIR/scripts/keys.sh" keyring "$trusted" "$work/usr/share/keyrings/$APT_KEYRING_NAME.gpg"
cp "$ROOT_DIR/debian/copyright" "$work/usr/share/doc/amneziawg-archive-keyring/copyright"
cat >"$work/DEBIAN/control" <<EOF
Package: amneziawg-archive-keyring
Version: $KEYS_VERSION
Architecture: all
Maintainer: AmneziaWG package builder <lqflqf@users.noreply.github.com>
Section: misc
Priority: optional
Multi-Arch: foreign
Description: OpenPGP keys of the AmneziaWG package repository
 This package installs the keyring /usr/share/keyrings/$APT_KEYRING_NAME.gpg.
 APT uses it to verify the AmneziaWG package repository.
EOF
chmod 0644 "$work/usr/share/keyrings/$APT_KEYRING_NAME.gpg" "$work/DEBIAN/control"
find "$work" -exec touch -h -d "@$KEYS_EPOCH" {} +
deb="amneziawg-archive-keyring_${KEYS_VERSION}_all.deb"
# Use dpkg-deb of the pinned image, not of the host. Then the package does not change when the
# host changes. "gpg --dearmor" above only decodes the armor. Its output does not change.
# shellcheck disable=SC2016 # The container expands the arguments.
"$ROOT_DIR/scripts/container.sh" --offline -e SOURCE_DATE_EPOCH "$DEB_BUILD_IMAGE" bash -c '
	set -e
	dpkg-deb --root-owner-group -Zxz --build "$OUT_DIR/work/keyring-deb" "$OUT_DIR/keyring/deb/$1" >/dev/null
	chmod a+rw "$OUT_DIR/keyring/deb/$1"' sh "$deb"
log "Wrote $out/deb/$deb"

# ---------------------------------------------------------------- Alpine
work="$OUT_DIR/work/keyring-apk"
rm -rf "$OUT_DIR/work/keyring-apk-repo"
rm -rf "$work"
mkdir -p "$work"
sources=""
for f in "$trusted"/apk/*.rsa.pub; do
	[ -f "$f" ] || continue
	cp "$f" "$work/"
	sources="$sources $(basename "$f")"
done
[ -n "$sources" ] || die "No Alpine keys in $trusted/apk"
sed -e "s|@KEYS_VERSION@|$KEYS_VERSION|" -e "s|@SOURCES@|${sources# }|" \
	"$ROOT_DIR/alpine/keys/APKBUILD.in" >"$work/APKBUILD"

# shellcheck disable=SC2016 # The container expands the variables.
"$ROOT_DIR/scripts/container.sh" -e APK_KEY_NAME -e APK_PRIVATE_KEY -e SOURCE_DATE_EPOCH signer bash -c '
	set -e
	scripts/keys.sh apk-setup >/dev/null
	echo "PACKAGER=\"AmneziaWG package builder <lqflqf@users.noreply.github.com>\"" >>"$HOME/.abuild/abuild.conf"
	cd out/work/keyring-apk
	abuild -F checksum >/dev/null
	abuild -F -d -P /w/out/work/keyring-apk-repo >/dev/null
	cp /w/out/work/keyring-apk-repo/*/noarch/amneziawg-keys-*.apk /w/out/keyring/apk/ 2>/dev/null ||
		cp /w/out/work/keyring-apk-repo/*/*/amneziawg-keys-*.apk /w/out/keyring/apk/
	chmod -R a+rwX /w/out/keyring /w/out/work/keyring-apk /w/out/work/keyring-apk-repo'
log "Wrote $(ls "$out"/apk/*.apk)"
