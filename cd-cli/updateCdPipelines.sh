#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h]

Required environment:
  AWS_REGION, ACCOUNT_TYPE, ENV_NAME, PROJECT_NAME
  UPDATER_STACK, TARGET_STACK, ARTIFACT_BUCKET
EOF
}

parse_params() {
  case "${1-}" in
    -h | --help) usage; exit 0 ;;
    '') ;;
    *) fail "Unknown option: $1" ;;
  esac

  : "${AWS_REGION:?}" "${ENV_NAME:?}" "${PROJECT_NAME:?}" "${UPDATER_STACK:?}"
  : "${TARGET_STACK:?}" "${ARTIFACT_BUCKET:?}"
  : "${ACCOUNT_TYPE:?}"
  case "$ACCOUNT_TYPE" in
    CORE) domain=core ;;
    CONFINFO) domain=confinfo ;;
    *) fail 'Expected ACCOUNT_TYPE CORE or CONFINFO' ;;
  esac
  export AWS_PAGER='' AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=3
  aws_command_base_args=(--region "$AWS_REGION")
}

dump_params() {
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:      ${PROJECT_NAME}"
  echo "Env Name:          ${ENV_NAME}"
  echo "AWS region:        ${AWS_REGION}"
  echo "Account type:      ${ACCOUNT_TYPE}"
  echo "Updater stack:     ${UPDATER_STACK}"
  echo "Target stack:      ${TARGET_STACK}"
  echo "Bucket Name:       ${ARTIFACT_BUCKET}"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

aws_cli() {
  aws "${aws_command_base_args[@]}" "$@"
}

read_stack() {
  aws_cli cloudformation describe-stacks --stack-name "$1" > "$2" || fail "Cannot read stack $1"
}

ready_stack() {
  jq -e '.Stacks | length == 1' "$1" > /dev/null || fail 'Expected one stack'
  case $(jq -r '.Stacks[0].StackStatus' "$1") in
    CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE) ;;
    *) fail "Stack is not ready: $(jq -r '.Stacks[0].StackStatus' "$1")" ;;
  esac
}

check_pipelines() {
  local name count pipelines
  pipelines=$(aws_cli cloudformation list-stack-resources --stack-name "$1" \
    --query "StackResourceSummaries[?ResourceType=='AWS::CodePipeline::Pipeline'].PhysicalResourceId" \
    --output json | jq -r 'unique[]')
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    count=$(aws_cli codepipeline list-pipeline-executions --pipeline-name "$name" \
      --no-paginate --max-results 100 \
      --query "length(pipelineExecutionSummaries[?status=='InProgress' || status=='Stopping'])" --output json)
    [[ $count == 0 ]] || fail "Pipeline is busy: $name. Retry after the current execution finishes."
  done <<< "$pipelines"
}

deploy_stack() {
  aws_cli cloudformation deploy \
    --stack-name "$1" \
    --template-file "$2" \
    --s3-bucket "$ARTIFACT_BUCKET" \
    --s3-prefix "${PROJECT_NAME}-cicd-update" \
    --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset
}

main() {
  work=$(mktemp -d)
  local target_id updater_id cicd_commit
  read_stack "$TARGET_STACK" "$work/target.json"
  read_stack "$UPDATER_STACK" "$work/self.json"
  ready_stack "$work/target.json"
  ready_stack "$work/self.json"
  target_id=$(jq -r '.Stacks[0].StackId' "$work/target.json")
  updater_id=$(jq -r '.Stacks[0].StackId' "$work/self.json")
  [[ $target_id != "$updater_id" ]] || fail 'Target and updater must be different stacks'
  jq -e --arg env "$ENV_NAME" --arg project "$PROJECT_NAME" '.Stacks[0] |
    any(.Parameters[]; .ParameterKey == "EnvName" and .ParameterValue == $env) and
    any(.Parameters[]; .ParameterKey == "ProjectName" and .ParameterValue == $project)' \
    "$work/target.json" > /dev/null || fail 'Stack context mismatch'
  # Only the CORE Complete declares E2ESubnetsIds.
  jq -e --arg domain "$domain" '(any(.Stacks[0].Parameters[]; .ParameterKey == "E2ESubnetsIds")) == ($domain == "core")' \
    "$work/target.json" > /dev/null || fail 'Account type does not match target stack'
  jq -e --arg bucket "$ARTIFACT_BUCKET" 'any(.Stacks[0].Outputs[]?;
    .OutputKey == "CdArtifactBucketName" and .OutputValue == $bucket)' "$work/target.json" > /dev/null ||
    fail 'Artifact bucket does not belong to the target'
  cicd_commit=$(awk -F= '/^[[:blank:]]*(export[[:blank:]]+)?cd_scripts_commitId=/ { v = $2 } END { print v }' \
    desired-commit-ids-env.sh)
  [[ -n $cicd_commit ]] || fail 'Missing cd_scripts_commitId'
  local template=cd-cli/cnf-templates/complete-pipeline.yaml
  [[ $domain == core ]] || template=cd-cli/cnf-templates/confinfo-complete-pipeline.yaml
  [[ -f $template && -f cd-cli/cnf-templates/cicd-update-pipeline.yaml ]] ||
    fail 'Selected release does not contain the updater'
  echo "Domain=$domain cicd=$cicd_commit"
  deploy_stack "$UPDATER_STACK" cd-cli/cnf-templates/cicd-update-pipeline.yaml
  check_pipelines "$TARGET_STACK"
  deploy_stack "$TARGET_STACK" "$template"
  echo "Pipeline maintenance complete: $target_id at $cicd_commit"
}

# START SCRIPT

parse_params "$@"
dump_params
main
