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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> [-s <cfgRepositorySecretName>] [-c <PnConfigurationTag>] [-i <CiCdAccountId>]

    [-h]                           : this help message
    [-v]                           : verbose mode
    [-p <aws-profile>]             : aws cli profile (optional)
    -r <aws-region>                : aws region as eu-south-1
    -e <env-type>                  : one of dev / uat / svil / coll / cert / prod
    [-s <cfgRepositorySecretName>] : nome del secret che contiene le informazioni per effettuare
                                     il download delle configurazioni specifiche dell'ambiente
    [-c <PnConfigurationTag>]      : a partire dal file repository-list.json nel repo pn-configuration 
                                     costruisce il file desiredCommitIds.sh
    [-i <CiCdAccountId>]            : CICD Account Id
    
    
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
  PN_CONFIGURATION_TAG=""
  cicd_account_id=""

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
    -c | --configuration) 
      PN_CONFIGURATION_TAG="${2-}"
      shift
      ;;
    -i | --cicd) 
      cicd_account_id="${2-}"
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
  echo "Configuration CommitIds: ${PN_CONFIGURATION_TAG}"
  echo "CICD Account ID:   ${cicd_account_id}"
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

aws_cicd_command_base_args=""
if ( [ ! -z "${aws_profile}" ] ) then
  aws_cicd_command_base_args="${aws_cicd_command_base_args} --profile $aws_profile"
fi
echo "CICD command ${aws_cicd_command_base_args}"

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
    ( cd custom-config && git fetch && git checkout $commit_id )
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


_clone_repository(){
  
  _DEPLOYKEY="deploykey/pn-configuration"
  
  echo " - try to download ssh deploykey $_DEPLOYKEY"
  _AWSDEPLOYKEYEXIST=$(aws ${aws_command_base_args} \
    secretsmanager list-secrets | \
    jq --arg keyname $_DEPLOYKEY  -c '.SecretList[] | select( .Name == $keyname )' )
  
  _GITURI="https://github.com/pagopa/pn-configuration.git"

  if ( [ -z "${_AWSDEPLOYKEYEXIST}" ] ); then    
    echo " - sshkey $_DEPLOYKEY not found - git clone via HTTPS"
  else
    echo " - sshkey $_DEPLOYKEY found - git clone via SSH"
    mkdir -p ~/.ssh
    _AWSDEPLOYKEY=$(aws ${aws_command_base_args} \
    secretsmanager get-secret-value --secret-id $_DEPLOYKEY --output json )
    echo $_AWSDEPLOYKEY | jq '.SecretString' | cut -d "\"" -f 2 | sed 's/\\n/\n/g' > ~/.ssh/id_rsa
    chmod 400 ~/.ssh/id_rsa
    _GITURI="git@github.com:pagopa/pn-configuration.git"
  fi

  git clone ${_GITURI}

  (cd pn-configuration && git reflog -n 10)
}

if ( [ ! -z "${PN_CONFIGURATION_TAG}" -a ! -z "${cicd_account_id}" ] ) ; then
  echo PN_CONFIGURATION_TAG is present. 
  PN_CONFIGURATION_TAG_param=""
  SUB1=tag
  SUB2=amazonaws
  SUB3=sha256
  #retrive secret:
  GITHUB_TOKEN=$(aws ${aws_command_base_args} secretsmanager get-secret-value --secret-id github-token --query SecretString --output text)

  #check if GitHub token is not null:
  if [ -z "$GITHUB_TOKEN" ]; then
      echo "****   WARNING: GitHub token not retrieved or is empty. Continuing without authentication.   ****"
      USE_TOKEN=false
  else
      echo "****   INFO: GitHub token retrieved successfully. Using authentication Token.   ****"
      USE_TOKEN=true
  fi
  
  #Function for Github request:
  github_request() {
      #Local variables, take the first value passed to fuction:
      local url=$1
      local response
      local http_code

      if $USE_TOKEN; then
          response=$(curl -s -w "%{http_code}" -o response.json -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" -H "Authorization: Bearer $GITHUB_TOKEN" "$url")
          http_code=$(tail -n1 <<< "$response")

          #Check if token is invalid or expired and print a Warning with the http code error:
          if [ "$http_code" -ne 200 ]; then
              echo "****   WARNING: GitHub token is expired or invalid, because the request for check failed with HTTP status code $http_code. CHECK TOKEN!!! CONTINUING THE SCRIPT WITHOUT AUTH.   ****"
              USE_TOKEN=false
              github_request "$url"
              return
          fi
      else
          #Go to GitHub without Auth:
          response=$(curl -s -w "%{http_code}" -o response.json -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" "$url")
          http_code=$(tail -n1 <<< "$response")
      fi

      #If script failed exit from immediately:
      if [ "$http_code" -ne 200 ]; then
          echo "****   ERROR: GitHub request not authetincated failed with HTTP status code $http_code error response. Exit from script.   ****"
          echo "****   EXPORT IS NOT COMPLETED   ****"
          exit 1
      fi
  }

  #cloning git repository and change directory:
  _clone_repository
  
  echo "****   EXPORT COMPLETED   ****"

  mkdir -p parameters
  cp -r pn-configuration/${env_type}/ parameters/${env_type}

else
  echo "nothing to do"
fi