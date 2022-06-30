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
    Usage: $(basename "${BASH_SOURCE[0]}") <aws-profile> <aws-region> <env-type> <github-commitid> <custom_config_dir>
    
EOF
  exit
}


if ( [ $# -ne 5 ] ) then
  usage
fi

project_name=pn
work_dir=$HOME/tmp/poste_deploy 
aws_profile=$1
aws_region=$2
env_type=$3
pn_infra_commitid=$4
custom_config_dir=$5

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
templateBucketHttpsBaseUrl="https://s3.${aws_region}.amazonaws.com/${bucketName}/pn-infra/${pn_infra_commitid}/runtime-infra"
echo " - Bucket Name: ${bucketName}"
echo " - Bucket Template S3 Url: ${templateBucketS3BaseUrl}"
echo " - Bucket Template HTTPS Url: ${templateBucketHttpsBaseUrl}"


echo ""
echo "=== Upload files to bucket"
aws --profile $aws_profile --region $aws_region \
    s3 cp pn-infra $templateBucketS3BaseUrl \
      --recursive


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
aws --profile $aws_profile --region $aws_region \
    cloudformation deploy \
      --stack-name once-$env_type \
      --capabilities CAPABILITY_NAMED_IAM \
      --template-file pn-infra/runtime-infra/once4account/${env_type}.yaml \
      --parameter-overrides \
        TemplateBucketBaseUrl="$templateBucketHttpsBaseUrl" \
        Version="${pn_infra_commitid}"




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
PreviousOutputFilePath=once4account-${env_type}-out.json
TemplateFilePath=pn-infra/runtime-infra/pn-infra.yaml
ParamFilePath=pn-infra/runtime-infra/pn-infra-${env_type}-cfg.json
EnanchedParamFilePath=pn-infra-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\"ProjectName=$project_name\",\"Version=${pn_infra_commitid}\""

echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - TemplateFilePath: ${TemplateFilePath}"
echo " - ParamFilePath: ${ParamFilePath}"
echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
echo " - PipelineParams: ${PipelineParams}"


echo ""
echo "= Read Outputs from previous stack"
aws --profile $aws_profile --region $aws_region \
    cloudformation describe-stacks \
      --stack-name once-$env_type \
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
echo "=== Deploy PN-INFRA FOR $env_type ACCOUNT"
aws --profile $aws_profile --region $aws_region \
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

echo ""
echo "=== Prepare parameters for pn-ipc.yaml deployment in $env_type ACCOUNT"
PreviousOutputFilePath=pn-infra-${env_type}-out.json
TemplateFilePath=pn-infra/runtime-infra/pn-ipc.yaml
ParamFilePath=pn-infra/runtime-infra/pn-ipc-${env_type}-cfg.json
EnanchedParamFilePath=pn-ipc-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\"ProjectName=$project_name\",\"Version=${pn_infra_commitid}\""

echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - TemplateFilePath: ${TemplateFilePath}"
echo " - ParamFilePath: ${ParamFilePath}"
echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
echo " - PipelineParams: ${PipelineParams}"


echo ""
echo "= Read Outputs from previous stack"
aws --profile $aws_profile --region $aws_region \
    cloudformation describe-stacks \
      --stack-name pn-infra-$env_type \
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
echo "=== Deploy PN-IPC FOR $env_type ACCOUNT"
aws --profile $aws_profile --region $aws_region \
    cloudformation deploy \
      --stack-name pn-ipc-$env_type \
      --capabilities CAPABILITY_NAMED_IAM \
      --template-file pn-infra/runtime-infra/pn-ipc.yaml \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )





