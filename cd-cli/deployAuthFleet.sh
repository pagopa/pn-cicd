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
    Usage: $(basename "${BASH_SOURCE[0]}") <aws-profile> <aws-region> <env-type> <pn-infra-github-commitid> <pn-authfleet-github-commitid> <custom_config_dir>
    
EOF
  exit
}


if ( [ $# -ne 6 ] ) then
  usage
fi

project_name=pn
work_dir=$HOME/tmp/poste_deploy 
aws_profile=$1
aws_region=$2
env_type=$3
pn_infra_commitid=$4
pn_authfleet_commitid=$5
custom_config_dir=$6

cd $work_dir

echo "=== Download pn-infra" 
if ( [ ! -e pn-infra ] ) then 
  git clone https://github.com/pagopa/pn-infra.git
fi

echo ""
echo "=== Checkout pn-infra commitId=${pn_infra_commitid}"
( cd pn-infra && git fetch && git checkout $pn_infra_commitid )
echo " - copy custom config"
cp -r $custom_config_dir/pn-infra .


echo "=== Download pn-auth-fleet" 
if ( [ ! -e pn-auth-fleet ] ) then 
  git clone https://github.com/pagopa/pn-auth-fleet.git
fi

echo ""
echo "=== Checkout pn-auth-fleet commitId=${pn_authfleet_commitid}"
( cd pn-auth-fleet && git fetch && git checkout $pn_authfleet_commitid )
echo " - copy custom config"
cp -r $custom_config_dir/pn-auth-fleet .



echo ""
echo "=== Ensure bucket"
aws --profile $aws_profile --region $aws_region \
    cloudformation deploy \
      --stack-name ArtifactBucket \
      --template-file ${script_dir}/cnf-templates/ArtifactBucket.yaml

echo ""
echo "=== Get bucket name"
getBucketNameCommand="aws --profile $aws_profile --region $aws_region cloudformation describe-stacks \
                           --stack-name ArtifactBucket \
                           --output json"

bucketName=$( $( echo $getBucketNameCommand ) | jq -r ".Stacks[0].Outputs[0].OutputValue" )
templateBucketS3BaseUrl="s3://${bucketName}/pn-infra/${pn_infra_commitid}"
templateBucketHttpsBaseUrl="https://s3.${aws_region}.amazonaws.com/${bucketName}/pn-infra/${pn_infra_commitid}/runtime-infra-new"
echo " - Bucket Name: ${bucketName}"
echo " - Bucket Template S3 Url: ${templateBucketS3BaseUrl}"
echo " - Bucket Template HTTPS Url: ${templateBucketHttpsBaseUrl}"


echo ""
echo "=== Upload files to bucket"
aws --profile $aws_profile --region $aws_region \
    s3 cp pn-infra $templateBucketS3BaseUrl \
      --recursive



LambdasBucketName="pn-ci-root-ciartifactbucket-p7efvlz7rmox"
aws --profile $aws_profile --region $aws_region \
    s3 cp \
      "s3://$LambdasBucketName/pn-auth-fleet/commits/${pn_authfleet_commitid}/apikeyAuthorizer.zip" \
      "s3://$bucketName/pn-auth-fleet/main/apikeyAuthorizer.zip" 

aws --profile $aws_profile --region $aws_region \
    s3 cp \
      "s3://$LambdasBucketName/pn-auth-fleet/commits/${pn_authfleet_commitid}/jwtAuthorizer.zip" \
      "s3://$bucketName/pn-auth-fleet/main/jwtAuthorizer.zip" 

aws --profile $aws_profile --region $aws_region \
    s3 cp \
      "s3://$LambdasBucketName/pn-auth-fleet/commits/${pn_authfleet_commitid}/tokenExchange.zip" \
      "s3://$bucketName/pn-auth-fleet/main/tokenExchange.zip" 

aws --profile $aws_profile --region $aws_region \
    s3 cp \
      "s3://$LambdasBucketName/pn-auth-fleet/commits/${pn_authfleet_commitid}/ioAuthorizer.zip" \
      "s3://$bucketName/pn-auth-fleet/main/ioAuthorizer.zip" 

LambdaZipVersionId1=$( aws --profile $aws_profile --region $aws_region \
    s3api head-object \
      --bucket $bucketName \
      --key "pn-auth-fleet/main/apikeyAuthorizer.zip" \
      --query "VersionId" \
      --output text )
LambdaZipVersionId2=$( aws --profile $aws_profile --region $aws_region \
    s3api head-object \
      --bucket $bucketName \
      --key "pn-auth-fleet/main/jwtAuthorizer.zip" \
      --query "VersionId" \
      --output text )
LambdaZipVersionId3=$( aws --profile $aws_profile --region $aws_region \
    s3api head-object \
      --bucket $bucketName \
      --key "pn-auth-fleet/main/tokenExchange.zip" \
      --query "VersionId" \
      --output text )
LambdaZipVersionId4=$( aws --profile $aws_profile --region $aws_region \
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
aws --profile $aws_profile --region $aws_region \
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
aws --profile $aws_profile --region $aws_region \
    cloudformation deploy \
      --stack-name pn-auth-fleet-microsvc-$env_type \
      --capabilities CAPABILITY_NAMED_IAM \
      --template-file ${TemplateFilePath} \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )
        
