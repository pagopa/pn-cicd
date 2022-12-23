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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -n <repo-name> -r <aws-region> -e <env-type> -i <github-commitid> -a <pn-microsvc-github-commitId> [-c <custom_config_dir>] -b <artifactBucketName> -B <lambdaArtifactBucketName> [-w <work_dir>]
    
    
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
    -w <work-dir>                    : working directory used by the script to download artifacts (default $HOME/tmp/deploy)

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

bucketBasePath="${repo_name}/main"
aws ${aws_command_base_args} s3 cp --recursive \
      "${lambdasLocalPath}/" \
      "s3://$bucketName/${bucketBasePath}/"

MicroserviceNumber=0

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
PreviousOutputFilePath=pn-ipc-${env_type}-out.json
TemplateFilePath=${repo_name}/scripts/aws/cfn/storage.yml
EnanchedParamFilePath=${repo_name}-storage-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\"ProjectName=$project_name\",\"MicroserviceNumber=${MicroserviceNumber}\",\"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid},${repo_name}=${pn_microsvc_commitId}\""

echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - TemplateFilePath: ${TemplateFilePath}"
echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
echo " - PipelineParams: ${PipelineParams}"


echo ""
echo "= Read Outputs from previous stack"
aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${PreviousOutputFilePath}

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } " ${PreviousOutputFilePath} \
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
echo "===             PN-PROGRESSION-SENSOR DEPLOYMENT                    ==="
echo "===                                                                 ==="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo ""
echo "=== Prepare parameters for pn-infra.yaml deployment in $env_type ACCOUNT"
PreviousOutputFilePath=${repo_name}-storage-${env_type}-out.json
InfraIpcOutputFilePath=pn-ipc-${env_type}-out.json
TemplateFilePath=${repo_name}/scripts/aws/cfn/microservice.yml
ParamFilePath=${repo_name}/scripts/aws/cfn/microservice-${env_type}-cfg.json
EnanchedParamFilePath=${repo_name}-microservice-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\
     \"ProjectName=$project_name\",\"MicroserviceNumber=${MicroserviceNumber}\",\
     \"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid},${repo_name}=${pn_microsvc_commitId}\""

echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - InfraIpcOutputFilePath: ${InfraIpcOutputFilePath}"
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
echo "= Read Outputs from infrastructure stack"
aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${InfraIpcOutputFilePath}

echo ""
echo "= Read Parameters file"
cat ${ParamFilePath} 

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } * .[1] * { \"Parameters\": .[2] }" \
   ${PreviousOutputFilePath} ${ParamFilePath} ${InfraIpcOutputFilePath} \
   | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
   > ${EnanchedParamFilePath}
echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}


echo ""
echo "=== Deploy $repo_name MICROSERVICE FOR $env_type ACCOUNT"
aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name ${repo_name}-microsvc-$env_type \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
      --template-file ${TemplateFilePath} \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )