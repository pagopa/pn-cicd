# pn-cicd 
CI/CD Piattaforma Notifiche

## Directory structure

- __infra__: infrastructure resources for CI/CD build and pipeline.
- __build__: cloud formation stack used for continuous integration.
- __deploy__: cloud formation stack used for continuous deployment.

## Pipeline 

Il file _infra/pn-cicd-pipeline_ è l'unico che deve essere caricato manualmente con il seguente comando:
```
aws cloudformation create-stack --stack-name pn-ci-pipeline --template-body file://infra/pn-ci-pipeline.yaml --profile cicd --capabilities=CAPABILITY_IAM
```

Oppure aggiornaro con il comando
```
aws cloudformation update-stack --stack-name pn-ci-pipeline --template-body file://infra/pn-ci-pipeline.yaml --profile cicd --capabilities=CAPABILITY_IAM
```

Lo stack contiene la pipeline che andando a leggere i template all'interno della cartella _build_
crea gli Stack che daranno origine ai progetti _CodeBuild_ per la CI dei moduli di PN su github.

## Comandi singoli

Creazione dello stack:
```
aws cloudformation create-stack --stack-name <value> --template-body build/mvn-jar-codebuild.yaml --parameters ParameterKey=string,ParameterValue=string,UsePreviousValue=boolean,ResolvedValue=string
```

Aggiornamento dello stack:
```
aws cloudformation update-stack --stack-name <value> --capabilities CAPABILITY_IAM
```

Cancellazione dello stack:
```
aws cloudformation delete-stack --stack-name <value> --capabilities CAPABILITY_IAM
```

## Lancio della sigola build

```
aws codebuild start-build --project-name myProject --environment-variables-override "[{\"name\":\"ACTION\",\"value\":\"create\"},{\"name\":\"BRANCH\",\"value\":\"${BITBUCKET_BRANCH}\"}]"
```
