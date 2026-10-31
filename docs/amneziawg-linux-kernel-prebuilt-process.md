# AmneziaWG Package Repository: Build and Release Process

## 1. Create two GitHub repositories

-   **`amneziawg-linux-kernel-module-build`**: Store package recipes, patches, build
    scripts, and GitHub Actions workflows. It is this repo
-   **`amneziawg-linux-kernel-module-packages`**: Store built packages, repository indexes,
    and public signing keys.

Keep the upstream AmneziaWG Linux Kernel Module source repository unchanged. The upstream AmneziaWG Linux Kernel Module source repository is https://github.com/amnezia-vpn/amneziawg-linux-kernel-module

## 2. Define the package targets

### Alpine Linux

-   Build pre-compiled APK packages.
-   Build each package for a specific Alpine release, kernel flavor,
    kernel ABI, and CPU architecture.
-   Start with Alpine 3.24 and 3.23.
-   Start with the `virt` and `lts` kernel flavors.
-   Start with `x86_64` and `aarch64`.
-   Rebuild a package when its target kernel ABI changes.

### Debian

-   Build one `amneziawg-dkms` DEB package.
-   Set the package architecture to `all`.
-   Support Debian 13 (Trixie) and Debian 12 (Bookworm).
-   Let DKMS build the kernel module on the target system.
-   Require matching kernel headers and a working kernel build
    environment.
-   Do not require the full Linux source tree by default. Test the build
    against each supported kernel.

## 3. Build packages with GitHub Actions

For each release:

1.  Select a fixed AmneziaWG upstream tag or commit.
2.  Build the Alpine APK packages for the target matrix.
3.  Build the Debian DKMS package.
4.  Run package and installation tests.
5.  Sign the packages and repository metadata.
6.  Publish the output to `amneziawg-packages`.

Use separate jobs or workflow steps for each target. Keep the build
inputs and versions fixed.

## 4. Sign and publish the repositories

-   Use GitHub Pages to host the package repository.
-   Publish APK files and the Alpine repository index.
-   Publish DEB files and the APT repository metadata (`Packages` and
    `Release`).
-   Sign the APT repository metadata.
-   Use `Signed-By` in the APT source configuration.
-   Publish the public signing key with the installation instructions.
-   Store private signing keys in GitHub Actions secrets or a protected
    signing environment. Never commit private keys.

GitHub Releases can also store build artifacts. Use GitHub Pages for the
package indexes and client configuration.

## 5. Test installation on clean systems

Test each supported target before release.

-   Install the APK on the matching Alpine release and kernel flavor.
-   Install the DEB on Debian 12 and Debian 13.
-   For Debian, confirm that DKMS builds the module for the running
    kernel.
-   Load the module and check that the AmneziaWG interface works.
-   Check the build log when a test fails.

## 6. Maintain the repository

-   Track upstream AmneziaWG releases.
-   Rebuild Alpine packages after a target kernel ABI change.
-   Rebuild and test the Debian DKMS package for new kernel versions.
-   Keep package versions, checksums, and repository indexes in sync.
-   Remove packages that are no longer supported.

## Recommended first milestone

Start with two test targets:

1.  Alpine 3.24, `virt`, `x86_64`.
2.  Debian 13, `amd64`, using the official kernel headers and DKMS.

Make both targets build, install, and load successfully. Then add more
Alpine flavors, releases, and architectures.
