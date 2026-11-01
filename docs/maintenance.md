# Maintenance procedures

This document tells how to keep the package repository up to date. For the one-time
setup, see [manual-setup.md](manual-setup.md). For the design, see
[amneziawg-linux-kernel-prebuilt-process.md](amneziawg-linux-kernel-prebuilt-process.md).

## How the workflows operate

| Workflow | Starts on | Result |
|---|---|---|
| `build.yml` | Pull request | Builds and tests all targets. Uses temporary test keys. Publishes nothing. |
| `build.yml` | Push to `main`, and the release inputs are different from the published release inputs | Builds, tests, signs with the release keys, and publishes. |
| `build.yml` | Manual run with `publish=true` on `main` | Builds, tests, signs, and publishes. |
| `track-updates.yml` | Each day, or a manual run | Finds new versions and opens one pull request. Opens an issue if an APT key expires in fewer than 90 days. |
| `refresh-metadata.yml` | Each week, or a manual run | Signs the APT metadata again. The packages do not change. |

The build workflow has these jobs:

1. `prepare`: decides if the run publishes, reads `versions/targets.json`, gets the upstream
   source, and makes the temporary test keys (not for a release).
2. `lint`: checks the documents (ASD-STE100), `keys/FINGERPRINTS.md`, and the version
   increases (pull requests only).
3. `build-apk`: builds one APK for each Alpine target. The `aarch64` targets use the
   `ubuntu-24.04-arm` runners.
4. `build-deb`: builds `amneziawg-dkms`.
5. `dkms-check`: compiles the module with DKMS and only the locked kernel headers, for each
   Debian suite and architecture.
6. `assemble`: signs the APKs, builds the keyring packages, verifies the published Debian
   packages, and signs the indexes.
7. `vm-test-alpine` and `vm-test-debian`: install the packages from the signed repository in
   clean QEMU VMs. They load the module and send packets through a tunnel.
8. `required` (check name `Required build checks`): fails if one of the jobs above failed.
   The branch rules use only this check.
9. `publish`: pushes the tested tree to the package repository.

The publish job publishes the same files that the VM tests used.

### Security design

- The jobs that run upstream build code (`build-apk`, `build-deb`, `dkms-check`) get no
  secrets. `build-apk` signs with a temporary key in the container.
- Only the `assemble` job uses the private keys. It runs no upstream code. It signs the APKs
  and the Alpine indexes in the signer container without network access.
- The build repository contains the trusted public keys (`keys/`). A release publishes only
  these keys. The `assemble` job keeps an old Debian package only if a signed index of a key in
  `keys/apt` lists it with the same SHA-256. Other files in the package repository are removed.
- A release stops if a new package has the same file name as a published package but a
  different content. Thus a published file does not change without a new version.
- All actions are pinned to a commit SHA. All container images are pinned to a digest.

### Publish decision

The file `build-info.txt` in the package repository contains a hash of the release inputs
(`scripts/release-hash.sh`). The release inputs are `versions/`, `config.env`, `alpine/`,
`debian/`, `patches/`, `keys/`, `README.md`, and the scripts in `scripts/` that make the
packages and the repository. The tests and the CI checks are not release inputs.

Each push to `main` compares the hash with the published hash. If they are different, the run
publishes. Thus, if a publish run is canceled or fails, the next run on `main` publishes.

## Version files

All build inputs are in `versions/`. Do not use other places for versions.

### `versions/upstream.env`

| Name | Meaning |
|---|---|
| `AWG_TAG`, `AWG_COMMIT` | Upstream tag and commit. The build stops if the tag does not point to the commit. |
| `AWG_VERSION` | Module version. The build writes it into `src/Makefile` and `src/version.h`. |
| `DEB_REVISION` | Debian revision. The Debian version is `<AWG_VERSION>-<DEB_REVISION>`. |
| `AWG_TOOLS_TAG`, `AWG_TOOLS_COMMIT` | `amneziawg-tools` for the VM tests only. |

### `versions/build.env`

| Name | Meaning |
|---|---|
| `IMAGE_ALPINE_*`, `IMAGE_DEBIAN_*` | Container images, pinned by digest. |
| `DEBIAN_SNAPSHOT` | The `snapshot.debian.org` time stamp for the Debian build tools. |
| `KEYS_VERSION` | Version of the keyring packages. |
| `KEYS_EPOCH` | Fixed time stamp of the files in the keyring packages. |

### `versions/targets.json`

- `alpine[]`: one entry for each package.
  - `kver`, `krel`: the Alpine kernel package `linux-<flavor>-<kver>-r<krel>`.
  - `rebuild`: a counter for rebuilds with the same kernel.
  - The APK version is `<kver>-r<krel * 100 + rebuild>`. This number always increases.
- `debian[]`: one entry for each suite and architecture.
  - `headers`: the `linux-headers-<arch>` version. The DKMS check installs exactly this
    version. If Debian replaced it, the check fails. Then run `track-updates`.

`scripts/check-updates.py` writes this file. Keep its format (one target on each line).

## Normal operation

1. The `track-updates` workflow opens a pull request with the name
   "Update the AmneziaWG and kernel versions".
2. The build workflow builds and tests the pull request.
3. Examine the results. If all checks pass, merge the pull request.
4. The push to `main` publishes the new packages.

If a check fails, see [When a test fails](#when-a-test-fails).

## Change the packaging files

A change to a package input must also increase the package version. The `lint` job
(`scripts/check-version-bump.py`) stops a pull request that does not do this.

| Changed input | Required version change |
|---|---|
| `alpine/APKBUILD.in`, `alpine/depmod.sh.in`, `scripts/build-apk.sh`, `IMAGE_ALPINE_*` | Increase `rebuild` of each Alpine target in `versions/targets.json`. |
| `debian/`, `scripts/build-deb.sh`, `IMAGE_DEBIAN_TRIXIE`, `DEBIAN_SNAPSHOT` | Increase `DEB_REVISION` in `versions/upstream.env`. |
| `debian/copyright` | Also increase `KEYS_VERSION` (the keyring DEB contains this file). |
| `patches/`, `scripts/fetch-upstream.sh`, the upstream commit | Both of the changes above (or a new `AWG_VERSION`). |
| `keys/apk/`, `keys/apt/`, `alpine/keys/`, `scripts/build-keyring-packages.sh`, `scripts/keys.sh`, `APT_KEYRING_NAME`, `KEYS_EPOCH` | Increase `KEYS_VERSION` in `versions/build.env`. |

To test the rule on your computer:

```sh
python3 scripts/check-version-bump.py origin/main
```

## Reproducible builds

The builds are reproducible: the same inputs give the same files. The release uses this
property. If a new package has the same name as a published package, the content must be the
same. If it is not the same, the release stops with the message "the new build is different
from the published package with the same version". Then increase the version as in
[Change the packaging files](#change-the-packaging-files).

- The Alpine build sets `-frandom-seed`. Without it, the `latent_entropy` GCC plugin of the
  kernel adds random values.
- The Alpine build uses the current Alpine packages (for example `gcc` and `abuild`). Alpine
  does not keep old package versions. If Alpine updates them in a stable release, the next
  release can stop. The message tells which version to increase: `rebuild` for the module
  packages, `KEYS_VERSION` for `amneziawg-keys`.
- The Debian build uses the packages of `DEBIAN_SNAPSHOT`.

## Update the container images or the Debian snapshot

1. Get the new digests:

   ```sh
   for i in alpine:3.24 alpine:3.23 debian:trixie debian:bookworm; do
     echo "$i $(docker buildx imagetools inspect "$i" | awk '/^Digest:/ {print $2; exit}')"
   done
   ```

2. Change `versions/build.env`. To use a new snapshot, set `DEBIAN_SNAPSHOT` to a time stamp
   in the format `YYYYMMDDTHHMMSSZ`.
3. Increase the versions as in [Change the packaging files](#change-the-packaging-files).
4. Open a pull request. Merge it when all checks pass.

## Use a different upstream version

1. Find the tag and the commit:

   ```sh
   git ls-remote https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git 'refs/tags/*'
   ```

2. Set `AWG_TAG`, `AWG_COMMIT`, and `AWG_VERSION` in `versions/upstream.env`.
   Set `DEB_REVISION=1`.
3. Increase `rebuild` for each Alpine target.
4. Open a pull request. Merge it when all checks pass.

## Add a patch

1. Put the patch file in `patches/`. Make the patch with `git diff` from the upstream root.
2. Add the file name to `patches/series`.
3. Increase the versions as in [Change the packaging files](#change-the-packaging-files).

## Add or remove a target

- Add an Alpine target: add an entry to `alpine[]`. Use the current kernel version from
  `scripts/check-updates.py --dry-run`. Set `rebuild` to 0.
- Add a Debian suite or architecture: add an entry to `debian[]`.
- Remove a target: remove its entry. The next release removes its packages and indexes from
  the package repository. Tell the users before you remove a target.

## Test on your computer

You need Docker. For the VM tests, you also need QEMU, `qemu-utils`, `cloud-image-utils`, and KVM.

```sh
scripts/fetch-upstream.sh all
scripts/keys.sh generate out/ci-keys
export APK_KEY_NAME="$(cat out/ci-keys/apk-key-name)"
export APK_PRIVATE_KEY="$(cat out/ci-keys/apk-private-key)"
export GPG_PRIVATE_KEY="$(cat out/ci-keys/gpg-private-key)"

# Use a smaller list of targets.
jq '.alpine |= map(select(.release == "3.24" and .flavor == "virt" and .arch == "x86_64"))' \
  versions/targets.json > out/targets-local.json
export TARGETS_FILE="$PWD/out/targets-local.json"

scripts/container.sh alpine-3.24 sh -c 'apk add -q bash jq && scripts/build-apk.sh 3.24 virt x86_64'
scripts/container.sh debian-trixie bash -c 'scripts/build-deb.sh'
scripts/container.sh debian-trixie \
  bash -c 'apt-get update -q && apt-get install -y -q jq && scripts/dkms-check.sh trixie amd64'

scripts/container.sh --make-signer
scripts/assemble-site.sh --out out/site --trusted-keys out/ci-keys/public
scripts/test/run-vm-test.sh alpine 3.24 virt x86_64
scripts/test/run-vm-test.sh debian trixie amd64
```

If the Docker network is slow or stops, set `CONTAINER_NETWORK=host`.

If downloads in the VM are slow, use `VM_SETUP_CMD` to change the network settings of the
VM before the test. For example, use the IPv6 address of the Debian mirror:

```sh
VM_SETUP_CMD="echo '$(getent ahostsv6 deb.debian.org | awk '{print $1; exit}') deb.debian.org' >> /etc/hosts" \
  scripts/test/run-vm-test.sh debian trixie amd64
```

## When a test fails

1. Open the failed job in the workflow run.
2. For a VM test, download the artifact `vm-logs-...`. It contains:
   - `console.log`: the serial console of the VM.
   - `dmesg.log`: the kernel messages.
   - `http.log`: the requests to the local package repository.
3. For a DKMS failure, the job log shows `make.log` from DKMS.

| Message | Cause | Action |
|---|---|---|
| `The repository has 'linux-...', but versions/targets.json has ...` | Alpine released a new kernel. | Run `track-updates`, or update `kver` and `krel`. |
| `Cannot install linux-headers-...=... The lock is old.` | Debian released new kernel headers. | Run `track-updates`. |
| `Tag ... points to ..., not to ...` | The upstream tag moved. | Examine the upstream change. Then set `AWG_COMMIT`. |
| `DKMS build failed` | The module does not compile with this kernel. | Add a patch, or wait for an upstream fix. |
| `the new build is different from the published package` | Same version, different content. | Increase the version that the message gives. |
| `does not agree with the signed ...` or `Signature of ... is not correct` | A file in the package repository changed without a valid signature. | Stop. Examine the package repository and the deploy key. Replace the deploy key. |
| `Running kernel is ..., not ...` | The VM did not start the expected kernel. | Examine `console.log`. Examine the cloud image kernel flavor. |
| `TUNNEL TEST FAILED` | The module or the tools do not operate correctly. | Examine `dmesg.log` and the job log. |

The `aarch64` and `arm64` VM tests use QEMU without KVM. They are slow. If they stop at the
time limit, increase `timeout-minutes` in `build.yml` or `VM_TIMEOUT`.

## Replace a signing key

Replace a key before it expires, or immediately if it becomes known to other persons.
Use two releases. Then users who installed the keyring packages get the new key before the
repository uses it.

### Release 1: publish the new key together with the old key

1. Make a new key with a new file name. Use the procedure in
   [manual-setup.md](manual-setup.md#step-6-make-the-alpine-signing-key) or
   [manual-setup.md](manual-setup.md#step-7-make-the-apt-signing-key), but do not change the
   secrets yet.
   - Alpine: for example `keys/apk/amneziawg-packages-2.rsa.pub`.
   - APT: for example `keys/apt/amneziawg-archive-key-2.asc`.
2. Keep the old public key in `keys/`.
3. Run `scripts/keys.sh fingerprints keys > keys/FINGERPRINTS.md`.
4. Increase `KEYS_VERSION`. Merge the change. The release publishes both keys, and the keyring
   packages install both keys. The old key still signs.
5. Tell the users about the new key. Wait some weeks.

### Release 2: sign with the new key

1. Replace the secret `APK_PRIVATE_KEY` or `GPG_PRIVATE_KEY` (and `GPG_PASSPHRASE`).
2. Alpine: set `RELEASE_APK_KEY_NAME` in `config.env` to the new name, and change the key name
   in `README.md`. Increase `rebuild` for all Alpine targets. Then all packages get the new
   signature.
3. Merge the change. The release signs with the new key.
4. Some weeks later, remove the old public key from `keys/`. Run the fingerprints command and
   increase `KEYS_VERSION` again.

### Emergency key change

Use this procedure if a private key became known to other persons. Do not use the two-release
procedure above. The users must install the new keys by hand.

1. Make new keys with new file names. Replace the secrets `APK_PRIVATE_KEY`,
   `GPG_PRIVATE_KEY`, and `GPG_PASSPHRASE` immediately.
2. In one pull request:
   - Remove the old public keys from `keys/`. Add the new public keys.
   - Run `scripts/keys.sh fingerprints keys > keys/FINGERPRINTS.md`.
   - Set `RELEASE_APK_KEY_NAME` in `config.env`. Change the key name in `README.md`.
   - Increase `KEYS_VERSION`, `rebuild` of all Alpine targets, and `DEB_REVISION`.
3. The pull request checks pass with a warning: the published Debian packages cannot be
   verified with the new keys. Merge the pull request.
4. The push to `main` stops in the `assemble` job for the same reason. This is correct.
   Start a release by hand that keeps no published file:

   ```sh
   gh workflow run build.yml --repo lqflqf/amneziawg-linux-kernel-module-build \
     --ref main -f publish=true -f distrust_published=true
   ```

5. The `refresh-metadata` workflow fails until this release is published. After the release,
   it operates again.
6. Tell the users to download the keys again and to compare the fingerprints (step 2 on
   Alpine Linux, step 3 on Debian in `README.md`). The old versions of the Debian packages are
   not available after this release.

## Retention and history

- Alpine: the package repository keeps only the current package of each target.
  The Alpine mirrors also keep only the current kernel.
- Debian: the package repository keeps the newest `DEB_KEEP_VERSIONS` versions of each
  package (see `config.env`).
- Public keys: only the keys in `keys/` are published.
- Git history: each publish and each refresh replaces the branch `main` of the package
  repository with one new commit (`scripts/push-site.sh`). Thus deleted packages do not stay
  in the Git history. The build workflow runs keep the history of the releases.
- APT metadata: the `Release` files are valid for `APT_VALID_DAYS` days. The
  `refresh-metadata` workflow signs them again each week. If it fails for some weeks, `apt`
  shows the error `Release file ... is expired`. Then run it by hand.
