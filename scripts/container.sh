#!/usr/bin/env bash
# Run a command in a pinned container image (versions/build.env).
# The repository is mounted at /w. OUT_DIR is /w/out.
#
# Usage:
#   scripts/container.sh [--offline] [-e NAME]... <image> <command> [args...]
#   scripts/container.sh --make-signer
#
# <image>: alpine-<release> | debian-<suite> | signer
#   signer: Alpine image with abuild, openssl, bash, jq, and no network access.
#           Make it first with --make-signer. Use it for all steps that use private keys.
# --offline: no network in the container.
# -e NAME:   copy the environment variable NAME into the container.
# CONTAINER_NETWORK: Docker network for the other containers (default: Docker default).
. "$(dirname "$0")/lib.sh"
load_config

SIGNER_IMAGE=amneziawg-signer:local
SIGNER_BASE=alpine-3.24

# Print the pinned image reference for <image>.
image_ref() {
	local var
	case "$1" in
	alpine-*) var="IMAGE_ALPINE_${1#alpine-}" ;;
	debian-*) var="IMAGE_DEBIAN_${1#debian-}" ;;
	*) die "Unknown image $1" ;;
	esac
	var="$(echo "$var" | tr '.a-z' '_A-Z')"
	[ -n "${!var:-}" ] || die "$var is not set in versions/build.env"
	echo "${!var}"
}

if [ "${1:-}" = --make-signer ]; then
	base="$(image_ref "$SIGNER_BASE")"
	name="amneziawg-signer-build-$$"
	log "Make $SIGNER_IMAGE from $base"
	docker run --name "$name" ${CONTAINER_NETWORK:+--network "$CONTAINER_NETWORK"} "$base" \
		apk add -q abuild openssl bash jq
	docker commit "$name" "$SIGNER_IMAGE" >/dev/null
	docker rm -f "$name" >/dev/null
	exit 0
fi

args=(--rm -v "$ROOT_DIR:/w" -w /w -e OUT_DIR=/w/out)
network="${CONTAINER_NETWORK:-}"
while [ $# -gt 0 ]; do
	case "$1" in
	--offline) network=none && shift ;;
	-e) args+=(-e "$2") && shift 2 ;;
	*) break ;;
	esac
done
[ $# -ge 2 ] || die "Usage: $0 [--offline] [-e NAME]... <image> <command> [args...]"

# Give the path of TARGETS_FILE in the container.
if [ -n "${TARGETS_FILE:-}" ] && [ "$TARGETS_FILE" != "$ROOT_DIR/versions/targets.json" ]; then
	case "$TARGETS_FILE" in
	"$ROOT_DIR"/*) args+=(-e "TARGETS_FILE=/w/${TARGETS_FILE#"$ROOT_DIR"/}") ;;
	*) die "TARGETS_FILE must be in $ROOT_DIR" ;;
	esac
fi

image="$1"
shift
if [ "$image" = signer ]; then
	docker image inspect "$SIGNER_IMAGE" >/dev/null 2>&1 || die "Run $0 --make-signer first"
	ref="$SIGNER_IMAGE"
	network=none
else
	ref="$(image_ref "$image")"
fi
[ -n "$network" ] && args+=(--network "$network")

exec docker run "${args[@]}" "$ref" "$@"
