const { AwsClientsWrapper } = require("./libs/AwsClientWrapper");
const { parseArgs } = require('util');
const fs = require('fs');

function _checkingParameters(args, values){
  const usage = "Usage: index.js --envName <env-name> --account <account> --parametersPath <parametersPath>"
  //CHECKING PARAMETER
  args.forEach(el => {
    if(el.mandatory && !values.values[el.name]){
      console.log("Param " + el.name + " is not defined")
      console.log(usage)
      process.exit(1)
    }
  })
  args.filter(el=> {
    return el.subcommand.length > 0
  }).forEach(el => {
    if(values.values[el.name]) {
      el.subcommand.forEach(val => {
        if (!values.values[val]) {
          console.log("SubParam " + val + " is not defined")
          console.log(usage)
          process.exit(1)
        }
      })
    }
  })
}

function getParameterToCheck(path) {
  if(fs.existsSync(path)){
    const parametersToCheck = fs.readdirSync(`${parametersPath}/${envName}/_conf/${account}/system_params`)
    return parametersToCheck
  }
  return []
}

function normalizeParameter(param) {
  let tmp = param.split('.')[0];
  if(param.indexOf('##A##') > 0) {
    tmp = tmp.replace('##A##', '')
  }
  const normalizedParameter = tmp.replace(/#/g, '/')
  return normalizedParameter;
} 

function isJSON(value) {
  try {
    JSON.parse(value)
    return true
  } catch (error) {
    return false
  }
}

function getLocalParam(filePath) {
  const data = fs.readFileSync(filePath, { encoding: 'utf8', flag: 'r' })
  const tmp = isJSON(data) ? JSON.parse(data) : `${data}`
  return tmp;
}

async function getAWSParam(awsClient, param) {
  const normalizedParameter = normalizeParameter(param)
  const res = await awsClient._getSSMParameter(normalizedParameter)
  const tmp = isJSON(res.Parameter.Value) ? JSON.parse(res.Parameter.Value) : `${res.Parameter.Value}`
  return tmp;
}

async function main() {
  const awsClient = new AwsClientsWrapper(profile);
  const path = `${parametersPath}/${envName}/_conf/${account}/system_params`
  const parameters = getParameterToCheck(path)
  for(const param of parameters) {
    const normalizedParameter = normalizeParameter(param)
    const awsParam = await getAWSParam(awsClient, normalizedParameter)
    const localParam = getLocalParam(`${path}/${param}`)
    if(awsParam !== localParam) {
      console.log(`${normalizedParameter} KO`)
      process.exit(1) 
    } else {
      console.log(`${normalizedParameter} OK`)
    }
  }
}

const args = [
  { name: "envName", mandatory: true, subcommand: [] },
  { name: "account", mandatory: true, subcommand: [] },
  { name: "parametersPath", mandatory: true, subcommand: [] },
  { name: "profile", mandatory: false, subcommand: [] }
]
const values = {
  values: { envName, account, parametersPath, profile },
} = parseArgs({
  options: {
    envName: {
      type: "string", short: "e", default: undefined
    },
    account: {
      type: "string", short: "a", default: undefined
    },
    parametersPath: {
      type: "string", short: "p", default: undefined
    },
    profile: {
      type: "string", short: "p", default: undefined
    },
  },
});  

_checkingParameters(args, values)
main();