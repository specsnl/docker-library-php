# Shared setup for the bats suites.
#
# The repo is mounted read-only, so every test works on a copy of the files
# pin-version.sh and apply-templates.sh need, under BATS_TEST_TMPDIR.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

load_libraries() {
	bats_load_library bats-support
	bats_load_library bats-assert
	bats_load_library bats-file
}

# Copies the repo into WORKDIR and puts the fake curl first on PATH.
#
# cp -p keeps the mtimes: apply-templates.sh downloads .jq-template.awk again
# whenever it is newer than that file, and there is no network to do it with.
setup_workdir() {
	if [ ! -f "$REPO_ROOT/.jq-template.awk" ]; then
		fail ".jq-template.awk is missing; run the suite with 'task test', which fetches it"
	fi

	WORKDIR="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$WORKDIR"
	cp -p \
		"$REPO_ROOT/versions.json" \
		"$REPO_ROOT/Dockerfile-linux.template" \
		"$REPO_ROOT/apply-templates.sh" \
		"$REPO_ROOT/.jq-template.awk" \
		"$REPO_ROOT"/docker-php-* \
		"$REPO_ROOT/apache2-foreground" \
		"$WORKDIR/"
	cp -pR "$REPO_ROOT/scripts" "$WORKDIR/"

	# shellcheck disable=SC2034 # used by the suites that load this file
	PIN_VERSION="$WORKDIR/scripts/pin-version.sh"

	export FIXTURES="$REPO_ROOT/test/fixtures"
	export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
	: > "$CURL_LOG"
	PATH="$REPO_ROOT/test/helpers/bin:$PATH"
}
