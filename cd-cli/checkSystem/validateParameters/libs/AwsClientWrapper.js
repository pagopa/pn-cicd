
const { SSMClient, GetParameterCommand, PutParameterCommand, DescribeParametersCommand} = require("@aws-sdk/client-ssm");
const { fromIni } = require("@aws-sdk/credential-provider-ini");

function awsClientCfg( profile ) {
  const self = this;
  return { 
    region: "eu-south-1", 
    credentials: fromIni({ 
      profile: profile,
    })
  }
}

class AwsClientsWrapper {

  constructor(profile) {
    if(profile) {
      this._ssmCoreClient = new SSMClient( awsClientCfg( profile ));
    }
    else {
      this._ssmCoreClient = new SSMClient()
    }
  }

  async _getSSMParameter(param) {
    const input = { // GetParameterRequest
      Name: param, // required
      WithDecryption: true,
    };
    const res = await this._ssmCoreClient.send(new GetParameterCommand(input));
    return res
  }

  async _getSSMParameterDescriptionTier(param) {
    const input = { // DescribeParametersRequest
      Filters: [ // ParametersFilterList
        { // ParametersFilter
          Key: "Name", // required
          Values: [ // ParametersFilterValueList // required
            param,
          ],
        },
      ],
    };
    const res = await this._ssmCoreClient.send(new DescribeParametersCommand(input));
    if(res) {
      var parameters = {}
      res.Parameters?.forEach(x => {
          parameters[x.Name] = x.Tier; 
      })
      return parameters
    }
  }

  async _updateSSMParameter(name, tier, value) {
    const input = { // PutParameterRequest
      Name: name, // required
      Value: value, // required
      Type: "String", 
      Overwrite: true,
      Tier: tier,
    };
    const command = new PutParameterCommand(input);
    const res = await this._getClient(accountName).send(command);
    if(res["$metadata"].httpStatusCode != 200) 
      this._errorDuringProcess(res.httpStatusCode, "_updateSSMParameter")
  }

  async _listSSMParameters(accountName) {
    const input = { // DescribeParametersRequest
      Filters: [ // ParametersFilterList
        
      ],
      MaxResults: 50,
    };

    // pagination and return all parameters
    var parameters = {}
    var nextToken = ""
    do {
      input.NextToken = nextToken
      const res = await this._getClient(accountName).send(new DescribeParametersCommand(input));
      if(res) {
        res.Parameters?.forEach(x => {
            parameters[x.Name] = x
        })
        nextToken = res.NextToken ? res.NextToken : ""
      }
      else {
        this._errorDuringProcess(res.httpStatusCode, "_listSSMParameters")
      }
    } while (nextToken != "")        

    return parameters;

  }

  _errorDuringProcess(httpStatusCode, methodName){
    console.error("Error during process, HTTPStatusCode= " + httpStatusCode + " during " + methodName + " method execution")
    process.exit(1)
  }
}

exports.AwsClientsWrapper = AwsClientsWrapper;

