#!/usr/bin/env bash

# SEND Release Tracking Script
# Used to record deployment events to S3 for monitoring and DORA metrics.

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
  if [[ -f "${TMP_JSON-}" ]]; then
    rm -f "${TMP_JSON}"
  fi
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
      cat <<EOF
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] 
                                          -n <component-name> 
                                          -e <environment> 
                                          -p <phase> 
                                          -b <artifact-bucket>
                                          [-i <event-id>]
                                          [-V <software-version>]
                                          [-c <config-version>]
                                          [-f <infra-version>]
                                          [-d <cicd-version>]
                                          [-l <pipeline-name>]
                                          [-m <error-message>]
                                          [-s <start-timestamp>]
                                          [-D <duration-seconds>]
                                          [-r <release-label>]
                                          [-R <aws-region>]
                                          [--dry-run]

    [-h]                      : this help message
    [-v]                      : verbose mode
    -n <component-name>       : component name (e.g. pn-delivery)
    -e <environment>          : environment (dev, uat, prod, ...)
    -p <phase>                : phase (STARTED, SUCCESS, FAILURE)
    -b <artifact-bucket>      : local artifact bucket name
    -i <event-id>             : unique event id for correlation
    -V <software-version>     : software version/commit
    -c <config-version>       : configuration version/commit
    -f <infra-version>        : infrastructure version/commit
    -d <cicd-version>         : cicd scripts version/commit
    -l <pipeline-name>        : codepipeline name
    -m <error-message>        : error message (for FAILURE phase)
    -s <start-timestamp>      : deployment start timestamp (ISO 8601)
    -D <duration-seconds>     : deployment duration in seconds
    -r <release-label>        : release label (e.g. GA26Q1.A)
    -R <aws-region>           : aws region
    --dry-run                 : print JSON without uploading to S3

EOF
  exit 1
}

parse_params() {
  # default values of variables set from params
  project_name="pn"
  component_name=""
  environment=""
  phase=""
  artifact_bucket=""
  event_id=""
  software_version=""
  config_version=""
  infra_version=""
  cicd_version=""
  pipeline_name=""
  error_message=""
  start_timestamp=""
  duration_seconds=""
  release_label=""
  aws_region="eu-south-1"
  dry_run="false"

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -n | --component-name)
      component_name="${2-}"
      shift
      ;;
    -e | --environment)
      environment="${2-}"
      shift
      ;;
    -p | --phase)
      phase="${2-}"
      shift
      ;;
    -b | --artifact-bucket)
      artifact_bucket="${2-}"
      shift
      ;;
    -i | --event-id)
      event_id="${2-}"
      shift
      ;;
    -V | --software-version)
      software_version="${2-}"
      shift
      ;;
    -c | --config-version)
      config_version="${2-}"
      shift
      ;;
    -f | --infra-version)
      infra_version="${2-}"
      shift
      ;;
    -d | --cicd-version)
      cicd_version="${2-}"
      shift
      ;;
    -l | --pipeline-name)
      pipeline_name="${2-}"
      shift
      ;;
    -m | --error-message)
      error_message="${2-}"
      shift
      ;;
    -s | --start-timestamp)
      start_timestamp="${2-}"
      shift
      ;;
    -D | --duration-seconds)
      duration_seconds="${2-}"
      shift
      ;;
    -r | --release-label)
      release_label="${2-}"
      shift
      ;;
    -R | --aws-region)
      aws_region="${2-}"
      shift
      ;;
    --dry-run)
      dry_run="true"
      ;;
    -?*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) break ;;
    esac
    shift
  done

   # check required params and arguments
  [[ -z "${component_name-}" ]] && usage
  [[ -z "${environment-}" ]] && usage
  [[ -z "${phase-}" ]] && usage
  [[ -z "${artifact_bucket-}" ]] && usage
  return 0
}

dump_params(){
  if [[ "${dry_run}" == "true" ]]; then
    echo "!!! DRY RUN ENABLED - No upload will be performed !!!"
  fi
  echo ""
  echo "######      RELEASE TRACKING      ######"
  echo "########################################"
  echo "Component:             ${component_name}"
  echo "Environment:           ${environment}"
  echo "Phase:                 ${phase}"
  echo "Bucket:                ${artifact_bucket}"
  echo "Event ID:              ${event_id}"
  echo "Software Version:      ${software_version}"
  echo "Region:                ${aws_region}"
}

# --- Main Execution ---

parse_params "$@"
dump_params

# Generate Event ID if not provided
if [[ -z "${event_id}" ]]; then
  event_id=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]' || echo "unknown-$(date +%s)")
fi

# Metadata gathering
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
year=$(date -u +"%Y")
month=$(date -u +"%m")
day=$(date -u +"%d")
hour=$(date -u +"%H")

echo "=== Gathering metadata for release event ${event_id}"

# Get User Identity and Pipeline Execution ID
execution_user=""
pipeline_execution_id="${PipelineExecutionId:-}"

if [[ -n "${CODEBUILD_INITIATOR:-}" ]] && [[ "${CODEBUILD_INITIATOR}" == codepipeline/* ]]; then
  # Extract pipeline name from CODEBUILD_INITIATOR (format: codepipeline/pipeline-name)
  _pipeline_name="${CODEBUILD_INITIATOR#codepipeline/}"
  
  if [[ -n "${pipeline_execution_id}" ]]; then
    echo "=== Retrieving pipeline trigger info for execution ${pipeline_execution_id}"
    # Get the user who triggered the pipeline execution
    execution_user=$(aws codepipeline get-pipeline-execution \
      --pipeline-name "${_pipeline_name}" \
      --pipeline-execution-id "${pipeline_execution_id}" \
      --query 'pipelineExecution.trigger.triggerDetail' \
      --output text 2>/dev/null || echo "")
  fi
fi

# Fallback to STS caller identity if pipeline trigger not available
if [[ -z "${execution_user}" ]]; then
  execution_user=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "")
fi

# Auto-detect config_version
if [[ -z "${config_version}" ]]; then
  # File created by downloadCustomConfig.sh in custom-config folder
  commit_file="${script_dir}/../custom-config/pn-configuration-commit-id.txt"
  
  if [[ -f "${commit_file}" ]]; then
    echo "=== Reading config_version from ${commit_file}"
    config_version=$(cat "${commit_file}" | tr -d '[:space:]')
  fi
fi

# Resolve Software Version (Tag vs Commit)
if [[ "${software_version}" == tag/* ]]; then
    tag="${software_version#tag/}"
    commit_id=""
else
    tag=""
    commit_id="${software_version}"
fi

# Build context
build_id="${CODEBUILD_BUILD_ID:-}"
build_url="${CODEBUILD_BUILD_URL:-}"

# --- JSON Construction ---
TMP_JSON=$(mktemp)

jq -cn \
  --arg event_id "${event_id}" \
  --arg timestamp "${timestamp}" \
  --arg start_timestamp "${start_timestamp}" \
  --arg duration_seconds "${duration_seconds}" \
  --arg execution_user "${execution_user}" \
  --arg project "${project_name}" \
  --arg component "${component_name}" \
  --arg environment "${environment}" \
  --arg phase "${phase}" \
  --arg requested_version "${software_version}" \
  --arg commit_id "${commit_id}" \
  --arg tag "${tag}" \
  --arg config_version "${config_version}" \
  --arg infra_version "${infra_version}" \
  --arg cicd_version "${cicd_version}" \
  --arg pipeline_name "${pipeline_name}" \
  --arg pipeline_execution_id "${pipeline_execution_id}" \
  --arg build_id "${build_id}" \
  --arg build_url "${build_url}" \
  --arg release_label "${release_label}" \
  --arg error_message "${error_message}" \
  '{
    event_id: $event_id,
    timestamp: $timestamp,
    start_timestamp: $start_timestamp,
    duration_seconds: $duration_seconds,
    execution_user: $execution_user,
    project: $project,
    component: $component,
    environment: $environment,
    phase: $phase,
    requested_version: $requested_version,
    commit_id: $commit_id,
    tag: $tag,
    config_version: $config_version,
    infra_version: $infra_version,
    cicd_version: $cicd_version,
    pipeline_name: $pipeline_name,
    pipeline_execution_id: $pipeline_execution_id,
    build_id: $build_id,
    build_url: $build_url,
    release_label: $release_label,
    error_message: $error_message
  }' > "${TMP_JSON}"

# --- Output / S3 Upload ---
event_id_short="${event_id:0:8}"
file_name="${timestamp}_${component_name}_${phase}_${event_id_short}.json"
s3_path="s3://${artifact_bucket}/release-events-raw/${year}/${month}/${day}/${hour}/${file_name}"

if [[ "${dry_run}" == "true" ]]; then
  echo "=== Dry Run Output ==="
  cat "${TMP_JSON}"
  echo -e "\n======================"
  echo "Target S3 path would be: ${s3_path}"
else
  echo "=== Uploading event to ${s3_path}"
  # Failure tolerance: don't fail the build if tracking fails
  aws s3 cp "${TMP_JSON}" "${s3_path}" --region "${aws_region}" || echo "Warning: Failed to upload release event to S3"
fi

echo "=== Release event ${phase} for ${component_name} tracked successfully"
