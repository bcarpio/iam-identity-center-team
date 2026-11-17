"""Generate diagrams/architecture.svg: the private TEAM architecture.

Run: python3 diagrams/generate_architecture.py
No network access, no dependencies beyond the standard library.

Layout rules: 900 units wide so labels stay legible when the image is scaled
to a README or blog content width, flows routed in channels beside
components (never through them), and a white background so the image reads
the same on light and dark pages.
"""

from pathlib import Path

OUT = Path(__file__).resolve().parent / "architecture.svg"
W, H = 900, 960

STYLE = """
  text { font-family: Inter, system-ui, -apple-system, 'Segoe UI', Helvetica, Arial, sans-serif; fill: #0f172a; }
  .bg { fill: #ffffff; }
  .public { fill: #fff7ed; stroke: #c2410c; stroke-width: 2; stroke-dasharray: 10 6; }
  .public-label { font-size: 19px; font-weight: 700; fill: #9a3412; }
  .account { fill: #f8fafc; stroke: #64748b; stroke-width: 2; }
  .account-label { font-size: 20px; font-weight: 700; fill: #334155; }
  .vpc { fill: #ffffff; stroke: #16a34a; stroke-width: 2.5; }
  .vpc-label { font-size: 19px; font-weight: 700; fill: #15803d; }
  .comp { fill: #ffffff; stroke: #334155; stroke-width: 2; }
  .comp-dim { fill: #ffffff; stroke: #94a3b8; stroke-width: 1.5; }
  .comp-text { font-size: 18px; font-weight: 600; }
  .comp-sub { font-size: 16px; fill: #475569; }
  .net { fill: #f1f5f9; stroke: #334155; stroke-width: 2; }
  .flow-label { font-size: 16px; fill: #334155; paint-order: stroke; stroke: #ffffff; stroke-width: 6px; stroke-linejoin: round; }
  .private { fill: none; stroke: #0369a1; stroke-width: 4; }
  .login { fill: none; stroke: #c2410c; stroke-width: 4; stroke-dasharray: 12 6; }
  .egress { fill: none; stroke: #64748b; stroke-width: 3; stroke-dasharray: 4 5; }
  .audit { fill: none; stroke: #7c3aed; stroke-width: 3; stroke-dasharray: 10 5; }
  .legend-text { font-size: 16px; fill: #334155; }
"""

MARKERS = "".join(
    f'\n  <marker id="arrow-{name}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="5" '
    f'markerHeight="5" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="{color}"/></marker>'
    for name, color in (("private", "#0369a1"), ("login", "#c2410c"), ("egress", "#64748b"), ("audit", "#7c3aed"))
) + "\n"


class Svg:
    def __init__(self):
        self.parts = []

    def add(self, s):
        self.parts.append(s)

    def rect(self, x, y, w, h, cls, rx=6):
        self.add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" class="{cls}"/>')

    def text(self, x, y, s, cls, anchor="start"):
        self.add(f'<text x="{x}" y="{y}" class="{cls}" text-anchor="{anchor}">{s}</text>')

    def comp(self, x, y, w, h, label, sub=None, cls="comp"):
        self.rect(x, y, w, h, cls)
        cx = x + w / 2
        if sub:
            self.text(cx, y + h / 2 - 4, label, "comp-text", "middle")
            self.text(cx, y + h / 2 + 17, sub, "comp-sub", "middle")
        else:
            self.text(cx, y + h / 2 + 6, label, "comp-text", "middle")

    def line(self, pts, cls, end=True, start=False):
        d = "M" + " L".join(f"{px},{py}" for px, py in pts)
        m = (f' marker-end="url(#arrow-{cls})"' if end else "") + (f' marker-start="url(#arrow-{cls})"' if start else "")
        self.add(f'<path d="{d}" class="{cls}"{m}/>')

    def legend(self, y, items):
        x = 40
        for cls, label in items:
            self.line([(x, y), (x + 46, y)], cls, end=False)
            self.text(x + 56, y + 6, label, "legend-text")
            x += 56 + len(label) * 8.4 + 34

    def write(self, title, desc):
        body = "\n  ".join(self.parts)
        OUT.write_text(
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
            f'role="img" aria-labelledby="t d">\n'
            f'  <title id="t">{title}</title>\n'
            f'  <desc id="d">{desc}</desc>\n'
            f"  <defs>\n  <style>{STYLE}  </style>{MARKERS}  </defs>\n"
            f'  <rect x="0" y="0" width="{W}" height="{H}" class="bg"/>\n'
            f"  {body}\n</svg>\n"
        )
        print(f"wrote {OUT}")


s = Svg()

# Row 1: the user, and the only public surface (AWS managed sign-in).
s.comp(30, 40, 230, 72, "Browser", "on the corporate network", cls="net")
s.rect(330, 20, 556, 150, "public")
s.text(350, 48, "Public, AWS managed", "public-label")
s.comp(345, 66, 252, 72, "Cognito managed login", "the only public surface")
s.comp(660, 66, 210, 72, "IAM Identity Center", "SAML IdP, portal")

# Row 2: the TEAM account.
s.rect(30, 220, 840, 500, "account")
s.text(850, 250, "TEAM account (Identity Center delegated admin)", "account-label", "end")
s.rect(50, 268, 490, 432, "vpc")
s.text(70, 686, "VPC: private subnets, 2 AZs", "vpc-label")

s.comp(68, 320, 220, 72, "Internal ALB", "HTTPS, no public IP")
s.comp(68, 440, 220, 72, "ECS Fargate", "nginx serves the SPA")
s.comp(68, 560, 220, 72, "Private hosted zone", "team.example.com")
s.comp(310, 320, 210, 72, "appsync-api", "interface endpoint")
s.comp(310, 440, 210, 72, "Six Lambdas", "call the private API")
s.comp(310, 560, 210, 72, "NAT gateway", "outbound only")

s.comp(580, 320, 270, 72, "AppSync API", "Visibility: PRIVATE")
s.comp(580, 440, 270, 72, "TEAM backend", "DynamoDB, Step Functions")
s.comp(580, 560, 270, 72, "CodeBuild", "builds and deploys TEAM", cls="comp-dim")

# Row 3: what the NAT reaches, and the management account.
s.comp(310, 790, 210, 72, "AWS APIs", "Cognito, IdC, Orgs", cls="net")
s.rect(560, 760, 310, 130, "account")
s.text(580, 790, "Management account", "account-label")
s.comp(580, 806, 270, 70, "Org trail log group", "CloudWatch Logs Insights")

# Flows. Sign-in: browser to Cognito, Cognito federates to Identity Center.
s.line([(260, 90), (345, 90)], "login")
s.line([(597, 102), (660, 102)], "login", start=True)
s.text(628, 92, "SAML", "flow-label", "middle")

# Private path: the browser reaches the ALB and the AppSync endpoint only
# over the corporate network into the VPC.
s.line([(145, 112), (145, 320)], "private")
s.text(244, 196, "Direct Connect, VPN or TGW", "flow-label")
s.line([(230, 112), (230, 290), (415, 290), (415, 320)], "private")
s.line([(178, 392), (178, 440)], "private")
s.line([(520, 356), (580, 356)], "private")
s.line([(415, 440), (415, 392)], "private")
s.line([(715, 392), (715, 440)], "private")

# Egress: NAT out to AWS APIs; the audit query assumes a role in management.
s.line([(415, 632), (415, 790)], "egress")
s.line([(520, 610), (548, 610), (548, 841), (580, 841)], "audit")
s.text(538, 748, "assume role,", "flow-label", "end")
s.text(538, 768, "query logs", "flow-label", "end")

s.legend(930, [
    ("private", "Private network path"),
    ("login", "Public sign-in"),
    ("egress", "Outbound only"),
    ("audit", "Audit log query"),
])

s.write(
    "Private TEAM architecture",
    "The browser reaches TEAM only over the corporate network (Direct Connect, VPN or Transit Gateway): "
    "an internal ALB with no public IP in front of nginx on ECS Fargate serving the SPA, and the appsync-api "
    "interface endpoint in front of an AppSync API with Visibility PRIVATE. The six Lambdas that call AppSync "
    "run in the VPC's private subnets and use a NAT gateway for outbound calls to AWS APIs such as Cognito, "
    "Identity Center and Organizations. Session audit logs come from the Control Tower organization trail's CloudWatch "
    "log group in the management account, queried with Logs Insights through an assumed role. The only public "
    "surface is Cognito managed login, which federates to IAM Identity Center over SAML.",
)
