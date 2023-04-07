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
      Ada1=558518206506 \
      Ada2=498209326947 \
      Ada3=946373734005 \
      \
      Ada4=748275689270 \
      Ada5=153517439884 \
      Ada6=648024184569 \
      \
      Ada7=615714398925 \
      Ada8=648535372866 \
      Ada9=205069730074 \
      \
      Ada10=734487133479 \
      Ada11=603228414473 \
      Ada12=354805605941 \
      \
      Ada13=804103868123 \
      Ada14=063295570123 \
      Ada15=118759374619 \
      \
      Ada16=911845998067 \
      Ada17=911845998067 \
      Ada18=911845998067 \
      \
      Ada19=830192246553 \
      Ada20=089813480515 \
      Ada21=644374009812 \
      Ada22=956319218727 \
      Ada23=510769970275 \
      Ada24=350578575906 \
      \
      Ada25=911845998067 \
      Ada26=911845998067 \
      Ada27=911845998067 \
      Ada28=911845998067 \
      Ada29=911845998067 \
      Ada30=911845998067



## INFORMAZIONI RIPORTATE dalla pagina confluence "AWS accounts" che è 
##  fonte ufficiale per i numeri di account.
##################################################################################

#911845998067 | team-notifiche+pn_cicd@pagopa.it | CICD non serve autorizzarlo

#558518206506 | team-notifiche+pn_beta@pagopa.it   | pn-core     DEV
#954693996334 | team-notifiche+pn_betas@pagopa.it  | pn-spidhub  DEV
#498209326947 | team-notifiche+pn_logs@pagopa.it   | pn-helpdesk DEV
#946373734005 | team-notifiche+pn_prod@pagopa.it   | pn-confinfo DEV   + preview sito vetrina

#748275689270 | pn-core     SVIL
#076638595177 | pn-spidhub  SVIL
#648024184569 | pn-helpdesk SVIL
#153517439884 | pn-confinfo SVIL

#615714398925 | pn-core     COLL
#540624516147 | pn-spidhub  COLL
#648535372866 | pn-helpdesk COLL
#205069730074 | pn-confinfo COLL

#603228414473 | pn-core     CERT
#942300612763 | pn-spidhub  CERT
#354805605941 | pn-helpdesk CERT
#734487133479 | pn-confinfo CERT

#804103868123 | team-notifiche+pn-core-hotfix@pagopa.it      | pn-core     HOTFIX
#907690015624 | team-notifiche+pn-hotfix@pagopa.it           | pn-spidhub  HOTFIX
#063295570123 | team-notifiche+pn-helpdesk-hotfix@pagopa.it  | pn-helpdesk HOTFIX
#118759374619 | team-notifiche+pn_hotfix@pagopa.it           | pn-confinfo HOTFIX


#830192246553 | pn-core-dev@pagopa.it      | pn-core     DEV (Versione B che contiene anche helpdesk) 
#089813480515 | pn-confinfo-dev@pagopa.it  | pn-confinfo DEV (Versione B che contiene anche spidhub) 

#644374009812 | pn-core-uat@pagopa.it      | pn-core     UAT (Versione B che contiene anche helpdesk) 
#956319218727 | pn-confinfo-uat@pagopa.it  | pn-confinfo UAT (Versione B che contiene anche spidhub) 

#510769970275 | pn-core-prod@pagopa.it     | pn-core     PROD (Versione B che contiene anche helpdesk) 
#350578575906 | pn-confinfo-prod@pagopa.it | pn-confinfo PROD (Versione B che contiene anche spidhub) 

