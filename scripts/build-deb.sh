#!/usr/bin/env bash
# Build the amneziawg-dkms DEB package. Run this script in a Debian container as root.
#
# Usage: scripts/build-deb.sh
# Input : out/source/amneziawg-linux-kernel-module-<AWG_VERSION>.tar.gz (scripts/fetch-upstream.sh)
# Output: out/deb/amneziawg-dkms_<AWG_VERSION>-<DEB_REVISION>_all.deb
. "$(dirname "$0")/lib.sh"
load_config

[ -f "$SRC_TARBALL" ] || die "$SRC_TARBALL is missing. Run scripts/fetch-upstream.sh module first."

if [ "$(id -u)" = 0 ] && command -v apt-get >/dev/null; then
	# Use the fixed snapshot.debian.org time stamp from versions/build.env. Then the build tools
	# do not change. APT verifies the signed Release files, thus plain HTTP is safe.
	log "Install the build tools from snapshot $DEBIAN_SNAPSHOT"
	. /etc/os-release
	rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
	cat >/etc/apt/sources.list.d/snapshot.sources <<EOF
Types: deb
URIs: http://snapshot.debian.org/archive/debian/$DEBIAN_SNAPSHOT
Suites: $VERSION_CODENAME $VERSION_CODENAME-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Check-Valid-Until: no

Types: deb
URIs: http://snapshot.debian.org/archive/debian-security/$DEBIAN_SNAPSHOT
Suites: $VERSION_CODENAME-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Check-Valid-Until: no
EOF
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -q --error-on=any
	apt-get install -y -q --no-install-recommends build-essential debhelper dh-dkms dpkg-dev jq
fi

epoch="$(cat "$SRC_TARBALL.epoch")"
export SOURCE_DATE_EPOCH="$epoch"

work="$OUT_DIR/work/deb"
rm -rf "$work"
mkdir -p "$work" "$OUT_DIR/deb"
tar -C "$work" -xzf "$SRC_TARBALL"
build="$work/$SRC_NAME"

# Replace the upstream debian/ directory with the packaging of this repository.
rm -rf "$build/debian"
cp -a "$ROOT_DIR/debian" "$build/debian"
rm -f "$build/debian/changelog.in"
sed -e "s|@DEB_VERSION@|$DEB_VERSION|" \
	-e "s|@AWG_VERSION@|$AWG_VERSION|" \
	-e "s|@AWG_TAG@|$AWG_TAG|" \
	-e "s|@AWG_COMMIT@|$AWG_COMMIT|" \
	-e "s|@DATE@|$(date -u -R -d "@$epoch")|" \
	"$ROOT_DIR/debian/changelog.in" >"$build/debian/changelog"

log "Build amneziawg-dkms $DEB_VERSION"
(cd "$build" && dpkg-buildpackage -b -us -uc)

deb="$work/amneziawg-dkms_${DEB_VERSION}_all.deb"
[ -f "$deb" ] || die "$deb was not made"
cp "$deb" "$OUT_DIR/deb/"
dpkg-deb --info "$deb"
dpkg-deb --contents "$deb"
log "Wrote $OUT_DIR/deb/$(basename "$deb")"
