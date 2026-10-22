#!/usr/bin/env bats
#
# Tests for scripts/smoke-test.sh. Run them with `task test`.
#
# The container has no images and no Docker socket, so the fake docker in
# test/helpers/bin stands in and logs each call to DOCKER_LOG. The first
# end-to-end build runs the checks against real images.

IMAGE='ghcr.io/specsnl/php@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'

setup() {
	bats_require_minimum_version 1.5.0

	load helpers/common
	load_libraries
	setup_workdir
}

# Loads the script's functions without running main.
source_smoke_test() {
	# shellcheck source=scripts/smoke-test.sh
	source "$SMOKE_TEST"
}

# Asserts the docker calls, one per line, against stdin.
assert_docker_calls() {
	run cat "$DOCKER_LOG"
	assert_output -
}

# Checks per variant

@test "cli runs php -v and php -m against the digest, and nothing else" {
	run "$SMOKE_TEST" "$IMAGE" cli

	assert_success
	assert_docker_calls <<-EOF
		run --rm $IMAGE sh -c php -v
		run --rm $IMAGE sh -c php -m
	EOF
}

@test "fpm also runs php-fpm -t" {
	run "$SMOKE_TEST" "$IMAGE" fpm

	assert_success
	assert_docker_calls <<-EOF
		run --rm $IMAGE sh -c php -v
		run --rm $IMAGE sh -c php -m
		run --rm $IMAGE sh -c php-fpm -t
	EOF
}

@test "apache also runs apache2ctl -t" {
	run "$SMOKE_TEST" "$IMAGE" apache

	assert_success
	assert_docker_calls <<-EOF
		run --rm $IMAGE sh -c php -v
		run --rm $IMAGE sh -c php -m
		run --rm $IMAGE sh -c apache2ctl -t
	EOF
}

@test "a variant without checks of its own, such as zts, runs the common checks only" {
	for variant in zts something-new; do
		: > "$DOCKER_LOG"

		run "$SMOKE_TEST" "$IMAGE" "$variant"

		assert_success
		assert_docker_calls <<-EOF
			run --rm $IMAGE sh -c php -v
			run --rm $IMAGE sh -c php -m
		EOF
	done
}

@test "checks_for lists the common checks first and the variant's own after them" {
	source_smoke_test

	run checks_for fpm

	assert_output - <<-'EOF'
		php -v
		php -m
		php-fpm -t
	EOF
}

@test "every check runs under sh -c, never bash" {
	for variant in cli fpm apache; do
		run "$SMOKE_TEST" "$IMAGE" "$variant"
		assert_success
	done

	run grep -cv " $IMAGE sh -c " "$DOCKER_LOG"
	assert_output 0
	run grep -c bash "$DOCKER_LOG"
	assert_output 0
}

@test "a passing run says which variant and image it checked" {
	run "$SMOKE_TEST" "$IMAGE" fpm

	assert_success
	assert_line --index 0 -- '--- php -v'
	assert_line "smoke test passed: fpm in $IMAGE"
}

# Failures

@test "a failing check fails the run and names the check and the image" {
	DOCKER_FAIL='php-fpm -t' run "$SMOKE_TEST" "$IMAGE" fpm

	assert_failure 1
	assert_line "error: 'php-fpm -t' failed in $IMAGE"
	assert_line "error: 1 of 3 smoke checks failed for fpm in $IMAGE"
	refute_line --partial 'smoke test passed'
}

@test "a failing check does not stop the checks after it" {
	DOCKER_FAIL='php -v' run "$SMOKE_TEST" "$IMAGE" apache

	assert_failure 1
	assert_docker_calls <<-EOF
		run --rm $IMAGE sh -c php -v
		run --rm $IMAGE sh -c php -m
		run --rm $IMAGE sh -c apache2ctl -t
	EOF
}

@test "every failing check is named" {
	DOCKER_FAIL='php -' run "$SMOKE_TEST" "$IMAGE" cli

	assert_failure 1
	assert_line "error: 'php -v' failed in $IMAGE"
	assert_line "error: 'php -m' failed in $IMAGE"
	assert_line "error: 2 of 2 smoke checks failed for cli in $IMAGE"
}

# Arguments

@test "an image without a digest is rejected before docker runs" {
	for image in ghcr.io/specsnl/php ghcr.io/specsnl/php:8.4.13-cli-trixie ghcr.io/specsnl/php@sha256:abc "ghcr.io/specsnl/php@${IMAGE#*@} extra" "${IMAGE%@*}@sha512:${IMAGE#*:}"; do
		run "$SMOKE_TEST" "$image" cli

		assert_failure 2
		assert_output --partial "error: '$image' is not an image reference by digest"
		assert_output --partial 'usage: smoke-test.sh <image@digest> <variant>'
	done

	assert_file_empty "$DOCKER_LOG"
}

@test "smoke-test.sh with missing, empty or extra arguments prints usage" {
	run "$SMOKE_TEST"
	assert_failure 2
	assert_output --partial 'usage: smoke-test.sh'

	run "$SMOKE_TEST" "$IMAGE"
	assert_failure 2
	assert_output --partial 'usage: smoke-test.sh'

	run "$SMOKE_TEST" "$IMAGE" ''
	assert_failure 2
	assert_output --partial 'usage: smoke-test.sh'

	run "$SMOKE_TEST" "$IMAGE" cli extra
	assert_failure 2
	assert_output --partial 'usage: smoke-test.sh'

	assert_file_empty "$DOCKER_LOG"
}

@test "smoke-test.sh is executable and runs under set -Eeuo pipefail" {
	assert_file_executable "$REPO_ROOT/scripts/smoke-test.sh"
	assert_file_contains "$REPO_ROOT/scripts/smoke-test.sh" '^set -Eeuo pipefail$'
}
