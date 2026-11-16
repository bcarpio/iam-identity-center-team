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
# Request (or reuse) the ACM certificate for the private TEAM UI hostname.
#
# Use this when the public DNS zone for UI_DOMAIN's parent domain lives in
# another account (or another DNS system, e.g. InfoBlox), so CloudFormation
# cannot validate the certificate itself. The flow is a one-time hand-off:
#
#   1. ./request-cert.sh
#        Requests a DNS-validated ECDSA P-256 certificate for UI_DOMAIN in
#        REGION (or reuses an existing one) and prints the one validation
#        CNAME, as plain values and as a Terraform aws_route53_record block.
#   2. The DNS owner adds that CNAME to the public zone. Keep it there: ACM
#      uses the same record for automatic renewal.
#   3. ./request-cert.sh --wait
#        Blocks until the certificate is ISSUED.
#   4. Put the printed ARN in parameters.sh as UI_CERTIFICATE_ARN.
#
# Imported / internal-CA certificates: do not run this script. Import the
# certificate into ACM in REGION yourself and set UI_CERTIFICATE_ARN directly.
# If the public zone is a Route 53 zone in the TEAM account, set
# UI_PUBLIC_ZONE_ID instead and let template.yml issue the certificate.
#
# Note: the hostname appears in Certificate Transparency logs. That makes it
# known, not reachable: it resolves only inside the VPC.
#
# Usage: ./request-cert.sh [--wait]
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=/dev/null
. "./parameters.sh"

WAIT=false
for arg in "$@"; do
  case "$arg" in
    --wait) WAIT=true ;;
    -h|--help) sed -n '16,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [ -n "${TEAM_ACCOUNT_PROFILE:-}" ]; then export AWS_PROFILE="$TEAM_ACCOUNT_PROFILE"; fi
: "${REGION:?REGION must be set in parameters.sh}"
: "${UI_DOMAIN:?UI_DOMAIN must be set in parameters.sh (bare hostname)}"

# list-certificates returns only RSA_1024/RSA_2048 unless key types are listed.
KEY_TYPES="RSA_1024,RSA_2048,RSA_3072,RSA_4096,EC_prime256v1,EC_secp384r1,EC_secp521r1"

# Reusable = anything that is not FAILED / EXPIRED / REVOKED. VALIDATION_TIMED_OUT
# is also skipped: ACM cannot re-validate it, a new request is required.
# Prefer an ISSUED certificate over a pending one.
find_cert() {
  local status arn
  for status in ISSUED PENDING_VALIDATION INACTIVE; do
    arn="$(aws acm list-certificates --region "$REGION" \
      --certificate-statuses "$status" --includes "keyTypes=${KEY_TYPES}" \
      --query "CertificateSummaryList[?DomainName=='${UI_DOMAIN}'].CertificateArn | [0]" --output text)"
    if [ -n "$arn" ] && [ "$arn" != "None" ]; then echo "$arn"; return 0; fi
  done
  return 1
}

if CERT_ARN="$(find_cert)"; then
  echo "==> Reusing existing certificate for ${UI_DOMAIN}: ${CERT_ARN}"
else
  echo "==> Requesting certificate for ${UI_DOMAIN} in ${REGION}"
  TAG_ARGS=()
  if [ -n "${TAGS:-}" ]; then
    read -r -a TAG_LIST <<< "$TAGS"
    for kv in "${TAG_LIST[@]}"; do TAG_ARGS+=("Key=${kv%%=*},Value=${kv#*=}"); done
  fi
  CERT_ARN="$(aws acm request-certificate --region "$REGION" \
    --domain-name "$UI_DOMAIN" \
    --validation-method DNS \
    --key-algorithm EC_prime256v1 \
    --idempotency-token teamui \
    ${TAG_ARGS[@]+--tags "${TAG_ARGS[@]}"} \
    --query CertificateArn --output text)"
  echo "    ${CERT_ARN}"
fi

# The validation record appears a few seconds after the request.
echo "==> Waiting for the DNS validation record"
RECORD=""
for _ in $(seq 1 30); do
  RECORD="$(aws acm describe-certificate --region "$REGION" --certificate-arn "$CERT_ARN" \
    --query 'Certificate.DomainValidationOptions[0].ResourceRecord.[Name,Type,Value]' --output text)"
  if [ -n "$RECORD" ] && [ "$RECORD" != "None" ]; then break; fi
  RECORD=""
  sleep 5
done
if [ -z "$RECORD" ]; then
  echo "No validation record after 150s; re-run this script." >&2
  exit 1
fi
read -r REC_NAME REC_TYPE REC_VALUE <<< "$RECORD"
STATUS="$(aws acm describe-certificate --region "$REGION" --certificate-arn "$CERT_ARN" \
  --query Certificate.Status --output text)"

cat <<EOT

Certificate status: ${STATUS}

DNS validation record (add once to the PUBLIC zone; keep it for renewals):
  Name:  ${REC_NAME}
  Type:  ${REC_TYPE}
  Value: ${REC_VALUE}

Terraform:
  resource "aws_route53_record" "team_ui_acm_validation" {
    zone_id = var.zone_id # the public zone that contains ${UI_DOMAIN}
    name    = "${REC_NAME}"
    type    = "${REC_TYPE}"
    ttl     = 300
    records = ["${REC_VALUE}"]
  }

Then set in parameters.sh:
  UI_CERTIFICATE_ARN=${CERT_ARN}
EOT

if [ "$WAIT" = true ] && [ "$STATUS" != "ISSUED" ]; then
  echo
  echo "==> Waiting for ${CERT_ARN} to be ISSUED (Ctrl-C to stop)"
  until aws acm wait certificate-validated --region "$REGION" --certificate-arn "$CERT_ARN" 2>/dev/null; do
    STATUS="$(aws acm describe-certificate --region "$REGION" --certificate-arn "$CERT_ARN" \
      --query Certificate.Status --output text)"
    case "$STATUS" in
      ISSUED) break ;;
      PENDING_VALIDATION) echo "    $(date +%H:%M:%S) still PENDING_VALIDATION" ;;
      *) echo "Certificate status ${STATUS}; giving up." >&2; exit 1 ;;
    esac
  done
  echo "==> ISSUED: ${CERT_ARN}"
fi
