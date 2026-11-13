#!/usr/bin/env bash
set -euo pipefail
export AWS_PAGER=''
export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=3

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h]

Required environment:
  AWS_REGION, AWS_PARTITION, ACCOUNT_ID, ENV_NAME, PROJECT_NAME
  UPDATER_STACK, TARGET_STACK, ARTIFACT_BUCKET, BOOTSTRAP_COMMIT
  CONFIGURATION_SECRET, UPDATER_PIPELINE, EXECUTION_ID
  CICD_REF, UPDATE_MODE (plan or apply), SNAPSHOT_ID

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
  : "${TARGET_STACK:?}" "${ARTIFACT_BUCKET:?}" "${BOOTSTRAP_COMMIT:?}" "${CONFIGURATION_SECRET:?}"
  : "${UPDATER_PIPELINE:?}" "${EXECUTION_ID:?}" "${CICD_REF:?}" "${UPDATE_MODE:?}" "${SNAPSHOT_ID:?}"
  [[ $UPDATE_MODE == plan || $UPDATE_MODE == apply ]] || fail 'Expected plan or apply'
  [[ $EXECUTION_ID =~ ^[a-f0-9-]{36}$ ]] || fail 'Invalid execution ID'
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
  echo "Updater stack:     ${UPDATER_STACK}"
  echo "Target stack:      ${TARGET_STACK}"
  echo "Bucket Name:       ${ARTIFACT_BUCKET}"
  echo "Bootstrap Commit:  ${BOOTSTRAP_COMMIT}"
  echo "Update mode:       ${UPDATE_MODE}"
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
  change="pn-cicd-update-$root-$kind"
  aws_cli s3api put-object --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
    --key "pn-cicd-update/$root/$kind.yaml" --body "$template" "${storage_args[@]}" > /dev/null
  aws_cli cloudformation create-change-set --stack-name "$stack" --change-set-name "$change" \
    --change-set-type UPDATE --client-token "$root-$kind" --capabilities CAPABILITY_NAMED_IAM \
    --template-url "https://s3.$AWS_REGION.amazonaws.com/$ARTIFACT_BUCKET/pn-cicd-update/$root/$kind.yaml" \
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
  local stack=$1 change=$2 state
  [[ $change != none ]] || return 0
  state=$(aws_cli cloudformation describe-change-set --change-set-name "$change" --query ExecutionStatus --output text)
  case "$state" in
    AVAILABLE)
      aws_cli cloudformation execute-change-set --stack-name "$stack" --change-set-name "$change" \
        --client-request-token "$root-$(basename "$stack")"
      ;;
    EXECUTE_COMPLETE)
      [[ $(aws_cli cloudformation describe-stacks --stack-name "$stack" --query 'Stacks[0].StackStatus' --output text) == UPDATE_COMPLETE ]] ||
        fail 'Previous update did not succeed'
      return 0 ;;
    EXECUTE_IN_PROGRESS) ;;
    *) fail "Change set cannot execute: $state" ;;
  esac
  aws_cli cloudformation wait stack-update-complete --stack-name "$stack"
}

main() {
  work=$(mktemp -d)
  local core=0 confinfo=0 domain peer target_id updater_id config_commit=none cicd_commit
  local self_change target_change root snapshot_key continuation=false
  local storage_args=(--server-side-encryption AES256)
  if [[ -n ${ARTIFACT_KMS_KEY_ARN:-} ]]; then
    storage_args=(--server-side-encryption aws:kms --ssekms-key-id "$ARTIFACT_KMS_KEY_ARN")
  fi
  read_stack "pn-infra-$ENV_NAME" "$work/core.json" && core=1
  read_stack "infra-$ENV_NAME" "$work/confinfo.json" && confinfo=1
  [[ $((core + confinfo)) == 1 ]] || fail 'Missing or ambiguous infrastructure domain'
  if [[ $core == 1 ]]; then domain=core; peer=ConfidentialInfoAccountId
  else domain=confinfo; peer=PnCoreAwsAccountId; fi
  ready_stack "$work/$domain.json"
  jq -e --arg key "$peer" --arg account "$ACCOUNT_ID" \
    '[.Stacks[0].Outputs[]? | select(.OutputKey == $key) | .OutputValue] |
      length == 1 and (.[0] | test("^[0-9]{12}$")) and .[0] != $account' \
    "$work/$domain.json" > /dev/null || fail 'Invalid domain account output'
  read_stack "$TARGET_STACK" "$work/target.json" || fail 'Target stack does not exist'
  read_stack "$UPDATER_STACK" "$work/self.json" || fail 'Updater stack does not exist'
  ready_stack "$work/target.json"
  ready_stack "$work/self.json"
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
  root=$EXECUTION_ID
  if [[ $SNAPSHOT_ID != new ]]; then
    [[ $SNAPSHOT_ID =~ ^[a-f0-9-]{36}$ && $SNAPSHOT_ID != "$EXECUTION_ID" ]] || fail 'Invalid continuation'
    root=$SNAPSHOT_ID
    continuation=true
  fi
  snapshot_key="pn-cicd-update/$root/snapshot.json"
  aws_cli s3api list-objects-v2 --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
    --prefix "$snapshot_key" --max-keys 1 > "$work/objects.json"
  if jq -e --arg key "$snapshot_key" 'any(.Contents[]?; .Key == $key)' "$work/objects.json" > /dev/null; then
    aws_cli s3api get-object --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
      --key "$snapshot_key" "$work/snapshot.json" > /dev/null
    jq -e --arg account "$ACCOUNT_ID" --arg region "$AWS_REGION" --arg env "$ENV_NAME" \
      --arg domain "$domain" --arg target "$target_id" --arg updater "$updater_id" --arg mode "$UPDATE_MODE" \
      '.account == $account and .region == $region and .environment == $env and .domain == $domain and
        .target == $target and .updater == $updater and .mode == $mode and
        (.cicd_commit | test("^[a-f0-9]{40}$"))' "$work/snapshot.json" > /dev/null || fail 'Snapshot context mismatch'
    cicd_commit=$(jq -r '.cicd_commit' "$work/snapshot.json")
    config_commit=$(jq -r '.configuration_commit' "$work/snapshot.json")
    self_change=$(jq -r '.self_change' "$work/snapshot.json")
    target_change=$(jq -r '.target_change' "$work/snapshot.json")
    [[ $continuation == false || $BOOTSTRAP_COMMIT == "$cicd_commit" ]] || fail 'Continuation revision mismatch'
  else
    [[ $continuation == false ]] || fail 'Continuation snapshot is missing'
    if [[ $CICD_REF == manifest ]]; then
      case "$ENV_NAME" in dev|svil) fail 'DEV pilot requires an explicit reviewed cicd_ref' ;; esac
      local token authorization
      token=$(aws_cli secretsmanager get-secret-value --secret-id "$CONFIGURATION_SECRET" --query SecretString --output text)
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
    idle_target
    jq '[.Stacks[0].Parameters[] | {ParameterKey, UsePreviousValue:true}]' "$work/target.json" > "$work/target-parameters.json"
    jq --arg commit "$cicd_commit" '[.Stacks[0].Parameters[] |
      if .ParameterKey == "BootstrapCicdCommitId" then {ParameterKey, ParameterValue:$commit}
      else {ParameterKey, UsePreviousValue:true} end]' "$work/self.json" > "$work/self-parameters.json"
    self_change=$(prepare_change_set "$updater_id" cd-cli/cnf-templates/cicd-update-pipeline.yaml self "$work/self-parameters.json")
    [[ $self_change != none || $BOOTSTRAP_COMMIT == "$cicd_commit" ]] || fail 'Bootstrap revision was not updated'
    target_change=$(prepare_change_set "$target_id" "$template" target "$work/target-parameters.json")
    jq -n --arg account "$ACCOUNT_ID" --arg region "$AWS_REGION" --arg env "$ENV_NAME" \
      --arg domain "$domain" --arg target "$target_id" --arg updater "$updater_id" --arg mode "$UPDATE_MODE" \
      --arg cicd "$cicd_commit" --arg config "$config_commit" --arg self "$self_change" --arg change "$target_change" \
      '{account:$account, region:$region, environment:$env, domain:$domain, target:$target, updater:$updater,
        mode:$mode, cicd_commit:$cicd, configuration_commit:$config, self_change:$self, target_change:$change}' > "$work/snapshot.json"
    aws_cli s3api put-object --bucket "$ARTIFACT_BUCKET" --expected-bucket-owner "$ACCOUNT_ID" \
      --key "$snapshot_key" --body "$work/snapshot.json" --if-none-match '*' "${storage_args[@]}" > /dev/null
  fi
  echo "Domain=$domain configuration=$config_commit cicd=$cicd_commit mode=$UPDATE_MODE"
  echo "Self change set=$self_change target change set=$target_change snapshot=$root"
  [[ $UPDATE_MODE == apply ]] || return 0
  idle_target
  if [[ $self_change != none ]]; then
    if [[ $continuation == false ]]; then
      execute_change_set "$updater_id" "$self_change"
      aws_cli codepipeline start-pipeline-execution --name "$UPDATER_PIPELINE" \
        --client-request-token "$root-continue" \
        --variables "name=cicd_ref,value=$cicd_commit" "name=mode,value=apply" "name=snapshot,value=$root"
      echo 'Self-update complete; target update queued on the same snapshot'
      return 0
    fi
    [[ $BOOTSTRAP_COMMIT == "$cicd_commit" ]] || fail 'Self-update did not activate the selected commit'
    [[ $(aws_cli cloudformation describe-change-set --change-set-name "$self_change" --query ExecutionStatus --output text) == EXECUTE_COMPLETE ]] ||
      fail 'Self-update has not completed'
  fi
  idle_target
  execute_change_set "$target_id" "$target_change"
  idle_target
  echo "Pipeline maintenance complete: $target_id at $cicd_commit"
}

# START SCRIPT

parse_params "$@"
dump_params
main
