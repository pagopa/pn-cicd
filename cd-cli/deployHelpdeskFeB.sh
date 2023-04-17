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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] -n <microcvs-name> [-p <aws-profile>] -r <aws-region> -e <env-type> -m <pn-microsvc-github-commitid> [-c <custom_config_dir>] -f <pn-frontend-github-commitid>
    
    [-h]                             : this help message
    [-v]                             : verbose mode
    [-p <aws-profile>]               : aws cli profile (optional)
    -r <aws-region>                  : aws region as eu-south-1
    -e <env-type>                    : one of dev / uat / svil / coll / cert / prod
    -m <pn-microsvc-github-commitid> : commitId for github repository del microservizio
    [-c <custom_config_dir>]         : where tor read additional env-type configurations
    -n <microcvs-name>               : nome del microservizio
    -f <frontend-commitid>           : pn-frontend github commit id

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
  pn_microsvc_commitid=""
  pn_frontend_commitid=""
  bucketName=""
  microcvs_name="pn-helpdesk-fe"

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
    -m | --ms-commitid) 
      pn_microsvc_commitid="${2-}"
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
    -f | --frontend-commitid) 
      pn_frontend_commitid="${2-}"
      shift
      ;;
    -b | --bucket-name) 
      bucketName="${2-}"
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
  [[ -z "${pn_microsvc_commitid-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${pn_frontend_commitid-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:        ${project_name}"
  echo "Work directory:      ${work_dir}"
  echo "Custom config dir:   ${custom_config_dir}"
  echo "Microsvc CommitId:   ${pn_microsvc_commitid}"
  echo "Frontend CommitId:   ${pn_frontend_commitid}"
  echo "Microsvc Name:       ${microcvs_name}"
  echo "Env Name:            ${env_type}"
  echo "AWS region:          ${aws_region}"
  echo "AWS profile:         ${aws_profile}"
}


# START SCRIPT

parse_params "$@"
dump_params


cd $work_dir

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

if ( [ ! -e "pn_frontend" ] ) then 
  git clone "https://github.com/pagopa/pn-frontend.git"
fi
echo "=== Checkout pn-frontend commitId=${pn_frontend_commitid}"
( cd pn-frontend && git fetch && git checkout $pn_frontend_commitid )



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

AlarmSNSTopicArn=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name once-$env_type \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"AlarmSNSTopicArn\") | .OutputValue" )

function prepareOneCloudFront() {
  CdnName=$1
  WebDomain=$2
  WebCertificateArn=$3
  HostedZoneId=$4
  WebApiUrl=$5
  
  OptionalParameters=""
  if ( [ ! -z "$HAS_MONITORING" ]) then
    OptionalParameters="${OptionalParameters} AlarmSNSTopicArn=${AlarmSNSTopicArn}"
  fi

  if ( [ -f "pn-frontend/aws-cdn-templates/one-logging.yaml" ] ) then
    echo ""
    echo "=== Create Logs Bucket ${CdnName}"
    aws ${aws_log_base_args} \
      cloudformation deploy \
        --no-fail-on-empty-changeset \
        --stack-name $CdnName-logging \
        --template-file pn-frontend/aws-cdn-templates/one-logging.yaml

    logBucketName=$( aws ${aws_log_base_args} \
      cloudformation describe-stacks \
        --stack-name $CdnName-logging \
        --output json \
    | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"LogsBucketName\") | .OutputValue" )

    OptionalParameters="${OptionalParameters} S3LogsBucket=${logBucketName}"
  fi

  echo ""
  echo "=== Create CDN ${CdnName} with domain ${WebDomain} in zone ${HostedZoneId}"
  echo "     CertificateARN=${WebCertificateArn}"
  aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name $CdnName \
      --template-file pn-frontend/aws-cdn-templates/one-cdn.yaml \
      --parameter-overrides \
        Name="${CdnName}" \
        WebDomain="${WebDomain}" \
        WebCertificateArn="${WebCertificateArn}" \
        HostedZoneId="${HostedZoneId}" \
        WebApiUrl="${WebApiUrl}" \
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

  if ( [ ! -z "$HAS_MONITORING" ]) then
    tooManyRequestsAlarmArn=$( aws ${aws_command_base_args} \
      cloudformation describe-stacks \
        --stack-name $CdnName \
        --output json \
    | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"TooManyRequestsAlarmArn\") | .OutputValue" )


    tooManyErrorsAlarmArn=$( aws ${aws_command_base_args} \
      cloudformation describe-stacks \
        --stack-name $CdnName \
        --output json \
    | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"TooManyErrorsAlarmArn\") | .OutputValue" )
  fi

  echo " - Created bucket name: ${bucketName}"
}


environment="${env_type}"

CognitoUserPoolId=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-cognito-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"CognitoUserPoolId\") | .OutputValue" \
    )

CognitoWebClientId=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-cognito-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"CognitoWebClientId\") | .OutputValue" \
    )

BoApiDnsName=$( aws ${aws_command_base_args}  cloudformation describe-stacks \
      --stack-name "pn-ipc-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"BoApiDnsName\") | .OutputValue" \
    )

WebApiDnsName=$( aws ${aws_command_base_args}  cloudformation describe-stacks \
      --stack-name "pn-ipc-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"WebApiDnsName\") | .OutputValue" \
    )

PortaleHelpdeskCertificateArn=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-ipc-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"PortaleHelpdeskCertificateArn\") | .OutputValue" \
    )
 
PortaleHelpdeskDomain=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-ipc-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"PortaleHelpdeskDomain\") | .OutputValue" \
    )
    
CdnZoneId=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-ipc-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"CdnZoneId\") | .OutputValue" \
    )

echo "CognitoUserPoolId: ${CognitoUserPoolId}"
echo "CognitoWebClientId: ${CognitoWebClientId}"
echo "BoApiDnsName: ${BoApiDnsName}"
echo "WebApiDnsName: ${WebApiDnsName}"

cd $microcvs_name

source scripts/aws/env-${environment}.sh

sed -e "s/\${USER_POOL_ID}/${CognitoUserPoolId}/" \
    -e "s/\${WEB_CLIENT_ID}/${CognitoWebClientId}/" \
    -e "s/\${WEB_API_DOMAIN}/${WebApiDnsName}/" \
    -e "s/\${API_DOMAIN}/${BoApiDnsName}/"  .env.template.b > .env.production 

yarn install
yarn build

cd build

ReactAppUrlApi=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"ReactAppUrlApi\") | .OutputValue" ) 

ReactAppUrlApi="${ReactAppUrlApi} https://cognito-idp.eu-south-1.amazonaws.com"
prepareOneCloudFront webapp-helpdesk-cdn-${env_type} \
    "$PortaleHelpdeskDomain" \
    "$PortaleHelpdeskCertificateArn" \
    "$CdnZoneId" \
    "$ReactAppUrlApi"

webappHelpdeskBucketName=${bucketName}
webappHelpdeskBDistributionId=${distributionId}
webappHelpdeskBTooManyRequestsAlarmArn=${tooManyRequestsAlarmArn}
webappHelpdeskBTooManyErrorsAlarmArn=${tooManyErrorsAlarmArn}

aws s3 sync ${profile_option} . s3://${bucketName} --delete

DistributionId=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-logextractor-frontend-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"DistributionId\") | .OutputValue" \
    )

DistributionDomainName=$( aws ${aws_command_base_args} cloudformation describe-stacks \
      --stack-name "pn-logextractor-frontend-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"DistributionDomainName\") | .OutputValue" \
    )

aws cloudfront create-invalidation ${aws_command_base_args} --distribution-id ${DistributionId} --paths "/*"

echo "Deployed to "${DistributionDomainName}





