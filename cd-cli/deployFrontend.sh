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
pn_frontend_commitid=$4
custom_config_dir=$5

cd $work_dir

echo "=== Download pn-frontend" 
if ( [ ! -e pn-frontend ] ) then 
  git clone https://github.com/pagopa/pn-frontend.git
fi

echo ""
echo "=== Checkout pn-frontend commitId=${pn_frontend_commitid}"
( cd pn-frontend && git fetch && git checkout $pn_frontend_commitid )
echo " - copy custom config"
cp -r $custom_config_dir/pn-frontend .


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

  echo ""
  echo "=== Create CDN ${CdnName} with domain ${WebDomain} in zone ${HostedZoneId}"
  echo "     CertificateARN=${WebCertificateArn}"
  aws --profile $aws_profile --region $aws_region \
    cloudformation deploy \
      --stack-name $CdnName \
      --template-file ${script_dir}/cnf-templates/one-cdn.yaml \
      --parameter-overrides \
        Name="${CdnName}" \
        WebDomain="${WebDomain}" \
        WebCertificateArn="${WebCertificateArn}" \
        HostedZoneId="${HostedZoneId}"
  
  bucketName=$( aws --profile $aws_profile --region $aws_region \
    cloudformation describe-stacks \
      --stack-name $CdnName \
      --output json \
  | jq -r ".Stacks[0].Outputs | .[] | select( .OutputKey==\"WebAppBucketName\") | .OutputValue" )
  echo " - Created bucket name: ${bucketName}"
}

source "pn-frontend/compile_envs/${env_type}/env-cdn.sh" 

prepareOneCloudFront webapp-pa-cdn-${env_type} \
    "portale-pa.${env_type}.pn.pagopa.it" \
    "$PORTALE_PA_CERTIFICATE_ARN" \
    "$ZONE_ID"
webappPaBucketName=${bucketName}


prepareOneCloudFront webapp-pf-cdn-${env_type} \
    "portale.${env_type}.pn.pagopa.it" \
    "$PORTALE_PF_CERTIFICATE_ARN" \
    "$ZONE_ID"
webappPfBucketName=${bucketName}

prepareOneCloudFront webapp-pfl-cdn-${env_type} \
    "portale-login.${env_type}.pn.pagopa.it" \
    "$PORTALE_PF_LOGIN_CERTIFICATE_ARN" \
    "$ZONE_ID"
webappPflBucketName=${bucketName}



echo ""
echo " === Bucket Portale PA = ${webappPaBucketName}"
echo " === Bucket Portale PF = ${webappPfBucketName}"
echo " === Bucket Portale PF login = ${webappPflBucketName}"




echo ""
echo ""
echo ""
echo ""

echo "====================================================================="
echo "====================================================================="
echo "===                                                               ==="
echo "===                    COMPILAZIONE E UPLOAD                      ==="
echo "===                                                               ==="
echo "====================================================================="
echo "====================================================================="


echo ""
echo "===                          PORTALE PA                           ==="
echo "====================================================================="
source "pn-frontend/compile_envs/${env_type}/pn-pa-webapp.sh" 
( cd pn-frontend/packages/pn-pa-webapp && yarn install && yarn build )

aws --profile $aws_profile --region $aws_region \
    s3 cp pn-frontend/packages/pn-pa-webapp/build "s3://${webappPaBucketName}/" \
      --recursive

echo ""
echo "===                          PORTALE PF                           ==="
echo "====================================================================="
source "pn-frontend/compile_envs/${env_type}/pn-personafisica-webapp.sh" 
( cd pn-frontend/packages/pn-personafisica-webapp && yarn install && yarn build )

aws --profile $aws_profile --region $aws_region \
    s3 cp pn-frontend/packages/pn-personafisica-webapp/build "s3://${webappPfBucketName}/" \
      --recursive



echo ""
echo "===                       PORTALE PF LOGIN                        ==="
echo "====================================================================="
source "pn-frontend/compile_envs/${env_type}/pn-personafisica-login.sh" 
( cd pn-frontend/packages/pn-personafisica-login && yarn install && yarn build )

aws --profile $aws_profile --region $aws_region \
    s3 cp pn-frontend/packages/pn-personafisica-login/build "s3://${webappPflBucketName}/" \
      --recursive


