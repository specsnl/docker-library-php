#!/usr/bin/env bats
#
# Tests for scripts/verify-tags.sh. Run them with `task test`.
#
# The fake docker in test/helpers/bin stands in for the registry: push_tag
# stores the manifests it should serve under DOCKER_INSPECT, and a manifest
# that is not stored there is gone, as if the cleanup had deleted it.

IMAGE='ghcr.io/specsnl/php'
TAG='8.4.13-fpm-trixie'

setup() {
	bats_require_minimum_version 1.5.0

	load helpers/common
	load_libraries
	setup_workdir

	AMD64="$(digest a)"
	ARM64="$(digest b)"
	AMD64_ATTESTATION="$(digest c)"
	ARM64_ATTESTATION="$(digest d)"
}

# Loads the script's functions without running main.
source_verify_tags() {
	# shellcheck source=scripts/verify-tags.sh
	source "$VERIFY_TAGS"
}

# Prints a made-up sha256 digest of one repeated hex character.
digest() {
	printf 'sha256:%s' "$(printf '%064d' 0 | tr 0 "$1")"
}

# Prints the file the fake docker serves for an image reference.
response_file() {
	local reference="$1"
	echo "$DOCKER_INSPECT/${reference//[\/:]/_}"
}

# Stores stdin as what the registry serves for an image reference.
respond() {
	cat > "$(response_file "$1")"
}

# Removes a manifest from the registry, as the cleanup deleting it would.
delete_manifest() {
	rm "$(response_file "$IMAGE@$1")"
}

# Stores a manifest list for the tag with one entry per <digest>=<platform>
# argument, and a manifest for each digest. unknown/unknown stands for an
# attestation manifest, as buildx pushes them.
push_tag() {
	local tag="$1" entry digest platform
	local -a manifests=()
	shift

	for entry in "$@"; do
		digest="${entry%%=*}" platform="${entry#*=}"
		manifests+=( "$(
			jq -nc --arg digest "$digest" --arg platform "$platform" '
				($platform | split("/")) as [$os, $architecture, $variant]
				| {
					mediaType: "application/vnd.oci.image.manifest.v1+json",
					digest: $digest,
					platform: ({ os: $os, architecture: $architecture } + if $variant then { variant: $variant } else {} end)
				}
			'
		)" )
		echo '{"schemaVersion": 2}' | respond "$IMAGE@$digest"
	done

	printf '%s\n' "${manifests[@]}" | jq -s '{ schemaVersion: 2, manifests: . }' | respond "$IMAGE:$tag"
}

# Pushes the tag the way build.yml's merge job leaves it: both platforms and
# an attestation manifest for each.
push_whole_tag() {
	push_tag "$1" \
		"$AMD64=linux/amd64" \
		"$ARM64=linux/arm64" \
		"$AMD64_ATTESTATION=unknown/unknown" \
		"$ARM64_ATTESTATION=unknown/unknown"
}

# Asserts the docker calls, one per line, against stdin.
assert_docker_calls() {
	run cat "$DOCKER_LOG"
	assert_output -
}

# Whole images

@test "a tag with both platforms and their attestations passes" {
	push_whole_tag "$TAG"

	run "$VERIFY_TAGS" "$IMAGE" <<< "$TAG"

	assert_success
	assert_output - <<-EOF
		ok: $IMAGE:$TAG
		all 1 tags of $IMAGE are whole on linux/amd64 linux/arm64
	EOF
}

@test "every manifest the list references is fetched by digest" {
	push_whole_tag "$TAG"

	run "$VERIFY_TAGS" "$IMAGE" <<< "$TAG"

	assert_success
	assert_docker_calls <<-EOF
		buildx imagetools inspect --raw $IMAGE:$TAG
		buildx imagetools inspect --raw $IMAGE@$AMD64
		buildx imagetools inspect --raw $IMAGE@$ARM64
		buildx imagetools inspect --raw $IMAGE@$AMD64_ATTESTATION
		buildx imagetools inspect --raw $IMAGE@$ARM64_ATTESTATION
	EOF
}

@test "an arm64 entry with variant v8 counts as linux/arm64" {
	push_tag "$TAG" "$AMD64=linux/amd64" "$ARM64=linux/arm64/v8"

	run "$VERIFY_TAGS" "$IMAGE" <<< "$TAG"

	assert_success
}

@test "every tag on stdin is checked, and blank lines are skipped" {
	push_whole_tag "$TAG"
	push_whole_tag fpm

	run "$VERIFY_TAGS" "$IMAGE" <<-EOF
		$TAG

		fpm
	EOF

	assert_success
	assert_line "ok: $IMAGE:$TAG"
	assert_line "ok: $IMAGE:fpm"
	assert_line "all 2 tags of $IMAGE are whole on linux/amd64 linux/arm64"
}

@test "the platforms come from build-config.json" {
	jq '.platforms = ["linux/amd64"]' "$REPO_ROOT/build-config.json" > "$WORKDIR/build-config.json"
	push_tag "$TAG" "$AMD64=linux/amd64"

	run "$VERIFY_TAGS" "$IMAGE" <<< "$TAG"

	assert_success
	assert_line "all 1 tags of $IMAGE are whole on linux/amd64"
}

@test "missing_platforms prints only the platforms the list lacks" {
	source_verify_tags
	push_tag "$TAG" "$AMD64=linux/amd64" "$AMD64_ATTESTATION=unknown/unknown"

	run missing_platforms linux/amd64 linux/arm64 linux/s390x < "$(response_file "$IMAGE:$TAG")"

	assert_success
	assert_output - <<-'EOF'
		linux/arm64
		linux/s390x
	EOF
}

# Broken images

@test "a deleted platform image fails the tag and names the digest" {
	push_whole_tag "$TAG"
	delete_manifest "$ARM64"

	run "$VERIFY_TAGS" "$IMAGE" <<< "$TAG"

	assert_failure 1
	assert_line "error: $IMAGE:$TAG references $ARM64, which is gone"
	assert_line "error: 1 of 1 tags of $IMAGE are broken: $TAG"
	refute_line --partial 'ok:'
}

@test "a deleted attestation manifest fails the tag as well" {
	push_whole_tag "$TAG"
	delete_manifest "$AMD64_ATTESTATION"

	run "$VERIFY_TAGS" "$IMAGE" <<< "$TAG"

	assert_failure 1
	assert_line "error: $IMAGE:$TAG references $AMD64_ATTESTATION, which is gone"
}

@test "a tag without an image for a platform fails" {
	push_tag "$TAG" "$AMD64=linux/amd64" "$AMD64_ATTESTATION=unknown/unknown"

	run "$VERIFY_TAGS" "$IMAGE" <<< "$TAG"

	assert_failure 1
	assert_line "error: $IMAGE:$TAG has no linux/arm64 image"
}

@test "every problem with a tag is reported, not just the first" {
	push_tag "$TAG" "$AMD64=linux/amd64" "$AMD64_ATTESTATION=unknown/unknown"
	delete_manifest "$AMD64"
	delete_manifest "$AMD64_ATTESTATION"

	run "$VERIFY_TAGS" "$IMAGE" <<< "$TAG"

	assert_failure 1
	assert_line "error: $IMAGE:$TAG has no linux/arm64 image"
	assert_line "error: $IMAGE:$TAG references $AMD64, which is gone"
	assert_line "error: $IMAGE:$TAG references $AMD64_ATTESTATION, which is gone"
}

@test "a tag the registry cannot serve fails" {
	run "$VERIFY_TAGS" "$IMAGE" <<< "$TAG"

	assert_failure 1
	assert_line "error: $IMAGE:$TAG cannot be fetched"
}

@test "a tag on a single-platform image fails as not a manifest list" {
	echo '{"schemaVersion": 2, "config": {}, "layers": []}' | respond "$IMAGE:$TAG"

	run "$VERIFY_TAGS" "$IMAGE" <<< "$TAG"

	assert_failure 1
	assert_line "error: $IMAGE:$TAG is not a manifest list"
}

@test "a broken tag does not stop the tags after it from being checked" {
	push_whole_tag fpm

	run "$VERIFY_TAGS" "$IMAGE" <<-EOF
		$TAG
		fpm
	EOF

	assert_failure 1
	assert_line "error: $IMAGE:$TAG cannot be fetched"
	assert_line "ok: $IMAGE:fpm"
	assert_line "error: 1 of 2 tags of $IMAGE are broken: $TAG"
}

# Arguments

@test "an empty tag list fails, as the listing must have gone wrong" {
	run "$VERIFY_TAGS" "$IMAGE" < /dev/null

	assert_failure 1
	assert_output 'error: no tags on stdin to verify'
}

@test "verify-tags.sh without an image or with an empty one prints usage" {
	run "$VERIFY_TAGS" < /dev/null
	assert_failure 2
	assert_output --partial 'usage: verify-tags.sh <image>'

	run "$VERIFY_TAGS" '' < /dev/null
	assert_failure 2
}

@test "verify-tags.sh is executable and runs under set -Eeuo pipefail" {
	assert_file_executable "$REPO_ROOT/scripts/verify-tags.sh"
	assert_file_contains "$REPO_ROOT/scripts/verify-tags.sh" '^set -Eeuo pipefail$'
}
