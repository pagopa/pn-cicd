#!/usr/bin/env bash

set -Eeuo pipefail

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> -i <github-commitid> -a <account> -b <artifact-bucket> [-c <custom-config-dir>] [-w <work-dir>]

  -h                         Show this help message
  -v                         Enable verbose mode
  -p <aws-profile>           AWS CLI profile (optional)
  -r <aws-region>            AWS region, for example eu-south-1
  -e <env-type>              Environment name
  -i <github-commitid>       pn-infra Git commit ID
  -a <account>               Account type: core or confinfo
  -b <artifact-bucket>       S3 bucket used for nested CloudFormation templates
  -c <custom-config-dir>     Additional environment configuration directory
  -w <work-dir>              Working directory (default: /tmp)
EOF
  exit 1
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

aws_region=""
env_type=""
pn_infra_commitid=""
account=""
artifact_bucket=""
custom_config_dir=""
work_dir="/tmp"
aws_profile=""

while :; do
  case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -p | --profile) aws_profile="${2-}"; shift ;;
    -r | --region) aws_region="${2-}"; shift ;;
    -e | --env-name) env_type="${2-}"; shift ;;
    -i | --infra-commitid) pn_infra_commitid="${2-}"; shift ;;
    -a | --account) account="${2-}"; shift ;;
    -b | --artifact-bucket) artifact_bucket="${2-}"; shift ;;
    -c | --custom-config-dir) custom_config_dir="${2-}"; shift ;;
    -w | --work-dir) work_dir="${2-}"; shift ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
  esac
  shift
done

[[ -z "$aws_region" ]] && usage
[[ -z "$env_type" ]] && usage
[[ -z "$pn_infra_commitid" ]] && usage
[[ -z "$artifact_bucket" ]] && usage
[[ "$account" != "core" && "$account" != "confinfo" ]] && die "Account must be 'core' or 'confinfo', got: $account"

if [[ "$env_type" != "dev" && "$env_type" != "hotfix" ]]; then
  echo "Prowler is enabled only in dev and hotfix; skipping environment $env_type"
  exit 0
fi

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
cd "$work_dir"

if [[ ! -d pn-infra ]]; then
  git clone https://github.com/pagopa/pn-infra.git
fi
(cd pn-infra && git fetch && git checkout "$pn_infra_commitid")

if [[ -n "$custom_config_dir" ]]; then
  cp -r "$custom_config_dir/pn-infra" .
fi

aws_command_base_args=(--region "$aws_region")
if [[ -n "$aws_profile" ]]; then
  aws_command_base_args+=(--profile "$aws_profile")
fi

template_bucket_base_path="pn-infra/${pn_infra_commitid}"
template_bucket_base_url="https://s3.${aws_region}.amazonaws.com/${artifact_bucket}/${template_bucket_base_path}/runtime-infra"
if [[ "$account" == "core" ]]; then
  aws "${aws_command_base_args[@]}" s3 cp pn-infra \
    "s3://${artifact_bucket}/${template_bucket_base_path}" \
    --recursive --exclude '.git/*' --quiet
fi

outputs_file="infra_all_outputs-${env_type}.json"
if [[ "$account" == "core" ]]; then
  (cd "$script_dir/commons" && ./merge-infra-outputs-core.sh -r "$aws_region" -e "$env_type" -o "$work_dir/$outputs_file")
else
  (cd "$script_dir/commons" && ./merge-infra-outputs-confinfo.sh -r "$aws_region" -e "$env_type" -o "$work_dir/$outputs_file")
fi

template_path="pn-infra/runtime-infra/pn-prowler.yaml"
config_path="pn-infra/runtime-infra/pn-prowler-${env_type}-cfg.json"
enhanced_config_path="pn-prowler-${account}-${env_type}-cfg-enhanced.json"

[[ -f "$template_path" ]] || die "Missing template $template_path"
if [[ ! -f "$config_path" ]]; then
  echo '{ "Parameters": {} }' > "$config_path"
fi

jq -s '
    {"Parameters": (.[0] | with_entries(select(.key == "PnCoreAwsAccountId" or .key == "ConfidentialInfoAccountId")))} * .[1]
  ' "$outputs_file" "$config_path" \
  | jq -r \
      --arg account "$account" \
      --arg environment "$env_type" \
      --arg template_bucket_base_url "$template_bucket_base_url" \
      '.Parameters + {
        AccountType: $account,
        EnvironmentType: $environment,
        TemplateBucketBaseUrl: $template_bucket_base_url
      } | to_entries | map("\(.key)=\(.value)")' \
      > "$enhanced_config_path"

aws "${aws_command_base_args[@]}" cloudformation deploy \
  --stack-name "pn-prowler-${account}-${env_type}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --template-file "$template_path" \
  --tags Microservice=pn-prowler Environment="$env_type" AccountType="$account" \
  --parameter-overrides "file://$(realpath "$enhanced_config_path")"