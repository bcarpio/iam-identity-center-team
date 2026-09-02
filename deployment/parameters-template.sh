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

# Copy to parameters.sh (git-ignored) and edit.

IDC_LOGIN_URL=https://d-90676dxxxx.awsapps.com/start
# Must be the IAM Identity Center region (template.yml asserts it).
REGION=us-east-2
TEAM_ACCOUNT=123456789101
ORG_MASTER_PROFILE=org_master_profile
TEAM_ACCOUNT_PROFILE=team_account_profile
TEAM_ADMIN_GROUP="team_admin_group_name"
TEAM_AUDITOR_GROUP="team_auditor_group_name"
TAGS="Environment=nonprod Application=team ManagedBy=cloudformation"
# read_write/read/write need CloudTrail Lake, closed to new customers; use none or cwlogs://.
CLOUDTRAIL_AUDIT_LOGS=none
# CloudTrail Lake is closed to new customers. To query the Control Tower org
# trail's CloudWatch log group instead (see docs/docs/deployment/configuration/cwlogs.md):
#   CLOUDTRAIL_AUDIT_LOGS=cwlogs://aws-controltower/CloudTrailLogs-<suffix>
#   CWLOGS_ASSUME_ROLE_ARN=arn:aws:iam::<management-account>:role/TEAM-CWLogs-Query
CWLOGS_ASSUME_ROLE_ARN=
CACHE_TTL=604800

# Private UI hostname (bare, no scheme).
# Resolves only inside the VPC via a private hosted zone of the same name.
UI_DOMAIN=team.example.com
# Certificate: set ONE of these.
#  - UI_PUBLIC_ZONE_ID: a public Route 53 zone for UI_DOMAIN in the TEAM
#    account; CloudFormation issues and validates the certificate itself.
#  - UI_CERTIFICATE_ARN: a certificate already issued in REGION (see
#    request-cert.sh, or import one from your internal CA).
UI_PUBLIC_ZONE_ID=
UI_CERTIFICATE_ARN=
# Optional extra CIDR (e.g. corporate network over DX/TGW/VPN) allowed to
# reach the internal ALB on 443. The VPC CIDR is always allowed.
ALLOWED_CLIENT_CIDR=
