#!/bin/bash

## Script to pull multi-arch docker images from DockerHub and push them to AWS ECR
## Usage: ./pushDockerhubToECR.sh <container_name> <image_amd> <image_arm>
## create Repository in ECR before running this script

PROFILE=$1
CONTAINER_NAME=$2
IMAGE_AMD=$3
IMAGE_ARM=$4
if [ -z "$PROFILE" ] || [ -z "$CONTAINER_NAME" ] || [ -z "$IMAGE_AMD" ] || [ -z "$IMAGE_ARM" ]; then
  echo "Usage: $0 <profile> <container_name> <image_amd> <image_arm>"
  echo "Example: $0 pn-cicd localstack/localstack localstack/localstack:sha256:xxx localstack/localstack:sha256:yyy"
  exit 1
fi

ACCOUNTID=$(aws sts get-caller-identity --profile $PROFILE --query Account --output text)
echo "Using AWS Account ID: $ACCOUNTID"

aws ecr get-login-password --region eu-central-1 --profile $PROFILE | docker login --username AWS --password-stdin $ACCOUNTID.dkr.ecr.eu-central-1.amazonaws.com
echo "Pulling images from DockerHub..."
docker pull $CONTAINER_NAME@$IMAGE_AMD 
docker pull $CONTAINER_NAME@$IMAGE_ARM 
echo "Tagging and pushing images to ECR..."
docker tag $CONTAINER_NAME@$IMAGE_AMD $ACCOUNTID.dkr.ecr.eu-central-1.amazonaws.com/$CONTAINER_NAME-amd
docker tag $CONTAINER_NAME@$IMAGE_ARM $ACCOUNTID.dkr.ecr.eu-central-1.amazonaws.com/$CONTAINER_NAME-arm
docker push $ACCOUNTID.dkr.ecr.eu-central-1.amazonaws.com/$CONTAINER_NAME-amd
docker push $ACCOUNTID.dkr.ecr.eu-central-1.amazonaws.com/$CONTAINER_NAME-arm
echo "Creating and pushing Docker manifest..."
docker manifest create $ACCOUNTID.dkr.ecr.eu-central-1.amazonaws.com/$CONTAINER_NAME $ACCOUNTID.dkr.ecr.eu-central-1.amazonaws.com/$CONTAINER_NAME-amd $ACCOUNTID.dkr.ecr.eu-central-1.amazonaws.com/$CONTAINER_NAME-arm
docker manifest push $ACCOUNTID.dkr.ecr.eu-central-1.amazonaws.com/$CONTAINER_NAME
echo "Done."