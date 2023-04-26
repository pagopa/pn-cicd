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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> [-s <cfgRepositorySecretName>] [-c <PnConfigurationTag>]

    [-h]                           : this help message
    [-v]                           : verbose mode
    [-p <aws-profile>]             : aws cli profile (optional)
    -r <aws-region>                : aws region as eu-south-1
    -e <env-type>                  : one of dev / uat / svil / coll / cert / prod
    [-s <cfgRepositorySecretName>] : nome del secret che contiene le informazioni per effettuare
                                     il download delle configurazioni specifiche dell'ambiente
    [-c <PnConfigurationTag>]      : a partire dal file repository-list.json nel repo pn-configuration 
                                     costruisce il file desiredCommitIds.sh
    
    
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

PN_CONFIGURATION_TAG_param=""
SUB1=tag

if ( [ ! -z "${PN_CONFIGURATION_TAG}"  ] ) ; then
  PN_CONFIGURATION_TAG_param=""
  SUB1=tag
  echo PN_CONFIGURATION_TAG is present. 
  touch desiredCommitIds.sh
  #List Components form PN-CONFIGURATION:
  for PN_CONFIGURATION_TAG_param in $(curl -s https://raw.githubusercontent.com/pagopa/pn-configuration/$PN_CONFIGURATION_TAG/repository-list.json  |  jq 'keys_unsorted'  | grep -E "Id|Url" | sed -E 's/"//g' | sed -E 's/,//g' | sed -E 's/ //g');do
  #List of CommitsIds (tag or branch):
  PN_COMMIT=$(echo "$( curl -s https://raw.githubusercontent.com/pagopa/pn-configuration/$PN_CONFIGURATION_TAG/repository-list.json | jq -r '.'\"$PN_CONFIGURATION_TAG_param\"'' )") ;

  #ONLY FOR TEST,
  #for PN_CONFIGURATION_TAG_param in $(cat example.json |  jq 'keys_unsorted'  | grep -E "Id|Url" | sed -E 's/"//g' | sed -E 's/,//g' | sed -E 's/ //g'); do
  #PN_COMMIT=$(echo "$( cat example.json | jq -r '.'\"$PN_CONFIGURATION_TAG_param\"'' )"); 
  #END TEST

  #ImageURL and Commit
  LineNum=$(echo $PN_COMMIT | wc -c)
  if [ 40 -le "$LineNum" ] ; then
  echo "CommitID or ImageUrl is present $PN_CONFIGURATION_TAG_param";
  echo "export $PN_CONFIGURATION_TAG_param=$PN_COMMIT" >> desiredCommitIds.sh

  #TAG:
  elif grep -q "$SUB1" <<< "$PN_COMMIT"; then
  echo "TAG is present for $PN_CONFIGURATION_TAG_param";
  #take only tag es: v1.0.0:
  TAG=$(echo $PN_COMMIT | cut -d "/" -f 2)
  #declare variable for repo:
  REPO=$(echo $PN_CONFIGURATION_TAG_param | sed -E 's/_commitId//g' | sed -E 's/_/-/g')
  PN_COMMIT_ID=$(echo "$( curl -L -s  \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/pagopa/$REPO/tags | jq '.[] | select(.name=='\"$TAG\"') ' |  jq -r '.commit.sha' )") ;
  echo "export $PN_CONFIGURATION_TAG_param=$PN_COMMIT_ID" >> desiredCommitIds.sh

  #BRANCH
  else
   echo "BRANCH is present for $PN_CONFIGURATION_TAG_param";
  #declare variable for repo:
  REPO=$(echo $PN_CONFIGURATION_TAG_param | sed -E 's/_commitId//g' | sed -E 's/_/-/g')
  PN_COMMIT_ID=$(echo "$( curl -L -s \
  -H "Accept: application/vnd.github+json" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  https://api.github.com/repos/pagopa/$REPO/branches/$PN_COMMIT |  jq -r '.commit.sha' )") ;
  echo "export $PN_CONFIGURATION_TAG_param=$PN_COMMIT_ID" >> desiredCommitIds.sh
  fi
  done
  echo export completed
  else
  echo "nothing to do"
fi