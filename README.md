# PN CI/CD 
Continuous Integration and Continuos Delivery per Piattaforma Notifiche

## Vista d'insieme
![CI/CD layout](docs/layout.drawio.png)

## Continuous Integration
See [ci/README.md](ci/README.md)

## Continuos Delivery
See [cd/README.md](cd/README.md)


## WARNING: Hardcoded AccountId 
The list of the "AWS account id" allowed to access to Continuos Integration 
artifacts is hardcoded in the [ci/bootstrap.sh](ci/bootstrap.sh) file in the
_"Deploy CI pipeline"_ command.