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
  const res = await awsClient._getSSMParameter(param)
  const tmp = isJSON(res.Parameter.Value) ? JSON.parse(res.Parameter.Value) : `${res.Parameter.Value}`
  return tmp;
}

function appendResult(fileName, data){
  if(!fs.existsSync(`results`))
    fs.mkdirSync(`results`, { recursive: true });
  fs.appendFileSync(`results/${fileName}`, data + "\n")
}

async function main() {
  const awsClient = new AwsClientsWrapper(profile);
  const path = `${parametersPath}/${envName}/_conf/${account}/system_params`
  const manifestPath = `${path}/_manifest.json`
  console.log(manifestPath)
  const parameters = fs.existsSync(manifestPath) ? JSON.parse(fs.readFileSync(manifestPath)) : []
  if(parameters.length == 0) {
    console.log(`No manifest configured in ${envName} environment.`)
  }
  for(const param of parameters) {
    const paramName = param.paramName
    const localName = param.localName
    const awsParam = await getAWSParam(awsClient, paramName)
    const localParam = getLocalParam(`${path}/${localName}`)
    if(JSON.stringify(awsParam) != JSON.stringify(localParam)) {
      appendResult('error.log', `${paramName} KO`)
      console.log(`${paramName} KO`)
    } else {
      appendResult('success.log', `${paramName} OK`)
      console.log(`${paramName} OK`)
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