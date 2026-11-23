#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h]

Required environment:
  AWS_REGION, AWS_PARTITION, ACCOUNT_ID, ACCOUNT_TYPE, ENV_NAME, PROJECT_NAME
  UPDATER_STACK, TARGET_STACK, ARTIFACT_BUCKET, CODEBUILD_BUILD_ID
EOF
}

parse_params() {
  case "${1-}" in
    -h | --help) usage; exit 0 ;;
    '') ;;
    *) fail "Unknown option: $1" ;;
  esac

  : "${AWS_REGION:?}" "${AWS_PARTITION:?}" "${ENV_NAME:?}" "${PROJECT_NAME:?}" "${ACCOUNT_ID:?}" "${UPDATER_STACK:?}"
  : "${TARGET_STACK:?}" "${ARTIFACT_BUCKET:?}" "${CODEBUILD_BUILD_ID:?}"
  : "${ACCOUNT_TYPE:?}"
  case "$ACCOUNT_TYPE" in
    CORE) domain=core ;;
    CONFINFO) domain=confinfo ;;
    *) fail 'Expected ACCOUNT_TYPE CORE or CONFINFO' ;;
  esac
  build_id=${CODEBUILD_BUILD_ID##*:}
  [[ $build_id =~ ^[a-f0-9-]{36}$ ]] || fail 'Invalid build ID'

  aws_command_base_args=(--region "$AWS_REGION")
}

dump_params() {
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:      ${PROJECT_NAME}"
  echo "Env Name:          ${ENV_NAME}"
  echo "AWS region:        ${AWS_REGION}"
  echo "Account ID:        ${ACCOUNT_ID}"
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
  local name=$1 output=$2
  if aws_cli cloudformation describe-stacks --stack-name "$name" > "$output" 2> "$work/error"; then
    return 0
  fi
  if grep -Fq "Stack with id $name does not exist" "$work/error"; then
    return 1
  fi
  cat "$work/error" >&2
  fail "Cannot inspect stack $name"
}

ready_stack() {
  jq -e '.Stacks | length == 1' "$1" > /dev/null || fail 'Expected one stack'
  case $(jq -r '.Stacks[0].StackStatus' "$1") in
    CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE) ;;
    *) fail "Stack is not ready: $(jq -r '.Stacks[0].StackStatus' "$1")" ;;
  esac
}

check_changed_pipelines() {
  local name count pipelines
  pipelines=$(jq -r '
    [.Changes[].ResourceChange | select(.ResourceType == "AWS::CodePipeline::Pipeline")
      | (.BeforeContext | fromjson | .Properties.Name)] | unique[]' "$1")
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    count=$(aws_cli codepipeline list-pipeline-executions --pipeline-name "$name" \
      --query "length(pipelineExecutionSummaries[?status=='InProgress' || status=='Stopping'])" --output json)
    [[ $count == 0 ]] || fail "Pipeline is busy: $name. Retry after the current execution finishes."
  done <<< "$pipelines"
}

prepare_change_set() {
  set -e
  local stack=$1 template=$2 kind=$3 parameters=$4 change status reason
  change="pn-cicd-update-$build_id-$kind"
  aws_cli s3api put-object --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
    --key "pn-cicd-update/$build_id/$kind.yaml" --body "$template" --server-side-encryption AES256 > /dev/null
  aws_cli cloudformation create-change-set --stack-name "$stack" --change-set-name "$change" \
    --change-set-type UPDATE --client-token "$build_id-$kind" --capabilities CAPABILITY_NAMED_IAM \
    --template-url "https://s3.$AWS_REGION.amazonaws.com/$ARTIFACT_BUCKET/pn-cicd-update/$build_id/$kind.yaml" \
    --parameters "file://$parameters" > /dev/null
  aws_cli cloudformation wait change-set-create-complete --stack-name "$stack" --change-set-name "$change" || true
  aws_cli cloudformation describe-change-set --stack-name "$stack" --change-set-name "$change" \
    --include-property-values --output json > "$work/$kind-change.json"
  status=$(jq -r '.Status' "$work/$kind-change.json")
  if [[ $status == FAILED ]]; then
    reason=$(jq -r '.StatusReason' "$work/$kind-change.json")
    case "$reason" in
      *"didn't contain changes"*|*"No updates are to be performed"*)
        aws_cli cloudformation delete-change-set --stack-name "$stack" --change-set-name "$change"
        printf 'none\n'; return ;;
      *) fail "$reason" ;;
    esac
  fi
  [[ $status == CREATE_COMPLETE ]] || fail "Change set not ready: $change"
  jq -e '
    (.Changes | length > 0) and all(.Changes[].ResourceChange;
      .Action == "Modify" and .Replacement == "False" and
      (.ResourceType == "AWS::CodePipeline::Pipeline" or .ResourceType == "AWS::CodeBuild::Project") and
      ((.BeforeContext | fromjson) as $before | (.AfterContext | fromjson) as $after |
      ($before.Properties | type == "object") and ($after.Properties | type == "object") and
      ($before.Properties.Name | type == "string") and
      (
      if .ResourceType == "AWS::CodePipeline::Pipeline" then
        ($before.Properties.Name | length > 0) and
        ($before.Properties.RoleArn | type == "string") and
        ($before.Properties.RestartExecutionOnUpdate | tostring) != "true" and
        ($after.Properties.RestartExecutionOnUpdate | tostring) != "true" and
        $before.Properties.RoleArn == $after.Properties.RoleArn and
        $before.Properties.Name == $after.Properties.Name and
        $before.Properties.Stages[0] == $after.Properties.Stages[0] and
        $before.Properties.Triggers == $after.Properties.Triggers
      else
        ($before.Properties.ServiceRole | type == "string") and
        $before.Properties.ServiceRole == $after.Properties.ServiceRole and
        $before.Properties.Name == $after.Properties.Name
      end)))' "$work/$kind-change.json" > /dev/null || fail "Unsafe change set: $change"
  jq -r '.ChangeSetId' "$work/$kind-change.json"
}

execute_change_set() {
  local stack=$1 change=$2
  if [[ $change == none ]]; then
    echo "No changes: $stack"
    return 0
  fi
  echo "Updating $stack: $change"
  aws_cli cloudformation execute-change-set --stack-name "$stack" --change-set-name "$change" \
    --client-request-token "$build_id-$(basename "$stack")"
  aws_cli cloudformation wait stack-update-complete --stack-name "$stack"
}

main() {
  work=$(mktemp -d)
  local target_id updater_id cicd_commit
  local self_change target_change
  read_stack "$TARGET_STACK" "$work/target.json" || fail 'Target stack does not exist'
  read_stack "$UPDATER_STACK" "$work/self.json" || fail 'Updater stack does not exist'
  ready_stack "$work/target.json"
  ready_stack "$work/self.json"
  jq -e --arg type "$ACCOUNT_TYPE" 'any(.Stacks[0].Parameters[];
    .ParameterKey == "accountType" and .ParameterValue == $type)' "$work/self.json" > /dev/null ||
    fail 'Account type does not match updater stack'
  target_id=$(jq -r '.Stacks[0].StackId' "$work/target.json")
  updater_id=$(jq -r '.Stacks[0].StackId' "$work/self.json")
  [[ $target_id != "$updater_id" ]] || fail 'Target and updater must be different stacks'
  for file in target self; do
    jq -e --arg env "$ENV_NAME" --arg project "$PROJECT_NAME" --arg prefix "arn:$AWS_PARTITION:cloudformation:$AWS_REGION:$ACCOUNT_ID:stack/" '
      .Stacks[0] | (.StackId | startswith($prefix)) and
      any(.Parameters[]; .ParameterKey == "EnvName" and .ParameterValue == $env) and
      any(.Parameters[]; .ParameterKey == "ProjectName" and .ParameterValue == $project)' \
      "$work/$file.json" > /dev/null || fail 'Stack context mismatch'
  done
  jq -e --arg bucket "$ARTIFACT_BUCKET" 'any(.Stacks[0].Outputs[]?;
    .OutputKey == "CdArtifactBucketName" and .OutputValue == $bucket)' "$work/target.json" > /dev/null ||
    fail 'Artifact bucket does not belong to the target'
  cicd_commit=$(git rev-parse --verify HEAD)
  local template=cd-cli/cnf-templates/complete-pipeline.yaml
  [[ $domain == core ]] || template=cd-cli/cnf-templates/confinfo-complete-pipeline.yaml
  [[ -f $template && -f cd-cli/updateCdPipelines.sh && -f cd-cli/cnf-templates/cicd-update-pipeline.yaml ]] ||
    fail 'Selected release does not contain the updater'
  echo "Domain=$domain cicd=$cicd_commit"
  jq '[.Stacks[0].Parameters[] | {ParameterKey, UsePreviousValue:true}]' "$work/target.json" > "$work/target-parameters.json"
  jq '[.Stacks[0].Parameters[] | {ParameterKey, UsePreviousValue:true}]' "$work/self.json" > "$work/self-parameters.json"
  self_change=$(prepare_change_set "$updater_id" cd-cli/cnf-templates/cicd-update-pipeline.yaml self "$work/self-parameters.json")
  execute_change_set "$updater_id" "$self_change"

  target_change=$(prepare_change_set "$target_id" "$template" target "$work/target-parameters.json")
  if [[ $target_change != none ]]; then
    check_changed_pipelines "$work/target-change.json"
  fi
  execute_change_set "$target_id" "$target_change"
  echo "Pipeline maintenance complete: $target_id at $cicd_commit"
}

# START SCRIPT

parse_params "$@"
dump_params
main
