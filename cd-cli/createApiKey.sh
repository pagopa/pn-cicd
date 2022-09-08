#!/usr/bin/env bash 

set -x 
set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)


usage() {
      cat <<EOF
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> <usage-plan-name> <api-key-name> <api-key-description> <cx-id> [<groups_id>]

    [-h]                      : this help message
    [-v]                      : verbose mode
    [-p <aws-profile>]        : aws cli profile (optional)
    -r <aws-region>           : aws region as eu-south-1
    <usage-plan-name>         : usage plan name 
    <api-key-name>            : api key name
    <api-key-description>     : api key description
    <cx-id>                   : customer Self Care identifier
    [<groups_id>]             : customer Self Care groups identifiers

EOF
  exit 1
}

parse_params() {
  # default values of variables set from params
  aws_profile=""
  aws_region=""
  env_type=""

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -p | --profile)
      aws_profile="${2-}"
      shift
      ;;
    -r | --region)
      aws_region="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done
  usageplan_name=${1-}
  apikey_name=${2-}
  apikey_desc=${3-}
  cx_id=${4-}
  cx_groups=${5-}

  args=("$@")

    # check required params and arguments
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${apikey_name-}" ]] && usage
  [[ -z "${apikey_desc-}" ]] && usage
  [[ -z "${usageplan_name-}" ]] && usage
  [[ -z "${cx_id-}" ]] && usage
  # [[ "${apigw_type-}" -ne "B2B" || "${apigw_type-}" -ne "IO" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Env Name:                 ${env_type}"
  echo "AWS region:               ${aws_region}"
  echo "AWS profile:              ${aws_profile}"
  echo "Usage Plan Name           ${usageplan_name}"
  echo "Api Key Name:             ${apikey_name}"
  echo "Api Key cx_id:            ${cx_id}"
  echo "Api Key cx_groups:        ${cx_groups}"
}

function checkApiKeyDuplicate() {
  local APIKEY_NAME=$1
  echo $(aws ${aws_command_base_args} apigateway get-api-keys --name-query $APIKEY_NAME  --query "items[].id" --output text)
}

function getUsagePlan() {
  local PLAN_NAME=$1
  echo $(aws ${aws_command_base_args} apigateway get-usage-plans --query "items[?name=='$PLAN_NAME'].id[]" --output text)
}

# START SCRIPT

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

if [ -n "$(checkApiKeyDuplicate $apikey_name)" ]; then
  echo "Key with name ${apikey_name} is already present"
  exit 0
fi

USAGEPLAN_ID=$(getUsagePlan $usageplan_name)

if [ -z $USAGEPLAN_ID ]; then
  echo "usage plan $usageplan_name not found"
  exit 1
fi

KEY_ID_VALUE=$(aws ${aws_command_base_args} apigateway create-api-key \
 --name ${apikey_name} \
 --description "${apikey_desc}" \
 --enabled \
 --tags cx_id=${cx_id},cx_groups=${cx_groups} \
 --no-paginate \
 --query "[id,value]" \
 --output text
)
KEY_ID_VALUE_ARR=($KEY_ID_VALUE)
KEY_ID=${KEY_ID_VALUE_ARR[0]}
KEY_VAL=${KEY_ID_VALUE_ARR[1]}

aws ${aws_command_base_args} apigateway create-usage-plan-key --usage-plan-id $USAGEPLAN_ID --key-id $KEY_ID --key-type "API_KEY"

echo "Key $KEY_ID with value $KEY_VAL added to $usageplan_name usage plan"