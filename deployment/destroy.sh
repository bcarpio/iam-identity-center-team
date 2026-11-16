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
# Tear down TEAM completely:
#   TEAM-IDC-UI -> Amplify backend stack -> Amplify app -> ECR images and
#   source bucket contents -> TEAM-IDC-APP -> SSM /team/amplify/app-id
#
# Usage: ./destroy.sh [--yes]
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

APP_STACK=TEAM-IDC-APP
UI_STACK=TEAM-IDC-UI
SSM_APP_ID=/team/amplify/app-id
AMPLIFY_ENV=main

if [ "${1:-}" != "--yes" ]; then
  read -r -p "Delete TEAM (${UI_STACK}, Amplify backend, ${APP_STACK}) in ${REGION}? Type DESTROY: " answer
  [ "$answer" = "DESTROY" ] || { echo "Aborted."; exit 1; }
fi

stack_exists() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$1" >/dev/null 2>&1
}
delete_stack() {
  if stack_exists "$1"; then
    echo "==> Deleting stack $1"
    aws cloudformation delete-stack --region "$REGION" --stack-name "$1"
    aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$1"
  else
    echo "==> Stack $1 not found; skipping"
  fi
}

# 1. UI service
delete_stack "$UI_STACK"

# 2-3. Amplify backend stack and app registry
APP_ID="$(aws ssm get-parameter --region "$REGION" --name "$SSM_APP_ID" --query Parameter.Value --output text 2>/dev/null || true)"
if [ -n "$APP_ID" ] && [ "$APP_ID" != "None" ]; then
  BACKEND_STACK="$(aws amplify get-backend-environment --region "$REGION" --app-id "$APP_ID" \
    --environment-name "$AMPLIFY_ENV" --query backendEnvironment.stackName --output text 2>/dev/null || true)"
  if [ -n "$BACKEND_STACK" ] && [ "$BACKEND_STACK" != "None" ]; then
    delete_stack "$BACKEND_STACK"
  fi
  echo "==> Deleting Amplify app ${APP_ID}"
  aws amplify delete-app --region "$REGION" --app-id "$APP_ID" >/dev/null || true
else
  echo "==> No Amplify app id in SSM ${SSM_APP_ID}; skipping Amplify backend"
fi

# 4. Empty the ECR repository and the (versioned) source bucket
if stack_exists "$APP_STACK"; then
  output() {
    aws cloudformation describe-stacks --region "$REGION" --stack-name "$APP_STACK" \
      --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" --output text
  }
  REPO_URI="$(output UiRepositoryUri)"
  BUCKET="$(output SourceBucket)"

  if [ -n "$REPO_URI" ] && [ "$REPO_URI" != "None" ]; then
    REPO_NAME="${REPO_URI#*/}"
    echo "==> Emptying ECR repository ${REPO_NAME}"
    aws ecr list-images --region "$REGION" --repository-name "$REPO_NAME" --query 'imageIds' --output json \
      | jq -c 'range(0; length; 100) as $i | .[$i:$i+100]' \
      | while read -r ids; do
          [ "$ids" = "[]" ] && continue
          aws ecr batch-delete-image --region "$REGION" --repository-name "$REPO_NAME" --image-ids "$ids" >/dev/null
        done
  fi

  if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
    echo "==> Emptying s3://${BUCKET} (all versions)"
    aws s3api list-object-versions --region "$REGION" --bucket "$BUCKET" --output json \
      | jq -c '[(.Versions // [])[], (.DeleteMarkers // [])[] | {Key, VersionId}]
               | range(0; length; 1000) as $i | {Objects: .[$i:$i+1000], Quiet: true}' \
      | while read -r batch; do
          aws s3api delete-objects --region "$REGION" --bucket "$BUCKET" --delete "$batch" >/dev/null
        done
  fi
fi

# 5. Application stack (deletes the now-empty repository and bucket)
delete_stack "$APP_STACK"

# 6. App id pointer
aws ssm delete-parameter --region "$REGION" --name "$SSM_APP_ID" 2>/dev/null || true
echo "==> TEAM destroyed"
