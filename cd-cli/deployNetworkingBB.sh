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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> -t <terraform-env> -i <github-pn-confinfo-bb-commitid> -m <github-pn-infra-commitid> -a <account-type> -b <cd-artifact-bucket-name> [-c <custom_config_dir>]

    [-h]                                     : this help message
    [-v]                                     : verbose mode
    [-p <aws-profile>]                       : aws cli profile (optional)
    -r <aws-region>                          : aws region as eu-south-1
    -e <env-type>                            : one of dev / uat / svil / coll / cert / prod
    -t <terraform-env>                       : terraform env name
    -i <github-pn-confinfo-bb-commitid>      : commitId for github repository pagopa/pn-infra-confinfo-bb
    -m <github-pn-infra-commitid>            : commitId for github repository pagopa/pn-infra
    [-c <custom_config_dir>]                 : where tor read additional env-type configurations
    -a <account-type>                        : account type, can be core or confinfo
    -b <cd-artifact-bucket-name>             : bucket name to use as temporary artifacts storage


EOF
  exit 1
}

parse_params() {
  # default values of variables set from params
  project_name=pn
  work_dir=$HOME/tmp/
  custom_config_dir=""
  aws_profile=""
  aws_region=""
  env_type=""
  pn_infra_commitid=""
  account_type=""
  cd_artifact_bucket_name=""

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
    -t | --terraform-env) 
      terraform_env="${2-}"
      shift
      ;;
    -a | --account-type) 
      account_type="${2-}"
      shift
      ;;      
    -i | --pn-confinfo-bb-commitid) 
      pn_confinfo_bb_commitid="${2-}"
      shift
      ;;
    -m | --infra-commitid) 
      pn_infra_commitid="${2-}"
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
    -b | --cd-artifact-bucket-name) 
      cd_artifact_bucket_name="${2-}"
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
  [[ -z "${terraform_env-}" ]] && usage 
  [[ -z "${pn_confinfo_bb_commitid-}" ]] && usage
  [[ -z "${pn_infra_commitid-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${account_type-}" ]] && usage 
  [[ -z "${cd_artifact_bucket_name-}" ]] && usage 
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:                  ${project_name}"
  echo "Work directory:                ${work_dir}"
  echo "Custom config dir:             ${custom_config_dir}"
  echo "Infra Confinfo bb CommitId:    ${pn_confinfo_bb_commitid}"
  echo "Infra CommitId:                ${pn_infra_commitid}"
  echo "Account Type:                  ${account_type}"
  echo "Env Name:                      ${env_type}"
  echo "Terraform Env Name:            ${terraform_env}"
  echo "AWS region:                    ${aws_region}"
  echo "AWS profile:                   ${aws_profile}"
  echo "Artifact Bucket Name:          ${cd_artifact_bucket_name}"
}


# START SCRIPT

parse_params "$@"
dump_params


cd $work_dir

## Download tfenv
echo "=== Download tfenv " 
terraform_tarball_path="terraform-tfenv_3.0.0.tar.gz"
terraform_local_folder="tfenv-3.0.0"
curl -Ls https://github.com/tfutils/tfenv/archive/refs/tags/v3.0.0.tar.gz -o ${terraform_tarball_path}

## Tfenv checksum
echo "=== Tfenv checksum " 
calculatedChecksum=($(sha256sum ${terraform_tarball_path}))
expectedChecksum=463132e45a211fa3faf85e62fdfaa9bb746343ff1954ccbad91cae743df3b648

echo "Checksum ${calculatedChecksum}"

if ([ $expectedChecksum != $calculatedChecksum ]) then
    echo "Checksum mismatch"
    exit 1
fi

echo "=== Tfenv install " 
tar -xzf ${terraform_tarball_path}
mv ${terraform_local_folder} /usr/local/tfenv
export PATH="/usr/local/tfenv/bin:$PATH" 

## Repository switch according to account type
echo "=== Repository switch according to account type " 
infra_confinfo_bb_repo="pn-infra-confinfo-bb"
infra_repo="pn-infra"
terraform_output_prefix="ConfInfo_"

## Download pn-infra
echo "=== Download ${infra_repo}" 
if ( [ ! -e ${infra_repo} ] ) then 
  git clone https://github.com/pagopa/${infra_repo}.git
fi

echo ""
echo "=== Checkout ${infra_repo} commitId=${pn_infra_commitid}"
( cd ${infra_repo} && git fetch && git checkout $pn_infra_commitid )

## Download pn-infra-confinfo-bb
echo "=== Download ${infra_confinfo_bb_repo}" 
if ( [ ! -e ${infra_confinfo_bb_repo} ] ) then 
  git clone https://github.com/pagopa/${infra_confinfo_bb_repo}.git
fi

echo ""
echo "=== Checkout ${infra_confinfo_bb_repo} commitId=${pn_confinfo_bb_commitid}"
( cd ${infra_confinfo_bb_repo} && git fetch && git checkout $pn_confinfo_bb_commitid )

## Build diagnostic Lambda
if ( [ -f ${infra_confinfo_bb_repo}/functions/build_lambda.sh ] ) then
	( cd ${infra_confinfo_bb_repo}/functions/ && ./build_lambda.sh )
fi

## Apply tf
(cd ${infra_confinfo_bb_repo}/src/main && ./terraform.sh init ${terraform_env} && ./terraform.sh apply ${terraform_env} --auto-approve)

terraformOutputPath=terraform-${env_type}-cfg.json
terraformTmpOutputPath=terraform-${env_type}-tmp-cfg.json

## Output tf
(cd ${infra_confinfo_bb_repo}/src/main && terraform output --json ) | jq 'to_entries[]' > $terraformTmpOutputPath
jq . $terraformTmpOutputPath | jq '{ (.key | sub("'${terraform_output_prefix}'" ; "")): .value.value | (if type=="string" then . else join(",") end ) }' | jq -s 'reduce .[] as $item ({}; . *= $item )' | jq -s '{ Parameters: .[0] }' > $terraformOutputPath

echo ""
echo "= Read Terraform Output file"
cat ${terraformOutputPath} 

echo " - copy custom config"
mkdir -p $custom_config_dir/${infra_confinfo_bb_repo}
cp -p ${terraformOutputPath} $custom_config_dir/${infra_confinfo_bb_repo}/

ParamFilePath=$custom_config_dir/${infra_confinfo_bb_repo}/${terraformOutputPath}

echo ""
echo "=== Base AWS command parameters"
aws_command_base_args=""
if ( [ ! -z "${aws_profile}" ] ) then
  aws_command_base_args="${aws_command_base_args} --profile $aws_profile"
fi
if ( [ ! -z "${aws_region}" ] ) then
  aws_command_base_args="${aws_command_base_args} --region $aws_region"
fi
echo ${aws_command_base_args}

echo ""
echo "=== Deploy lambda-cloudwatch-dashboard-transform FOR $env_type ACCOUNT"
CLOUDWATCH_DASHBOARD_STACK_FILE=pn-infra/runtime-infra/fragments/lambda-cloudwatch-dashboard-transform.yaml 

echo ""
echo "= Read Parameters file"
cat ${ParamFilePath} 

if [[ -f "$CLOUDWATCH_DASHBOARD_STACK_FILE" ]]; then
    echo "$CLOUDWATCH_DASHBOARD_STACK_FILE exists, updating monitoring stack"

    aws ${aws_command_base_args} \
        cloudformation deploy \
          --stack-name lambda-cloudwatch-dashboard-transform-$env_type \
          --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
          --s3-bucket $cd_artifact_bucket_name \
          --template-file ${CLOUDWATCH_DASHBOARD_STACK_FILE} \
          --tags Microservice=lambda-cloudwatch-dashboard-transform 

else
  echo "microservice-cloudwatch-dashboard file doesn't exist, stack update skipped"
fi

