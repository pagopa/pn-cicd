#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)


usage() {
      cat <<EOF
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] -p <project-name> -r <aws-region> -m <microcvs-name>
    [-h]                      : this help message
    -p <project-name>         : project name
    -r <aws-region>           : aws region
    -m <microcvs-name>        : microcvs name

EOF
  exit 1
}

parse_params() {
  # default values of variables set from params
  project_name="pn"
  aws_region=""
  microcvs_name=""
  env_type=""

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -p | --project-name)
      project_name="${2-}"
      shift
      ;;
    -r | --aws-region)
      aws_region="${2-}"
      shift
      ;;
    -m | --microcvs-name)
      microcvs_name="${2-}"
      shift
      ;;
    -e | --env-type)
      env_type="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

   # check required params and arguments
  [[ -z "${project_name-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${microcvs_name-}" ]] && usage
  [[ -z "${env_type-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:                ${project_name}"
  echo "AWS Region:                  ${aws_region}"
  echo "Microservice Name:           ${microcvs_name}"
  echo "Env Type:                    ${env_type}"

}


parse_params "$@"
dump_params
declare -A components_map

components_map["pn-ec"]="pn-external-channel"
components_map["pn-ss"]="pn-safe-storage"
components_map["pn-statemachinemanager"]="pn-state-machine-manager"
components_map["pn-data-vault"]="pn-data-vault-sep"

echo ""
echo "=== Base AWS command parameters"
aws_command_base_args=""
if ( [ ! -z "${aws_region}" ] ) then
  aws_command_base_args="${aws_command_base_args} --region  $aws_region"
fi
echo ${aws_command_base_args}

if [[ -n ${components_map[${microcvs_name}]+_} ]]; then
    runtime_microcvs_name=${components_map[${microcvs_name}]}
else 
    runtime_microcvs_name=${microcvs_name}
fi

file_env_application_path=${microcvs_name}/scripts/aws/cfn/application-${env_type}.env
file_env_application_name="application.env"
account_id=$(aws sts get-caller-identity --query Account --output text)
bucket_env_path=${project_name}-runtime-environment-variables-${aws_region}-${account_id}

if [[ -f "${file_env_application_path}" ]]; then
  aws ${aws_command_base_args} \
      s3 cp ${file_env_application_path} s3://${bucket_env_path}/${runtime_microcvs_name}/${file_env_application_name}
  echo "environment variable updated for $microcvs_name microservice deployment in $env_type ACCOUNT"
  app_env_file_sha=$(sha256sum ${file_env_application_path} | awk '{print $1}')
  echo ""
  echo ""
else
  echo ""
  echo "${file_env_application_path} file doesn't exist, updating empty application.env..."
  touch ./${file_env_application_name}
  aws ${aws_command_base_args} \
      s3 cp ${file_env_application_name} s3://${bucket_env_path}/${runtime_microcvs_name}/${file_env_application_name}
  rm ./${file_env_application_name}
  echo "Empty application.env updated"
  echo ""
  echo ""
fi