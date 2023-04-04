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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> -i <github-commitid> -a <account-type> [-c <custom_config_dir>]

    [-h]                      : this help message
    [-v]                      : verbose mode
    [-p <aws-profile>]        : aws cli profile (optional)
    -r <aws-region>           : aws region as eu-south-1
    -e <env-type>             : one of dev / uat / svil / coll / cert / prod
    -i <github-commitid>      : commitId for github repository pagopa/pn-infra_core or pagopa/pn-infra-confinfo
    [-c <custom_config_dir>]  : where tor read additional env-type configurations
    -a <account-type>         : account type, can be core or confinfo
    
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
    -a | --account-type) 
      account_type="${2-}"
      shift
      ;;      
    -i | --infra-commitid) 
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
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${env_type-}" ]] && usage 
  [[ -z "${pn_infra_commitid-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${pn_infra_commitid-}" ]] && usage
  [[ -z "${account_type-}" ]] && usage 
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
  echo "Account Type:      ${account_type}"
  echo "Env Name:          ${env_type}"
  echo "AWS region:        ${aws_region}"
  echo "AWS profile:       ${aws_profile}"
}


# START SCRIPT

parse_params "$@"
dump_params


cd $work_dir

## Download tfenv
echo "=== Download tfenv " 
terraform_deb_file_path=terraform-tfenv_3.0.0-1_all.deb
curl -Ls https://github.com/reegnz/terraform-tfenv-package/releases/download/v3.0.0-1/terraform-tfenv_3.0.0-1_all.deb -o ${terraform_deb_file_path}

## Tfenv checksum
echo "=== Tfenv checksum " 
calculatedChecksum=($(sha256sum ${terraform_deb_file_path}))
expectedChecksum=4f0e8b02d2787b1d3c0662a650f1603367144e1cd7caf345201e737117645f0f

if ([ $expectedChecksum != $calculatedChecksum ]) then
    echo "Checksum mismatch"
    exit 1
fi

echo "=== Tfenv install " 
sudo apt install -y ./${terraform_deb_file_path}

## Repository switch according to account type
echo "=== Repository switch according to account type " 
infra_repo="pn-infra-core"
if ([ $account_type = "confinfo"]) then
    infra_repo="pn-infra-confinfo"
fi

echo "=== Download ${infra_repo}" 
if ( [ ! -e ${infra_repo} ] ) then 
  git clone https://github.com/pagopa/${infra_repo}.git
fi

echo ""
echo "=== Checkout ${infra_repo} commitId=${pn_infra_commitid}"
( cd ${infra_repo} && git fetch && git checkout $pn_infra_commitid )


## Apply tf
(cd ${infra_repo}/src/main && ./terraform.sh init ${env_type} && ./terraform.sh apply ${env_type})

echo " - copy custom config"
if ( [ ! -z "${custom_config_dir}" ] ) then
  cp -r $custom_config_dir/pn-infra .
fi