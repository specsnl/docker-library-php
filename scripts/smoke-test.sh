#!/usr/bin/env bash
#
# Runs the basic checks against a pushed image before any tag points at it:
# php -v, the PHP version and php -m for every variant, plus a config test for
# fpm and apache. The PHP version must equal the one the run asked for, so a
# pinning mistake fails here instead of getting tagged, and php -m must list
# every extension in build-config.json's required_extensions.
#
# The image is addressed by digest, so the checks run against exactly what the
# build pushed. Each check runs under sh -c, which every image has, whereas
# bash is missing from Alpine's.
#
# Usage: scripts/smoke-test.sh <image@digest> <variant> <php_version>
#   e.g. scripts/smoke-test.sh ghcr.io/specsnl/php@sha256:<hex> fpm 8.4.13
set -Eeuo pipefail

readonly VERSION_CHECK="php -r 'echo PHP_VERSION;'"

usage() {
	echo >&2 "usage: ${0##*/} <image@digest> <variant> <php_version>    e.g. ${0##*/} ghcr.io/specsnl/php@sha256:<hex> fpm 8.4.13"
	exit 2
}

# Prints the checks for a variant, one shell command per line. A variant
# without checks of its own, such as zts, gets the common ones only.
checks_for() {
	echo 'php -v'
	echo "$VERSION_CHECK"
	echo 'php -m'

	case "$1" in
		fpm) echo 'php-fpm -t' ;;
		apache) echo 'apache2ctl -t' ;;
	esac
}

verify_version() {
	local image="$1" expected="$2" actual="$3"

	if [ "$actual" != "$expected" ]; then
		echo >&2 "error: $image runs PHP $actual, expected $expected"
		return 1
	fi
}

# Fails for every required extension that php -m does not list. PHP compares
# extension names case-insensitively, so this does too.
verify_extensions() {
	local image="$1" modules="${2,,}" extension list
	local -a missing=()

	for extension in "${required_extensions[@]}"; do
		grep -qxF -- "${extension,,}" <<< "$modules" || missing+=( "$extension" )
	done

	if [ "${#missing[@]}" -gt 0 ]; then
		printf -v list '%s, ' "${missing[@]}"
		echo >&2 "error: $image is missing required extensions: ${list%, }"
		return 1
	fi
}

# Compares a check's output where it has something to compare. The other
# checks pass as long as they exit 0.
verify_output() {
	local image="$1" version="$2" check="$3" output="$4"

	case "$check" in
		"$VERSION_CHECK") verify_version "$image" "$version" "$output" ;;
		'php -m') verify_extensions "$image" "$output" ;;
	esac
}

# Sets the global array required_extensions from build-config.json.
read_required_extensions() {
	if ! jq -e '.required_extensions | type == "array" and all(type == "string")' build-config.json > /dev/null; then
		echo >&2 "error: build-config.json's required_extensions is not a list of extension names"
		exit 1
	fi

	mapfile -t required_extensions < <(jq -r '.required_extensions[]' build-config.json)
}

# Runs every check, so one run reports all that fail, and fails if any did.
run_checks() {
	local image="$1" variant="$2" version="$3" check output status
	local -a checks failed=()
	mapfile -t checks < <(checks_for "$variant")

	for check in "${checks[@]}"; do
		echo "--- $check"
		status=0
		output="$(docker run --rm "$image" sh -c "$check")" || status=$?
		[ -z "$output" ] || printf '%s\n' "$output"

		if [ "$status" -ne 0 ]; then
			echo >&2 "error: '$check' failed in $image"
			failed+=( "$check" )
		elif ! verify_output "$image" "$version" "$check" "$output"; then
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
	[ "$#" -eq 3 ] || usage
	local image="$1" variant="$2" version="$3"

	if [[ ! "$image" =~ ^[^@[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
		echo >&2 "error: '$image' is not an image reference by digest like ghcr.io/specsnl/php@sha256:<hex>"
		usage
	fi
	[ -n "$variant" ] || usage
	if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+((alpha|beta|RC)[0-9]+)?$ ]]; then
		echo >&2 "error: '$version' is not a PHP version like 8.4.13"
		usage
	fi

	cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."
	read_required_extensions

	run_checks "$image" "$variant" "$version"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
