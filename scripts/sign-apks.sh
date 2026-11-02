#!/usr/bin/env bash
# Replace the temporary signature of the built APK packages with the release signature.
# The signing step runs in the offline signer container (scripts/container.sh --make-signer).
#
# Usage: scripts/sign-apks.sh <unsigned-dir> <signed-dir>
#   <unsigned-dir>/v<release>/<arch>/*.apk -> <signed-dir>/v<release>/<arch>/*.apk
# Environment: APK_KEY_NAME, APK_PRIVATE_KEY
. "$(dirname "$0")/lib.sh"
load_config

in_dir="${1:?Usage: $0 <unsigned-dir> <signed-dir>}"
out_dir="${2:?Usage: $0 <unsigned-dir> <signed-dir>}"
: "${APK_KEY_NAME:?APK_KEY_NAME is not set}"

work="$OUT_DIR/work/sign"
rm -rf "$work" "$out_dir"
mkdir -p "$work" "$out_dir"

mapfile -t apks < <(cd "$in_dir" && find . -name '*.apk' | LC_ALL=C sort)
[ "${#apks[@]}" -gt 0 ] || die "No packages in $in_dir"

i=0
for apk in "${apks[@]}"; do
	i=$((i + 1))
	python3 "$ROOT_DIR/scripts/apk-tool.py" split "$in_dir/$apk" "$work/$i"
	echo "${apk#./}" >"$work/$i/name"
done

log "Sign ${#apks[@]} packages with $APK_KEY_NAME (offline container)"
# shellcheck disable=SC2016 # The container expands the variables.
"$ROOT_DIR/scripts/container.sh" -e APK_KEY_NAME -e APK_PRIVATE_KEY signer bash -c '
	set -e
	scripts/keys.sh apk-setup >/dev/null
	for d in out/work/sign/*/; do
		abuild-sign -q -k "$HOME/.abuild/$APK_KEY_NAME" "$d/control.tar.gz"
	done
	chmod -R a+rwX out/work/sign'

pubdir="$(mktemp -d)"
trap 'rm -rf "$pubdir"' EXIT
printf '%s\n' "$APK_PRIVATE_KEY" | openssl rsa -pubout -out "$pubdir/$APK_KEY_NAME.pub" 2>/dev/null

for d in "$work"/*/; do
	name="$(cat "$d/name")"
	mkdir -p "$(dirname "$out_dir/$name")"
	cat "$d/control.tar.gz" "$d/data.tar.gz" >"$out_dir/$name"
	python3 "$ROOT_DIR/scripts/apk-tool.py" verify "$out_dir/$name" "$pubdir" >/dev/null
	log "Signed $name"
done
