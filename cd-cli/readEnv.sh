#!/usr/bin/env bash
    
set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
custom_config_dir="${script_dir}/custom-config"

usage() {
      cat <<EOF
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> 
    
    [-h]                           : this help message
    [-v]                           : verbose mode
    [-p <aws-profile>]             : aws cli profile (optional)
    -r <aws-region>                : aws region as eu-south-1
    -e <env-type>                  : one of dev / uat / svil / coll / cert / prod
EOF
  exit 1
}
parse_params() {
  # default values of variables set from params
  project_name=pn
  aws_profile=""
  aws_region=""
  env_type=""
  
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
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${env_type-}" ]] && usage 
  [[ -z "${aws_region-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:       ${project_name}"
  echo "Env Name:           ${env_type}"
  echo "AWS region:         ${aws_region}"
  echo "AWS profile:        ${aws_profile}"
}


# START SCRIPT

parse_params "$@"
dump_params

aws_base_args=""
if ( [ ! -z "${aws_profile}" ]) then
  aws_base_args="${aws_base_args} --profile ${aws_profile}"
fi

if ( [ ! -z "${aws_region}" ]) then
  aws_base_args="${aws_base_args} --region ${aws_region}"
fi


ALL_VERSIONS=""

echo ""
echo ""
echo "=== VERSIONI RICHIESTE DAI MICROSERVIZI ==="
echo "==========================================="

stacks="pn-ipc-${env_type} \
        pn-auth-fleet-microsvc-${env_type} \
        pn-delivery-microsvc-${env_type} \
        pn-delivery-push-microsvc-${env_type} \
        pn-user-attributes-microsvc-${env_type}
        pn-mandate-microsvc-${env_type}
        pn-data-vault-microsvc-${env_type}
        pn-external-registries-microsvc-${env_type}
      " 
for stack in $( echo $stacks ) ; do
  version=$( aws ${aws_base_args} cloudformation describe-stacks --stack-name ${stack} \
      | jq -r '.Stacks[0].Parameters | .[] | select(.ParameterKey=="Version") | .ParameterValue' )
  
  echo ""
  echo " - Stack $stack Version:"
  normalizedVersions=$( echo "${version}" | tr "," "\n" \
       | sed -e 's/^pn-delivery=/pn_delivery_commitId=/' \
       | sed -e 's/^pn-delivery-push=/pn_delivery_push_commitId=/' \
       | sed -e 's/^pn-user-attributes=/pn_UserAttributes_commitId=/' \
       | sed -e 's/^pn-mandate=/pn_mandate_commitId=/' \
       | sed -e 's/^pn-data-vault=/pn_data_vault_commitId=/' \
       | sed -e 's/^pn-external-registries=/pn_ExternalRegistry_commitId=/' \
    )
  echo ${normalizedVersions} | tr " " "\n"

  ALL_VERSIONS="${ALL_VERSIONS} ${normalizedVersions}"
done



ecs_cluster_arn=$( aws ${aws_base_args} \
    ecs list-clusters \
    | jq -r '.clusterArns | .[]' | grep '/pn-core-ecs-cluster' )

echo ""
echo " === Cluster ARN=${ecs_cluster_arn}"
echo " ==============================================================="

for serviceArn in $(aws ${aws_base_args}\
    ecs list-services --cluster ${ecs_cluster_arn} \
    | jq -r '.serviceArns | .[]') ; do

  echo ""
  echo " - Service: $serviceArn"
  for taskDef in $(aws ${aws_base_args} \
    ecs describe-services --cluster  ${ecs_cluster_arn} --service ${serviceArn} \
    | jq -r '.services | .[] | .deployments | .[] | .taskDefinition' ) ; do
    
    echo "   taskDef: ${taskDef}"
    imageUrl=$( aws ${aws_base_args} \
        ecs describe-task-definition --task-definition ${taskDef} \
        | jq -r '.taskDefinition | .containerDefinitions | .[] | .image' )
    
    msName=$( echo $taskDef | sed -e 's|.*/||' | sed -e 's|:.*||' | tr '-' '_')
    
    imgUrlVersionRow="${msName}_imageUrl=\"${imageUrl}\""
    echo "   IMAGE URL ${imgUrlVersionRow}"
    
    ALL_VERSIONS="${ALL_VERSIONS} ${imgUrlVersionRow}"
  done
done


echo ""
echo ""
echo ""
echo "======================================================================"
echo "===     ELENCO COMMIT ID E IMAGE URL, FARE ATTENZIONE AI DOPPI     ==="
echo "======================================================================"
echo ""
echo ""
echo $ALL_VERSIONS | tr " " "\n" | sed -e 's/^/export /' | sort 

