#!/usr/bin/env bash
#
# fetchE2ETestConfig.sh
#
# Recupera segreti (AWS Secrets Manager) e parametri (AWS SSM Parameter Store)
# usati dai test e2e B2B e assembla la lista delle proprieta' Maven (-D...).
#
# Lo script va "sourced" dal buildspec del CodeBuild RunTestsCodebuildProject:
#
#     source ./pn-cicd/cd-cli/fetchE2ETestConfig.sh
#     ( cd pn-b2b-client && ./mvnw ... "${MVN_PROPS[@]}" clean verify )
#
# Al termine espone l'array bash MVN_PROPS gia' pronto da passare a Maven.
#
# ------------------------------------------------------------------------------
# MANUTENZIONE
# ------------------------------------------------------------------------------
# Per aggiungere/rimuovere un valore basta toccare UNA sola riga nella tabella
# corretta qui sotto (SECRET_PROPS / SSM_PROPS / sezione derivate-statiche).
# Ogni riga ha il formato "proprieta.maven=sorgente":
#
#   * segreto       -> SECRET_PROPS:  "proprieta.maven=chiaveNelSegreto"
#   * parametro SSM -> SSM_PROPS:     "proprieta.maven=/nome/parametro"
#
# Non serve piu' modificare anche il comando Maven: l'array MVN_PROPS viene
# generato automaticamente dalle tabelle.
# ------------------------------------------------------------------------------

set -euo pipefail

: "${ENV_NAME:?ENV_NAME deve essere valorizzato}"

# Tutti i segreti dei test stanno in un'unica entry di Secrets Manager: la
# leggiamo una sola volta e poi estraiamo le singole chiavi con jq.
SECRETS_JSON="$(aws secretsmanager get-secret-value \
  --secret-id secretsForTests --query SecretString --output text)"

# ------------------------------------------------------------------------------
# Helper
# ------------------------------------------------------------------------------

# Estrae una chiave dal bundle dei segreti: _secret <chiaveJson>
_secret() { jq -r --arg k "$1" '.[$k]' <<<"$SECRETS_JSON"; }

# Legge un parametro SSM: _ssm <nome>
_ssm() {
  aws ssm get-parameters --names "$1" --query "Parameters[*].Value" --output text
}

# Array finale passato a Maven
MVN_PROPS=()
_prop() { MVN_PROPS+=("-D$1=$2"); }

# ==============================================================================
# SEGRETI  ->  "proprieta.maven=chiaveNelSegreto"
# ==============================================================================
SECRET_PROPS=(
  "pn.external.api-keys.pagopa-dev-false=e2eTestApiKey"
  "pn.external.api-keys.pagopa-dev-2-false=e2eTestApiKey2"
  "pn.external.api-keys.pagopa-dev-GA-false=e2eTestApiKeyGA"
  "pn.external.api-keys.pagopa-dev-SON-false=e2eTestApiKeySON"
  "pn.external.api-keys.pagopa-dev-ROOT-false=e2eTestApiKeyROOT"
  "pn.external.api-keys.pagopa-dev-true=e2eTestApiKeyInterop"
  "pn.external.api-keys.pagopa-dev-2-true=e2eTestApiKey2Interop"
  "pn.external.api-keys.pagopa-dev-GA-true=e2eTestApiKeyGAInterop"
  "pn.external.api-keys.pagopa-dev-SON-true=e2eTestApiKeySONInterop"
  "pn.external.api-keys.pagopa-dev-ROOT-true=e2eTestApiKeyROOTInterop"
  "pn.external.appio.api-key=e2eAppIOTestApiKey"
  "pn.external.senderId=e2eTestSenderId1"
  "pn.external.senderId-2=e2eTestSenderId2"
  "pn.external.senderId-GA=e2eTestSenderIdGA"
  "pn.external.senderId-SON=e2eTestSenderIdSON"
  "pn.external.senderId-SON-2=e2eTestSenderIdSON2"
  "pn.external.senderId-ROOT=e2eTestSenderIdROOT"
  "pn.external.bearer-token-pa-1=e2eTestBearerTokenPA1"
  "pn.external.bearer-token-pa-2=e2eTestBearerTokenPA2"
  "pn.external.bearer-token-pa-GA=e2eTestBearerTokenGA"
  "pn.external.bearer-token-pa-SON=e2eTestBearerTokenSON"
  "pn.external.bearer-token-pa-ROOT=e2eTestBearerTokenROOT"
  "pn.bearer-token.user2=e2eTestBearerTokenCristoforoC"
  "pn.bearer-token.user1=e2eTestBearerTokenFieramoscaE"
  "pn.bearer-token.user3=e2eTestbearerTokenUser3"
  "pn.bearer-token.user4=e2eTestbearerTokenUser4"
  "pn.bearer-token.user5=e2eTestbearerTokenUser5"
  "pn.bearer-token.pg1=e2eTestbearerTokenUserPG1"
  "pn.bearer-token.pg2=e2eTestbearerTokenUserPG2"
  "pn.external.bearer-token-pg1.id=e2eTestPg1OrganizationId"
  "pn.external.bearer-token-pg2.id=e2eTestPg2OrganizationId"
  "pn.external.api-subscription-key=e2eTestSubscriptionKey"
  "pn.bearer-token-payinfo=e2eTestbearerTokenPayInfo"
  "pn.external.api-keys.service-desk=e2eTestServiceDeskKey"
  "pn.OpenSearch.username=e2eTestOpenSearchUsername"
  "pn.OpenSearch.password=e2eTestOpenSearchPassword"
  "pn.bearer-token.scaduto=e2eTokenScaduto"
  "pn.external.bearer-token-radd-1=e2eTokenRaddista1"
  "pn.external.bearer-token-radd-2=e2eTokenRaddista2"
  "pn.external.bearer-token-radd-3=e2eTokenRaddista3"
  "pn.external.bearer-token-radd-non-censito=e2eTokenRaddNonCensito"
  "pn.external.bearer-token-radd-dati-errati=e2eTokenRaddDatiErrati"
  "pn.external.bearer-token-radd-jwt-scaduto=e2eTokenRaddJwtScaduto"
  "pn.external.bearer-token-radd-kid-diverso=e2eTokenRaddKidDiverso"
  "pn.external.bearer-token-radd-aud-erratto=e2eTokenRaddAudErrato"
  "pn.external.bearer-token-radd-over-50KB=e2eTokenRaddOver50Kb"
  "pn.external.bearer-token-radd-privateKey-diverso=e2eTokenRaddPrivateKeyDiverso"
  "b2b.mail.password=e2eEmailPassword"
  "pn.safeStorage.apikey=e2eSafeStorageApikey"
  "pn.consolidatore.api.key=e2eConsolidatoreApiKey"
  "pn.interop.clientId=e2eTestClientIdInterop"
  "pn.interop.token-oauth2.client-assertion=e2eTestTokenClientAssertionInterop"
  "pn.bearer-token-b2b.pg2=e2eTestbearerTokenB2BPG2"
  "pn.bearer-token.pg3=e2eTestbearerTokenUserPG3"
  "pn.bearer-token.pg4=e2eTestbearerTokenUserPG4"
  "pn.bearer-token.pg5=e2eTestbearerTokenUserPG5"
  "pn.authentication.pg.public.key.rotation=e2eTestPublicKeyRotation"
  "pn.external.radd-cognito-password-user-1=e2eTestCognitoPasswordUser1"
  "pn.external.radd-cognito-clientid-user-1=e2eTestCognitoClientIdUser1"
  "pn.external.radd-cognito-password-user-2=e2eTestCognitoPasswordUser2"
  "pn.external.radd-cognito-clientid-user-2=e2eTestCognitoClientIdUser2"
)

# ==============================================================================
# PARAMETRI SSM  ->  "proprieta.maven=/nome/parametro"
# ==============================================================================
SSM_PROPS=(
  "pn.iun.120gg.fieramosca=/pn-test-e2e/iun120ggUser1"
  "pn.iun.120gg.lucio=/pn-test-e2e/iun120ggUser2"
  "pn.iun.120gg.gherkin=/pn-test-e2e/iun120ggUser3"
  "pn.iun.60gg.fieramosca=/pn-test-e2e/iun60ggUser1"
  "pn.iun.withf24Payment.colombo=/pn-test-e2e/iunPaymentWithF24"
  "pn.iun.withPagoPaPayment.colombo=/pn-test-e2e/iunPaymentWithPagoPA"
  "pn.iun.withoutPayment.colombo=/pn-test-e2e/iunWithoutPayment"
  "pn.notification-mario.gherkin.older-10-years=/pn-test-e2e/iun10years"
  "pn.legalFact-mario.gherkin.older-10-years=/pn-test-e2e/legalFact10years"
  "b2b.sender.mail=/pn-test-e2e/senderEmail"
  "pn.blacklist.tax-ids=MapTaxIdBlackList"
  "pn.paper-channel.base-url=/pn-test-e2e/deliveryUrl"
  "pn.delivery.base-url=/pn-test-e2e/deliveryUrl"
  "pn.radd.base-url=/pn-test-e2e/deliveryPushUrl"
  "pn.internal.delivery-push-base-url=/pn-test-e2e/deliveryPushUrl"
  "pn.externalChannels.base-url=/pn-test-e2e/externalChannelsUrl"
  "pn.dataVault.base-url=/pn-test-e2e/dataVaultUrl"
  "pn.safeStorage.base-url=/pn-test-e2e/safeStorageDevUrl"
  "pn.safeStorage.clientId=/pn-test-e2e/safeStorageClientId"
  "pn.OpenSearch.base-url=/pn-test-e2e/OpenSearchUrl"
  "pn.interop.base-url=/pn-test-e2e/interopBaseUrl"
  "pn.interop.token-oauth2.path=/pn-test-e2e/interopTokenPath"
  "pn.internal.gpd-base-url=/pn-test-e2e/GpdUrl"
  "pn.retention.time.preload=/pn-test-e2e/preLoadRetetionTime"
  "pn.retention.time.load=/pn-test-e2e/loadRetentionTime"
  "pn.retention.videotime.preload=/pn-test-e2e/retentionVideotimePreload"
  "pn.external.costo_base_notifica=/pn-test-e2e/CostoBaseNotifica"
  "pn.external.digitalDomicile.address=/pn-test-e2e/digitalDomicile"
  "pn.external.digitalDomicile.address.alt=/pn-test-e2e/digitalDomicileAlt"
  "pn.external.api-key-taxID=/pn-test-e2e/paTaxId1"
  "pn.external.api-key-2-taxID=/pn-test-e2e/paTaxId2"
  "pn.external.api-key-GA-taxID=/pn-test-e2e/paTaxIdGA"
  "pn.external.api-key-SON-taxID=/pn-test-e2e/paTaxIdSON"
  "pn.external.api-key-ROOT-taxID=/pn-test-e2e/paTaxIdROOT"
  "pn.bearer-token.user1.taxID=/pn-test-e2e/userTaxId1"
  "pn.bearer-token.user2.taxID=/pn-test-e2e/userTaxId2"
  "pn.consolidatore.requestId=/pn-test-e2e/requestId"
  "pn.external.radd-cognito-user-1=/pn-test-e2e/cognitoUser1"
  "pn.external.radd-cognito-user-2=/pn-test-e2e/cognitoUser2"
  "pn.appIO.checkQrCode-bodyUrl=/pn-test-e2e/appIOQrCodeUrl"
  "pn.appIO.checkQrCodeV2-bodyUrl=/pn-test-e2e/appIOQrCodeV2Url"
  "pn.delayer.lambda.arn=/pn-test-e2e/pnDelayerLambdaArn"
  "pn.delayer.portfat.lambda.name=/pn-test-e2e/portfatLambdaArn"
  "pn-deleghe-temporanee-bucket-s3=/pn-test-e2e/delegheTemporaneeBucketS3"
  # NB: pn.radd-vpc.base-url e' condizionale (vedi sezione DERIVATE / STATICHE).
)

# ------------------------------------------------------------------------------
# Costruzione MVN_PROPS dalle tabelle (formato riga: "prop=sorgente")
# ------------------------------------------------------------------------------
for entry in "${SECRET_PROPS[@]}"; do
  _prop "${entry%%=*}" "$(_secret "${entry#*=}")"
done

for entry in "${SSM_PROPS[@]}"; do
  _prop "${entry%%=*}" "$(_ssm "${entry#*=}")"
done

# ==============================================================================
# PROPRIETA' DERIVATE / STATICHE
# (URL costruiti da ENV_NAME + DOMAIN, valori fissi, segreti speciali)
# ==============================================================================
DOMAIN="$(_ssm /pn-test-e2e/domain)"
PUBLIC_KEY="$(_secret e2eTestPublicKey)"
# Token GitHub: vive in un segreto separato (l'intera stringa e' il token).
GITHUB_TOKEN="$(aws secretsmanager get-secret-value \
  --secret-id github-token --query SecretString --output text)"

_prop "pn.external.base-url"            "https://api.${ENV_NAME}.${DOMAIN}"
_prop "pn.external.dest.base-url"       "https://api.dest.${ENV_NAME}.${DOMAIN}"
_prop "pn.radd.alt.external.base-url"   "https://api.radd.${ENV_NAME}.${DOMAIN}"
_prop "pn.webapi.external.base-url"     "https://webapi.${ENV_NAME}.${DOMAIN}"
_prop "pn.appio.externa.base-url"       "https://api-io.${ENV_NAME}.${DOMAIN}"
_prop "pn.authentication.pg.public.key" "https://api.dest.${PUBLIC_KEY}"
_prop "pn.interop.enable"               "${INTEROP_ENABLED:-false}"
_prop "spring.profiles.active"          "${ENV_NAME}"
_prop "jdk.httpclient.allowRestrictedMethods" "PATCH"
_prop "github.token"                    "${GITHUB_TOKEN}"

# pn.radd-vpc.base-url: il parametro SSM da leggere dipende dal flag opzionale
# RADD_POSTE_ENV:
#   test -> /pn-test-e2e/raddVpcBaseUrlTest
#   uat  -> /pn-test-e2e/raddVpcBaseUrlUat
#   altro/non valorizzato -> /pn-test-e2e/raddVpcBaseUrlHotfix

if [ "${RADD_POSTE_ENV:-}" = "test" ]; then
  _prop "pn.radd-vpc.base-url" "$(_ssm /pn-test-e2e/raddVpcBaseUrlTest)"
elif [ "${RADD_POSTE_ENV:-}" = "uat" ]; then
  _prop "pn.radd-vpc.base-url" "$(_ssm /pn-test-e2e/raddVpcBaseUrlUat)"
else
  _prop "pn.radd-vpc.base-url" "$(_ssm /pn-test-e2e/raddVpcBaseUrlHotfix)"
fi

echo "### fetch-test-config: caricate ${#MVN_PROPS[@]} proprieta' Maven ###"
