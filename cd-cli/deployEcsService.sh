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
    Usage: $(basename "${BASH_SOURCE[0]}") <microcvs-name> <microcvs-idx> <aws-profile> <aws-region> <env-type> <pn-infra-github-commitid> <pn-microsvc-github-commitid> <countainer-image-uri>  <custom_config_dir>
    
EOF
  exit
}


if ( [ $# -ne 9 ] ) then
  usage
fi

project_name=pn
work_dir=$HOME/tmp/poste_deploy 
microcvs_name=$1
MicroserviceNumber=$2
aws_profile=$3
aws_region=$4
env_type=$5
pn_infra_commitid=$6
pn_microsvc_commitid=$7
ContainerImageUri=$8
custom_config_dir=$9

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


echo "=== Download microservizio ${microcvs_name}" 
if ( [ ! -e ${microcvs_name} ] ) then 
  git clone "https://github.com/pagopa/${microcvs_name}.git"
fi

echo ""
echo "=== Checkout ${microcvs_name} commitId=${pn_microsvc_commitid}"
( cd ${microcvs_name} && git fetch && git checkout $pn_microsvc_commitid )
echo " - copy custom config"
cp -r $custom_config_dir/${microcvs_name} .


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
echo "===                                                                 ==="
echo "===                $microcvs_name STORAGE DEPLOYMENT                ==="
echo "===                                                                 ==="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo ""
echo "=== Prepare parameters for $microcvs_name storage deployment in $env_type ACCOUNT"
PreviousOutputFilePath=pn-ipc-${env_type}-out.json
TemplateFilePath=${microcvs_name}/scripts/aws/cfn/storage.yml
EnanchedParamFilePath=${microcvs_name}-storage-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\"ProjectName=$project_name\",\"MicroserviceNumber=${MicroserviceNumber}\",\"Version=infra_${pn_infra_commitid},ms=${pn_microsvc_commitid}\""

echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - TemplateFilePath: ${TemplateFilePath}"
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

keepKeys=$( yq eval '.Parameters | keys' $TemplateFilePath | sed -e 's/#.*//' | sed -e '/^ *$/d' | sed -e 's/^. //g' | tr '\n' ',' | sed -e 's/,$//' )
echo "Parameters required from stack: $keepKeys"

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } " ${PreviousOutputFilePath} \
   | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
   > ${EnanchedParamFilePath}
echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}


echo ""
echo "=== Deploy $microcvs_name STORAGE FOR $env_type ACCOUNT"
aws --profile $aws_profile --region $aws_region \
    cloudformation deploy \
      --stack-name ${microcvs_name}-storage-$env_type \
      --capabilities CAPABILITY_NAMED_IAM \
      --template-file ${TemplateFilePath} \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )
   









echo ""
echo ""
echo ""
echo "======================================================================="
echo "======================================================================="
echo "===                                                                 ==="
echo "===              $microcvs_name MICROSERVICE DEPLOYMENT              ==="
echo "===                                                                 ==="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo ""
echo "=== Prepare parameters for $microcvs_name microservice deployment in $env_type ACCOUNT"
PreviousOutputFilePath=${microcvs_name}-storage-${env_type}-out.json
InfraIpcOutputFilePath=pn-ipc-${env_type}-out.json
TemplateFilePath=${microcvs_name}/scripts/aws/cfn/microservice.yml
ParamFilePath=${microcvs_name}/scripts/aws/cfn/microservice-${env_type}-cfg.json
EnanchedParamFilePath=${microcvs_name}-microservice-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\
     \"ProjectName=$project_name\",\"MicroserviceNumber=${MicroserviceNumber}\",\
     \"ContainerImageUri=${ContainerImageUri}\",\
     \"Version=infra_${pn_infra_commitid},ms=${pn_microsvc_commitid}\""

echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - InfraIpcOutputFilePath: ${InfraIpcOutputFilePath}"
echo " - TemplateFilePath: ${TemplateFilePath}"
echo " - ParamFilePath: ${ParamFilePath}"
echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
echo " - PipelineParams: ${PipelineParams}"


echo ""
echo "= Read Outputs from previous stack"
aws --profile $aws_profile --region $aws_region \
    cloudformation describe-stacks \
      --stack-name ${microcvs_name}-storage-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${PreviousOutputFilePath}

echo ""
echo "= Read Outputs from infrastructure stack"
aws --profile $aws_profile --region $aws_region \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${InfraIpcOutputFilePath}

echo ""
echo "= Read Parameters file"
cat ${ParamFilePath} 


keepKeys=$( yq eval '.Parameters | keys' $TemplateFilePath | sed -e 's/#.*//' | sed -e '/^ *$/d' | sed -e 's/^. //g' | tr '\n' ',' | sed -e 's/,$//' )
echo "Parameters required from stack: $keepKeys"

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } * .[1] * { \"Parameters\": .[2] }" \
   ${PreviousOutputFilePath} ${ParamFilePath} ${InfraIpcOutputFilePath} \
   | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
   > ${EnanchedParamFilePath}
echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}


echo ""
echo "=== Deploy $microcvs_name MICROSERVICE FOR $env_type ACCOUNT"
aws --profile $aws_profile --region $aws_region \
    cloudformation deploy \
      --stack-name ${microcvs_name}-microsvc-$env_type \
      --capabilities CAPABILITY_NAMED_IAM \
      --template-file ${TemplateFilePath} \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )
   





