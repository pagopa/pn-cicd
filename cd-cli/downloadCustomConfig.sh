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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> [-s <cfgRepositorySecretName>]

    [-h]                           : this help message
    [-v]                           : verbose mode
    [-p <aws-profile>]             : aws cli profile (optional)
    -r <aws-region>                : aws region as eu-south-1
    -e <env-type>                  : one of dev / uat / svil / coll / cert / prod
    [-s <cfgRepositorySecretName>] : nome del secret che contiene le informazioni per effettuare
                                     il download delle configurazioni specifiche dell'ambiente
    
    
EOF
  exit 1
}

parse_params() {
  # default values of variables set from params
  work_dir=$HOME/tmp/poste_deploy
  project_name=pn
  aws_profile=""
  aws_region=""
  env_type=""
  configuration_repository_secret_name="pn-configurations-repository"

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
    -s | --secret-name) 
      configuration_repository_secret_name="${2-}"
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
  [[ -z "${configuration_repository_secret_name-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:      ${project_name}"
  echo "Work directory:    ${work_dir}"
  echo "Env Name:          ${env_type}"
  echo "AWS region:        ${aws_region}"
  echo "AWS profile:       ${aws_profile}"
  echo "Configuration Repository Informations contained into Secret: ${configuration_repository_secret_name}"
}


# START SCRIPT

parse_params "$@"
dump_params


cd $work_dir

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


if ( [ ! -z "${configuration_repository_secret_name}" ] ) then 
  secretPresent=$( aws ${aws_command_base_args} secretsmanager list-secrets \
    --filter Key="name",Values="${configuration_repository_secret_name}" \
    | jq '.SecretList | length ' )

  if ( [ "$secretPresent" -eq "1" ]) then

    echo "=== Retrieve configuration repository informations" 
    aws ${aws_command_base_args} secretsmanager get-secret-value \
        --secret-id pn-configurations-repository \
        --output text --query 'SecretString' > ./secret-config-repo.json
    commit_id=$( cat ./secret-config-repo.json | jq -r '.commitId' )
    echo "Commit id: ${commit_id}"

    git clone $( cat ./secret-config-repo.json | jq -r '.repositoryUrl' ) custom-config
    ( cd custom-config && git fetch && git checkout -c advice.detachedHead=false $commit_id )
    touch custom-config/empty.txt
    rm ./secret-config-repo.json
  else 
    echo "=== Secret $configuration_repository_secret_name not found"
    mkdir custom-config
    touch custom-config/empty.txt
  fi
else 
  echo "=== Nothing to do!!" 
  mkdir custom-config
  touch custom-config/empty.txt
fi
