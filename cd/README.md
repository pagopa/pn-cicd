# CD pipeline

A continuos delivery "environment" pipeline is really structured in multiple pipelines:
- One "Infrastructure" pipeline responsable of 
  - networking and cluster resources and
  - resources that enable communication between different microservices.
- Multiple pipelines, one for each microservice, responsable of
  - storage resources for each microservice and
  - microservice execution resources and API exposition resources.

## Initialize a Continuos Delivery environment

Prepare a configuration file as described in the next section and use the 
[boostrap.sh](boostrap/boostrap.sh) script.

More informations about pipelines internals and how to structure infrastructure 
and microservices templates are available [here](bootstrap).


## Configuration file example with comments
```
{
    "project-name": "test",
    "infrastructure": {
        "repo-name": "pagopa/pn-infra",
        "branch-name": "feature/PN-574",
        "repo-subdir": "runtime-infra-new",
        "codestar-connection-arn": "arn:aws:codestar-connections:eu-central-1:911845998067:connection/b28acf11-85de-478c-8ed2-2823f8c2a92d"
    },
    "accounts": {
        "cicd": {
            "region": "eu-west-3"
        },
        "dev": {
            "region": "eu-south-1"
        },
        "uat": {
            "region": "eu-south-1"
        }
    },
    "microservices": [
        {
            "name": "example1",
            "repo-name": "marco-vit-pagopa/api-first-springboot",
            "branch-name": "main",
            "image-name-and-tag": "api-first-springboot:latest",
            "codestar-connection-arn": "arn:aws:codestar-connections:eu-west-3:911845998067:connection/03777403-e8c7-46ec-9d0b-9a6bf2c115f9"
        },
        {
            "name": "example2",
            "repo-name": "marco-vit-pagopa/api-first-springboot",
            "branch-name": "feature/2",
            "image-name-and-tag": "api-first-springboot-f2:latest",
            "codestar-connection-arn": "arn:aws:codestar-connections:eu-west-3:911845998067:connection/03777403-e8c7-46ec-9d0b-9a6bf2c115f9"
        }
    ]
}
```
- **project-name**: only ascii letters and numbers, used to distinguis main branch from feature branch.
- **infrastructure**: informations about infrastructure CFN template repository
  - *repo-name*: the name of the repository
  - *branch-name*: the branch to checkout
  - *repo-subdir*: a repository subdirectory (usually runtime-template)
  - *codestar-connection-arn*: AWS CodeStar connection to use for repository checkout
- **accounts**:
  - *cicd.region*: the region where to deploy the pipelines definitions
  - *dev.region*: the region where to deploy development environment
  - *uat.region*: the region where to deploy User Acceptance Test environment
- **microservices**: an array of microservice pipelines definitions
  - *name*: the logical name of microservice (only ascii letters and numbers)
  - *repo-name*: the name of the repository
  - *branch-name*: the branch to checkout
  - *image-name-and-tag*: the ECR repository name and the image tag separated by a column (:)
  - *codestar-connection-arn*: AWS CodeStar connection to use for microservice repository checkout.
    Microservice pipelines checkout and use CFN templates for storage and runtime definition.


## TODO
 - Multiregion Pipeline
 - Notification for failed pipelines executions
 - Trigger microservices pipelines after successful infrastructure pipeline executions
 
 - (LATER) Support prod environment n the pipelines

