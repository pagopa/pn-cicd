BE_MVN_COMMON_PROJECTS=(pn-parent pn-model pn-commons pn-authotization)
BE_MVN_PROJECTS=(pn-delivery pn-delivery-push pn-external-registries pn-mandate pn-data-vault\
 pn-user-attributes pn-radd-fsu pn-downtime-logs\
 pn-logextractor-be pn-logsaver-be pn-national-registries \
 pn-apikey-manager \
 pn-bff)
BE_PROJECTS+=( "${BE_MVN_COMMON_PROJECTS[@]}" "${BE_MVN_PROJECTS[@]}")
FE_PROJECTS=(pn-frontend pn-helpdesk-fe)
INFRA_PROJECTS=(pn-infra pn-cicd pn-auth-fleet)

MOCK_PROJECTS=(pn-external-channels pn-safe-storage)
TEST_PROJECTS=(pn-b2b-client)

OTHER_PROJECTS=(pn-localdev pn-hub-spid-login-aws)

ALL_ACTIVE_PROJECTS+=( "${BE_PROJECTS[@]}" "${FE_PROJECTS[@]}" "${INFRA_PROJECTS[@]}" "${MOCK_PROJECTS[@]}" "${OTHER_PROJECTS[@]}" )
FE_PROJECTS=(pn-frontend pn-helpdesk-fe)

UNUSED_PROJECTS=(pn-design pn-legal-facts)

GH_PREFIX="git@github.com:pagopa"