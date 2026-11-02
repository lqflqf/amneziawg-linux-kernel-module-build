#!/usr/bin/env bats
# Tests of scripts/container.sh with a fake "docker" command.

setup() {
	ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	unset OUT_DIR TARGETS_FILE CONTAINER_NETWORK GITHUB_ACTIONS
	bin="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$bin"
	# The fake docker writes its arguments to docker.log. "docker run" fails if FAIL_RUN is set.
	cat >"$bin/docker" <<'SH'
#!/bin/sh
echo "$*" >>"$BATS_TEST_TMPDIR/docker.log"
[ "$1" = run ] && [ -n "${FAIL_RUN:-}" ] && exit 1
exit 0
SH
	chmod +x "$bin/docker"
	PATH="$bin:$PATH"
	# shellcheck source=../versions/build.env
	. "$ROOT/versions/build.env"
}

@test "an image name gives the pinned reference" {
	run "$ROOT/scripts/container.sh" alpine-3.24 true
	[ "$status" -eq 0 ]
	grep -qF -- "-v $ROOT:/w -w /w -e OUT_DIR=/w/out $IMAGE_ALPINE_3_24 true" "$BATS_TEST_TMPDIR/docker.log"
}

@test "DEB_BUILD_IMAGE is a pinned image" {
	run "$ROOT/scripts/container.sh" --offline "$DEB_BUILD_IMAGE" true
	[ "$status" -eq 0 ]
	grep -qF -- "--network none" "$BATS_TEST_TMPDIR/docker.log"
	grep -qF -- "$IMAGE_DEBIAN_TRIXIE true" "$BATS_TEST_TMPDIR/docker.log"
}

@test "an unknown image stops" {
	run "$ROOT/scripts/container.sh" alpine-9.99 true
	[ "$status" -eq 1 ]
	[[ "$output" == *"IMAGE_ALPINE_9_99 is not set"* ]]
}

@test "OUT_DIR outside the repository stops" {
	OUT_DIR="$BATS_TEST_TMPDIR/out" run "$ROOT/scripts/container.sh" alpine-3.24 true
	[ "$status" -eq 1 ]
	[[ "$output" == *"OUT_DIR must be"* ]]
}

@test "--make-signer uses SIGNER_BASE" {
	run "$ROOT/scripts/container.sh" --make-signer
	[ "$status" -eq 0 ]
	ref="IMAGE_$(echo "$SIGNER_BASE" | tr '.a-z-' '_A-Z_')"
	grep -qF -- "${!ref} apk add" "$BATS_TEST_TMPDIR/docker.log"
}

@test "--make-signer removes the container if the build fails" {
	FAIL_RUN=1 run "$ROOT/scripts/container.sh" --make-signer
	[ "$status" -ne 0 ]
	grep -q '^rm -f amneziawg-signer-build-' "$BATS_TEST_TMPDIR/docker.log"
	! grep -q '^commit' "$BATS_TEST_TMPDIR/docker.log"
}
