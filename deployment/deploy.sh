#!/usr/bin/env bash
# Copyright 2022 Amazon Web Services, Inc
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
# Deploy (or update) TEAM:
#   1. deploy stack TEAM-IDC-APP (deployment/template.yml)
#   2. upload `git archive HEAD` of this repo to the stack's source bucket
#   3. run the CodeBuild project (amplify push, UI image, stack TEAM-IDC-UI)
#      and wait for it to finish
#
# Only COMMITTED code is shipped (git archive HEAD).
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

: "${REGION:?REGION must be set in parameters.sh (the IAM Identity Center region)}"
: "${UI_DOMAIN:?UI_DOMAIN must be set in parameters.sh (bare hostname, e.g. team.example.com)}"
: "${IDC_LOGIN_URL:?IDC_LOGIN_URL must be set in parameters.sh}"
if [ -z "${UI_PUBLIC_ZONE_ID:-}" ] && [ -z "${UI_CERTIFICATE_ARN:-}" ]; then
  echo "Set UI_PUBLIC_ZONE_ID or UI_CERTIFICATE_ARN in parameters.sh (see request-cert.sh)." >&2
  exit 1
fi

APP_STACK=TEAM-IDC-APP
CACHE_DIR="$HOME/.cache/team-deploy"
SOURCE_ZIP="$CACHE_DIR/source.zip"

# ---------------------------------------------------------------- 1. stack
echo "==> Deploying ${APP_STACK} in ${REGION}"
OVERRIDES=(
  "Login=${IDC_LOGIN_URL}"
  "CloudTrailAuditLogs=${CLOUDTRAIL_AUDIT_LOGS:-read_write}"
  "teamAdminGroup=${TEAM_ADMIN_GROUP}"
  "teamAuditGroup=${TEAM_AUDITOR_GROUP}"
  "tags=${TAGS:-}"
  "teamAccount=${TEAM_ACCOUNT:-}"
  "cacheTTL=${CACHE_TTL:-604800}"
  "UiDomain=${UI_DOMAIN}"
  "UiPublicZoneId=${UI_PUBLIC_ZONE_ID:-}"
  "UiCertificateArn=${UI_CERTIFICATE_ARN:-}"
  "AllowedClientCidr=${ALLOWED_CLIENT_CIDR:-}"
)
TAG_ARGS=()
if [ -n "${TAGS:-}" ]; then
  read -r -a TAG_LIST <<< "$TAGS"
  TAG_ARGS=(--tags "${TAG_LIST[@]}")
fi

aws cloudformation deploy --region "$REGION" --template-file template.yml \
  --stack-name "$APP_STACK" \
  --parameter-overrides "${OVERRIDES[@]}" \
  ${TAG_ARGS[@]+"${TAG_ARGS[@]}"} \
  --no-fail-on-empty-changeset --capabilities CAPABILITY_NAMED_IAM

output() {
  aws cloudformation describe-stacks --region "$REGION" --stack-name "$APP_STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue | [0]" --output text
}
SOURCE_BUCKET="$(output SourceBucket)"
BUILD_PROJECT="$(output BuildProject)"
echo "    source bucket: ${SOURCE_BUCKET}"
echo "    build project: ${BUILD_PROJECT}"

# ---------------------------------------------------------------- 2. source
if [ -n "$(git -C .. status --porcelain)" ]; then
  echo "WARNING: the working tree has uncommitted changes. git archive HEAD ships only committed code." >&2
fi
COMMIT="$(git -C .. rev-parse HEAD)"
mkdir -p "$CACHE_DIR"
echo "==> Archiving ${COMMIT} to ${SOURCE_ZIP}"
git -C .. archive --format=zip -o "$SOURCE_ZIP" HEAD

echo "==> Uploading to s3://${SOURCE_BUCKET}/source.zip"
SOURCE_VERSION="$(aws s3api put-object --region "$REGION" --bucket "$SOURCE_BUCKET" --key source.zip \
  --body "$SOURCE_ZIP" --query VersionId --output text)"
echo "    object version: ${SOURCE_VERSION}"

# ---------------------------------------------------------------- 3. build
echo "==> Starting CodeBuild ${BUILD_PROJECT}"
BUILD_ID="$(aws codebuild start-build --region "$REGION" --project-name "$BUILD_PROJECT" \
  --source-version "$SOURCE_VERSION" \
  --environment-variables-override "name=SOURCE_COMMIT,value=${COMMIT},type=PLAINTEXT" \
  --query build.id --output text)"
echo "    build id: ${BUILD_ID}"
echo "    logs: https://${REGION}.console.aws.amazon.com/codesuite/codebuild/projects/${BUILD_PROJECT}/build/${BUILD_ID//:/%3A}/log?region=${REGION}"

LAST_PHASE=""
while :; do
  read -r STATUS PHASE < <(aws codebuild batch-get-builds --region "$REGION" --ids "$BUILD_ID" \
    --query 'builds[0].[buildStatus,currentPhase]' --output text)
  if [ "$PHASE" != "$LAST_PHASE" ]; then
    echo "    $(date +%H:%M:%S) ${STATUS} ${PHASE}"
    LAST_PHASE="$PHASE"
  fi
  case "$STATUS" in
    IN_PROGRESS) sleep 20 ;;
    SUCCEEDED)
      echo "==> Build succeeded. UI: $(output UiUrl)"
      exit 0 ;;
    *)
      echo "==> Build ${BUILD_ID} finished with status ${STATUS}" >&2
      exit 1 ;;
  esac
done
