#!/usr/bin/env bats
#
# Tests for scripts/compute-tags.sh. Run them with `task test`.
#
# The script only works on strings, so these run it straight from the repo,
# without a WORKDIR copy, fixtures or the fake curl.

setup() {
	bats_require_minimum_version 1.5.0

	load helpers/common
	load_libraries

	COMPUTE_TAGS="$REPO_ROOT/scripts/compute-tags.sh"
}

# Loads the script's functions without running main.
source_compute_tags() {
	# shellcheck source=scripts/compute-tags.sh
	source "$COMPUTE_TAGS"
}

# Tags

@test "without floating tags, only the exact tag is printed" {
	run "$COMPUTE_TAGS" 8.4.13 fpm trixie false

	assert_success
	assert_output 'ghcr.io/specsnl/php:8.4.13-fpm-trixie'
}

@test "with floating tags, the branch, major and variant tags follow the exact one" {
	run "$COMPUTE_TAGS" 8.4.13 fpm trixie true

	assert_success
	assert_output - <<-'EOF'
		ghcr.io/specsnl/php:8.4.13-fpm-trixie
		ghcr.io/specsnl/php:8.4-fpm-trixie
		ghcr.io/specsnl/php:8-fpm
		ghcr.io/specsnl/php:fpm
	EOF
}

@test "cli alone also gets latest" {
	run "$COMPUTE_TAGS" 8.4.13 cli trixie true

	assert_success
	assert_output - <<-'EOF'
		ghcr.io/specsnl/php:8.4.13-cli-trixie
		ghcr.io/specsnl/php:8.4-cli-trixie
		ghcr.io/specsnl/php:8-cli
		ghcr.io/specsnl/php:cli
		ghcr.io/specsnl/php:latest
	EOF
}

@test "latest goes to exactly one variant, never to every one" {
	local variant with_latest=()

	for variant in cli fpm apache zts; do
		run "$COMPUTE_TAGS" 8.4.13 "$variant" trixie true
		assert_success
		if [[ "$output" == *:latest* ]]; then
			with_latest+=( "$variant" )
		fi
	done

	assert_equal "${with_latest[*]}" cli
}

@test "latest is not moved without floating tags, even for cli" {
	run "$COMPUTE_TAGS" 8.4.13 cli trixie false

	assert_success
	assert_output 'ghcr.io/specsnl/php:8.4.13-cli-trixie'
}

@test "the suite goes into the exact and branch tags; the suite-less ones follow any suite" {
	# build.yml refuses update_floating_tags with a base override for this
	# reason: a bookworm run would move 8-fpm and fpm off the default suite.
	run "$COMPUTE_TAGS" 8.4.13 fpm bookworm true

	assert_success
	assert_output - <<-'EOF'
		ghcr.io/specsnl/php:8.4.13-fpm-bookworm
		ghcr.io/specsnl/php:8.4-fpm-bookworm
		ghcr.io/specsnl/php:8-fpm
		ghcr.io/specsnl/php:fpm
	EOF
}

# Image name

@test "the image name is lowercase and every tag takes it from IMAGE" {
	source_compute_tags
	assert_equal "$IMAGE" "${IMAGE,,}"

	IMAGE=registry.test/elsewhere
	run main 8.4.13 cli trixie true

	assert_success
	assert_equal "${#lines[@]}" 5
	refute_output --partial ghcr.io
	run grep -vc '^registry.test/elsewhere:' <<< "$output"
	assert_output 0
}

@test "build.yml reads the image name from compute-tags.sh rather than repeating it" {
	run grep -n 'specsnl/php' "$REPO_ROOT/.github/workflows/build.yml"

	assert_failure 1
}

# floating_tags_allowed

@test "floating_tags_allowed follows update_floating_tags for a stable version" {
	source_compute_tags

	run floating_tags_allowed 8.4.13 true
	assert_success

	run floating_tags_allowed 8.4.13 false
	assert_failure
}

@test "floating_tags_allowed refuses a pre-release even when update_floating_tags is true" {
	source_compute_tags

	for version in 8.5.0RC1 8.5.0beta2 8.5.0alpha1; do
		run floating_tags_allowed "$version" true
		assert_failure
	done
}

# Arguments

@test "update_floating_tags accepts only true and false" {
	for value in True FALSE yes 1 0 ''; do
		run "$COMPUTE_TAGS" 8.4.13 fpm trixie "$value"

		assert_failure 2
		assert_output --partial "error: update_floating_tags must be true or false, not '$value'"
		assert_output --partial 'usage: compute-tags.sh'
	done
}

@test "an invalid version prints usage" {
	for version in 8.4 v8.4.13 8.4.13.1 ''; do
		run "$COMPUTE_TAGS" "$version" fpm trixie false

		assert_failure 2
		assert_output --partial "error: '$version' is not a PHP version like 8.4.13"
		assert_output --partial 'usage: compute-tags.sh <version> <variant> <suite> <update_floating_tags>'
	done
}

@test "a pre-release gets only its exact tag" {
	run "$COMPUTE_TAGS" 8.6.0RC1 fpm trixie false

	assert_success
	assert_output 'ghcr.io/specsnl/php:8.6.0RC1-fpm-trixie'
}

@test "a pre-release gets only its exact tag even with update_floating_tags, and says so" {
	local version
	for version in 8.6.0RC1 8.6.0beta2 8.6.0alpha1; do
		run --separate-stderr "$COMPUTE_TAGS" "$version" cli trixie true

		assert_success
		assert_output "ghcr.io/specsnl/php:$version-cli-trixie"
		assert_equal "$stderr" "note: $version is a pre-release, so the floating tags stay where they are"
	done
}

@test "a variant or suite that cannot go into a tag prints usage" {
	run "$COMPUTE_TAGS" 8.4.13 FPM trixie false
	assert_failure 2
	assert_output --partial "error: 'FPM' is not a variant like fpm or trixie"

	run "$COMPUTE_TAGS" 8.4.13 fpm-trixie trixie false
	assert_failure 2
	assert_output --partial "error: 'fpm-trixie' is not a variant"

	run "$COMPUTE_TAGS" 8.4.13 fpm 'trixie:latest' false
	assert_failure 2
	assert_output --partial "error: 'trixie:latest' is not a suite"

	run "$COMPUTE_TAGS" 8.4.13 fpm '' false
	assert_failure 2
	assert_output --partial "error: '' is not a suite"
}

@test "compute-tags.sh with missing or extra arguments prints usage" {
	run "$COMPUTE_TAGS"
	assert_failure 2
	assert_output --partial 'usage: compute-tags.sh'

	run "$COMPUTE_TAGS" 8.4.13 fpm trixie
	assert_failure 2
	assert_output --partial 'usage: compute-tags.sh'

	run "$COMPUTE_TAGS" 8.4.13 fpm trixie false extra
	assert_failure 2
	assert_output --partial 'usage: compute-tags.sh'
}

@test "compute-tags.sh is executable and runs under set -Eeuo pipefail" {
	assert_file_executable "$REPO_ROOT/scripts/compute-tags.sh"
	assert_file_contains "$REPO_ROOT/scripts/compute-tags.sh" '^set -Eeuo pipefail$'
}
