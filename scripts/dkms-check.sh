#!/usr/bin/env bash
# Make sure that DKMS builds the module with only the kernel headers (no full kernel source).
# Run this script in a debian:<suite> container as root. The container architecture is the
# Debian architecture that is tested.
#
# Usage: scripts/dkms-check.sh <suite> <arch>
# Input: out/deb/amneziawg-dkms_<DEB_VERSION>_all.deb
. "$(dirname "$0")/lib.sh"
load_config

[ $# -eq 2 ] || die "Usage: $0 <suite> <arch>"
suite="$1" arch="$2"

[ "$(dpkg --print-architecture)" = "$arch" ] || die "Container architecture is $(dpkg --print-architecture), not $arch"
. /etc/os-release
[ "${VERSION_CODENAME:-}" = "$suite" ] || die "Container is Debian ${VERSION_CODENAME:-unknown}, not $suite"

deb="$OUT_DIR/deb/amneziawg-dkms_${DEB_VERSION}_all.deb"
[ -f "$deb" ] || die "$deb is missing. Run scripts/build-deb.sh first."

locked="$(jq -r --arg s "$suite" --arg a "$arch" \
	'.debian[] | select(.suite == $s and .arch == $a) | .headers' "$TARGETS_FILE")"
[ -n "$locked" ] && [ "$locked" != null ] || die "No Debian target $suite/$arch in versions/targets.json"

export DEBIAN_FRONTEND=noninteractive
apt-get update -q --error-on=any
log "Install linux-headers-$arch $locked (versions/targets.json)"
# Use the locked version. If Debian replaced it, this step fails. Then run the track-updates workflow.
if ! apt-get install -y -q --no-install-recommends "linux-headers-$arch=$locked" dkms kmod; then
	die "Cannot install linux-headers-$arch=$locked. The lock is old. Run the track-updates workflow."
fi
headers_version="$(dpkg-query -W -f='${Version}' "linux-headers-$arch")"
[ "$headers_version" = "$locked" ] || die "linux-headers-$arch is $headers_version, not $locked"

# The kernel release that the headers are for, for example "6.12.48+deb13-amd64".
kver="$(dpkg-query -W -f='${Depends}' "linux-headers-$arch" | tr ',' '\n' |
	sed -n -E 's/^ *linux-headers-([^ ]+).*/\1/p' | head -n 1)"
[ -n "$kver" ] && [ -d "/usr/src/linux-headers-$kver" ] || die "Cannot find the headers of linux-headers-$arch"
[ ! -e "/usr/src/linux-source-${kver%%.*}" ] || die "A full kernel source tree is installed. This test must use only the headers."
log "Kernel headers: $kver ($headers_version)"

log "Install $(basename "$deb")"
apt-get install -y -q --no-install-recommends "$deb"

status="$(dkms status -m amneziawg -v "$AWG_VERSION" -k "$kver" 2>/dev/null || true)"
if ! echo "$status" | grep -q installed; then
	log "Build the module with DKMS for $kver"
	dkms build -m amneziawg -v "$AWG_VERSION" -k "$kver" ||
		{
			cat "/var/lib/dkms/amneziawg/$AWG_VERSION/build/make.log" || true
			die "DKMS build failed for $kver"
		}
	dkms install -m amneziawg -v "$AWG_VERSION" -k "$kver"
fi
dkms status -m amneziawg

ko="$(find "/lib/modules/$kver/updates" -name 'amneziawg.ko*' | head -n 1)"
[ -n "$ko" ] || die "amneziawg.ko is not installed in /lib/modules/$kver/updates"
modinfo "$ko"
[ "$(modinfo -F version "$ko")" = "$AWG_VERSION" ] || die "The module version is not $AWG_VERSION"
modinfo -F vermagic "$ko" | grep -q "^$kver " || die "The module vermagic does not agree with $kver"

log "Remove the package"
apt-get purge -y -q amneziawg-dkms
[ ! -e "$ko" ] || die "The module was not removed"
log "DKMS check passed for $suite/$arch ($kver)"
