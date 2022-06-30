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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> -i <github-commitid> -a <pn-authfleet-github-commitid> [-c <custom_config_dir>] -b <artifactBucketName> -B <lambdaArtifactBucketName> 
    
    
    [-h]                  x         : this help message
    [-v]                           : verbose mode
    [-p <aws-profile>]             : aws cli profile (optional)
    -r <aws-region>                : aws region as eu-south-1
    -e <env-type>                  : one of dev / uat / svil / coll / cert / prod
    -i <infra-github-commitid>     : commitId for github repository pagopa/pn-infra
    -a <authfleet-github-commitid> : commitId for github repository pagopa/pn-infra
    [-c <custom_config_dir>]       : where tor read additional env-type configurations
    -b <artifactBucketName>        : bucket name to use as temporary artifacts storage
    -B <lambdaArtifactBucketName>  : bucket name where lambda artifact are memorized
EOF
  exit
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
  pn_authfleet_commitid=""
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
    -a | --authfleet-commitid) 
      pn_authfleet_commitid="${2-}"
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
  [[ -z "${pn_authfleet_commitid-}" ]] && usage
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
  echo "Authfleet CommitId: ${pn_authfleet_commitid}"
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



echo "=== Download pn-auth-fleet" 
if ( [ ! -e pn-auth-fleet ] ) then 
  git clone https://github.com/pagopa/pn-auth-fleet.git
fi

echo ""
echo "=== Checkout pn-auth-fleet commitId=${pn_authfleet_commitid}"
( cd pn-auth-fleet && git fetch && git checkout $pn_authfleet_commitid )
echo " - copy custom config"
if ( [ ! -z "${custom_config_dir}" ] ) then
  cp -r $custom_config_dir/pn-auth-fleet .
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
templateBucketHttpsBaseUrl="https://s3.${aws_region}.amazonaws.com/${bucketName}/pn-infra/${pn_infra_commitid}/runtime-infra-new"
echo " - Bucket Name: ${bucketName}"
echo " - Bucket Template S3 Url: ${templateBucketS3BaseUrl}"
echo " - Bucket Template HTTPS Url: ${templateBucketHttpsBaseUrl}"


echo ""
echo "=== Upload files to bucket"
aws ${aws_command_base_args} \
    s3 cp pn-infra $templateBucketS3BaseUrl \
      --recursive

aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-auth-fleet/commits/${pn_authfleet_commitid}/apikeyAuthorizer.zip" \
      "apikeyAuthorizer.zip"
aws ${aws_command_base_args} s3 cp \
      "apikeyAuthorizer.zip" \
      "s3://$bucketName/pn-auth-fleet/main/apikeyAuthorizer.zip" 

aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-auth-fleet/commits/${pn_authfleet_commitid}/jwtAuthorizer.zip" \
      "jwtAuthorizer.zip"
aws ${aws_command_base_args} s3 cp \
      "jwtAuthorizer.zip" \
      "s3://$bucketName/pn-auth-fleet/main/jwtAuthorizer.zip" 

aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-auth-fleet/commits/${pn_authfleet_commitid}/tokenExchange.zip" \
      "tokenExchange.zip"
aws ${aws_command_base_args} s3 cp \
      "tokenExchange.zip" \
      "s3://$bucketName/pn-auth-fleet/main/tokenExchange.zip" 

aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-auth-fleet/commits/${pn_authfleet_commitid}/ioAuthorizer.zip" \
      "ioAuthorizer.zip"
aws ${aws_command_base_args} s3 cp \
      "ioAuthorizer.zip" \
      "s3://$bucketName/pn-auth-fleet/main/ioAuthorizer.zip" 


LambdaZipVersionId1=$( aws ${aws_command_base_args} \
    s3api head-object \
      --bucket $bucketName \
      --key "pn-auth-fleet/main/apikeyAuthorizer.zip" \
      --query "VersionId" \
      --output text )
LambdaZipVersionId2=$( aws ${aws_command_base_args} \
    s3api head-object \
      --bucket $bucketName \
      --key "pn-auth-fleet/main/jwtAuthorizer.zip" \
      --query "VersionId" \
      --output text )
LambdaZipVersionId3=$( aws ${aws_command_base_args} \
    s3api head-object \
      --bucket $bucketName \
      --key "pn-auth-fleet/main/tokenExchange.zip" \
      --query "VersionId" \
      --output text )
LambdaZipVersionId4=$( aws ${aws_command_base_args} \
    s3api head-object \
      --bucket $bucketName \
      --key "pn-auth-fleet/main/ioAuthorizer.zip" \
      --query "VersionId" \
      --output text )
MicroserviceNumber=0

echo "=== PARAMETERS "
echo " - LambdasBucketName: ${bucketName}"
echo " - LambdaZipVersionId1: ${LambdaZipVersionId1}"
echo " - LambdaZipVersionId2: ${LambdaZipVersionId2}"
echo " - LambdaZipVersionId3: ${LambdaZipVersionId3}"
echo " - LambdaZipVersionId4: ${LambdaZipVersionId4}"
echo " - MicroserviceNumber: ${MicroserviceNumber}"


echo ""
echo ""
echo ""
echo "======================================================================="
echo "======================================================================="
echo "===                                                                 ==="
echo "===                     PN-AUTH-FLEET DEPLOYMENT                    ==="
echo "===                                                                 ==="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo ""
echo "=== Prepare parameters for pn-infra.yaml deployment in $env_type ACCOUNT"
PreviousOutputFilePath=pn-ipc-${env_type}-out.json
TemplateFilePath=pn-auth-fleet/scripts/aws/cfn/microservice.yml
ParamFilePath=pn-auth-fleet/scripts/aws/cfn/microservice-${env_type}-cfg.json
EnanchedParamFilePath=pn-auth-fleet-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\"ProjectName=$project_name\",\
  \"LambdasBucketName=${bucketName}\",\"MicroserviceNumber=${MicroserviceNumber}\",\
  \"LambdaZipVersionId1=${LambdaZipVersionId1}\",\"LambdaZipVersionId2=${LambdaZipVersionId2}\",\
  \"LambdaZipVersionId3=${LambdaZipVersionId3}\",\"LambdaZipVersionId4=${LambdaZipVersionId4}\",\
  \"Version=infra_${pn_infra_commitid},authfleet_${pn_authfleet_commitid}\""

echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - TemplateFilePath: ${TemplateFilePath}"
echo " - ParamFilePath: ${ParamFilePath}"
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
echo "= Read Parameters file"
cat ${ParamFilePath} 

keepKeys=$( yq eval '.Parameters | keys' $TemplateFilePath | sed -e 's/#.*//' | sed -e '/^ *$/d' | sed -e 's/^. //g' | tr '\n' ',' | sed -e 's/,$//' )
echo "Parameters required from stack: $keepKeys"

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } * .[1]" ${PreviousOutputFilePath} ${ParamFilePath} \
   | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
   > ${EnanchedParamFilePath}
echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}


echo ""
echo "=== Deploy PN-AUTH-FLEET FOR $env_type ACCOUNT"
aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name pn-auth-fleet-microsvc-$env_type \
      --capabilities CAPABILITY_NAMED_IAM \
      --template-file ${TemplateFilePath} \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )
        
