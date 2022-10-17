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

cd $work_dir

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
  echo " - Created bucket name: ${bucketName}"
}


source "pn-frontend/aws-cdn-templates/${env_type}/env-cdn.sh" 

prepareOneCloudFront webapp-pa-cdn-${env_type} \
    "portale-pa.${env_type}.pn.pagopa.it" \
    "$PORTALE_PA_CERTIFICATE_ARN" \
    "$ZONE_ID" \
    "$REACT_APP_URL_API" \
    "${PORTALE_PA_ALTERNATE_DNS-}"

webappPaBucketName=${bucketName}


prepareOneCloudFront webapp-pf-cdn-${env_type} \
    "portale.${env_type}.pn.pagopa.it" \
    "$PORTALE_PF_CERTIFICATE_ARN" \
    "$ZONE_ID" \
    "$REACT_APP_URL_API" \
    "${PORTALE_PF_ALTERNATE_DNS-}"
webappPfBucketName=${bucketName}

prepareOneCloudFront webapp-pfl-cdn-${env_type} \
    "portale-login.${env_type}.pn.pagopa.it" \
    "$PORTALE_PF_LOGIN_CERTIFICATE_ARN" \
    "$ZONE_ID" \
    "$REACT_APP_URL_API" \
    "${PORTALE_PF_LOGIN_ALTERNATE_DNS-}"
webappPflBucketName=${bucketName}



prepareOneCloudFront web-landing-cdn-${env_type} \
    "www.${env_type}.pn.pagopa.it" \
    "$LANDING_CERTIFICATE_ARN" \
    "$ZONE_ID" \
    "$REACT_APP_URL_API" \
    "${LANDING_SITE_ALTERNATE_DNS-}"
landingBucketName=${bucketName}



echo ""
echo " === Bucket Portale PA = ${webappPaBucketName}"
echo " === Bucket Portale PF = ${webappPfBucketName}"
echo " === Bucket Portale PF login = ${webappPflBucketName}"
echo " === Bucket Sito LAnding = ${landingBucketName}"




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
      --bucket "$LambdasBucketName" --key "pn-frontend/commits/${pn_frontend_commitid}/pn-pa-webapp_${env_type}.tar.gz" \
      "pn-pa-webapp_${env_type}.tar.gz"

mkdir -p "pn-pa-webapp_${env_type}"
( cd "pn-pa-webapp_${env_type}" \
     && tar xvzf "../pn-pa-webapp_${env_type}.tar.gz" \
)

aws ${aws_command_base_args} \
    s3 cp "pn-pa-webapp_${env_type}" "s3://${webappPaBucketName}/" \
      --recursive



echo ""
echo "===                          PORTALE PF                           ==="
echo "====================================================================="
aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-frontend/commits/${pn_frontend_commitid}/pn-personafisica-webapp_${env_type}.tar.gz" \
      "pn-personafisica-webapp_${env_type}.tar.gz"

mkdir -p "pn-personafisica-webapp_${env_type}"
( cd "pn-personafisica-webapp_${env_type}" \
     && tar xvzf "../pn-personafisica-webapp_${env_type}.tar.gz" \
)

aws ${aws_command_base_args} \
    s3 cp "pn-personafisica-webapp_${env_type}" "s3://${webappPfBucketName}/" \
      --recursive


echo ""
echo "===                       PORTALE PF LOGIN                        ==="
echo "====================================================================="
aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-frontend/commits/${pn_frontend_commitid}/pn-personafisica-login_${env_type}.tar.gz" \
      "pn-personafisica-login_${env_type}.tar.gz"

mkdir -p "pn-personafisica-login_${env_type}"
( cd "pn-personafisica-login_${env_type}" \
     && tar xvzf "../pn-personafisica-login_${env_type}.tar.gz" \
)

aws ${aws_command_base_args} \
    s3 cp "pn-personafisica-login_${env_type}" "s3://${webappPflBucketName}/" \
      --recursive




echo ""
echo "===                          SITO LANDING                         ==="
echo "====================================================================="
aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
      --bucket "$LambdasBucketName" --key "pn-frontend/commits/${pn_frontend_commitid}/pn-landing-webapp_${env_type}.tar.gz" \
      "pn-landing-webapp_${env_type}.tar.gz"

mkdir -p "pn-landing-webapp_${env_type}"
( cd "pn-landing-webapp_${env_type}" \
     && tar xvzf "../pn-landing-webapp_${env_type}.tar.gz" \
)

aws ${aws_command_base_args} \
    s3 cp "pn-landing-webapp_${env_type}" "s3://${landingBucketName}/" \
      --recursive
