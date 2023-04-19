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
  work_dir=$HOME/tmp/poste_deploy
  custom_config_dir=""
  aws_profile=""
  aws_region=""
  env_type=""
  pn_infra_commitid=""
  bucketName=""
  LambdasBucketName=""


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
    -B | --lambda-bucket-name) 
      LambdasBucketName="${2-}"
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
  [[ -z "${LambdasBucketName-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:      ${project_name}"
  echo "Work directory:    ${work_dir}"
  echo "Custom config dir: ${custom_config_dir}"
  echo "Infra CommitId:    ${pn_infra_commitid}"
  echo "Env Name:          ${env_type}"
  echo "AWS region:        ${aws_region}"
  echo "AWS profile:       ${aws_profile}"
  echo "Bucket Name:       ${bucketName}"
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


echo " - Copy Lambdas zip"
lambdasZip='functions.zip'
lambdasLocalPath='functions'
repo_name='pn-infra'

aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "${repo_name}/commits/${pn_infra_commitid}/${lambdasZip}" \
      "${lambdasZip}"

unzip ${lambdasZip} -d ./${lambdasLocalPath}

bucketBasePath="${repo_name}/${pn_infra_commitid}"
aws ${aws_command_base_args} s3 cp --recursive \
      "${lambdasLocalPath}/" \
      "s3://$bucketName/${bucketBasePath}/"

# delete functions folder
rm -rf ${lambdasLocalPath} 

TERRAFORM_PARAMS_FILEPATH=pn-infra-core/terraform-${env_type}-cfg.json
TmpFilePath=terraform-merge-${env_type}-cfg.json

echo ""
echo ""
echo ""
echo "======================================================================="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo "=== Deploy ONCE FOR $env_type ACCOUNT"
echo "======================================================================="
aws ${aws_command_base_args}  \
    cloudformation deploy \
      --stack-name once-$env_type \
      --capabilities CAPABILITY_NAMED_IAM \
      --template-file pn-infra/runtime-infra/once4account/${env_type}.yaml \
      --parameter-overrides \
        TemplateBucketBaseUrl="$templateBucketHttpsBaseUrl" \
        Version="cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid}"

STORAGE_STACK_FILE=pn-infra/runtime-infra/pn-infra-storage.yaml 

INFRA_INPUT_STACK=once-${env_type} 
if [[ -f "$STORAGE_STACK_FILE" ]]; then
  echo ""
  echo ""
  echo ""
  echo "======================================================================="
  echo "======================================================================="
  echo "===                                                                 ==="
  echo "===                       PN-INFRA-STORAGE DEPLOYMENT               ==="
  echo "===                                                                 ==="
  echo "======================================================================="
  echo "======================================================================="
  echo ""
  echo ""
  echo ""
  echo "=== Prepare parameters for pn-infra-storage.yaml deployment in $env_type ACCOUNT"


  ParamFilePath=pn-infra/runtime-infra/pn-infra-storage-${env_type}-cfg.json
  if ( [ -f "$TERRAFORM_PARAMS_FILEPATH" ] ) then
    echo "Merging outputs of ${TERRAFORM_PARAMS_FILEPATH} into pn-infra-storage"

    echo ""
    echo "= Enanched Terraform parameters file for pn-infra-storage"
    jq -s ".[0] * .[1]" ${ParamFilePath} ${TERRAFORM_PARAMS_FILEPATH} > ${TmpFilePath}
    cat ${TmpFilePath}
    mv ${TmpFilePath} ${ParamFilePath}
  fi

  PreviousOutputFilePath=once4account-${env_type}-out.json
  TemplateFilePath=pn-infra/runtime-infra/pn-infra-storage.yaml
  EnanchedParamFilePath=pn-infra-storage-${env_type}-cfg-enanched.json
  PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\"ProjectName=$project_name\",\"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid}\""

  echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
  echo " - TemplateFilePath: ${TemplateFilePath}"
  echo " - ParamFilePath: ${ParamFilePath}"
  echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
  echo " - PipelineParams: ${PipelineParams}"


  echo ""
  echo "= Read Outputs from previous stack"
  aws ${aws_command_base_args}  \
      cloudformation describe-stacks \
        --stack-name once-$env_type \
        --query "Stacks[0].Outputs" \
        --output json \
        | jq 'map({ (.OutputKey): .OutputValue}) | add' \
        | tee ${PreviousOutputFilePath}

  echo ""
  echo "= Read Parameters file"
  cat ${ParamFilePath} 

  echo ""
  echo "= Enanched parameters file"
  jq -s "{ \"Parameters\": .[0] } * .[1]" ${PreviousOutputFilePath} ${ParamFilePath} \
    | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
    > ${EnanchedParamFilePath}
  echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
  cat ${EnanchedParamFilePath}


  echo ""
  echo "=== Deploy PN-INFRA-STORAGE FOR $env_type ACCOUNT"
  aws ${aws_command_base_args} \
      cloudformation deploy \
        --stack-name pn-infra-storage-$env_type \
        --capabilities CAPABILITY_NAMED_IAM \
        --template-file pn-infra/runtime-infra/pn-infra-storage.yaml \
        --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )
  
  INFRA_INPUT_STACK=pn-infra-storage-${env_type}
fi

echo ""
echo ""
echo ""
echo "======================================================================="
echo "======================================================================="
echo "===                                                                 ==="
echo "===                       PN-INFRA DEPLOYMENT                       ==="
echo "===                                                                 ==="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo ""
echo "=== Prepare parameters for pn-infra.yaml deployment in $env_type ACCOUNT"

## Merge pn_infra_core output into EnanchedParamFilePath=${microcvs_name}-infra-${env_type}-cfg-enanched.json
ParamFilePath=pn-infra/runtime-infra/pn-infra-${env_type}-cfg.json # infra cfg file, it is the target of merge from pn_infra_confinfo
if ( [ -f "$TERRAFORM_PARAMS_FILEPATH" ] ) then
  echo "Merging outputs of ${TERRAFORM_PARAMS_FILEPATH} into pn-infra"

  echo ""
  echo "= Enanched Terraform parameters file for pn-infra"
  jq -s ".[0] * .[1]" ${ParamFilePath} ${TERRAFORM_PARAMS_FILEPATH} > ${TmpFilePath}
  cat ${TmpFilePath}
  mv ${TmpFilePath} ${ParamFilePath}
fi

PreviousOutputFilePath=${INFRA_INPUT_STACK}-out.json
TemplateFilePath=pn-infra/runtime-infra/pn-infra.yaml
EnanchedParamFilePath=pn-infra-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\"ProjectName=$project_name\",\"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid}\""

echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - TemplateFilePath: ${TemplateFilePath}"
echo " - ParamFilePath: ${ParamFilePath}"
echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
echo " - PipelineParams: ${PipelineParams}"


echo ""
echo "= Read Outputs from previous stack"
aws ${aws_command_base_args}  \
    cloudformation describe-stacks \
      --stack-name ${INFRA_INPUT_STACK} \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${PreviousOutputFilePath}

echo ""
echo "= Read Parameters file"
cat ${ParamFilePath} 

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } * .[1]" ${PreviousOutputFilePath} ${ParamFilePath} \
   | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
   > ${EnanchedParamFilePath}
echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}


echo ""
echo "=== Deploy PN-INFRA FOR $env_type ACCOUNT"
aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name pn-infra-$env_type \
      --capabilities CAPABILITY_NAMED_IAM \
      --template-file pn-infra/runtime-infra/pn-infra.yaml \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )
        











echo ""
echo ""
echo ""
echo "======================================================================="
echo "======================================================================="
echo "===                                                                 ==="
echo "===                        PN-IPC DEPLOYMENT                        ==="
echo "===                                                                 ==="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo ""

ParamFilePath=pn-infra/runtime-infra/pn-ipc-${env_type}-cfg.json
OptionalParams=""
if ( [ -f "$TERRAFORM_PARAMS_FILEPATH" ] ) then
  echo "Merging outputs of ${TERRAFORM_PARAMS_FILEPATH} into pn-ipc"

  echo ""
  echo "= Enanched Terraform parameters file for pn-ipc"
  jq -s ".[0] * .[1]" ${ParamFilePath} ${TERRAFORM_PARAMS_FILEPATH} > ${TmpFilePath}
  cat ${TmpFilePath}
  mv ${TmpFilePath} ${ParamFilePath}

  helpdeskAccountId=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-cognito-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"HelpdeskAccountId\") | .OutputValue" \
    ) 

  cognitoUserPoolArn=$( aws ${aws_command_base_args} cloudformation describe-stacks \
        --stack-name "pn-cognito-${env_type}" | jq -r \
        ".Stacks[0].Outputs | .[] | select(.OutputKey==\"CognitoUserPoolArn\") | .OutputValue" \
      ) 

  cognitoWebClientId=$( aws ${aws_command_base_args} cloudformation describe-stacks \
    --stack-name "pn-cognito-${env_type}" | jq -r \
    ".Stacks[0].Outputs | .[] | select(.OutputKey==\"CognitoWebClientId\") | .OutputValue" \
  )

  cognitoUserPoolId=$( aws ${aws_command_base_args} cloudformation describe-stacks \
    --stack-name "pn-cognito-${env_type}" | jq -r \
    ".Stacks[0].Outputs | .[] | select(.OutputKey==\"CognitoUserPoolId\") | .OutputValue" \
  )

  openSearchArn=$( aws ${aws_command_base_args} cloudformation describe-stacks \
    --stack-name "pn-opensearch-${env_type}" | jq -r \
    ".Stacks[0].Outputs | .[] | select(.OutputKey==\"DomainArn\") | .OutputValue" \
  )

  openSearchEndpoint=$( aws ${aws_command_base_args} cloudformation describe-stacks \
    --stack-name "pn-opensearch-${env_type}" | jq -r \
    ".Stacks[0].Outputs | .[] | select(.OutputKey==\"DomainEndpoint\") | .OutputValue" \
  )

  elasticacheEndpoint=$( aws ${aws_command_base_args} cloudformation describe-stacks \
    --stack-name "pn-cache-${env_type}" | jq -r \
    ".Stacks[0].Outputs | .[] | select(.OutputKey==\"RedisEndpoint\") | .OutputValue" \
  )

  elasticacheSecurityGroupId=$( aws ${aws_command_base_args} cloudformation describe-stacks \
    --stack-name "pn-cache-${env_type}" | jq -r \
    ".Stacks[0].Outputs | .[] | select(.OutputKey==\"AllowedSecurityGroupId\") | .OutputValue" \
  )

  OptionalParams=",\"CognitoUserPoolArn=$cognitoUserPoolArn\",\"CognitoClientId=$cognitoWebClientId\",\"HelpdeskAccountId=$helpdeskAccountId\",\"OpenSearchArn=$openSearchArn\",\"OpenSearchEndpoint=$openSearchEndpoint\",\"ElasticacheEndpoint=$elasticacheEndpoint\",\"ElasticacheSecurityGroup=$elasticacheSecurityGroupId\""

fi

echo ""
echo "=== Prepare parameters for pn-ipc.yaml deployment in $env_type ACCOUNT"
PreviousOutputFilePath=pn-infra-${env_type}-out.json
TemplateFilePath=pn-infra/runtime-infra/pn-ipc.yaml
EnanchedParamFilePath=pn-ipc-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\"ProjectName=$project_name\",\"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid}\",\"LambdasBucketName=${bucketName}\",\"LambdasBasePath=$bucketBasePath\",\"EnvironmentType=$env_type\"${OptionalParams}"


echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - TemplateFilePath: ${TemplateFilePath}"
echo " - ParamFilePath: ${ParamFilePath}"
echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
echo " - PipelineParams: ${PipelineParams}"


echo ""
echo "= Read Outputs from previous stack"
aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-infra-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${PreviousOutputFilePath}

echo ""
echo "= Read Parameters file"
cat ${ParamFilePath} 

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } * .[1]" ${PreviousOutputFilePath} ${ParamFilePath} \
   | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
   > ${EnanchedParamFilePath}
echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}


echo ""
echo "=== Deploy PN-IPC FOR $env_type ACCOUNT"
aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name pn-ipc-$env_type \
      --s3-bucket $bucketName \
      --capabilities CAPABILITY_NAMED_IAM \
      --template-file pn-infra/runtime-infra/pn-ipc.yaml \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )


echo ""
echo "=== Deploy PN-EVENT-BRIDGE FOR $env_type ACCOUNT"

ParamFilePath=pn-infra/runtime-infra/pn-event-bridge-${env_type}-cfg.json
echo ""
echo "= Read Outputs from previous stack"
aws ${aws_command_base_args}  \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${PreviousOutputFilePath}

echo ""
echo "= Read Parameters file"
cat ${ParamFilePath} 

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } * .[1]" ${PreviousOutputFilePath} ${ParamFilePath} \
  | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
  > ${EnanchedParamFilePath}
echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}

aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name pn-event-bridge-$env_type \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
      --template-file pn-infra/runtime-infra/pn-event-bridge.yaml  \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )


echo ""
echo "=== Deploy PN-Monitoring FOR $env_type ACCOUNT"
MONITORING_STACK_FILE=pn-infra/runtime-infra/pn-monitoring.yaml 

if [[ -f "$MONITORING_STACK_FILE" ]]; then
    echo "$MONITORING_STACK_FILE exists, updating monitoring stack"

    echo ""
    echo "= Read Outputs from previous stack"
    aws ${aws_command_base_args}  \
        cloudformation describe-stacks \
          --stack-name pn-ipc-$env_type \
          --query "Stacks[0].Outputs" \
          --output json \
          | jq 'map({ (.OutputKey): .OutputValue}) | add' \
          | tee ${PreviousOutputFilePath}

    echo ""
    echo "= Read Parameters file"
    cat ${ParamFilePath} 

    echo ""
    echo "= Enanched parameters file"
    jq -s "{ \"Parameters\": .[0] } * .[1]" ${PreviousOutputFilePath} ${ParamFilePath} \
      | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
      > ${EnanchedParamFilePath}
    echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
    cat ${EnanchedParamFilePath}

    aws ${aws_command_base_args} \
        cloudformation deploy \
          --stack-name pn-monitoring-$env_type \
          --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
          --template-file ${MONITORING_STACK_FILE} \
          --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )

else
  echo "Monitoring file doesn't exist, stack update skipped"
fi