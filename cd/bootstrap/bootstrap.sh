#!/usr/bin/env bash -e

# N.B: per aggiungere o rimuovere un ambiente dev/uat/prod bisogna rimuovere la pipeline e ricrearla
# la pipeline la prima volta fallisce per questione di diritti


ProjectName="pn"
GithubRepoName="pagopa/pn-infra"
GithubBranchName="feature/PN-574"
InfraRepoSubdir="runtime-infra-new"
CodeStarGithubConnectionArn="arn:aws:codestar-connections:eu-central-1:911845998067:connection/b28acf11-85de-478c-8ed2-2823f8c2a92d"
   

if ( [ $# -ne 4 -a $# -ne 6 -a $# -ne 8 ] ) then
  echo "This script create or renew a certificate for a server domain name"
  echo "Usage: $0 <cicd-profile> <cicd-region> <dev-profile> <dev-region> [<uat-profile> <uat-region> [<prod-profile> <prod-region>]]"
  echo "<cicd-profile>: AWS connection profile for cicd account"
  echo "<cicd-region>: AWS region where deploy cicd pipelines"
  echo "<dev-profile>: AWS connection profile for dev environment account"
  echo "<dev-region>: AWS region where deploy dev environment infrastructure"
  echo "<uat-profile>: AWS connection profile for uat environment account"
  echo "<uat-region>: AWS region where deploy uat environment infrastructure"
  echo "<prod-profile>: AWS connection profile for prod environment account"
  echo "<prod-region>: AWS region where deploy prod environment infrastructure"
  echo ""
  echo "This script require following executable configured in the PATH variable:"
  echo " - aws cli 2.0 "
  echo " - jq"
  echo " - sha256"

  if ( [ "$BASH_SOURCE" = "" ] ) then
    return 1
  else
    exit 1
  fi
fi


CiCdProfile=$1
CiCdRegion=$2
CiCdAccount=$(aws sts get-caller-identity --profile $CiCdProfile | jq -r .Account)

DevProfile=$3
DevRegion=$4 # Ignored, reserved for future use
DevAccount=$(aws sts get-caller-identity --profile $DevProfile | jq -r .Account)

UatProfile="$DevProfile"
UatRegion="$DevRegion"
UatAccount="$DevAccount"
if ( [ $# -eq 6 ] ) then
  UatProfile=$5
  UatRegion=$6 # Ignored, reserved for future use
  UatAccount=$(aws sts get-caller-identity --profile $UatProfile | jq -r .Account)
fi

ProdProfile="$DevProfile"
ProdRegion="$DevRegion"
ProdAccount="$DevAccount"
if ( [ $# -eq 8 ] ) then
  ProdProfile=$7
  ProdRegion=$8 # Ignored, reserved for future use
  ProdAccount=$(aws sts get-caller-identity --profile $ProdProfile | jq -r .Account)
fi


scriptDir=$( dirname "$0" )

echo ""
padding="            "
echo "======================= PARAMETRIZZAZIONE ==========================="
echo "| EnvName |  Account Id  |   Region    |  Profile "
echo "|---------|--------------|-------------|-----------------------------"
echo "|    cicd | $CiCdAccount | ${CiCdRegion}${padding:${#CiCdRegion}}| $CiCdProfile"
echo "|     dev | $DevAccount | ${DevRegion}${padding:${#DevRegion}}| $DevProfile"
if ( [ ! "$UatAccount" = "$DevAccount" ] ) then
echo "|     uat | $UatAccount | ${UatRegion}${padding:${#UatRegion}}| $UatProfile"
fi
if ( [ ! "$ProdAccount" = "$DevAccount" ] ) then
echo "|    prod | $ProdAccount | ${ProdRegion}${padding:${#ProdRegion}}| $ProdProfile"
fi
echo "---------------------------------------------------------------------"
echo ""


echo "########### PREPARE Continuos Delivery BUCKETS AND ROLSE ####################"
echo "# Deploying pre-requisite stack to the ci cd account... "
aws --profile "$CiCdProfile" --region "$CiCdRegion" cloudformation deploy \
    --stack-name "${ProjectName}-bucket-crypto-keys" \
    --template-file ${scriptDir}/cfn-templates/cicd-pipe-00-shared_buckets_key.yaml \
    --parameter-overrides \
      ProjectName="$ProjectName" \
      DevAccount="$DevAccount" \
      UatAccount="$UatAccount" \
      ProdAccount="$ProdAccount" 
echo ""
echo "Fetching CMK ARN from CloudFormation automatically..."

get_cmk_command="aws --profile $CiCdProfile --region $CiCdRegion \
    cloudformation describe-stacks --stack-name \"${ProjectName}-bucket-crypto-keys\" \
    --query \"Stacks[0].Outputs[?OutputKey=='CMK'].OutputValue\" --output text"

CMKArn=$(eval $get_cmk_command)
echo "# Got CMK ARN: $CMKArn"

echo ""
echo "# Enable CiCd roles in Dev Account"
aws --profile $DevProfile --region $CiCdRegion cloudformation deploy \
    --stack-name "${ProjectName}-cicd-roles" \
    --template-file ${scriptDir}/cfn-templates/target-pipe-20-cicd_roles.yaml \
    --capabilities CAPABILITY_NAMED_IAM \
    --parameter-overrides \
      ProjectName="$ProjectName" \
      CiCdAccount=$CiCdAccount \
      CMKARN=$CMKArn 

if ( [ ! "$UatAccount" = "$DevAccount" ] ) then
  echo ""
  echo "# Enable CiCd roles in Uat Account"
  aws --profile $UatProfile --region $CiCdRegion cloudformation deploy \
      --stack-name "${ProjectName}-cicd-roles" \
      --template-file ${scriptDir}/cfn-templates/target-pipe-20-cicd_roles.yaml \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        ProjectName="$ProjectName" \
        CiCdAccount=$CiCdAccount \
        CMKARN=$CMKArn 
fi

if ( [ ! "$ProdAccount" = "$DevAccount" ] ) then
  echo ""
  echo "# Enable CiCd roles in Prod Account"
  aws --profile $ProdProfile --region $CiCdRegion cloudformation deploy \
      --stack-name "${ProjectName}-cicd-roles" \
      --template-file ${scriptDir}/cfn-templates/target-pipe-20-cicd_roles.yaml \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        ProjectName="$ProjectName" \
        CiCdAccount=$CiCdAccount \
        CMKARN=$CMKArn 
fi

echo ""
echo ""
echo ""
echo ""

function deployStackAndUpdateCrossAccountCondition() {
  echo "# Deploy stack"
  eval $@
  echo ""
  echo "# Activate CrossAccountCondition"
  eval $@ CrossAccountCondition=true
}


echo "########## Deploy INFRASTRUCTURE pipeline ##########"
deployStackAndUpdateCrossAccountCondition \
  aws --profile $CiCdProfile --region $CiCdRegion cloudformation deploy \
      --stack-name "${ProjectName}-infra-pipeline" \
      --template-file ${scriptDir}/cfn-templates/cicd-pipe-50-infra_pipeline.yaml \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        CodeStarGithubConnectionArn="$CodeStarGithubConnectionArn" \
        CMKARN=$CMKArn \
        ProjectName="$ProjectName" \
        InfraRepoName="$GithubRepoName" \
        InfraBranchName="$GithubBranchName" \
        InfraRepoSubdir="$InfraRepoSubdir" \
        DevAccount="$DevAccount" \
        UatAccount="$UatAccount" \
        ProdAccount="$ProdAccount" 


#aws cloudformation deploy --stack-name infra-pipeline-github-source --template-file CiCdAccount/infra_pipeline_github_source.yaml --parameter-overrides CMKARN=$CMKArn BetaAccount=$BetaAccount ProductionAccount=$ProdAccount  --capabilities CAPABILITY_NAMED_IAM --profile $CiCdProfile

#echo "Adding Permissions to the Cross Accounts"

#aws cloudformation deploy --stack-name infra-pipeline-github-source --template-file CiCdAccount/infra_pipeline_github_source.yaml --parameter-overrides CrossAccountCondition=true --capabilities CAPABILITY_NAMED_IAM --profile $CiCdProfile
#aws cloudformation deploy --stack-name microservice-cd-ecr-source --template-file CiCdAccount/microservice_cd_ecr_source.yaml --parameter-overrides CrossAccountCondition=true --capabilities CAPABILITY_NAMED_IAM --profile $CiCdProfile

