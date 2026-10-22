#!/usr/bin/env bats
#
# Tests for scripts/smoke-test.sh. Run them with `task test`.
#
# The container has no images and no Docker socket, so the fake docker in
# test/helpers/bin stands in and logs each call to DOCKER_LOG. The first
# end-to-end build runs the checks against real images.

IMAGE='ghcr.io/specsnl/php@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
VERSION='8.4.13'

setup() {
	bats_require_minimum_version 1.5.0

	load helpers/common
	load_libraries
	setup_workdir

	export DOCKER_PHP_VERSION="$VERSION"
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

@test "cli runs php -v, the version check and php -m against the digest, and nothing else" {
	run "$SMOKE_TEST" "$IMAGE" cli "$VERSION"

	assert_success
	assert_docker_calls <<-EOF
		run --rm $IMAGE sh -c php -v
		run --rm $IMAGE sh -c php -r 'echo PHP_VERSION;'
		run --rm $IMAGE sh -c php -m
	EOF
}

@test "fpm also runs php-fpm -t" {
	run "$SMOKE_TEST" "$IMAGE" fpm "$VERSION"

	assert_success
	assert_docker_calls <<-EOF
		run --rm $IMAGE sh -c php -v
		run --rm $IMAGE sh -c php -r 'echo PHP_VERSION;'
		run --rm $IMAGE sh -c php -m
		run --rm $IMAGE sh -c php-fpm -t
	EOF
}

@test "apache also runs apache2ctl -t" {
	run "$SMOKE_TEST" "$IMAGE" apache "$VERSION"

	assert_success
	assert_docker_calls <<-EOF
		run --rm $IMAGE sh -c php -v
		run --rm $IMAGE sh -c php -r 'echo PHP_VERSION;'
		run --rm $IMAGE sh -c php -m
		run --rm $IMAGE sh -c apache2ctl -t
	EOF
}

@test "a variant without checks of its own, such as zts, runs the common checks only" {
	for variant in zts something-new; do
		: > "$DOCKER_LOG"

		run "$SMOKE_TEST" "$IMAGE" "$variant" "$VERSION"

		assert_success
		assert_docker_calls <<-EOF
			run --rm $IMAGE sh -c php -v
			run --rm $IMAGE sh -c php -r 'echo PHP_VERSION;'
			run --rm $IMAGE sh -c php -m
		EOF
	done
}

@test "checks_for lists the common checks first and the variant's own after them" {
	source_smoke_test

	run checks_for fpm

	assert_output - <<-'EOF'
		php -v
		php -r 'echo PHP_VERSION;'
		php -m
		php-fpm -t
	EOF
}

@test "every check runs under sh -c, never bash" {
	for variant in cli fpm apache; do
		run "$SMOKE_TEST" "$IMAGE" "$variant" "$VERSION"
		assert_success
	done

	run grep -cv " $IMAGE sh -c " "$DOCKER_LOG"
	assert_output 0
	run grep -c bash "$DOCKER_LOG"
	assert_output 0
}

@test "a passing run says which variant and image it checked" {
	run "$SMOKE_TEST" "$IMAGE" fpm "$VERSION"

	assert_success
	assert_line --index 0 -- '--- php -v'
	assert_line "smoke test passed: fpm in $IMAGE"
}

@test "a check's output is printed under its heading" {
	run "$SMOKE_TEST" "$IMAGE" cli "$VERSION"

	assert_success
	assert_line --index 1 -- "--- php -r 'echo PHP_VERSION;'"
	assert_line --index 2 "$VERSION"
}

# PHP version

@test "an image running another PHP version fails and shows both versions" {
	DOCKER_PHP_VERSION='8.4.14' run "$SMOKE_TEST" "$IMAGE" fpm "$VERSION"

	assert_failure 1
	assert_line "error: $IMAGE runs PHP 8.4.14, expected $VERSION"
	assert_line "error: 1 of 4 smoke checks failed for fpm in $IMAGE"
	refute_line --partial 'smoke test passed'
}

@test "a version mismatch does not stop the checks after it" {
	DOCKER_PHP_VERSION='8.4.14' run "$SMOKE_TEST" "$IMAGE" apache "$VERSION"

	assert_failure 1
	assert_docker_calls <<-EOF
		run --rm $IMAGE sh -c php -v
		run --rm $IMAGE sh -c php -r 'echo PHP_VERSION;'
		run --rm $IMAGE sh -c php -m
		run --rm $IMAGE sh -c apache2ctl -t
	EOF
}

@test "the version is compared exactly, not as a prefix" {
	for actual in 8.4.1 8.4.130 8.4.13RC1 '8.4.13 '; do
		DOCKER_PHP_VERSION="$actual" run "$SMOKE_TEST" "$IMAGE" cli "$VERSION"

		assert_failure 1
		assert_line "error: $IMAGE runs PHP $actual, expected $VERSION"
	done
}

@test "a pre-release version passes when the image runs exactly that one" {
	DOCKER_PHP_VERSION='8.5.0RC2' run "$SMOKE_TEST" "$IMAGE" cli 8.5.0RC2

	assert_success
	assert_line "smoke test passed: cli in $IMAGE"
}

# Failures

@test "a failing check fails the run and names the check and the image" {
	DOCKER_FAIL='php-fpm -t' run "$SMOKE_TEST" "$IMAGE" fpm "$VERSION"

	assert_failure 1
	assert_line "error: 'php-fpm -t' failed in $IMAGE"
	assert_line "error: 1 of 4 smoke checks failed for fpm in $IMAGE"
	refute_line --partial 'smoke test passed'
}

@test "a failing check does not stop the checks after it" {
	DOCKER_FAIL='php -v' run "$SMOKE_TEST" "$IMAGE" apache "$VERSION"

	assert_failure 1
	assert_docker_calls <<-EOF
		run --rm $IMAGE sh -c php -v
		run --rm $IMAGE sh -c php -r 'echo PHP_VERSION;'
		run --rm $IMAGE sh -c php -m
		run --rm $IMAGE sh -c apache2ctl -t
	EOF
}

@test "every failing check is named" {
	DOCKER_FAIL='php -' run "$SMOKE_TEST" "$IMAGE" cli "$VERSION"

	assert_failure 1
	assert_line "error: 'php -v' failed in $IMAGE"
	assert_line "error: 'php -r 'echo PHP_VERSION;'' failed in $IMAGE"
	assert_line "error: 'php -m' failed in $IMAGE"
	assert_line "error: 3 of 3 smoke checks failed for cli in $IMAGE"
}

# Arguments

@test "an image without a digest is rejected before docker runs" {
	for image in ghcr.io/specsnl/php ghcr.io/specsnl/php:8.4.13-cli-trixie ghcr.io/specsnl/php@sha256:abc "ghcr.io/specsnl/php@${IMAGE#*@} extra" "${IMAGE%@*}@sha512:${IMAGE#*:}"; do
		run "$SMOKE_TEST" "$image" cli "$VERSION"

		assert_failure 2
		assert_output --partial "error: '$image' is not an image reference by digest"
		assert_output --partial 'usage: smoke-test.sh <image@digest> <variant> <php_version>'
	done

	assert_file_empty "$DOCKER_LOG"
}

@test "a php_version that is not an exact version is rejected before docker runs" {
	for version in 8.4 v8.4.13 8.4.13-RC1 8.4.13rc1 '8.4.13 ' 8; do
		run "$SMOKE_TEST" "$IMAGE" cli "$version"

		assert_failure 2
		assert_output --partial "error: '$version' is not a PHP version like 8.4.13"
		assert_output --partial 'usage: smoke-test.sh'
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

	run "$SMOKE_TEST" "$IMAGE" cli
	assert_failure 2
	assert_output --partial 'usage: smoke-test.sh'

	run "$SMOKE_TEST" "$IMAGE" '' "$VERSION"
	assert_failure 2
	assert_output --partial 'usage: smoke-test.sh'

	run "$SMOKE_TEST" "$IMAGE" cli ''
	assert_failure 2
	assert_output --partial 'usage: smoke-test.sh'

	run "$SMOKE_TEST" "$IMAGE" cli "$VERSION" extra
	assert_failure 2
	assert_output --partial 'usage: smoke-test.sh'

	assert_file_empty "$DOCKER_LOG"
}

@test "smoke-test.sh is executable and runs under set -Eeuo pipefail" {
	assert_file_executable "$REPO_ROOT/scripts/smoke-test.sh"
	assert_file_contains "$REPO_ROOT/scripts/smoke-test.sh" '^set -Eeuo pipefail$'
}
