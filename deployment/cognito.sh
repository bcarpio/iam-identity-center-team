#!/usr/bin/env bash
# Copyright 2023 Amazon Web Services, Inc
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Wire IAM Identity Center (SAML, details.json) into the TEAM Cognito user
# pool and point the web client's OAuth callback/logout at https://$UI_DOMAIN/.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=/dev/null
. "./parameters.sh"

if [ -z "${TEAM_ACCOUNT:-}" ]; then
  PROFILE="${ORG_MASTER_PROFILE:-}"
else
  PROFILE="${TEAM_ACCOUNT_PROFILE:-}"
fi
if [ -n "$PROFILE" ]; then export AWS_PROFILE="$PROFILE"; fi

: "${REGION:?REGION must be set in parameters.sh}"
: "${UI_DOMAIN:?UI_DOMAIN must be set in parameters.sh (bare hostname)}"

cognitoUserpoolId=$(aws cognito-idp list-user-pools --region "$REGION" --max-results 60 --output json | jq -r '.UserPools[] | select(.Name | contains("team06dbb7fc")) | .Id')
if [ -z "$cognitoUserpoolId" ]; then
  echo "TEAM Cognito user pool (name contains team06dbb7fc) not found in $REGION" >&2
  exit 1
fi
clientID=$(aws cognito-idp list-user-pool-clients --region "$REGION" --user-pool-id "$cognitoUserpoolId" --output json | jq -r '.UserPoolClients[] | select(.ClientName | contains("clientWeb")) | .ClientId')

uiUrl="https://${UI_DOMAIN}/"
echo "User pool: $cognitoUserpoolId  client: $clientID  callback/logout: $uiUrl"

aws cognito-idp create-identity-provider --region "$REGION" --user-pool-id "$cognitoUserpoolId" --provider-name=IDC --provider-type SAML --provider-details file://details.json --attribute-mapping email=Email --idp-identifiers team
aws cognito-idp update-user-pool-client --region "$REGION" --user-pool-id "$cognitoUserpoolId" \
--client-id "$clientID" \
--refresh-token-validity 1 \
--supported-identity-providers IDC \
--allowed-o-auth-flows code \
--allowed-o-auth-scopes "phone" "email" "openid" "profile" "aws.cognito.signin.user.admin" \
--logout-urls "$uiUrl"  \
--callback-urls "$uiUrl" \
--allowed-o-auth-flows-user-pool-client
