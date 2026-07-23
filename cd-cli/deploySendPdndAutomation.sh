#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
}

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-p <aws-profile>] -r <aws-region> -e <env-type> -i <pn-infra-commitid> -b <artifact-bucket> [-c <custom-config-dir>] [-w <work-dir>]
EOF
  exit 1
}

project_name=pn
work_dir=$HOME/tmp/poste_deploy
custom_config_dir=""
aws_profile=""
aws_region=""
env_type=""
pn_infra_commitid=""
bucket_name=""

while :; do
  case "${1-}" in
    -h | --help) usage ;;
    -p | --profile) aws_profile="${2-}"; shift ;;
    -r | --region) aws_region="${2-}"; shift ;;
    -e | --env-name) env_type="${2-}"; shift ;;
    -i | --infra-commitid) pn_infra_commitid="${2-}"; shift ;;
    -b | --bucket-name) bucket_name="${2-}"; shift ;;
    -c | --custom-config-dir) custom_config_dir="${2-}"; shift ;;
    -w | --work-dir) work_dir="${2-}"; shift ;;
    -?*) usage ;;
    *) break ;;
  esac
  shift
done

[[ -z "${aws_region}" ]] && usage
[[ -z "${env_type}" ]] && usage
[[ -z "${pn_infra_commitid}" ]] && usage
[[ -z "${bucket_name}" ]] && usage

case "${env_type}" in
  dev | hotfix | prod) ;;
  *)
    echo "SEND PDND automation is not enabled for ${env_type}; skipping deployment."
    exit 0
    ;;
esac

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
cd "${work_dir}"

echo "=== Download pn-infra"
if [[ ! -e pn-infra ]]; then
  git clone https://github.com/pagopa/pn-infra.git
fi

echo "=== Checkout pn-infra commitId=${pn_infra_commitid}"
(cd pn-infra && git fetch && git checkout "${pn_infra_commitid}")

if [[ -n "${custom_config_dir}" && -d "${custom_config_dir}/pn-infra" ]]; then
  cp -r "${custom_config_dir}/pn-infra" .
fi

template_path=pn-infra/runtime-infra/pn-send-pdnd-automation.yaml
config_path=pn-infra/runtime-infra/pn-send-pdnd-automation-${env_type}-cfg.json
if [[ ! -f "${template_path}" || ! -f "${config_path}" ]]; then
  echo "SEND PDND automation configuration not available for ${env_type}; skipping deployment."
  exit 0
fi

aws_command_base_args=()
if [[ -n "${aws_profile}" ]]; then
  aws_command_base_args+=(--profile "${aws_profile}")
fi
aws_command_base_args+=(--region "${aws_region}")

template_bucket_base_path="pn-infra/${pn_infra_commitid}"
template_bucket_base_url="https://s3.${aws_region}.amazonaws.com/${bucket_name}/${template_bucket_base_path}/runtime-infra"
lambda_base_path="pn-send-pdnd-automation/${pn_infra_commitid}"

echo "=== Upload SEND PDND automation templates"
aws "${aws_command_base_args[@]}" s3 cp pn-infra "s3://${bucket_name}/${template_bucket_base_path}" \
  --recursive --exclude ".git/*" --quiet

for runner_name in \
  "send-pdnd-signup-runner" \
  "send-pdnd-onboarding-tech-runner"
do
  runner_source="pn-infra/runtime-infra/lambdas/${runner_name}"
  runner_build="${work_dir}/${runner_name}-build"
  runner_zip="${work_dir}/${runner_name}.zip"

  echo "=== Package ${runner_name}"
  rm -rf "${runner_build}"
  rm -f "${runner_zip}"
  mkdir -p "${runner_build}"
  cp "${runner_source}/package.json" "${runner_source}/package-lock.json" \
    "${runner_source}"/*.js "${runner_build}/"
  (cd "${runner_build}" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund)
  (cd "${runner_build}" && zip -qr "${runner_zip}" .)
  aws "${aws_command_base_args[@]}" s3 cp "${runner_zip}" \
    "s3://${bucket_name}/${lambda_base_path}/${runner_name}.zip" --quiet
  rm -rf "${runner_build}"
  rm -f "${runner_zip}"
done

infra_outputs_path="${work_dir}/infra_all_outputs_${env_type}.json"
merge_outputs_args=(-r "${aws_region}" -e "${env_type}" -o "${infra_outputs_path}")
if [[ -n "${aws_profile}" ]]; then
  merge_outputs_args+=(-p "${aws_profile}")
fi
(cd "${script_dir}/commons" && ./merge-infra-outputs-core.sh "${merge_outputs_args[@]}")

warning_topic_arn=$(jq -r '.WarningSNSTopicArn // empty' "${infra_outputs_path}")
if [[ -z "${warning_topic_arn}" ]]; then
  echo "Missing WarningSNSTopicArn in the merged pn-infra-storage outputs."
  exit 1
fi

EnhancedParamFilePath="${work_dir}/pn-send-pdnd-automation-${env_type}-cfg-enhanced.json"

echo "= Enhanced parameters file"
jq -s '{ "Parameters": .[0] } * .[1]' \
  "${infra_outputs_path}" "${config_path}" \
  | jq '.Parameters | to_entries | map("\(.key)=\(.value | tostring)")' \
  > "${EnhancedParamFilePath}"

PipelineParams=(
  "TemplateBucketBaseUrl=${template_bucket_base_url}"
  "ProjectName=${project_name}"
  "EnvironmentType=${env_type}"
  "LambdasBucketName=${bucket_name}"
  "LambdasBasePath=${lambda_base_path}"
)
jq \
  --args \
  '. + $ARGS.positional' \
  "${PipelineParams[@]}" \
  < "${EnhancedParamFilePath}" \
  > "${EnhancedParamFilePath}.tmp"
mv "${EnhancedParamFilePath}.tmp" "${EnhancedParamFilePath}"
cat "${EnhancedParamFilePath}"

echo "=== Deploy SEND PDND automation for ${env_type}"
aws "${aws_command_base_args[@]}" cloudformation deploy \
  --stack-name "pn-send-pdnd-automation-${env_type}" \
  --capabilities CAPABILITY_NAMED_IAM \
  --template-file "${template_path}" \
  --tags Microservice=pn-send-pdnd-automation \
  --parameter-overrides "file://$(realpath "${EnhancedParamFilePath}")"
