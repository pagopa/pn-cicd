# Disclaimers
- Create DNS and certificates before run Continuous Delivery initialization. 
  Follow the instruction in [pn-infra project](https://github.com/pagopa/pn-infra)

# CD pipeline

A continuous delivery "environment" pipeline is really structured in multiple pipelines:

- One __"Infrastructure" pipeline__ responsible for:
  - networking and cluster resources 
  - resources that enable communication between different microservices.

- Multiple __Microservice pipeline__, one for each microservice, responsible for:
  - storage resources
  - microservice execution resources 
  - API exposition resources

## Constraints on infrastructure CFN templates repository
See [pn-infra](https://github.com/pagopa/pn-infra) GithubRepository. 

## Constraints on microservices repository 
Each microservice repository must have two files
 - __scripts/aws/cfn/storage.yml__: define the resources where microservice data are stored
 - __scripts/aws/cfn/microservice.yml__: define the microservice runtime resources
 - __scripts/aws/cfn/microservice-<env-name>-cfg.json__: define the microservice runtime template parameters

## Initialize a Continuous Delivery environment
Prepare a configuration file as described in the next section and use the 
[boostrap.sh](bootstrap/bootstrap.sh) script.

More information about pipelines internals and how to structure infrastructure 
and microservices templates are available [here](bootstrap/README.md).

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
            "type": "container",
            "image-name-and-tag": "api-first-springboot:latest",
            "codestar-connection-arn": "arn:aws:codestar-connections:eu-west-3:911845998067:connection/03777403-e8c7-46ec-9d0b-9a6bf2c115f9"
        },
        {
            "name": "example2",
            "repo-name": "marco-vit-pagopa/api-first-springboot",
            "branch-name": "feature/2",
            "type": "container",
            "image-name-and-tag": "api-first-springboot-f2:latest",
            "codestar-connection-arn": "arn:aws:codestar-connections:eu-west-3:911845998067:connection/03777403-e8c7-46ec-9d0b-9a6bf2c115f9"
        },
        {
            "name": "auth-fleet",
            "repo-name": "pagopa/pn-auth-fleet",
            "branch-name": "feature/PN-611",
            "type": "lambdas",
            "lambda-names": [
                "pn-auth-fleet/main/apikeyAuthorizer",
                "pn-auth-fleet/main/jwtAuthorizer",
                "pn-auth-fleet/main/tokenExchange"
            ],
            "codestar-connection-arn": "arn:aws:codestar-connections:eu-central-1:911845998067:connection/b28acf11-85de-478c-8ed2-2823f8c2a92d"
        }
    ]
}
```

- __project-name__: only ascii letters and numbers. Usually "pn", can be pnNNN where NNN is the feature number
- __infrastructure__: information about infrastructure CFN template repository
  - _repo-name_: the name of the repository
  - _branch-name_: the branch to checkout
  - _repo-subdir_: a repository subdirectory (usually runtime-template)
  - _codestar-connection-arn_: AWS CodeStar connection to use for repository checkout
- __accounts__:
  - _cicd.region_: the region where to deploy the pipelines definitions
  - _dev.region_: the region where to deploy development environment
  - _uat.region_: the region where to deploy User Acceptance Test environment
- __microservices__: an array of microservice pipelines definitions
  - _name_: the logical name of microservice (only ascii letters and numbers)
  - _repo-name_: the name of the repository
  - _branch-name_: the branch to checkout
  - _type_: __container__ for ECR microservices, __lambdas__ for groups of lambda functions.
  - _image-name-and-tag_: the ECR repository name and the image tag separated by a column (:)
  - _lambda-names_: array containing up to five C.I. lambda artifacts written as 
    $lt;repo-name$gt;/$lt;branch-name$gt;/$lt;lambda-name$gt;
  - _codestar-connection-arn_: AWS CodeStar connection to use for microservice repository checkout.
    Microservice pipelines checkout and use CFN templates for storage and runtime definition.


## TODO
 - PN-665 Multiregion Pipeline
 - PN-666: Template bucket shared between multiple pipeline executions. We can solve "partitioning" 
   the bucket by pipeline execution id. (We can also write all the pipeline in the same stage :( ).
 - PN-667: Add changeset web link to manual approval steps
 - PN-668: (NICE TO HAVE) move "parameters enrichment" to a lambda function
 
 - (LATER) Support prod environment in the pipelines


