#!/usr/bin/env bats
#
# Tests for scripts/select-matrix.sh. Run them with `task test`.
#
# They read test/fixtures/versions-matrix.json rather than the repo's
# versions.json, so an upstream merge that adds a suite does not move the
# default suite out from under them.

setup() {
	bats_require_minimum_version 1.5.0

	load helpers/common
	load_libraries
	setup_workdir

	cp "$FIXTURES/versions-matrix.json" "$WORKDIR/versions.json"

	# What pin-version.sh would render, minus the files.
	local variant
	for variant in $(jq -r '.["8.4"].variants[]' "$WORKDIR/versions.json"); do
		mkdir -p "$WORKDIR/8.4/$variant"
	done
}

# Loads the script's functions without running main.
source_select_matrix() {
	# shellcheck source=scripts/select-matrix.sh
	source "$SELECT_MATRIX"
	cd "$WORKDIR"
}

# Runs select-matrix.sh, expecting success, and sets MATRIX to the JSON.
select_matrix() {
	run "$SELECT_MATRIX" "$@"
	assert_success
	MATRIX="${output#matrix=}"
}

# Applies a jq filter to MATRIX.
matrix() {
	jq -c "$1" <<< "$MATRIX"
}

# Prints the directory and platform of each entry, one entry per line.
matrix_pairs() {
	jq -r '.include[] | "\(.directory) \(.platform)"' <<< "$MATRIX"
}

# Default config

@test "the default config selects cli, fpm and apache on the newest Debian suite for both platforms" {
	select_matrix 8.4

	run matrix_pairs
	assert_output - <<-'EOF'
		8.4/trixie/cli linux/amd64
		8.4/trixie/cli linux/arm64
		8.4/trixie/fpm linux/amd64
		8.4/trixie/fpm linux/arm64
		8.4/trixie/apache linux/amd64
		8.4/trixie/apache linux/arm64
	EOF
}

@test "a full version gives the same matrix as its branch" {
	select_matrix 8.4
	local branch_matrix="$MATRIX"

	select_matrix 8.4.13

	assert_equal "$MATRIX" "$branch_matrix"
}

@test "every entry has directory, variant, suite, platform and runner" {
	select_matrix 8.4

	assert_equal "$(matrix '[.include[] | keys_unsorted] | unique')" '[["directory","variant","suite","platform","runner"]]'
	assert_equal "$(matrix '.include[0]')" '{"directory":"8.4/trixie/cli","variant":"cli","suite":"trixie","platform":"linux/amd64","runner":"ubuntu-24.04"}'
	assert_equal "$(matrix '[.include[] | {platform, runner}] | unique')" '[{"platform":"linux/amd64","runner":"ubuntu-24.04"},{"platform":"linux/arm64","runner":"ubuntu-24.04-arm"}]'
}

@test "runner_for maps each platform to its native runner and fails for any other" {
	source_select_matrix

	assert_equal "$(runner_for linux/amd64)" ubuntu-24.04
	assert_equal "$(runner_for linux/arm64)" ubuntu-24.04-arm

	run runner_for linux/riscv64
	assert_failure 1
	assert_output "error: no runner builds platform 'linux/riscv64'"
}

# Suite

@test "the default suite is the first Debian suite versions.json lists, never an Alpine one" {
	edit_json build-config.json '.families.alpine = true'
	edit_json versions.json '.["8.4"].variants |= (map(select(startswith("alpine3.24/"))) + map(select(startswith("alpine3.24/") | not)))'
	source_select_matrix
	branch=8.4

	select_suite ''

	assert_equal "$suite" trixie
}

@test "a base override selects only that suite" {
	select_matrix 8.4 '' bookworm

	assert_equal "$(matrix '[.include[].suite] | unique')" '["bookworm"]'
	assert_equal "$(matrix '[.include[].directory] | unique')" '["8.4/bookworm/apache","8.4/bookworm/cli","8.4/bookworm/fpm"]'
}

@test "an unknown base fails and names the valid suites" {
	run "$SELECT_MATRIX" 8.4 '' trixy

	assert_failure 1
	assert_output "error: PHP 8.4 has no suite 'trixy'; valid suites: trixie bookworm"
}

@test "an Alpine base fails while families.alpine is false" {
	run "$SELECT_MATRIX" 8.4 '' alpine3.24

	assert_failure 1
	assert_output "error: suite 'alpine3.24' is in the alpine family, which build-config.json disables (families.alpine is false)"
}

@test "setting families.alpine to true is all it takes to select Alpine" {
	edit_json build-config.json '.families.alpine = true | .variants = ["cli", "fpm"]'

	select_matrix 8.4 '' alpine3.24

	run matrix_pairs
	assert_output - <<-'EOF'
		8.4/alpine3.24/cli linux/amd64
		8.4/alpine3.24/cli linux/arm64
		8.4/alpine3.24/fpm linux/amd64
		8.4/alpine3.24/fpm linux/arm64
	EOF
}

@test "Windows is never selected, whatever the config says" {
	edit_json build-config.json '.families |= (map_values(true) + { windows: true })'

	run "$SELECT_MATRIX" 8.4 '' windows
	assert_failure 1
	assert_output "error: suite 'windows' belongs to no family this repo builds; valid suites: trixie bookworm alpine3.24 alpine3.23"

	select_matrix 8.4
	assert_equal "$(matrix '[.include[] | select(.directory | contains("windows"))]')" '[]'
}

# Variants

@test "a variants override of cli selects only cli" {
	select_matrix 8.4 cli

	assert_equal "$(matrix '[.include[].directory] | unique')" '["8.4/trixie/cli"]'
	assert_equal "$(matrix '.include | length')" 2
}

@test "a variants override can add a variant build-config.json leaves out" {
	select_matrix 8.4 cli,zts

	run matrix_pairs
	assert_output - <<-'EOF'
		8.4/trixie/cli linux/amd64
		8.4/trixie/cli linux/arm64
		8.4/trixie/zts linux/amd64
		8.4/trixie/zts linux/arm64
	EOF
}

@test "a variants override accepts spaces after the commas and ignores repeats" {
	select_matrix 8.4 'cli, zts,cli'

	assert_equal "$(matrix '[.include[].variant]')" '["cli","cli","zts","zts"]'
}

@test "a variant the suite does not have fails and names the available ones" {
	run "$SELECT_MATRIX" 8.4 cli,fmp

	assert_failure 1
	assert_output "error: PHP 8.4 has no variant 'fmp' on trixie; available: cli apache fpm zts"
}

@test "apache on Alpine fails, since upstream renders no such directory" {
	edit_json build-config.json '.families.alpine = true'

	run "$SELECT_MATRIX" 8.4 '' alpine3.24

	assert_failure 1
	assert_output "error: PHP 8.4 has no variant 'apache' on alpine3.24; available: cli fpm zts"
}

# Branch and rendered directories

@test "a branch missing from versions.json fails" {
	run "$SELECT_MATRIX" 8.1.30

	assert_failure 1
	assert_output 'error: PHP 8.1 is not in versions.json; merge upstream docker-library/php first'
}

@test "a branch versions.json lists as null fails like a missing one" {
	edit_json versions.json '.["8.5"] = null'

	run "$SELECT_MATRIX" 8.5

	assert_failure 1
	assert_output 'error: PHP 8.5 is not in versions.json; merge upstream docker-library/php first'
}

@test "a directory that was not rendered fails and points at pin-version.sh" {
	rm -r "$WORKDIR/8.4/trixie/fpm"

	run "$SELECT_MATRIX" 8.4

	assert_failure 1
	assert_output 'error: 8.4/trixie/fpm does not exist; run scripts/pin-version.sh first'
}

# Output and invocation

@test "the output is a single matrix=<json> line that can go straight to GITHUB_OUTPUT" {
	local GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"

	"$SELECT_MATRIX" 8.4 >> "$GITHUB_OUTPUT"

	run cat "$GITHUB_OUTPUT"
	assert_equal "${#lines[@]}" 1
	assert_line --index 0 --regexp '^matrix=\{.*\}$'

	run jq -e '.include | length == 6' <<< "${lines[0]#matrix=}"
	assert_success
}

@test "select-matrix.sh rejects anything but a branch or a stable version with usage" {
	for version in 8 8.6.0RC3 v8.4 8.4.13.1 ''; do
		run "$SELECT_MATRIX" "$version"
		assert_failure 2
		assert_output --partial 'usage: select-matrix.sh <version> [variants] [base]'
	done
}

@test "select-matrix.sh without arguments or with too many prints usage" {
	run "$SELECT_MATRIX"
	assert_failure 2
	assert_output --partial 'usage: select-matrix.sh'

	run "$SELECT_MATRIX" 8.4 cli trixie extra
	assert_failure 2
	assert_output --partial 'usage: select-matrix.sh'
}

@test "select-matrix.sh is executable and runs under set -Eeuo pipefail" {
	assert_file_executable "$REPO_ROOT/scripts/select-matrix.sh"
	assert_file_contains "$REPO_ROOT/scripts/select-matrix.sh" '^set -Eeuo pipefail$'
}
