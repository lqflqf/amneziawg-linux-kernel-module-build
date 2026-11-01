#!/usr/bin/env bash
# Write a simple HTML start page for the package repository to stdout.
# Usage: scripts/make-index.sh <site-dir>
. "$(dirname "$0")/lib.sh"
load_config

site="${1:?Usage: $0 <site-dir>}"
readme="https://github.com/$PACKAGES_REPO#readme"

cat <<EOF
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>$REPO_LABEL packages</title></head>
<body>
<h1>$REPO_LABEL packages</h1>
<p>Installation instructions: <a href="$readme">$readme</a></p>
<p>AmneziaWG version: $AWG_VERSION (upstream tag $AWG_TAG)</p>
<h2>Public keys</h2>
<ul>
EOF
(cd "$site" && find keys -type f | sort) | while read -r f; do
	echo "<li><a href=\"$f\">$f</a></li>"
done
echo "</ul>"
echo "<h2>Packages</h2>"
echo "<ul>"
(cd "$site" && find alpine debian/pool -type f \( -name '*.apk' -o -name '*.deb' \) | sort) | while read -r f; do
	echo "<li><a href=\"$f\">$f</a></li>"
done
cat <<EOF
</ul>
</body>
</html>
EOF
