#!/usr/bin/env bash
    
set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)


usage() {
      cat <<EOF
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-p <aws-profile>] -r <aws-region> -e <env-type> -i <github-commitid> [-c <custom_config_dir>] -b <artifactBucketName>

    [-h]                      : this help message
    [-v]                      : verbose mode
    [-p <aws-profile>]        : aws cli profile (optional)
    -r <aws-region>           : aws region as eu-south-1
    -e <env-type>             : one of dev / uat / svil / coll / cert / prod
    -i <github-commitid>      : commitId for github repository pagopa/pn-infra
    [-c <custom_config_dir>]  : where tor read additional env-type configurations
    -b <artifactBucketName>   : bucket name to use as temporary artifacts storage
    
EOF
  exit 1
}

parse_params() {
  # default values of variables set from params
  project_name=pn
  work_dir=$HOME/tmp/deploy
  custom_config_dir=""
  aws_profile=""
  aws_region=""
  env_type=""
  pn_infra_commitid=""
  bucketName=""
  LambdasBucketName=""

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -p | --profile) 
      aws_profile="${2-}"
      shift
      ;;
    -r | --region) 
      aws_region="${2-}"
      shift
      ;;
    -e | --env-name) 
      env_type="${2-}"
      shift
      ;;
    -i | --infra-commitid) 
      pn_infra_commitid="${2-}"
      shift
      ;;
    -c | --custom-config-dir) 
      custom_config_dir="${2-}"
      shift
      ;;
    -w | --work-dir) 
      work_dir="${2-}"
      shift
      ;;
    -b | --bucket-name) 
      bucketName="${2-}"
      shift
      ;;
    -B | --lambda-bucket-name) 
      LambdasBucketName="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${env_type-}" ]] && usage 
  [[ -z "${pn_infra_commitid-}" ]] && usage
  [[ -z "${bucketName-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${LambdasBucketName-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:       ${project_name}"
  echo "Work directory:     ${work_dir}"
  echo "Custom config dir:  ${custom_config_dir}"
  echo "Infra CommitId:     ${pn_infra_commitid}"
  echo "Env Name:           ${env_type}"
  echo "AWS region:         ${aws_region}"
  echo "AWS profile:        ${aws_profile}"
  echo "Bucket Name:        ${bucketName}"
  echo "Lambda Bucket Name: ${LambdasBucketName}"
}

collect_apis_csv() {
  local apis_text="$1"
  shift
  local patterns=("$@")
  local matched=()

  while IFS= read -r api_name; do
    [[ -z "${api_name}" ]] && continue
    for pattern in "${patterns[@]}"; do
      if [[ "$api_name" == *"-${pattern}-"* ]]; then
        matched+=("$api_name")
        break
      fi
    done
  done <<< "$apis_text"

  if [[ ${#matched[@]} -eq 0 ]]; then
    echo ""
    return 0
  fi

  printf '%s\n' "${matched[@]}" | awk 'NF && !seen[$0]++ { printf("%s\047%s\047", sep, $0); sep="," } END { print "" }'
}

collect_apis_lines() {
  local apis_text="$1"
  shift
  local patterns=("$@")
  local matched=()

  while IFS= read -r api_name; do
    [[ -z "${api_name}" ]] && continue
    for pattern in "${patterns[@]}"; do
      if [[ "$api_name" == *"-${pattern}-"* ]]; then
        matched+=("$api_name")
        break
      fi
    done
  done <<< "$apis_text"

  if [[ ${#matched[@]} -eq 0 ]]; then
    echo ""
    return 0
  fi

  printf '%s\n' "${matched[@]}" | awk 'NF && !seen[$0]++'
}

build_category_widgets() {
  local category_label="$1"
  local category_key="$2"
  local y_base="$3"
  local apis_lines="$4"

  mapfile -t apis < <(printf '%s\n' "$apis_lines" | sed '/^$/d')
  if [[ ${#apis[@]} -eq 0 ]]; then
    echo ""
    return 0
  fi

  local metrics_worst=""
  local metrics_ts=""
  local metric_ids=""
  local idx=1

  for api_name in "${apis[@]}"; do
    if [[ -z "$metric_ids" ]]; then
      metric_ids="m${idx}"
    else
      metric_ids="${metric_ids},m${idx}"
    fi

    local worst_entry
    worst_entry=$(jq -cn \
      --arg apiName "$api_name" \
      --arg id "m${idx}" \
      '["AWS/ApiGateway","Latency","ApiName",$apiName,{"stat":"p95","id":$id,"visible":false}]')

    local ts_entry
    ts_entry=$(jq -cn \
      --arg apiName "$api_name" \
      --arg id "m${idx}" \
      '["AWS/ApiGateway","Latency","ApiName",$apiName,{"stat":"p95","label":$apiName,"id":$id}]')

    if [[ -z "$metrics_worst" ]]; then
      metrics_worst="$worst_entry"
    else
      metrics_worst="${metrics_worst},${worst_entry}"
    fi

    if [[ -z "$metrics_ts" ]]; then
      metrics_ts="$ts_entry"
    else
      metrics_ts="${metrics_ts},${ts_entry}"
    fi

    idx=$((idx + 1))
  done

  local worst_expression="MAX([${metric_ids}])"

  local header_widget
  header_widget=$(jq -cn \
    --arg title "# OER - ${category_label} API Gateway" \
    --argjson y "$y_base" \
    '{type:"text",x:0,y:$y,width:24,height:1,properties:{markdown:$title}}')

  local worst_widget
  worst_widget=$(jq -cn \
    --arg expr "$worst_expression" \
    --arg label "${category_label} P95 - Worst API" \
    --argjson y "$((y_base + 1))" \
    --argjson metrics "[${metrics_worst}]" \
    '{
      type:"metric",
      x:0,
      y:$y,
      width:8,
      height:6,
      properties:{
        metrics: ([ [{expression:$expr,label:$label,id:"e1"}] ] + $metrics),
        view:"singleValue",
        region:"${AWS::Region}",
        title:$label,
        period:300,
        setPeriodToTimeRange:true,
        singleValueFullPrecision:false
      }
    }')

  local timeseries_widget
  timeseries_widget=$(jq -cn \
    --arg title "${category_label} API Latency - P95" \
    --argjson y "$((y_base + 1))" \
    --argjson metrics "[${metrics_ts}]" \
    '{
      type:"metric",
      x:8,
      y:$y,
      width:16,
      height:6,
      properties:{
        metrics:$metrics,
        view:"timeSeries",
        region:"${AWS::Region}",
        title:$title,
        period:300,
        yAxis:{left:{label:"Latency (ms)",showUnits:false}},
        legend:{position:"bottom"}
      }
    }')

  local detail_widgets=""
  local x_positions=(0 8 16)
  local max_details=3
  local detail_count=${#apis[@]}
  if (( detail_count > max_details )); then
    detail_count=$max_details
  fi

  for ((i=0; i<detail_count; i++)); do
    local api_name="${apis[$i]}"
    local x_val="${x_positions[$i]}"
    local short_title="$api_name"
    short_title="${short_title#pn-}"

    local detail_widget
    detail_widget=$(jq -cn \
      --arg apiName "$api_name" \
      --arg title "${short_title} - P95" \
      --argjson x "$x_val" \
      --argjson y "$((y_base + 7))" \
      '{
        type:"metric",
        x:$x,
        y:$y,
        width:8,
        height:5,
        properties:{
          metrics:[["AWS/ApiGateway","Latency","ApiName",$apiName,{"stat":"p95","label":"P95"}]],
          view:"singleValue",
          region:"${AWS::Region}",
          title:$title,
          period:300,
          setPeriodToTimeRange:true
        }
      }')

    if [[ -z "$detail_widgets" ]]; then
      detail_widgets="$detail_widget"
    else
      detail_widgets="${detail_widgets},${detail_widget}"
    fi
  done

  if [[ -n "$detail_widgets" ]]; then
    echo "${header_widget},${worst_widget},${timeseries_widget},${detail_widgets}"
  else
    echo "${header_widget},${worst_widget},${timeseries_widget}"
  fi
}

build_all_api_widgets() {
  local backoffice_lines="$1"
  local b2b_lines="$2"
  local b2bpg_lines="$3"
  local web_lines="$4"
  local io_lines="$5"

  local all_widgets=""
  local current_y=16

  local block

  block=$(build_category_widgets "BACKOFFICE" "BACKOFFICE" "$current_y" "$backoffice_lines")
  if [[ -n "$block" ]]; then
    all_widgets="${all_widgets},${block}"
    current_y=$((current_y + 13))
  fi

  block=$(build_category_widgets "B2B" "B2B" "$current_y" "$b2b_lines")
  if [[ -n "$block" ]]; then
    all_widgets="${all_widgets},${block}"
    current_y=$((current_y + 13))
  fi

  block=$(build_category_widgets "B2BPG" "B2BPG" "$current_y" "$b2bpg_lines")
  if [[ -n "$block" ]]; then
    all_widgets="${all_widgets},${block}"
    current_y=$((current_y + 13))
  fi

  block=$(build_category_widgets "WEB" "WEB" "$current_y" "$web_lines")
  if [[ -n "$block" ]]; then
    all_widgets="${all_widgets},${block}"
    current_y=$((current_y + 13))
  fi

  block=$(build_category_widgets "IO" "IO" "$current_y" "$io_lines")
  if [[ -n "$block" ]]; then
    all_widgets="${all_widgets},${block}"
  fi

  echo "$all_widgets"
}


# START SCRIPT

parse_params "$@"
dump_params

cwdir=$(pwd)
cd $work_dir


echo "=== Download pn-infra" 
if ( [ ! -e pn-infra ] ) then 
  git clone https://github.com/pagopa/pn-infra.git
fi

echo ""
echo "=== Checkout pn-infra commitId=${pn_infra_commitid}"
( cd pn-infra && git fetch && git checkout $pn_infra_commitid )
echo " - copy custom config"
if ( [ ! -z "${custom_config_dir}" ] ) then
  cp -r $custom_config_dir/pn-infra .
fi

echo ""
echo "=== Base AWS command parameters"
aws_command_base_args=""
if ( [ ! -z "${aws_profile}" ] ) then
  aws_command_base_args="${aws_command_base_args} --profile $aws_profile"
fi
if ( [ ! -z "${aws_region}" ] ) then
  aws_command_base_args="${aws_command_base_args} --region  $aws_region"
fi
echo ${aws_command_base_args}


templateBucketS3BaseUrl="s3://${bucketName}/pn-infra/${pn_infra_commitid}"
templateBucketHttpsBaseUrl="https://s3.${aws_region}.amazonaws.com/${bucketName}/pn-infra/${pn_infra_commitid}/runtime-infra"
echo " - Bucket Name: ${bucketName}"
echo " - Bucket Template S3 Url: ${templateBucketS3BaseUrl}"
echo " - Bucket Template HTTPS Url: ${templateBucketHttpsBaseUrl}"


echo ""
echo "=== Upload files to bucket"
aws ${aws_command_base_args} \
    s3 cp pn-infra $templateBucketS3BaseUrl \
      --recursive --exclude ".git/*"

echo "Load all outputs in a single file for next stack deployments"
INFRA_ALL_OUTPUTS_FILE=infra_all_outputs-${env_type}.json
(cd ${cwdir}/commons && ./merge-infra-outputs-core.sh -r ${aws_region} -e ${env_type} -o ${work_dir}/${INFRA_ALL_OUTPUTS_FILE} )

echo "## start merge all ##"
cat $INFRA_ALL_OUTPUTS_FILE
echo "## end merge all ##"


## Script to get metric alarms not used by any composite alarm
if ( [ -f pn-infra/runtime-infra/pn-oer-dashboard.yaml ] ) then
    echo "Deploy OER dashboard deploy"
    aws ${aws_command_base_args} cloudwatch describe-alarms | jq -r '.MetricAlarms[].AlarmArn' | tee all_metric_alarms.txt
    aws ${aws_command_base_args} cloudwatch describe-alarms --alarm-types CompositeAlarm | jq -r '.CompositeAlarms[].AlarmRule' | grep -o '(.*)' | sed 's/[()]//g' | sed 's/ OR /\n/g' | sed 's/ALARM//g' | sort -u | tee used.txt

    comm -3 all_metric_alarms.txt used.txt | tee not_referenced_metric_allarms.txt

    #confidentialInfoAccountId=$(cat $INFRA_ALL_OUTPUTS_FILE | jq -r '.ConfidentialInfoAccountId') 
    #echo "ConfidentialInfoAccountId=${confidentialInfoAccountId}"
#
    #helpdeskAccountId=$(cat $INFRA_ALL_OUTPUTS_FILE | jq -r '.HelpdeskAccountId') 
    #echo "HelpdeskAccountId=${helpdeskAccountId}"
#
    #openSearchArn=$(cat $INFRA_ALL_OUTPUTS_FILE | jq -r '.OpenSearchArn') 
    #echo "OpenSearchArn=${openSearchArn}"
#
    #logsBucketKmsKeyArn=$(cat $INFRA_ALL_OUTPUTS_FILE | jq -r '.LogsBucketKmsKeyArn')
    #echo "LogsBucketKmsKeyArn=${logsBucketKmsKeyArn}"
#
    #logRetention=$(cat $INFRA_ALL_OUTPUTS_FILE | jq -r '.LogRetention')
    #echo "LogRetention=${logRetention}"
  
    #logsBucketName=$(cat $INFRA_ALL_OUTPUTS_FILE | jq -r '.LogsBucketName') 
    #echo "LogsBucketName=${logsBucketName}"

    #logsBucketName=''

    #LambdasBasePath=$(cat $INFRA_ALL_OUTPUTS_FILE | jq -r '.LambdasBasePath') 
    #echo "LambdasBasePath=${LambdasBasePath}"

    applicationLoadBalancerListenerArn=$(cat $INFRA_ALL_OUTPUTS_FILE | jq -r '.ApplicationLoadBalancerListenerArn') 
    echo "ApplicationLoadBalancerListenerArn=${applicationLoadBalancerListenerArn}"
    #echo "LambdasBucketName=${bucketName}"
    #echo "LambdasBasePath=${LambdasBasePath}"
    
    raddTargetGroupArn=$( aws ${aws_command_base_args}  elbv2 describe-rules --listener-arn ${applicationLoadBalancerListenerArn}  \
       --query "Rules[].{Host:Conditions[0].Values[0],TargetGroup:Actions[0].TargetGroupArn}" | jq -r \
       ".[] | select(.Host==\"/radd/*\") | .TargetGroup")
    
    OptionalParameters=""
    #if ( [ ! -z "$confidentialInfoAccountId" ] ) then
    #  OptionalParameters="${OptionalParameters} ConfidentialInfoAccountId=${confidentialInfoAccountId}"
    #fi
#
    #if ( [ ! -z "$helpdeskAccountId" ] ) then
    #  OptionalParameters="${OptionalParameters} HelpdeskAccountId=${helpdeskAccountId}"
    #fi
#
    #if ( [ ! -z "$openSearchArn" ] ) then
    #  OptionalParameters="${OptionalParameters} OpenSearchArn=${openSearchArn}"
    #fi
#
    #if ( [ ! -z "$logsBucketName" ] ) then
    #  OptionalParameters="${OptionalParameters} LogsBucketName=${logsBucketName}"
    #else
    #  OptionalParameters="${OptionalParameters} LogsBucketName=${logsBucketName}"
    #fi

    # The Radd is not currently exposed on Api Gateway but using an Application Load Balancer Target Group
    # so we have to monitor metrics on ALB Target Group
    if ( [ ! -z "$raddTargetGroupArn" ] ) then
      delimiter="listener/"
      s=$applicationLoadBalancerListenerArn$delimiter
      array=();
      while [[ $s ]]; do
          array+=( "${s%%"$delimiter"*}" );
          s=${s#*"$delimiter"};
      done;

      albRef=${array[1]}

      delimiter1="targetgroup/"
      s1=$raddTargetGroupArn$delimiter1
      array1=();
      while [[ $s1 ]]; do
          array1+=( "${s1%%"$delimiter1"*}" );
          s1=${s1#*"$delimiter1"};
      done;

      raddRef="targetgroup/"${array1[1]}
      OptionalParameters="\"Alb=${albRef}\",\"RaddTargetGroup=${raddRef}\",\"TemplateBucketHttpsBaseUrl=${templateBucketHttpsBaseUrl}\""
    fi

    echo "Optional Parameters ${OptionalParameters}"
    
    ParamFilePath="pn-infra/runtime-infra/pn-oer-dashboard-${env_type}-cfg.json"
    TmpFilePath=terraform-merge-${env_type}-cfg.json

    if ( [ -f "$INFRA_ALL_OUTPUTS_FILE" ] ) then
      echo "Merging outputs of ${INFRA_ALL_OUTPUTS_FILE} into pn-oer-dashboard"

      echo ""
      echo "= Enanched Terraform parameters file for pn-oer-dashboard"
      jq -s ".[0] * .[1]" ${ParamFilePath} ${INFRA_ALL_OUTPUTS_FILE} > ${TmpFilePath}
      cat ${TmpFilePath}
      mv ${TmpFilePath} ${ParamFilePath}
    fi

    echo ""
    echo "= Fetch API Gateway names and inject OER API parameters"
    api_names=$(aws ${aws_command_base_args} apigateway get-rest-apis --query 'items[].name' --output text | tr '\t' '\n' | sed '/^$/d' | sort -u)

    backoffice_apis=$(collect_apis_csv "$api_names" "BACKOFFICE")
    b2b_apis=$(collect_apis_csv "$api_names" "B2B")
    b2bpg_apis=$(collect_apis_csv "$api_names" "B2BPG")
    web_apis=$(collect_apis_csv "$api_names" "WEB")
    io_apis=$(collect_apis_csv "$api_names" "IO" "IO_EXP")

    echo "BackofficeApis=${backoffice_apis}"
    echo "B2BApis=${b2b_apis}"
    echo "B2BPGApis=${b2bpg_apis}"
    echo "WEBApis=${web_apis}"
    echo "IOApis=${io_apis}"

    jq \
      --arg backofficeApis "$backoffice_apis" \
      --arg b2bApis "$b2b_apis" \
      --arg b2bpgApis "$b2bpg_apis" \
      --arg webApis "$web_apis" \
      --arg ioApis "$io_apis" \
      '.Parameters = (.Parameters // {})
      | .Parameters.BackofficeApis = $backofficeApis
      | .Parameters.B2BApis = $b2bApis
      | .Parameters.B2BPGApis = $b2bpgApis
      | .Parameters.WEBApis = $webApis
      | .Parameters.IOApis = $ioApis' \
      ${ParamFilePath} > ${TmpFilePath}

    mv ${TmpFilePath} ${ParamFilePath}
    cat ${ParamFilePath}

    PipelineParams="\"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitId}\",$OptionalParameters"
    EnanchedParamFilePath="pn-infra/runtime-infra/pn-oer-dashboard-${env_type}-enhanced-cfg.json"

    echo ""
    echo "= Enanched parameters file"
    jq -c "." \
      ${ParamFilePath} \
      | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
      > ${EnanchedParamFilePath}
    echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
    cat ${EnanchedParamFilePath}

    aws ${aws_command_base_args} cloudformation deploy \
        --stack-name pn-oer-dashboard-${env_type} \
        --capabilities CAPABILITY_NAMED_IAM \
        --s3-bucket ${bucketName} \
        --template-file pn-infra/runtime-infra/pn-oer-dashboard.yaml \
        --tags Microservice=pn-infra-monitoring \
        --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )
else
    echo "Skipped OER dashboard deploy"
fi
