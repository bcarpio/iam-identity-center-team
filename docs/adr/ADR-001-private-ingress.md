# ADR-001: Private ingress for TEAM (internal ALB, private AppSync, VPC Lambdas)

## Status

Accepted (2026-11-16)

## Context

Upstream TEAM serves its React SPA from Amplify Hosting, which is a public
CloudFront distribution, and its AppSync GraphQL API is a public endpoint.
Both are reachable by anyone on the internet; authentication is the only
control in front of them.

A regulated life-sciences customer's architecture and security teams rejected
TEAM on that basis. The objection stood even though the AWS console and the
IAM Identity Center access portal are themselves public: TEAM is an
*elevated-access* tool, and their policy is that internally built privileged
tooling has no inbound path from the internet.

Two obvious mitigations do not meet that bar:

- **Amplify Hosting cannot be made private.** There is no VPC-only or
  internal mode; it always fronts the app with a public CloudFront
  distribution.
- **WAF IP allowlisting still leaves a public URL.** The origin still resolves
  and answers on the internet; WAF only filters what reaches it. A reviewer
  asking "is there an internet-reachable origin?" still gets "yes".

This fork therefore changes how TEAM is hosted and reached, not how it works.
The approval workflow, data model and Identity Center integration are
unchanged.

## Decision

**TEAM is served only inside a VPC. Nothing TEAM runs has an inbound path from
the internet. Cognito's hosted domain is the one public surface, because AWS
offers no private path to it.**

### 1. SPA: nginx on ECS Fargate behind an internal ALB

The built SPA is served by an nginx container on ECS Fargate, behind an
internal Application Load Balancer, with an ACM certificate and a record in a
private hosted zone. No CloudFront. No WAF Web ACL.

This mirrors outcome-ops-ai-assist-private ADR-042:

> **The UI is served by an ALB inside the customer's VPC. No CloudFront.
> No WAF Web ACL.**

> The default enterprise posture is `ui_alb_internal = true` — the ALB
> has no public IP; it is only reachable from inside the customer's
> VPC (Direct Connect, Transit Gateway, VPN, or on-VPC compute). WAF
> protects the internet edge; an internal ALB has no internet edge to
> protect.

### 2. AppSync: `Visibility: PRIVATE`

The AppSync API is created with `Visibility: PRIVATE` and is reached through
the `appsync-api` interface VPC endpoint with private DNS enabled. This covers
both GraphQL queries/mutations **and** realtime subscriptions; the browser's
subscription websocket goes through the same endpoint.

### 3. The six Lambdas that call AppSync run in private subnets

These functions call the AppSync API (now private) and are attached to the
VPC's private subnets:

- `teamRouter`
- `teamStatus`
- `teamgetEntitlement`
- `teamGetPermissionSets`
- `teamPublishOUs`
- `teamgetLogs`

All other functions are unchanged and run outside the VPC as upstream does.

### 4. Build and deploy: CodeBuild, Amplify Hosting removed

CodeBuild runs `amplify push`, the frontend build, the container image push
and the UI service deploy. CodeBuild runs outside the VPC and calls only AWS
control-plane APIs, so it needs no network path to the private API or ALB.

Amplify Hosting is removed. The Amplify Gen1 CLI remains the backend
deployer, and `amplify init` still creates an Amplify App as the backend
environment registry. That app has no branch and serves nothing.

### 5. Cognito managed login stays public, and we say so

Cognito managed login, the OAuth2 endpoints and the SAML ACS endpoint remain
public. This is AWS's design, not a gap in this one. From the Amazon Cognito
documentation:

> "Requests to domain endpoints are also public … You can only make requests
> for domain services through public-internet paths."

The browser reaches the Cognito domain over its normal internet path, the
same way it reaches the IAM Identity Center portal. Nothing inside the VPC
needs to reach Cognito's hosted domain, and no TEAM origin or API becomes
public as a result.

This is the same honesty applied in outcome-ops-ai-assist-private ADR-045:

> AWS resolves `*.lambda-url.<region>.on.aws` on public DNS, but a public
> DNS answer is not a public API

Here the reverse holds and is stated plainly: Cognito's domain *is* a public
API, owned and operated by AWS, and it is the only public surface in the
request path.

### 6. Region = the IAM Identity Center region

TEAM's Lambdas call `sso-admin` and `identitystore` in their own region, so
TEAM must be deployed in the region where IAM Identity Center is enabled. The
reference deployment is **us-east-2**.

### 7. The network is the adopter's

TEAM does not create a VPC. The adopter provides:

- A VPC with private subnets in at least two Availability Zones.
- A path from those subnets to the AWS APIs TEAM calls: internet egress (a
  NAT gateway; Transit Gateway to a DMZ/egress VPC; or Transit Gateway to
  Direct Connect to a datacenter and out), **or** VPC endpoints for every one
  of them (below).
- The `appsync-api` interface VPC endpoint with private DNS enabled. This one
  endpoint is **mandatory**: a private AppSync API is reachable only through
  it.

**Running with no internet egress.** Everything inside the VPC can reach its
AWS APIs through endpoints instead of NAT:

| Caller | Service | Endpoint |
|---|---|---|
| Lambdas | IAM Identity Center (`sso-admin`) | `com.amazonaws.<region>.sso` |
| Lambdas | Identity Store | `com.amazonaws.<region>.identitystore` |
| Lambdas | Step Functions | `com.amazonaws.<region>.states` |
| Lambdas | Cognito user pools | `com.amazonaws.<region>.cognito-idp` |
| Lambdas | STS (audit-log role) | `com.amazonaws.<region>.sts` |
| Lambdas, Fargate | CloudWatch Logs | `com.amazonaws.<region>.logs` |
| Lambdas | CloudTrail (only with a CloudTrail Lake backend) | `com.amazonaws.<region>.cloudtrail` |
| Lambdas | DynamoDB | gateway endpoint |
| Fargate | ECR image pull | `ecr.api`, `ecr.dkr`, and the S3 gateway endpoint |
| Lambdas | **Organizations** | `com.amazonaws.us-east-1.organizations` only |

Organizations is the exception. It is a global service and its interface
endpoint exists only in us-east-1. From any other region, create it as a
cross-region interface endpoint (requires the `vpce:AllowMultiRegion`
permission on `ec2:CreateVpcEndpoint`; cross-region data transfer is billed),
or reach a us-east-1 endpoint over Transit Gateway or peering, which is the
route the Organizations documentation describes. CodeBuild runs outside the
VPC and is not affected. The endpoint-only configuration has not been tested
in the reference deployment.

The reference implementation uses one NAT gateway, the `appsync-api`
interface endpoint, and the free S3 and DynamoDB gateway endpoints. In the
reference deployment the VPC (10.42.0.0/16) is provisioned by Account Factory
for Terraform and published to SSM as `/network/vpc-id`,
`/network/vpc-cidr` and `/network/private-subnet-ids`, which the TEAM
deployment reads.

Egress is outbound only. "Private" in this ADR means **no inbound path from
the internet** to any TEAM origin or API; it does not mean the VPC has no
route out.

## Consequences

### Positive

- No internet-reachable TEAM origin or API. The SPA, the GraphQL API and its
  realtime subscriptions are reachable only from inside the VPC or networks
  routed to it.
- Security review gets a paper trail: one document that states what is
  private, what is public (Cognito's hosted domain) and why.
- Approval workflow, data model and Identity Center behaviour are unchanged,
  so upstream TEAM documentation still describes how the app is used.

### Tradeoffs

- **Cost.** A NAT gateway plus one interface endpoint, roughly $45/month in
  the lab, on top of the Fargate task and internal ALB. The endpoint-only
  option replaces the NAT gateway with about nine more interface endpoints,
  roughly $130/month across two Availability Zones: more expensive for a
  deployment this small, and chosen for policy (no internet route), not cost.
- **Permanent fork.** Upstream will not take this change; it removes Amplify
  Hosting, which is upstream's deployment model. This fork does not track
  upstream PRs and is maintained independently.
- **Lambda cold starts.** VPC-attached functions incur ENI overhead on cold
  start. It is small with Hyperplane ENIs, but nonzero, and applies to the six
  functions above.
- **Reachability.** Users need corporate network reachability to the VPC
  (Direct Connect, VPN, Transit Gateway, or a tunnel) to use TEAM at all.

## When to reconsider

- **Phase 2 ships.** If Cognito is replaced by a server-side SAML service
  provider in the UI container, there are zero public surfaces; supersede this
  ADR with one that records that.
- **AWS adds PrivateLink for Cognito managed login.** Then the remaining
  public surface can move inside the VPC and this ADR should be superseded.

## Related

- outcome-ops-ai-assist-private ADR-042: UI served by an internal ALB, no
  CloudFront, no WAF.
- outcome-ops-ai-assist-private ADR-045: a public DNS answer is not a public
  API.
- [Private access testing runbook](../private-access-testing.md)
- [README: This fork](../../README.md#this-fork)

## Version History

- 2026-11-16: Initial version. Accepted.
