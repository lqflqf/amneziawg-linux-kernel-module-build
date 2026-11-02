#!/usr/bin/env bash
# Install the packages from a package repository tree in a clean QEMU VM and test them.
#
# Usage:
#   scripts/test/run-vm-test.sh [--image-key] alpine <release> <flavor> <arch>
#   scripts/test/run-vm-test.sh [--image-key] debian <suite> <arch>
#
# --image-key: print only a key for the cloud image (file name and checksum), then stop.
#              The build workflow uses it as the cache key of VM_CACHE.
#
# Environment:
#   SITE_DIR     Package repository tree (default: out/site, from scripts/assemble-site.sh)
#   VM_MEM       VM memory in MiB (default: 2048)
#   VM_CPUS      VM CPUs (default: 2)
#   VM_TIMEOUT   Time limit in seconds to wait for ssh after a boot (default: 600 with KVM, 2400 without)
#   VM_CACHE     Directory for downloaded images (default: out/vm-cache)
#   VM_SETUP_CMD Optional shell command that runs as root in the VM before the test.
#                Use it only for local network settings, for example a package mirror.
# Needs: qemu-system-x86_64 or qemu-system-aarch64, qemu-img, cloud-localds, ssh, curl, python3.
# For aarch64 also: qemu-efi-aarch64 (UEFI firmware).
# shellcheck source=../lib.sh
. "$(dirname "$0")/../lib.sh"
load_config

image_key=0
if [ "${1:-}" = --image-key ]; then
	image_key=1
	shift
fi
distro="${1:?Usage: $0 alpine <release> <flavor> <arch> | debian <suite> <arch>}"
case "$distro" in
alpine)
	[ $# -eq 4 ] || die "Usage: $0 alpine <release> <flavor> <arch>"
	release="$2" flavor="$3" arch="$4"
	name="alpine-$release-$flavor-$arch"
	# The images lock the root account. Use the default user and doas.
	vm_user=alpine sudo_cmd="doas -n"
	;;
debian)
	[ $# -eq 3 ] || die "Usage: $0 debian <suite> <arch>"
	suite="$2" arch="$3"
	name="debian-$suite-$arch"
	vm_user=debian sudo_cmd="sudo -n"
	;;
*) die "Unknown distribution $distro" ;;
esac

SITE_DIR="${SITE_DIR:-$OUT_DIR/site}"
VM_MEM="${VM_MEM:-2048}"
VM_CPUS="${VM_CPUS:-2}"
VM_CACHE="${VM_CACHE:-$OUT_DIR/vm-cache}"
vm="$OUT_DIR/vm/$name"
TOOLS_TARBALL="$OUT_DIR/source/amneziawg-tools.tar.gz"

# ---------------------------------------------------------------- image
case "$arch" in
x86_64 | amd64) qarch=x86_64 ;;
aarch64 | arm64) qarch=aarch64 ;;
*) die "Unknown architecture $arch" ;;
esac

# Print the URL of the cloud image for this test.
image_url() {
	if [ "$distro" = alpine ]; then
		local base="https://dl-cdn.alpinelinux.org/alpine/v$release/releases/cloud"
		local fw=bios metal=""
		[ "$qarch" = aarch64 ] && fw=uefi
		# The "metal" images use the linux-lts kernel. The other images use linux-virt.
		[ "$flavor" = lts ] && metal="-metal"
		local file
		file="$(curl -fsSL "$base/" |
			grep -oE "generic_alpine-$release\.[0-9]+-$qarch-$fw-cloudinit$metal-r[0-9]+\.qcow2\"" |
			tr -d '"' | sort -V | tail -n 1)"
		[ -n "$file" ] || die "Cannot find an Alpine $release $qarch$metal cloud image in $base"
		echo "$base/$file"
	else
		local version
		version="$(jq -r --arg s "$suite" '[.debian[] | select(.suite == $s)][0].version' "$TARGETS_FILE")"
		echo "https://cloud.debian.org/images/cloud/$suite/latest/debian-$version-genericcloud-$arch.qcow2"
	fi
}

# Print the SHA-512 checksum of <url> from the image server.
image_checksum() {
	local url="$1" sum
	if [ "$distro" = alpine ]; then
		sum="$(curl -fsSL "$url.sha512" | awk '{print $1}')"
	else
		sum="$(curl -fsSL "$(dirname "$url")/SHA512SUMS" | awk -v f="$(basename "$url")" '$2 == f {print $1}')"
	fi
	[ -n "$sum" ] || die "Cannot get the checksum of $url"
	echo "$sum"
}

# Download <url> to the cache and verify the SHA-512 checksum from the image server.
fetch_image() {
	local url="$1" file sum expected
	file="$VM_CACHE/$(basename "$url")"
	expected="$(image_checksum "$url")"
	if [ ! -f "$file" ] || [ "$(sha512sum "$file" | awk '{print $1}')" != "$expected" ]; then
		log "Download $url"
		curl -fsSL --retry 3 -o "$file.part" "$url"
		mv "$file.part" "$file"
	fi
	sum="$(sha512sum "$file" | awk '{print $1}')"
	[ "$sum" = "$expected" ] || die "Checksum of $file is not correct"
	echo "$file"
}

url="$(image_url)"
if [ "$image_key" = 1 ]; then
	sum="$(image_checksum "$url")"
	echo "$(basename "$url")-${sum:0:16}"
	exit 0
fi

[ -d "$SITE_DIR" ] || die "$SITE_DIR is missing. Run scripts/assemble-site.sh first."
[ -f "$TOOLS_TARBALL" ] || die "$TOOLS_TARBALL is missing. Run scripts/fetch-upstream.sh tools first."
rm -rf "$vm"
mkdir -p "$vm" "$VM_CACHE"

base_image="$(fetch_image "$url")"
log "Image: $base_image"
qemu-img create -q -f qcow2 -b "$(readlink -f "$base_image")" -F qcow2 "$vm/disk.qcow2" 12G

# ---------------------------------------------------------------- cloud-init
ssh-keygen -q -t ed25519 -N '' -f "$vm/id_ed25519"
cat >"$vm/user-data" <<EOF
#cloud-config
ssh_pwauth: false
ssh_authorized_keys:
  - $(cat "$vm/id_ed25519.pub")
EOF
printf 'instance-id: %s\nlocal-hostname: awgtest\n' "$name" >"$vm/meta-data"
cloud-localds "$vm/seed.img" "$vm/user-data" "$vm/meta-data"

# ---------------------------------------------------------------- HTTP server for the repository
http_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
ssh_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -m http.server "$http_port" --bind 127.0.0.1 --directory "$SITE_DIR" >"$vm/http.log" 2>&1 &
http_pid=$!
# QEMU user networking sends 10.0.2.2 to the host loopback address.
repo_url="http://10.0.2.2:$http_port"

# ---------------------------------------------------------------- QEMU
accel=tcg cpu=max
if [ "$(uname -m)" = "$qarch" ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
	accel=kvm cpu=host
fi
VM_TIMEOUT="${VM_TIMEOUT:-$([ "$accel" = kvm ] && echo 600 || echo 2400)}"
log "VM $name: accelerator $accel, $VM_CPUS CPUs, $VM_MEM MiB"

qemu_args=(
	-name "$name" -accel "$accel" -cpu "$cpu" -smp "$VM_CPUS" -m "$VM_MEM"
	-drive "if=virtio,file=$vm/disk.qcow2,format=qcow2"
	-drive "if=virtio,file=$vm/seed.img,format=raw,readonly=on"
	# romfile=: no network boot ROM. Then the test does not need the ipxe-qemu package.
	-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22"
	-device "virtio-net-pci,netdev=net0,romfile="
	-device virtio-rng-pci
	-serial "file:$vm/console.log" -display none
	-daemonize -pidfile "$vm/qemu.pid"
)
if [ "$qarch" = x86_64 ]; then
	qemu_bin="qemu-system-x86_64"
	qemu_args+=(-machine q35)
else
	qemu_bin="qemu-system-aarch64"
	firmware=""
	for f in /usr/share/qemu-efi-aarch64/QEMU_EFI.fd /usr/share/AAVMF/AAVMF_CODE.fd /usr/share/edk2/aarch64/QEMU_EFI.fd; do
		[ -f "$f" ] && firmware="$f" && break
	done
	[ -n "$firmware" ] || die "UEFI firmware for aarch64 is missing. Install qemu-efi-aarch64."
	qemu_args+=(-machine virt -bios "$firmware")
fi

cleanup() {
	local rc=$?
	if [ -f "$vm/qemu.pid" ]; then
		vm_root dmesg >"$vm/dmesg.log" 2>/dev/null || true
		kill "$(cat "$vm/qemu.pid")" 2>/dev/null || true
	fi
	kill "$http_pid" 2>/dev/null || true
	if [ "$rc" != 0 ]; then
		echo "---- last lines of the VM console ($vm/console.log) ----" >&2
		tail -n 60 "$vm/console.log" >&2 || true
	fi
	exit "$rc"
}
trap cleanup EXIT
trap "exit 143" INT TERM

ssh_opts=(-i "$vm/id_ed25519" -p "$ssh_port" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
	-o LogLevel=ERROR -o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=8 -o BatchMode=yes)
# The arguments are a command for the VM. The VM shell expands them.
# shellcheck disable=SC2029
vm_ssh() { ssh "${ssh_opts[@]}" "$vm_user@127.0.0.1" "$@"; }
vm_root() { vm_ssh "$sudo_cmd" "$@"; }
vm_copy() { vm_root "tee '$2' >/dev/null" <"$1"; }

boot_id=""
wait_ssh() {
	local start=$SECONDS id
	while :; do
		if ! kill -0 "$(cat "$vm/qemu.pid")" 2>/dev/null; then
			die "QEMU stopped"
		fi
		id="$(vm_ssh 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)"
		if [ -n "$id" ] && [ "$id" != "$boot_id" ]; then
			boot_id="$id"
			break
		fi
		[ $((SECONDS - start)) -lt "$VM_TIMEOUT" ] || die "No ssh connection to the VM after $VM_TIMEOUT seconds"
		sleep 5
	done
	# Wait until cloud-init is complete. Then the package manager is free.
	# cloud-init can restart sshd during this time (for example for ssh_pwauth). Then the
	# connection fails with "Connection reset by peer". Try again until the time limit.
	until vm_ssh 'command -v cloud-init >/dev/null && cloud-init status --wait >/dev/null 2>&1 || true' 2>/dev/null; do
		[ $((SECONDS - start)) -lt "$VM_TIMEOUT" ] || die "No ssh connection to the VM after $VM_TIMEOUT seconds"
		sleep 5
	done
	log "VM is ready ($((SECONDS - start)) s): $(vm_ssh 'uname -r')"
}

log "Start the VM"
"$qemu_bin" "${qemu_args[@]}"
wait_ssh

# ---------------------------------------------------------------- test
vm_copy "$TOOLS_TARBALL" /root/amneziawg-tools.tar.gz
vm_copy "$ROOT_DIR/scripts/test/tunnel-test.sh" /root/tunnel-test.sh

if [ "$distro" = alpine ]; then
	# Copy all published Alpine keys. During a key change there are two keys.
	ls "$SITE_DIR"/keys/*.rsa.pub >/dev/null 2>&1 || die "No Alpine public key in $SITE_DIR/keys"
	(cd "$SITE_DIR/keys" && tar -czf - ./*.rsa.pub) |
		vm_root sh -c "'mkdir -p /root/apk-keys && tar -C /root/apk-keys -xzf -'"
	guest="$ROOT_DIR/scripts/test/guest-alpine.sh"
	prepare_args=("$repo_url" "$release" "$flavor")
else
	vm_copy "$SITE_DIR/keys/$APT_KEYRING_NAME.gpg" "/root/$APT_KEYRING_NAME.gpg"
	guest="$ROOT_DIR/scripts/test/guest-debian.sh"
	prepare_args=("$repo_url" "$suite" "$arch" "$APT_KEYRING_NAME")
fi
vm_copy "$guest" /root/guest.sh

if [ -n "${VM_SETUP_CMD:-}" ]; then
	log "Run VM_SETUP_CMD"
	vm_root sh -c "$(printf '%q' "$VM_SETUP_CMD")"
fi

log "Phase: prepare"
rc=0
vm_root sh /root/guest.sh prepare "${prepare_args[@]}" || rc=$?
if [ "$rc" = 100 ]; then
	log "Reboot the VM"
	vm_root reboot || true
	wait_ssh
elif [ "$rc" != 0 ]; then
	die "Phase prepare failed with exit code $rc"
fi

log "Phase: test"
vm_root sh /root/guest.sh test "$AWG_VERSION" || die "Phase test failed"
log "VM test passed: $name"
