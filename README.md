# PN CI/CD 
Continuous Integration and Continuos Delivery per Piattaforma Notifiche

## Vista d'insieme
![CI/CD layout](docs/layout.drawio.png)

## Continuous Integration
See [ci/README.md](ci/README.md)

## Continuos Delivery
See [cd/README.md](cd/README.md)

## WARNING: Hardcoded AccountId 

Due to effort need to parametrize the AccountId having access to the ECR,
in (ci/builders/mvn-docker-codebuild.yaml) the _RepositoryPolicyText_ contains
the AccountId for the _dev_, _aut_, _prod_ accounts.