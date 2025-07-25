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
    Usage: $(basename "${BASH_SOURCE[0]}")  [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> -i <github-commitid> -I <pn-infra-core-commitid> -f <pn-showcase-site-github-commitid> [-c <custom_config_dir>] -b <artifactBucketName> -B <webArtifactBucketName> 
    
    [-h]                           : this help message
    [-v]                           : verbose mode
    [-p <aws-profile>]             : aws cli profile (optional)
    -r <aws-region>                : aws region as eu-south-1
    -e <env-type>                  : one of dev / uat / svil / coll / cert / prod
    -i <infra-github-commitid>     : commitId for github repository pagopa/pn-infra
    -I <pn-infra-core-commitid>    : commitId for github repository pagopa/pn-infra-core
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
  pn_infra_core_commitid=""
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
    -I |--infra-core-commitid)
      pn_infra_core_commitid="${2-}"
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
  [[ -z "${pn_infra_core_commitid-}" ]] && usage
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
  echo "Infra Core CommitId: ${pn_infra_core_commitid}"
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

INFRA_SHOWCASE_SITE_BASE_PATH=pn-infra/runtime-infra/frontend/pn-showcase-site/aws-cdn-templates
if [ ! -e $INFRA_SHOWCASE_SITE_BASE_PATH ]; then
  INFRA_SHOWCASE_SITE_BASE_PATH=pn-helpdesk-fe/aws-cdn-templates
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

echo "Load all outputs in a single file for next stack deployments"
INFRA_ALL_OUTPUTS_FILE=infra_all_outputs-${env_type}.json
(cd ${cwdir}/commons && ./merge-infra-outputs-core.sh -r ${aws_region} -e ${env_type} -o ${work_dir}/${INFRA_ALL_OUTPUTS_FILE} )

echo "## start merge all ##"
cat $INFRA_ALL_OUTPUTS_FILE
echo "## end merge all ##"

echo "Load all terraform outputs in a single file for"
TERRAFORM_OUTPUTS_FILE=terraform_outputs-${env_type}.json
(cd ${cwdir}/commons && ./get-all-terraform-outputs.sh -r ${aws_region} -e ${env_type} -I ${pn_infra_core_commitid} -a core -o ${work_dir}/${TERRAFORM_OUTPUTS_FILE} )

echo "## terraform outputss ##"
cat $TERRAFORM_OUTPUTS_FILE
echo "## end terraform outputs ##"

LandingDomain=$( cat ${work_dir}/${INFRA_ALL_OUTPUTS_FILE} | jq -r '.LandingDomain' )
# Extract multi-domain-cert parameters from terraform outputs
LandingMultiDomainCertificateArn=$( cat ${work_dir}/${TERRAFORM_OUTPUTS_FILE} | jq -r '.Parameters.LandingMultiDomainCertificateArn // empty' )
LandingMultiDomainCertJoinedDomains=$( cat ${work_dir}/${TERRAFORM_OUTPUTS_FILE} | jq -r '.Parameters.LandingMultiDomainCertJoinedDomains // empty' )
LandingMultiDomainCertInternalDomainsZonesMap=$( cat ${work_dir}/${TERRAFORM_OUTPUTS_FILE} | jq -r '.Parameters.LandingMultiDomainCertInternalDomainsZonesMap // empty' )
LandingMultiDomainCertExternalDomainsZonesMap=$( cat ${work_dir}/${TERRAFORM_OUTPUTS_FILE} | jq -r '.Parameters.LandingMultiDomainCertExternalDomainsZonesMap // empty' )
DnsZoneName=$( cat ${work_dir}/${TERRAFORM_OUTPUTS_FILE} | jq -r '.Parameters.DnsZoneName // empty' )
EnableLandingCdnRedirectFunction=$( cat ${work_dir}/${TERRAFORM_OUTPUTS_FILE} | jq -r '.Parameters.EnableLandingCdnRedirectFunction // empty' )

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
if ( [ -f "${INFRA_SHOWCASE_SITE_BASE_PATH}/one-monitoring.yaml" ] ) then
  HAS_MONITORING="true"
fi

function deployLocationProxyStack() {
  local stackName=$1
  local enhancedParamsFile=$2
  
  echo "=== Deploying Location Service Proxy Stack: ${stackName}"
  
  aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name "${stackName}" \
      --template-file "${INFRA_SHOWCASE_SITE_BASE_PATH}/location-maps-proxy.yaml" \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides file://${enhancedParamsFile}
}

echo ""
echo "====================================================================="
echo "===           DEPLOY LOCATION SERVICE PROXY                       ==="
echo "====================================================================="

LOCATION_PROXY_STACK_NAME="${project_name}-showcase-maps-proxy-${env_type}"
mapsProxyLogBucketName="-"

if [ -f "${INFRA_SHOWCASE_SITE_BASE_PATH}/one-logging.yaml" ]; then
  echo ""
  echo "=== Create Logs Bucket for Maps Proxy on eu-central-1"
  mapsProxyLogStackName="${LOCATION_PROXY_STACK_NAME}-logging"
  aws ${aws_log_base_args} \
    cloudformation deploy \
      --no-fail-on-empty-changeset \
      --stack-name "${mapsProxyLogStackName}" \
      --template-file ${INFRA_SHOWCASE_SITE_BASE_PATH}/one-logging.yaml

  mapsProxyLogBucketName=$( aws ${aws_log_base_args} \
    cloudformation describe-stacks \
      --stack-name "${mapsProxyLogStackName}" \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"LogsBucketName\") | .OutputValue" )
fi

echo "=== Prepare enhanced parameters for location proxy deployment"
LocationProxyConfigFile="${INFRA_SHOWCASE_SITE_BASE_PATH}/location-maps-proxy-${env_type}-cfg.json"

if [ ! -f ${LocationProxyConfigFile} ]; then
  echo "{ \"Parameters\": {} }" > ${LocationProxyConfigFile}
fi

EnhancedParamFilePath="location-maps-proxy-${env_type}-cfg-enhanced.json"
PipelineParams="\"TemplateBucketBaseUrl=${templateBucketHttpsBaseUrl}\",\"AccessLogsBucket=${mapsProxyLogBucketName}\""

echo "= Enhanced parameters file"
jq -s "{ \"Parameters\": .[0] } * .[1] * .[2]" \
   ${INFRA_ALL_OUTPUTS_FILE} ${TERRAFORM_OUTPUTS_FILE} ${LocationProxyConfigFile} \
   | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
   > ${EnhancedParamFilePath}
echo "${PipelineParams} ]" >> ${EnhancedParamFilePath}
cat ${EnhancedParamFilePath}

deployLocationProxyStack "${LOCATION_PROXY_STACK_NAME}" "${EnhancedParamFilePath}"

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
  Environment=$5   #added env parameter as pn-showcase does not use pn-configuration, useful for env based condition on cloudfromation
  
  OptionalParameters=""
  # if ( [ ! -z "$AlternateWebDomain" ] ) then
  #   OptionalParameters="${OptionalParameters} AlternateWebDomain=${AlternateWebDomain}"
  #   OptionalParameters="${OptionalParameters} WebDomainReferenceToSite=false"
  #   OptionalParameters="${OptionalParameters} AlternateWebDomainReferenceToSite=true"
  # fi

  if ( [ ! -z "$HAS_MONITORING" ]) then
    OptionalParameters="${OptionalParameters} AlarmSNSTopicArn=${AlarmSNSTopicArn}"
  fi

  if ( [ -f "${INFRA_SHOWCASE_SITE_BASE_PATH}/one-logging.yaml" ] ) then
    echo ""
    echo "=== Create Logs Bucket ${CdnName}"
    aws ${aws_log_base_args} \
      cloudformation deploy \
        --no-fail-on-empty-changeset \
        --stack-name $CdnName-logging \
        --template-file ${INFRA_SHOWCASE_SITE_BASE_PATH}/one-logging.yaml

    logBucketName=$( aws ${aws_log_base_args} \
      cloudformation describe-stacks \
        --stack-name $CdnName-logging \
        --output json \
    | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"LogsBucketName\") | .OutputValue" )

    OptionalParameters="${OptionalParameters} S3LogsBucket=${logBucketName}"
  fi

  # Parameters used for multi-domain setup, always override the value, also if empty
  MultiDomainParameters=""
  MultiDomainParameters="${MultiDomainParameters} MultiDomainCertificateArn=${LandingMultiDomainCertificateArn:-}"
  MultiDomainParameters="${MultiDomainParameters} MultiDomainAliases=${LandingMultiDomainCertJoinedDomains:-}"
  MultiDomainParameters="${MultiDomainParameters} MultiDomainCertInternalAliasesWithZones=${LandingMultiDomainCertInternalDomainsZonesMap:-}"
  MultiDomainParameters="${MultiDomainParameters} MultiDomainCertExternalAliasesWithZones=${LandingMultiDomainCertExternalDomainsZonesMap:-}"
  MultiDomainParameters="${MultiDomainParameters} WebBaseDnsZoneName=${DnsZoneName:-}"
  MultiDomainParameters="${MultiDomainParameters} EnableCdnRedirectFunction=${EnableLandingCdnRedirectFunction:-}"
  
  echo ""
  echo "=== Create CDN ${CdnName} with domain ${WebDomain} in zone ${HostedZoneId}"
  echo "     CertificateARN=${WebCertificateArn}"
  aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name $CdnName \
      --template-file ${INFRA_SHOWCASE_SITE_BASE_PATH}/one-cdn.yaml \
      --parameter-overrides \
        Name="${CdnName}" \
        WebDomain="${WebDomain}" \
        WebCertificateArn="${WebCertificateArn}" \
        HostedZoneId="${HostedZoneId}" \
        Environment="${Environment}" \
        $OptionalParameters \
        $MultiDomainParameters

  
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

ZoneId=$( cat ${work_dir}/${INFRA_ALL_OUTPUTS_FILE} | jq -r '.CdnZoneId' )

if ( [ $ZoneId != '-' ] ) then
  ZONE_ID=$ZoneId
fi

LandingCertificateArn=$( cat ${work_dir}/${INFRA_ALL_OUTPUTS_FILE} | jq -r '.LandingCertificateArn' )
if ( [ $LandingCertificateArn != '-' ] ) then
  LANDING_CERTIFICATE_ARN=$LandingCertificateArn
fi

LandingDomain=$( cat ${work_dir}/${INFRA_ALL_OUTPUTS_FILE} | jq -r '.LandingDomain' )
if ( [ $LandingDomain != '-' ] ) then
  LANDING_DOMAIN=$LandingDomain
fi

prepareOneCloudFront web-landing-cdn-${env_type} \
    "$LANDING_DOMAIN" \
    "$LANDING_CERTIFICATE_ARN" \
    "$ZONE_ID" \
    "$env_type"
landingBucketName=${bucketName}
landingDistributionId=${distributionId}
landingTooManyRequestsAlarmArn=${tooManyRequestsAlarmArn}
landingTooManyErrorsAlarmArn=${tooManyErrorsAlarmArn}

# replace config files in build artifact
replace_config() {
  echo " === replace_config for env_type=$1"

  LocalFilePath=/tmp/config.json
  echo '{}' > $LocalFilePath

  if ( [ $1 == 'dev' ] ) then
    configRootPath=.
  else
    # relative path from "deploy" dir
    configRootPath=../../pn-showcase-site
  fi
  
  jq -s ".[0] * .[1]" $configRootPath/conf/config-$1.json ${LocalFilePath} > ./conf/config.json
  rm -f ./conf/config-dev.json
}


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
      --template-file ${INFRA_SHOWCASE_SITE_BASE_PATH}/one-monitoring.yaml \
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
mkdir -p "deploy"
cd "deploy"
aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-showcase-site/commits/${pn_showcase_site_commitid}/pn-showcase-site.tar.gz" \
      "pn-showcase-site.tar.gz"

mkdir -p "pn-showcase-site"
( cd "pn-showcase-site" \
     && tar xvzf "../pn-showcase-site.tar.gz" \
     && replace_config ${env_type}
)

aws ${aws_command_base_args} \
    s3 cp "pn-showcase-site" "s3://${landingBucketName}/" --recursive 

aws ${aws_command_base_args} \
    s3 sync "pn-showcase-site" "s3://${landingBucketName}/" --delete --exclude "static/documents/*"

aws ${aws_command_base_args} cloudfront create-invalidation --distribution-id ${landingDistributionId} --paths "/*"