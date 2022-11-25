#!/usr/bin/env bash -e

if ( [ $# -ne 2 ] ) then
  echo "Usage: $0 <cicd-profile> <aws-region>"
  echo "<cicd-profile>: AWS connection profile for cicd account"
  echo "<aws-region>: AWS region to deploy the CI stacks"

  if ( [ "$BASH_SOURCE" = "" ] ) then
    return 1
  else
    exit 1
  fi
fi

scriptDir=$( dirname "$0" )

CiCdAccountProfile=$1
AWSRegion=$2

echo "Create notifications topic"
aws --profile $CiCdAccountProfile --region $AWSRegion cloudformation deploy \
    --stack-name cicd-pipeline-notification-sns-topic \
    --template-file ${scriptDir}/bootstrap/pipeline-notification-sns-topic.yaml \
    --capabilities CAPABILITY_NAMED_IAM 

get_sns_topic_command="aws cloudformation describe-stacks --stack-name cicd-pipeline-notification-sns-topic --profile $CiCdAccountProfile --region $AWSRegion --query \"Stacks[0].Outputs[?OutputKey=='NotificationSNSTopicArn'].OutputValue\" --output text"
sns_topic_arn=$(eval $get_sns_topic_command)
echo "Got sns topic ARN: $sns_topic_arn"

echo "Deploy CI pipeline"
aws --profile $CiCdAccountProfile --region $AWSRegion cloudformation deploy \
    --stack-name pn-ci-pipeline \
    --template-file ${scriptDir}/bootstrap/pn-ci-pipeline.yaml  \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      NotificationSNSTopic=$sns_topic_arn \
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
      AllowedDeployAccount18=118759374619

