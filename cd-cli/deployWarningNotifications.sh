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
    -p | --profile)
      aws_profile="${2-}"
      shift
      ;;
    -r | --region)
      aws_region="${2-}"
      shift
      ;;
    -e | --env-name)
      env_type="${2-}"
      shift
      ;;
    -i | --infra-commitid)
      pn_infra_commitid="${2-}"
      shift
      ;;
    -b | --bucket-name)
      bucket_name="${2-}"
      shift
      ;;
    -c | --custom-config-dir)
      custom_config_dir="${2-}"
      shift
      ;;
    -w | --work-dir)
      work_dir="${2-}"
      shift
      ;;
    -?*) usage ;;
    *) break ;;
  esac
  shift
done

[[ -z "${aws_region}" ]] && usage
[[ -z "${env_type}" ]] && usage
[[ -z "${pn_infra_commitid}" ]] && usage
[[ -z "${bucket_name}" ]] && usage

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
cd ${work_dir}

echo "=== Download pn-infra"
if [[ ! -e pn-infra ]]; then
  git clone https://github.com/pagopa/pn-infra.git
fi

echo "=== Checkout pn-infra commitId=${pn_infra_commitid}"
(cd pn-infra && git fetch && git checkout ${pn_infra_commitid})

if [[ -n "${custom_config_dir}" && -d "${custom_config_dir}/pn-infra" ]]; then
  cp -r ${custom_config_dir}/pn-infra .
fi

template_path=pn-infra/runtime-infra/pn-warning-notifications.yaml
config_path=pn-infra/runtime-infra/pn-warning-notifications-${env_type}-cfg.json
if [[ ! -f "${template_path}" || ! -f "${config_path}" ]]; then
  echo "Warning notification runtime configuration not available for ${env_type}; skipping deployment."
  exit 0
fi

aws_command_base_args=""
if [[ -n "${aws_profile}" ]]; then
  aws_command_base_args="${aws_command_base_args} --profile ${aws_profile}"
fi
if [[ -n "${aws_region}" ]]; then
  aws_command_base_args="${aws_command_base_args} --region ${aws_region}"
fi

template_bucket_base_path="pn-infra/${pn_infra_commitid}"
template_bucket_base_url="https://s3.${aws_region}.amazonaws.com/${bucket_name}/${template_bucket_base_path}/runtime-infra"
lambda_base_path="pn-warning-notifications/${pn_infra_commitid}"
lambda_name=warning-notification-dispatcher
lambda_zip_path="${work_dir}/${lambda_name}.zip"

echo "=== Upload warning notification templates"
aws ${aws_command_base_args} s3 cp pn-infra "s3://${bucket_name}/${template_bucket_base_path}" \
  --recursive --exclude ".git/*" --quiet

echo "=== Package warning notification dispatcher"
rm -f ${lambda_zip_path}
(cd pn-infra/runtime-infra/lambdas/${lambda_name} && zip -qr ${lambda_zip_path} .)
aws ${aws_command_base_args} s3 cp ${lambda_zip_path} \
  "s3://${bucket_name}/${lambda_base_path}/${lambda_name}.zip" --quiet
rm -f ${lambda_zip_path}

infra_outputs_path="${work_dir}/infra_all_outputs_${env_type}.json"
(cd ${script_dir}/commons && ./merge-infra-outputs-core.sh \
  -r ${aws_region} -e ${env_type} -o ${infra_outputs_path})

enhanced_parameters_path="${work_dir}/pn-warning-notifications-${env_type}-cfg-enhanced.json"
jq -s \
  --arg TemplateBucketBaseUrl "${template_bucket_base_url}" \
  --arg ProjectName "${project_name}" \
  --arg EnvironmentType "${env_type}" \
  --arg LambdasBucketName "${bucket_name}" \
  --arg LambdasBasePath "${lambda_base_path}" \
  '.[0] + .[1].Parameters + {
    TemplateBucketBaseUrl: $TemplateBucketBaseUrl,
    ProjectName: $ProjectName,
    EnvironmentType: $EnvironmentType,
    LambdasBucketName: $LambdasBucketName,
    LambdasBasePath: $LambdasBasePath
  } | to_entries | map("\(.key)=\(.value | tostring)")' \
  ${infra_outputs_path} ${config_path} > ${enhanced_parameters_path}

echo "=== Deploy warning notification runtime for ${env_type}"
aws ${aws_command_base_args} cloudformation deploy \
  --stack-name pn-warning-notifications-${env_type} \
  --capabilities CAPABILITY_NAMED_IAM \
  --template-file ${template_path} \
  --tags Microservice=pn-warning-notifications \
  --parameter-overrides file://$(realpath ${enhanced_parameters_path})
