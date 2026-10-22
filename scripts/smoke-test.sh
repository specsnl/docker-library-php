#!/usr/bin/env bash
#
# Runs the basic checks against a pushed image before any tag points at it:
# php -v and php -m for every variant, plus a config test for fpm and apache.
#
# The image is addressed by digest, so the checks run against exactly what the
# build pushed. Each check runs under sh -c, which every image has, whereas
# bash is missing from Alpine's.
#
# Usage: scripts/smoke-test.sh <image@digest> <variant>
#   e.g. scripts/smoke-test.sh ghcr.io/specsnl/php@sha256:<hex> fpm
set -Eeuo pipefail

usage() {
	echo >&2 "usage: ${0##*/} <image@digest> <variant>    e.g. ${0##*/} ghcr.io/specsnl/php@sha256:<hex> fpm"
	exit 2
}

# Prints the checks for a variant, one shell command per line. A variant
# without checks of its own, such as zts, gets the common ones only.
checks_for() {
	echo 'php -v'
	echo 'php -m'

	case "$1" in
		fpm) echo 'php-fpm -t' ;;
		apache) echo 'apache2ctl -t' ;;
	esac
}

# Runs every check, so one run reports all that fail, and fails if any did.
run_checks() {
	local image="$1" variant="$2" check
	local -a checks failed=()
	mapfile -t checks < <(checks_for "$variant")

	for check in "${checks[@]}"; do
		echo "--- $check"
		if ! docker run --rm "$image" sh -c "$check"; then
			echo >&2 "error: '$check' failed in $image"
			failed+=( "$check" )
		fi
	done

	if [ "${#failed[@]}" -gt 0 ]; then
		echo >&2 "error: ${#failed[@]} of ${#checks[@]} smoke checks failed for $variant in $image"
		return 1
	fi

	echo "smoke test passed: $variant in $image"
}

main() {
	[ "$#" -eq 2 ] || usage
	local image="$1" variant="$2"

	if [[ ! "$image" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
		echo >&2 "error: '$image' is not an image reference by digest like ghcr.io/specsnl/php@sha256:<hex>"
		usage
	fi
	[ -n "$variant" ] || usage

	run_checks "$image" "$variant"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
