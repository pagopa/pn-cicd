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
    Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] -n <microcvs-name> -N <microcvs-idx> [-p <aws-profile>] -r <aws-region> -e <env-type> -d <cicd-github-commitid> -i <pn-infra-github-commitid> -m <pn-microsvc-github-commitid> -I <countainer-image-uri> -b <artifactBucketName> -b <lambdaArtifactBucketName> [-w <work_dir>] [-c <custom_config_dir>]
    
    [-h]                             : this help message
    [-v]                             : verbose mode
    [-p <aws-profile>]               : aws cli profile (optional)
    -r <aws-region>                  : aws region as eu-south-1
    -e <env-type>                    : one of dev / uat / svil / coll / cert / prod
    -d <cicd-github-commitid>        : commitId for github repository pagopa/pn-cicd
    -i <infra-github-commitid>       : commitId for github repository pagopa/pn-infra
    -m <pn-microsvc-github-commitid> : commitId for github repository del microservizio
    [-c <custom_config_dir>]         : where tor read additional env-type configurations
    -b <artifactBucketName>          : bucket name to use as temporary artifacts storage
    -B <lambdaArtifactBucketName>  : bucket name where lambda artifact are memorized    
    -n <microcvs-name>               : nome del microservizio
    -N <microcvs-idx>                : id del microservizio
    -I <image-uri>                   : url immagine docker microservizio
    -w <work-dir>                    : working directory used by the script to download artifacts (default $HOME/tmp/deploy)
    
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
  pn_microsvc_commitid=""
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
    -d | --cicd-commitid) 
      cd_scripts_commitId="${2-}"
      shift
      ;;  
    -i | --infra-commitid) 
      pn_infra_commitid="${2-}"
      shift
      ;;
    -m | --ms-commitid) 
      pn_microsvc_commitid="${2-}"
      shift
      ;;
    -n | --ms-name) 
      microcvs_name="${2-}"
      shift
      ;;
    -N | --ms-number)
      MicroserviceNumber="${2-}"
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
    -I | --container-image-url) 
      ContainerImageUri="${2-}"
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
  [[ -z "${cd_scripts_commitId-}" ]] && usage
  [[ -z "${pn_infra_commitid-}" ]] && usage
  [[ -z "${pn_microsvc_commitid-}" ]] && usage
  [[ -z "${bucketName-}" ]] && usage
  [[ -z "${LambdasBucketName-}" ]] && usage
  [[ -z "${aws_region-}" ]] && usage
  [[ -z "${ContainerImageUri-}" ]] && usage
  [[ -z "${microcvs_name-}" ]] && usage
  [[ -z "${MicroserviceNumber-}" ]] && usage
  return 0
}

dump_params(){
  echo ""
  echo "######      PARAMETERS      ######"
  echo "##################################"
  echo "Project Name:        ${project_name}"
  echo "Work directory:      ${work_dir}"
  echo "Custom config dir:   ${custom_config_dir}"
  echo "CICD Commit ID:      ${cd_scripts_commitId}"
  echo "Infra CommitId:      ${pn_infra_commitid}"
  echo "Microsvc CommitId:   ${pn_microsvc_commitid}"
  echo "Microsvc Name:       ${microcvs_name}"
  echo "Microsvc Idx:        ${MicroserviceNumber}"
  echo "Env Name:            ${env_type}"
  echo "AWS region:          ${aws_region}"
  echo "AWS profile:         ${aws_profile}"
  echo "Bucket Name:         ${bucketName}"
  echo "Lambda Bucket Name:  ${LambdasBucketName}"
  echo "Container image URL: ${ContainerImageUri}"
}

_clone_repository(){
  
  _DEPLOYKEY="deploykey/${microcvs_name}"
  
  echo " - try to download ssh deploykey $_DEPLOYKEY"
  _AWSDEPLOYKEYEXIST=$(aws ${aws_command_base_args} \
    secretsmanager list-secrets | \
    jq --arg keyname $_DEPLOYKEY  -c '.SecretList[] | select( .Name == $keyname )' )
  
  _GITURI="https://github.com/pagopa/${microcvs_name}.git"

  if ( [ -z "${_AWSDEPLOYKEYEXIST}" ] ); then    
    echo " - sshkey $_DEPLOYKEY not found - git clone via HTTPS"
  else
    echo " - sshkey $_DEPLOYKEY found - git clone via SSH"
    mkdir -p ~/.ssh
    curl -L https://api.github.com/meta | jq -r '.ssh_keys | .[]' | sed -e 's/^/github.com /' > ~/.ssh/known_hosts
    _AWSDEPLOYKEY=$(aws ${aws_command_base_args} \
    secretsmanager get-secret-value --secret-id $_DEPLOYKEY --output json )
    echo $_AWSDEPLOYKEY | jq '.SecretString' | cut -d "\"" -f 2 | sed 's/\\n/\n/g' > ~/.ssh/id_rsa
    chmod 400 ~/.ssh/id_rsa
    _GITURI="git@github.com:pagopa/${microcvs_name}.git"
  fi

  git clone ${_GITURI}
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

echo "=== Download microservizio ${microcvs_name}" 
if ( [ ! -e ${microcvs_name} ] ) then 
  _clone_repository
fi

echo ""
echo "=== Checkout ${microcvs_name} commitId=${pn_microsvc_commitid}"
( cd ${microcvs_name} && git fetch && git checkout $pn_microsvc_commitid )
echo " - copy custom config"
if ( [ ! -z "${custom_config_dir}" ] ) then
  cp -r $custom_config_dir/${microcvs_name} .
fi



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

echo "Environment variables file creation"
(cd ${cwdir}/commons && ./environment-files-creation.sh -p ${project_name} -r ${aws_region} -m ${microcvs_name})

echo ""
echo "=== Upload microservice files to bucket"
microserviceBucketName=$bucketName
microserviceBucketBaseKey="projects/${microcvs_name}/${pn_microsvc_commitid}_$(date +%s)"
microserviceBucketS3BaseUrl="s3://${microserviceBucketName}/${microserviceBucketBaseKey}"
aws ${aws_command_base_args} \
    s3 cp ${microcvs_name} $microserviceBucketS3BaseUrl \
      --recursive --exclude ".git/*"


echo " - Copy Lambdas zip"
lambdasZip='functions.zip'
lambdasLocalPath='functions'

functionsDirPresent=$( ( aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api head-object --bucket ${LambdasBucketName} --key "${microcvs_name}/commits/${pn_microsvc_commitid}/${lambdasZip}" 2> /dev/null > /dev/null ) && echo "OK"  || echo "KO" )
if ( [ $functionsDirPresent = "OK" ] ) then
  aws ${aws_command_base_args} --endpoint-url https://s3.eu-central-1.amazonaws.com s3api get-object \
        --bucket "$LambdasBucketName" --key "${microcvs_name}/commits/${pn_microsvc_commitid}/${lambdasZip}" \
        "${lambdasZip}"

  unzip ${lambdasZip} -d ./${lambdasLocalPath}

  # timestamp.txt workaround lambda to fix problem with Lambda versioning when deploying the same commit ID
  date > timestamp.txt

  for f in $lambdasLocalPath/*.zip; do
    if [ -f "$f" ]; then
      zip $f timestamp.txt
    fi
  done
  # end of timestamp.txt workaround

  aws ${aws_command_base_args} s3 cp --recursive \
      "${lambdasLocalPath}" \
      "${microserviceBucketS3BaseUrl}/functions_zip/"

else
  echo "File functions.zip not found, skipping lambda functions deployment"
fi

echo "Load all outputs in a single file for next stack deployments"
INFRA_ALL_OUTPUTS_FILE=infra_all_outputs-${env_type}.json
(cd ${cwdir}/commons && ./merge-infra-outputs-core.sh -r ${aws_region} -e ${env_type} -o ${work_dir}/${INFRA_ALL_OUTPUTS_FILE} )

echo "## start merge all ##"
cat $INFRA_ALL_OUTPUTS_FILE
echo "## end merge all ##"


echo ""
echo ""
echo ""
echo "======================================================================="
echo "======================================================================="
echo "===                                                                 ==="
echo "===                $microcvs_name STORAGE DEPLOYMENT                ==="
echo "===                                                                 ==="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo ""
echo "=== Prepare parameters for $microcvs_name storage deployment in $env_type ACCOUNT"
PreviousOutputFilePath=$INFRA_ALL_OUTPUTS_FILE
TemplateFilePath=${microcvs_name}/scripts/aws/cfn/storage.yml
ParamFilePath=${microcvs_name}/scripts/aws/cfn/storage-${env_type}-cfg.json
EnanchedParamFilePath=${microcvs_name}-storage-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\"ProjectName=$project_name\",\"MicroserviceNumber=${MicroserviceNumber}\",\"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid},${microcvs_name}=${pn_microsvc_commitid}\""

echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - TemplateFilePath: ${TemplateFilePath}"
echo " - ParamFilePath: ${ParamFilePath}"
echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
echo " - PipelineParams: ${PipelineParams}"

# if ParamFilePath doesn't exist, create an empty one
if [ ! -f ${ParamFilePath} ]; then
  echo "{ \"Parameters\": {} }" > ${ParamFilePath}
fi

echo ""
echo "= Read Parameters file"
cat ${ParamFilePath} 

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } * .[1]" ${PreviousOutputFilePath} ${ParamFilePath} \
   | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
   > ${EnanchedParamFilePath}
echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}


echo ""
echo "=== Deploy $microcvs_name STORAGE FOR $env_type ACCOUNT"
aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name ${microcvs_name}-storage-$env_type \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
      --template-file ${TemplateFilePath} \
      --tags "Microservice=${microcvs_name}" \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )
   



echo ""
echo ""
echo ""
echo "======================================================================="
echo "======================================================================="
echo "===                                                                 ==="
echo "===              $microcvs_name MICROSERVICE DEPLOYMENT              ==="
echo "===                                                                 ==="
echo "======================================================================="
echo "======================================================================="
echo ""
echo ""
echo ""
echo "=== Prepare parameters for $microcvs_name microservice deployment in $env_type ACCOUNT"

app_env_file_sha="-"

echo "Environment variables file upload"
bash ${cwdir}/commons/upload-files-runtime.sh -p ${project_name} -r ${aws_region} -m ${microcvs_name} -e ${env_type}

file_env_application_path=${microcvs_name}/scripts/aws/cfn/application-${env_type}.env
if [[ -f "${file_env_application_path}" ]]; then
  app_env_file_sha=$(sha256sum ${file_env_application_path} | awk '{print $1}')
  echo ""
  echo ""
fi

PreviousOutputFilePath=${microcvs_name}-storage-${env_type}-out.json
InfraIpcOutputFilePath=$INFRA_ALL_OUTPUTS_FILE
TemplateFilePath=${microcvs_name}/scripts/aws/cfn/microservice.yml
ParamFilePath=${microcvs_name}/scripts/aws/cfn/microservice-${env_type}-cfg.json
EnanchedParamFilePath=${microcvs_name}-microservice-${env_type}-cfg-enanched.json
PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\
     \"ProjectName=$project_name\",\"MicroserviceNumber=${MicroserviceNumber}\",\
     \"ContainerImageUri=${ContainerImageUri}\",\
     \"MicroserviceBucketName=${microserviceBucketName}\",\"MicroserviceBucketBaseKey=${microserviceBucketBaseKey}\",\
     \"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid},${microcvs_name}=${pn_microsvc_commitid}\",\
     \"ApplicativeEnvFileChecksum=${app_env_file_sha}\""

echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
echo " - InfraIpcOutputFilePath: ${InfraIpcOutputFilePath}"
echo " - TemplateFilePath: ${TemplateFilePath}"
echo " - ParamFilePath: ${ParamFilePath}"
echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
echo " - PipelineParams: ${PipelineParams}"


echo ""
echo "= Read Outputs from previous stack"
aws ${aws_command_base_args} \
    cloudformation describe-stacks \
      --stack-name ${microcvs_name}-storage-$env_type \
      --query "Stacks[0].Outputs" \
      --output json \
      | jq 'map({ (.OutputKey): .OutputValue}) | add' \
      | tee ${PreviousOutputFilePath}

echo ""
echo "= Read Parameters file"
cat ${ParamFilePath} 

echo ""
echo "= Enanched parameters file"
jq -s "{ \"Parameters\": .[0] } * { \"Parameters\": .[1] } * .[2]" \
   ${InfraIpcOutputFilePath} ${PreviousOutputFilePath} ${ParamFilePath} \
   | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
   > ${EnanchedParamFilePath}
echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
cat ${EnanchedParamFilePath}


echo ""
echo "=== Deploy $microcvs_name MICROSERVICE FOR $env_type ACCOUNT"
aws ${aws_command_base_args} \
    cloudformation deploy \
      --stack-name ${microcvs_name}-microsvc-$env_type \
      --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
      --template-file ${TemplateFilePath} \
      --s3-bucket ${bucketName} \
      --s3-prefix cfn \
      --tags "Microservice=${microcvs_name}" \
      --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )

if [[ -f "${microcvs_name}/scripts/aws/cfn/data-quality.yml" ]]; then
    echo ""
    echo ""
    echo ""
    echo "======================================================================="
    echo "======================================================================="
    echo "===                                                                 ==="
    echo "===              $microcvs_name DATA QUALITY DEPLOYMENT            ==="
    echo "===                                                                 ==="
    echo "======================================================================="
    echo "======================================================================="
    echo ""
    echo ""
    echo ""
    echo "=== Prepare parameters for $microcvs_name data quality deployment in $env_type ACCOUNT"
    PreviousOutputFilePath=${microcvs_name}-storage-${env_type}-out.json
    CdcAnalyticsOutputFilePath=pn-cdc-analytics-${env_type}-out.json
    InfraOutputFilePath=$INFRA_ALL_OUTPUTS_FILE
    TemplateFilePath=${microcvs_name}/scripts/aws/cfn/data-quality.yml
    ParamFilePath=${microcvs_name}/scripts/aws/cfn/data-quality-${env_type}-cfg.json
    EnanchedParamFilePath=${microcvs_name}-data-quality-${env_type}-cfg-enanched.json
    PipelineParams="\"TemplateBucketBaseUrl=$templateBucketHttpsBaseUrl\",\
         \"ProjectName=$project_name\",\"MicroserviceNumber=${MicroserviceNumber}\",\
         \"Version=cd_scripts_commitId=${cd_scripts_commitId},pn_infra_commitId=${pn_infra_commitid},${microcvs_name}=${pn_microsvc_commitid}\""

    echo " - PreviousOutputFilePath: ${PreviousOutputFilePath}"
    echo " - CdcAnalyticsOutputFilePath: ${CdcAnalyticsOutputFilePath}"
    echo " - InfraOutputFilePath: ${InfraOutputFilePath}"
    echo " - TemplateFilePath: ${TemplateFilePath}"
    echo " - ParamFilePath: ${ParamFilePath}"
    echo " - EnanchedParamFilePath: ${EnanchedParamFilePath}"
    echo " - PipelineParams: ${PipelineParams}"

    echo ""
    echo "= Read Outputs from Storage stack"
    aws ${aws_command_base_args} \
        cloudformation describe-stacks \
          --stack-name ${microcvs_name}-storage-$env_type \
          --query "Stacks[0].Outputs" \
          --output json \
          | jq 'map({ (.OutputKey): .OutputValue}) | add' \
          | tee ${PreviousOutputFilePath}

    echo ""
    echo "= Read Outputs from CDC Analytics stack"
    aws ${aws_command_base_args} \
        cloudformation describe-stacks \
          --stack-name pn-cdc-analytics-$env_type \
          --query "Stacks[0].Outputs" \
          --output json \
          | jq 'map({ (.OutputKey): .OutputValue}) | add' \
          | tee ${CdcAnalyticsOutputFilePath}

    echo ""
    echo "= Read Parameters file"
    cat ${ParamFilePath} 

    echo ""
    echo "= Enanched parameters file"
    jq -s "{ \"Parameters\": .[0] } * { \"Parameters\": .[1] } * { \"Parameters\": .[2] } * .[3]" \
       ${InfraOutputFilePath} ${PreviousOutputFilePath} ${CdcAnalyticsOutputFilePath} ${ParamFilePath} \
       | jq -s ".[] | .Parameters" | sed -e 's/": "/=/' -e 's/^{$/[/' -e 's/^}$/,/' \
       > ${EnanchedParamFilePath}
    echo "${PipelineParams} ]" >> ${EnanchedParamFilePath}
    cat ${EnanchedParamFilePath}

    echo ""
    echo "=== Deploy $microcvs_name DATA QUALITY FOR $env_type ACCOUNT"
    aws ${aws_command_base_args} \
        cloudformation deploy \
          --stack-name ${microcvs_name}-data-quality-$env_type \
          --capabilities CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND \
          --template-file ${TemplateFilePath} \
          --tags "Microservice=${microcvs_name}" \
          --parameter-overrides file://$( realpath ${EnanchedParamFilePath} )
else
    echo ""
    echo "${microcvs_name}/scripts/aws/cfn/data-quality.yml file doesn't exist, data quality deployment skipped"
fi




