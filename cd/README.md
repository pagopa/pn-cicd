# CD pipeline

A continuous delivery "environment" pipeline is really structured in multiple pipelines:

- One __"Infrastructure" pipeline__ responsible for:
  - networking and cluster resources 
  - resources that enable communication between different microservices.

- Multiple __Microservice pipeline__, one for each microservice, responsible for:
  - storage resources
  - microservice execution resources 
  - API exposition resources

## How to define a Continuous Delivery environment

### Prepare infrastructure repository
See pn-infra

### Prepare a microservice repository 
TODO Descrivere struttura minima

### Initialize a Continuous Delivery environment

Prepare a configuration file as described in the next section and use the 
[boostrap.sh](bootstrap/bootstrap.sh) script.

More information about pipelines internals and how to structure infrastructure 
and microservices templates are available [here](bootstrap/README.md).

### Configuration file example with comments

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
  - _image-name-and-tag_: the ECR repository name and the image tag separated by a column (:)
  - _codestar-connection-arn_: AWS CodeStar connection to use for microservice repository checkout.
    Microservice pipelines checkout and use CFN templates for storage and runtime definition.


## TODO
 - Multiregion Pipeline
 - Notification for failed pipelines executions
 - Trigger microservices pipelines after successful infrastructure pipeline executions
 - Template bucket shared between multiple pipeline executions. We can solve "partitioning" 
   the bucket by pipeline execution id. (We can also write all the pipeline in the same stage :( ).
 - Red from the continer image the environment variable CVS_COMMIT_ID and use its value to 
   read the exact commit from github.
 - Add changeset web link to manual approval steps
 - (NICE TO HAVE) move "parameters enrichement" to a lambda function
 
 - (LATER) Support prod environment n the pipelines


