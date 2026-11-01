#!/usr/bin/env bash
# Source this file in a CI step: ". scripts/ci-keys-env.sh"
# It exports APK_KEY_NAME, APK_PRIVATE_KEY, GPG_PRIVATE_KEY, GPG_PASSPHRASE, TRUSTED_KEYS_DIR.
#
# PUBLISH=true: the private keys come from the GitHub environment "release" (secrets).
#               The Alpine key name is RELEASE_APK_KEY_NAME in config.env.
#               The trusted public keys are in keys/.
# Other runs:   the keys come from out/ci-keys (temporary test keys from the "prepare" job).

if [ "${PUBLISH:-false}" = true ]; then
	APK_KEY_NAME="$(sed -n 's/^RELEASE_APK_KEY_NAME=//p' config.env)"
	for v in APK_KEY_NAME APK_PRIVATE_KEY GPG_PRIVATE_KEY; do
		if [ -z "${!v:-}" ]; then
			echo "::error::$v is not set. Add it to the GitHub environment \"release\" (see docs/manual-setup.md)." >&2
			exit 1
		fi
	done
	TRUSTED_KEYS_DIR=keys
else
	dir="${CI_KEYS_DIR:-out/ci-keys}"
	if [ ! -f "$dir/apk-key-name" ]; then
		echo "::error::$dir is missing. The prepare job makes the temporary test keys." >&2
		exit 1
	fi
	APK_KEY_NAME="$(cat "$dir/apk-key-name")"
	APK_PRIVATE_KEY="$(cat "$dir/apk-private-key")"
	GPG_PRIVATE_KEY="$(cat "$dir/gpg-private-key")"
	GPG_PASSPHRASE=""
	TRUSTED_KEYS_DIR="$dir/public"
fi
export APK_KEY_NAME APK_PRIVATE_KEY GPG_PRIVATE_KEY GPG_PASSPHRASE TRUSTED_KEYS_DIR
