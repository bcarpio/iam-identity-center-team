# Copyright 2022 Amazon Web Services, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License 

#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

#!/usr/bin/env bash

. "./parameters.sh"

if [ -z "$TEAM_ACCOUNT" ]; then 
  export AWS_PROFILE=$ORG_MASTER_PROFILE
else 
  export AWS_PROFILE=$TEAM_ACCOUNT_PROFILE
fi

green='\033[0;32m'
clear='\033[0m'
cognitoUserpoolId=`aws cognito-idp list-user-pools --region $REGION --max-results 10 --output json | jq -r '.UserPools[] | select(.Name | contains("team06dbb7fc")) | .Id'`
cognitouserpoolhostedUIdomain=`aws cognito-idp describe-user-pool --region $REGION --user-pool-id $cognitoUserpoolId --output json | jq -r '.UserPool.Domain'`
cognitoClientWebClientID=`aws cognito-idp list-user-pool-clients --region $REGION --user-pool-id $cognitoUserpoolId --output json | jq -r '.UserPoolClients[] | select(.ClientName | contains("clientWeb")) | .ClientId'`
cognitoHostedUIdomain=$cognitouserpoolhostedUIdomain.auth.$REGION.amazoncognito.com

# This fork serves the UI from the internal ALB at UI_DOMAIN, not Amplify Hosting.
if [ -z "${UI_DOMAIN:-}" ]; then
  echo "UI_DOMAIN is not set in parameters.sh" >&2
  exit 1
fi

applicationStartURL="https://$cognitoHostedUIdomain/authorize?client_id=$cognitoClientWebClientID&response_type=code&scope=aws.cognito.signin.user.admin+email+openid+phone+profile&redirect_uri=https://$UI_DOMAIN/&idp_identifier=team"
applicationACSURL="https://$cognitoHostedUIdomain/saml2/idpresponse"
applicationSAMLAudience="urn:amazon:cognito:sp:$cognitoUserpoolId"

printf "\n${green}applicationStartURL:${clear} %s\n${green}applicationACSURL:${clear} %s\n${green}applicationSAMLAudience:${clear} %s\n\n" "$applicationStartURL" "$applicationACSURL" "$applicationSAMLAudience"
