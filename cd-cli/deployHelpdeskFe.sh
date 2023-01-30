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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] -n <microcvs-name> [-p <aws-profile>] -r <aws-region> -e <env-type> -m <pn-microsvc-github-commitid> [-c <custom_config_dir>]
    
    [-h]                             : this help message
    [-v]                             : verbose mode
    [-p <aws-profile>]               : aws cli profile (optional)
    -r <aws-region>                  : aws region as eu-south-1
    -e <env-type>                    : one of dev / uat / svil / coll / cert / prod
    -m <pn-microsvc-github-commitid> : commitId for github repository del microservizio
    [-c <custom_config_dir>]         : where tor read additional env-type configurations
    -b <artifactBucketName>          : bucket name to use as temporary artifacts storage
    -n <microcvs-name>               : nome del microservizio
    
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
  bucketName=""

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
    -n | --ms-name) 
      microcvs_name="${2-}"
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
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${env_type-}" ]] && usage 
  [[ -z "${pn_microsvc_commitid-}" ]] && usage
  [[ -z "${bucketName-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${microcvs_name-}" ]] && usage
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
  echo "Microsvc Name:       ${microcvs_name}"
  echo "Env Name:            ${env_type}"
  echo "AWS region:          ${aws_region}"
  echo "AWS profile:         ${aws_profile}"
  echo "Bucket Name:         ${bucketName}"
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


profile_option=""
if ( [ ! -z "${aws_profile}" ] ) then
  profile_option="-- profile $aws_profile"
fi
echo "Profile option ${profile_option}"


environment="${env_type}"

CognitoUserPoolId=$( aws ${profile_option} --region="eu-central-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-support-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"CognitoUserPoolId\") | .OutputValue" \
    )

CognitoWebClientId=$( aws ${profile_option} --region="eu-central-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-support-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"CognitoWebClientId\") | .OutputValue" \
    )

ApiDomain=$( aws ${profile_option} --region="eu-south-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"ApiDomain\") | .OutputValue" \
    )

cd $microcvs_name

source scripts/aws/env-${environment}.sh

sed -e "s/\${USER_POOL_ID}/${CognitoUserPoolId}/" \
    -e "s/\${WEB_CLIENT_ID}/${CognitoWebClientId}/" \
    -e "s/\${WEB_API_DOMAIN}/${WEB_API_DOMAIN}/" \
    -e "s/\${API_DOMAIN}/${ApiDomain}/"  .env.template > .env.production 

yarn install
yarn build

cd build

aws s3 sync ${profile_option} --region eu-south-1 . s3://pn-logextractor-${environment}-hosting

DistributionId=$( aws ${profile_option} --region="eu-south-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-frontend-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"DistributionId\") | .OutputValue" \
    )

DistributionDomainName=$( aws ${profile_option} --region="eu-south-1" cloudformation describe-stacks \
      --stack-name "pn-logextractor-frontend-${environment}" | jq -r \
      ".Stacks[0].Outputs | .[] | select(.OutputKey==\"DistributionDomainName\") | .OutputValue" \
    )

aws cloudfront create-invalidation ${profile_option} --region eu-south-1 --distribution-id ${DistributionId} --paths "/*"

echo "Deployed to "${DistributionDomainName}





