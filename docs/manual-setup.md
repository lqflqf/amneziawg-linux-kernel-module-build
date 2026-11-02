# Manual setup steps

This document gives the steps that you must do one time by hand. The workflows cannot do these
steps, because they need administrator access or private keys.

Do the steps in the given sequence.

## Before you start

- You must have administrator access to `lqflqf/amneziawg-linux-kernel-module-build`.
- You must be able to make a new repository in the `lqflqf` account.
- Use a Linux computer that you trust. The procedure keeps the private keys in `/dev/shm`.
  This directory is in memory, thus the keys are not written to a disk.
- Install these tools: `git`, `gh` (GitHub CLI), `gpg`, `openssl`, and `ssh-keygen`.
- Log in to the GitHub CLI:

  ```sh
  gh auth login
  ```

- Clone the build repository. Do the steps in the clone.

  ```sh
  git clone https://github.com/lqflqf/amneziawg-linux-kernel-module-build.git
  cd amneziawg-linux-kernel-module-build
  ```

## Names in this document

| Item | Value |
|---|---|
| Build repository | `lqflqf/amneziawg-linux-kernel-module-build` |
| Package repository | `lqflqf/amneziawg-linux-kernel-module-packages` |
| Package repository URL | `https://lqflqf.github.io/amneziawg-linux-kernel-module-packages` |
| GitHub environment for releases | `release` |
| Alpine key file name | `amneziawg-packages.rsa` (`RELEASE_APK_KEY_NAME` in `config.env`) |
| APT public key file | `keys/apt/amneziawg-archive-key-1.asc` |

## Step 1: Make the package repository

1. Make a public repository. GitHub Pages for free accounts needs a public repository.

   ```sh
   gh repo create lqflqf/amneziawg-linux-kernel-module-packages --public \
     --description "Signed AmneziaWG kernel module packages for Alpine Linux and Debian"
   ```

2. Push a first commit to the branch `main`.

   ```sh
   git clone https://github.com/lqflqf/amneziawg-linux-kernel-module-packages.git /tmp/packages
   cd /tmp/packages
   git checkout -b main
   touch .nojekyll
   echo "The publish workflow writes the files in this repository." > README.md
   git add .nojekyll README.md
   git commit -m "Start the package repository"
   git push -u origin main
   cd -
   rm -rf /tmp/packages
   ```

   The `.nojekyll` file stops the Jekyll processing of GitHub Pages.

3. Do not protect the branch `main` of the package repository. The publish job replaces the
   branch with one new commit each time (force push). Then the old package files do not stay
   in the Git history.

## Step 2: Turn on GitHub Pages

1. Set GitHub Pages to use the branch `main` and the root folder.

   ```sh
   gh api -X POST repos/lqflqf/amneziawg-linux-kernel-module-packages/pages \
     -f "source[branch]=main" -f "source[path]=/"
   ```

   You can also use the web page: **Settings** > **Pages** > **Build and deployment** >
   **Source**: `Deploy from a branch`, **Branch**: `main`, `/ (root)`.

2. Make sure that the site works. This can take some minutes.

   ```sh
   curl -fsS https://lqflqf.github.io/amneziawg-linux-kernel-module-packages/README.md
   ```

## Step 3: Make the release environment

The `release` environment keeps the signing keys and the deploy key. Only the branch `main`
can use this environment.

1. Make the environment, and allow only the branch `main`.

   ```sh
   gh api -X PUT repos/lqflqf/amneziawg-linux-kernel-module-build/environments/release \
     --input - <<'EOF'
   {"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
   EOF
   gh api -X POST repos/lqflqf/amneziawg-linux-kernel-module-build/environments/release/deployment-branch-policies \
     -f name=main -f type=branch
   ```

2. Do not add secrets to the `ci` environment. Pull requests use the `ci` environment with
   temporary test keys. The workflow makes the `ci` environment automatically.

## Step 4: Make a work directory in memory

Do steps 5, 6, and 7 in this directory. Keep the terminal open until step 7 is complete.

You also need a backup directory outside the work directory, for example on a USB drive that
you keep offline. Steps 6 and 7 write the encrypted backups of the private keys to it.
Step 7 deletes the work directory. Thus do not use a directory in `$WORK` for the backups.

```sh
# Run this step in the clone of the build repository. The commands stop if you are not in it.
export BUILD_REPO="$(git rev-parse --show-toplevel)" && test -f "$BUILD_REPO/config.env" &&
  echo "Build repository: $BUILD_REPO"
export BACKUP_DIR=/path/to/offline/backup   # Change this path.
mkdir -p "$BACKUP_DIR"
umask 077
# gpg shows its passphrase prompts on this terminal.
export GPG_TTY="$(tty)"
export WORK="$(mktemp -d -p /dev/shm amneziawg-keys.XXXXXX)"
chmod 700 "$WORK"
cd "$WORK"
```

## Step 5: Make the deploy key

The publish job and the refresh job use this SSH key to push to the package repository.

1. Make the key pair. Do not set a passphrase.

   ```sh
   ssh-keygen -t ed25519 -N '' -C "amneziawg publish" -f "$WORK/deploy-key"
   ```

2. Add the public key to the package repository with write access.

   ```sh
   gh repo deploy-key add "$WORK/deploy-key.pub" \
     --repo lqflqf/amneziawg-linux-kernel-module-packages \
     --title "amneziawg-linux-kernel-module-build publish" --allow-write
   ```

3. Add the private key to the `release` environment.

   ```sh
   gh secret set PACKAGES_DEPLOY_KEY --env release \
     --repo lqflqf/amneziawg-linux-kernel-module-build < "$WORK/deploy-key"
   ```

   You do not need a backup of this key. If you lose it, make a new key.

## Step 6: Make the Alpine signing key

The Alpine key signs the APK packages and the `APKINDEX.tar.gz` files.

1. Make an RSA private key and its public key.

   ```sh
   (umask 077 && openssl genrsa -out "$WORK/amneziawg-packages.rsa" 4096)
   mkdir -p "$BUILD_REPO/keys/apk"
   openssl rsa -in "$WORK/amneziawg-packages.rsa" -pubout \
     -out "$BUILD_REPO/keys/apk/amneziawg-packages.rsa.pub"
   ```

   The file name is important. Alpine finds the public key by its file name. The name must
   agree with `RELEASE_APK_KEY_NAME` in `config.env`.

2. Add the private key to the `release` environment.

   ```sh
   gh secret set APK_PRIVATE_KEY --env release \
     --repo lqflqf/amneziawg-linux-kernel-module-build < "$WORK/amneziawg-packages.rsa"
   ```

3. Make an encrypted backup copy in `$BACKUP_DIR`. `gpg` asks for a backup passphrase. Keep
   the passphrase in a password manager.

   ```sh
   gpg --symmetric --no-symkey-cache --cipher-algo AES256 \
     -o "$BACKUP_DIR/amneziawg-packages.rsa.gpg" "$WORK/amneziawg-packages.rsa"
   ```

## Step 7: Make the APT signing key

The OpenPGP key signs the `InRelease` and `Release.gpg` files of the APT repository.

1. Make a key that can only sign. The key expires after 3 years. `gpg` asks for a passphrase.
   Do not type the passphrase on the command line.

   ```sh
   export GNUPGHOME="$WORK/gnupg"
   mkdir -m 700 "$GNUPGHOME"
   gpg --quick-gen-key "AmneziaWG packages <lqflqf@users.noreply.github.com>" rsa4096 sign 3y
   FPR="$(gpg --list-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')"
   echo "$FPR"
   ```

2. Add the private key and its passphrase to the `release` environment. The second command
   asks for the passphrase.

   ```sh
   gpg --armor --export-secret-keys "$FPR" | gh secret set GPG_PRIVATE_KEY --env release \
     --repo lqflqf/amneziawg-linux-kernel-module-build
   gh secret set GPG_PASSPHRASE --env release --repo lqflqf/amneziawg-linux-kernel-module-build
   ```

3. Put the public key in the build repository.

   ```sh
   mkdir -p "$BUILD_REPO/keys/apt"
   gpg --armor --export "$FPR" > "$BUILD_REPO/keys/apt/amneziawg-archive-key-1.asc"
   ```

4. Make an encrypted backup copy in `$BACKUP_DIR`. The first command asks for the passphrase of
   the APT key. The second command asks for a backup passphrase. Keep the backup passphrase in
   a password manager.

   ```sh
   gpg --armor --export-secret-keys "$FPR" > "$WORK/apt-key.asc" &&
     test -s "$WORK/apt-key.asc" &&
     gpg --symmetric --no-symkey-cache --cipher-algo AES256 \
       -o "$BACKUP_DIR/amneziawg-apt-key.asc.gpg" "$WORK/apt-key.asc"
   rm -f "$WORK/apt-key.asc"
   ```

5. Make sure that you can decrypt the two backups. Each command asks for its backup
   passphrase and must show `OK`. If a command does not show `OK`, do steps 6.3 and 7.4 again.
   Do not continue.

   ```sh
   gpg --no-symkey-cache -d "$BACKUP_DIR/amneziawg-packages.rsa.gpg" >/dev/null && echo OK
   gpg --no-symkey-cache -d "$BACKUP_DIR/amneziawg-apt-key.asc.gpg" >/dev/null && echo OK
   ```

6. Stop the GnuPG agent of the work directory, and remove the work directory. The private keys
   are now only in GitHub and in the backups. Move the backups to a safe offline location.

   ```sh
   gpgconf --kill gpg-agent
   cd "$BUILD_REPO"
   rm -rf "$WORK"
   unset GNUPGHOME WORK FPR
   ```

## Step 8: Commit the public keys

The build repository keeps the trusted public keys. The workflows publish only these keys,
and they keep a published Debian package only if one of these keys signed its index. Users
compare the fingerprints in `keys/FINGERPRINTS.md` with the downloaded keys.

```sh
scripts/keys.sh fingerprints keys > keys/FINGERPRINTS.md
git add keys
git commit -m "Add the public signing keys"
```

Do not push yet. Step 11 pushes the commit.

## Step 9: Make the token for the update pull requests

The `track-updates` workflow opens pull requests. A pull request from the default
`GITHUB_TOKEN` does not start other workflows. Thus the workflow needs a different token.

1. Make a fine-grained personal access token at
   <https://github.com/settings/personal-access-tokens/new>:
   - **Repository access**: only `lqflqf/amneziawg-linux-kernel-module-build`.
   - **Permissions**: `Contents`: read and write. `Pull requests`: read and write.
   - **Expiration**: set a date. Record the date. Replace the token before that date.
2. Add the token as a repository secret (not an environment secret).

   ```sh
   gh secret set UPDATE_PR_TOKEN --repo lqflqf/amneziawg-linux-kernel-module-build
   ```

## Step 10: Set the workflow permissions

Let GitHub Actions run with read-only permissions by default. The workflows ask for more
permissions only where necessary.

```sh
gh api -X PUT repos/lqflqf/amneziawg-linux-kernel-module-build/actions/permissions/workflow \
  -f default_workflow_permissions=read -F can_approve_pull_request_reviews=false
```

## Step 11: Make the first release

1. Push the branch `main`. The package repository has no `build-info.txt` file yet. Thus
   this run publishes.

   ```sh
   git push origin main
   ```

2. Monitor the workflow. The `aarch64` and `arm64` tests can take more than one hour.

   ```sh
   gh run watch --repo lqflqf/amneziawg-linux-kernel-module-build
   ```

3. If the run fails, correct the problem. Then start the run again by hand:

   ```sh
   gh workflow run build.yml --repo lqflqf/amneziawg-linux-kernel-module-build \
     --ref main -f publish=true
   ```

4. Make sure that the publish job pushed a commit to the package repository.
5. Make sure that these files are available:
   - `https://lqflqf.github.io/amneziawg-linux-kernel-module-packages/keys/amneziawg-packages.rsa.pub`
   - `https://lqflqf.github.io/amneziawg-linux-kernel-module-packages/keys/amneziawg-archive-keyring.gpg`
   - `https://lqflqf.github.io/amneziawg-linux-kernel-module-packages/debian/dists/trixie/InRelease`
   - `https://lqflqf.github.io/amneziawg-linux-kernel-module-packages/alpine/v3.24/main/x86_64/APKINDEX.tar.gz`
6. Do the installation procedures in `README.md` on a test system. Compare the key
   fingerprints with `keys/FINGERPRINTS.md`.

## Step 12: Protect the branch main

Do this step after the first run. Before the first run, the check does not exist and you cannot
select it.

1. Open **Settings** > **Rules** > **Rulesets** > **New ruleset** > **New branch ruleset**.
2. Set **Target branches** to the default branch (`main`).
3. Select **Require a pull request before merging**.
4. Select **Require status checks to pass**. Add only the check `Required build checks`.
   This check fails if one of the build, lint, or test jobs fails. The names of the other
   checks change with the target list. Thus do not add them.
5. Select **Block force pushes**.
6. Do not add a rule for the branch `automation/update-versions`. The `track-updates` workflow
   must be able to force push to it.

## Step 13: Start the scheduled workflows

1. Run the `track-updates` workflow one time by hand. If there are new versions, it opens a
   pull request.

   ```sh
   gh workflow run track-updates.yml --repo lqflqf/amneziawg-linux-kernel-module-build
   ```

2. Run the `refresh-metadata` workflow one time by hand. Make sure that it is successful.

   ```sh
   gh workflow run refresh-metadata.yml --repo lqflqf/amneziawg-linux-kernel-module-build
   ```

After these runs, the workflows run automatically: `track-updates` each day, and
`refresh-metadata` each week.

## Step 14: Turn on the private security reports

`SECURITY.md` tells persons to report security problems with the private report function of
GitHub. Turn on this function:

```sh
gh api -X PUT repos/lqflqf/amneziawg-linux-kernel-module-build/private-vulnerability-reporting
```

You can also use the web page: **Settings** > **Advanced Security** >
**Private vulnerability reporting** > **Enable**.

## Safety rules

- Never commit a private key to a repository.
- Keep the private keys only in the `release` environment and in the encrypted offline backups.
- Give the `release` environment only to the branch `main`.
- If a private key becomes known to other persons, replace it immediately. Use the
  procedure in [maintenance.md](maintenance.md#replace-a-signing-key).
- The `track-updates` workflow opens an issue 90 days before the APT key expires.
  Replace the key before it expires.
- The `track-updates` workflow also opens an issue 14 days before the published APT metadata
  expires. Then the `refresh-metadata` workflow failed for some weeks. Correct the problem.

## Summary of the secrets

| Name | Type | Location | Used by |
|---|---|---|---|
| `PACKAGES_DEPLOY_KEY` | SSH private key | Environment `release` | Publish job, refresh job |
| `APK_PRIVATE_KEY` | RSA private key (PEM) | Environment `release` | Signing in the `assemble` job |
| `GPG_PRIVATE_KEY` | OpenPGP private key (armored) | Environment `release` | Signing in the `assemble` job, refresh job |
| `GPG_PASSPHRASE` | Text | Environment `release` | Same as `GPG_PRIVATE_KEY` |
| `UPDATE_PR_TOKEN` | Fine-grained token | Repository secret | `track-updates` workflow |
