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
    --parameter-overrides NotificationSNSTopic=$sns_topic_arn \
    --capabilities CAPABILITY_NAMED_IAM
