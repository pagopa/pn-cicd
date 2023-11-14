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
    Usage: $(basename "${BASH_SOURCE[0]}")  [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> -i <github-commitid> -f <pn-showcase-site-github-commitid> [-c <custom_config_dir>] -b <artifactBucketName> -B <webArtifactBucketName> 
    
    [-h]                           : this help message
    [-v]                           : verbose mode
    [-p <aws-profile>]             : aws cli profile (optional)
    -r <aws-region>                : aws region as eu-south-1
    -e <env-type>                  : one of dev / uat / svil / coll / cert / prod
    -i <infra-github-commitid>     : commitId for github repository pagopa/pn-infra
    -f <pn-showcase-site-github-commitid>  : commitId for github repository pagopa/pn-showcase-site
    [-c <custom_config_dir>]       : where tor read additional env-type configurations
    -b <artifactBucketName>        : bucket name to use as temporary artifacts storage
    -B <webArtifactBucketName>     : bucket name where web application artifact are memorized
EOF
  exit 1
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
  pn_showcase_site_commitid=""
  bucketName=""
  distributionId=""
  tooManyErrorsAlarmArn=""
  tooManyRequestsAlarmArn=""
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
    -f | --showcase-site-commitid) 
      pn_showcase_site_commitid="${2-}"
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
  [[ -z "${pn_showcase_site_commitid-}" ]] && usage
  [[ -z "${bucketName-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${LambdasBucketName-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:      ${project_name}"
  echo "Work directory:    ${work_dir}"
  echo "Custom config dir: ${custom_config_dir}"
  echo "Infra CommitId:    ${pn_infra_commitid}"
  echo "Showcase site CommitId: ${pn_showcase_site_commitid}"
  echo "Env Name:          ${env_type}"
  echo "AWS region:        ${aws_region}"
  echo "AWS profile:       ${aws_profile}"
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

echo "=== Download pn-showcase-site" 
if ( [ ! -e pn-showcase-site ] ) then 
  git clone https://github.com/pagopa/pn-showcase-site.git
fi

echo ""
echo "=== Checkout pn-showcase-site commitId=${pn_showcase_site_commitid}"
( cd pn-showcase-site && git fetch && git checkout $pn_showcase_site_commitid )
echo " - copy custom config"
if ( [ ! -z "${custom_config_dir}" ] ) then
  cp -r $custom_config_dir/pn-showcase-site .
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


LandingDomain=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"LandingDomain\") | .OutputValue" )
LANDING_SITE_URL=""
if ( [ $LandingDomain != '-' ] ) then
  LANDING_SITE_URL="https://${LandingDomain}"
fi

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

HAS_MONITORING=""
if ( [ -f "pn-showcase-site/aws-cdn-templates/one-monitoring.yaml" ] ) then
  HAS_MONITORING="true"
fi

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
  WebApiUrl=$5
  AlternateWebDomain=$6
  
  OptionalParameters=""
  if ( [ ! -z "$AlternateWebDomain" ] ) then
    OptionalParameters="${OptionalParameters} AlternateWebDomain=${AlternateWebDomain}"
    OptionalParameters="${OptionalParameters} WebDomainReferenceToSite=false"
    OptionalParameters="${OptionalParameters} AlternateWebDomainReferenceToSite=true"
  fi

  if ( [ ! -z "$HAS_MONITORING" ]) then
    OptionalParameters="${OptionalParameters} AlarmSNSTopicArn=${AlarmSNSTopicArn}"
  fi

  if ( [ -f "pn-showcase-site/aws-cdn-templates/one-logging.yaml" ] ) then
    echo ""
    echo "=== Create Logs Bucket ${CdnName}"
    aws ${aws_log_base_args} \
      cloudformation deploy \
        --no-fail-on-empty-changeset \
        --stack-name $CdnName-logging \
        --template-file pn-showcase-site/aws-cdn-templates/one-logging.yaml

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
      --template-file pn-showcase-site/aws-cdn-templates/one-cdn.yaml \
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


ZONE_ID=""
SHOWCASE_SITE_CERTIFICATE_ARN=""

LANDING_DOMAIN="www.${env_type}.pn.pagopa.it"

REACT_APP_URL_API=""

ENV_FILE_PATH="pn-showcase-site/aws-cdn-templates/${env_type}/env-cdn.sh" 
if ( [ -f $ENV_FILE_PATH ] ) then
  source $ENV_FILE_PATH
fi

# read output from pn-ipc
echo ""
echo "= Read Outputs from pn-ipc stack"


ZoneId=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"CdnZoneId\") | .OutputValue" )

if ( [ $ZoneId != '-' ] ) then
  ZONE_ID=$ZoneId
fi

# CERTIFICATES
LandingCertificateArn=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"LandingCertificateArn\") | .OutputValue" ) 

if ( [ $LandingCertificateArn != '-' ] ) then
  LANDING_CERTIFICATE_ARN=$LandingCertificateArn
fi

# DOMAIN
LandingDomain=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name pn-ipc-$env_type \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"LandingDomain\") | .OutputValue" ) 

if ( [ $LandingDomain != '-' ] ) then
  LANDING_DOMAIN=$LandingDomain
fi

prepareOneCloudFront web-landing-cdn-${env_type} \
    "$LANDING_DOMAIN" \
    "$LANDING_CERTIFICATE_ARN" \
    "$ZONE_ID" \
    "$REACT_APP_URL_API" \
    "${LANDING_SITE_ALTERNATE_DNS-}"
landingBucketName=${bucketName}
landingDistributionId=${distributionId}
landingTooManyRequestsAlarmArn=${tooManyRequestsAlarmArn}
landingTooManyErrorsAlarmArn=${tooManyErrorsAlarmArn}



echo ""
echo " === Bucket Sito Vetrina = ${landingBucketName}"
echo " === Distribution ID Portale Sito Vetrins = ${landingDistributionId}"
echo " === Too Many Request Alarm Sito Vetrina = ${landingTooManyRequestsAlarmArn}"
echo " === Too Many Errors Alarm Sito Vetrina = ${landingTooManyErrorsAlarmArn}"
if ( [ ! -z "$HAS_MONITORING" ]) then

  echo ""
  echo ""
  echo ""
  echo ""

  echo "====================================================================="
  echo "====================================================================="
  echo "===                                                               ==="
  echo "===               DEPLOY CDN MONITORING DASHBOARD                 ==="
  echo "===                                                               ==="
  echo "====================================================================="
  echo "====================================================================="
  
  echo ""
  echo "=== Create CDN monitoring dashboard"
  aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name frontend-monitoring-${env_type} \
      --template-file pn-showcase-site/aws-cdn-templates/one-monitoring.yaml \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
      --parameter-overrides \
        ProjectName="${project_name}" \
        TemplateBucketBaseUrl="${templateBucketHttpsBaseUrl}" \
        LandingTooManyErrorsAlarmArn="${landingTooManyErrorsAlarmArn}" \
        LandingTooManyRequestsAlarmArn="${landingTooManyRequestsAlarmArn}"
fi

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

echo ""
echo "===                          SITO VETRINA                         ==="
echo "====================================================================="
aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-showcase-site/commits/${pn_showcase_site_commitid}/pn-showcase-site.tar.gz" \
      "pn-showcase-site.tar.gz"

# showcase site has a different config management - we use env variables but they are the same for each env
mkdir -p "pn-showcase-site"
( cd "pn-showcase-site" \
     && tar xvzf "../pn-showcase-site.tar.gz" \
)

aws ${aws_command_base_args} \
    s3 cp "pn-showcase-site" "s3://${landingBucketName}/" --recursive 

aws ${aws_command_base_args} \
    s3 sync "pn-showcase-site" "s3://${landingBucketName}/" --delete 

aws ${aws_command_base_args} cloudfront create-invalidation --distribution-id ${landingDistributionId} --paths "/*"
