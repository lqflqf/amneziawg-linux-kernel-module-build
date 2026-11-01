#!/usr/bin/env bash
# Build one Alpine APK package. Run this script in an alpine:<release> container as root.
# The container architecture must agree with <arch>.
#
# Usage: scripts/build-apk.sh <release> <flavor> <arch>
# Input : out/source/amneziawg-linux-kernel-module-<AWG_VERSION>.tar.gz
# Output: out/apk-unsigned/v<release>/<arch>/amneziawg-<flavor>-<kver>-r<pkgrel>.apk
#
# This step runs upstream build code. Thus it does not get the signing keys. abuild signs the
# package with a temporary key. scripts/sign-apks.sh replaces that signature later.
. "$(dirname "$0")/lib.sh"
load_config

[ $# -eq 3 ] || die "Usage: $0 <release> <flavor> <arch>"
release="$1" flavor="$2" arch="$3"

[ -f /etc/alpine-release ] || die "Run this script in an Alpine container"
case "$(cat /etc/alpine-release)" in
"$release" | "$release".*) ;;
*) die "Container is Alpine $(cat /etc/alpine-release), not $release" ;;
esac
[ "$(apk --print-arch)" = "$arch" ] || die "Container architecture is $(apk --print-arch), not $arch"
[ -f "$SRC_TARBALL" ] || die "$SRC_TARBALL is missing. Run scripts/fetch-upstream.sh module first."

kver="$(alpine_field "$release" "$flavor" "$arch" kver)"
krel="$(alpine_field "$release" "$flavor" "$arch" krel)"
pkgrel="$(alpine_pkgrel "$release" "$flavor" "$arch")"
kabi="$kver-$krel-$flavor"

log "Install the build tools"
apk add -q alpine-sdk openssl

# Make sure that the locked kernel version is the current version in the Alpine repository.
current="$(apk search -x "linux-$flavor-dev" 2>/dev/null | head -n 1 || true)"
[ "$current" = "linux-$flavor-dev-$kver-r$krel" ] ||
	die "The repository has '$current', but versions/targets.json has linux-$flavor-dev-$kver-r$krel. Run the track-updates workflow."

rm -rf "$HOME/.abuild"
mkdir -p "$HOME/.abuild"
tmpkey="$HOME/.abuild/amneziawg-build-temporary.rsa"
openssl genrsa -out "$tmpkey" 2048 2>/dev/null
openssl rsa -in "$tmpkey" -pubout -out "$tmpkey.pub" 2>/dev/null
cp "$tmpkey.pub" /etc/apk/keys/
echo "PACKAGER_PRIVKEY=\"$tmpkey\"" >"$HOME/.abuild/abuild.conf"
echo 'PACKAGER="AmneziaWG package builder <lqflqf@users.noreply.github.com>"' >>"$HOME/.abuild/abuild.conf"

work="$OUT_DIR/work/apk/$release-$flavor-$arch"
rm -rf "$work"
mkdir -p "$work"
cp "$SRC_TARBALL" "$work/"

sed -e "s|@FLAVOR@|$flavor|" -e "s|@KVER@|$kver|" -e "s|@KREL@|$krel|" \
	-e "s|@PKGREL@|$pkgrel|" -e "s|@AWG_VERSION@|$AWG_VERSION|" \
	"$ROOT_DIR/alpine/APKBUILD.in" >"$work/APKBUILD"
for script in post-install post-upgrade post-deinstall; do
	sed -e "s|@KABI@|$kabi|" "$ROOT_DIR/alpine/depmod.sh.in" >"$work/amneziawg-$flavor.$script"
done

export SOURCE_DATE_EPOCH
SOURCE_DATE_EPOCH="$(cat "$SRC_TARBALL.epoch")"
repo="$work-repo"
rm -rf "$repo"
cd "$work" || exit 1
abuild -F checksum
log "Build amneziawg-$flavor-$kver-r$pkgrel for $release/$arch"
abuild -F -r -P "$repo" -s "$work"

apk_file="$(find "$repo" -name "amneziawg-$flavor-$kver-r$pkgrel.apk" | head -n 1)"
[ -n "$apk_file" ] || die "The package was not made"

dest="$OUT_DIR/apk-unsigned/v$release/$arch"
mkdir -p "$dest"
cp "$apk_file" "$dest/"

log "Package contents:"
tar -tzf "$apk_file" 2>/dev/null | grep -v '^\.' || true
ko="$(tar -tzf "$apk_file" 2>/dev/null | grep -E "^lib/modules/$kabi/extra/amneziawg\.ko(\.[a-z]+)?$" || true)"
[ -n "$ko" ] || die "The package has no lib/modules/$kabi/extra/amneziawg.ko"
log "Wrote $dest/$(basename "$apk_file")"
