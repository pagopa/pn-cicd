#!/usr/bin/env bash

set -Eeuo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <bff-commit-id> <jwt-authorizer-zip>" >&2
  exit 1
fi

bff_commit_id="$1"
jwt_archive="$2"

if [[ ! "$bff_commit_id" =~ ^[[:xdigit:]]{40}$ ]]; then
  echo "A resolved, full pn-bff commit ID is required for JWT policy packaging" >&2
  exit 1
fi

if [[ ! -f "$jwt_archive" ]]; then
  echo "JWT authorizer archive not found: $jwt_archive" >&2
  exit 1
fi

archive_dir=$(cd "$(dirname "$jwt_archive")" && pwd -P)
jwt_archive="${archive_dir}/$(basename "$jwt_archive")"
staging_dir=$(mktemp -d "${archive_dir}/.jwt-policies.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT

bff_dir="${staging_dir}/pn-bff"
git clone --no-checkout https://github.com/pagopa/pn-bff.git "$bff_dir"
git -C "$bff_dir" checkout --detach "$bff_commit_id"

policies_dir="${bff_dir}/docs/openapi/policies/generated"
if [[ ! -d "$policies_dir" ]]; then
  echo "BFF policies not found at commit ${bff_commit_id}: docs/openapi/policies/generated" >&2
  exit 1
fi
if [[ -z "$(find "$policies_dir" -type f -print -quit)" ]]; then
  echo "No BFF policy files found at commit ${bff_commit_id}" >&2
  exit 1
fi

package_dir="${staging_dir}/package"
unzip -q "$jwt_archive" -d "$package_dir"
generated_dir="${package_dir}/resource/policies/generated"
rm -rf "$generated_dir"
mkdir -p "$generated_dir"
cp -R "${policies_dir}/." "$generated_dir/"

(cd "$package_dir" && zip -q -r "${staging_dir}/jwtAuthorizer.zip" .)
mv "${staging_dir}/jwtAuthorizer.zip" "$jwt_archive"
echo "JWT policies packaged from pn-bff commit ${bff_commit_id}"