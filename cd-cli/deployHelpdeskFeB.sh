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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> -i <github-commitid> -f <pn-helpdesk-fe-github-commitid> [-c <custom_config_dir>] -b <artifactBucketName> -B <webArtifactBucketName> 
    
    [-h]                             : this help message
    [-v]                             : verbose mode
    [-p <aws-profile>]               : aws cli profile (optional)
    -r <aws-region>                  : aws region as eu-south-1
    -e <env-type>                    : one of dev / uat / svil / coll / cert / prod
    -i <infra-github-commitid>     : commitId for github repository pagopa/pn-infra
    -f <pn-helpdesk-fe-github-commitid>  : commitId for github repository pagopa/pn-helpdesk-fe
    [-c <custom_config_dir>]         : where tor read additional env-type configurations
    -b <artifactBucketName>        : bucket name to use as temporary artifacts storage
    -B <webArtifactBucketName>     : bucket name where web application artifact are memorized

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
  pn_helpdesk_fe_commitid=""
  bucketName=""
  distributionId=""
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
    -f | --helpdesk-fe-commitid) 
      pn_helpdesk_fe_commitid="${2-}"
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
  [[ -z "${pn_helpdesk_fe_commitid-}" ]] && usage
   [[ -z "${bucketName-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
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
  echo "Infra CommitId:    ${pn_infra_commitid}"
  echo "Showcase site CommitId: ${pn_helpdesk_fe_commitid}"
  echo "Env Name:            ${env_type}"
  echo "AWS region:          ${aws_region}"
  echo "AWS profile:         ${aws_profile}"
  echo "Bucket Name:       ${bucketName}"
  echo "Ci Bucket Name:    ${LambdasBucketName}"
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

echo "=== Download pn-helpdesk-fe" 
if ( [ ! -e pn-helpdesk-fe ] ) then 
  git clone "https://github.com/pagopa/pn-helpdesk-fe.git"
fi

echo ""
echo "=== Checkout pn-helpdesk-fe commitId=${pn_helpdesk_fe_commitid}"
( cd pn-helpdesk-fe && git fetch && git checkout $pn_helpdesk_fe_commitid )
echo " - copy custom config"
if ( [ ! -z "${custom_config_dir}" ] ) then
  cp -r $custom_config_dir/pn-helpdesk-fe .
fi

templateBucketS3BaseUrl="s3://${bucketName}/pn-infra/${pn_infra_commitid}"
templateBucketHttpsBaseUrl="https://s3.${aws_region}.amazonaws.com/${bucketName}/pn-infra/${pn_infra_commitid}/runtime-infra"
echo " - Bucket Name: ${bucketName}"
echo " - Bucket Template S3 Url: ${templateBucketS3BaseUrl}"
echo " - Bucket Template HTTPS Url: ${templateBucketHttpsBaseUrl}"


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

aws_log_base_args=""
if ( [ ! -z "${aws_profile}" ] ) then
  aws_log_base_args="${aws_log_base_args} --profile $aws_profile"
fi
aws_log_base_args="${aws_log_base_args} --region eu-central-1"

# API
WebApiDnsName=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"WebApiDnsName\") | .OutputValue" )
API_BASE_URL=""
if ( [ $WebApiDnsName != '-' ] ) then
  API_BASE_URL="https://${WebApiDnsName}/"
fi

BoApiDnsName=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \ 
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select(.OutputKey==\"BoApiDnsName\") | .OutputValue" )
BO_API_BASE_URL=""
if ( [ $BoApiDnsName != '-' ] ) then
  BO_API_BASE_URL="https://${BoApiDnsName}/"
fi

# COGNITO
CognitoUserPoolId=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-cognito-$env_type \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select(.OutputKey==\"CognitoUserPoolId\") | .OutputValue" )
USER_POOL_ID=""
if ( [ $CognitoUserPoolId != '-' ] ) then
  USER_POOL_ID=$CognitoUserPoolId
fi

CognitoWebClientId=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-cognito-$env_type \ 
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select(.OutputKey==\"CognitoWebClientId\") | .OutputValue" )
WEB_CLIENT_ID=""
if ( [ $CognitoWebClientId != '-' ] ) then
  WEB_CLIENT_ID=$CognitoWebClientId
fi

# replace config files in build artifact
function replace_config() {
#  cp ./conf/env/config.$1.json ./conf/config.json

  LocalFilePath=/tmp/$2-filled.json
  echo '{}' > $LocalFilePath

  jq -r '.' /tmp/$2.json \
      | jq ".AWS_USER_POOLS_ID=\"$USER_POOL_ID\"" \
      | jq ".AWS_USER_POOLS_WEB_CLIENT_ID=\"$WEB_CLIENT_ID\"" \
      | tee $LocalFilePath

  jq -s ".[0] * .[1]" ./conf/env/config.$1.json ${LocalFilePath} > ./conf/config.json
}


echo ""
echo "=== Upload files to bucket"
aws ${aws_command_base_args} \
    s3 cp pn-infra $templateBucketS3BaseUrl \
      --recursive --exclude ".git/*"

AlarmSNSTopicArn=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name once-$env_type \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"AlarmSNSTopicArn\") | .OutputValue" )

echo "AlarmSNSTopicArn : ${AlarmSNSTopicArn}"

echo ""
echo ""
echo ""
echo "====================================================================="
echo "====================================================================="
echo "===                                                               ==="
echo "===                      PREPARE CLOUDFRONT                       ==="
echo "===                                                               ==="
echo "====================================================================="
echo "====================================================================="

function prepareOneCloudFront() {
  CdnName=$1
  WebDomain=$2
  WebCertificateArn=$3
  HostedZoneId=$4
  
  OptionalParameters="AlarmSNSTopicArn=${AlarmSNSTopicArn}"

  echo ""
  echo "=== Create CDN ${CdnName} with domain ${WebDomain} in zone ${HostedZoneId}"
  echo "     CertificateARN=${WebCertificateArn}"
  aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name $CdnName \
      --template-file pn-helpdesk-fe/scripts/aws/one-cdn.yaml \
      --parameter-overrides \
        Name="${CdnName}" \
        WebDomain="${WebDomain}" \
        WebCertificateArn="${WebCertificateArn}" \
        HostedZoneId="${HostedZoneId}" \
        WebApiUrl="${API_BASE_URL}" \
        BoWebApiUrl="${BO_API_BASE_URL}" \
        $OptionalParameters
  
  bucketName=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name $CdnName \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"WebAppBucketName\") | .OutputValue" )

  distributionId=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name $CdnName \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"DistributionId\") | .OutputValue" )

  echo " - Created bucket name: ${bucketName}"
}

# read output from pn-ipc
echo ""
echo "= Read Outputs from pn-ipc stack"

ZoneId=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select(.OutputKey==\"CdnZoneId\") | .OutputValue" )
ZONE_ID=""
if ( [ $ZoneId != '-' ] ) then
  ZONE_ID=$ZoneId
fi

# CERTIFICATES
PortaleHelpdeskCertificateArn=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --outout json \
  | jq -r ".Stacks[0].Outputs | .[] | select(.OutputKey==\"PortaleHelpdeskCertificateArn\") | .OutputValue" )
PORTALE_HELPDESK_CERTIFICATE_ARN=""
if ( [ $PortaleHelpdeskCertificateArn != '-' ] ) then
  PORTALE_HELPDESK_CERTIFICATE_ARN=$PortaleHelpdeskCertificateArn
fi

# DOMAIN
PortaleHelpdeskDomain=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"PortaleHelpdeskDomain\") | .OutputValue" )
PORTALE_HELPDESK_DOMAIN=""
if ( [ $PortaleHelpdeskDomain != '-' ] ) then
  PORTALE_HELPDESK_DOMAIN="https://${PortaleHelpdeskDomain}"
fi

prepareOneCloudFront webapp-helpdesk-cdn-${env_type} \
    "$PORTALE_HELPDESK_DOMAIN" \
    "$PORTALE_HELPDESK_CERTIFICATE_ARN" \
    "$ZONE_ID"

webappHelpdeskBucketName=${bucketName}
webappHelpdeskBDistributionId=${distributionId}

echo ""
echo " === Distribution ID Portale Helpdesk = ${webappHelpdeskBDistributionId}"
echo " === Bucket Portale Helpdesk = ${webappHelpdeskBucketName}"

echo ""
echo ""
echo ""
echo ""

echo "====================================================================="
echo "====================================================================="
echo "===                                                               ==="
echo "===                 DEPLOY WEB APPLICATION TO CDN                 ==="
echo "===                                                               ==="
echo "====================================================================="
echo "====================================================================="
aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-helpdesk-fe/commits/${pn_helpdesk_fe_commitid}/pn-helpdesk-fe.tar.gz" \
      "pn-helpdesk-fe.tar.gz"

mkdir -p "pn-helpdesk-fe"
( cd "pn-helpdesk-fe" \
     && tar xvzf "../pn-helpdesk-fe.tar.gz" \
     && replace_config ${env_type} "pn-helpdesk-fe" \
)

aws ${aws_command_base_args} \
    s3 cp "pn-helpdesk-fe" "s3://${webappHelpdeskBucketName}/" --recursive 

aws ${aws_command_base_args} cloudfront create-invalidation --distribution-id ${webappHelpdeskBDistributionId} --paths "/*"

aws ${aws_command_base_args} \
    s3 sync "pn-helpdesk-fe" "s3://${webappHelpdeskBucketName}/" --delete 


