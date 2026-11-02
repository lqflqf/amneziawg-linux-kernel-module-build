#!/usr/bin/env bats
# Tests of scripts/lib.sh.

setup() {
	ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	unset GITHUB_ACTIONS TARGETS_FILE
	# shellcheck source=../scripts/lib.sh
	. "$ROOT/scripts/lib.sh"
	set +e
}

@test "alpine_pkgrel is krel * 100 + rebuild" {
	TARGETS_FILE="$BATS_TEST_TMPDIR/targets.json"
	echo '{"alpine": [{"release": "3.24", "flavor": "virt", "arch": "x86_64", "kver": "6.1", "krel": 3, "rebuild": 7}]}' >"$TARGETS_FILE"
	run alpine_pkgrel 3.24 virt x86_64
	[ "$status" -eq 0 ]
	[ "$output" = 307 ]
}

@test "alpine_pkgrel stops if the rebuild counter is 100" {
	TARGETS_FILE="$BATS_TEST_TMPDIR/targets.json"
	echo '{"alpine": [{"release": "3.24", "flavor": "virt", "arch": "x86_64", "kver": "6.1", "krel": 3, "rebuild": 100}]}' >"$TARGETS_FILE"
	run alpine_pkgrel 3.24 virt x86_64
	[ "$status" -eq 1 ]
	[[ "$output" == *"rebuild counter must be less than 100"* ]]
}

@test "alpine_pkgrel stops for an unknown target" {
	run alpine_pkgrel 9.99 virt x86_64
	[ "$status" -eq 1 ]
	[[ "$output" == *"No Alpine target 9.99/virt/x86_64"* ]]
}

@test "release_inputs_hash agrees with sha256sum of the release input files" {
	expected="$(cd "$ROOT" && release_input_files | xargs sha256sum | sha256sum | cut -d' ' -f1)"
	run release_inputs_hash
	[ "$status" -eq 0 ]
	[ "$output" = "$expected" ]
}

@test "published_action" {
	[ "$(published_action yes "" new)" = same ]
	[ "$(published_action yes old new)" = same ]
	[ "$(published_action no abc abc)" = rebuilt ]
	[ "$(published_action no old new)" = changed ]
	# A published tree without package-inputs.txt.
	[ "$(published_action no "" new)" = changed ]
}

@test "load_config sets DEB_VERSION" {
	load_config
	[ "$DEB_VERSION" = "$AWG_VERSION-$DEB_REVISION" ]
	[ -n "$SIGNER_BASE" ] && [ -n "$DEB_BUILD_IMAGE" ]
}

@test "die writes a GitHub error annotation in GitHub Actions" {
	GITHUB_ACTIONS=true run die "broken"
	[ "$status" -eq 1 ]
	[ "$output" = "::error::broken" ]
}
