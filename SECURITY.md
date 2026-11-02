# Security policy

This document tells how to report a security problem in the AmneziaWG package repository or
in this build repository.

## Scope

Report these problems here:

- A private signing key (APK or APT) or the deploy key became known to other persons.
- A package in the package repository has a signature that is not correct, or its content
  is not the content that this repository builds.
- A problem in the scripts or the workflows that can change the packages or the signing keys.

Report problems in the AmneziaWG kernel module source to the upstream project:
<https://github.com/amnezia-vpn/amneziawg-linux-kernel-module>.

## Report a problem

Do not open a public issue for a security problem. Use the private report function of GitHub:

1. Open <https://github.com/lqflqf/amneziawg-linux-kernel-module-build/security/advisories/new>.
2. Write the problem, the affected files or packages, and the steps to see the problem.

The maintainer examines each report. The maintainer tells you the result.

## Signing keys

The fingerprints of the trusted public keys are in [keys/FINGERPRINTS.md](keys/FINGERPRINTS.md).
If a private key became known to other persons, the maintainer does the procedure
"Emergency key change" in [docs/maintenance.md](docs/maintenance.md). Then the users must
install the new keys by hand. The `README.md` file tells how.
