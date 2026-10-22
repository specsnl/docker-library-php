#!/usr/bin/env bats
#
# Tests for scripts/list-tags.sh. Run them with `task test`.
#
# The container has no GitHub access, so the fake gh in test/helpers/bin
# answers the package versions endpoint from a file in GH_API, which these
# tests write, and logs each call to GH_LOG.

IMAGE='ghcr.io/specsnl/php'
ENDPOINT='/orgs/specsnl/packages/container/php/versions'

setup() {
	bats_require_minimum_version 1.5.0

	load helpers/common
	load_libraries
	setup_workdir
}

# Writes the package versions the API returns, one version per argument as a
# space-separated list of its tags. An empty argument is an untagged version.
versions_with_tags() {
	local tags id=0
	for tags in "$@"; do
		jq -n --argjson id "$((++id))" --arg tags "$tags" \
			'{ id: $id, metadata: { package_type: "container", container: { tags: ($tags | split(" ") | map(select(. != ""))) } } }'
	done | jq -s . > "$GH_API/${ENDPOINT//\//_}"
}

@test "every tag is listed once, in version order, and untagged versions add nothing" {
	versions_with_tags '8.4.14-fpm-trixie 8.4-fpm-trixie 8-fpm fpm' '' '8.4.9-fpm-trixie' '8.4.13-fpm-trixie' ''

	run --separate-stderr "$LIST_TAGS" "$IMAGE"

	assert_success
	assert_output - <<-'EOF'
		8-fpm
		8.4-fpm-trixie
		8.4.9-fpm-trixie
		8.4.13-fpm-trixie
		8.4.14-fpm-trixie
		fpm
	EOF
}

@test "the versions are read through the GitHub API, every page of them" {
	versions_with_tags fpm

	run "$LIST_TAGS" "$IMAGE"

	assert_success
	run cat "$GH_LOG"
	assert_output "api --paginate $ENDPOINT --jq .[].metadata.container.tags[]"
}

@test "a package without tags prints nothing" {
	versions_with_tags '' ''

	run "$LIST_TAGS" "$IMAGE"

	assert_success
	assert_output ''
}

@test "an API error fails the run instead of printing a partial list" {
	versions_with_tags fpm
	export GH_FAIL=1

	run --separate-stderr "$LIST_TAGS" "$IMAGE"

	assert_failure 1
	assert_output ''
}

@test "a missing package fails the run" {
	run --separate-stderr "$LIST_TAGS" "$IMAGE"

	assert_failure 1
	assert_output ''
}

@test "an image that is not on GHCR, or has a tag or digest, is rejected before gh runs" {
	for image in docker.io/library/php ghcr.io/specsnl ghcr.io/specsnl/php:fpm 'ghcr.io/specsnl/php@sha256:0' ghcr.io/a/b/c; do
		run "$LIST_TAGS" "$image"

		assert_failure 2
		assert_line "error: '$image' is not a GHCR image like ghcr.io/specsnl/php"
	done

	assert_file_empty "$GH_LOG"
}

@test "anything but one image argument prints usage" {
	run "$LIST_TAGS"
	assert_failure 2
	assert_output --partial 'usage: list-tags.sh <image>'

	run "$LIST_TAGS" "$IMAGE" extra
	assert_failure 2

	assert_file_empty "$GH_LOG"
}

@test "list-tags.sh is executable and runs under set -Eeuo pipefail" {
	assert_file_executable "$REPO_ROOT/scripts/list-tags.sh"
	assert_file_contains "$REPO_ROOT/scripts/list-tags.sh" '^set -Eeuo pipefail$'
}
