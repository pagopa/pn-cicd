
# Continuos Delivery Pipelines internals

## Big Picture
![Big picture image](big-picture.drawio.png)

The CICD account contains pipelines that deploy CFN stacks in dev, uat and prod accounts.

To allow this we need two shared bucket for artifacts and CFN templates fragment (we 
use nested stack). The [cicd-pipe-00-shared_buckets_key.yaml](cicd-pipe-00-shared_buckets_key.yaml)
template contains encription key definition.

The [target-pipe-20-cicd_roles.yaml] CFN templates contains the role definition repeated 
in each of dev, uat and prod accounts that permit to CiCd account to deploy CFN stacks into
target accounts.


## The infrastructure pipeline
Defined in [cicd-pipe-50-infra_pipeline.yaml](cicd-pipe-50-infra_pipeline.yaml) is composed 
of the following steps
- Checkout infrastructure templates
- Copy it to an S3 bucket (useful for nested stack)
- Deploy development account
  - Deploy a "once for account" templte (useful for global configuration like API-Gateway log 
    configuration and Chatbot slack subscriptions)
  - Merge CFN parameters file for next step with output from previous step
  - Deploy "network infrastructure" CFN template
  - Merge CFN parameters file for next step with output from previous step
  - Deploy "Inter Process Comunication infrastructure" CFN template (usually some queue)
- Deploy User Acceptance Test account: same step of dev account but ask manual approval and
  use different parameters file.
- (TODO) Deploy Production account

*<base>* means the *infrastructure.repo-subdir* configuration value.

### Once in one account infrastructure CNF template
This script is read from the infrastructure git repository with path 
```
<base>/once4account/<env-name>.yaml
```
 - **Input**: only one mandatory parameter TemplateBucketBaseUrl containing the base URL of 
   infrastructure CFN fragments
 - **Output**: any output useful for next steps.
 - **Responsability**: configure global resources as API-Gateway log configuration and 
   Chatbot slack subscriptions

### Networking infrastructure CNF template
This script is read from the infrastructure git repository with path 
```
<base>/pn-infra.yaml
```
 - **Input**: file, previous step and some mandatory parameters
   - A file ```<base>/pn-infra-<env-name>-cfg.json``` from infrastructure repository
   - The outputs of "once in an account" CFN templates
   - ProjectName: the *project-name* configuration value
   - TemplateBucketBaseUrl: containing the base URL of infrastructure CFN fragments
 - **Output**: any output useful for next steps.
 - **Responsability**: configure networking infrastructure

### Ipc infrastructure CNF template
This script is read from the infrastructure git repository with path 
```
<base>/pn-ipc.yaml
```
 - **Input**: file, previous step and some mandatory parameters
   - A file ```<base>/pn-ipc-<env-name>-cfg.json``` from infrastructure repository
   - The outputs of "network infrastructure" CFN templates
   - ProjectName: the *project-name* configuration value
   - TemplateBucketBaseUrl: containing the base URL of infrastructure CFN fragments
 - **Output**: any output useful to the microservices.
 - **Responsability**: configure comunication between microservices and define all CFN 
   parameters that microservices can use.


## The microservices pipelines
Defined in [cicd-pipe-70-microsvc_pipeline.yaml](cicd-pipe-70-microsvc_pipeline.yaml) has the 
following steps
- Checkout micorservice container image, microservice CFN templates and infrastructure CFN templates
- Copy infrastructure CFN templates to an S3 bucket (useful for nested stack)
- Deploy development account
  - Deploy a "microservice storage" CFN template
  - Merge CFN parameters file for next step with output from previous step
  - Deploy "microservice runtime" CFN template
- Deploy User Acceptance Test account: same step of dev account but ask manual approval and
  use different parameters file.
- (TODO) Deploy Production account

### Storage microservice CNF template
 This script is read from the microservice git repository with path 
```
scripts/aws/cfn/storage.yml
```
 - **Input**: some mandatory parameters
   - ProjectName: the *project-name* configuration value
   - TemplateBucketBaseUrl: containing the base URL of infrastructure CFN fragments
   - MicroserviceNumber: an unique number for each microservice in a microservice 
     group (usefull to disambiguate two instance of the same microservice)
 - **Output**: any output useful to the microservice.
 - **Responsability**: configure storage resources for the microservice.


### Runtime microservice CNF template
 This script is read from the microservice git repository with path 
```
scripts/aws/cfn/microservice.yml
```
 - **Input**: file, previous step and some mandatory parameters
   - A file ```scripts/aws/cfn/microservice-<env-name>-cfg.json``` from microservice repository
   - The outputs of "microservice storage" CFN templates
   - ProjectName: the *project-name* configuration value
   - TemplateBucketBaseUrl: containing the base URL of infrastructure CFN fragments
   - ContainerImageUri: the full URI of the container image with digest
   - MicroserviceNumber: an unique number for each microservice in a microservice 
     group (usefull to disambiguate load balancer rules)
 - **Output**: nobody use this output
 - **Responsability**: configure microservice runtime and API exposition.



