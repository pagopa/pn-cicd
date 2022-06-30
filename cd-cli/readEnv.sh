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
    Usage: $(basename "${BASH_SOURCE[0]}") <aws-profile> <aws-region>
    
EOF
  exit
}


if ( [ $# -ne 2 ] ) then
  usage
fi


aws_profile=$1
aws_region=$2


ecs_cluster_arn=$( aws --profile $aws_profile --region $aws_region \
    ecs list-clusters \
    | jq -r '.clusterArns | .[]' | grep '/pn-core-ecs-cluster' )

echo ""
echo " === Cluster ARN=${ecs_cluster_arn}"
echo " ==============================================================="

for serviceArn in $(aws --profile $aws_profile --region $aws_region \
    ecs list-services --cluster ${ecs_cluster_arn} \
    | jq -r '.serviceArns | .[]') ; do

  echo ""
  echo " - Service: $serviceArn"
  for taskDef in $(aws --profile $aws_profile --region $aws_region \
    ecs describe-services --cluster  ${ecs_cluster_arn} --service ${serviceArn} \
    | jq -r '.services | .[] | .deployments | .[] | .taskDefinition' ) ; do
    
    echo "   taskDef: ${taskDef}"
    imageUrl=$( aws --profile $aws_profile --region $aws_region \
        ecs describe-task-definition --task-definition ${taskDef} \
        | jq -r '.taskDefinition | .containerDefinitions | .[] | .image' )
    
    msName=$( echo $taskDef | sed -e 's|.*/||' | sed -e 's|:.*||' | tr '-' '_')
    echo "   IMAGE URL ${msName}_imageUrl=\"${imageUrl}\""
  done
done


