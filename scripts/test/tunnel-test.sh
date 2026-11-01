#!/bin/sh
# Make a tunnel between two network namespaces with the amneziawg module and
# send packets through it. Run this script in the test VM as root.
#
# Usage: tunnel-test.sh <awg-binary>
set -eu

AWG="${1:?Usage: $0 <awg-binary>}"
A=awgtest-a
B=awgtest-b
CONF_DIR="$(mktemp -d)"

cleanup() {
	ip netns del "$A" 2>/dev/null || true
	ip netns del "$B" 2>/dev/null || true
	rm -rf "$CONF_DIR"
}
trap cleanup EXIT

fail() {
	echo "TUNNEL TEST FAILED: $*" >&2
	ip netns exec "$A" "$AWG" show 2>&1 || true
	ip netns exec "$B" "$AWG" show 2>&1 || true
	exit 1
}

ip netns add "$A"
ip netns add "$B"
ip link add veth-a netns "$A" type veth peer name veth-b netns "$B"
ip -n "$A" addr add 192.0.2.1/24 dev veth-a
ip -n "$B" addr add 192.0.2.2/24 dev veth-b
ip -n "$A" link set lo up
ip -n "$B" link set lo up
ip -n "$A" link set veth-a up
ip -n "$B" link set veth-b up

key_a="$("$AWG" genkey)"
key_b="$("$AWG" genkey)"
pub_a="$(echo "$key_a" | "$AWG" pubkey)"
pub_b="$(echo "$key_b" | "$AWG" pubkey)"

# Write the configuration of one side. The obfuscation values must be the same on both sides.
# Usage: write_conf <file> <private-key> <port> <peer-public-key> <peer-tunnel-ip> <peer-endpoint>
write_conf() {
	cat >"$1" <<EOF
[Interface]
PrivateKey = $2
ListenPort = $3
Jc = 4
Jmin = 8
Jmax = 80
S1 = 15
S2 = 18
H1 = 1234567891
H2 = 1234567892
H3 = 1234567893
H4 = 1234567894

[Peer]
PublicKey = $4
AllowedIPs = $5/32
Endpoint = $6
EOF
}
write_conf "$CONF_DIR/a.conf" "$key_a" 51820 "$pub_b" 10.200.0.2 192.0.2.2:51821
write_conf "$CONF_DIR/b.conf" "$key_b" 51821 "$pub_a" 10.200.0.1 192.0.2.1:51820

for side in a b; do
	if [ "$side" = a ]; then ns="$A" ip_addr=10.200.0.1; else ns="$B" ip_addr=10.200.0.2; fi
	ip -n "$ns" link add awg0 type amneziawg || fail "cannot add an amneziawg interface"
	ip netns exec "$ns" "$AWG" setconf awg0 "$CONF_DIR/$side.conf" || fail "awg setconf failed"
	ip -n "$ns" addr add "$ip_addr/24" dev awg0
	ip -n "$ns" link set awg0 up
done

ip netns exec "$A" "$AWG" show awg0
ip netns exec "$A" "$AWG" show awg0 jc 2>/dev/null || true

ip netns exec "$A" ping -c 5 -W 3 10.200.0.2 || fail "no reply through the tunnel from A to B"
ip netns exec "$B" ping -c 5 -W 3 10.200.0.1 || fail "no reply through the tunnel from B to A"

handshake="$(ip netns exec "$A" "$AWG" show awg0 latest-handshakes | awk '{print $2}')"
[ -n "$handshake" ] && [ "$handshake" -gt 0 ] || fail "no handshake"
rx="$(ip netns exec "$A" "$AWG" show awg0 transfer | awk '{print $2}')"
[ -n "$rx" ] && [ "$rx" -gt 0 ] || fail "no data received"

echo "TUNNEL TEST PASSED (handshake $handshake, received $rx bytes)"
