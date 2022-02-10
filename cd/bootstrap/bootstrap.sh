#!/usr/bin/env bash -e

if ( [ $# -ne 3 -a $# -ne 4 -a $# -ne 5 ] ) then
  echo "This script create or renew a certificate for a server domain name"
  echo "Usage: $0 <config-file> <cicd-profile> <dev-profile> [<uat-profile> [<prod-profile>]]"
  echo "<config-file>: environment pipelines configuration file"
  echo "<cicd-profile>: AWS connection profile for cicd account"
  echo "<dev-profile>: AWS connection profile for dev environment account"
  echo "<uat-profile>: AWS connection profile for uat environment account"
  echo "<prod-profile>: AWS connection profile for prod environment account"
  echo ""
  echo "This script require following executable configured in the PATH variable:"
  echo " - aws cli 2.0 "
  echo " - jq"
  echo " - sha256"
  echo ""
  echo ""
  echo " === WARNINGS ==="
  echo " - This script do not remove CFN templates. You have to remove them manually when needed"
  echo " - When you reconfigure a pipeline adding one environment (uat or prod) you have to "
  echo "   remove pipeline CFN stack manually before re-execute this script"  

  if ( [ "$BASH_SOURCE" = "" ] ) then
    return 1
  else
    exit 1
  fi
fi

scriptDir=$( dirname "$0" )

ConfigFile=$1

CiCdProfile=$2
CiCdRegion=$(jq -r '.accounts.cicd.region' $ConfigFile )
CiCdAccount=$(aws sts get-caller-identity --profile $CiCdProfile | jq -r .Account)

DevProfile=$3
DevRegion=$(jq -r '.accounts.dev.region' $ConfigFile ) # Ignored, reserved for future use
DevAccount=$(aws sts get-caller-identity --profile $DevProfile | jq -r .Account)

UatProfile="$DevProfile"
UatRegion="$DevRegion"
UatAccount="$DevAccount"
if ( [ $# -ge 4 ] ) then
  UatProfile=$4
  UatRegion=$(jq -r '.accounts.uat.region' $ConfigFile ) # Ignored, reserved for future use
  UatAccount=$(aws sts get-caller-identity --profile $UatProfile | jq -r .Account)
fi

ProdProfile="$DevProfile"
ProdRegion="$DevRegion"
ProdAccount="$DevAccount"
if ( [ $# -eq 5 ] ) then
  ProdProfile=$5
  ProdRegion=$(jq -r '.accounts.prod.region' $ConfigFile ) # Ignored, reserved for future use
  ProdAccount=$(aws sts get-caller-identity --profile $ProdProfile | jq -r .Account)
fi

ProjectName=$(jq -r '."project-name"' $ConfigFile )

InfraRepoName=$(jq -r '.infrastructure."repo-name"' $ConfigFile )
InfraBranchName=$(jq -r '.infrastructure."branch-name"' $ConfigFile )
InfraRepoSubdir=$(jq -r '.infrastructure."repo-subdir"' $ConfigFile )
InfraCodeStarGithubConnectionArn=$(jq -r '.infrastructure."codestar-connection-arn"' $ConfigFile )


echo ""
padding="            "
echo "======================== PARAMETRIZATION ==========================="
echo "Project Name = ${ProjectName}"
echo ""
echo " === Infrastructure repository connection"
echo " -  Repository name: ${InfraRepoName}"
echo " -      Branch name: ${InfraBranchName}"
echo " - Templates subdir: ${InfraRepoSubdir}"
echo " - Codestar connection: ${InfraCodeStarGithubConnectionArn}"
echo ""
echo " === AWS ACCOUNT INFORMATIONS "
echo "---------------------------------------------------------------------"
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


NumberOfMicroservices=$(jq '.microservices | length' $ConfigFile )

echo ""
echo " === MICROSERVICES CONFIGURATIONS "
for (( m=0; m<${NumberOfMicroservices}; m++ ))
do
  MicroserviceName=$(jq -r ".microservices[$m].name" $ConfigFile )
  MicroserviceRepoName=$(jq -r ".microservices[$m].\"repo-name\"" $ConfigFile )
  MicroserviceBranchName=$(jq -r ".microservices[$m].\"branch-name\"" $ConfigFile )
  MicroserviceImageNameAndTag=$(jq -r ".microservices[$m].\"image-name-and-tag\"" $ConfigFile )
  MicroserviceType=$(jq -r ".microservices[$m].type" $ConfigFile )
  MicroserviceLambdaList=$(jq -r "try .microservices[$m].\"lambda-names\"[]" $ConfigFile | tr "\n" "," | sed -e 's/,$//' )
  MicroCodeStarGithubConnectionArn=$(jq -r ".microservices[$m].\"codestar-connection-arn\"" $ConfigFile )

  echo " --- ${MicroserviceName} "
  echo " - Type (container|lambdas): ${MicroserviceType}"
  echo " -          Repository name: ${MicroserviceRepoName}"
  echo " -              Branch name: ${MicroserviceBranchName}"
  echo " -       Image name and tag: ${MicroserviceImageNameAndTag}"
  echo " -       Lambdas names list: ${MicroserviceLambdaList}"
  echo " -      Codestar connection: ${MicroCodeStarGithubConnectionArn}"   
done

echo ""
echo ""
echo ""
echo ""

echo "###########     GET NOTIFICATIONS SNS TOPIC FROM C.I.     ####################"
getSnsTopicCommand="aws --profile $CiCdProfile --region $CiCdRegion cloudformation describe-stacks \
                           --stack-name cicd-pipeline-notification-sns-topic \
                           --query \"Stacks[0].Outputs[?OutputKey=='NotificationSNSTopicArn'].OutputValue\" \
                           --output text"
SnsTopicArn=$(eval $getSnsTopicCommand)
echo "Got sns topic ARN: $SnsTopicArn"
echo ""

echo "########### GET WEB / LAMBDA ARTIFACTS BUCKET NAME FROM C.I. ####################"
getWebLambdaBucketCommand="aws --profile $CiCdProfile --region $CiCdRegion cloudformation describe-stacks \
                           --stack-name pn-ci-root \
                           --query \"Stacks[0].Outputs[?OutputKey=='CiArtifactBucket'].OutputValue\" \
                           --output text"
WebLambdaBucketName=$(eval $getWebLambdaBucketCommand)
echo "Got web and lambda artifacts bucket name: $WebLambdaBucketName"
echo ""

echo "########### PREPARE Continuos Delivery BUCKETS AND ROLSE ####################"
echo "# Deploying pre-requisite stack to the ci cd account... "
aws --profile "$CiCdProfile" --region "$CiCdRegion" cloudformation deploy \
    --stack-name "${ProjectName}-bucket-crypto-keys" \
    --template-file ${scriptDir}/cfn-templates/00-shared_buckets_key.yaml \
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
    --template-file ${scriptDir}/cfn-templates/20-target_accounts_roles.yaml \
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
      --template-file ${scriptDir}/cfn-templates/20-target_accounts_roles.yaml \
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
      --template-file ${scriptDir}/cfn-templates/20-target_accounts_roles.yaml \
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
      --template-file ${scriptDir}/cfn-templates/50-infrastructure_deployer_pipeline.yaml \
      --capabilities CAPABILITY_NAMED_IAM \
      --parameter-overrides \
        CodeStarGithubConnectionArn="$InfraCodeStarGithubConnectionArn" \
        CMKARN=$CMKArn \
        ProjectName="$ProjectName" \
        InfraRepoName="$InfraRepoName" \
        InfraBranchName="$InfraBranchName" \
        InfraRepoSubdir="$InfraRepoSubdir" \
        DevAccount="$DevAccount" \
        UatAccount="$UatAccount" \
        ProdAccount="$ProdAccount" \
        NotificationSNSTopic=${SnsTopicArn}

for (( m=0; m<${NumberOfMicroservices}; m++ ))
do
  MicroserviceName=$(jq -r ".microservices[$m].name" $ConfigFile )
  MicroserviceRepoName=$(jq -r ".microservices[$m].\"repo-name\"" $ConfigFile )
  MicroserviceBranchName=$(jq -r ".microservices[$m].\"branch-name\"" $ConfigFile )
  MicroserviceType=$(jq -r ".microservices[$m].type" $ConfigFile )
  MicroserviceImageNameAndTag=$(jq -r ".microservices[$m].\"image-name-and-tag\"" $ConfigFile )
  MicroserviceLambdaList=$(jq -r "try .microservices[$m].\"lambda-names\"[]" $ConfigFile | tr "\n" "," | sed -e 's/,$//' )
  MicroserviceLambdaListLength=$(jq -r "try .microservices[$m].\"lambda-names\" | length" $ConfigFile )
  MicroCodeStarGithubConnectionArn=$(jq -r ".microservices[$m].\"codestar-connection-arn\"" $ConfigFile )

  if ( [ "container" = "${MicroserviceType}" ] ) then
    echo ""
    echo ""
    echo "########## Deploy CONTAINER MICROSERVICE ${MicroserviceName} pipeline ##########"
    deployStackAndUpdateCrossAccountCondition \
      aws --profile $CiCdProfile --region $CiCdRegion cloudformation deploy \
          --stack-name "${ProjectName}-microsvc-${MicroserviceName}-pipeline" \
          --template-file ${scriptDir}/cfn-templates/70-microservice_container_deployer_pipeline.yaml \
          --capabilities CAPABILITY_NAMED_IAM \
          --parameter-overrides \
            CodeStarGithubConnectionArnInfra="$InfraCodeStarGithubConnectionArn" \
            CodeStarGithubConnectionArnMicro="$MicroCodeStarGithubConnectionArn" \
            CMKARN=$CMKArn \
            ProjectName="$ProjectName" \
            InfraRepoName="$InfraRepoName" \
            InfraBranchName="$InfraBranchName" \
            InfraRepoSubdir="$InfraRepoSubdir" \
            DevAccount="$DevAccount" \
            UatAccount="$UatAccount" \
            ProdAccount="$ProdAccount" \
            MicroserviceName="${MicroserviceName}" \
            MicroserviceRepoName="${MicroserviceRepoName}" \
            MicroserviceBranchName="${MicroserviceBranchName}" \
            MicroserviceImageNameAndTag="${MicroserviceImageNameAndTag}" \
            MicroserviceNumber="$[ ${m} + 1 ]"\
            NotificationSNSTopic=${SnsTopicArn}
  
  elif ( [ "lambdas" = "${MicroserviceType}" ] ) then
    echo ""
    echo ""
    echo "########## Deploy LAMBDAS MICROSERVICE ${MicroserviceName} pipeline ##########"
    deployStackAndUpdateCrossAccountCondition \
      aws --profile $CiCdProfile --region $CiCdRegion cloudformation deploy \
          --stack-name "${ProjectName}-microsvc-${MicroserviceName}-pipeline" \
          --template-file ${scriptDir}/cfn-templates/70-microservice_lambdas_deployer_pipeline.yaml \
          --capabilities CAPABILITY_NAMED_IAM \
          --parameter-overrides \
            CodeStarGithubConnectionArnInfra="$InfraCodeStarGithubConnectionArn" \
            CodeStarGithubConnectionArnMicro="$MicroCodeStarGithubConnectionArn" \
            LambdasZipsBucketName="${WebLambdaBucketName}" \
            CMKARN=$CMKArn \
            ProjectName="$ProjectName" \
            InfraRepoName="$InfraRepoName" \
            InfraBranchName="$InfraBranchName" \
            InfraRepoSubdir="$InfraRepoSubdir" \
            DevAccount="$DevAccount" \
            UatAccount="$UatAccount" \
            ProdAccount="$ProdAccount" \
            MicroserviceName="${MicroserviceName}" \
            MicroserviceRepoName="${MicroserviceRepoName}" \
            MicroserviceBranchName="${MicroserviceBranchName}" \
            LambdasNames="${MicroserviceLambdaList}" \
            LambdasNamesLength="${MicroserviceLambdaListLength}" \
            MicroserviceNumber="$[ ${m} + 1 ]"\
            NotificationSNSTopic=${SnsTopicArn}
  
  else 
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!! ERROR !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!!!  Unknown microservice ${MicroserviceName} type \"${MicroserviceType}\" "
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    if ( [ "$BASH_SOURCE" = "" ] ) then
      return 1
    else
      exit 1
    fi
  fi  
done

