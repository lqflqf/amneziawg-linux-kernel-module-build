#!/usr/bin/env bash
# Find APT keys in keys/apt that expire soon.
#
# Usage: scripts/check-key-expiry.sh [days]
#   days: warn if a key expires in fewer days than this (default: 90).
# Output: one line for each key. In GitHub Actions also "expiring=true|false" and
#         "report=<file>" in $GITHUB_OUTPUT.
. "$(dirname "$0")/lib.sh"
load_config

limit="${1:-90}"
now="$(date -u +%s)"
report="$(mktemp)"
expiring=false

for f in "$ROOT_DIR"/keys/apt/*.asc; do
	[ -f "$f" ] || continue
	while read -r fpr expiry; do
		if [ "$expiry" = 0 ]; then
			echo "apt/$(basename "$f") $fpr: no expiry date" | tee -a "$report"
			continue
		fi
		days=$(((expiry - now) / 86400))
		line="apt/$(basename "$f") $fpr: expires on $(date -u -d "@$expiry" +%Y-%m-%d) ($days days)"
		echo "$line" | tee -a "$report"
		[ "$days" -ge "$limit" ] || expiring=true
	done < <(gpg --dearmor <"$f" | gpg --batch --show-keys --with-colons 2>/dev/null |
		awk -F: '/^pub/ {e = $7; p = 1; next} p && /^fpr/ {print $10, (e == "" ? 0 : e); p = 0}')
done

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "expiring=$expiring" >>"$GITHUB_OUTPUT"
	echo "report=$report" >>"$GITHUB_OUTPUT"
fi
[ "$expiring" = false ] || warn "An APT key expires in fewer than $limit days. See docs/maintenance.md."
