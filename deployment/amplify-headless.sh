#!/usr/bin/env bash
# Copyright 2026 Amazon Web Services, Inc
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
# Headless Amplify Gen1 backend deploy for CodeBuild.
#
# Replaces Amplify Hosting's `amplifyPush --simple`, which only exists inside
# Amplify Hosting builds. Run from the repository root (buildspec pre_build).
# Local source always wins: amplify/backend/ from the checked-out source is
# what gets pushed; nothing is pulled down over it.
#
# The Amplify App created by `amplify init` is only the backend-environment
# registry. It has no branch and hosts nothing.
#
# State:   SSM /team/amplify/app-id (String) holds the Amplify App ID.
# Inputs:  AMPLIFY_ENV (default main), AWS_REGION (set by CodeBuild).
# Output:  backend deployed, src/aws-exports.js generated.
#
# Credentials: `configLevel: general` makes the Amplify CLI use the AWS SDK
# default credential chain, which picks up CodeBuild's container credentials.
# (`useProfile: false` would require static access keys in the JSON.)
set -euo pipefail

step() { echo; echo "==> [amplify-headless] $*"; }

AMPLIFY_ENV="${AMPLIFY_ENV:-main}"
export AWS_REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-2}}"
SSM_APP_ID=/team/amplify/app-id

if [[ ! -f amplify/.config/project-config.json ]]; then
  echo "amplify/.config/project-config.json not found; run from the repository root" >&2
  exit 1
fi

# Use the project's committed name so a re-init never renames the project.
PROJECT_NAME="$(node -p "require('./amplify/.config/project-config.json').projectName")"

# The Amplify App's display name. Upstream's template.yml created the app as
# TEAM-IDC-APP, and backend code finds it by that name (the s3bucketSecurity
# custom resource; deployment/integration.sh). `amplify init` names the app
# after projectName, which the CLI restricts to alphanumerics, so the app is
# renamed after init.
APP_NAME="TEAM-IDC-APP"

AMPLIFY_JSON_BASE='"projectName":"'"$PROJECT_NAME"'","envName":"'"$AMPLIFY_ENV"'","defaultEditor":"code"'
# Credentials: the CLI needs a project-level named profile. With
# configLevel "general" most of the CLI falls back to the SDK's default chain,
# but some code paths (e.g. the auth trigger uploader) call
# getConfiguredAWSClientConfig, which returns undefined for "general" and
# crashes ("Cannot read properties of undefined (reading 'region')").
# Amplify Hosting's amplifyPush also uses a profile. In CodeBuild, materialise
# the container credentials into a dedicated profile (not "default", so the
# aws CLI elsewhere keeps using the container credential chain). Outside
# CodeBuild, use the caller's AWS_PROFILE.
if [[ -n "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:-}" ]]; then
  AMPLIFY_PROFILE="amplify-headless"
  CREDS_JSON="$(curl -fsS "http://169.254.170.2${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}")"
  cred() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s)[process.argv[1]]||""))' "$1" <<< "$CREDS_JSON"; }
  aws configure set aws_access_key_id "$(cred AccessKeyId)" --profile "$AMPLIFY_PROFILE"
  aws configure set aws_secret_access_key "$(cred SecretAccessKey)" --profile "$AMPLIFY_PROFILE"
  aws configure set aws_session_token "$(cred Token)" --profile "$AMPLIFY_PROFILE"
  aws configure set region "$AWS_REGION" --profile "$AMPLIFY_PROFILE"
  unset CREDS_JSON
else
  AMPLIFY_PROFILE="${AWS_PROFILE:?set AWS_PROFILE when running outside CodeBuild}"
fi
PROVIDERS='{"awscloudformation":{"configLevel":"project","useProfile":true,"profileName":"'"$AMPLIFY_PROFILE"'"}}'
AWS_INFO='{"configLevel":"project","useProfile":true,"profileName":"'"$AMPLIFY_PROFILE"'"}'
FRONTEND='{"frontend":"javascript","framework":"react","config":{"SourceDir":"src","DistributionDir":"build","BuildCommand":"npm run-script build","StartCommand":"npm run-script start"}}'

step "Region ${AWS_REGION}, project ${PROJECT_NAME}, env ${AMPLIFY_ENV}"

step "Resolving Amplify App ID from SSM ${SSM_APP_ID}"
APP_ID="$(aws ssm get-parameter --name "$SSM_APP_ID" --query Parameter.Value --output text 2>/dev/null || true)"
if [[ "$APP_ID" == "None" ]]; then APP_ID=""; fi

if [[ -z "$APP_ID" ]]; then
  # Recover from a build that created the app but died before writing SSM.
  step "No App ID in SSM; looking for an existing Amplify app named ${APP_NAME} or ${PROJECT_NAME}"
  MATCHES="$(aws amplify list-apps --query "apps[?name=='${APP_NAME}' || name=='${PROJECT_NAME}'].appId" --output text || true)"
  if [[ -n "$MATCHES" && "$MATCHES" != "None" ]]; then
    if [[ "$(wc -w <<< "$MATCHES")" -gt 1 ]]; then
      echo "Several Amplify apps named ${APP_NAME}/${PROJECT_NAME} exist (${MATCHES}). Put the right one in SSM ${SSM_APP_ID} and re-run." >&2
      exit 1
    fi
    APP_ID="$MATCHES"
    step "Found ${APP_ID}; recording it in SSM"
    aws ssm put-parameter --name "$SSM_APP_ID" --type String --value "$APP_ID" --overwrite >/dev/null
  fi
fi

# Does the backend environment (and its root stack) already exist?
ROOT_STACK=""
if [[ -n "$APP_ID" ]]; then
  ROOT_STACK="$(aws amplify get-backend-environment --app-id "$APP_ID" --environment-name "$AMPLIFY_ENV" \
    --query backendEnvironment.stackName --output text 2>/dev/null || true)"
  if [[ "$ROOT_STACK" == "None" ]]; then ROOT_STACK=""; fi
  if [[ -n "$ROOT_STACK" ]]; then
    STATUS="$(aws cloudformation describe-stacks --stack-name "$ROOT_STACK" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
    if [[ -z "$STATUS" || "$STATUS" == "None" || "$STATUS" == "DELETE_COMPLETE" ]]; then
      step "Backend env ${AMPLIFY_ENV} points at missing stack ${ROOT_STACK}; amplify init will recreate it"
      ROOT_STACK=""
    else
      step "Existing root stack ${ROOT_STACK} (${STATUS})"
    fi
  fi
fi

if [[ -z "$APP_ID" ]]; then
  step "First deploy: amplify init (creates the Amplify App registry and root stack)"
  amplify init \
    --amplify "{${AMPLIFY_JSON_BASE}}" \
    --providers "$PROVIDERS" \
    --frontend "$FRONTEND" \
    --yes

  APP_ID="$(node -p "
    const fs = require('fs');
    let id = '';
    try { id = require('./amplify/team-provider-info.json')['${AMPLIFY_ENV}'].awscloudformation.AmplifyAppId || ''; } catch (e) {}
    if (!id) { try { id = require('./amplify/backend/amplify-meta.json').providers.awscloudformation.AmplifyAppId || ''; } catch (e) {} }
    id")"
  if [[ -z "$APP_ID" ]]; then
    echo "amplify init succeeded but no AmplifyAppId found in team-provider-info.json or amplify-meta.json" >&2
    exit 1
  fi
  step "Recording App ID ${APP_ID} in SSM ${SSM_APP_ID}"
  aws ssm put-parameter --name "$SSM_APP_ID" --type String --value "$APP_ID" --overwrite >/dev/null

elif [[ -z "$ROOT_STACK" ]]; then
  step "App ${APP_ID} exists but env ${AMPLIFY_ENV} has no root stack: amplify init against the existing app"
  amplify init \
    --amplify "{${AMPLIFY_JSON_BASE},\"appId\":\"${APP_ID}\"}" \
    --providers "$PROVIDERS" \
    --frontend "$FRONTEND" \
    --yes

else
  # Same sequence as Amplify Hosting's amplifyPush for an existing env:
  # `env import` registers the env locally (so init does not try to create a
  # second root stack), then `init --appId` attaches to it. Unlike
  # `amplify pull`, neither step overwrites amplify/backend/.
  step "Rebuilding env config for ${AMPLIFY_ENV} from root stack ${ROOT_STACK} outputs"
  STACK_INFO="$(aws cloudformation describe-stacks --stack-name "$ROOT_STACK" --output json | APP_ID="$APP_ID" node -e '
    let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
      const st = JSON.parse(s).Stacks[0];
      const o = Object.fromEntries((st.Outputs || []).map(x => [x.OutputKey, x.OutputValue]));
      const need = ["Region","DeploymentBucketName","UnauthRoleName","UnauthRoleArn","AuthRoleName","AuthRoleArn","StackName","StackId"];
      const missing = need.filter(k => !o[k]);
      if (missing.length) { console.error("root stack outputs missing: " + missing.join(",")); process.exit(1); }
      const cfg = {}; need.forEach(k => cfg[k] = o[k]);
      cfg.AmplifyAppId = process.env.APP_ID;
      process.stdout.write(JSON.stringify({ awscloudformation: cfg }));
    });')"

  step "amplify env import --name ${AMPLIFY_ENV}"
  amplify env import --name "$AMPLIFY_ENV" --config "$STACK_INFO" --awsInfo "$AWS_INFO" --yes

  step "amplify init against existing app ${APP_ID} / env ${AMPLIFY_ENV}"
  amplify init \
    --amplify "{${AMPLIFY_JSON_BASE},\"appId\":\"${APP_ID}\"}" \
    --providers "$PROVIDERS" \
    --frontend "$FRONTEND" \
    --yes
fi

CURRENT_NAME="$(aws amplify get-app --app-id "$APP_ID" --query app.name --output text)"
if [[ "$CURRENT_NAME" != "$APP_NAME" ]]; then
  step "Renaming Amplify app ${APP_ID} from ${CURRENT_NAME} to ${APP_NAME}"
  aws amplify update-app --app-id "$APP_ID" --name "$APP_NAME" >/dev/null
fi

step "amplify status"
amplify status || true

step "amplify push"
# The CLI often reports only a summary ("Unable to upload trigger files to
# S3"); the underlying error is in its own log, which dies with the build
# container. Print the tail of that log on failure.
if ! amplify push --yes --allow-destructive-graphql-schema-updates; then
  echo "---- amplify CLI log (tail) ----" >&2
  tail -n 150 "$HOME"/.amplify/logs/amplify-cli-*.log >&2 2>/dev/null || echo "(no CLI log found under ~/.amplify/logs)" >&2
  exit 1
fi

if [[ ! -f src/aws-exports.js ]]; then
  echo "amplify push finished but src/aws-exports.js was not generated" >&2
  exit 1
fi
step "Done: backend pushed, src/aws-exports.js generated"
