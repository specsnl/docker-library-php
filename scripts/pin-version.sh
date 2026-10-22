#!/usr/bin/env bash
#
# Pins versions.json to an exact PHP release and renders that branch's
# Dockerfiles. Upstream's versions.sh always picks the latest patch of a
# branch; this writes the entry for the version asked for.
#
# Neither versions.json nor the rendered Dockerfiles are meant to be committed.
#
# Usage: scripts/pin-version.sh <version>    e.g. scripts/pin-version.sh 8.4.13
set -Eeuo pipefail

usage() {
	echo >&2 "usage: ${0##*/} <version>    e.g. ${0##*/} 8.4.13"
	exit 2
}

die() {
	echo >&2 "error: $*"
	exit 1
}

# Succeeds for a pre-release version like 8.6.0RC1.
is_prerelease() {
	[[ "$1" =~ (alpha|beta|RC)[0-9]+$ ]]
}

# Splits a version into the globals branch, patch and prerelease, and sets key
# to its versions.json entry: the branch, or <branch>-rc for a pre-release, as
# upstream keys them. The rendered directories take the same name.
parse_version() {
	local version="$1"

	if [[ ! "$version" =~ ^([0-9]+\.[0-9]+)\.([0-9]+)((alpha|beta|RC)[0-9]+)?$ ]]; then
		echo >&2 "error: '$version' is not a PHP version like 8.4.13"
		usage
	fi

	branch="${BASH_REMATCH[1]}"
	# shellcheck disable=SC2034 # part of the parsed result, for callers
	patch="${BASH_REMATCH[2]}"
	prerelease="${BASH_REMATCH[3]}"
	key="$branch${prerelease:+-rc}"
}

# Sets the globals url, ascUrl and sha256 for a release or a pre-release.
#
# The checksum comes from php.net's JSON rather than from hashing the
# download, so it is an independent check on the tarball the build fetches.
resolve_source() {
	if is_prerelease "$1"; then
		resolve_prerelease_source "$1"
	else
		resolve_release_source "$1"
	fi
}

resolve_release_source() {
	local version="$1"
	local apiUrl="https://www.php.net/releases/index.php?json&version=$version"
	local json

	if ! json="$(curl -fsSL "$apiUrl")"; then
		die "could not fetch the release metadata for PHP $version from $apiUrl"
	fi

	# php.net answers an unknown version with {"error": ...}, and a version it
	# can match by prefix (8.5.0RC1 gives 8.5.0) with a different release.
	if ! jq -e --arg version "$version" '.version == $version' <<<"$json" > /dev/null 2>&1; then
		local error
		error="$(jq -r '.error // empty' <<<"$json" 2> /dev/null || true)"
		die "php.net does not know PHP $version${error:+ ($error)}"
	fi

	local filename="php-$version.tar.xz"
	sha256="$(jq -r --arg filename "$filename" '.source[]? | select(.filename == $filename) | .sha256 // empty' <<<"$json")"
	if [ -z "$sha256" ]; then
		die "php.net lists no $filename checksum for PHP $version"
	fi

	url="https://www.php.net/distributions/$filename"
	ascUrl="$url.asc"
}

# Pre-releases are published on downloads.php.net and missing from the release
# JSON. php.net's pre-release builds list has them, but only the newest one of
# each branch. It gives no .asc URL, so this assumes one next to the tarball,
# as upstream's versions.sh does.
resolve_prerelease_source() {
	local version="$1"
	local apiUrl='https://www.php.net/pre-release-builds.php?format=json'
	local json xz

	if ! json="$(curl -fsSL "$apiUrl")"; then
		die "could not fetch the pre-release builds from $apiUrl"
	fi

	if ! xz="$(jq -ce --arg version "$version" '[(.releases // {})[] | select(.version == $version) | .files.xz][0]' <<<"$json" 2> /dev/null)"; then
		local listed
		listed="$(jq -r '[(.releases // {})[].version] | join(", ")' <<<"$json" 2> /dev/null || true)"
		die "php.net lists no pre-release PHP $version; it only lists the newest pre-release of each branch (${listed:-none right now})"
	fi

	url="$(jq -r '.path // empty' <<<"$xz")"
	sha256="$(jq -r '.sha256 // empty' <<<"$xz")"
	if [ -z "$url" ] || [ -z "$sha256" ]; then
		die "php.net lists no php-$version.tar.xz with a checksum for PHP $version"
	fi

	ascUrl="$url.asc"
}

main() {
	[ "$#" -eq 1 ] || usage
	local version="$1"

	cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.."

	parse_version "$version"

	if [ -n "$prerelease" ] && ! jq -e '.prerelease == true' build-config.json > /dev/null; then
		die "pre-release versions like '$version' are disabled; set \"prerelease\": true in build-config.json to build them"
	fi

	if ! jq -e --arg key "$key" '.[$key] | type == "object"' versions.json > /dev/null; then
		die "PHP $key is not in versions.json; merge upstream docker-library/php first"
	fi

	resolve_source "$version"

	# jq keeps the key order and upstream's formatting, so only these four
	# values change in the file.
	local json
	json="$(
		jq \
			--arg key "$key" \
			--arg version "$version" \
			--arg url "$url" \
			--arg ascUrl "$ascUrl" \
			--arg sha256 "$sha256" \
			'.[$key] += { version: $version, url: $url, ascUrl: $ascUrl, sha256: $sha256 }' \
			versions.json
	)"
	printf '%s\n' "$json" > versions.json

	echo "$key: $version"

	./apply-templates.sh "$key"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
