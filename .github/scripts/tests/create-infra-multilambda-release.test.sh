#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
release_script="$script_dir/../create-infra-multilambda-release.sh"
export REAL_GIT
REAL_GIT=$(command -v git)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/pn-20162.XXXXXX")
cleanup() {
  if [[ -d "$test_root" && "$test_root" == */pn-20162.* ]]; then
    rm -rf -- "$test_root"
  fi
}
trap cleanup EXIT
mkdir -p "$test_root/bin"

cat > "$test_root/bin/git" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
  ls-remote)
    printf 'git %s\n' "$*" >> "$FIXTURE/network.log"
    calls=0
    if [[ -f "$FIXTURE/remote-calls" ]]; then calls=$(< "$FIXTURE/remote-calls"); fi
    calls=$((calls + 1))
    printf '%s\n' "$calls" > "$FIXTURE/remote-calls"
    [[ "${STUB_REMOTE_FAIL:-false}" != true ]] || exit 9
    if [[ "$calls" -eq 2 && -n "${STUB_CONCURRENT_SHA:-}" ]]; then
      awk -v sha="$STUB_CONCURRENT_SHA" \
        '$2 == "refs/heads/develop" { $1 = sha } { print }' \
        "$FIXTURE/remote-refs" > "$FIXTURE/changed-refs"
      mv "$FIXTURE/changed-refs" "$FIXTURE/remote-refs"
    fi
    cat "$FIXTURE/remote-refs"
    ;;
  push)
    printf 'git %s\n' "$*" >> "$FIXTURE/network.log"
    [[ "$2" == --atomic && "$3" == origin ]] || exit 97
    [[ "${STUB_PUSH_FAIL:-false}" != true ]] || exit 10
    shift 3
    for spec in "$@"; do
      [[ "$spec" != +* ]] || exit 96
      source="${spec%%:*}"
      destination="${spec#*:}"
      sha=$("$REAL_GIT" rev-parse "$source")
      "$REAL_GIT" update-ref "$destination" "$sha"
      case "$destination" in
        refs/heads/*)
          "$REAL_GIT" update-ref "refs/remotes/origin/${destination#refs/heads/}" "$sha"
          ;;
      esac
    done
    "$REAL_GIT" for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags > "$FIXTURE/remote-refs"
    ;;
  fetch | pull | clone)
    printf 'Unexpected network command: git %s\n' "$*" >&2
    exit 95
    ;;
  *) exec "$REAL_GIT" "$@" ;;
esac
STUB

cat > "$test_root/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'gh %s\n' "$*" >> "$FIXTURE/network.log"
case "$1 $2" in
  "api --paginate")
    [[ "${STUB_API_FAIL:-false}" != true ]] || exit 11
    printf '%s' "${STUB_EXISTING_RELEASE:-}"
    ;;
  "release create")
    [[ "${STUB_RELEASE_FAIL:-false}" != true ]] || exit 12
    ;;
  *) exit 94 ;;
esac
STUB
chmod +x "$test_root/bin/git" "$test_root/bin/gh"
export PATH="$test_root/bin:$PATH"
fixture_count=0
passed=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  if [[ -f "${FIXTURE:-}/output" ]]; then cat "$FIXTURE/output" >&2; fi
  exit 1
}

g() {
  "$REAL_GIT" -C "$FIXTURE/repo" "$@"
}

sync_remote() {
  g for-each-ref --format='%(objectname) %(refname)' refs/heads refs/tags > "$FIXTURE/remote-refs"
  : > "$FIXTURE/network.log"
  printf '0\n' > "$FIXTURE/remote-calls"
}

new_fixture() {
  fixture_count=$((fixture_count + 1))
  export FIXTURE="$test_root/case-$fixture_count"
  mkdir -p "$FIXTURE/repo"
  g init -q
  g checkout -qb develop
  g config user.name "Release Test"
  g config user.email "release-test@example.invalid"
  g config commit.gpgsign false
  g config tag.gpgsign false
  printf '%s\n' "${1:-2.5.0-SNAPSHOT}" > "$FIXTURE/repo/VERSION"
  printf 'original application\n' > "$FIXTURE/repo/app.txt"
  printf '{"version":"1.0.0"}\n' > "$FIXTURE/repo/package.json"
  g add .
  g commit -qm baseline
  g branch main
  g remote add origin https://github.com/pagopa/pn-infra.git
  sync_remote
  export RELEASE_REPOSITORY=pagopa/pn-infra
  export RELEASE_VERSION=2.5.0-RC.1
  export RELEASE_BASE_BRANCH=develop
  export RELEASE_MERGE_IN_MAIN=true
  export RELEASE_INCREMENT_SNAPSHOT=false
  export GITHUB_STEP_SUMMARY="$FIXTURE/summary"
  unset STUB_PUSH_FAIL STUB_REMOTE_FAIL STUB_API_FAIL STUB_RELEASE_FAIL \
    STUB_EXISTING_RELEASE STUB_CONCURRENT_SHA
}

run_release() {
  (cd "$FIXTURE/repo" && bash "$release_script" "$@") > "$FIXTURE/output" 2>&1
}

pass() {
  passed=$((passed + 1))
  printf 'PASS %s\n' "$*"
}

expect_success() {
  run_release || fail "$1"
  pass "$1"
}

expect_preflight_failure() {
  if run_release; then fail "$1 unexpectedly succeeded"; fi
  grep -Fq -- "$2" "$FIXTURE/output" || fail "$1 did not explain the error"
  if grep -q '^git push\|^gh release create' "$FIXTURE/network.log"; then
    fail "$1 attempted publication"
  fi
  pass "$1"
}

assert_equal() {
  [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"
}

prepare_rc() {
  run_release || fail "RC fixture preparation"
  sync_remote
  : > "$FIXTURE/summary"
}

new_fixture
for target in pn-infra pn-infra-core pn-infra-confinfo pn-auth-fleet \
  pn-progression-sensor pn-cn pn-pdf-normalizer-integration pn-bfhd \
  go-automation pn-zendesk-auth; do
  RELEASE_REPOSITORY="pagopa/$target" run_release --validate-inputs || fail "repository format $target"
done
[[ ! -s "$FIXTURE/network.log" ]] || fail "input validation accessed the network"
pass "all ten targets accepted without target access"
RELEASE_REPOSITORY=pagopa/future-multilambda run_release --validate-inputs ||
  fail "a new workflow choice requires a script change"
[[ ! -s "$FIXTURE/network.log" ]] || fail "new repository validation accessed the network"
pass "future workflow choices require no script allowlist update"

for invalid in v2.5.0 02.5.0 2.05.0 2.5.00 2.5.0-RC.0 2.5.0-RC.01 2.5.0-RC-1 2.5.0-SNAPSHOT '2.5.0; echo injected'; do
  RELEASE_VERSION="$invalid" expect_preflight_failure "reject invalid version $invalid" "Expected X.Y.Z"
done
for invalid in '' pagopa/ pn-infra other-org/pn-infra pagopa/../pn-infra pagopa/-pn-infra 'pagopa/pn-infra; echo injected'; do
  RELEASE_REPOSITORY="$invalid" expect_preflight_failure "reject invalid repository '$invalid'" "pagopa/<name> format"
done
RELEASE_MERGE_IN_MAIN=invalid expect_preflight_failure "invalid merge boolean" "merge_in_main must"
RELEASE_INCREMENT_SNAPSHOT=invalid expect_preflight_failure "invalid increment boolean" "increment_snapshot must"
RELEASE_BASE_BRANCH='bad branch' expect_preflight_failure "invalid branch" "Invalid base branch"
RELEASE_BASE_BRANCH=release/2.5.0 expect_preflight_failure "base equals release branch" "must differ"

expect_success "first RC"
rc_sha=$(g rev-parse 'refs/tags/v2.5.0-RC.1^{commit}')
assert_equal "$(g show "$rc_sha:VERSION")" 2.5.0-RC.1 "RC VERSION"
assert_equal "$(g cat-file -t refs/tags/v2.5.0-RC.1)" tag "annotated RC tag"
assert_equal "$(g rev-parse refs/heads/release/2.5.0)" "$rc_sha" "RC branch"
assert_equal "$(g show "$rc_sha:package.json")" '{"version":"1.0.0"}' "Lambda version unchanged"
if grep -q '^gh release create' "$FIXTURE/network.log"; then fail "RC created a GitHub Release"; fi

sync_remote
expect_preflight_failure "duplicate RC tag" "already exists"
g checkout -q develop
printf 'fixed application\n' > "$FIXTURE/repo/app.txt"
g add app.txt
g commit -qm fix
sync_remote
RELEASE_VERSION=2.5.0-RC.2
expect_success "second RC incorporates base changes"
assert_equal "$(g show refs/heads/release/2.5.0:app.txt)" "fixed application" "RC base merge"
sync_remote
RELEASE_VERSION=2.5.0
expect_success "final release with main merge"
final_sha=$(g rev-parse 'refs/tags/v2.5.0^{commit}')
assert_equal "$(g rev-parse refs/heads/main)" "$final_sha" "final tag targets main"
assert_equal "$(g show "$final_sha:VERSION")" 2.5.0 "final VERSION"
g diff --quiet v2.5.0-RC.2 "$final_sha" -- . ':(exclude)VERSION' || fail "final altered RC code"
grep -Fq -- "--verify-tag --target $final_sha --generate-notes" "$FIXTURE/network.log" || fail "Release target not explicit"
sync_remote
expect_preflight_failure "repeated final fails before publication" "already exists"

new_fixture
prepare_rc
main_before=$(g rev-parse main)
RELEASE_VERSION=2.5.0
RELEASE_MERGE_IN_MAIN=false
expect_success "final without main merge"
assert_equal "$(g rev-parse main)" "$main_before" "main unchanged"
assert_equal "$(g rev-parse 'v2.5.0^{commit}')" "$(g rev-parse refs/heads/release/2.5.0)" "final targets release branch"

new_fixture
RELEASE_INCREMENT_SNAPSHOT=true
expect_success "optional next minor SNAPSHOT"
assert_equal "$(g show refs/heads/next-release:VERSION)" 2.6.0-SNAPSHOT "next minor"
assert_equal "$(g show develop:VERSION)" 2.5.0-SNAPSHOT "develop untouched"
next_before=$(g rev-parse next-release)
sync_remote
RELEASE_VERSION=2.5.0-RC.2
expect_success "compatible next-release reused without empty commit"
assert_equal "$(g rev-parse next-release)" "$next_before" "next-release reused"
grep -Fq "no empty commit" "$FIXTURE/output" || fail "reuse not reported"

new_fixture 2.999999999999999999999999.7-SNAPSHOT
RELEASE_VERSION=2.999999999999999999999999.7-RC.1
RELEASE_INCREMENT_SNAPSHOT=true
expect_success "minor increment avoids integer overflow and resets patch"
assert_equal "$(g show next-release:VERSION)" 2.1000000000000000000000000.0-SNAPSHOT "large minor"

new_fixture
prepare_rc
g checkout -q develop
printf '2.6.0-SNAPSHOT\n' > "$FIXTURE/repo/VERSION"
printf 'next cycle work\n' > "$FIXTURE/repo/app.txt"
g add .
g commit -qm next-cycle
sync_remote
RELEASE_VERSION=2.5.0
expect_success "final does not import or require the old VERSION on develop"
assert_equal "$(g show main:app.txt)" "original application" "new develop code not finalized"

new_fixture
g rm -q VERSION
g commit -qm missing-version
sync_remote
expect_preflight_failure "missing VERSION" "explicit onboarding"

new_fixture invalid-version
expect_preflight_failure "malformed VERSION" "Malformed VERSION"

new_fixture
g rm -q VERSION
ln -s app.txt "$FIXTURE/repo/VERSION"
g add VERSION
g commit -qm symlink-version
sync_remote
expect_preflight_failure "symlink VERSION rejected" "regular file"

new_fixture 2.4.0-SNAPSHOT
expect_preflight_failure "VERSION cycle mismatch" "inconsistent"

new_fixture
printf 'uncommitted\n' >> "$FIXTURE/repo/app.txt"
expect_preflight_failure "dirty working tree" "must be clean"

new_fixture
g remote set-url origin https://github.com/pagopa/pn-cicd.git
expect_preflight_failure "wrong target origin" "origin does not match"

new_fixture
RELEASE_VERSION=2.5.0
expect_preflight_failure "final without RC" "Required branch is missing"

new_fixture
prepare_rc
g checkout -q release/2.5.0
printf 'unvalidated fix\n' > "$FIXTURE/repo/app.txt"
g add app.txt
g commit -qm unvalidated-fix
sync_remote
RELEASE_VERSION=2.5.0
expect_preflight_failure "release advanced after RC" "advanced since the RC"

new_fixture
prepare_rc
g tag -a v2.5.0-RC-3 -m newer-number
sync_remote
RELEASE_VERSION=2.5.0-RC.2
expect_preflight_failure "RC number counts legacy separator" "greater than existing RC"
RELEASE_VERSION=2.5.0
expect_preflight_failure "final cannot select stale RC" "latest RC"

new_fixture
prepare_rc
g checkout -q release/2.5.0
printf '2.5.0-RC-2\n' > "$FIXTURE/repo/VERSION"
g add VERSION
g commit -qm historical-rc
g tag -a v2.5.0-RC-2 -m historical-rc
sync_remote
RELEASE_VERSION=2.5.0
expect_success "final accepts historical RC VERSION and tag"

new_fixture
prepare_rc
g checkout -q main
printf 'main-only\n' > "$FIXTURE/repo/main-only.txt"
g add main-only.txt
g commit -qm main-only
sync_remote
RELEASE_VERSION=2.5.0
expect_preflight_failure "main would introduce unvalidated content" "Merge would change final release content"

new_fixture
prepare_rc
g checkout -q release/2.5.0
printf 'release edit\n' > "$FIXTURE/repo/app.txt"
g add app.txt
g commit -qm release-edit
g checkout -q develop
printf 'conflicting base edit\n' > "$FIXTURE/repo/app.txt"
g add app.txt
g commit -qm base-edit
sync_remote
RELEASE_VERSION=2.5.0-RC.2
expect_preflight_failure "RC merge conflict" "CONFLICT"

new_fixture
g checkout -qb next-release
printf '2.7.0-SNAPSHOT\n' > "$FIXTURE/repo/VERSION"
g add VERSION
g commit -qm incompatible-next
sync_remote
RELEASE_INCREMENT_SNAPSHOT=true
expect_preflight_failure "incompatible next-release" "different version"

new_fixture
g checkout -qb next-release
printf '2.6.0-SNAPSHOT\n' > "$FIXTURE/repo/VERSION"
printf 'unexpected next code\n' > "$FIXTURE/repo/app.txt"
g add .
g commit -qm extra-next-content
sync_remote
RELEASE_INCREMENT_SNAPSHOT=true
expect_preflight_failure "next-release has extra code" "contains other changes"

new_fixture
export STUB_REMOTE_FAIL=true
expect_preflight_failure "remote read failure" "FAILED:"

new_fixture
g checkout -q --detach
printf 'concurrent work\n' > "$FIXTURE/repo/app.txt"
g add app.txt
g commit -qm concurrent
export STUB_CONCURRENT_SHA
STUB_CONCURRENT_SHA=$(g rev-parse HEAD)
expect_preflight_failure "concurrent remote update" "Relevant remote refs changed"

new_fixture
export STUB_PUSH_FAIL=true
if run_release; then fail "push failure succeeded"; fi
grep -Fq "confirmed success: false" "$FIXTURE/output" || fail "uncertain push not reported"
if grep -q '^gh release create' "$FIXTURE/network.log"; then fail "Release attempted after push error"; fi
if grep -Fq 'refs/tags/v2.5.0-RC.1' "$FIXTURE/remote-refs"; then fail "rejected push changed remote refs"; fi
pass "failed atomic push stops and reports attempted refs"

new_fixture
prepare_rc
export STUB_API_FAIL=true
RELEASE_VERSION=2.5.0
expect_preflight_failure "GitHub API failure stops before publication" "FAILED:"

new_fixture
prepare_rc
export STUB_EXISTING_RELEASE=v2.5.0
RELEASE_VERSION=2.5.0
expect_preflight_failure "orphan GitHub Release detected" "GitHub Release v2.5.0 already exists"

new_fixture
prepare_rc
export STUB_RELEASE_FAIL=true
RELEASE_VERSION=2.5.0
if run_release; then fail "GitHub Release failure succeeded"; fi
grep -Fq "confirmed success: true" "$FIXTURE/summary" || fail "published refs omitted"
grep -Fq "GitHub Release creation attempted" "$FIXTURE/summary" || fail "partial API state omitted"
grep -Fq "refs/tags/v2.5.0" "$FIXTURE/remote-refs" || fail "published final tag missing"
if grep -q '^SUCCESS:' "$FIXTURE/output"; then fail "partial failure reported success"; fi
pass "GitHub Release failure reports partial publication without rollback"
sync_remote
expect_preflight_failure "partial publication cannot be blindly repeated" "already exists"

new_fixture
RELEASE_REPOSITORY=pagopa/future-multilambda
g remote set-url origin https://github.com/pagopa/future-multilambda.git
expect_success "release of a future workflow target without script changes"
assert_equal "$(g show refs/heads/release/2.5.0:VERSION)" 2.5.0-RC.1 "future target VERSION"

printf '\n%s checks passed. No real network commands executed.\n' "$passed"
