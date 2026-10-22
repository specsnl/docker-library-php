#!/usr/bin/env bash
#
# Lists every tag of a GHCR image, one per line in version order, for the
# workflows that check the published tags. The registry has no tag listing
# that spans every package version, so this reads the package's versions
# through the GitHub API; GH_TOKEN needs read access to the package.
#
# It fails when the API does, on any page, rather than printing a partial
# list.
#
# Usage: scripts/list-tags.sh <image>    e.g. scripts/list-tags.sh ghcr.io/specsnl/php
set -Eeuo pipefail

usage() {
	echo >&2 "usage: ${0##*/} <image>    e.g. ${0##*/} ghcr.io/specsnl/php"
	exit 2
}

main() {
	[ "$#" -eq 1 ] || usage
	local image="$1" tags

	if [[ ! "$image" =~ ^ghcr\.io/([^/]+)/([^/:@]+)$ ]]; then
		echo >&2 "error: '$image' is not a GHCR image like ghcr.io/specsnl/php"
		usage
	fi
	local owner="${BASH_REMATCH[1]}" package="${BASH_REMATCH[2]}"

	tags="$(gh api --paginate "/orgs/$owner/packages/container/$package/versions" --jq '.[].metadata.container.tags[]')"
	[ -z "$tags" ] || sort -uV <<< "$tags"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
