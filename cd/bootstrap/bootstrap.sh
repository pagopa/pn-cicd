#!/usr/bin/env bash -e


CiCdProfile=cicd
CiCdAccount=$(aws sts get-caller-identity --profile $CiCdProfile | jq -r .UserId)
BetaProfile=beta
BetaAccount=$(aws sts get-caller-identity --profile $BetaProfile | jq -r .UserId)
ProdProfile=prod
ProdAccount=$(aws sts get-caller-identity --profile $ProdProfile | jq -r .UserId)


echo "Deploying pre-requisite stack to the ci cd account... "
aws cloudformation deploy --stack-name pre-reqs --template-file pre-reqs.yaml --parameter-overrides BetaAccount="$BetaAccount" ProductionAccount="$ProdAccount" --profile "$CiCdProfile"
echo "Fetching CMK ARN from CloudFormation automatically..."

get_cmk_command="aws cloudformation describe-stacks --stack-name pre-reqs --profile $CiCdProfile --query \"Stacks[0].Outputs[?OutputKey=='CMK'].OutputValue\" --output text"
CMKArn=$(eval $get_cmk_command)
echo "Got CMK ARN: $CMKArn"

echo "Executing in Beta Account"
aws cloudformation deploy --stack-name cicd-acct-codepipeline-role --template-file BetaAccount/cicd-acct-codepipeline-role.yaml --capabilities CAPABILITY_NAMED_IAM --parameter-overrides CiCdAccount=$CiCdAccount CMKARN=$CMKArn --profile $BetaProfile

echo "Executing in PROD Account"
aws cloudformation deploy --stack-name cicd-acct-codepipeline-cloudformation-role --template-file ProdAccount/cicd-acct-codepipeline-cloudformation-deployer.yaml --capabilities CAPABILITY_NAMED_IAM --parameter-overrides CiCdAccount=$CiCdAccount CMKARN=$CMKArn --profile $ProdProfile

echo "Creating Pipeline in CiCd Account"
aws cloudformation deploy --stack-name microservice-cd-ecr-source --template-file CiCdAccount/microservice_cd_ecr_source.yaml --parameter-overrides CMKARN=$CMKArn BetaAccount=$BetaAccount ProductionAccount=$ProdAccount  --capabilities CAPABILITY_NAMED_IAM --profile $CiCdProfile

aws cloudformation deploy --stack-name infra-pipeline-github-source --template-file CiCdAccount/infra_pipeline_github_source.yaml --parameter-overrides CMKARN=$CMKArn BetaAccount=$BetaAccount ProductionAccount=$ProdAccount  --capabilities CAPABILITY_NAMED_IAM --profile $CiCdProfile

echo "Adding Permissions to the Cross Accounts"

aws cloudformation deploy --stack-name infra-pipeline-github-source --template-file CiCdAccount/infra_pipeline_github_source.yaml --parameter-overrides CrossAccountCondition=true --capabilities CAPABILITY_NAMED_IAM --profile $CiCdProfile
aws cloudformation deploy --stack-name microservice-cd-ecr-source --template-file CiCdAccount/microservice_cd_ecr_source.yaml --parameter-overrides CrossAccountCondition=true --capabilities CAPABILITY_NAMED_IAM --profile $CiCdProfile

