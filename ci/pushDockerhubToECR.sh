#!/bin/bash

IMAGE=$1
PLATFORM=$2 # linux/arm64 or linux/amd64

if [ -z "$IMAGE" ] || [ -z "$PLATFORM" ]; then
  echo "Usage: $0 <image> <platform>"
  echo "Example: $0 localstack/localstack:4.0.3 linux/amd64"
  exit 1
fi

PLATFORM="--platform $PLATFORM"

aws ecr get-login-password --region eu-central-1 --profile sso_pn-cicd | docker login --username AWS --password-stdin 911845998067.dkr.ecr.eu-central-1.amazonaws.com
docker pull $IMAGE $PLATFORM # pull from dockerhub
docker tag $IMAGE 911845998067.dkr.ecr.eu-central-1.amazonaws.com/$IMAGE
docker push 911845998067.dkr.ecr.eu-central-1.amazonaws.com/$IMAGE $PLATFORM
