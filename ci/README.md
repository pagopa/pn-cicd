# Continuous Integration Piattaforma Notifiche

## Directory structure
- __bootstrap__: CI pipeline infrastructure resources for CI/CD build and pipeline.
- __infra__: cloud formation stack ci infrastructure.
- __builders__: cloud formation stack template used for continuous integration via CodeBuild.

## CI Pipeline
The CI pipeline stack is deployed by the Cloud Formation template _ci/bootstrap/pn-cicd-pipeline.yaml_.

This is the only one need manual deployment with the following command:

```
aws cloudformation deploy --stack-name pn-ci-pipeline --template-body ci/bootstrap/pn-ci-pipeline.yaml --profile cicd --capabilities=CAPABILITY_IAM
```

- __NOTE__: a _cicd_ profile configuration in `~/.aws/config` and `~/.aws/credential` are needed. 

The pipeline read _[infra/root.yaml](infra/root.yaml)_ template to create the CI Stacks. 

It will deploy common resource shared with the CD pipeline like:
- CodeArtifact: Artifact repository for maven, npm, ....
- ArtifactBuckets: Used to store artifact like lambda, static website  
- CodeBuildNotifications: to connect build failure to SNSTopic (ChatBot on Slack)

It use nested templates in _[builders](builders)_ directory to deploy resources
needed for the CI process like:
- CodeBuild
- ECR (for docker artificats)

## Add a project to CI pipeline

The process to add a project in the CI pipeline is done by add some lines in _root.yaml_ file.

Exaple: Properties depends on the selected _builder_ type.

````yaml
<Name for CI Stack>:
  Type: AWS::CloudFormation::Stack
  Properties:
   TemplateURL: !Sub 'https://s3.amazonaws.com/${PnCiCdTemplatesBucketName}/ci/builders/<builder-type>.yaml'
   Parameters:
   GitHubProjectName: '<pagopa github project name>'
   CodeArtifactDomainName: !Ref 'CodeArtifactDomainName'
   CodeArtifactRepositoryName: !Ref 'CodeArtifactRepositoryName'
   NotificationSNSTopic: !Ref 'NotificationSNSTopic'
  TimeoutInMinutes: <timeout in minutes for build process>
````

## Useful commands

### Create a stack using builders for testing purpose
```
aws cloudformation deploy --stack-name <value> --template-body builders/mvn-jar-codebuild.yaml --profile cicd  \
 --parameters ParameterKey=string,ParameterValue=string,UsePreviousValue=boolean,ResolvedValue=string
```

### Remove stack after test
```
aws cloudformation delete-stack --stack-name <value> --profile cicd --capabilities CAPABILITY_IAM 
```

### Launch a build on CodeBuild
```
aws codebuild start-build --project-name myProject --profile cicd \
 --environment-variables-override "[{\"name\":\"ACTION\",\"value\":\"create\"},{\"name\":\"BRANCH\",\"value\":\"${BITBUCKET_BRANCH}\"}]"
```
