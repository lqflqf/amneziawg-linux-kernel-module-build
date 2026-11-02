#!/usr/bin/env bash
# Check the code and run the tests. The "lint" job of the build workflow runs this script.
#
# Usage: scripts/lint-code.sh [shellcheck|actionlint|python|tests|all]
#   "shellcheck" checks the shell scripts (settings in .shellcheckrc).
#   "actionlint" checks the workflows, also the shell code in them (with shellcheck).
#   "python"     runs ruff and ty (settings in pyproject.toml).
#   "tests"      runs pytest (tests/*.py) and bats (tests/*.bats).
# Needs: shellcheck, actionlint, bats, and the Python packages in requirements-dev.txt.
# shellcheck source=lib.sh
. "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR" || exit 1

run_shellcheck() {
	local files
	# Also the new files that are not committed yet.
	mapfile -t files < <(git ls-files --cached --others --exclude-standard -- '*.sh' 'debian/*.postinst')
	log "shellcheck: ${#files[@]} files"
	shellcheck "${files[@]}"
	# Templates: build-apk.sh replaces the @...@ values.
	shellcheck --shell=sh alpine/depmod.sh.in
}

run_actionlint() {
	log "actionlint"
	actionlint
}

run_python() {
	log "ruff"
	ruff check
	log "ty"
	ty check
}

run_tests() {
	log "pytest"
	python3 -m pytest -q tests
	log "bats"
	bats tests
}

case "${1:-all}" in
shellcheck) run_shellcheck ;;
actionlint) run_actionlint ;;
python) run_python ;;
tests) run_tests ;;
all)
	# Do not use "&&" here: then "set -e" has no effect in the functions.
	run_shellcheck
	run_actionlint
	run_python
	run_tests
	;;
*) die "Usage: $0 [shellcheck|actionlint|python|tests|all]" ;;
esac
