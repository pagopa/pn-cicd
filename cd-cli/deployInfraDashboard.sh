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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> -i <github-commitid> [-c <custom_config_dir>] -b <artifactBucketName>

    [-h]                      : this help message
    [-v]                      : verbose mode
    [-p <aws-profile>]        : aws cli profile (optional)
    -r <aws-region>           : aws region as eu-south-1
    -e <env-type>             : one of dev / uat / svil / coll / cert / prod
    -i <github-commitid>      : commitId for github repository pagopa/pn-infra
    [-c <custom_config_dir>]  : where tor read additional env-type configurations
    -b <artifactBucketName>   : bucket name to use as temporary artifacts storage
    
EOF
  exit 1
}

parse_params() {
  # default values of variables set from params
  project_name=pn
  work_dir=$HOME/tmp/deploy
  custom_config_dir=""
  aws_profile=""
  aws_region=""
  env_type=""
  pn_infra_commitid=""
  bucketName=""

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
    -e | --env-name) 
      env_type="${2-}"
      shift
      ;;
    -i | --infra-commitid) 
      pn_infra_commitid="${2-}"
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
    -b | --bucket-name) 
      bucketName="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${env_type-}" ]] && usage 
  [[ -z "${pn_infra_commitid-}" ]] && usage
  [[ -z "${bucketName-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:       ${project_name}"
  echo "Work directory:     ${work_dir}"
  echo "Custom config dir:  ${custom_config_dir}"
  echo "Infra CommitId:     ${pn_infra_commitid}"
  echo "Env Name:           ${env_type}"
  echo "AWS region:         ${aws_region}"
  echo "AWS profile:        ${aws_profile}"
  echo "Bucket Name:        ${bucketName}"
}


# START SCRIPT

parse_params "$@"
dump_params


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

echo " - copy pn-infra-core config"
if ( [ -d "${custom_config_dir}/pn-infra-core" ] ) then
  cp -r $custom_config_dir/pn-infra-core .
fi


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


templateBucketS3BaseUrl="s3://${bucketName}/pn-infra/${pn_infra_commitid}"
templateBucketHttpsBaseUrl="https://s3.${aws_region}.amazonaws.com/${bucketName}/pn-infra/${pn_infra_commitid}/runtime-infra"
echo " - Bucket Name: ${bucketName}"
echo " - Bucket Template S3 Url: ${templateBucketS3BaseUrl}"
echo " - Bucket Template HTTPS Url: ${templateBucketHttpsBaseUrl}"


echo ""
echo "=== Upload files to bucket"
aws ${aws_command_base_args} \
    s3 cp pn-infra $templateBucketS3BaseUrl \
      --recursive --exclude ".git/*"



echo ""
echo ""
echo ""
echo "###    READ EXPORTS FROM PN-EVENT-BRIDGE AND PN-LOGS-EXPORT     ###"
echo "###################################################################"

PreviousOutputFilePath=previous-output-${env_type}.json
PreviousLogsOutputFilePath=previous-logs-output-${env_type}.json
PreviousMonitoringOutputFilePath=previous-monitoring-output-${env_type}.json
TemplateFilePath="pn-infra/runtime-infra/pn-infra-dashboard.yaml"
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\"ProjectName=$project_name\",\"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid}\""
EnanchedParamFilePath="pn-infra-dashboard-${env_type}-enhanced.json"

aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-event-bridge-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${PreviousOutputFilePath}

aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-logs-export-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${PreviousLogsOutputFilePath}

# Monitoring stack #
MONITORING_STACK_FILE=pn-infra/runtime-infra/pn-monitoring.yaml 
if [[ -f "$MONITORING_STACK_FILE" ]]; then

  aws ${aws_command_base_args} \
      cloudformation describe-stacks \
        --stack-name pn-monitoring-$env_type \
        --query "Stacks[0].Outputs" \
        --output json \
        | jq 'map({ (.OutputKey): .OutputValue}) | add' \
        | tee ${PreviousMonitoringOutputFilePath}
else
  echo '{ }' | tee ${PreviousMonitoringOutputFilePath}
fi

# Monitoring stack #
AdditionalParams=""
TERRAFORM_PARAMS_FILEPATH=pn-infra-core/terraform-${env_type}-cfg.json
if ( [ -f "$TERRAFORM_PARAMS_FILEPATH" ] ) then
  echo ""
  OpenSearchClusterName=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-opensearch-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"ClusterName\") | .OutputValue" \
    )

  RedisCurrentConnectionsAlarmArn=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-cache-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"RedisCurrentConnectionsAlarmArn\") | .OutputValue" \
    )

  RedisMemoryUtilizationAlarm=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-cache-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"RedisMemoryUtilizationAlarm\") | .OutputValue" \
    )

  RedisCPUUtilizationAlarm=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-cache-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"RedisCPUUtilizationAlarm\") | .OutputValue" \
    )

  RedisEngineCPUAlarm=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-cache-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"RedisEngineCPUAlarm\") | .OutputValue" \
    )

  AdditionalParams=", \"OpenSearchClusterName=${OpenSearchClusterName}\""
  AdditionalParams="${AdditionalParams}, \"RedisCurrentConnectionsAlarmArn=${RedisCurrentConnectionsAlarmArn}\""
  AdditionalParams="${AdditionalParams}, \"RedisMemoryUtilizationAlarm=${RedisMemoryUtilizationAlarm}\""
  AdditionalParams="${AdditionalParams}, \"RedisCPUUtilizationAlarm=${RedisCPUUtilizationAlarm}\""
  AdditionalParams="${AdditionalParams}, \"RedisEngineCPUAlarm=${RedisEngineCPUAlarm}\""
fi

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } * { \"Parameters\": .[1] } * { \"Parameters\": .[2] }" \
   ${PreviousOutputFilePath} ${PreviousLogsOutputFilePath} ${PreviousMonitoringOutputFilePath} \
   | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
   > ${EnanchedParamFilePath}
echo "${PipelineParams} ${AdditionalParams}]" >> ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}

aws ${aws_command_base_args} cloudformation deploy \
      --stack-name pn-infra-dashboard-${env_type} \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
      --template-file "$TemplateFilePath" \
      --tags Microservice=pn-infra-monitoring \
      --parameter-overrides file://$(realpath $EnanchedParamFilePath)
