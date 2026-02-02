#!/usr/bin/env bash
    
set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  _exit_code=$?
  trap - SIGINT SIGTERM ERR EXIT
  
  if [[ ${_exit_code} -ne 0 && "${_DEPLOY_SUCCESS:-false}" != "true" ]]; then
    echo "=== Detected failure, tracking release event..."
    bash "${script_dir}/commons/track-release.sh" \
        -i "${_RELEASE_EVENT_ID:-}" \
        -n "${repo_name:-}" \
        -e "${env_type:-}" \
        -p "FAILURE" \
        -V "${pn_microsvc_commitId:-}" \
        -f "${pn_infra_commitid:-}" \
        -c "${_pn_config_commit:-}" \
        -d "${cd_scripts_commitId:-}" \
        -b "${bucketName:-}" \
        -m "Exit code: ${_exit_code}" \
        -r "${release_label:-}" \
        -R "${aws_region:-}" || true
  fi
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

die() {
  local msg=$1
  local code=${2-1}
  echo >&2 "$msg"
  exit "$code"
}

usage() {
      cat <<EOF
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -n <repo-name> -r <aws-region> -e <env-type> -i <github-commitid> -a <pn-microsvc-github-commitId> [-c <custom_config_dir>] -b <artifactBucketName> -B <lambdaArtifactBucketName> [-w <work_dir>] [-R <release-label>]
    
    
    [-h]                           : this help message
    [-v]                           : verbose mode
    [-p <aws-profile>]             : aws cli profile (optional)
    -r <aws-region>                : aws region as eu-south-1
    -e <env-type>                  : one of dev / uat / svil / coll / cert / prod
    -i <infra-github-commitid>     : commitId for github repository pagopa/pn-infra
    -a <microsvc-github-commitid> : commitId for github repository microsvc
    [-c <custom_config_dir>]       : where tor read additional env-type configurations
    -b <artifactBucketName>        : bucket name to use as temporary artifacts storage
    -B <lambdaArtifactBucketName>  : bucket name where lambda artifact are memorized
    -n <repo-name>                 : nome del repository del servizio
    -w <work-dir>                  : working directory used by the script to download artifacts (default $HOME/tmp/deploy)
    [-R <release-label>]           : release label for tracking (e.g., GA26Q1.A)

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
  repo_name=""
  pn_infra_commitid=""
  pn_microsvc_commitId=""
  bucketName=""
  LambdasBucketName=""
  release_label=""

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
    -a | --microsvc-commitid) 
      pn_microsvc_commitId="${2-}"
      shift
      ;;
    -c | --custom-config-dir) 
      custom_config_dir="${2-}"
      shift
      ;;
    -n | --repo-name) 
      repo_name="${2-}"
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
    -R | --release-label)
      release_label="${2-}"
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
  [[ -z "${pn_microsvc_commitId-}" ]] && usage
  [[ -z "${repo_name-}" ]] && usage
  [[ -z "${bucketName-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${LambdasBucketName-}" ]] && usage
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
  echo "Microsvc CommitId: ${pn_microsvc_commitId}"
  echo "Repo Name: ${repo_name}"
  echo "Env Name:           ${env_type}"
  echo "AWS region:         ${aws_region}"
  echo "AWS profile:        ${aws_profile}"
  echo "Bucket Name:        ${bucketName}"
  echo "Lambda Bucket Name: ${LambdasBucketName}"
  echo "Release Label:      ${release_label}"
}


# START SCRIPT

parse_params "$@"
dump_params

# Release Tracking: Initial ID generation
_RELEASE_EVENT_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]' || echo "id-$(date +%s)")
_DEPLOY_SUCCESS=false

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



echo "=== Download ${repo_name}" 
if ( [ ! -e ${repo_name} ] ) then 
  git clone https://github.com/pagopa/${repo_name}.git
fi

echo ""
echo "=== Checkout ${repo_name} commitId=${pn_microsvc_commitId}"
( cd ${repo_name} && git fetch && git checkout $pn_microsvc_commitId )

echo " - copy custom config"
if ( [ ! -z "${custom_config_dir}" ] ) then
  cp -r $custom_config_dir/${repo_name} .
fi

# pn_configuration commit - left empty for now (TODO: add export in downloadCustomConfig.sh)
_pn_config_commit=""

# Release Tracking: STARTED
bash "${script_dir}/commons/track-release.sh" \
    -i "${_RELEASE_EVENT_ID}" \
    -n "${repo_name}" \
    -e "${env_type}" \
    -p "STARTED" \
    -V "${pn_microsvc_commitId}" \
    -f "${pn_infra_commitid}" \
    -c "${_pn_config_commit}" \
    -d "${cd_scripts_commitId:-}" \
    -b "${bucketName}" \
    -r "${release_label}" \
    -R "${aws_region}" || true

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

aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "${repo_name}/commits/${pn_microsvc_commitId}/${lambdasZip}" \
      "${lambdasZip}"

unzip ${lambdasZip} -d ./${lambdasLocalPath}

bucketBasePath="${repo_name}/${pn_microsvc_commitId}"
aws ${aws_command_base_args} s3 cp --recursive \
      "${lambdasLocalPath}/" \
      "s3://$bucketName/${bucketBasePath}/"


echo ""
echo "=== Upload microservice files to bucket"
microserviceBucketS3BaseUrl="s3://${bucketName}/${bucketBasePath}"
aws ${aws_command_base_args} \
    s3 cp "${repo_name}/" $microserviceBucketS3BaseUrl \
      --recursive --exclude ".git/*" --exclude "functions/*"

MicroserviceNumber=0

echo "Load all outputs in a single file for next stack deployments"
INFRA_ALL_OUTPUTS_FILE=infra_all_outputs-${env_type}.json
(cd ${cwdir}/commons && ./merge-infra-outputs-core.sh -r ${aws_region} -e ${env_type} -o ${work_dir}/${INFRA_ALL_OUTPUTS_FILE} )

echo "## start merge all ##"
cat $INFRA_ALL_OUTPUTS_FILE
echo "## end merge all ##"


echo ""
echo ""
echo ""
echo "======================================================================="
echo "======================================================================="
echo "===                                                                 ==="
echo "===                $repo_name STORAGE DEPLOYMENT                    ==="
echo "===                                                                 ==="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo ""
echo "=== Prepare parameters for $repo_name storage deployment in $env_type ACCOUNT"
TemplateFilePath=${repo_name}/scripts/aws/cfn/storage.yml
ParamFilePath=${repo_name}/scripts/aws/cfn/storage-${env_type}-cfg.json
EnanchedParamFilePath=${repo_name}-storage-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\"ProjectName=$project_name\",\"MicroserviceNumber=${MicroserviceNumber}\",\"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid},${repo_name}=${pn_microsvc_commitId}\""

##Add transform in storage template
echo "Add transform in storage template"
bash ${cwdir}/commons/transform-microservice-template.sh -f ${TemplateFilePath}

echo " - TemplateFilePath: ${TemplateFilePath}"
echo " - ParamFilePath: ${ParamFilePath}"
echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
echo " - PipelineParams: ${PipelineParams}"

# if ParamFilePath doesn't exist, create an empty one
if [ ! -f ${ParamFilePath} ]; then
  echo "{ \"Parameters\": {} }" > ${ParamFilePath}
fi

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


echo ""
echo "=== Deploy $repo_name STORAGE FOR $env_type ACCOUNT"
aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name ${repo_name}-storage-$env_type \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
      --template-file ${TemplateFilePath} \
      --s3-bucket ${bucketName} \
      --s3-prefix cfn \
      --tags "Microservice=${repo_name}" \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )
   

echo "=== PARAMETERS "
echo " - LambdasBucketName: ${bucketName}"
echo " - MicroserviceName: ${repo_name}"
echo " - MicroserviceNumber: ${MicroserviceNumber}"


echo ""
echo ""
echo ""
echo "======================================================================="
echo "======================================================================="
echo "===                                                                 ==="
echo "===             MICROSERVICE DEPLOYMENT                             ==="
echo "===                                                                 ==="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo ""
echo "=== Prepare parameters for pn-infra.yaml deployment in $env_type ACCOUNT"
PreviousOutputFilePath=${repo_name}-storage-${env_type}-out.json
TemplateFilePath=${repo_name}/scripts/aws/cfn/microservice.yml
ParamFilePath=${repo_name}/scripts/aws/cfn/microservice-${env_type}-cfg.json
EnanchedParamFilePath=${repo_name}-microservice-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\
     \"ProjectName=$project_name\",\"MicroserviceNumber=${MicroserviceNumber}\",\
     \"LambdasBucketName=${bucketName}\",\"BucketBasePath=$bucketBasePath\",\
     \"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid},${repo_name}=${pn_microsvc_commitId}\""

echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - TemplateFilePath: ${TemplateFilePath}"
echo " - ParamFilePath: ${ParamFilePath}"
echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
echo " - PipelineParams: ${PipelineParams}"


echo ""
echo "= Read Outputs from previous stack"
aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name ${repo_name}-storage-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${PreviousOutputFilePath}

echo ""
echo "= Read Parameters file"
cat ${ParamFilePath} 

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } * .[1] * { \"Parameters\": .[2] }" \
   ${PreviousOutputFilePath} ${ParamFilePath} ${INFRA_ALL_OUTPUTS_FILE} \
   | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
   > ${EnanchedParamFilePath}
echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}

##Add transform in microservice template
echo "Add transform in microservice template"
bash ${cwdir}/commons/transform-microservice-template.sh -f ${TemplateFilePath}

echo ""
echo "=== Deploy $repo_name MICROSERVICE FOR $env_type ACCOUNT"
aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name ${repo_name}-microsvc-$env_type \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
      --template-file ${TemplateFilePath} \
      --s3-bucket ${bucketName} \
      --s3-prefix cfn \
      --tags "Microservice=${repo_name}" \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )

if [[ -f "${repo_name}/scripts/aws/cfn/data-quality.yml" ]]; then
    echo ""
    echo ""
    echo ""
    echo "======================================================================="
    echo "======================================================================="
    echo "===                                                                 ==="
    echo "===              $repo_name DATA QUALITY DEPLOYMENT                ==="
    echo "===                                                                 ==="
    echo "======================================================================="
    echo "======================================================================="
    echo ""
    echo ""
    echo ""
    echo "=== Prepare parameters for $repo_name data quality deployment in $env_type ACCOUNT"
    PreviousOutputFilePath=${repo_name}-storage-${env_type}-out.json
    CdcAnalyticsOutputFilePath=pn-cdc-analytics-${env_type}-out.json
    TemplateFilePath=${repo_name}/scripts/aws/cfn/data-quality.yml
    ParamFilePath=${repo_name}/scripts/aws/cfn/data-quality-${env_type}-cfg.json
    EnanchedParamFilePath=${repo_name}-data-quality-${env_type}-cfg-enanched.json
    PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\
         \"ProjectName=$project_name\",\"MicroserviceNumber=${MicroserviceNumber}\",\
         \"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid},${repo_name}=${pn_microsvc_commitId}\""

    echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
    echo " - CdcAnalyticsOutputFilePath: ${CdcAnalyticsOutputFilePath}"
    echo " - TemplateFilePath: ${TemplateFilePath}"
    echo " - ParamFilePath: ${ParamFilePath}"
    echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
    echo " - PipelineParams: ${PipelineParams}"

    echo ""
    echo "= Read Outputs from Storage stack"
    aws ${aws_command_base_args} \
        cloudformation describe-stacks \
          --stack-name ${repo_name}-storage-$env_type \
          --query "Stacks[0].Outputs" \
          --output json \
          | jq 'map({ (.OutputKey): .OutputValue}) | add' \
          | tee ${PreviousOutputFilePath}

    echo ""
    echo "= Read Outputs from CDC Analytics stack"
    aws ${aws_command_base_args} \
        cloudformation describe-stacks \
          --stack-name pn-cdc-analytics-$env_type \
          --query "Stacks[0].Outputs" \
          --output json \
          | jq 'map({ (.OutputKey): .OutputValue}) | add' \
          | tee ${CdcAnalyticsOutputFilePath}

    echo ""
    echo "= Read Parameters file"
    cat ${ParamFilePath} 

    echo ""
    echo "= Enanched parameters file"
    jq -s "{ \"Parameters\": .[0] } * .[1] * { \"Parameters\": .[2] } * { \"Parameters\": .[3] }" \
       ${PreviousOutputFilePath} ${ParamFilePath} ${CdcAnalyticsOutputFilePath} ${INFRA_ALL_OUTPUTS_FILE} \
       | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
       > ${EnanchedParamFilePath}
    echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
    cat ${EnanchedParamFilePath}

    echo ""
    echo "=== Deploy $repo_name DATA QUALITY FOR $env_type ACCOUNT"
    aws ${aws_command_base_args} \
        cloudformation deploy \
          --stack-name ${repo_name}-data-quality-$env_type \
          --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
          --template-file ${TemplateFilePath} \
          --tags "Microservice=${repo_name}" \
          --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )
else
    echo ""
    echo "${repo_name}/scripts/aws/cfn/data-quality.yml file doesn't exist, data quality deployment skipped"
fi

# Release Tracking: SUCCESS
_DEPLOY_SUCCESS=true
echo "=== Deploy completed successfully, tracking release event..."
bash "${script_dir}/commons/track-release.sh" \
    -i "${_RELEASE_EVENT_ID}" \
    -n "${repo_name}" \
    -e "${env_type}" \
    -p "SUCCESS" \
    -V "${pn_microsvc_commitId}" \
    -f "${pn_infra_commitid}" \
    -c "${_pn_config_commit}" \
    -d "${cd_scripts_commitId:-}" \
    -b "${bucketName}" \
    -r "${release_label}" \
    -R "${aws_region}" || true
