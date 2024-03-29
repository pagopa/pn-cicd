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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> <usage-plan-name> <api-gw-type>

    [-h]                      : this help message
    [-v]                      : verbose mode
    [-p <aws-profile>]        : aws cli profile (optional)
    -r <aws-region>           : aws region as eu-south-1
    <usage-plan-name>         : usage plan name 
    <api-gw-type>             : api gateway type to map with Tag PN_APIGW_TYPE. Allowed B2B / IO 

EOF
  exit 1
}

parse_params() {
  # default values of variables set from params
  aws_profile=""
  aws_region=""
  env_type=""
  work_dir=$HOME/tmp/deploy
  pn_infra_commitid=""
  

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
    -i | --infra-commitid) 
      pn_infra_commitid="${2-}"
      shift
      ;;
    -w | --work-dir) 
      work_dir="${2-}"
      shift
      ;;
    
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done
  usageplan_name=${1-}
  apigw_type=${2-}

  args=("$@")

  
  # check required params and arguments
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${usageplan_name-}" ]] && usage
  [[ -z "${apigw_type-}" ]] && usage
  [[ -z "${pn_infra_commitid-}" ]] && usage
  # [[ "${apigw_type-}" -ne "B2B" || "${apigw_type-}" -ne "IO" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Env Name:          ${env_type}"
  echo "AWS region:        ${aws_region}"
  echo "AWS profile:       ${aws_profile}"
  echo "Usage Plan Name    ${usageplan_name}"
  echo "Api Gateway type:  ${apigw_type}"
  echo "Work directory:    ${work_dir}"
  echo "Infra CommitId:    ${pn_infra_commitid}"
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


function getUsagePlan() {
  local PLAN_NAME=$1
  echo $(aws ${aws_command_base_args} apigateway get-usage-plans --query "items[?name=='$PLAN_NAME'].id[]" --output text)
}

function getRestApiIdByTag() {
  local APIGW_TYPE=$1
  echo $(aws ${aws_command_base_args} apigateway get-rest-apis --query "items[?tags.PN_APIGW_TYPE=='$APIGW_TYPE'].id"  --output text)
}

function getCurrentStages() {
  local PLAN_NAME=$1
  echo $(aws ${aws_command_base_args} apigateway get-usage-plans --query "items[?name=='$PLAN_NAME'].apiStages[].apiId" --output text )
}

function createUsagePlan() {
  local PLAN_NAME=$1
  local apigw_type=$2
  local STAGE=unique
  REST_APIS_IDS=$(getRestApiIdByTag $apigw_type)

  if [[ ${PLAN_NAME} == "APP_IO_BE" ]]
  then
    aws ${aws_command_base_args} cloudformation deploy \
        --template-file pn-infra/runtime-infra/fragments/api-gw-usageplans-IO.yaml \
        --stack-name "APP-IO-BE-api-usage-plan"
  elif [[ ${PLAN_NAME} == "STANDARD_B2B" ]]
  then
      aws ${aws_command_base_args} cloudformation deploy \
        --template-file pn-infra/runtime-infra/fragments/api-gw-usageplans-B2B.yaml \
        --stack-name "STANDARD-B2B-api-usage-plan"
  elif [[ ${PLAN_NAME} == "SELCPG" ]]
  then
      if ( [ -f pn-infra/runtime-infra/fragments/api-gw-usageplans-PNPG.yaml ] ) then
        aws ${aws_command_base_args} cloudformation deploy \
          --template-file pn-infra/runtime-infra/fragments/api-gw-usageplans-PNPG.yaml \
          --stack-name "SELCPG-api-usage-plan"
      fi
  fi

  if ( [ $PLAN_NAME != 'SELCPG'] || ( [ $PLAN_NAME='SELCPG'] && [ -f pn-infra/runtime-infra/fragments/api-gw-usageplans-PNPG.yaml ] ) ) then
    USAGE_PLAN_ID=$(getUsagePlan $PLAN_NAME)
    for CURR_ID in $REST_APIS_IDS; do
      sleep 20
      aws ${aws_command_base_args} apigateway update-usage-plan --usage-plan-id $USAGE_PLAN_ID \
          --patch-operations op=add,path="/apiStages",value="$CURR_ID:$STAGE" --no-cli-pager
    done
  fi
  
  
}

function updateUsagePlan() {
  local PLAN_NAME=$1
  local apigw_type=$2
  local STAGE=unique
  local API_STAGES
  local USAGE_PLAN_ID
  USAGE_PLAN_ID=$(getUsagePlan $usageplan_name)
  REST_APIS_IDS=$(getRestApiIdByTag $apigw_type)
  CONF_APIS_IDS=$(getCurrentStages $PLAN_NAME)
  for CURR_ID in $REST_APIS_IDS; do
    if [[ ! " ${CONF_APIS_IDS[*]} " =~ " ${CURR_ID} " ]]; then
      sleep 20
      aws ${aws_command_base_args} apigateway update-usage-plan --usage-plan-id $USAGE_PLAN_ID \
        --patch-operations op=add,path="/apiStages",value="$CURR_ID:$STAGE" --no-cli-pager
    fi
  done
}

cd $work_dir

echo "=== Download pn-infra" 
if ( [ ! -e pn-infra ] ) then 
  git clone https://github.com/pagopa/pn-infra.git
fi

echo ""
echo "=== Checkout pn-infra commitId=${pn_infra_commitid}"
( cd pn-infra && git fetch && git checkout $pn_infra_commitid )
echo " - copy custom config"
if ( [ ! -z "${custom_config_dir}" ] ) then
  cp -r $custom_config_dir/pn-infra .
fi


echo "" 
echo "" 
echo "" 
echo "" 
echo "" 
echo "===                  CREATE OR UPDATE USAGE PLANS                  ===" 
echo "======================================================================"
USAGE_PLAN_ID=$(getUsagePlan $usageplan_name)

if [ "X$USAGE_PLAN_ID" == "X" ]; then
  createUsagePlan $usageplan_name $apigw_type
else
  updateUsagePlan $usageplan_name $apigw_type
fi
