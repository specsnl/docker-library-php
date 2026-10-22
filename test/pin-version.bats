#!/usr/bin/env bats
#
# Tests for scripts/pin-version.sh. Run them with `task test`: the suite needs
# the container's GNU tooling and is meant to run without network access.

setup() {
	bats_require_minimum_version 1.5.0

	load helpers/common
	load_libraries
	setup_workdir
}

# Loads the script's functions without running main.
source_pin_version() {
	# shellcheck source=scripts/pin-version.sh
	source "$PIN_VERSION"
}

# The 8.4 entry the repo carries now, which every pin below moves away from.
current_84() {
	jq -r --arg key "$1" '.["8.4"][$key]' "$REPO_ROOT/versions.json"
}

# parse_version

@test "parse_version splits a stable version into branch and patch" {
	source_pin_version

	parse_version 8.4.13

	assert_equal "$branch" 8.4
	assert_equal "$patch" 13
	assert_equal "$prerelease" ''
	assert_equal "$key" 8.4
}

@test "parse_version maps a pre-release to its branch's -rc entry" {
	source_pin_version

	local version suffix
	for suffix in RC1 beta2 alpha1; do
		version="8.6.0$suffix"
		parse_version "$version"

		assert_equal "$branch" 8.6
		assert_equal "$patch" 0
		assert_equal "$prerelease" "$suffix"
		assert_equal "$key" 8.6-rc
	done
}

@test "parse_version answers anything else with usage" {
	source_pin_version

	for version in 8.4 v8.4.13 8.4.13.1 ''; do
		run parse_version "$version"
		assert_failure 2
		assert_output --partial 'usage:'
	done
}

# is_prerelease

@test "is_prerelease tells RC, beta and alpha versions from stable ones" {
	source_pin_version

	local version
	for version in 8.6.0RC1 8.6.0beta2 8.6.0alpha1; do
		run is_prerelease "$version"
		assert_success
	done

	for version in 8.4.13 8.6.0; do
		run is_prerelease "$version"
		assert_failure
	done
}

# resolve_source

@test "resolve_source takes the .xz tarball, its .asc and the checksum from the release JSON" {
	source_pin_version

	resolve_source 8.4.13

	assert_equal "$url" https://www.php.net/distributions/php-8.4.13.tar.xz
	assert_equal "$ascUrl" https://www.php.net/distributions/php-8.4.13.tar.xz.asc
	assert_equal "$sha256" b4f27adf30bcf262eacf93c78250dd811980f20f3b90d79a3dc11248681842df
}

@test "resolve_source fails clearly for a version php.net does not know" {
	source_pin_version

	run resolve_source 8.4.999

	assert_failure 1
	assert_output 'error: php.net does not know PHP 8.4.999 (Unknown version)'
}

@test "resolve_source fails clearly when php.net is unreachable" {
	source_pin_version
	export CURL_FAIL=1

	run resolve_source 8.4.13

	assert_failure 1
	assert_output --partial 'error: could not fetch the release metadata for PHP 8.4.13'
}

@test "resolve_source reads the checksum from the JSON and never downloads the tarball" {
	source_pin_version

	resolve_source 8.4.13

	run cat "$CURL_LOG"
	assert_output '-fsSL https://www.php.net/releases/index.php?json&version=8.4.13'
}

# End to end

@test "pinning 8.4.13 changes only the 8.4 version, url, ascUrl and sha256" {
	run "$PIN_VERSION" 8.4.13
	assert_success

	# One hunk: the four lines replaced in place, everything else byte-identical.
	run diff "$REPO_ROOT/versions.json" "$WORKDIR/versions.json"
	assert_failure 1
	assert_equal "${#lines[@]}" 10
	assert_line --index 0 --regexp '^[0-9]+,[0-9]+c[0-9]+,[0-9]+$'
	assert_line --index 1 "<     \"version\": \"$(current_84 version)\","
	assert_line --index 2 "<     \"url\": \"$(current_84 url)\","
	assert_line --index 3 "<     \"ascUrl\": \"$(current_84 ascUrl)\","
	assert_line --index 4 "<     \"sha256\": \"$(current_84 sha256)\","
	assert_line --index 5 '---'
	assert_line --index 6 '>     "version": "8.4.13",'
	assert_line --index 7 '>     "url": "https://www.php.net/distributions/php-8.4.13.tar.xz",'
	assert_line --index 8 '>     "ascUrl": "https://www.php.net/distributions/php-8.4.13.tar.xz.asc",'
	assert_line --index 9 '>     "sha256": "b4f27adf30bcf262eacf93c78250dd811980f20f3b90d79a3dc11248681842df",'
}

@test "pinning 8.4.13 renders it into every 8.4 Dockerfile" {
	run "$PIN_VERSION" 8.4.13
	assert_success

	local dockerfiles=( "$WORKDIR"/8.4/*/*/Dockerfile )
	assert_equal "${#dockerfiles[@]}" "$(jq '.["8.4"].variants | length' "$REPO_ROOT/versions.json")"

	for dockerfile in "${dockerfiles[@]}"; do
		assert_file_contains "$dockerfile" '^ENV PHP_VERSION 8\.4\.13$'
		assert_file_contains "$dockerfile" '^ENV PHP_URL="https://www\.php\.net/distributions/php-8\.4\.13\.tar\.xz" PHP_ASC_URL="https://www\.php\.net/distributions/php-8\.4\.13\.tar\.xz\.asc"$'
		assert_file_contains "$dockerfile" '^ENV PHP_SHA256="b4f27adf30bcf262eacf93c78250dd811980f20f3b90d79a3dc11248681842df"$'
	done
}

@test "pinning a branch missing from versions.json says to merge upstream first" {
	# 8.1.30 has a fixture, so php.net knowing the version cannot be what fails.
	run "$PIN_VERSION" 8.1.30

	assert_failure 1
	assert_output 'error: PHP 8.1 is not in versions.json; merge upstream docker-library/php first'
	assert_file_not_exists "$WORKDIR/8.1"
	assert_file_empty "$CURL_LOG"
	cmp "$REPO_ROOT/versions.json" "$WORKDIR/versions.json"
}

@test "pinning a pre-release while build-config.json disables them fails before fetching anything" {
	run jq -e '.prerelease == false' "$REPO_ROOT/build-config.json"
	assert_success

	run "$PIN_VERSION" 8.4.0RC4

	assert_failure 1
	assert_output "error: pre-release versions like '8.4.0RC4' are disabled; set \"prerelease\": true in build-config.json to build them"
	assert_file_empty "$CURL_LOG"
	cmp "$REPO_ROOT/versions.json" "$WORKDIR/versions.json"
}

@test "pinning a pre-release whose -rc entry is null says to merge upstream first" {
	edit_json build-config.json '.prerelease = true'
	edit_json versions.json '.["8.4-rc"] = null'
	cp "$WORKDIR/versions.json" "$BATS_TEST_TMPDIR/versions.json"

	run "$PIN_VERSION" 8.4.0RC4

	assert_failure 1
	assert_output 'error: PHP 8.4-rc is not in versions.json; merge upstream docker-library/php first'
	assert_file_empty "$CURL_LOG"
	cmp "$BATS_TEST_TMPDIR/versions.json" "$WORKDIR/versions.json"
}

@test "pin-version.sh without arguments prints usage" {
	run "$PIN_VERSION"

	assert_failure 2
	assert_output --partial 'usage: pin-version.sh <version>'
}

@test "pin-version.sh with too many arguments prints usage" {
	run "$PIN_VERSION" 8.4.13 8.4.12

	assert_failure 2
	assert_output --partial 'usage: pin-version.sh <version>'
}

@test "pin-version.sh is executable and runs under set -Eeuo pipefail" {
	assert_file_executable "$REPO_ROOT/scripts/pin-version.sh"
	assert_file_contains "$REPO_ROOT/scripts/pin-version.sh" '^set -Eeuo pipefail$'
}
