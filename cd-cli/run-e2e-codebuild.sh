#!/usr/bin/env bash
set -euo pipefail

echo "### PREPARE VARIABLES ###"

get_ssm() {
  local name="$1"
  aws ssm get-parameters --names "${name}" --query "Parameters[*].Value" --output text
}

SECRETS_JSON="$(aws secretsmanager get-secret-value --secret-id secretsForTests --query SecretString --output text)"
get_secret_field() {
  local field="$1"
  jq -r --arg f "$field" '.[$f]' <<< "${SECRETS_JSON}"
}

set_var() {
  local var_name="$1"
  local var_value="$2"
  printf -v "${var_name}" '%s' "${var_value}"
}

# ---- secretsForTests mappings: VAR FIELD ----
while read -r var field; do
  [ -z "${var:-}" ] && continue
  set_var "${var}" "$(get_secret_field "${field}")"
done <<'EOF'
API_KEY e2eTestApiKey
API_KEY_2 e2eTestApiKey2
API_KEY_GA e2eTestApiKeyGA
API_KEY_SON e2eTestApiKeySON
API_KEY_ROOT e2eTestApiKeyROOT
API_KEY_INTEROP e2eTestApiKeyInterop
API_KEY_2_INTEROP e2eTestApiKey2Interop
API_KEY_GA_INTEROP e2eTestApiKeyGAInterop
API_KEY_SON_INTEROP e2eTestApiKeySONInterop
API_KEY_ROOT_INTEROP e2eTestApiKeyROOTInterop
API_KEY_APPIO e2eAppIOTestApiKey
SENDER_ID_1 e2eTestSenderId1
SENDER_ID_2 e2eTestSenderId2
SENDER_ID_GA e2eTestSenderIdGA
SENDER_ID_SON e2eTestSenderIdSON
SENDER_ID_ROOT e2eTestSenderIdROOT
TOKEN_PA_1 e2eTestBearerTokenPA1
TOKEN_PA_2 e2eTestBearerTokenPA2
TOKEN_PA_GA e2eTestBearerTokenGA
TOKEN_PA_SON e2eTestBearerTokenSON
TOKEN_PA_ROOT e2eTestBearerTokenROOT
CRISTOFORO_C e2eTestBearerTokenCristoforoC
FIERAMOSCA_E e2eTestBearerTokenFieramoscaE
TOKEN_USER_3 e2eTestbearerTokenUser3
TOKEN_USER_4 e2eTestbearerTokenUser4
TOKEN_USER_5 e2eTestbearerTokenUser5
TOKEN_USER_PG_1 e2eTestbearerTokenUserPG1
TOKEN_USER_PG_2 e2eTestbearerTokenUserPG2
PG1_ORGANIZATION_ID e2eTestPg1OrganizationId
PG2_ORGANIZATION_ID e2eTestPg2OrganizationId
SUBSCRIPTION_KEY e2eTestSubscriptionKey
TOKEN_PAY_INFO e2eTestbearerTokenPayInfo
SERVICE_DESK_KEY e2eTestServiceDeskKey
OPEN_SEARCH_USERNAME e2eTestOpenSearchUsername
OPEN_SEARCH_PASSWORD e2eTestOpenSearchPassword
TOKEN_USER_SCADUTO e2eTokenScaduto
TOKEN_RADD_1 e2eTokenRaddista1
TOKEN_RADD_2 e2eTokenRaddista2
TOKEN_RADD_NON_CENSITO e2eTokenRaddNonCensito
TOKEN_RADD_DATI_ERRATI e2eTokenRaddDatiErrati
TOKEN_RADD_JWT_SCADUTO e2eTokenRaddJwtScaduto
TOKEN_RADD_KID_DIVERSO e2eTokenRaddKidDiverso
TOKEN_RADD_AUD_ERRATO e2eTokenRaddAudErrato
TOKEN_RADD_OVER_50KB e2eTokenRaddOver50Kb
EMAIL_PASSWORD e2eEmailPassword
TOKEN_RADD_PRIVATEKEY_DIVERSO e2eTokenRaddPrivateKeyDiverso
SAFE_STORAGE_APIKEY e2eSafeStorageApikey
CONSOLIDATORE_API_KEY e2eConsolidatoreApiKey
INTEROP_CLIENT_ID e2eTestClientIdInterop
INTEROP_TOKEN_ASSERTION e2eTestTokenClientAssertionInterop
TOKEN_RADD_3 e2eTokenRaddista3
TOKEN_B2B_PG_2 e2eTestbearerTokenB2BPG2
TOKEN_USER_PG_3 e2eTestbearerTokenUserPG3
TOKEN_USER_PG_4 e2eTestbearerTokenUserPG4
TOKEN_USER_PG_5 e2eTestbearerTokenUserPG5
PUBLIC_KEY e2eTestPublicKey
PUBLIC_KEY_ROTATION e2eTestPublicKeyRotation
COGNITO_PASSWORD_USER_1 e2eTestCognitoPasswordUser1
COGNITO_CLIENTID_USER_1 e2eTestCognitoClientIdUser1
COGNITO_PASSWORD_USER_2 e2eTestCognitoPasswordUser2
COGNITO_CLIENTID_USER_2 e2eTestCognitoClientIdUser2
EOF

GITHUB_TOKEN="$(aws secretsmanager get-secret-value --secret-id github-token --query SecretString --output text)"

# ---- Parameter-Store mappings: VAR PARAM_NAME ----
while read -r var ssm_name; do
  [ -z "${var:-}" ] && continue
  set_var "${var}" "$(get_ssm "${ssm_name}")"
done <<'EOF'
PRE_RETENTION_TIME /pn-test-e2e/preLoadRetetionTime
LOAD_RETENTION_TIME /pn-test-e2e/loadRetentionTime
PRE_RETENTION_VIDEOTIME /pn-test-e2e/retentionVideotimePreload
SAFE_STORAGE_URL /pn-test-e2e/safeStorageDevUrl
OPERN_SEARCH_URL /pn-test-e2e/OpenSearchUrl
DATA_VAULT_URL /pn-test-e2e/dataVaultUrl
DELIVERY_PUSH_URL /pn-test-e2e/deliveryPushUrl
EXTERNAL_CHANNEL_URL /pn-test-e2e/externalChannelsUrl
DELIVERY_URL /pn-test-e2e/deliveryUrl
PA_TAX_ID_1 /pn-test-e2e/paTaxId1
PA_TAX_ID_2 /pn-test-e2e/paTaxId2
PA_TAX_ID_GA /pn-test-e2e/paTaxIdGA
PA_TAX_ID_SON /pn-test-e2e/paTaxIdSON
PA_TAX_ID_ROOT /pn-test-e2e/paTaxIdROOT
USER_TAX_ID_1 /pn-test-e2e/userTaxId1
USER_TAX_ID_2 /pn-test-e2e/userTaxId2
DOMAIN /pn-test-e2e/domain
DIGITAL_DOMICILIO /pn-test-e2e/digitalDomicile
DIGITAL_DOMICILIO_ALT /pn-test-e2e/digitalDomicileAlt
GPD_URL /pn-test-e2e/GpdUrl
COSTO_BASE_NOTIFICA /pn-test-e2e/CostoBaseNotifica
INTEROP_BASE_URL /pn-test-e2e/interopBaseUrl
INTEROP_TOKEN_PATH /pn-test-e2e/interopTokenPath
IUN_120GG_USER_1 /pn-test-e2e/iun120ggUser1
IUN_120GG_USER_2 /pn-test-e2e/iun120ggUser2
SENDER_EMAIL /pn-test-e2e/senderEmail
REQUEST_ID /pn-test-e2e/requestId
SAFE_STORAGE_CLIENT_ID /pn-test-e2e/safeStorageClientId
IUN_PAYMENT_WITH_PAGOPA /pn-test-e2e/iunPaymentWithPagoPA
IUN_PAYMENT_WITH_F24 /pn-test-e2e/iunPaymentWithF24
IUN_WITHOUT_PAYMENT /pn-test-e2e/iunWithoutPayment
BLACK_LIST_CF MapTaxIdBlackList
COGNITO_USER_1 /pn-test-e2e/cognitoUser1
COGNITO_USER_2 /pn-test-e2e/cognitoUser2
DELAYER_LAMBDA_ARN /pn-test-e2e/pnDelayerLambdaArn
APPIO_QRCODE_URL /pn-test-e2e/appIOQrCodeUrl
IUN_60GG_USER_1 /pn-test-e2e/iun60ggUser1
APPIO_QRCODEV2_URL /pn-test-e2e/appIOQrCodeV2Url
DELEGHE_TEMPORANEE_S3 /pn-test-e2e/delegheTemporaneeBucketS3
EOF

echo "### CLONE E2E TEST REPOSITORY ###"
git clone --depth 1 --branch "${ENV_NAME}" https://github.com/pagopa/pn-b2b-client pn-b2b-client

MAVEN_ARGLINE="-Xms6g -Xmx10g -XX:+UseG1GC -XX:MaxGCPauseMillis=200"

# Build property array (evita problemi di quoting)
COMMON_MAVEN_PARAMS=(
  "-Dpn.external.base-url=https://api.${ENV_NAME}.${DOMAIN}"
  "-Dpn.interop.enable=${INTEROP_ENABLED:-false}"
  "-Dpn.iun.120gg.fieramosca=${IUN_120GG_USER_1}"
  "-Db2b.mail.password=${EMAIL_PASSWORD}"
  "-Db2b.sender.mail=${SENDER_EMAIL}"
  "-Dpn.blacklist.tax-ids=${BLACK_LIST_CF}"
  "-Dpn.iun.120gg.lucio=${IUN_120GG_USER_2}"
  "-Dpn.external.bearer-token-radd-1=${TOKEN_RADD_1}"
  "-Dpn.external.bearer-token-radd-2=${TOKEN_RADD_2}"
  "-Dpn.paper-channel.base-url=${DELIVERY_URL}"
  "-Dpn.external.bearer-token-radd-non-censito=${TOKEN_RADD_NON_CENSITO}"
  "-Dpn.external.bearer-token-radd-dati-errati=${TOKEN_RADD_DATI_ERRATI}"
  "-Dpn.external.bearer-token-radd-3=${TOKEN_RADD_3}"
  "-Dpn.iun.withf24Payment.colombo=${IUN_PAYMENT_WITH_F24}"
  "-Dpn.iun.withPagoPaPayment.colombo=${IUN_PAYMENT_WITH_PAGOPA}"
  "-Dpn.iun.withoutPayment.colombo=${IUN_WITHOUT_PAYMENT}"
  "-Dpn.external.bearer-token-radd-jwt-scaduto=${TOKEN_RADD_JWT_SCADUTO}"
  "-Dpn.external.bearer-token-radd-kid-diverso=${TOKEN_RADD_KID_DIVERSO}"
  "-Dpn.external.bearer-token-radd-aud-erratto=${TOKEN_RADD_AUD_ERRATO}"
  "-Dpn.external.bearer-token-radd-privateKey-diverso=${TOKEN_RADD_PRIVATEKEY_DIVERSO}"
  "-Dpn.safeStorage.apikey=${SAFE_STORAGE_APIKEY}"
  "-Dpn.safeStorage.clientId=${SAFE_STORAGE_CLIENT_ID}"
  "-Dpn.bearer-token.scaduto=${TOKEN_USER_SCADUTO}"
  "-Dpn.external.bearer-token-radd-over-50KB=${TOKEN_RADD_OVER_50KB}"
  "-Dpn.external.api-keys.pagopa-dev-false=${API_KEY}"
  "-Dpn.external.api-keys.pagopa-dev-2-false=${API_KEY_2}"
  "-Dpn.external.api-keys.pagopa-dev-GA-false=${API_KEY_GA}"
  "-Dpn.external.api-keys.pagopa-dev-SON-false=${API_KEY_SON}"
  "-Dpn.external.api-keys.pagopa-dev-ROOT-false=${API_KEY_ROOT}"
  "-Dpn.external.api-keys.pagopa-dev-true=${API_KEY_INTEROP}"
  "-Dpn.external.api-keys.pagopa-dev-2-true=${API_KEY_2_INTEROP}"
  "-Dpn.external.api-keys.pagopa-dev-GA-true=${API_KEY_GA_INTEROP}"
  "-Dpn.external.api-keys.pagopa-dev-SON-true=${API_KEY_SON_INTEROP}"
  "-Dpn.external.api-keys.pagopa-dev-ROOT-true=${API_KEY_ROOT_INTEROP}"
  "-Dpn.interop.token-oauth2.path=${INTEROP_TOKEN_PATH}"
  "-Dpn.interop.base-url=${INTEROP_BASE_URL}"
  "-Dpn.interop.token-oauth2.client-assertion=${INTEROP_TOKEN_ASSERTION}"
  "-Dpn.interop.clientId=${INTEROP_CLIENT_ID}"
  "-Dpn.OpenSearch.base-url=${OPERN_SEARCH_URL}"
  "-Dpn.retention.videotime.preload=${PRE_RETENTION_VIDEOTIME}"
  "-Dpn.OpenSearch.password=${OPEN_SEARCH_PASSWORD}"
  "-Dpn.OpenSearch.username=${OPEN_SEARCH_USERNAME}"
  "-Dpn.external.api-keys.service-desk=${SERVICE_DESK_KEY}"
  "-Dpn.external.bearer-token-pg2.id=${PG2_ORGANIZATION_ID}"
  "-Dpn.external.bearer-token-pg1.id=${PG1_ORGANIZATION_ID}"
  "-Dpn.external.costo_base_notifica=${COSTO_BASE_NOTIFICA}"
  "-Dpn.external.digitalDomicile.address=${DIGITAL_DOMICILIO}"
  "-Dpn.external.digitalDomicile.address.alt=${DIGITAL_DOMICILIO_ALT}"
  "-Dpn.internal.gpd-base-url=${GPD_URL}"
  "-Dspring.profiles.active=${ENV_NAME}"
  "-Dpn.external.bearer-token-pa-1=${TOKEN_PA_1}"
  "-Dpn.external.bearer-token-pa-2=${TOKEN_PA_2}"
  "-Dpn.external.bearer-token-pa-GA=${TOKEN_PA_GA}"
  "-Dpn.external.bearer-token-pa-SON=${TOKEN_PA_SON}"
  "-Dpn.external.bearer-token-pa-ROOT=${TOKEN_PA_ROOT}"
  "-Dpn.bearer-token.user3=${TOKEN_USER_3}"
  "-Dpn.bearer-token.user4=${TOKEN_USER_4}"
  "-Dpn.bearer-token.user5=${TOKEN_USER_5}"
  "-Dpn.bearer-token.pg1=${TOKEN_USER_PG_1}"
  "-Dpn.bearer-token.pg2=${TOKEN_USER_PG_2}"
  "-Dpn.external.api-key-taxID=${PA_TAX_ID_1}"
  "-Dpn.external.api-key-2-taxID=${PA_TAX_ID_2}"
  "-Dpn.external.api-key-GA-taxID=${PA_TAX_ID_GA}"
  "-Dpn.external.api-key-SON-taxID=${PA_TAX_ID_SON}"
  "-Dpn.external.api-key-ROOT-taxID=${PA_TAX_ID_ROOT}"
  "-Dpn.bearer-token.user1.taxID=${USER_TAX_ID_1}"
  "-Dpn.bearer-token.user2.taxID=${USER_TAX_ID_2}"
  "-Dpn.external.senderId=${SENDER_ID_1}"
  "-Dpn.external.senderId-2=${SENDER_ID_2}"
  "-Dpn.external.senderId-GA=${SENDER_ID_GA}"
  "-Dpn.external.senderId-SON=${SENDER_ID_SON}"
  "-Dpn.external.senderId-ROOT=${SENDER_ID_ROOT}"
  "-Dpn.external.appio.api-key=${API_KEY_APPIO}"
  "-Dpn.radd.alt.external.base-url=https://api.radd.${ENV_NAME}.${DOMAIN}"
  "-Dpn.webapi.external.base-url=https://webapi.${ENV_NAME}.${DOMAIN}"
  "-Dpn.appio.externa.base-url=https://api-io.${ENV_NAME}.${DOMAIN}"
  "-Dpn.bearer-token.user2=${CRISTOFORO_C}"
  "-Dpn.bearer-token.user1=${FIERAMOSCA_E}"
  "-Dpn.retention.time.preload=${PRE_RETENTION_TIME}"
  "-Dpn.retention.time.load=${LOAD_RETENTION_TIME}"
  "-Dpn.safeStorage.base-url=${SAFE_STORAGE_URL}"
  "-Dpn.internal.delivery-push-base-url=${DELIVERY_PUSH_URL}"
  "-Dpn.externalChannels.base-url=${EXTERNAL_CHANNEL_URL}"
  "-Dpn.external.api-subscription-key=${SUBSCRIPTION_KEY}"
  "-Dpn.bearer-token-payinfo=${TOKEN_PAY_INFO}"
  "-Dpn.dataVault.base-url=${DATA_VAULT_URL}"
  "-Dpn.consolidatore.api.key=${CONSOLIDATORE_API_KEY}"
  "-Dpn.radd.base-url=${DELIVERY_PUSH_URL}"
  "-Dpn.consolidatore.requestId=${REQUEST_ID}"
  "-Dpn.delivery.base-url=${DELIVERY_URL}"
  "-Dpn.external.dest.base-url=https://api.dest.${ENV_NAME}.${DOMAIN}"
  "-Dpn.bearer-token-b2b.pg2=${TOKEN_B2B_PG_2}"
  "-Dpn.bearer-token.pg3=${TOKEN_USER_PG_3}"
  "-Dpn.bearer-token.pg4=${TOKEN_USER_PG_4}"
  "-Dpn.bearer-token.pg5=${TOKEN_USER_PG_5}"
  "-Dpn.authentication.pg.public.key=https://api.dest.${PUBLIC_KEY}"
  "-Dpn.authentication.pg.public.key.rotation=${PUBLIC_KEY_ROTATION}"
  "-Dpn.external.radd-cognito-user-1=${COGNITO_USER_1}"
  "-Dpn.external.radd-cognito-password-user-1=${COGNITO_PASSWORD_USER_1}"
  "-Dpn.external.radd-cognito-clientid-user-1=${COGNITO_CLIENTID_USER_1}"
  "-Dpn.external.radd-cognito-user-2=${COGNITO_USER_2}"
  "-Dpn.external.radd-cognito-password-user-2=${COGNITO_PASSWORD_USER_2}"
  "-Dpn.external.radd-cognito-clientid-user-2=${COGNITO_CLIENTID_USER_2}"
  "-Dgithub.token=${GITHUB_TOKEN}"
  "-Dpn.appIO.checkQrCode-bodyUrl=${APPIO_QRCODE_URL}"
  "-Dpn.delayer.lambda.arn=${DELAYER_LAMBDA_ARN}"
  "-Dpn.iun.60gg.fieramosca=${IUN_60GG_USER_1}"
  "-Dpn.appIO.checkQrCodeV2-bodyUrl=${APPIO_QRCODEV2_URL}"
  "-Dpn-deleghe-temporanee-bucket-s3=${DELEGHE_TEMPORANEE_S3}"
  "-Djdk.httpclient.allowRestrictedMethods=PATCH"
)

MAIN_SUITE="${TEST_SUITE:-NrtTest_${ENV_NAME}}"
RERUN_SUITE="${TEST_SUITE_RERUN:-RerunFailedTestSuite}"

echo "### RUN MAIN SUITE: ${MAIN_SUITE} ###"
(
  cd pn-b2b-client
  MAVEN_OPTS='-Xms1g -Xmx2g' ./mvnw \
    "-DargLine=${MAVEN_ARGLINE}" \
    "-Dtest=it.pagopa.pn.cucumber.${MAIN_SUITE}" \
    "${COMMON_MAVEN_PARAMS[@]}" \
    clean verify
)

REPORT_JSON_TO_USE="pn-b2b-client/target/cucumber-report.json"

if [ "${ENABLE_RERUN:-false}" = "true" ]; then
  echo "### RUN RERUN SUITE: ${RERUN_SUITE} ###"
  (
    cd pn-b2b-client
    MAVEN_OPTS='-Xms1g -Xmx2g' ./mvnw \
      "-DargLine=${MAVEN_ARGLINE}" \
      "-Dtest=it.pagopa.pn.cucumber.${RERUN_SUITE}" \
      "${COMMON_MAVEN_PARAMS[@]}" \
      verify

    echo "### GENERATE MERGED CUCUMBER REPORT ###"
    ./mvnw exec:java@process-cucumber-report
  )
  REPORT_JSON_TO_USE="pn-b2b-client/target/cucumber-report-merged.json"
fi

echo "### PREPARE CODEBUILD ARTIFACTS ###"
ARTIFACTS_DIR="pn-b2b-client/target/codebuild-artifacts"
rm -rf "${ARTIFACTS_DIR}"
mkdir -p "${ARTIFACTS_DIR}"

cp "${REPORT_JSON_TO_USE}" "${ARTIFACTS_DIR}/cucumber-report-to-publish.json"
cp "pn-b2b-client/target/cucumber-report.csv" "${ARTIFACTS_DIR}/"
cp "pn-b2b-client/target/cucumber-report.json" "${ARTIFACTS_DIR}/" || true
cp "pn-b2b-client/target/cucumber-report.html" "${ARTIFACTS_DIR}/" || true

if [ "${ENABLE_RERUN:-false}" = "true" ]; then
  cp "pn-b2b-client/target/cucumber-report-rerun.html" "${ARTIFACTS_DIR}/" || true
  cp -R "pn-b2b-client/target/cucumber-html-reports" "${ARTIFACTS_DIR}/" || true
fi

echo "### DONE ###"
