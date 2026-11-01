# AmneziaWG kernel module packages

This repository builds packages of the
[AmneziaWG Linux kernel module](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module).
GitHub Actions builds, tests, and signs the packages. The packages are in the package
repository at <https://lqflqf.github.io/amneziawg-linux-kernel-module-packages>.

- **Alpine Linux**: pre-compiled modules (APK). Each package is for one kernel version.
- **Debian**: one DKMS package (DEB). DKMS compiles the module on your system.

This repository does not supply the `awg` tool. To configure an interface, install
[amneziawg-tools](https://github.com/amnezia-vpn/amneziawg-tools).

## Supported systems

| System | Release | Kernel | Architecture | Package |
|---|---|---|---|---|
| Alpine Linux | 3.24, 3.23 | `linux-virt`, `linux-lts` | `x86_64`, `aarch64` | `amneziawg-virt`, `amneziawg-lts` |
| Debian | 13 (trixie), 12 (bookworm) | Debian kernels with headers | `amd64`, `arm64` | `amneziawg-dkms` |

Run all commands in this document as `root`.

## Install on Alpine Linux

1. Find the kernel flavor. The output of `uname -r` ends with `-virt` or `-lts`.

   ```sh
   uname -r
   ```

2. Install the public key of the package repository.

   ```sh
   wget -O /etc/apk/keys/amneziawg-packages.rsa.pub \
     https://lqflqf.github.io/amneziawg-linux-kernel-module-packages/keys/amneziawg-packages.rsa.pub
   ```

   Compare the key with the value in [keys/FINGERPRINTS.md](https://github.com/lqflqf/amneziawg-linux-kernel-module-build/blob/main/keys/FINGERPRINTS.md). This file is in the build
   repository, not in the package repository. If the values are different, do not continue.

   ```sh
   sha256sum /etc/apk/keys/amneziawg-packages.rsa.pub
   ```

3. Add the package repository for your Alpine release.

   ```sh
   echo "https://lqflqf.github.io/amneziawg-linux-kernel-module-packages/alpine/v$(cut -d. -f1,2 /etc/alpine-release)/main" \
     >> /etc/apk/repositories
   ```

4. Install the package for your kernel flavor and the keyring package. Use `amneziawg-lts`
   for the `lts` kernel. The keyring package `amneziawg-keys` installs new keys when the
   repository changes its keys.

   ```sh
   apk update
   apk add amneziawg-keys amneziawg-virt
   ```

5. Compare the kernel version of the package with the running kernel.

   ```sh
   apk info -L amneziawg-virt | grep amneziawg.ko
   uname -r
   ```

   If the versions are different, `apk` installed a newer kernel. Reboot the system.

6. Load the module and examine the version.

   ```sh
   modprobe amneziawg
   cat /sys/module/amneziawg/version
   ```

7. Load the module each time the system starts.

   ```sh
   echo amneziawg >> /etc/modules
   ```

### Kernel updates on Alpine Linux

Each package agrees with only one kernel version. The package has a dependency on that
exact version (for example `linux-virt=6.18.59-r0`). Thus `apk upgrade` does not install a
new kernel before the package for that kernel is available.

- A workflow examines the Alpine kernel versions each day.
- When Alpine releases a new kernel, the workflow builds a new package.
- If `apk upgrade` shows a conflict for `linux-virt` or `linux-lts`, wait for the new package.
  Then run `apk update` and `apk upgrade` again.

## Install on Debian

1. Install DKMS and the kernel headers for the running kernel.

   ```sh
   apt update
   apt install dkms "linux-headers-$(uname -r)" curl ca-certificates
   ```

2. Install the kernel headers metapackage. Then DKMS can compile the module for new kernels.
   Use the metapackage that agrees with your kernel, for example:

   ```sh
   apt install linux-headers-amd64        # amd64, standard kernel
   apt install linux-headers-arm64        # arm64, standard kernel
   apt install linux-headers-cloud-amd64  # amd64, cloud kernel
   ```

3. Install the public key of the package repository.

   ```sh
   curl -fsSL -o /usr/share/keyrings/amneziawg-archive-keyring.gpg \
     https://lqflqf.github.io/amneziawg-linux-kernel-module-packages/keys/amneziawg-archive-keyring.gpg
   ```

   Compare the fingerprints with the values in [keys/FINGERPRINTS.md](https://github.com/lqflqf/amneziawg-linux-kernel-module-build/blob/main/keys/FINGERPRINTS.md). This file is in the
   build repository, not in the package repository. If the values are different, do not continue.

   ```sh
   gpg --show-keys /usr/share/keyrings/amneziawg-archive-keyring.gpg
   ```

4. Add the package repository. This command uses the Debian release of your system.

   ```sh
   cat > /etc/apt/sources.list.d/amneziawg.sources <<EOF
   Types: deb
   URIs: https://lqflqf.github.io/amneziawg-linux-kernel-module-packages/debian
   Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
   Components: main
   Signed-By: /usr/share/keyrings/amneziawg-archive-keyring.gpg
   EOF
   ```

5. Install the package and the keyring package. DKMS compiles and installs the module. This
   can take some minutes. The keyring package `amneziawg-archive-keyring` installs new keys
   when the repository changes its keys.

   ```sh
   apt update
   apt install amneziawg-dkms amneziawg-archive-keyring
   ```

6. Make sure that DKMS installed the module for the running kernel.

   ```sh
   dkms status amneziawg
   ```

   The output must show `installed` for the kernel version from `uname -r`.

7. Load the module and examine the version.

   ```sh
   modprobe amneziawg
   cat /sys/module/amneziawg/version
   ```

8. Load the module each time the system starts.

   ```sh
   echo amneziawg > /etc/modules-load.d/amneziawg.conf
   ```

### Secure Boot on Debian

If Secure Boot is on, the kernel loads only signed modules. DKMS signs the module with a
local key (MOK). You must enroll this key one time.

1. Enroll the DKMS key. Enter a temporary password when the command asks for it.

   ```sh
   mokutil --import /var/lib/dkms/mok.pub
   ```

2. Reboot the system. In the blue MOK manager screen, select **Enroll MOK**.
   Enter the temporary password.
3. Load the module again with `modprobe amneziawg`.

## Make a test interface

After you install `amneziawg-tools`, you can make an interface:

```sh
ip link add dev awg0 type amneziawg
awg show awg0
ip link del dev awg0
```

## Upgrade the packages

- Alpine Linux: `apk update && apk upgrade`. Reboot if a new kernel was installed.
- Debian: `apt update && apt upgrade`. DKMS compiles the new module version.
  Reboot, or unload and load the module again. The interfaces stop during this step.

## Remove the packages

- Alpine Linux: `apk del amneziawg-virt amneziawg-keys` (or `amneziawg-lts`).
  Then remove the repository line from `/etc/apk/repositories`.
- Debian: `apt purge amneziawg-dkms amneziawg-archive-keyring`.
  Then remove `/etc/apt/sources.list.d/amneziawg.sources`.

## Troubleshooting

| Problem | Cause | Action |
|---|---|---|
| `apk`: `UNTRUSTED signature` | The public key is not installed. | Do step 2 of the Alpine procedure again. |
| `apk`: conflict for `linux-virt` or `linux-lts` | The package for the new kernel is not available yet. | Wait one day. Then try again. |
| `modprobe`: `Module amneziawg not found` (Alpine) | The running kernel is not the kernel of the package. | Reboot into the new kernel. |
| `apt`: `NO_PUBKEY` or `not signed` | The keyring file is missing or old. | Do step 3 of the Debian procedure again. Then install `amneziawg-archive-keyring`. |
| `apt`: `Release file ... is expired` | The repository did not sign its metadata again in time. | Wait one day. If the problem continues, open an issue in the build repository. |
| `dkms status` does not show `installed` | The kernel headers are missing, or the compilation failed. | Install `linux-headers-$(uname -r)`. Then run `dkms autoinstall`. Read `/var/lib/dkms/amneziawg/<version>/build/make.log`. |
| `modprobe`: `Key was rejected by service` | Secure Boot is on and the DKMS key is not enrolled. | Do the Secure Boot procedure. |

## Key changes

The repository can change its signing keys. Before a change, the repository publishes the new
key together with the old key for some time. The keyring packages `amneziawg-keys` and
`amneziawg-archive-keyring` install the new key with a normal upgrade. If you did not install
the keyring packages, download the keys again (step 2 on Alpine Linux, step 3 on Debian).
The current fingerprints are always in [keys/FINGERPRINTS.md](https://github.com/lqflqf/amneziawg-linux-kernel-module-build/blob/main/keys/FINGERPRINTS.md).

## Information for maintainers

- [Build and release process](https://github.com/lqflqf/amneziawg-linux-kernel-module-build/blob/main/docs/amneziawg-linux-kernel-prebuilt-process.md)
- [Manual setup steps](https://github.com/lqflqf/amneziawg-linux-kernel-module-build/blob/main/docs/manual-setup.md)
- [Maintenance procedures](https://github.com/lqflqf/amneziawg-linux-kernel-module-build/blob/main/docs/maintenance.md)

## License

The AmneziaWG kernel module is licensed under GPL-2.0. The packaging files in this
repository are licensed under GPL-2.0.
