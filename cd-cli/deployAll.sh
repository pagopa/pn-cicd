#!/usr/bin/env bash
    
set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
custom_config_dir="${script_dir}/custom-config"
desired_commit_id_dir="${script_dir}/envs_desired_versions"

usage() {
      cat <<EOF
    Usage: $(basename "${BASH_SOURCE[0]}") [-p <aws-profile>] -r <aws-region> -e <env-type> [-c <custom_config_dir>] -b <artifactBucketName> -B <lambdaArtifactBucketName>
   
    [-h]                           : this help message
    [-v]                           : verbose mode
    [-p <aws-profile>]             : aws cli profile (optional)
    -r <aws-region>                : aws region as eu-south-1
    -e <env-type>                  : one of dev / uat / svil / coll / cert / prod
    [-c <custom_config_dir>]       : where tor read additional env-type configurations
    -b <artifactBucketName>        : bucket name to use as temporary artifacts storage
    -B <lambdaArtifactBucketName>  : bucket name where lambda artifact are memorized
    [-w <work_dir>]                : work directory
EOF
  exit 1
}
parse_params() {
  # default values of variables set from params
  project_name=pn
  work_dir=$HOME/tmp/poste_deploy
  aws_profile=""
  aws_region=""
  env_type=""
  pn_infra_commitid=""
  pn_authfleet_commitid=""
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
  [[ -z "${bucketName-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${LambdasBucketName-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:       ${project_name}"
  echo "Work directory:     ${work_dir}"
  echo "Custom config dir:  ${custom_config_dir}"
  echo "Env Name:           ${env_type}"
  echo "AWS region:         ${aws_region}"
  echo "AWS profile:        ${aws_profile}"
  echo "Bucket Name:        ${bucketName}"
  echo "Lambda Bucket Name: ${LambdasBucketName}"
}


# START SCRIPT

parse_params "$@"
dump_params

if ( [ -z "$aws_profile" ] ) then
  aws_profile_param=""
else
  aws_profile_param="-p $aws_profile"
fi
source "${desired_commit_id_dir}/${env_type}/desired-commit-ids-env.sh"



./deployInfra.sh $aws_profile_param \
      -r $aws_region -e $env_type -i $pn_infra_commitId \
      -b $bucketName -w $work_dir -c $custom_config_dir 

./deployAuthFleet.sh $aws_profile_param \
      -r $aws_region -e $env_type -i $pn_infra_commitId \
      -a $pn_authfleet_commitId -B $LambdasBucketName \
      -b $bucketName -w $work_dir -c $custom_config_dir 




./deployEcsService.sh $aws_profile_param \
      -n pn-delivery -N 1 \
      -r $aws_region -e $env_type -i $pn_infra_commitId \
      -m $pn_delivery_commitId -I $pn_delivery_imageUrl \
      -b $bucketName -w $work_dir -c $custom_config_dir 

./deployEcsService.sh $aws_profile_param \
      -n pn-delivery-push -N 2 \
      -r $aws_region -e $env_type -i $pn_infra_commitId \
      -m $pn_delivery_push_commitId -I $pn_delivery_push_imageUrl \
      -b $bucketName -w $work_dir -c $custom_config_dir 

./deployEcsService.sh $aws_profile_param \
      -n pn-mandate -N 4 \
      -r $aws_region -e $env_type -i $pn_infra_commitId \
      -m $pn_mandate_commitId -I $pn_mandate_imageUrl \
      -b $bucketName -w $work_dir -c $custom_config_dir 

./deployEcsService.sh $aws_profile_param \
      -n pn-data-vault -N 5 \
      -r $aws_region -e $env_type -i $pn_infra_commitId \
      -m $pn_data_vault_commitId -I $pn_data_vault_imageUrl \
      -b $bucketName -w $work_dir -c $custom_config_dir 

./deployEcsService.sh $aws_profile_param \
      -n pn-external-registries -N 6 \
      -r $aws_region -e $env_type -i $pn_infra_commitId \
      -m $pn_external_registries_commitId -I $pn_external_registries_imageUrl \
      -b $bucketName -w $work_dir -c $custom_config_dir 

./deployEcsService.sh $aws_profile_param \
      -n pn-user-attributes -N 7 \
      -r $aws_region -e $env_type -i $pn_infra_commitId \
      -m $pn_user_attributes_commitId -I $pn_user_attributes_imageUrl \
      -b $bucketName -w $work_dir -c $custom_config_dir 



./deployFrontend.sh $aws_profile_param \
      -r $aws_region -e $env_type -i $pn_infra_commitId \
      -f $pn_frontend_commitId -B $LambdasBucketName \
      -b $bucketName -w $work_dir -c $custom_config_dir


./deployShowcaseSite.sh $aws_profile_param \
      -r $aws_region -e $env_type -i $pn_infra_commitId \
      -f $pn_showcase_site_commitId -B $LambdasBucketName \
      -b $bucketName -w $work_dir -c $custom_config_dir 
