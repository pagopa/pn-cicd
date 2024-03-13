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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> -i <hubspid-github-commitid> [-c <custom_config_dir>] -b <artifactBucketName> -B <lambdaArtifactBucketName>
    
    
    [-h]                           : this help message
    [-v]                           : verbose mode
    [-p <aws-profile>]             : aws cli profile (optional)
    -r <aws-region>                : aws region as eu-south-1
    -e <env-type>                  : one of dev / uat / svil / coll / cert / prod
    -i <spidhub_commitid>          : commitId for github repository pagopa/pn-hub-spid-login-aws
    [-c <custom_config_dir>]       : where tor read additional env-type configurations
    -b <artifactBucketName>        : bucket name to use as temporary artifacts storage
EOF
  exit 1
}
parse_params() {
  # default values of variables set from params
  project_name=spidhub
  work_dir=$HOME/tmp/spidhub_deploy
  custom_config_dir=""
  aws_profile=""
  aws_region=""
  env_type=""
  spidhub_commitid=""
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
    -i | --spidhub-commitid)
      spidhub_commitid="${2-}"
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
  [[ -z "${spidhub_commitid-}" ]] && usage
  [[ -z "${bucketName-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:       ${project_name}"
  echo "Work directory:     ${work_dir}"
  echo "Custom config dir:  ${custom_config_dir}"
  echo "Spid hub CommitId:  ${spidhub_commitid}"
  echo "Env Name:           ${env_type}"
  echo "AWS region:         ${aws_region}"
  echo "AWS profile:        ${aws_profile}"
  echo "Bucket Name:        ${bucketName}"
}


# START SCRIPT

parse_params "$@"
dump_params

cd "$work_dir"

echo "=== Download pn-hub-spid-login-aws"
if [ ! -e pn-hub-spid-login-aws ]; then
  git clone https://github.com/pagopa/pn-hub-spid-login-aws.git
fi

echo ""
echo "=== Checkout pn-hub-spid-login-aws commitId=${spidhub_commitid}"
( cd pn-hub-spid-login-aws && git fetch && git checkout "${spidhub_commitid}" )
echo " - copy custom config"
if [ -n "${custom_config_dir}" ]; then
  cp -r "$custom_config_dir/pn-hub-spid-login-aws" .
fi

echo ""
echo "=== Base AWS command parameters"
aws_command_base_args=""
if [ -n "${aws_profile}" ]; then
  aws_command_base_args="${aws_command_base_args} --profile $aws_profile"
fi
if [ -n "${aws_region}" ]; then
  aws_command_base_args="${aws_command_base_args} --region $aws_region"
fi
echo "${aws_command_base_args}"

echo ""
echo ""
echo ""
echo "======================================================================="
echo "======================================================================="
echo "===                                                                 ==="
echo "===              SPIDHUB MICROSERVICE DEPLOYMENT                    ==="
echo "===                                                                 ==="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo ""
echo "=== Prepare parameters for spidhub microservice deployment in $env_type ACCOUNT"


BucketName=$(cat "./environments/$env_type/params.json" \
  | jq -r ".Parameters.Storage")

echo "Bucket Name: ${BucketName}"

STACK_NAME=$project_name
PACKAGE_PREFIX=package
PACKAGE_BUCKET=$BucketName

secretPresent=$( aws "${aws_command_base_args}" \
  secretsmanager list-secrets \
  --max-items 100 \
  | jq -r ".SecretList | .[] | select(.Name==\"$project_name-$env_type-hub-login\")" | wc -l )

logSecretPresent=$( aws "${aws_command_base_args}" \
  secretsmanager list-secrets \
  --max-items 100 \
  | jq -r ".SecretList | .[] | select(.Name==\"$project_name-$env_type-hub-login-logs\")" | wc -l )

cacheSecretPresent=$( aws "${aws_command_base_args}" \
  secretsmanager list-secrets \
  --max-items 100 \
  | jq -r ".SecretList | .[] | select(.Name==\"$project_name-$env_type-cache\")" | wc -l )

if [ "$cacheSecretPresent" -eq 0 ]; then
  echo "Warning: the secret $project_name-$env_type-cache doesn't exist, please insert it"
  exit 1
else
  UserRegistryApiKey=$(aws ${aws_command_base_args} \
      secretsmanager get-secret-value \
      --no-paginate \
      --secret-id $project_name-$env_type-cache \
      --query SecretString --output text | jq -r .AuthToken)
fi

hubLoginEnvFile="./environments/$env_type/storage/config/hub-login/v1/.env"
if [ $secretPresent -eq 0 ]; then
  mkdir -p "./environments/$env_type/certs"

  openssl req -nodes -new -x509 -sha256 -days 365 -newkey rsa:2048 \
    -subj "/C=IT/ST=State/L=City/O=Acme Inc. /OU=IT Department/CN=hub-spid-login-ms" \
    -keyout "./environments/$env_type/certs/key.pem" \
    -out "./environments/$env_type/certs/cert.pem"

  mkdir -p "./environments/$env_type/jwt"
  mkdir -p "./environments/$env_type/logs"

  openssl genrsa -out "./environments/$env_type/jwt/jwt_rsa_key.pem" 2048
  openssl rsa -in "./environments/$env_type/jwt/jwt_rsa_key.pem" \
    -outform PEM -pubout -out "./environments/$env_type/jwt/jwt_rsa_public.pem"

  openssl genrsa -out "./environments/$env_type/logs/logs_rsa_key.pem" 2048
  openssl rsa -in "./environments/$env_type/logs/logs_rsa_key.pem" \
    -outform PEM -pubout -out "./environments/$env_type/logs/logs_rsa_public.pem"

  MakecertPrivate=$( sed -e 's/$/\\n/' "./environments/$env_type/certs/key.pem" | tr -d '\n' | sed -e 's/\\n$//')
  MakecertPublic=$( sed -e 's/$/\\n/' "./environments/$env_type/certs/cert.pem" | tr -d '\n' | sed -e 's/\\n$//' )
  JwtTokenPrivateKey=$( sed -e 's/$/\\n/' "./environments/$env_type/jwt/jwt_rsa_key.pem" | tr -d '\n' | sed -e 's/\\n$//' )
  Jwks=$(docker run -i --rm danedmunds/pem-to-jwk:latest --jwks-out < "./environments/$env_type/jwt/jwt_rsa_public.pem")
  Kid=$(echo "$Jwks" | jq -r '.keys[0].kid')
  LogsPublicKey=$( sed -e 's/$/\\n/' "./environments/$env_type/logs/logs_rsa_public.pem" | tr -d '\n' | sed -e 's/\\n$//' )

  sed -i'.tmp' -e "/^JWT_TOKEN_KID=/s/=.*/=$Kid/" "$hubLoginEnvFile"

  SecretString=$(echo "{\"MakecertPrivate\":\"$MakecertPrivate\",\"MakecertPublic\":\"$MakecertPublic\",\"JwtTokenPrivateKey\":\"$JwtTokenPrivateKey\",\"UserRegistryApiKey\":\"$UserRegistryApiKey\",\"LogsPublicKey\":\"$LogsPublicKey\"}" | jq --arg v "$Jwks" '. + {"Jwks":$v}')

  aws ${aws_command_base_args} \
    secretsmanager create-secret \
    --name $project_name-$env_type-hub-login \
    --secret-string "$SecretString"

  # set private key to decrypt logs in a specific secret
  LogsPrivateKey=$( sed -e 's/$/\\n/' "./environments/$env_type/logs/logs_rsa_key.pem" | tr -d '\n' | sed -e 's/\\n$//' )
  LogsSecretString=$(echo "{\"LogsPrivateKey\":\"$LogsPrivateKey\"}")

  aws "${aws_command_base_args}" \
    secretsmanager create-secret \
    --name "$project_name-$env_type-hub-login-logs" \
    --secret-string "$SecretString"

else
  if [ "$logSecretPresent" -eq 0 ]; then
    echo "Warning: the secret $project_name-$env_type-hub-login-logs doesn't exist, please create it using generate-logs-keys.sh script"
    exit 1
  fi

  Kid=$(aws "${aws_command_base_args}" \
    secretsmanager get-secret-value \
    --no-paginate \
    --secret-id $project_name-$env_type-hub-login \
    --query SecretString --output text |  jq -r .Jwks | jq -r '.keys[0].kid')
  sed -i'.tmp' -e "/^JWT_TOKEN_KID=/s/=.*/=$Kid/" "$hubLoginEnvFile"
fi

aws ${aws_command_base_args} \
  cloudformation deploy \
  --template-file "./stacks/storage.yaml" \
  --stack-name "$project_name-$env_type-storage" \
  --parameter-overrides Project=$project_name Environment="$env_type" BucketName="$BucketName" \
  --tags Project=$project_name Environment="$env_type" \
  --no-fail-on-empty-changeset


aws "${aws_command_base_args}" \
  s3 sync \
  "./environments/$env_type/storage/" \
  "s3://$PACKAGE_BUCKET/" \
  --delete

alarmName=""

SkipAlarmTopic=$(cat "./environments/$env_type/params.json" | jq -r '.Parameters.SkipAlarmTopic' )

if [ "$SkipAlarmTopic" = "true" ]; then
  alarmName=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
    --stack-name "once-$env_type" \
    | jq -r '.Stacks[0].Outputs | .[] | select ( .OutputKey=="AlarmSNSTopicName") | .OutputValue' \
  )
else
  aws "${aws_command_base_args}" \
    cloudformation deploy \
    --stack-name "$project_name-$env_type-alarm" \
    --tags Project=$project_name Environment=$env_type \
    --template-file "./stacks/alarm-topic/$env_type.yaml" \

  alarmName=$( aws ${aws_command_base_args} \
    cloudformation describe-stacks \
    --stack-name "$project_name-$env_type-alarm" \
    | jq -r '.Stacks[0].Outputs | .[] | select ( .OutputKey=="AlarmSNSTopicName") | .OutputValue' \
  )
fi

echo ""
echo ""
echo "=== Alarm Name: ${alarmName}"
cat "./environments/$env_type/params.json" \
    | jq ".Parameters.AlarmSNSTopicName = \"${alarmName}\"" \
    | tee "./environments/$env_type/params-enanched.json.tmp"

aws "${aws_command_base_args}"
  cloudformation package \
  --template-file "./$STACK_NAME.yaml" \
  --output-template-file "./$STACK_NAME.tmp" \
  --s3-bucket "$PACKAGE_BUCKET" \
  --s3-prefix "$PACKAGE_PREFIX"

aws "${aws_command_base_args}" \
  cloudformation deploy \
  --stack-name "$project_name-$env_type" \
  --parameter-overrides "file://environments/$env_type/params-enanched.json.tmp" \
  --tags Project=$project_name Environment="$env_type" \
  --template-file "./$STACK_NAME.tmp" \
  --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
  --no-fail-on-empty-changeset

