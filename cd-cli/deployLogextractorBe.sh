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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] -n <microcvs-name> -N <microcvs-idx> [-p <aws-profile>] -r  <aws-region> -e <env-type> -i <pn-infra-github-commitid> -m <pn-microsvc-github-commitid> -I <countainer-image-uri> [-c <custom_config_dir>]
    
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
    -N <microcvs-idx>                : id del microservizio
    -I <image-uri>                   : url immagine docker microservizio
    
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
    -N | --ms-number)
      MicroserviceNumber="${2-}"
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
    -I | --container-image-url) 
      ContainerImageUri="${2-}"
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
  [[ -z "${ContainerImageUri-}" ]] && usage
  [[ -z "${microcvs_name-}" ]] && usage
  [[ -z "${MicroserviceNumber-}" ]] && usage
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
  echo "Microsvc Idx:        ${MicroserviceNumber}"
  echo "Env Name:            ${env_type}"
  echo "AWS region:          ${aws_region}"
  echo "AWS profile:         ${aws_profile}"
  echo "Bucket Name:         ${bucketName}"
  echo "Container image URL: ${ContainerImageUri}"
}


# START SCRIPT

parse_params "$@"
dump_params


cd $work_dir

echo "=== Download pn-infra" 
if ( [ ! -e pn-infra ] ) then 
  git clone https://github.com/pagopa/pn-infra.git
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

profile_option=""
if ( [ ! -z "${aws_profile}" ] ) then
  profile_option="-- profile $aws_profile"
fi
echo "Profile option ${profile_option}"

templateBucketS3BaseUrl="s3://${bucketName}/pn-infra/${pn_infra_commitid}"
templateBucketHttpsBaseUrl="https://s3.${aws_region}.amazonaws.com/${bucketName}/pn-infra/${pn_infra_commitid}/runtime-infra"
echo " - Bucket Name: ${bucketName}"
echo " - Bucket Template S3 Url: ${templateBucketS3BaseUrl}"
echo " - Bucket Template HTTPS Url: ${templateBucketHttpsBaseUrl}"

echo ""
echo "=== Upload files to bucket"
aws ${profile_option} \
    s3 cp pn-infra $templateBucketS3BaseUrl \
      --recursive --exclude ".git/*"

source $microcvs_name/scripts/aws/environments/.env.infra.${env_type}
source $microcvs_name/scripts/aws/environments/.env.backend.${env_type}

OpenSearchEndpoint=$( aws ${profile_option} --region="eu-south-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-storage-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"OpenSearchEndpoint\") | .OutputValue" \
    )

ElasticacheEndpoint=$( aws ${profile_option} --region="eu-south-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-storage-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"ElasticacheEndpoint\") | .OutputValue" \
    )

ElasticacheSecurityGroup=$( aws ${profile_option} --region="eu-south-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-storage-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"ElasticacheSecurityGroup\") | .OutputValue" \
    )

AlbListenerArn=$( aws ${profile_option} --region="eu-south-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"AlbListenerArn\") | .OutputValue" \
    )

AlbSecurityGroup=$( aws ${profile_option} --region="eu-south-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"AlbSecurityGroup\") | .OutputValue" \
    )

DistributionDomainName=$( aws ${profile_option} --region="eu-south-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-frontend-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"DistributionDomainName\") | .OutputValue" \
    )

echo "OpenSearchEndpoint="${OpenSearchEndpoint}
echo "ElasticacheEndpoint="${ElasticacheEndpoint}
echo "ElasticacheSecurityGroup="${ElasticacheSecurityGroup}
echo "AlbListenerArn="${AlbListenerArn}
echo "AllowedOrigin="${AllowedOrigin}
echo "AlbSecurityGroup="${AlbSecurityGroup}

TemplateFilePath="$microcvs_name/scripts/aws/ecs-service.yaml"
aws cloudformation deploy ${profile_option} --region "eu-south-1" --template-file $TemplateFilePath \
    --stack-name "pn-logextractor-service-${env_type}" \
    --parameter-overrides "AdditionalMicroserviceSecurityGroup=${ElasticacheSecurityGroup}" "MicroServiceUniqueName=pn-logextractor-be-${env_type}" \
        "ECSClusterName=pn-logextractor-${env_type}-ecs-cluster" "MappedPaths=/*" \
        "AlbSecurityGroup=${AlbSecurityGroup}" \
        "ContainerImageURI=${ContainerImageUri}" \
        "CpuValue=1024" "MemoryAmount=4GB" "VpcId=${VpcId}" \
        "Subnets=${PrivateSubnetIds}" \
        "LoadBalancerListenerArn=${AlbListenerArn}" \
        "LoadbalancerRulePriority=11" \
        "ContainerEnvEntry1=ENSURE_RECIPIENT_BY_EXTERNAL_ID_URL=${PnDataVaultRootPath}/datavault-private/v1/recipients/external/%s" \
        "ContainerEnvEntry2=GET_RECIPIENT_DENOMINATION_BY_INTERNAL_ID_URL=${PnDataVaultRootPath}/datavault-private/v1/recipients/internal" \
        "ContainerEnvEntry3=GET_SENT_NOTIFICATION_URL=${PnCoreRootPath}/delivery-private/search" \
        "ContainerEnvEntry4=GET_SENT_NOTIFICATION_DETAILS_URL=${PnCoreRootPath}/delivery-private/notifications/%s" \
        "ContainerEnvEntry5=GET_SENT_NOTIFICATION_HISTORY_URL=${PnCoreRootPath}/delivery-push-private/%s/history" \
        "ContainerEnvEntry6=GET_ENCODED_IPA_CODE_URL=${PnCoreRootPath}/ext-registry/pa/v1/activated-on-pn" \
        "ContainerEnvEntry7=GET_PUBLIC_AUTHORITY_NAME_URL=${PnCoreRootPath}/ext-registry-private/pa/v1/activated-on-pn/%s" \
        "ContainerEnvEntry8=DOWNLOAD_FILE_URL=https://%s/%s/safe-storage/v1/files/%s" \
        "ContainerEnvEntry9=SAFESTORAGE_ENDPOINT=${SafeStorageEndpoint}" \
        "ContainerEnvEntry10=SAFESTORAGE_STAGE=${SafeStorageStage}" \
        "ContainerEnvEntry11=SAFESTORAGE_CXID=${SafeStorageCxId}" \
        "ContainerEnvEntry12=SEARCH_URL=https://${OpenSearchEndpoint}/pn-logs/_search" \
        "ContainerEnvEntry13=SEARCH_FOLLOWUP_URL=https://${OpenSearchEndpoint}/_search/scroll" \
        "ContainerEnvEntry14=ELASTICACHE_HOSTNAME=${ElasticacheEndpoint}" \
        "ContainerEnvEntry15=ELASTICACHE_PORT=6379" \
        "ContainerEnvEntry17=ALLOWED_ORIGIN=${AllowedOrigin}" \
        "ContainerEnvEntry18=DOWNTIME_EVENTS_URL=${PnCoreRootPath}/downtime-internal/v1/events" \
        "ContainerEnvEntry19=DOWNTIME_STATUS_URL=${PnCoreRootPath}/downtime/v1/status" \
        "ContainerSecret1=BASIC_AUTH_USERNAME=${OpenSearchSecretArn}:username:AWSCURRENT:" \
        "ContainerSecret2=BASIC_AUTH_PASSWORD=${OpenSearchSecretArn}:password:AWSCURRENT:" \
    --capabilities "CAPABILITY_NAMED_IAM"


OpenSearchClusterName=$( aws ${profile_option} --region="eu-south-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-storage-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"OpenSearchClusterName\") | .OutputValue" \
    )

AlarmSNSTopicArn=$( aws ${profile_option} --region="eu-south-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-topics-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"AlarmSNSTopicArn\") | .OutputValue" \
    )

LogGroupName=$( aws ${profile_option} --region="eu-south-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-service-${env_type}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"LogGroupName\") | .OutputValue" \
    )

TemplateFilePath="$microcvs_name/scripts/aws/alarms.yaml"
aws cloudformation deploy ${profile_option} --region "eu-south-1" --template-file $TemplateFilePath \
    --stack-name "pn-logextractor-alarms-${env_type}" \
    --parameter-overrides "ProjectName=pn-helpdesk" \
        "EnvType=${env_type}" \
        "OpenSearchClusterName=${OpenSearchClusterName}" \
        "TemplateBucketBaseUrl=${templateBucketHttpsBaseUrl}" \
        "AlarmSNSTopicArn=${AlarmSNSTopicArn}" \
        "LogGroupName=${LogGroupName}" \
        "OpenSearchMasterNodeType=${OpenSearchMasterNodeType}" \
    --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND




