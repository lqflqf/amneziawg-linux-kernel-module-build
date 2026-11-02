#!/usr/bin/env bash
# Common helpers. Other scripts source this file.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out}"
# Override this file only for local tests with a smaller target list.
TARGETS_FILE="${TARGETS_FILE:-$ROOT_DIR/versions/targets.json}"

log() { printf '==> %s\n' "$*" >&2; }
warn() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::warning::%s\n' "$*" >&2
	else
		printf 'WARNING: %s\n' "$*" >&2
	fi
}
die() {
	if [ -n "${GITHUB_ACTIONS:-}" ]; then
		printf '::error::%s\n' "$*" >&2
	else
		printf 'ERROR: %s\n' "$*" >&2
	fi
	exit 1
}

# Export the values from versions/upstream.env, versions/build.env, and config.env.
load_config() {
	set -a
	# shellcheck source=../versions/upstream.env
	. "$ROOT_DIR/versions/upstream.env"
	# shellcheck source=../versions/build.env
	. "$ROOT_DIR/versions/build.env"
	# shellcheck source=../config.env
	. "$ROOT_DIR/config.env"
	set +a
	DEB_VERSION="$AWG_VERSION-$DEB_REVISION"
	SRC_NAME="amneziawg-linux-kernel-module-$AWG_VERSION"
	SRC_TARBALL="$OUT_DIR/source/$SRC_NAME.tar.gz"
	export DEB_VERSION SRC_NAME SRC_TARBALL
}

# Print one field of an Alpine target from versions/targets.json.
# Usage: alpine_field <release> <flavor> <arch> <field>
alpine_field() {
	jq -er --arg r "$1" --arg f "$2" --arg a "$3" --arg k "$4" \
		'.alpine[] | select(.release == $r and .flavor == $f and .arch == $a) | .[$k]' \
		"$TARGETS_FILE" ||
		die "No Alpine target $1/$2/$3 in versions/targets.json"
}

# Alpine package release number. It always increases:
# a kernel package release change adds 100, a rebuild adds 1.
alpine_pkgrel() {
	local krel rebuild
	krel="$(alpine_field "$1" "$2" "$3" krel)"
	rebuild="$(alpine_field "$1" "$2" "$3" rebuild)"
	[ "$rebuild" -lt 100 ] || die "rebuild counter must be less than 100"
	echo $((krel * 100 + rebuild))
}

# Files that change the published packages, metadata, or start page (scripts/buildlib.py).
# The tests, the tracker, and the CI checks are not release inputs.
release_input_files() {
	python3 "$ROOT_DIR/scripts/buildlib.py" release-files
}

# Hash of the release inputs. The published tree records it in build-info.txt.
# The build workflow publishes when the published hash is different.
release_inputs_hash() {
	python3 "$ROOT_DIR/scripts/buildlib.py" release-hash
}

# Compare a new package with the published package that has the same file name.
# Usage: published_action <same content: yes|no> <published input hash> <new input hash>
# Prints one word:
#   same     The content is the same.
#   rebuilt  The content is different, but the package inputs are the same. Thus the build
#            tools changed (for example gcc or abuild from the Alpine repository).
#   changed  The package inputs changed, but the version did not increase.
published_action() {
	if [ "$1" = yes ]; then
		echo same
	elif [ -n "$2" ] && [ "$2" = "$3" ]; then
		echo rebuilt
	else
		echo changed
	fi
}
