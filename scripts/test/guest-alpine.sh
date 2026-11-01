#!/bin/sh
# Installation test in an Alpine VM. The host runs this script through ssh as root.
#
# Usage: guest-alpine.sh prepare <repo-url> <release> <flavor>
#        guest-alpine.sh test <awg-version>
# Exit code 100 from "prepare": reboot the VM, then run "test".
# The host copies the public keys to /root/apk-keys/, and the tools source to
# /root/amneziawg-tools.tar.gz and /root/tunnel-test.sh.
set -eu

phase="${1:?phase}"
shift

# Try a network command again if it fails. "apk --timeout" stops a download that does not
# progress. "timeout" stops a download that is very slow.
retry() {
	n=1
	until "$@"; do
		[ "$n" -lt 3 ] || return 1
		n=$((n + 1))
		echo "Try again ($n): $*" >&2
		sleep 5
	done
}

case "$phase" in
prepare)
	repo_url="$1" release="$2" flavor="$3"
	cp /root/apk-keys/*.rsa.pub /etc/apk/keys/
	line="$repo_url/alpine/v$release/main"
	grep -qxF "$line" /etc/apk/repositories || echo "$line" >>/etc/apk/repositories
	retry timeout 300 apk --timeout 60 update
	retry timeout 600 apk --timeout 60 add "amneziawg-$flavor" iproute2 build-base linux-headers kmod
	# The keyring package must take over the key file. Then apk must still trust the repository.
	retry timeout 300 apk --timeout 60 add amneziawg-keys
	for key in /root/apk-keys/*.rsa.pub; do
		key="/etc/apk/keys/$(basename "$key")"
		apk info -W "$key" | grep -q amneziawg-keys ||
			{ echo "amneziawg-keys does not own $key" >&2; exit 1; }
	done
	retry timeout 300 apk --timeout 60 update
	apk info -L "amneziawg-$flavor"
	kabi="$(apk info -L "amneziawg-$flavor" | sed -n 's|^lib/modules/\([^/]*\)/extra/.*|\1|p' | head -n 1)"
	echo "$kabi" >/root/expected-kernel
	if [ "$(uname -r)" != "$kabi" ]; then
		echo "Running kernel is $(uname -r). The package is for $kabi. A reboot is necessary."
		exit 100
	fi
	;;
test)
	awg_version="$1"
	kabi="$(cat /root/expected-kernel)"
	[ "$(uname -r)" = "$kabi" ] || {
		echo "Running kernel is $(uname -r), not $kabi. Make sure that the image uses the linux kernel flavor of the test." >&2
		exit 1
	}
	modprobe amneziawg
	lsmod | grep -q '^amneziawg ' || { echo "amneziawg is not loaded" >&2; exit 1; }
	loaded="$(cat /sys/module/amneziawg/version)"
	[ "$loaded" = "$awg_version" ] || { echo "Loaded version $loaded is not $awg_version" >&2; exit 1; }
	dmesg | grep -i amneziawg || true

	rm -rf /root/amneziawg-tools
	tar -C /root -xzf /root/amneziawg-tools.tar.gz
	make -C /root/amneziawg-tools/src -j"$(nproc)" >/root/tools-build.log 2>&1 ||
		{ tail -n 50 /root/tools-build.log; exit 1; }
	# The build makes "wg". "make install" names it "awg".
	sh /root/tunnel-test.sh /root/amneziawg-tools/src/wg
	;;
*)
	echo "Unknown phase $phase" >&2
	exit 2
	;;
esac
