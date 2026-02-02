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

# 1. Get User Identity
execution_user=$(aws sts get-caller-identity --query Arn --output text 2>/dev/null || echo "")

# 2. Resolve Software Version (Tag vs Commit)
if [[ "${software_version}" == tag/* ]]; then
    tag="${software_version#tag/}"
    commit_id=""
else
    tag=""
    commit_id="${software_version}"
fi

# 3. Build context
build_id="${CODEBUILD_BUILD_ID:-}"
build_url="${CODEBUILD_BUILD_URL:-}"

# --- JSON Construction ---
TMP_JSON=$(mktemp)

# Build JSON manually to avoid dependencies like jq for writing
# Handling null for error_message and ensuring proper quoting
escaped_error_message="null"
if [[ -n "${error_message}" ]]; then
    # Escape double quotes for JSON
    escaped_val="${error_message//\"/\\\"}"
    escaped_error_message="\"${escaped_val}\""
fi

cat > "${TMP_JSON}" <<EOF
{
  "event_id": "${event_id}",
  "timestamp": "${timestamp}",
  "execution_user": "${execution_user}",
  "project": "${project_name}",
  "component": "${component_name}",
  "environment": "${environment}",
  "phase": "${phase}",
  "requested_version": "${software_version}",
  "commit_id": "${commit_id}",
  "tag": "${tag}",
  "config_version": "${config_version}",
  "infra_version": "${infra_version}",
  "cicd_version": "${cicd_version}",
  "pipeline_name": "${pipeline_name}",
  "build_id": "${build_id}",
  "build_url": "${build_url}",
  "release_label": "${release_label}",
  "error_message": ${escaped_error_message}
}
EOF

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
