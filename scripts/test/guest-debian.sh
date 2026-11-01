#!/bin/sh
# Installation test in a Debian VM. The host runs this script through ssh as root.
#
# Usage: guest-debian.sh prepare <repo-url> <suite> <arch> <keyring-name>
#        guest-debian.sh test <awg-version>
# Exit code 100 from "prepare": reboot the VM, then run "test".
# The host copies the keyring to /root/<keyring-name>.gpg, and the tools source to
# /root/amneziawg-tools.tar.gz and /root/tunnel-test.sh.
set -eu
export DEBIAN_FRONTEND=noninteractive
# Try downloads again if they fail or do not progress.
printf 'Acquire::Retries "5";\nAcquire::http::Timeout "60";\nAcquire::https::Timeout "60";\n' \
	>/etc/apt/apt.conf.d/80awgtest-retries

phase="${1:?phase}"
shift

case "$phase" in
prepare)
	repo_url="$1" suite="$2" arch="$3" keyring="$4"
	install -m 0644 "/root/$keyring.gpg" "/usr/share/keyrings/$keyring.gpg"
	cat >/etc/apt/sources.list.d/amneziawg.sources <<EOF
Types: deb
URIs: $repo_url/debian
Suites: $suite
Components: main
Signed-By: /usr/share/keyrings/$keyring.gpg
EOF
	# Stop if a repository is not available. Without this option, apt-get only gives a warning.
	apt-get update --error-on=any
	apt-cache policy amneziawg-dkms | grep -q 'Candidate: [0-9]' || {
		echo "amneziawg-dkms is not available from $repo_url" >&2
		exit 1
	}
	# Use the newest kernel of the suite. The cloud image can have an older kernel.
	apt-get install -y "linux-image-cloud-$arch" "linux-headers-cloud-$arch" build-essential iproute2 kmod
	newest="$(dpkg-query -W -f='${Depends}' "linux-image-cloud-$arch" |
		tr ',' '\n' | sed -n -E 's/^ *linux-image-([^ ]+).*/\1/p' | head -n 1)"
	newest="${newest%-unsigned}"
	echo "$newest" >/root/expected-kernel
	if [ "$(uname -r)" != "$newest" ]; then
		echo "Running kernel is $(uname -r). The newest kernel is $newest. A reboot is necessary."
		exit 100
	fi
	;;
test)
	awg_version="$1"
	kver="$(uname -r)"
	[ "$kver" = "$(cat /root/expected-kernel)" ] || {
		echo "Running kernel is $kver, not $(cat /root/expected-kernel)" >&2
		exit 1
	}
	dpkg -s "linux-headers-$kver" >/dev/null 2>&1 || apt-get install -y "linux-headers-$kver"
	# This is the installation step for users. DKMS builds the module in the postinst script.
	# The keyring package must take over the keyring file.
	apt-get install -y --no-install-recommends amneziawg-dkms amneziawg-archive-keyring
	dpkg -S /usr/share/keyrings/amneziawg-archive-keyring.gpg | grep -q '^amneziawg-archive-keyring:' ||
		{ echo "amneziawg-archive-keyring does not own the keyring file" >&2; exit 1; }
	apt-get update --error-on=any
	dkms status -m amneziawg
	dkms status -m amneziawg -v "$awg_version" -k "$kver" | grep -q installed || {
		cat /var/lib/dkms/amneziawg/"$awg_version"/build/make.log 2>/dev/null || true
		echo "DKMS did not install the module for $kver" >&2
		exit 1
	}
	modprobe amneziawg
	loaded="$(cat /sys/module/amneziawg/version)"
	[ "$loaded" = "$awg_version" ] || { echo "Loaded version $loaded is not $awg_version" >&2; exit 1; }
	dmesg | grep -i amneziawg || true

	rm -rf /root/amneziawg-tools
	tar -C /root -xzf /root/amneziawg-tools.tar.gz
	make -C /root/amneziawg-tools/src -j"$(nproc)" >/root/tools-build.log 2>&1 ||
		{ tail -n 50 /root/tools-build.log; exit 1; }
	# The build makes "wg". "make install" names it "awg".
	sh /root/tunnel-test.sh /root/amneziawg-tools/src/wg

	# Removal test.
	modprobe -r amneziawg
	apt-get purge -y amneziawg-dkms
	if find "/lib/modules/$kver" -name 'amneziawg.ko*' | grep -q .; then
		echo "The module is still installed after removal" >&2
		exit 1
	fi
	echo "Removal test passed"
	;;
*)
	echo "Unknown phase $phase" >&2
	exit 2
	;;
esac
