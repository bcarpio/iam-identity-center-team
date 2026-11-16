// © 2021 Amazon Web Services, Inc. or its affiliates. All Rights Reserved.
// This AWS Content is provided subject to the terms of the AWS Customer Agreement available at
// http://aws.amazon.com/agreement or other written agreement between Customer and either
// Amazon Web Services, Inc. or Amazon Web Services EMEA SARL or both.

const fs = require("fs");
const path = require("path");

const {
  SSO_LOGIN,
  TEAM_ADMIN_GROUP,
  TEAM_AUDITOR_GROUP,
  TAGS,
  CLOUDTRAIL_AUDIT_LOGS,
  TEAM_ACCOUNT,
  UI_DOMAIN,
  COGNITO_DOMAIN_PREFIX,
  LAMBDA_SUBNET_IDS,
  LAMBDA_SECURITY_GROUP_ID,
} = process.env;

// Lambda functions that run inside the VPC. Listed explicitly (never globbed)
// so only these functions receive a VpcConfig.
const VPC_FUNCTIONS = [
  "teamRouter",
  "teamStatus",
  "teamgetEntitlement",
  "teamGetPermissionSets",
  "teamPublishOUs",
  "teamgetLogs",
];
module.exports = { VPC_FUNCTIONS };

const REQUIRED_ENV_VARS = {
  UI_DOMAIN,
  COGNITO_DOMAIN_PREFIX,
  LAMBDA_SUBNET_IDS,
  LAMBDA_SECURITY_GROUP_ID,
};
for (const [name, value] of Object.entries(REQUIRED_ENV_VARS)) {
  if (!value || !value.trim()) {
    console.error(`required environment variable ${name} is not set`);
    process.exit(1);
  }
}

async function update_auth_parameters() {
  console.log(`updating amplify config for UI domain "${UI_DOMAIN}"...`);
  // update callback/logout redirect urls for build url
  const backendConfig = require(path.resolve(
    "./amplify/backend/backend-config.json"
  ));
  const authResourceName = Object.keys(backendConfig.auth)[0];
  const authParametersJsonPath = path.resolve(
    `./amplify/backend/auth/${authResourceName}/cli-inputs.json`
  );
  const authParametersJson = require(authParametersJsonPath);
  const oAuthMetadata = JSON.parse(
    authParametersJson.cognitoConfig.oAuthMetadata
  );
  const uiUrl = `https://${UI_DOMAIN}/`;

  console.log("domain", uiUrl);
  oAuthMetadata.CallbackURLs = [uiUrl];
  oAuthMetadata.LogoutURLs = [uiUrl];

  authParametersJson.cognitoConfig.oAuthMetadata =
    JSON.stringify(oAuthMetadata);

  authParametersJson.cognitoConfig.hostedUIDomainName = COGNITO_DOMAIN_PREFIX;

  fs.writeFileSync(
    authParametersJsonPath,
    JSON.stringify(authParametersJson, null, 4)
  );
}
async function update_react_parameters() {
  console.log(`updating react parameters"...`);
  const reactParametersJsonPath = path.resolve(`./src/parameters.json`);
  const reactParametersJson = require(reactParametersJsonPath);
  reactParametersJson.Login = SSO_LOGIN;

  console.log("Team Account param:");
  console.log(TEAM_ACCOUNT);
  if (TEAM_ACCOUNT === undefined) {
    reactParametersJson.DeploymentType = "management"
  } else {
    reactParametersJson.DeploymentType = "delegated"
  };

  reactParametersJson.teamAdminGroup = TEAM_ADMIN_GROUP;
  reactParametersJson.teamAuditorGroup = TEAM_AUDITOR_GROUP;


  fs.writeFileSync(
    reactParametersJsonPath,
    JSON.stringify(reactParametersJson, null, 4)
  );
}

async function update_groups_parameters() {
  console.log(`updating team06dbb7fcPreTokenGeneration lambda parameters"...`);

  const groupsParametersJsonPath = path.resolve(
    `./amplify/backend/function/team06dbb7fcPreTokenGeneration/parameters.json`
  );
  const groupsParametersJson = require(groupsParametersJsonPath);

  groupsParametersJson.teamAdminGroup = TEAM_ADMIN_GROUP;
  groupsParametersJson.teamAuditorGroup = TEAM_AUDITOR_GROUP;

  fs.writeFileSync(
    groupsParametersJsonPath,
    JSON.stringify(groupsParametersJson, null, 4)
  );
}

async function update_router_parameters() {
  console.log(`updating teamRouter lambda parameters"...`);

  const routerParametersJsonPath = path.resolve(
    `./amplify/backend/function/teamRouter/parameters.json`
  );
  const routerParametersJson = require(routerParametersJsonPath);

  routerParametersJson.SSOLoginUrl = SSO_LOGIN;

  fs.writeFileSync(
    routerParametersJsonPath,
    JSON.stringify(routerParametersJson, null, 4)
  );
}

async function update_tag_parameters() {
  console.log(`updating amplify/backend/tags.json"...`);

  const tagsParametersJsonPath = path.resolve(
    `./amplify/backend/tags.json`
  );

  const tagsArray = TAGS ? TAGS.split(' ').map((tag) => {
    const [key, value] = tag.split('=');
    return {
      Key: key,
      Value: value,
    };
  }) : [];

  fs.writeFileSync(tagsParametersJsonPath, JSON.stringify(tagsArray, null, 2));
}

async function update_cloudtrail_parameters() {
  console.log(`updating amplify/backend/custom/cloudtrailLake/parameters.json"...`);

  const cloudtrailParametersJsonPath = path.resolve(
    `./amplify/backend/custom/cloudtrailLake/parameters.json`
  );

  const cloudtrailParametersJson = require(cloudtrailParametersJsonPath);

  cloudtrailParametersJson.CloudTrailAuditLogs = CLOUDTRAIL_AUDIT_LOGS;
  
  fs.writeFileSync(
    cloudtrailParametersJsonPath,
    JSON.stringify(cloudtrailParametersJson, null, 4)
  );
}

async function update_cloudtrail_parameters() {
  console.log(`updating amplify/backend/custom/cloudtrailLake/parameters.json"...`);

  const cloudtrailParametersJsonPath = path.resolve(
    `./amplify/backend/custom/cloudtrailLake/parameters.json`
  );

  const cloudtrailParametersJson = require(cloudtrailParametersJsonPath);

  cloudtrailParametersJson.CloudTrailAuditLogs = CLOUDTRAIL_AUDIT_LOGS;
  
  fs.writeFileSync(
    cloudtrailParametersJsonPath,
    JSON.stringify(cloudtrailParametersJson, null, 4)
  );
}

async function update_vpc_parameters() {
  for (const functionName of VPC_FUNCTIONS) {
    console.log(`updating ${functionName} lambda VPC parameters...`);

    const vpcParametersJsonPath = path.resolve(
      `./amplify/backend/function/${functionName}/parameters.json`
    );
    // A missing function directory means VPC_FUNCTIONS names a function that
    // does not exist (typo or rename); fail rather than create a stray dir.
    if (!fs.existsSync(path.dirname(vpcParametersJsonPath))) {
      console.error(`VPC function ${functionName} not found under amplify/backend/function`);
      process.exit(1);
    }
    // Read from disk rather than require() so earlier writes in this run
    // (e.g. update_router_parameters) are preserved.
    const vpcParametersJson = fs.existsSync(vpcParametersJsonPath)
      ? JSON.parse(fs.readFileSync(vpcParametersJsonPath, "utf8"))
      : {};

    vpcParametersJson.vpcSubnetIds = LAMBDA_SUBNET_IDS;
    vpcParametersJson.vpcSecurityGroupId = LAMBDA_SECURITY_GROUP_ID;

    fs.writeFileSync(
      vpcParametersJsonPath,
      JSON.stringify(vpcParametersJson, null, 4)
    );
  }
}

update_auth_parameters();
update_react_parameters();
update_groups_parameters();
update_router_parameters()
update_tag_parameters();
update_cloudtrail_parameters();
update_vpc_parameters();