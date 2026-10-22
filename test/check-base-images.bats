#!/usr/bin/env bats
#
# Tests for scripts/check-base-images.sh. Run them with `task test`.
#
# The container has no registry access, so the fake docker in test/helpers/bin
# answers each imagetools inspect from a file in DOCKER_INSPECT, which these
# tests write, and logs each call to DOCKER_LOG.

IMAGE='ghcr.io/specsnl/php'

OLD='sha256:1111111111111111111111111111111111111111111111111111111111111111'
NEW='sha256:2222222222222222222222222222222222222222222222222222222222222222'

setup() {
	bats_require_minimum_version 1.5.0

	load helpers/common
	load_libraries
	setup_workdir
}

# Writes what the fake docker answers for a reference.
inspect_answers() {
	local ref="$1"

	cat > "$DOCKER_INSPECT/${ref//[\/:]/_}"
}

# Gives a tag the provenance buildkit attaches: the SBOM scanner and the base
# image as resolved dependencies on each platform. The arm64 digest defaults
# to the amd64 one, as both platforms pull the same manifest list.
tag_built_on() {
	local tag="$1" base="$2" amd64="$3" arm64="${4:-$3}"

	jq -n --arg base "$base" --arg amd64 "${amd64#sha256:}" --arg arm64 "${arm64#sha256:}" '
		def platform($platform; $digest): {
			($platform): { SLSA: { buildDefinition: { resolvedDependencies: [
				{
					digest: { sha256: "ae4f3b554449e7e25548e7d8ccc029d17357348e30c6e3df01b92bc93654d6a9" },
					uri: "pkg:docker/docker/buildkit-syft-scanner@stable-1?platform=\($platform | @uri)"
				},
				{
					digest: { sha256: $digest },
					uri: "pkg:docker/\($base | sub(":"; "@"))?platform=\($platform | @uri)"
				}
			] } } }
		};
		platform("linux/amd64"; $amd64) + platform("linux/arm64"; $arm64)
	' | inspect_answers "$IMAGE:$tag"
}

# Points a base image reference at a digest, as --format '{{.Manifest.Digest}}'
# prints it: without a newline.
base_now_at() {
	local ref="$1" digest="$2"

	printf '%s' "$digest" | inspect_answers "$ref"
}

# Assert on the stderr that run --separate-stderr keeps apart; this
# bats-assert has no assert_stderr of its own.
assert_stderr() {
	local output="$stderr"
	assert_output "$@"
}

assert_stderr_line() {
	local output="$stderr"
	local -a lines=( "${stderr_lines[@]}" )
	assert_line "$@"
}

# Asserts the docker calls, one per line, against stdin.
assert_docker_calls() {
	run cat "$DOCKER_LOG"
	assert_output -
}

# Reporting

@test "with every tag on the current base image, nothing goes to stdout" {
	tag_built_on 8.4.13-cli-trixie debian:trixie-slim "$NEW"
	tag_built_on 8.4.13-fpm-trixie debian:trixie-slim "$NEW"
	base_now_at debian:trixie-slim "$NEW"

	run --separate-stderr "$CHECK_BASE_IMAGES" "$IMAGE" <<-'EOF'
		8.4.13-cli-trixie
		8.4.13-fpm-trixie
	EOF

	assert_success
	assert_output ''
	assert_stderr - <<-EOF
		ok: $IMAGE:8.4.13-cli-trixie is on the current debian:trixie-slim
		ok: $IMAGE:8.4.13-fpm-trixie is on the current debian:trixie-slim
		0 of 2 tags of $IMAGE are behind their base image
	EOF
}

@test "the tags that are behind are listed in a table, in the order they came in" {
	tag_built_on 8.4.13-fpm-trixie debian:trixie-slim "$OLD"
	tag_built_on 8.4.14-fpm-trixie debian:trixie-slim "$NEW"
	tag_built_on fpm debian:trixie-slim "$OLD"
	base_now_at debian:trixie-slim "$NEW"

	run --separate-stderr "$CHECK_BASE_IMAGES" "$IMAGE" <<-'EOF'
		8.4.13-fpm-trixie
		8.4.14-fpm-trixie
		fpm
	EOF

	assert_success
	assert_output - <<-'EOF'
		| Tag | Base image | Built on | Now |
		|-----|------------|----------|-----|
		| `8.4.13-fpm-trixie` | `debian:trixie-slim` | `sha256:111111111111` | `sha256:222222222222` |
		| `fpm` | `debian:trixie-slim` | `sha256:111111111111` | `sha256:222222222222` |
	EOF
	assert_stderr_line "behind: $IMAGE:8.4.13-fpm-trixie was built on debian:trixie-slim@$OLD, which now points at $NEW"
	assert_stderr_line "ok: $IMAGE:8.4.14-fpm-trixie is on the current debian:trixie-slim"
	assert_stderr_line "2 of 3 tags of $IMAGE are behind their base image"
}

@test "each tag is compared with its own base image" {
	tag_built_on 8.4.13-cli-bookworm debian:bookworm-slim "$OLD"
	tag_built_on 8.4.13-cli-trixie debian:trixie-slim "$NEW"
	base_now_at debian:bookworm-slim "$OLD"
	base_now_at debian:trixie-slim "$NEW"

	run --separate-stderr "$CHECK_BASE_IMAGES" "$IMAGE" <<-'EOF'
		8.4.13-cli-bookworm
		8.4.13-cli-trixie
	EOF

	assert_success
	assert_output ''
}

@test "a tag is behind when one of its platforms is" {
	tag_built_on 8.4.13-cli-trixie debian:trixie-slim "$NEW" "$OLD"
	base_now_at debian:trixie-slim "$NEW"

	run --separate-stderr "$CHECK_BASE_IMAGES" "$IMAGE" <<< 8.4.13-cli-trixie

	assert_success
	assert_line "| \`8.4.13-cli-trixie\` | \`debian:trixie-slim\` | \`sha256:111111111111\` | \`sha256:222222222222\` |"
	assert_stderr_line "1 of 1 tags of $IMAGE are behind their base image"
}

@test "the base image comes from buildkit's real provenance format" {
	inspect_answers "$IMAGE:8.4.26-cli-trixie" < "$FIXTURES/provenance-8.4.26-cli-trixie.json"
	base_now_at debian:trixie-slim "$NEW"

	run --separate-stderr "$CHECK_BASE_IMAGES" "$IMAGE" <<< 8.4.26-cli-trixie

	assert_success
	assert_line "| \`8.4.26-cli-trixie\` | \`debian:trixie-slim\` | \`sha256:62bd423aeee9\` | \`sha256:222222222222\` |"
}

@test "pre-release tags are skipped without a registry call" {
	tag_built_on 8.4.13-cli-trixie debian:trixie-slim "$NEW"
	base_now_at debian:trixie-slim "$NEW"

	run --separate-stderr "$CHECK_BASE_IMAGES" "$IMAGE" <<-'EOF'
		8.6.0RC1-cli-trixie
		8.4.13-cli-trixie
		8.6.0alpha2-fpm-trixie
	EOF

	assert_success
	assert_output ''
	assert_stderr - <<-EOF
		skip: $IMAGE:8.6.0RC1-cli-trixie is a pre-release
		ok: $IMAGE:8.4.13-cli-trixie is on the current debian:trixie-slim
		skip: $IMAGE:8.6.0alpha2-fpm-trixie is a pre-release
		0 of 3 tags of $IMAGE are behind their base image
	EOF
	run grep -c 'alpha\|RC' "$DOCKER_LOG"
	assert_output 0
}

# Registry calls

@test "the provenance is read per tag, and each base image looked up once" {
	tag_built_on 8.4.13-cli-trixie debian:trixie-slim "$NEW"
	tag_built_on 8.4.13-fpm-trixie debian:trixie-slim "$NEW"
	base_now_at debian:trixie-slim "$NEW"

	run "$CHECK_BASE_IMAGES" "$IMAGE" <<-'EOF'
		8.4.13-cli-trixie
		8.4.13-fpm-trixie
	EOF

	assert_success
	assert_docker_calls <<-EOF
		buildx imagetools inspect --format {{json .Provenance}} $IMAGE:8.4.13-cli-trixie
		buildx imagetools inspect --format {{.Manifest.Digest}} debian:trixie-slim
		buildx imagetools inspect --format {{json .Provenance}} $IMAGE:8.4.13-fpm-trixie
	EOF
}

@test "nothing but imagetools inspect is ever run" {
	tag_built_on 8.4.13-cli-trixie debian:trixie-slim "$OLD"
	base_now_at debian:trixie-slim "$NEW"

	run "$CHECK_BASE_IMAGES" "$IMAGE" <<< 8.4.13-cli-trixie

	assert_success
	run grep -cv '^buildx imagetools inspect ' "$DOCKER_LOG"
	assert_output 0
}

# Input

@test "blank lines on stdin are skipped" {
	tag_built_on 8.4.13-cli-trixie debian:trixie-slim "$NEW"
	base_now_at debian:trixie-slim "$NEW"

	run --separate-stderr "$CHECK_BASE_IMAGES" "$IMAGE" <<< $'\n8.4.13-cli-trixie\n  \n'

	assert_success
	assert_stderr_line "0 of 1 tags of $IMAGE are behind their base image"
}

@test "no tags on stdin is an error, not a clean report" {
	run "$CHECK_BASE_IMAGES" "$IMAGE" < /dev/null

	assert_failure 1
	assert_output 'error: no tags on stdin to check'
}

@test "anything but one image argument prints usage" {
	run "$CHECK_BASE_IMAGES" < /dev/null
	assert_failure 2
	assert_output --partial 'usage: check-base-images.sh <image> < tags'

	run "$CHECK_BASE_IMAGES" '' < /dev/null
	assert_failure 2

	run "$CHECK_BASE_IMAGES" "$IMAGE" extra < /dev/null
	assert_failure 2
}

# Failures

@test "a tag that cannot be fetched fails the run, after the other tags are checked" {
	tag_built_on 8.4.13-fpm-trixie debian:trixie-slim "$OLD"
	base_now_at debian:trixie-slim "$NEW"

	run --separate-stderr "$CHECK_BASE_IMAGES" "$IMAGE" <<-'EOF'
		8.4.13-cli-trixie
		8.4.13-fpm-trixie
	EOF

	assert_failure 1
	assert_line "| \`8.4.13-fpm-trixie\` | \`debian:trixie-slim\` | \`sha256:111111111111\` | \`sha256:222222222222\` |"
	assert_stderr_line "error: $IMAGE:8.4.13-cli-trixie cannot be fetched"
	assert_stderr_line "error: 1 of 2 tags of $IMAGE could not be checked: 8.4.13-cli-trixie"
}

@test "a tag without provenance fails the run" {
	echo '{}' | inspect_answers "$IMAGE:8.4.13-cli-trixie"

	run --separate-stderr "$CHECK_BASE_IMAGES" "$IMAGE" <<< 8.4.13-cli-trixie

	assert_failure 1
	assert_stderr_line "error: $IMAGE:8.4.13-cli-trixie has no provenance that records its base image"
}

@test "a base image that cannot be fetched fails the run" {
	tag_built_on 8.4.13-cli-trixie debian:trixie-slim "$NEW"

	run --separate-stderr "$CHECK_BASE_IMAGES" "$IMAGE" <<< 8.4.13-cli-trixie

	assert_failure 1
	assert_stderr_line 'error: debian:trixie-slim cannot be fetched'
	assert_stderr_line "error: 1 of 1 tags of $IMAGE could not be checked: 8.4.13-cli-trixie"
}
