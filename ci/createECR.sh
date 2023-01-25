#!/usr/bin/env bash

if ( [ $# -ne 3 ] ) then
  echo "Usage: $0 <cicd-profile> <aws-region> <ECR-name>"
  echo "<cicd-profile>: AWS connection profile for cicd account"
  echo "<aws-region>: AWS region to deploy the CI stacks"
  echo ""
  echo "Sample: $0 cicd eu-central-1 pn-delivery"

  if ( [ "$BASH_SOURCE" = "" ] ) then
    return 1
  else
    exit 1
  fi
fi

scriptDir=$( dirname "$0" )

CiCdAccountProfile=$1
AWSRegion=$2
RepoName=$3
REPO_ID=$(aws --profile $CiCdAccountProfile --region $AWSRegion ecr describe-repositories --repository-names $RepoName --query 'repositories[] .registryId' 2 >/dev/null)
if [ $REPO_ID ]; then
  echo "ECR $RepoName already exists with id: $REPO_ID"
else
  aws --profile $CiCdAccountProfile --region $AWSRegion cloudformation deploy \
      --stack-name ecr-$RepoName \
      --capabilities CAPABILITY_NAMED_IAM \
      --template-file infra/ecr.yaml \
      --parameter-overrides \
        EcrName=$RepoName \
        AllowedDeployAccount1=558518206506 \
        AllowedDeployAccount2=946373734005 \
        AllowedDeployAccount3=498209326947 \
        AllowedDeployAccount4=748275689270 \
        AllowedDeployAccount5=153517439884 \
        AllowedDeployAccount6=648024184569 \
        AllowedDeployAccount7=615714398925 \
        AllowedDeployAccount8=205069730074 \
        AllowedDeployAccount9=648535372866 \
        AllowedDeployAccount10=734487133479 \
        AllowedDeployAccount11=603228414473 \
        AllowedDeployAccount12=911845998067 \
        AllowedDeployAccount13=804103868123 \
        AllowedDeployAccount14=118759374619 \
        AllowedDeployAccount15=063295570123 \
        AllowedDeployAccount16=118759374619 \
        AllowedDeployAccount17=118759374619 \
        AllowedDeployAccount18=118759374619 \
        AllowedDeployAccount19=118759374619 \
        AllowedDeployAccount20=118759374619
fi