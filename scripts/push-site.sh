#!/usr/bin/env bash
# Replace the content of the packages repository with <site-dir> in one new commit without
# parents. The force push removes the old commits. Thus the old package files do not stay in
# the Git history, and the repository does not grow.
#
# Usage: scripts/push-site.sh <site-dir> <packages-clone> <commit-message>...
#   <packages-clone> is a clone of the packages repository with push access.
# Environment: PUBLISH_BRANCH (default: main), the GitHub Pages branch.
. "$(dirname "$0")/lib.sh"
load_config

site="${1:?Usage: $0 <site-dir> <packages-clone> <message>...}"
clone="${2:?Usage: $0 <site-dir> <packages-clone> <message>...}"
shift 2
[ $# -gt 0 ] || die "A commit message is necessary"
[ -d "$clone/.git" ] || die "$clone is not a Git clone"

find "$clone" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -a "$site/." "$clone/"
cd "$clone" || exit 1
branch="${PUBLISH_BRANCH:-main}"
if git rev-parse -q --verify HEAD >/dev/null && [ -z "$(git status --porcelain)" ]; then
	log "No changes to publish."
	exit 0
fi

git checkout -q --orphan "publish-$$"
git add -A
args=()
for m in "$@"; do args+=(-m "$m"); done
git -c user.name="github-actions[bot]" \
	-c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
	commit -q "${args[@]}"
git branch -q -M "$branch"
git push --force origin "HEAD:refs/heads/$branch"
log "Published $(git rev-parse --short HEAD) to $branch"
