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
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:                ${project_name}"
  echo "AWS Region:                  ${aws_region}"
  echo "Microservice Name:           ${microcvs_name}"
}

parse_params "$@"
dump_params
declare -A components_map

components_map["pn-ec"]="pn-external-channel"
components_map["pn-ss"]="pn-safe-storage"
components_map["pn-statemachinemanager"]="pn-state-machine-manager"
components_map["pn-data-vault"]="pn-data-vault-sep"

if [[ -n ${components_map[${microcvs_name}]+_} ]]; then
    microcvs_name=${components_map[${microcvs_name}]}
fi

account_id=$(aws sts get-caller-identity --query Account --output text)
bucket_env_path=${project_name}-runtime-environment-variables-${aws_region}-${account_id}
file_env_name="runtime-variable.env"
file_env_application_name="application.env"

if aws s3api head-bucket --bucket ${bucket_env_path} 2>/dev/null; then 
  if aws s3api head-object --bucket ${bucket_env_path} --key ${microcvs_name}/${file_env_name} > /dev/null 2>&1; then
      echo "File ${file_env_name} already exists."
  else
    touch ./${file_env_name}
    echo "Generating ${file_env_name}"
    aws s3 cp ${file_env_name} s3://${bucket_env_path}/${microcvs_name}/
    rm ./${file_env_name}
  fi
  if aws s3api head-object --bucket ${bucket_env_path} --key ${microcvs_name}/${file_env_application_name} > /dev/null 2>&1; then
      echo "File ${file_env_application_name} already exists."
  else
    touch ./${file_env_application_name}
    echo "Generating ${file_env_application_name}"
    aws s3 cp ${file_env_application_name} s3://${bucket_env_path}/${microcvs_name}/
    rm ./${file_env_application_name}
  fi
else
  echo "Bucket ${bucket_env_path} does not exists."
fi