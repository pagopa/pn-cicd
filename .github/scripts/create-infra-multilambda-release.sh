#!/usr/bin/env bash
set -Eeuo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

increment_decimal() {
  local number="$1" suffix="" digit
  while [[ -n "$number" ]]; do
    digit="${number: -1}"
    number="${number%?}"
    if [[ "$digit" != 9 ]]; then
      printf '%s%s%s\n' "$number" "$((digit + 1))" "$suffix"
      return
    fi
    suffix="0$suffix"
  done
  printf '1%s\n' "$suffix"
}

decimal_greater() {
  [[ ${#1} -gt ${#2} || ( ${#1} -eq ${#2} && "$1" > "$2" ) ]]
}

repository="${RELEASE_REPOSITORY:-}"
version="${RELEASE_VERSION:-}"
base_branch="${RELEASE_BASE_BRANCH:-develop}"
merge_in_main="${RELEASE_MERGE_IN_MAIN:-true}"
increment_snapshot="${RELEASE_INCREMENT_SNAPSHOT:-false}"
number='(0|[1-9][0-9]*)'
version_pattern="^${number}\\.${number}\\.${number}(-RC\\.([1-9][0-9]*))?$"
file_version_pattern="^${number}\\.${number}\\.${number}(-SNAPSHOT|-RC[.-][1-9][0-9]*)?$"

case "$repository" in
  pagopa/pn-infra | pagopa/pn-infra-core | pagopa/pn-infra-confinfo | \
  pagopa/pn-auth-fleet | pagopa/pn-progression-sensor | pagopa/pn-cn | \
  pagopa/pn-pdf-normalizer-integration | pagopa/pn-bfhd | \
  pagopa/go-automation | pagopa/pn-zendesk-auth) ;;
  *) die "Repository is not in the approved infra/multilambda list: $repository" ;;
esac
[[ "$version" =~ $version_pattern ]] || die "Expected X.Y.Z or X.Y.Z-RC.N without a v prefix"
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
version_base="$major.$minor.$patch"
rc_number="${BASH_REMATCH[5]:-}"
[[ "$merge_in_main" == true || "$merge_in_main" == false ]] || die "merge_in_main must be true or false"
[[ "$increment_snapshot" == true || "$increment_snapshot" == false ]] || die "increment_snapshot must be true or false"
[[ -n "$base_branch" && "$base_branch" != -* && "$base_branch" != refs/* ]] ||
  die "Invalid base branch"
git check-ref-format "refs/heads/$base_branch" || die "Invalid base branch"
release_branch="release/$version_base"
[[ "$base_branch" != "$release_branch" && "$base_branch" != next-release ]] ||
  die "The base branch must differ from the release and next-release branches"
if [[ "${1:-}" == --validate-inputs && $# -eq 1 ]]; then
  exit 0
fi
[[ $# -eq 0 ]] || die "Unexpected arguments"

step="checking target repository"
publish_attempted=false
release_attempted=false
published=false
remote_snapshot=""
fresh_snapshot=""
tag="v$version"
publication_refs=()

report() {
  printf '%s\n' "$*"
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    printf '%s\n' "$*" >> "$GITHUB_STEP_SUMMARY"
  fi
}

finish() {
  local status=$?
  trap - EXIT
  if [[ $status -ne 0 ]]; then
    report "FAILED: $repository $version during: $step" >&2
    if [[ "$publish_attempted" == true ]]; then
      report "Git publication attempted (confirmed success: $published). Inspect these refs before recovery:" >&2
      printf '  %s\n' "${publication_refs[@]}" >&2
      if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        printf '  %s\n' "${publication_refs[@]}" >> "$GITHUB_STEP_SUMMARY"
      fi
    fi
    if [[ "$release_attempted" == true ]]; then
      report "GitHub Release creation attempted for $tag; inspect its state before recovery." >&2
    fi
    report "No automatic rollback or overwrite. Resolve the cause and recover manually; do not blindly rerun." >&2
  fi
  if [[ -n "$remote_snapshot" ]]; then rm -f -- "$remote_snapshot"; fi
  if [[ -n "$fresh_snapshot" ]]; then rm -f -- "$fresh_snapshot"; fi
  exit "$status"
}
trap finish EXIT

[[ -z "$(git rev-parse --show-prefix)" ]] || die "Run from the target repository root"
[[ -z "$(git status --porcelain)" ]] || die "Target working tree must be clean"
origin_url=$(git remote get-url origin)
[[ "$origin_url" == "https://github.com/$repository.git" || "$origin_url" == "https://github.com/$repository" ]] ||
  die "origin does not match the requested repository"
git config user.name "GitHub Actions Bot"
git config user.email "github-actions[bot]@users.noreply.github.com"
remote_snapshot=$(mktemp)
fresh_snapshot=$(mktemp)
git ls-remote origin > "$remote_snapshot"

remote_oid() {
  awk -v ref="$1" '$2 == ref { print $1 }' "$remote_snapshot"
}

read_version() {
  local sha="$1" entry value
  entry=$(git ls-tree "$sha" -- VERSION)
  case "$entry" in
    "100644 blob "* | "100755 blob "*) ;;
    *) die "VERSION must exist as a regular file at $sha; explicit onboarding is required" ;;
  esac
  value=$(git show "$sha:VERSION")
  [[ "$value" =~ $file_version_pattern ]] || die "Malformed VERSION at $sha"
  printf '%s\n' "$value"
}

check_cycle() {
  local value
  value=$(read_version "$1")
  [[ "${value%%-*}" == "$version_base" ]] ||
    die "VERSION $value at $1 is inconsistent with requested cycle $version_base"
}

require_commit() {
  [[ -n "$1" ]] || die "Required branch is missing: $2"
  git cat-file -e "$1^{commit}" ||
    die "Remote revision for $2 is not available locally; start again with a fresh full checkout"
}

latest_rc() {
  local oid ref candidate latest=0
  while read -r oid ref; do
    case "$ref" in
      "refs/tags/v${version_base}-RC."* | "refs/tags/v${version_base}-RC-"*)
        candidate="${ref#"refs/tags/v${version_base}-RC"}"
        candidate="${candidate:1}"
        if [[ "$candidate" =~ ^[1-9][0-9]*$ ]] && decimal_greater "$candidate" "$latest"; then
          latest="$candidate"
        fi
        ;;
    esac
  done < "$remote_snapshot"
  printf '%s\n' "$latest"
}

step="validating remote refs and VERSION"
base_sha=$(remote_oid "refs/heads/$base_branch")
release_sha=$(remote_oid "refs/heads/$release_branch")
main_sha=$(remote_oid refs/heads/main)
next_sha=$(remote_oid refs/heads/next-release)
require_commit "$base_sha" "$base_branch"
if [[ -n "$rc_number" ]]; then check_cycle "$base_sha"; fi
[[ -z "$(remote_oid "refs/tags/$tag")" ]] || die "Tag $tag already exists; tags are immutable"
[[ -z "$(remote_oid "refs/tags/v$version_base")" ]] || die "Cycle $version_base already has a final tag"
latest=$(latest_rc)

if [[ -n "$rc_number" ]]; then
  decimal_greater "$rc_number" "$latest" || die "RC number must be greater than existing RC $latest"
  if [[ -n "$release_sha" ]]; then
    require_commit "$release_sha" "$release_branch"
    check_cycle "$release_sha"
  fi
else
  require_commit "$release_sha" "$release_branch"
  current_version=$(read_version "$release_sha")
  [[ ( "$current_version" == "$version_base-RC.$latest" ||
       "$current_version" == "$version_base-RC-$latest" ) && "$latest" != 0 ]] ||
    die "The release branch must identify the latest RC of $version_base"
  rc_ref="refs/tags/v$current_version"
  rc_oid=$(remote_oid "$rc_ref")
  [[ -n "$rc_oid" ]] || die "A published RC tag is required"
  [[ "$(git rev-parse --verify "$rc_ref")" == "$rc_oid" ]] || die "Local RC tag differs from remote"
  rc_sha=$(git rev-parse --verify "$rc_ref^{commit}")
  [[ "$rc_sha" == "$release_sha" ]] || die "Release branch advanced since the RC; create a new RC"
  if [[ "$merge_in_main" == true ]]; then require_commit "$main_sha" main; fi
  existing_releases=$(gh api --paginate "repos/$repository/releases?per_page=100" --jq '.[].tag_name')
  if grep -Fxq -- "$tag" <<< "$existing_releases"; then
    die "GitHub Release $tag already exists"
  fi
fi

next_publication=""
if [[ "$increment_snapshot" == true ]]; then
  step="preparing the next minor SNAPSHOT"
  next_version="$major.$(increment_decimal "$minor").0-SNAPSHOT"
  base_version=$(read_version "$base_sha")
  [[ "${base_version%%-*}" == "$version_base" || "$base_version" == "$next_version" ]] ||
    die "Base VERSION is incompatible with the requested next cycle"
  if [[ -n "$next_sha" ]]; then
    require_commit "$next_sha" next-release
    [[ "$(read_version "$next_sha")" == "$next_version" ]] ||
      die "Existing next-release has a different version; integrate or resolve it manually"
    git merge-base --is-ancestor "$base_sha" "$next_sha" ||
      die "Existing next-release is not based on the selected base revision"
    git diff --quiet "$base_sha" "$next_sha" -- . ':(exclude)VERSION' ||
      die "Existing next-release contains other changes; resolve it manually"
    report "next-release already contains the expected $next_version; no empty commit created."
  else
    git checkout --detach "$base_sha"
    if [[ "$base_version" != "$next_version" ]]; then
      printf '%s\n' "$next_version" > VERSION
      git add -- VERSION
      git commit -m "[$next_version] Prepare next minor development cycle"
    fi
    next_publication="$(git rev-parse HEAD):refs/heads/next-release"
  fi
fi

if [[ -n "$rc_number" ]]; then
  step="preparing release candidate"
  git checkout --detach "${release_sha:-$base_sha}"
  if [[ -n "$release_sha" ]]; then
    git merge --no-edit "$base_sha"
    check_cycle HEAD
  fi
  printf '%s\n' "$version" > VERSION
  git add -- VERSION
  git commit -m "[$version] Create release candidate"
  release_sha=$(git rev-parse HEAD)
  target_sha="$release_sha"
else
  step="preparing final release"
  git checkout --detach "$release_sha"
  printf '%s\n' "$version" > VERSION
  git add -- VERSION
  git commit -m "[$version] Create final release"
  release_sha=$(git rev-parse HEAD)
  target_sha="$release_sha"
  if [[ "$merge_in_main" == true ]]; then
    git checkout --detach "$main_sha"
    git merge --no-edit "$release_sha"
    target_sha=$(git rev-parse HEAD)
    git diff --quiet "$release_sha" "$target_sha" -- ||
      die "Merge would change final release content; no refs have been published"
  fi
  git diff --quiet "$rc_sha" "$target_sha" -- . ':(exclude)VERSION' ||
    die "Final content differs from the RC outside VERSION"
fi

step="checking for concurrent remote changes"
git ls-remote origin > "$fresh_snapshot"
relevant_refs() {
  awk -v base="refs/heads/$base_branch" -v release="refs/heads/$release_branch" \
    -v prefix="refs/tags/v$version_base" \
    '$2 == base || $2 == release || $2 == "refs/heads/main" ||
     $2 == "refs/heads/next-release" || $2 == prefix ||
     index($2, prefix "-RC.") == 1 || index($2, prefix "-RC-") == 1 { print }' "$1" | LC_ALL=C sort
}
diff -q <(relevant_refs "$remote_snapshot") <(relevant_refs "$fresh_snapshot") ||
  die "Relevant remote refs changed during preparation; no publication attempted"
git tag -a "$tag" "$target_sha" -m "Release $version"
publication_refs=("$release_sha:refs/heads/$release_branch" "refs/tags/$tag:refs/tags/$tag")
if [[ -z "$rc_number" && "$merge_in_main" == true ]]; then
  publication_refs+=("$target_sha:refs/heads/main")
fi
if [[ -n "$next_publication" ]]; then publication_refs+=("$next_publication"); fi
step="publishing Git refs atomically"
publish_attempted=true
git push --atomic origin "${publication_refs[@]}"
published=true
report "Published $repository $version: $tag -> $target_sha (branch $release_branch -> $release_sha)."
if [[ "$increment_snapshot" == true ]]; then
  report "Next cycle: $next_version on next-release. Integration into $base_branch remains manual."
fi

if [[ -z "$rc_number" ]]; then
  step="creating GitHub Release"
  release_attempted=true
  gh release create "$tag" --repo "$repository" --verify-tag --target "$target_sha" --generate-notes
fi
report "SUCCESS: Git release workflow completed. Build, artifact validation and deployment are separate."
