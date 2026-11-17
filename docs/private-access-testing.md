---
layout: default
title: Private access testing
nav_exclude: true
---

# Private-access testing (SSH over SSM + SOCKS + PAC)

When TEAM is deployed privately, the UI sits behind an internal ALB with no
public IP, and the AppSync GraphQL API is private: its hostnames only resolve
and connect from inside the VPC. This runbook explains how to open that
deployment from a laptop for testing. It uses an SSM-managed tunnel host
inside the VPC. Only the private hostnames go through the tunnel. Cognito and
IAM Identity Center sign-in go direct from your own browser.

> **This is the lab path, not the user path.** Our default enterprise
> posture is an internal ALB: it "is only reachable from inside the
> customer's VPC (Direct Connect, Transit Gateway, VPN, or on-VPC compute)".
> This runbook is the *on-VPC compute* option, meant for a lab account with
> no DX or VPN. Real users would reach TEAM over the customer's Direct
> Connect, Transit Gateway or VPN, with the private hosted zone resolvable
> from their network. They would not use a tunnel host.

## How it works

```
browser ──PAC──► private names ──SOCKS5 127.0.0.1:1080──► ssh -D ──(inside SSM session)──► tunnel host ──► ALB / AppSync VPC endpoint
        └──────► everything else (Cognito, IdC portal, fonts) ──DIRECT──► internet
```

- **Tunnel host:** an EC2 instance tagged `Name=shared-network-tunnel` in a
  private subnet. It has no public IP and its security group allows **no
  ingress**. Egress is limited to 443. The SSM agent reaches Systems Manager
  through the NAT gateway.
- **SSH inside SSM:** `ssh` uses `aws ssm start-session --document-name
  AWS-StartSSHSession` as its `ProxyCommand`. Port 22 is never exposed: the
  SSH stream rides inside the SSM session.
- **SOCKS on top:** `DynamicForward 1080` (the same as `ssh -D 1080`) opens a
  SOCKS5 proxy on `127.0.0.1:1080`. With SOCKS5 *remote DNS*, the tunnel host
  resolves the hostnames itself, using the VPC resolver. That is the only way the
  private hosted zone records and the AppSync private-endpoint names
  resolve to the right addresses.
- **PAC file:** the browser sends only the private names to the proxy.

## Prerequisites

- AWS CLI v2 and the
  [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).
- An AWS profile for the account that holds the tunnel host, exported as
  `AWS_PROFILE`. It needs these permissions:
  - `ssm:StartSession` on the instance and on the `AWS-StartSSHSession` document
  - `ec2-instance-connect:SendSSHPublicKey` on the instance
  - `ec2:DescribeInstances` (to look up the instance id)
- An SSH key pair on the laptop (the examples use `~/.ssh/id_ed25519`).
- The UI hostname (`UI_DOMAIN` below) and the AppSync API id.

## 1. Find the tunnel instance

The instance id is not fixed, because the host can be replaced. Look it up by
its Name tag:

```bash
export AWS_PROFILE=<profile-for-the-tunnel-account>
TUNNEL_ID=$(aws ec2 describe-instances --region us-east-2 \
  --filters Name=tag:Name,Values=shared-network-tunnel Name=instance-state-name,Values=running \
  --query 'Reservations[].Instances[].InstanceId' --output text)
echo "$TUNNEL_ID"

# Optional: confirm the SSM agent is online
aws ssm describe-instance-information --region us-east-2 \
  --filters Key=InstanceIds,Values="$TUNNEL_ID" \
  --query 'InstanceInformationList[].PingStatus' --output text   # Online
```

## 2. Configure SSH

Append [`private-access/ssh_config.example`](private-access/ssh_config.example)
to `~/.ssh/config`. Then replace `HostName` with `$TUNNEL_ID`:

```
Host team-tunnel
  HostName i-REPLACE_WITH_TUNNEL_INSTANCE_ID
  User ec2-user
  ProxyCommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters portNumber=%p --region us-east-2"
  DynamicForward 1080
  ServerAliveInterval 30
```

## 3. Push a short-lived key and open the tunnel

No key pair is baked into the instance. Instead, EC2 Instance Connect pushes
your public key, and the key is accepted for **60 seconds**. Connect right
after pushing it. The `ec2-instance-connect` package that accepts the key is
preinstalled on Amazon Linux 2023.

```bash
aws ec2-instance-connect send-ssh-public-key --region us-east-2 \
  --instance-id "$TUNNEL_ID" \
  --instance-os-user ec2-user \
  --ssh-public-key file://~/.ssh/id_ed25519.pub

ssh -N team-tunnel     # leave running; Ctrl-C closes the tunnel
```

Once the session is established, it stays up after the 60-second window. You
only need to push the key again to reconnect.

## 4. Configure the browser with the PAC file

Copy [`private-access/team.pac.example`](private-access/team.pac.example) to
somewhere like `~/team.pac` and replace `REPLACE_UI_DOMAIN` with your UI
hostname:

```js
function FindProxyForURL(url, host) {
  // Private-only names: resolve AND connect inside the VPC (SOCKS5 with remote DNS).
  if (dnsDomainIs(host, "REPLACE_UI_DOMAIN") ||
      shExpMatch(host, "*.appsync-api.us-east-2.amazonaws.com") ||
      shExpMatch(host, "*.appsync-realtime-api.us-east-2.amazonaws.com")) {
    return "SOCKS5 127.0.0.1:1080";
  }
  // Everything else — Cognito managed login, IdC portal, fonts — goes direct.
  return "DIRECT";
}
```

**Why split the traffic?** The tunnel host *can* reach the internet through
the NAT gateway, so a single "proxy everything" setting would technically
work, but it has two costs:

- Your whole browsing session would leave through the lab's NAT IP.
- IAM Identity Center and Cognito sign-in would come from an AWS IP instead of
  your own. Any IP-based sign-in policy would then judge the wrong address,
  and the sign-in would no longer show what a real user's browser does.

The split keeps the test honest. The UI, the GraphQL API and its realtime
subscriptions go through the VPC, and only these names are private. The Cognito
redirect, the SAML POST to `*.amazoncognito.com` and the IdC portal go direct,
the way they would for a user on the corporate network.

Browser setup:

- **Firefox:** Settings → Network Settings → *Automatic proxy configuration
  URL* → `file:///home/<you>/team.pac`, and tick **Proxy DNS when using SOCKS
  v5**. A PAC `SOCKS5` result already implies remote DNS in Firefox, so the
  tick box is belt and braces. A dedicated Firefox profile keeps this
  separate from everyday browsing.
- **Chrome / Chromium:** current Chrome ignores `file://` PAC URLs (the page
  fails with `DNS_PROBE_FINISHED_NXDOMAIN` because the name was resolved
  locally). Pass the PAC script inline as a data URL instead:
  `--proxy-pac-url="data:application/x-ns-proxy-autoconfig;base64,$(base64 -w0 ~/team.pac)"`.
  A separate `--user-data-dir` is recommended, so the flag is not overridden
  by an existing browser process. Chrome always resolves DNS remotely for
  SOCKS5 proxies.

Do not shortcut the PAC file with `--proxy-server=socks5://...`. That sends
Cognito managed login and the IdC portal through the tunnel too, which only
works while the tunnel host has internet egress; without it, sign-in times
out.

> AppSync private DNS only works when the hostname is resolved **inside** the
> VPC. If the laptop resolves it, the request goes to the public AppSync
> endpoint, which rejects it. Remote DNS is the reason SOCKS5 is used here.

## 5. Smoke tests

With `ssh -N team-tunnel` running:

```bash
UI_DOMAIN=<ui hostname>
API_ID=<appsync api id>

# UI through the tunnel
curl --socks5-hostname 127.0.0.1:1080 -sf https://$UI_DOMAIN/healthz            # ok

# Private AppSync API through the tunnel: 401 = reached the private API (no auth token sent)
curl --socks5-hostname 127.0.0.1:1080 -s -o /dev/null -w '%{http_code}\n' \
  -X POST https://$API_ID.appsync-api.us-east-2.amazonaws.com/graphql

# Same API from the laptop WITHOUT the tunnel: expect 403/ForbiddenException,
# which proves the API is not publicly usable
curl -s -o /dev/null -w '%{http_code}\n' -m 10 -X POST https://$API_ID.appsync-api.us-east-2.amazonaws.com/graphql

# The UI name lives in a private hosted zone only: empty from the laptop
dig +short $UI_DOMAIN
```

Use `--socks5-hostname`, not `--socks5`. The `-hostname` variant is curl's remote-DNS
mode.

Then open `https://$UI_DOMAIN` in the PAC-configured browser and sign in.
Sign-in goes direct to IdC/Cognito, and you should land back on the private UI.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `Permission denied (publickey)` | The pushed key expired (60 s) before `ssh` connected. Push it again and connect immediately. |
| `SessionManagerPlugin is not found` | Install the Session Manager plugin. |
| `TargetNotConnected` | The SSM agent is offline, or the instance id is stale. Look it up again by Name tag. |
| UI loads, but data calls fail or hang | The AppSync names are not matched by the PAC, or DNS is being resolved locally. Check the PAC region and the remote-DNS setting. |
| Sign-in loops or fails | Cognito/IdC traffic is being proxied. Make sure the PAC returns `DIRECT` for `*.amazoncognito.com` and the IdC portal. |

## Plan B: SSM port forwarding to the ALB

If SSH is not an option, Systems Manager can forward a local port straight to the
internal ALB:

```bash
aws ssm start-session --region us-east-2 --target "$TUNNEL_ID" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters host=<internal-alb-dns-name>,portNumber=443,localPortNumber=8443
```

Then add a hosts-file entry `127.0.0.1 <UI_DOMAIN>` and browse to
`https://<UI_DOMAIN>:8443`. This plan has limits:

- It does **not** cover the AppSync private DNS names. The UI shell loads,
  but GraphQL calls and realtime subscriptions cannot reach the private API.
- The non-standard port does not match the registered Cognito callback URL.

That is why plan A, SOCKS with remote DNS, is the default.
