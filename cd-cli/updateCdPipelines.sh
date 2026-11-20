#!/usr/bin/env bash
set -euo pipefail
export AWS_PAGER=''
export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=3

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h]

Required environment:
  AWS_REGION, AWS_PARTITION, ACCOUNT_ID, ACCOUNT_TYPE, ENV_NAME, PROJECT_NAME
  UPDATER_STACK, TARGET_STACK, ARTIFACT_BUCKET, BOOTSTRAP_COMMIT
  CODEBUILD_BUILD_ID, CICD_REF

Optional environment:
  ARTIFACT_KMS_KEY_ARN
EOF
}

parse_params() {
  case "${1-}" in
    -h | --help) usage; exit 0 ;;
    '') ;;
    *) fail "Unknown option: $1" ;;
  esac

  : "${AWS_REGION:?}" "${AWS_PARTITION:?}" "${ENV_NAME:?}" "${PROJECT_NAME:?}" "${ACCOUNT_ID:?}" "${UPDATER_STACK:?}"
  : "${TARGET_STACK:?}" "${ARTIFACT_BUCKET:?}" "${BOOTSTRAP_COMMIT:?}"
  : "${CODEBUILD_BUILD_ID:?}" "${CICD_REF:?}"
  : "${ACCOUNT_TYPE:?}"
  case "$ACCOUNT_TYPE" in
    CORE) domain=core ;;
    CONFINFO) domain=confinfo ;;
    *) fail 'Expected ACCOUNT_TYPE CORE or CONFINFO' ;;
  esac
  build_id=${CODEBUILD_BUILD_ID##*:}
  [[ $build_id =~ ^[a-f0-9-]{36}$ ]] || fail 'Invalid build ID'
  [[ $BOOTSTRAP_COMMIT =~ ^[a-f0-9]{40}$ ]] || fail 'Invalid bootstrap commit'
  [[ $(git rev-parse HEAD) == "$BOOTSTRAP_COMMIT" ]] || fail 'Unexpected bootstrap checkout'

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
  echo "Bootstrap Commit:  ${BOOTSTRAP_COMMIT}"
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

resolve_commit() {
  local repo=$1 ref=$2 result
  case "$ref" in tag/*) ref="refs/tags/${ref#tag/}" ;; esac
  result=$(git -C "$repo" rev-parse --verify --end-of-options "$ref^{commit}" 2>/dev/null) ||
    result=$(git -C "$repo" rev-parse --verify --end-of-options "refs/remotes/origin/$ref^{commit}") ||
    fail "Unknown revision: $ref"
  [[ $result =~ ^[a-f0-9]{40}$ ]] || fail 'Invalid commit'
  printf '%s\n' "$result"
}

idle_target() {
  local resource name builds count ids
  aws_cli cloudformation list-stack-resources --stack-name "$target_id" > "$work/resources.json"
  while IFS=$'\t' read -r resource name; do
    case "$resource" in
      AWS::CodePipeline::Pipeline)
        count=$(aws_cli codepipeline list-pipeline-executions --pipeline-name "$name" \
          --query "length(pipelineExecutionSummaries[?status=='InProgress' || status=='Stopping'])" --output json)
        [[ $count == 0 ]] || fail "Pipeline is busy: $name"
        ;;
      AWS::CodeBuild::Project)
        builds=$(aws_cli codebuild list-builds-for-project --project-name "$name" --output json)
        while read -r ids; do
          [[ -n $ids ]] || continue
          read -r -a build_ids <<< "$ids"
          count=$(aws_cli codebuild batch-get-builds --ids "${build_ids[@]}" \
            --query "length(builds[?buildStatus=='IN_PROGRESS'])" --output json)
          [[ $count == 0 ]] || fail "CodeBuild is busy: $name"
        done < <(jq -r '.ids | range(0; length; 100) as $i | .[$i:$i+100] | join(" ")' <<< "$builds")
        ;;
    esac
  done < <(jq -r '.StackResourceSummaries[] | [.ResourceType, .PhysicalResourceId] | @tsv' "$work/resources.json")
}

prepare_change_set() {
  set -e
  local stack=$1 template=$2 kind=$3 parameters=$4 change status reason token page
  change="pn-cicd-update-$build_id-$kind"
  aws_cli s3api put-object --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
    --key "pn-cicd-update/$build_id/$kind.yaml" --body "$template" "${storage_args[@]}" > /dev/null
  aws_cli cloudformation create-change-set --stack-name "$stack" --change-set-name "$change" \
    --change-set-type UPDATE --client-token "$build_id-$kind" --capabilities CAPABILITY_NAMED_IAM \
    --template-url "https://s3.$AWS_REGION.amazonaws.com/$ARTIFACT_BUCKET/pn-cicd-update/$build_id/$kind.yaml" \
    --parameters "file://$parameters" > /dev/null
  aws_cli cloudformation wait change-set-create-complete --stack-name "$stack" --change-set-name "$change" || true
  aws_cli cloudformation describe-change-set --stack-name "$stack" --change-set-name "$change" \
    --include-property-values > "$work/$kind-change.json"
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
  token=$(jq -r '.NextToken // empty' "$work/$kind-change.json")
  while [[ -n $token ]]; do
    page=$(aws_cli cloudformation describe-change-set --stack-name "$stack" --change-set-name "$change" \
      --include-property-values --next-token "$token")
    jq --argjson page "$page" '.Changes += $page.Changes | .NextToken = $page.NextToken' \
      "$work/$kind-change.json" > "$work/page.json"
    mv "$work/page.json" "$work/$kind-change.json"
    token=$(jq -r '.NextToken // empty' <<< "$page")
  done
  jq -e '
    (.Changes | length > 0) and all(.Changes[].ResourceChange;
      .Action == "Modify" and .Replacement == "False" and
      (.ResourceType == "AWS::CodePipeline::Pipeline" or .ResourceType == "AWS::CodeBuild::Project") and
      ((.BeforeContext | fromjson) as $before | (.AfterContext | fromjson) as $after |
      ($before.Properties | type == "object") and ($after.Properties | type == "object") and
      ($before.Properties.Name | type == "string") and
      (
      if .ResourceType == "AWS::CodePipeline::Pipeline" then
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
  local target_id updater_id config_commit=none cicd_commit
  local self_change target_change
  local storage_args=(--server-side-encryption AES256)
  if [[ -n ${ARTIFACT_KMS_KEY_ARN:-} ]]; then
    storage_args=(--server-side-encryption aws:kms --ssekms-key-id "$ARTIFACT_KMS_KEY_ARN")
  fi
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
  if [[ $CICD_REF == manifest ]]; then
    [[ $ENV_NAME != dev ]] || fail 'DEV pilot requires an explicit reviewed cicd_ref'
    local token authorization
    token=$(aws_cli secretsmanager get-secret-value --secret-id github-token --query SecretString --output text)
    [[ -n $token && $token != None ]] || fail 'Missing GitHub credential'
    authorization=$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')
    GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
      GIT_CONFIG_VALUE_0="Authorization: Basic $authorization" \
      git clone --branch main https://github.com/pagopa/pn-configuration.git "$work/pn-configuration"
    unset token authorization
    config_commit=$(git -C "$work/pn-configuration" rev-parse HEAD)
    CICD_REF=$(jq -er '.cd_scripts_commitId | select(type == "string" and length > 0)' \
      "$work/pn-configuration/$ENV_NAME/repository-list.json")
  else
    [[ $CICD_REF =~ ^[a-f0-9]{40}$ ]] || fail 'Explicit cicd_ref must be a reviewed commit SHA'
  fi
  cicd_commit=$(resolve_commit . "$CICD_REF")
  git merge-base --is-ancestor "$BOOTSTRAP_COMMIT" "$cicd_commit" || fail 'Automatic downgrade or divergent revision rejected'
  git checkout --detach "$cicd_commit"
  local template=cd-cli/cnf-templates/complete-pipeline.yaml
  [[ $domain == core ]] || template=cd-cli/cnf-templates/confinfo-complete-pipeline.yaml
  [[ -f $template && -f cd-cli/updateCdPipelines.sh && -f cd-cli/cnf-templates/cicd-update-pipeline.yaml ]] ||
    fail 'Selected release does not contain the updater'
  echo "Domain=$domain configuration=$config_commit cicd=$cicd_commit"
  idle_target
  jq '[.Stacks[0].Parameters[] | {ParameterKey, UsePreviousValue:true}]' "$work/target.json" > "$work/target-parameters.json"
  jq --arg commit "$cicd_commit" '[.Stacks[0].Parameters[] |
    if .ParameterKey == "BootstrapCicdCommitId" then {ParameterKey, ParameterValue:$commit}
    else {ParameterKey, UsePreviousValue:true} end]' "$work/self.json" > "$work/self-parameters.json"
  self_change=$(prepare_change_set "$updater_id" cd-cli/cnf-templates/cicd-update-pipeline.yaml self "$work/self-parameters.json")
  [[ $self_change != none || $BOOTSTRAP_COMMIT == "$cicd_commit" ]] || fail 'Bootstrap revision was not updated'
  execute_change_set "$updater_id" "$self_change"

  target_change=$(prepare_change_set "$target_id" "$template" target "$work/target-parameters.json")
  idle_target
  execute_change_set "$target_id" "$target_change"
  idle_target
  echo "Pipeline maintenance complete: $target_id at $cicd_commit"
}

# START SCRIPT

parse_params "$@"
dump_params
main
