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
        AllowedDeployAccount16=089813480515 \
        AllowedDeployAccount17=830192246553 \
        AllowedDeployAccount18=956319218727 \
        AllowedDeployAccount19=644374009812 \
        AllowedDeployAccount20=510769970275 \
        AllowedDeployAccount20=089813480515 \
        AllowedDeployAccount21=644374009812 \
        AllowedDeployAccount22=956319218727 \
        AllowedDeployAccount23=510769970275 \
        AllowedDeployAccount24=350578575906 \
        AllowedDeployAccount25=911845998067 \
        AllowedDeployAccount26=911845998067 \
        AllowedDeployAccount27=911845998067 \
        AllowedDeployAccount28=911845998067 \
        AllowedDeployAccount29=911845998067 \
        AllowedDeployAccount30=911845998067

fi