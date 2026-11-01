#!/usr/bin/env bash
# Make reproducible source tarballs from the pinned upstream commits.
#
# Usage: scripts/fetch-upstream.sh [module|tools|all]
#   module: out/source/amneziawg-linux-kernel-module-<AWG_VERSION>.tar.gz
#           (patches/series applied, version set to AWG_VERSION)
#   tools : out/source/amneziawg-tools-<AWG_TOOLS_TAG>.tar.gz (for the tests only)
. "$(dirname "$0")/lib.sh"
load_config

# Clone <repo> at <commit> into <dir>. Make sure that <tag> points to <commit>.
fetch_commit() {
	local repo="$1" tag="$2" commit="$3" dir="$4" remote
	remote="$(git ls-remote "$repo" "refs/tags/$tag^{}" "refs/tags/$tag" |
		sort -k2 | tail -n 1 | cut -f1)"
	[ "$remote" = "$commit" ] ||
		die "Tag $tag of $repo points to '$remote', not to $commit"
	rm -rf "$dir"
	git init -q "$dir"
	git -C "$dir" fetch -q --depth 1 "$repo" "$commit"
	git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD
}

# Write <dir> as a reproducible tar.gz file with the top directory <name>.
make_tarball() {
	local dir="$1" name="$2" out="$3" epoch
	epoch="$(git -C "$dir" log -1 --format=%ct)"
	rm -rf "$dir/.git"
	mkdir -p "$(dirname "$out")"
	tar -C "$(dirname "$dir")" --sort=name --mtime="@$epoch" \
		--owner=0 --group=0 --numeric-owner --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
		--transform="s,^$(basename "$dir"),$name," -cf - "$(basename "$dir")" |
		gzip -9n >"$out"
	echo "$epoch" >"$out.epoch"
	log "Wrote $out"
}

fetch_module() {
	local work="$OUT_DIR/work/module"
	log "Get $AWG_REPO $AWG_TAG ($AWG_COMMIT)"
	fetch_commit "$AWG_REPO" "$AWG_TAG" "$AWG_COMMIT" "$work"

	local patch
	while read -r patch; do
		case "$patch" in '' | '#'*) continue ;; esac
		log "Apply patches/$patch"
		git -C "$work" apply --verbose "$ROOT_DIR/patches/$patch"
	done <"$ROOT_DIR/patches/series"

	# Upstream does not keep the version in src/Makefile and src/version.h up to date.
	# Set AWG_VERSION in both files. Then all build methods use the same version.
	sed -i -E "s/^WIREGUARD_VERSION = .*/WIREGUARD_VERSION = $AWG_VERSION/" "$work/src/Makefile"
	sed -i -E "s/^#define WIREGUARD_VERSION \".*\"/#define WIREGUARD_VERSION \"$AWG_VERSION\"/" "$work/src/version.h"
	grep -q "^WIREGUARD_VERSION = $AWG_VERSION\$" "$work/src/Makefile" || die "Cannot set the version in src/Makefile"
	grep -q "\"$AWG_VERSION\"" "$work/src/version.h" || die "Cannot set the version in src/version.h"

	make_tarball "$work" "$SRC_NAME" "$SRC_TARBALL"
}

fetch_tools() {
	local work="$OUT_DIR/work/tools"
	log "Get $AWG_TOOLS_REPO $AWG_TOOLS_TAG ($AWG_TOOLS_COMMIT)"
	fetch_commit "$AWG_TOOLS_REPO" "$AWG_TOOLS_TAG" "$AWG_TOOLS_COMMIT" "$work"
	make_tarball "$work" "amneziawg-tools" "$OUT_DIR/source/amneziawg-tools.tar.gz"
}

case "${1:-all}" in
module) fetch_module ;;
tools) fetch_tools ;;
all) fetch_module && fetch_tools ;;
*) die "Usage: $0 [module|tools|all]" ;;
esac
