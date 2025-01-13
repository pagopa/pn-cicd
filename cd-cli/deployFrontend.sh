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
    Usage: $(basename "${BASH_SOURCE[0]}")  [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> -i <github-commitid> -f <pn-frontend-github-commitid> [-c <custom_config_dir>] -b <artifactBucketName> -B <webArtifactBucketName> 
    
    [-h]                           : this help message
    [-v]                           : verbose mode
    [-p <aws-profile>]             : aws cli profile (optional)
    -r <aws-region>                : aws region as eu-south-1
    -e <env-type>                  : one of dev / uat / svil / coll / cert / prod
    -i <infra-github-commitid>     : commitId for github repository pagopa/pn-infra
    -f <frontend-github-commitid>  : commitId for github repository pagopa/pn-frontend
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
  pn_frontend_commitid=""
  bucketName=""
  distributionId=""
  distributionDomainName=""
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
    -f | --frontend-commitid) 
      pn_frontend_commitid="${2-}"
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
  [[ -z "${pn_frontend_commitid-}" ]] && usage
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
  echo "Frontend CommitId: ${pn_frontend_commitid}"
  echo "Env Name:          ${env_type}"
  echo "AWS region:        ${aws_region}"
  echo "AWS profile:       ${aws_profile}"
  echo "Bucket Name:       ${bucketName}"
  echo "Ci Bucket Name:    ${LambdasBucketName}"
}

# START SCRIPT

parse_params "$@"
dump_params

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

echo "=== Download pn-frontend" 
if ( [ ! -e pn-frontend ] ) then 
  git clone https://github.com/pagopa/pn-frontend.git
fi

echo ""
echo "=== Checkout pn-frontend commitId=${pn_frontend_commitid}"
( cd pn-frontend && git fetch && git checkout $pn_frontend_commitid )
echo " - copy custom config"
if ( [ ! -z "${custom_config_dir}" ] ) then
  cp -r $custom_config_dir/pn-frontend .
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


echo "Load all outputs in a single file for next stack deployments"
INFRA_ALL_OUTPUTS_FILE=infra_all_outputs-${env_type}.json
(cd ${cwdir}/commons && ./merge-infra-outputs-core.sh -r ${aws_region} -e ${env_type} -o ${work_dir}/${INFRA_ALL_OUTPUTS_FILE} )

echo "## start merge all ##"
cat $INFRA_ALL_OUTPUTS_FILE
echo "## end merge all ##"

WebApiDnsName=$(cat $INFRA_ALL_OUTPUTS_FILE | jq -r '.WebApiDnsName')
API_BASE_URL=""
if ( [ $WebApiDnsName != '-' ] ) then
  API_BASE_URL="https://${WebApiDnsName}/"
fi

HubLoginDomain=$(cat $INFRA_ALL_OUTPUTS_FILE | jq -r '.HubLoginDomain')
URL_API_LOGIN=""
if ( [ $HubLoginDomain != '-' ] ) then
  URL_API_LOGIN="https://${HubLoginDomain}"
fi

PortalePfDomain=$(cat $INFRA_ALL_OUTPUTS_FILE | jq -r '.PortalePfDomain')
PF_URL=""
if ( [ $PortalePfDomain != '-' ] ) then
  PF_URL="https://${PortalePfDomain}"
fi

PortalePfLoginDomain=$(cat $INFRA_ALL_OUTPUTS_FILE | jq -r '.PortalePfLoginDomain')
URL_FE_LOGIN=""
if ( [ $PortalePfLoginDomain != '-' ] ) then
  URL_FE_LOGIN="https://${PortalePfLoginDomain}/"
fi

# replace config files in build artifact
# when "replace_config" is executed, we are in folder $2
# the $2 dir is the dir of the webapp (pn-pa-webapp, pn-personafisica-webapp...) 
replace_config() {

  LocalFilePath=/tmp/$2.json
  echo '{}' > $LocalFilePath
  if ( [ "$HubLoginDomain" != "-" ] ) then
    LocalFilePath=/tmp/$2-filled-pg.json
    jq -r '.' /tmp/$2.json \
      | jq ".API_BASE_URL=\"$API_BASE_URL\"" \
      | jq ".URL_API_LOGIN=\"$URL_API_LOGIN\"" \
      | jq ".PF_URL=\"$PF_URL\"" \
      | tee $LocalFilePath
  
    if ( [ $2 != 'pn-personagiuridica-webapp' ] ) then
      LocalFilePath=/tmp/$2-filled.json
      jq -r '.' /tmp/$2-filled-pg.json \
        | jq ".URL_FE_LOGIN=\"$URL_FE_LOGIN\"" \
        | tee $LocalFilePath
    fi
  fi

  if ( [ $1 == 'dev' ] ) then
    configRootPath=.
  else
    configRootPath=../pn-frontend/$2
  fi

  # we have to get the configurations from pn-configurations
  # the content of the pn-configurations is copied into the directory pn-frontend in the root of the project
  # the $2 directory is at the same level of the pn-frontend directory
  # if persona fisica login, the configuration file is in the auth dir
  if ( [ $2 != 'pn-personafisica-login' ] ) then
    jq -s ".[0] * .[1]" $configRootPath/conf/config-$1.json ${LocalFilePath} > ./conf/config.json
    rm -f ./conf/config-dev.json
  else
    jq -s ".[0] * .[1]" $configRootPath/auth/conf/config-$1.json ${LocalFilePath} > ./auth/conf/config.json
    rm -f ./auth/conf/config-dev.json
  fi
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

HAS_MONITORING=""
if ( [ -f "pn-frontend/aws-cdn-templates/one-monitoring.yaml" ] ) then
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
  SubCdnDomain=${7-no_value}
  RootWebDomain=${8-no_value}
  
  OptionalParameters=""
  if ( [ ! -z "$AlternateWebDomain" ] ) then
    OptionalParameters="${OptionalParameters} AlternateWebDomain=${AlternateWebDomain}"
    OptionalParameters="${OptionalParameters} WebDomainReferenceToSite=false"
    OptionalParameters="${OptionalParameters} AlternateWebDomainReferenceToSite=true"
  fi

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
        SubCdnDomain="${SubCdnDomain}" \
        RootWebDomain="${RootWebDomain}" \
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

  distributionDomainName=$( aws ${aws_command_base_args} \
    cloudfront get-distribution \
      --id $distributionId \
      --output json \
  | jq -r ".Distribution | .DomainName" )

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
PORTALE_PA_CERTIFICATE_ARN=""
PORTALE_PF_CERTIFICATE_ARN=""
PORTALE_PF_LOGIN_CERTIFICATE_ARN=""
PORTALE_PG_CERTIFICATE_ARN=""
PORTALE_STATUS_CERTIFICATE_ARN=""

PORTALE_PA_DOMAIN="portale-pa.${env_type}.pn.pagopa.it"
PORTALE_PF_DOMAIN="portale.${env_type}.pn.pagopa.it"
PORTALE_PF_LOGIN_DOMAIN="portale-login.${env_type}.pn.pagopa.it"
PORTALE_PG_DOMAIN="portale-pg.${env_type}.pn.pagopa.it"
PORTALE_STATUS_DOMAIN="status.${env_type}.pn.pagopa.it"

REACT_APP_URL_API=""

ENV_FILE_PATH="pn-frontend/aws-cdn-templates/${env_type}/env-cdn.sh" 
if ( [ -f $ENV_FILE_PATH ] ) then
  source $ENV_FILE_PATH
fi

ZoneId=$( cat ${INFRA_ALL_OUTPUTS_FILE} | jq -r '.CdnZoneId' )
if ( [ $ZoneId != '-' ] ) then
  ZONE_ID=$ZoneId
fi

# CERTIFICATES
PortalePaCertificateArn=$( cat ${INFRA_ALL_OUTPUTS_FILE} | jq -r '.PortalePaCertificateArn' )
if ( [ $PortalePaCertificateArn != '-' ] ) then
  PORTALE_PA_CERTIFICATE_ARN=$PortalePaCertificateArn
fi

PortalePfCertificateArn=$( cat ${INFRA_ALL_OUTPUTS_FILE} | jq -r '.PortalePfCertificateArn' )
if ( [ $PortalePfCertificateArn != '-' ] ) then
  PORTALE_PF_CERTIFICATE_ARN=$PortalePfCertificateArn
fi

PortalePfLoginCertificateArn=$( cat ${INFRA_ALL_OUTPUTS_FILE} | jq -r '.PortalePfLoginCertificateArn' )
if ( [ $PortalePfLoginCertificateArn != '-' ] ) then
  PORTALE_PF_LOGIN_CERTIFICATE_ARN=$PortalePfLoginCertificateArn
fi

PortalePgCertificateArn=$( cat ${INFRA_ALL_OUTPUTS_FILE} | jq -r '.PortalePgCertificateArn' )
if ( [ $PortalePgCertificateArn != '-' ] ) then
  PORTALE_PG_CERTIFICATE_ARN=$PortalePgCertificateArn
fi

PortaleStatusCertificateArn=$( cat ${INFRA_ALL_OUTPUTS_FILE} | jq -r '.PortaleStatusCertificateArn' )
if ( [ $PortaleStatusCertificateArn != '-' ] ) then
  PORTALE_STATUS_CERTIFICATE_ARN=$PortaleStatusCertificateArn
fi

# DOMAIN

PortalePaDomain=$( cat ${INFRA_ALL_OUTPUTS_FILE} | jq -r '.PortalePaDomain' )
if ( [ $PortalePaDomain != '-' ] ) then
  PORTALE_PA_DOMAIN=$PortalePaDomain
fi

PortalePfDomain=$( cat ${INFRA_ALL_OUTPUTS_FILE} | jq -r '.PortalePfDomain' )
if ( [ $PortalePfDomain != '-' ] ) then
  PORTALE_PF_DOMAIN=$PortalePfDomain
fi

PortalePfLoginDomain=$( cat ${INFRA_ALL_OUTPUTS_FILE} | jq -r '.PortalePfLoginDomain' )
if ( [ $PortalePfLoginDomain != '-' ] ) then
  PORTALE_PF_LOGIN_DOMAIN=$PortalePfLoginDomain
fi

PortalePgDomain=$( cat ${INFRA_ALL_OUTPUTS_FILE} | jq -r '.PortalePgDomain' )
if ( [ $PortalePgDomain != '-' ] ) then
  PORTALE_PG_DOMAIN=$PortalePgDomain
fi

PortaleStatusDomain=$( cat ${INFRA_ALL_OUTPUTS_FILE} | jq -r '.PortaleStatusDomain' )
if ( [ $PortaleStatusDomain != '-' ] ) then
  PORTALE_STATUS_DOMAIN=$PortaleStatusDomain
fi

ReactAppUrlApi=$( cat ${INFRA_ALL_OUTPUTS_FILE} | jq -r '.ReactAppUrlApi' )
echo "ReactAppUrlApi ${ReactAppUrlApi}"
if ( [ "$ReactAppUrlApi" != '-' ] ) then
  REACT_APP_URL_API=$ReactAppUrlApi
fi

echo "REACT_APP_URL_API ${REACT_APP_URL_API}"

portalePgTarballPresent=$( ( aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api head-object --bucket ${LambdasBucketName} --key "pn-frontend/commits/${pn_frontend_commitid}/pn-personagiuridica-webapp.tar.gz" 2> /dev/null > /dev/null ) && echo "OK"  || echo "KO" )
HAS_PORTALE_PG=""
if ( [ $portalePgTarballPresent = "OK" ] ) then
  HAS_PORTALE_PG="true"
fi

portaleStatusTarballPresent=$( ( aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api head-object --bucket ${LambdasBucketName} --key "pn-frontend/commits/${pn_frontend_commitid}/pn-status-webapp.tar.gz" 2> /dev/null > /dev/null ) && echo "OK"  || echo "KO" )
HAS_PORTALE_STATUS=""
if ( [ $portaleStatusTarballPresent = "OK" ] ) then
  HAS_PORTALE_STATUS="true"
fi

prepareOneCloudFront webapp-pa-cdn-${env_type} \
    "$PORTALE_PA_DOMAIN" \
    "$PORTALE_PA_CERTIFICATE_ARN" \
    "$ZONE_ID" \
    "$REACT_APP_URL_API" \
    "${PORTALE_PA_ALTERNATE_DNS-}"
webappPaBucketName=${bucketName}
webappPaDistributionId=${distributionId}
webappPaTooManyRequestsAlarmArn=${tooManyRequestsAlarmArn}
webappPaTooManyErrorsAlarmArn=${tooManyErrorsAlarmArn}

prepareOneCloudFront webapp-pfl-cdn-${env_type} \
    "$PORTALE_PF_LOGIN_DOMAIN" \
    "$PORTALE_PF_LOGIN_CERTIFICATE_ARN" \
    "$ZONE_ID" \
    "$REACT_APP_URL_API" \
    "${PORTALE_PF_LOGIN_ALTERNATE_DNS-}"\
    ""\
    "$PORTALE_PF_DOMAIN"
webappPflBucketName=${bucketName}
webappPflDistributionId=${distributionId}
webappPflDistributionDomainName=${distributionDomainName}
webappPflTooManyRequestsAlarmArn=${tooManyRequestsAlarmArn}
webappPflTooManyErrorsAlarmArn=${tooManyErrorsAlarmArn}

prepareOneCloudFront webapp-pf-cdn-${env_type} \
    "$PORTALE_PF_DOMAIN" \
    "$PORTALE_PF_CERTIFICATE_ARN" \
    "$ZONE_ID" \
    "$REACT_APP_URL_API" \
    "${PORTALE_PF_ALTERNATE_DNS-}"\
    "$webappPflDistributionDomainName"
webappPfBucketName=${bucketName}
webappPfDistributionId=${distributionId}
webappPfTooManyRequestsAlarmArn=${tooManyRequestsAlarmArn}
webappPfTooManyErrorsAlarmArn=${tooManyErrorsAlarmArn}

if ( [ ! -z $HAS_PORTALE_PG ] ) then
  prepareOneCloudFront webapp-pg-cdn-${env_type} \
      "$PORTALE_PG_DOMAIN" \
      "$PORTALE_PG_CERTIFICATE_ARN" \
      "$ZONE_ID" \
      "$REACT_APP_URL_API" \
      "${PORTALE_PG_ALTERNATE_DNS-}"
  webappPgBucketName=${bucketName}
  webappPgDistributionId=${distributionId}
  webappPgTooManyRequestsAlarmArn=${tooManyRequestsAlarmArn}
  webappPgTooManyErrorsAlarmArn=${tooManyErrorsAlarmArn}
fi

if ( [ ! -z $HAS_PORTALE_STATUS ] ) then
  prepareOneCloudFront webapp-status-cdn-${env_type} \
      "$PORTALE_STATUS_DOMAIN" \
      "$PORTALE_STATUS_CERTIFICATE_ARN" \
      "$ZONE_ID" \
      "$REACT_APP_URL_API" \
      "${PORTALE_STATUS_ALTERNATE_DNS-}"
  webappStatusBucketName=${bucketName}
  webappStatusDistributionId=${distributionId}
  webappStatusTooManyRequestsAlarmArn=${tooManyRequestsAlarmArn}
  webappStatusTooManyErrorsAlarmArn=${tooManyErrorsAlarmArn}
fi

echo ""
echo " === Distribution ID Portale PA = ${webappPaDistributionId}"
echo " === Bucket Portale PA = ${webappPaBucketName}"
echo " === Too Many Request Alarm Portale PA = ${webappPaTooManyRequestsAlarmArn}"
echo " === Too Many Errors Alarm Portale PA = ${webappPaTooManyErrorsAlarmArn}"
echo " === Bucket Portale PF = ${webappPfBucketName}"
echo " === Distribution ID Portale PF = ${webappPfDistributionId}"
echo " === Too Many Request Alarm Portale PF = ${webappPfTooManyRequestsAlarmArn}"
echo " === Too Many Errors Alarm Portale PF = ${webappPfTooManyErrorsAlarmArn}"
echo " === Bucket Portale PF login = ${webappPflBucketName}"
echo " === Distribution ID Portale PF login = ${webappPflDistributionId}"
echo " === Distribution Domain Name Portale PF login = ${webappPflDistributionDomainName}"
echo " === Too Many Request Alarm Portale PFL = ${webappPflTooManyRequestsAlarmArn}"
echo " === Too Many Errors Alarm Portale PFL = ${webappPflTooManyErrorsAlarmArn}"
if ( [ ! -z $HAS_PORTALE_PG ] ) then
  echo " === Bucket Portale PG = ${webappPgBucketName}"
  echo " === Too Many Request Alarm Portale PG = ${webappPgTooManyRequestsAlarmArn}"
  echo " === Too Many Errors Alarm Portale PG = ${webappPgTooManyErrorsAlarmArn}"
  echo " === Distribution ID Portale PG login = ${webappPgDistributionId}"
fi
if ( [ ! -z $HAS_PORTALE_STATUS ] ) then
  echo " === Bucket Portale Status = ${webappStatusBucketName}"
  echo " === Too Many Request Alarm Portale Status = ${webappStatusTooManyRequestsAlarmArn}"
  echo " === Too Many Errors Alarm Portale Status = ${webappStatusTooManyErrorsAlarmArn}"
  echo " === Distribution ID Portale status = ${webappStatusDistributionId}"
fi

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
  

  OptionalMonitoringParameters=""
  if ( [ ! -z $HAS_PORTALE_PG ] ) then
    OptionalMonitoringParameters="${OptionalMonitoringParameters} PGTooManyErrorsAlarmArn=${webappPgTooManyErrorsAlarmArn}"
    OptionalMonitoringParameters="${OptionalMonitoringParameters} PGTooManyRequestsAlarmArn=${webappPgTooManyRequestsAlarmArn}"    
  fi

  if ( [ ! -z $HAS_PORTALE_STATUS ] ) then
    OptionalMonitoringParameters="${OptionalMonitoringParameters} StatusTooManyErrorsAlarmArn=${webappStatusTooManyErrorsAlarmArn}"
    OptionalMonitoringParameters="${OptionalMonitoringParameters} StatusTooManyRequestsAlarmArn=${webappStatusTooManyRequestsAlarmArn}"    
  fi
  
  echo ""
  echo "=== Create CDN monitoring dashboard"
  aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name frontend-monitoring-${env_type} \
      --template-file pn-frontend/aws-cdn-templates/one-monitoring.yaml \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
      --parameter-overrides \
        ProjectName="${project_name}" \
        TemplateBucketBaseUrl="${templateBucketHttpsBaseUrl}" \
        PATooManyErrorsAlarmArn="${webappPaTooManyErrorsAlarmArn}" \
        PATooManyRequestsAlarmArn="${webappPaTooManyRequestsAlarmArn}" \
        PFTooManyErrorsAlarmArn="${webappPfTooManyErrorsAlarmArn}" \
        PFTooManyRequestsAlarmArn="${webappPfTooManyRequestsAlarmArn}" \
        PFLoginTooManyErrorsAlarmArn="${webappPflTooManyErrorsAlarmArn}" \
        PFLoginTooManyRequestsAlarmArn="${webappPflTooManyRequestsAlarmArn}" \
        $OptionalMonitoringParameters
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
echo "===                          PORTALE PA                           ==="
echo "====================================================================="
aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-frontend/commits/${pn_frontend_commitid}/pn-pa-webapp.tar.gz" \
      "pn-pa-webapp.tar.gz"

mkdir -p "pn-pa-webapp"
( cd "pn-pa-webapp" \
     && tar xvzf "../pn-pa-webapp.tar.gz" \
     && replace_config ${env_type} "pn-pa-webapp" \
)

aws ${aws_command_base_args} \
    s3 cp "pn-pa-webapp" "s3://${webappPaBucketName}/" --recursive 

aws ${aws_command_base_args} cloudfront create-invalidation --distribution-id ${webappPaDistributionId} --paths "/*"

aws ${aws_command_base_args} \
    s3 sync "pn-pa-webapp" "s3://${webappPaBucketName}/" --delete 

echo ""
echo "===                          PORTALE PF                           ==="
echo "====================================================================="
aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-frontend/commits/${pn_frontend_commitid}/pn-personafisica-webapp.tar.gz" \
      "pn-personafisica-webapp.tar.gz"

mkdir -p "pn-personafisica-webapp"
( cd "pn-personafisica-webapp" \
     && tar xvzf "../pn-personafisica-webapp.tar.gz" \
     && replace_config ${env_type} "pn-personafisica-webapp" \
)

aws ${aws_command_base_args} \
    s3 cp "pn-personafisica-webapp" "s3://${webappPfBucketName}/" --recursive 

aws ${aws_command_base_args} cloudfront create-invalidation --distribution-id ${webappPfDistributionId} --paths "/*"

aws ${aws_command_base_args} \
    s3 sync "pn-personafisica-webapp" "s3://${webappPfBucketName}/" --delete 

echo ""
echo "===                       PORTALE PF LOGIN                        ==="
echo "====================================================================="
aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-frontend/commits/${pn_frontend_commitid}/pn-personafisica-login.tar.gz" \
      "pn-personafisica-login.tar.gz"

mkdir -p "pn-personafisica-login"
( cd "pn-personafisica-login" \
     && tar xvzf "../pn-personafisica-login.tar.gz" \
     && replace_config ${env_type} "pn-personafisica-login" \
)

aws ${aws_command_base_args} \
    s3 cp "pn-personafisica-login" "s3://${webappPflBucketName}/" --recursive 

aws ${aws_command_base_args} cloudfront create-invalidation --distribution-id ${webappPflDistributionId} --paths "/*"

aws ${aws_command_base_args} \
    s3 sync "pn-personafisica-login" "s3://${webappPflBucketName}/" --delete 

if ( [ ! -z $HAS_PORTALE_PG ] ) then
  echo ""
  echo "===                          PORTALE PG                           ==="
  echo "====================================================================="
  aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
        --bucket "$LambdasBucketName" --key "pn-frontend/commits/${pn_frontend_commitid}/pn-personagiuridica-webapp.tar.gz" \
        "pn-personagiuridica-webapp.tar.gz"

  mkdir -p "pn-personagiuridica-webapp"
  ( cd "pn-personagiuridica-webapp" \
      && tar xvzf "../pn-personagiuridica-webapp.tar.gz" \
      && replace_config ${env_type} "pn-personagiuridica-webapp" \
  )

  aws ${aws_command_base_args} \
      s3 cp "pn-personagiuridica-webapp" "s3://${webappPgBucketName}/" --recursive 

  aws ${aws_command_base_args} cloudfront create-invalidation --distribution-id ${webappPgDistributionId} --paths "/*"
  
  aws ${aws_command_base_args} \
      s3 sync "pn-personagiuridica-webapp" "s3://${webappPgBucketName}/" --delete 
      
fi

if ( [ ! -z $HAS_PORTALE_STATUS ] ) then
  echo ""
  echo "===                          PORTALE STATUS                           ==="
  echo "====================================================================="
  aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
        --bucket "$LambdasBucketName" --key "pn-frontend/commits/${pn_frontend_commitid}/pn-status-webapp.tar.gz" \
        "pn-status-webapp.tar.gz"

  mkdir -p "pn-status-webapp"
  ( cd "pn-status-webapp" \
      && tar xvzf "../pn-status-webapp.tar.gz" \
      && replace_config ${env_type} "pn-status-webapp" \
  )

  aws ${aws_command_base_args} \
      s3 cp "pn-status-webapp" "s3://${webappStatusBucketName}/" --recursive 

  aws ${aws_command_base_args} cloudfront create-invalidation --distribution-id ${webappStatusDistributionId} --paths "/*"
  
  aws ${aws_command_base_args} \
      s3 sync "pn-status-webapp" "s3://${webappStatusBucketName}/" --delete 

fi