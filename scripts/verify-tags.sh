#!/usr/bin/env bash
#
# Checks that every tag of the image still points at a whole multi-arch image,
# for the cleanup workflow to run after it has deleted package versions. A tag
# passes when it is a manifest list with an entry for each platform
# build-config.json lists, and every manifest the list references, platform
# images and attestations alike, is still in the registry.
#
# The tags come on stdin, one per line, so the workflow lists them through the
# GitHub API and this script only ever talks to the registry.
#
# Usage: scripts/verify-tags.sh <image> < tags
#   e.g. scripts/verify-tags.sh ghcr.io/specsnl/php <<< 8.4.13-fpm-trixie
set -Eeuo pipefail

usage() {
	echo >&2 "usage: ${0##*/} <image> < tags    e.g. ${0##*/} ghcr.io/specsnl/php <<< 8.4.13-fpm-trixie"
	exit 2
}

die() {
	echo >&2 "error: $*"
	exit 1
}

# Prints each of the given platforms that the manifest list on stdin has no
# entry for. An entry's variant is optional to match, so linux/arm64 finds an
# arm64 entry with variant v8.
missing_platforms() {
	jq -r --args '
		[.manifests[].platform // empty | "\(.os)/\(.architecture)", "\(.os)/\(.architecture)/\(.variant)"] as $present
		| $ARGS.positional[] | select(IN($present[]) | not)
	' "$@"
}

# Checks one tag, reporting every problem it finds, and fails if there was any.
verify_tag() {
	local image="$1" tag="$2" index platform digest
	local -a platforms_missing digests failed=()

	if ! index="$(docker buildx imagetools inspect --raw "$image:$tag")"; then
		echo >&2 "error: $image:$tag cannot be fetched"
		return 1
	fi

	if ! jq -e '.manifests | type == "array"' <<< "$index" > /dev/null; then
		echo >&2 "error: $image:$tag is not a manifest list"
		return 1
	fi

	mapfile -t platforms_missing < <(missing_platforms "${platforms[@]}" <<< "$index")
	for platform in "${platforms_missing[@]}"; do
		echo >&2 "error: $image:$tag has no $platform image"
		failed+=( "$platform" )
	done

	mapfile -t digests < <(jq -r '.manifests[].digest' <<< "$index")
	for digest in "${digests[@]}"; do
		if ! docker buildx imagetools inspect --raw "$image@$digest" > /dev/null; then
			echo >&2 "error: $image:$tag references $digest, which is gone"
			failed+=( "$digest" )
		fi
	done

	[ "${#failed[@]}" -eq 0 ] || return 1

	echo "ok: $image:$tag"
}

main() {
	[ "$#" -eq 1 ] && [ -n "$1" ] || usage
	local image="$1" tag
	local -a tags failed=()

	cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

	mapfile -t platforms < <(jq -r '.platforms[]' build-config.json)
	[ "${#platforms[@]}" -gt 0 ] || die "build-config.json lists no platforms"

	# A package that has images always has tags, so an empty list means the
	# listing went wrong rather than that there is nothing to check.
	mapfile -t tags < <(grep -v '^[[:space:]]*$' || true)
	[ "${#tags[@]}" -gt 0 ] || die "no tags on stdin to verify"

	for tag in "${tags[@]}"; do
		verify_tag "$image" "$tag" || failed+=( "$tag" )
	done

	if [ "${#failed[@]}" -gt 0 ]; then
		die "${#failed[@]} of ${#tags[@]} tags of $image are broken: ${failed[*]}"
	fi

	echo "all ${#tags[@]} tags of $image are whole on ${platforms[*]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
