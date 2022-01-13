# pn-cicd 
CI/CD Piattaforma Notifiche

## The big picture
![CI/CD layout](docs/layout.drawio.png)

## Continuos Integration 

### Directory structure
- __bootstrap__: CI pipeline infrastructure resources for CI/CD build and pipeline.
- __infra__: cloud formation stack ci infrastructure.
- __builders__: cloud formation stack template used for continuous integration via CodeBuild.

### Pipeline 
Il file _ci/bootstrap/pn-cicd-pipeline.yaml_ è l'unico che deve essere caricato manualmente con il seguente comando:
```
aws cloudformation create-stack --stack-name pn-ci-pipeline --template-body ci/bootstrap/pn-ci-pipeline.yaml --profile cicd --capabilities=CAPABILITY_IAM
```
Oppure aggiornaro con il comando
```
aws cloudformation update-stack --stack-name pn-ci-pipeline --template-body ci/bootstrap/pn-ci-pipeline.yaml --profile cicd --capabilities=CAPABILITY_IAM
```

Lo stack contiene la pipeline che lancia il template _ci/infra/root.yaml_ che crea le risorse necessarie
 alla CI e chiama i template contenuti in _builders_ per crere gli stack che daranno origine ai 
 progetti _CodeBuild_ per la CI dei moduli di PN su github.

### Comandi singoli che possono tornare utili

#### Creazione dello stack singolo
```
aws cloudformation create-stack --stack-name <value> --template-body build/mvn-jar-codebuild.yaml --parameters ParameterKey=string,ParameterValue=string,UsePreviousValue=boolean,ResolvedValue=string
```

#### Aggiornamento dello stack
```
aws cloudformation update-stack --stack-name <value> --capabilities CAPABILITY_IAM
```

#### Cancellazione dello stack
```
aws cloudformation delete-stack --stack-name <value> --capabilities CAPABILITY_IAM
```

#### Lancio della singola build
```
aws codebuild start-build --project-name myProject --environment-variables-override "[{\"name\":\"ACTION\",\"value\":\"create\"},{\"name\":\"BRANCH\",\"value\":\"${BITBUCKET_BRANCH}\"}]"
```
