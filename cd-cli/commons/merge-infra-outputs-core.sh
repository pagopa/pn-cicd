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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-p <aws-profile>] -r <aws-region> -e <env-type> -o <output-file>
    [-h]                      : this help message
    [-p <aws-profile>]        : aws cli profile (optional)
    -r <aws-region>           : aws region as eu-south-1
    -e <env-type>             : aws region as eu-south-1
    -o <output-file>          : output file to store the merged outputs

EOF
  exit 1
}

parse_params() {
  # default values of variables set from params
  aws_region=""
  aws_profile=""
  env_type=""
  output_file=""

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -r | --aws-region)
      aws_region="${2-}"
      shift
      ;;
    -p | --aws-profile)
      aws_profile="${2-}"
      shift
      ;;
    -e | --env-type)
      env_type="${2-}"
      shift
      ;;    
    -o | --output-file)
      output_file="${2-}"
      shift
      ;;    
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

   # check required params and arguments
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${env_type-}" ]] && usage
  [[ -z "${output_file-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "AWS Region:                  ${aws_region}"
  echo "Env Type:                    ${env_type}"
  echo "Output File:                 ${output_file}"
}

parse_params "$@"
dump_params

echo ""
echo "=== Base AWS command parameters"
aws_command_base_args=""
if ( [ ! -z "${aws_profile}" ] ) then
  aws_command_base_args="${aws_command_base_args} --profile $aws_profile"
fi
if ( [ ! -z "${aws_region}" ] ) then
  aws_command_base_args="${aws_command_base_args} --region  $aws_region"
fi
echo ${aws_command_base_args}

# Infra Storage output stack
InfraStorageOutputFilePath="infra-storage-output.json"
echo ""
echo "= Read Outputs from pn-infra-storage stack"
aws ${aws_command_base_args}  \
    cloudformation describe-stacks \
      --stack-name pn-infra-storage-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${InfraStorageOutputFilePath}

# Infra output stack
InfraOutputFilePath="infra-output.json"
echo ""
echo "= Read Outputs from pn-infra stack"
aws ${aws_command_base_args}  \
    cloudformation describe-stacks \
      --stack-name pn-infra-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${InfraOutputFilePath}

# IPC output stack
IpcOutputFilePath="ipc-output.json"
echo ""
echo "= Read Outputs from pn-ipc stack"
aws ${aws_command_base_args}  \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${IpcOutputFilePath}

# merge all outputs
echo ""
echo "= Merge all outputs"
jq -s '.[0] * .[1] * .[2]' ${InfraStorageOutputFilePath} ${InfraOutputFilePath} ${IpcOutputFilePath} | tee ${output_file}

# cleanup
rm ${InfraStorageOutputFilePath}
rm ${InfraOutputFilePath}
rm ${IpcOutputFilePath}