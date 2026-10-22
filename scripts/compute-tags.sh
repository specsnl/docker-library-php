#!/usr/bin/env bash
#
# Prints the tags the merge job applies to one directory's multi-arch image,
# one full image reference per line.
#
# The exact tag, <version>-<variant>-<suite>, is always printed. The floating
# tags follow only when update_floating_tags is true, so rebuilding an old
# patch release never moves them backwards: <branch>-<variant>-<suite>, the
# suite-less <major>-<variant> and <variant>, and latest for cli alone, as the
# official image does.
#
# The suite-less tags track whichever suite the run built on, so build.yml
# refuses update_floating_tags together with a base override.
#
# Usage: scripts/compute-tags.sh <version> <variant> <suite> <update_floating_tags>
#   e.g. scripts/compute-tags.sh 8.4.13 fpm trixie false
set -Eeuo pipefail

# shellcheck source=scripts/pin-version.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/pin-version.sh"

# GHCR only accepts lowercase repository names. build.yml reads this too.
IMAGE=ghcr.io/specsnl/php

LATEST_VARIANT=cli

# Replaces pin-version.sh's, which parse_version calls.
usage() {
	echo >&2 "usage: ${0##*/} <version> <variant> <suite> <update_floating_tags>    e.g. ${0##*/} 8.4.13 fpm trixie false"
	exit 2
}

# Fails with usage unless a variant or suite can go into a tag as-is.
check_tag_part() {
	local name="$1" value="$2"

	if [[ ! "$value" =~ ^[a-z0-9][a-z0-9.]*$ ]]; then
		echo >&2 "error: '$value' is not a $name like fpm or trixie"
		usage
	fi
}

# Succeeds when a run may move the floating tags. Pre-releases never do,
# whatever update_floating_tags says; parse_version rejects them for now, so
# this is where that rule takes effect once it accepts them.
floating_tags_allowed() {
	local version="$1" update_floating_tags="$2"

	[ "$update_floating_tags" = true ] && [[ ! "$version" =~ (alpha|beta|RC)[0-9]+$ ]]
}

main() {
	[ "$#" -eq 4 ] || usage
	local version="$1" variant="$2" suite="$3" update_floating_tags="$4"

	parse_version "$version"
	check_tag_part variant "$variant"
	check_tag_part suite "$suite"

	case "$update_floating_tags" in
		true | false) ;;
		*)
			echo >&2 "error: update_floating_tags must be true or false, not '$update_floating_tags'"
			usage
			;;
	esac

	echo "$IMAGE:$version-$variant-$suite"

	if floating_tags_allowed "$version" "$update_floating_tags"; then
		echo "$IMAGE:$branch-$variant-$suite"
		echo "$IMAGE:${branch%%.*}-$variant"
		echo "$IMAGE:$variant"
		if [ "$variant" = "$LATEST_VARIANT" ]; then
			echo "$IMAGE:latest"
		fi
	fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
