#!/usr/bin/env bash
#
# Prints the build job matrix for a PHP branch: one entry per rendered
# <branch>/<suite>/<variant> directory × platform that build-config.json
# enables. Run it after scripts/pin-version.sh has rendered the branch.
#
# The output is a single matrix=<json> line, so it can be appended to
# $GITHUB_OUTPUT as-is and read back with fromJSON() as strategy.matrix.
#
# Usage: scripts/select-matrix.sh <version> [variants] [base]
#   e.g. scripts/select-matrix.sh 8.4.13
#        scripts/select-matrix.sh 8.4.13 cli,zts bookworm
#
# variants is a comma-separated override of build-config.json's variants, and
# base the Debian suite to build on, by default the newest one versions.json
# lists. An empty argument takes the default, so workflow inputs can be passed
# through unchanged.
set -Eeuo pipefail

usage() {
	echo >&2 "usage: ${0##*/} <version> [variants] [base]    e.g. ${0##*/} 8.4.13 cli,zts bookworm"
	exit 2
}

die() {
	echo >&2 "error: $*"
	exit 1
}

# Succeeds when the first argument equals any of the others.
contains() {
	local needle="$1" item
	shift
	for item; do
		[ "$item" = "$needle" ] && return 0
	done
	return 1
}

# Sets the global branch from a branch (8.4) or a full version (8.4.13).
parse_branch() {
	local version="$1"

	if [[ ! "$version" =~ ^([0-9]+\.[0-9]+)(\.[0-9]+)?$ ]]; then
		echo >&2 "error: '$version' is not a PHP branch or version like 8.4 or 8.4.13"
		usage
	fi

	branch="${BASH_REMATCH[1]}"
}

# Prints the family a suite belongs to. Windows belongs to none, so no
# build-config.json setting can select it.
suite_family() {
	case "$1" in
		windows*) ;;
		alpine*) echo alpine ;;
		*) echo debian ;;
	esac
}

family_enabled() {
	local family="$1"
	[ -n "$family" ] && jq -e --arg family "$family" '.families[$family] == true' build-config.json > /dev/null
}

# Prints the GitHub-hosted runner that builds a platform natively.
runner_for() {
	case "$1" in
		linux/amd64) echo ubuntu-24.04 ;;
		linux/arm64) echo ubuntu-24.04-arm ;;
		*) die "no runner builds platform '$1'" ;;
	esac
}

# Prints the branch's suites in versions.json order, which upstream keeps
# newest first.
branch_suites() {
	jq -r --arg branch "$branch" '.[$branch].variants[] | split("/")[0]' versions.json | awk '!seen[$0]++'
}

suite_variants() {
	local suite="$1"
	jq -r --arg branch "$branch" --arg prefix "$suite/" \
		'.[$branch].variants[] | select(startswith($prefix)) | ltrimstr($prefix)' \
		versions.json
}

# Sets the global suite to base, or to the newest Debian suite when base is
# empty. Fails for a suite the branch lacks or whose family is disabled.
select_suite() {
	local base="$1" candidate family
	local -a suites enabled=()
	mapfile -t suites < <(branch_suites)

	for candidate in "${suites[@]}"; do
		if family_enabled "$(suite_family "$candidate")"; then
			enabled+=( "$candidate" )
		fi
	done

	if [ -z "$base" ]; then
		for candidate in "${suites[@]}"; do
			if [ "$(suite_family "$candidate")" = debian ]; then
				base="$candidate"
				break
			fi
		done
		[ -n "$base" ] || die "versions.json lists no Debian suite for PHP $branch"
	fi

	family="$(suite_family "$base")"
	if ! contains "$base" "${suites[@]}"; then
		die "PHP $branch has no suite '$base'; valid suites: ${enabled[*]:-none}"
	elif [ -z "$family" ]; then
		die "suite '$base' belongs to no family this repo builds; valid suites: ${enabled[*]:-none}"
	elif ! family_enabled "$family"; then
		die "suite '$base' is in the $family family, which build-config.json disables (families.$family is false)"
	fi

	suite="$base"
}

# Sets the global array variants to the comma-separated override, or to
# build-config.json's variants when it is empty. Fails for any variant the
# suite does not have, so a typo surfaces before a build starts.
select_variants() {
	local override="$1" variant
	local -a requested available
	variants=()
	mapfile -t available < <(suite_variants "$suite")

	if [ -n "$override" ]; then
		IFS=', ' read -r -a requested <<< "$override"
	else
		mapfile -t requested < <(jq -r '.variants[]' build-config.json)
	fi

	for variant in "${requested[@]}"; do
		if ! contains "$variant" "${available[@]}"; then
			die "PHP $branch has no variant '$variant' on $suite; available: ${available[*]}"
		fi
		contains "$variant" "${variants[@]}" || variants+=( "$variant" )
	done

	[ "${#variants[@]}" -gt 0 ] || die "no variants selected"
}

# Prints the matrix as compact JSON, {"include": [...]}, with one entry per
# directory × platform.
build_matrix() {
	local variant directory platform runner
	local -a platforms entries=()
	mapfile -t platforms < <(jq -r '.platforms[]' build-config.json)

	[ "${#platforms[@]}" -gt 0 ] || die "build-config.json lists no platforms"

	for variant in "${variants[@]}"; do
		directory="$branch/$suite/$variant"
		[ -d "$directory" ] || die "$directory does not exist; run scripts/pin-version.sh first"

		for platform in "${platforms[@]}"; do
			runner="$(runner_for "$platform")" || exit
			entries+=( "$(
				jq -nc \
					--arg directory "$directory" \
					--arg variant "$variant" \
					--arg suite "$suite" \
					--arg platform "$platform" \
					--arg runner "$runner" \
					'$ARGS.named'
			)" )
		done
	done

	printf '%s\n' "${entries[@]}" | jq -sc '{ include: . }'
}

main() {
	[ "$#" -ge 1 ] && [ "$#" -le 3 ] || usage

	cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

	parse_branch "$1"

	if ! jq -e --arg branch "$branch" '.[$branch] | type == "object"' versions.json > /dev/null; then
		die "PHP $branch is not in versions.json; merge upstream docker-library/php first"
	fi

	select_suite "${3:-}"
	select_variants "${2:-}"

	local matrix
	matrix="$(build_matrix)"
	echo "matrix=$matrix"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
