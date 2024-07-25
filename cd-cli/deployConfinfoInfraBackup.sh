#!/usr/bin/env bash

#REMOVE THIS FILE WITH MERGE PN-11642
set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)


usage() {
      cat <<EOF
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] -n <microcvs-name> [-p <aws-profile>] -r  <aws-region> -e <env-type> -i <pn-infra-github-commitid> -m <pn-microsvc-github-commitid> [-c <custom_config_dir>]

    [-h]                             : this help message
    [-v]                             : verbose mode
    [-p <aws-profile>]               : aws cli profile (optional)
    -r <aws-region>                  : aws region as eu-south-1
    -e <env-type>                    : one of dev / uat / svil / coll / cert / prod
    -i <infra-github-commitid>       : commitId for github repository pagopa/pn-infra
    -m <pn-microsvc-github-commitid> : commitId for github repository del microservizio
    [-c <custom_config_dir>]         : where tor read additional env-type configurations
    -b <artifactBucketName>          : bucket name to use as temporary artifacts storage
    -n <microcvs-name>               : nome del microservizio

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
  pn_microsvc_commitid=""
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
    -m | --ms-commitid)
      pn_microsvc_commitid="${2-}"
      shift
      ;;
    -n | --ms-name)
      microcvs_name="${2-}"
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
  [[ -z "${pn_microsvc_commitid-}" ]] && usage
  [[ -z "${bucketName-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${microcvs_name-}" ]] && usage
  [[ -z "${LambdasBucketName-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:        ${project_name}"
  echo "Work directory:      ${work_dir}"
  echo "Custom config dir:   ${custom_config_dir}"
  echo "Infra CommitId:      ${pn_infra_commitid}"
  echo "Microsvc CommitId:   ${pn_microsvc_commitid}"
  echo "Microsvc Name:       ${microcvs_name}"
  echo "Env Name:            ${env_type}"
  echo "AWS region:          ${aws_region}"
  echo "AWS profile:         ${aws_profile}"
  echo "Bucket Name:         ${bucketName}"
  echo "Lambdas Bucket Name: ${LambdasBucketName}"
}


# START SCRIPT

parse_params "$@"
dump_params

cwdir=$(pwd)
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

echo " - copy pn-infra-confinfo config"
if ( [ -d "${custom_config_dir}/pn-infra-confinfo" ] ) then
  cp -r $custom_config_dir/pn-infra-confinfo .
fi

echo "=== Download microservizio ${microcvs_name}"
if ( [ ! -e ${microcvs_name} ] ) then
  git clone "https://github.com/pagopa/${microcvs_name}.git"
fi

echo ""
echo "=== Checkout ${microcvs_name} commitId=${pn_microsvc_commitid}"
( cd ${microcvs_name} && git fetch && git checkout $pn_microsvc_commitid )
echo " - copy custom config"
if ( [ ! -z "${custom_config_dir}" ] ) then
  cp -r $custom_config_dir/${microcvs_name} .
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


TERRAFORM_PARAMS_FILEPATH=pn-infra-confinfo/terraform-${env_type}-cfg.json
TmpFilePath=terraform-merge-${env_type}-cfg.json

PnCoreAwsAccountId=""
if ( [ -f "$TERRAFORM_PARAMS_FILEPATH" ] ) then
  PnCoreAwsAccountId=$(cat $TERRAFORM_PARAMS_FILEPATH | jq -r '.Parameters.PnCoreAwsAccountId')
  echo "PnCoreAwsAccountId  ${PnCoreAwsAccountId}"
fi

echo "Load all outputs in a single file for next stack deployments"
INFRA_ALL_OUTPUTS_FILE=infra_all_outputs-${env_type}.json
(cd ${cwdir}/commons && ./merge-infra-outputs-confinfo.sh -r ${aws_region} -e ${env_type} -o ${work_dir}/${INFRA_ALL_OUTPUTS_FILE} )

echo "## start merge all ##"
cat $INFRA_ALL_OUTPUTS_FILE
echo "## end merge all ##"

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
      --template-file ${microcvs_name}/scripts/aws/cfn/once4account.yaml \
      --parameter-overrides \
        TemplateBucketBaseUrl="$templateBucketHttpsBaseUrl" \
        PnCoreAwsAccountId="$PnCoreAwsAccountId" \
        Version="cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid}"


STORAGE_STACK_FILE=${microcvs_name}/scripts/aws/cfn/infra-storage.yaml

INFRA_INPUT_STACK=once-${env_type}
if [[ -f "$STORAGE_STACK_FILE" ]]; then
  echo ""
  echo ""
  echo ""
  echo "======================================================================="
  echo "======================================================================="
  echo "===                                                                 ==="
  echo "===                       INFRA-STORAGE DEPLOYMENT                  ==="
  echo "===                                                                 ==="
  echo "======================================================================="
  echo "======================================================================="
  echo ""
  echo ""
  echo ""
  echo "=== Prepare parameters for infra-storage.yaml deployment in $env_type ACCOUNT"

  ## Merge pn_infra_confinfo output into EnanchedParamFilePath=${microcvs_name}-infra-${env_type}-cfg-enanched.json
  ParamFilePath=${microcvs_name}/scripts/aws/cfn/infra-storage-${env_type}-cfg.json

  if ( [ -f "$TERRAFORM_PARAMS_FILEPATH" ] ) then
    echo "Merging outputs of ${TERRAFORM_PARAMS_FILEPATH}"

    echo ""
    echo "= Enanched Terraform parameters file for infra-storage"
    jq -s ".[0] * .[1]" ${ParamFilePath} ${TERRAFORM_PARAMS_FILEPATH} > ${TmpFilePath}
    cat ${TmpFilePath}
    mv ${TmpFilePath} ${ParamFilePath}
  fi

  PreviousOutputFilePath=once4account-${env_type}-out.json
  TemplateFilePath=${microcvs_name}/scripts/aws/cfn/infra-storage.yaml
  EnanchedParamFilePath=infra-storage-${env_type}-cfg-enanched.json
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
  echo "=== Deploy INFRA-STORAGE FOR $env_type ACCOUNT"
  aws ${aws_command_base_args} \
      cloudformation deploy \
        --stack-name infra-storage-$env_type \
        --capabilities CAPABILITY_NAMED_IAM \
        --tags Microservice=pn-infra-logs \
        --template-file ${microcvs_name}/scripts/aws/cfn/infra-storage.yaml \
        --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )

  INFRA_INPUT_STACK=infra-storage-${env_type}
fi

## Merge pn_infra_confinfo output into EnanchedParamFilePath=${microcvs_name}-infra-${env_type}-cfg-enanched.json
ParamFilePath=${microcvs_name}/scripts/aws/cfn/infra-${env_type}-cfg.json # infra cfg file, it is the target of merge from pn_infra_confinfo

if ( [ -f "$TERRAFORM_PARAMS_FILEPATH" ] ) then
  echo "Merging outputs of ${TERRAFORM_PARAMS_FILEPATH}"

  echo ""
  echo "= Enanched Terraform parameters file"
  jq -s ".[0] * .[1]" ${ParamFilePath} ${TERRAFORM_PARAMS_FILEPATH} > ${TmpFilePath}
  cat ${TmpFilePath}
  mv ${TmpFilePath} ${ParamFilePath}
fi

echo ""
echo ""
echo ""
echo "======================================================================="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo "=== Deploy INFRA FOR $env_type ACCOUNT"
echo "======================================================================="

echo ""
echo "= Read Outputs from previous stack"

PreviousOutputFilePath=${INFRA_INPUT_STACK}-out.json
TemplateFilePath=${microcvs_name}/scripts/aws/cfn/infra.yml
EnanchedParamFilePath=${microcvs_name}-infra-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\"ProjectName=$project_name\",\"CdBucketName=${bucketName}\",\"BucketBasePath=$bucketBasePath\",\"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid}\""

aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name ${INFRA_INPUT_STACK} \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${PreviousOutputFilePath}

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } * .[1]" \
   ${PreviousOutputFilePath} ${ParamFilePath} \
   | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
   > ${EnanchedParamFilePath}
echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}


aws ${aws_command_base_args}  \
    cloudformation deploy \
      --stack-name infra-$env_type \
      --capabilities CAPABILITY_NAMED_IAM \
      --tags "Microservice=pn-infra-networking" \
      --template-file ${microcvs_name}/scripts/aws/cfn/infra.yml \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )


echo ""
echo "=== Deploy PN-Buckup FOR $env_type ACCOUNT"
BACKUP_STACK_FILE=pn-infra/runtime-infra/pn-backup_confinfo_dynamotable.yaml

if [[ -f "$BACKUP_STACK_FILE" ]]; then
    echo "$BACKUP_STACK_FILE exists, updating backup stack"

    echo ""
    echo "= Read Parameters file"
    cat ${ParamFilePath}

    echo ""
    echo "= Enanched parameters file"
    jq -s "{ \"Parameters\": .[0] } * .[1]" ${INFRA_ALL_OUTPUTS_FILE} ${ParamFilePath} \
      | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
      > ${EnanchedParamFilePath}
    echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
    cat ${EnanchedParamFilePath}

    aws ${aws_command_base_args} \
        cloudformation deploy \
          --stack-name pn-dynamodb-backup-$env_type \
          --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
          --tags Microservice=pn-infra-backup \
          --template-file ${BACKUP_STACK_FILE} \
          --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )

else
  echo "Backup file doesn't exist, stack update skipped"
fi

echo ""
echo "=== Deploy PN-Data-Monitoring FOR $env_type ACCOUNT"
DATA_MONITORING_STACK_FILE=pn-infra/runtime-infra/pn-data-monitoring.yaml

if [[ -f "$DATA_MONITORING_STACK_FILE" ]]; then
    echo "$DATA_MONITORING_STACK_FILE exists, updating pn-data-monitoring stack"

    
    echo "= Read Parameters file"
    cat ${ParamFilePath}

    echo ""
    echo "= Enanched parameters file"
    jq -s "{ \"Parameters\": .[0] } * .[1]" ${INFRA_ALL_OUTPUTS_FILE} ${ParamFilePath} \
      | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
      > ${EnanchedParamFilePath}
    echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
    cat ${EnanchedParamFilePath}

    aws ${aws_command_base_args} \
        cloudformation deploy \
          --stack-name pn-data-monitoring-$env_type \
          --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
          --tags Microservice=pn-infra-data-monitoring \
          --template-file ${DATA_MONITORING_STACK_FILE} \
          --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )

else
  echo "${DATA_MONITORING_STACK_FILE} file doesn't exist, stack update skipped"
fi

echo ""
echo "=== Deploy PN-Cost-Saving FOR $env_type ACCOUNT"
COST_SAVING_STACK_FILE=pn-infra/runtime-infra/pn-cost-saving.yaml

if [[ -f "$COST_SAVING_STACK_FILE" ]]; then
    echo "$COST_SAVING_STACK_FILE exists, updating pn-cost-saving stack"

    echo ""
    echo "= Read Parameters file"
    cat ${ParamFilePath} 

    echo ""
    echo "= Enanched parameters file"
    jq -s "{ \"Parameters\": .[0] } * .[1]" ${INFRA_ALL_OUTPUTS_FILE} ${ParamFilePath} \
      | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
      > ${EnanchedParamFilePath}
    echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
    cat ${EnanchedParamFilePath}

    aws ${aws_command_base_args} \
        cloudformation deploy \
          --stack-name pn-cost-saving-$env_type \
          --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
          --tags Microservice=pn-infra-cost-saving \
          --template-file ${COST_SAVING_STACK_FILE} \
          --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )

else
  echo "${COST_SAVING_STACK_FILE} file doesn't exist, stack update skipped"
fi

MONITORING_STACK_FILE=${microcvs_name}/scripts/aws/cfn/infra-monitoring.yaml
if [[ -f "$MONITORING_STACK_FILE" ]]; then
    echo "$MONITORING_STACK_FILE exists, updating monitoring stack"

    echo ""
    echo "= Read Parameters file"
    cat ${ParamFilePath}

    echo ""
    echo "= Enanched parameters file"
    jq -s "{ \"Parameters\": .[0] } * .[1]" ${INFRA_ALL_OUTPUTS_FILE} ${ParamFilePath} \
      | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
      > ${EnanchedParamFilePath}
    echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
    cat ${EnanchedParamFilePath}

    aws ${aws_command_base_args} \
        cloudformation deploy \
          --stack-name pn-infra-monitoring-$env_type \
          --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
          --tags Microservice=pn-infra-monitoring \
          --template-file ${MONITORING_STACK_FILE} \
          --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )

else
  echo "Backup file doesn't exist, stack update skipped"
fi