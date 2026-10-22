#!/usr/bin/env bash
#
# Reports the tags of the image whose base image has moved on since they were
# built, for the scheduled base image check. It never pushes or tags anything.
#
# build.yml attaches a provenance attestation to every image, and it records
# the base image the build pulled, e.g. debian:trixie-slim, by digest. A tag is
# behind when that digest is no longer the one the base image's tag points at,
# on any platform.
#
# The tags come on stdin, one per line, so the workflow lists them through the
# GitHub API and this script only ever talks to the registries. It prints a
# Markdown table of the tags that are behind, and nothing at all when every
# tag is current. How each tag fares goes to stderr.
#
# Pre-release tags are skipped: php.net only serves the newest pre-release of
# a branch, so an older one cannot be rebuilt and would stay behind for good.
#
# Usage: scripts/check-base-images.sh <image> < tags
#   e.g. scripts/check-base-images.sh ghcr.io/specsnl/php <<< 8.4.13-fpm-trixie
set -Eeuo pipefail

# shellcheck source=scripts/pin-version.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/pin-version.sh"

usage() {
	echo >&2 "usage: ${0##*/} <image> < tags    e.g. ${0##*/} ghcr.io/specsnl/php <<< 8.4.13-fpm-trixie"
	exit 2
}

die() {
	echo >&2 "error: $*"
	exit 1
}

# The digest each base image reference points at now, looked up once per run.
declare -A current=()

# The tags that are behind, and their table rows.
behind=()
rows=()

# Prints the base images the provenance on stdin records, one
# "<reference> <digest>" line per distinct pair across the platforms. The base
# is the official image among the resolved dependencies; the namespaced ones,
# such as the SBOM scanner docker/buildkit-syft-scanner, are build tooling.
base_images() {
	jq -r '
		.[].SLSA.buildDefinition.resolvedDependencies[]?
		| (.uri | capture("^pkg:docker/(?<name>[^/@?]+)@(?<tag>[^?]+)")) as $ref
		| "\($ref.name):\($ref.tag) sha256:\(.digest.sha256)"
	' | sort -u
}

# Looks up the digest a base image reference points at now, into current.
resolve_base() {
	local ref="$1"

	[ -z "${current[$ref]:-}" ] || return 0
	current[$ref]="$(docker buildx imagetools inspect --format '{{.Manifest.Digest}}' "$ref")"
}

# Shortens a digest for the table, as sha256:<first 12 hex digits>.
short() {
	echo "${1:0:19}"
}

# Checks one tag, adding it to behind and its rows to rows when it is behind.
# Fails when the tag cannot be checked.
check_tag() {
	local image="$1" tag="$2" provenance base ref digest is_behind=false
	local -a bases

	if ! provenance="$(docker buildx imagetools inspect --format '{{json .Provenance}}' "$image:$tag")"; then
		echo >&2 "error: $image:$tag cannot be fetched"
		return 1
	fi

	mapfile -t bases < <(base_images <<< "$provenance" 2> /dev/null || true)
	if [ "${#bases[@]}" -eq 0 ]; then
		echo >&2 "error: $image:$tag has no provenance that records its base image"
		return 1
	fi

	for base in "${bases[@]}"; do
		read -r ref digest <<< "$base"

		if ! resolve_base "$ref"; then
			echo >&2 "error: $ref cannot be fetched"
			return 1
		fi

		if [ "$digest" = "${current[$ref]}" ]; then
			echo >&2 "ok: $image:$tag is on the current $ref"
		else
			echo >&2 "behind: $image:$tag was built on $ref@$digest, which now points at ${current[$ref]}"
			rows+=( "| \`$tag\` | \`$ref\` | \`$(short "$digest")\` | \`$(short "${current[$ref]}")\` |" )
			is_behind=true
		fi
	done

	if [ "$is_behind" = true ]; then
		behind+=( "$tag" )
	fi
}

main() {
	[ "$#" -eq 1 ] && [ -n "$1" ] || usage
	local image="$1" tag
	local -a tags failed=()

	# A package that has images always has tags, so an empty list means the
	# listing went wrong rather than that there is nothing to check.
	mapfile -t tags < <(grep -v '^[[:space:]]*$' || true)
	[ "${#tags[@]}" -gt 0 ] || die "no tags on stdin to check"

	for tag in "${tags[@]}"; do
		if is_prerelease "${tag%%-*}"; then
			echo >&2 "skip: $image:$tag is a pre-release"
			continue
		fi
		check_tag "$image" "$tag" || failed+=( "$tag" )
	done

	if [ "${#rows[@]}" -gt 0 ]; then
		echo '| Tag | Base image | Built on | Now |'
		echo '|-----|------------|----------|-----|'
		printf '%s\n' "${rows[@]}"
	fi

	if [ "${#failed[@]}" -gt 0 ]; then
		die "${#failed[@]} of ${#tags[@]} tags of $image could not be checked: ${failed[*]}"
	fi

	echo >&2 "${#behind[@]} of ${#tags[@]} tags of $image are behind their base image"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
