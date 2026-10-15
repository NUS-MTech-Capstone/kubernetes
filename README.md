# Kubernetes

EKS manifests and deployment tooling for the DenDenMushi SSH access platform.

The AWS deployment runs these services:

- Session Manager
- Audit Service
- STS
- Proxy Control Plane
- Proxy Dataplane
- Agent Control Plane
- Incident Agent
- Incident Reasoning Agent
- Agent Tool Gateway
- Redis monitoring cache
- Nest Backend
- Angular

DDM Agent remains reserved and is not deployed in the SSH-only path.

Workloads are isolated into `dendenmushi-ssh`, `dendenmushi-agentic`, and
`dendenmushi-webapp`.

Project-wide documentation and submission evidence live in the workspace-level
`capstone/documentation/` directory beside the repositories. That directory is
untracked by Git and is supplied separately with the capstone submission. It
contains `KUBERNETES_ARCHITECTURE_AND_OPERATIONS.md`, `AGENTIC_AI_FEATURES.md`,
the API load-testing guide and the release evidence index. This repository
retains its operational instructions below, manifests and deployment tooling.

## AWS Prerequisites

Apply the main infrastructure and target host first:

```bash
cd ../aws-terraform
aws sts get-caller-identity
terraform init -reconfigure
terraform plan -var-file=secrets.tfvars -var-file=teammate-access.local.tfvars
terraform apply -var-file=secrets.tfvars -var-file=teammate-access.local.tfvars

cd ../target-hosts-setup
./scripts/bootstrap.sh -auto-approve
```

The first infrastructure apply creates:

- EKS and the AWS Load Balancer Controller
- ECR repositories
- GitHub Actions ECR push role
- Proxy Dataplane IRSA role
- Nest Backend IRSA role
- STS, Proxy Control Plane, Session Manager, Audit Service, and Agent Control
  Plane event-lane IRSA permissions
- Dedicated Incident Reasoning Agent IRSA permissions for Bedrock and the
  optional tracing secret
- SNS topic, Audit Service SQS queue, and audit event DLQ for sanitized
  lifecycle metadata
- Cognito user pool/client
- Dedicated web application database credentials
- Regional ACM certificate for `api.ddm.keiyam.me`

If a GitHub OIDC provider already exists in the AWS account, set its ARN instead
of creating another provider:

```bash
terraform apply \
  -var-file=secrets.tfvars \
  -var-file=teammate-access.local.tfvars \
  -var='github_oidc_provider_arn=arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com'
```

## Build and Push Images

Get the role created for GitHub Actions:

```bash
cd ../aws-terraform
terraform output -raw github_ecr_push_role_arn
```

Set that value as the `AWS_ROLE_ARN` Actions secret in these repositories:

```text
NUS-MTech-Capstone/sts
NUS-MTech-Capstone/proxy-controlplane
NUS-MTech-Capstone/session-manager
NUS-MTech-Capstone/audit-service
NUS-MTech-Capstone/proxy-dataplane
NUS-MTech-Capstone/agent-controlplane
NUS-MTech-Capstone/incident-agent
NUS-MTech-Capstone/nest-backend
NUS-MTech-Capstone/angular
```

With GitHub CLI:

```bash
ROLE_ARN=$(terraform output -raw github_ecr_push_role_arn)
for repo in sts proxy-controlplane session-manager audit-service proxy-dataplane agent-controlplane incident-agent nest-backend angular; do
  gh secret set AWS_ROLE_ARN --repo "NUS-MTech-Capstone/${repo}" --body "${ROLE_ARN}"
done
```

Push each service’s `main` branch or run its `Image` workflow manually. Each
workflow publishes the commit SHA tag and the `main` tag. Verify:

```bash
aws ecr describe-images \
  --region ap-southeast-1 \
  --repository-name dendenmushi/proxy-dataplane \
  --query 'imageDetails[].imageTags'
```

## GitOps Deploy

Argo CD owns normal workload reconciliation from this repository. Service
repositories publish commit-tagged images, then open promotion PRs that
write the successful build digest to `apps/dendenmushi/overlays/dev/kustomization.yaml`.
Tags provide traceability; `image@sha256:...` provides deployment immutability. Merging a promotion
PR to `main` is the deployment approval because the Argo CD Application tracks
this repository and branch.

The bootstrap script performs the cluster-side and environment-discovery work
that should not happen inside every Argo sync:

1. Configures `kubectl`.
2. Creates or preserves the STS JWT signing secret.
3. Bootstraps the `ddm_webapp` database and least-privilege login.
4. Reads the target details from Terraform outputs.
5. Runs `ssh-keyscan` from an EKS pod.
6. Builds trusted STS inventory in the dev overlay.
7. Refreshes non-secret AWS, Cognito, IRSA, SNS, SQS, AgentCore gateway, and
   Incident Agent LangSmith identifiers in the dev overlay. The OpenAI key is
   never copied into Kubernetes.
8. Applies the Argo CD Application manifest.

```bash
cd ../kubernetes
./scripts/bootstrap-aws.sh
```

Bootstrap also reconciles the web-facing record for the Terraform-managed
`host-dev-1` target and the `DenDenMushi Demo Operators` group. The job keeps
the existing virtual-machine UUID, refreshes the address and SSH port from
Terraform, and ensures the group includes the target and `ec2-user`. Run the
same repair independently with:

```bash
AWS_PROFILE=capstone EXPECTED_AWS_ACCOUNT_ID=891377133321 \
./scripts/reconcile-webapp-target.sh
```

STS deliberately does not use Nest Backend's server-inventory endpoint. Its
trusted SSH address, credential secret, host key, and bounded automation
catalog come only from the GitOps-generated `SERVER_INVENTORY_STATIC_JSON`.
Nest Backend owns the Change Request and display inventory records, which the
reconciliation job keeps aligned with that authoritative target.

Review and commit the generated changes to these files when bootstrap discovers
new environment values:

```text
apps/dendenmushi/overlays/dev/env.properties
apps/dendenmushi/overlays/dev/server-inventory.static.json
```

To explicitly supply the JWT signing key:

```bash
JWT_SIGNING_KEY=$(openssl rand -base64 48) \
./scripts/bootstrap-aws.sh
```

After Argo CD syncs, verify the deployed workloads:

```bash
./scripts/verify-aws.sh
```

After verification prints the ALB DNS name, perform the second Terraform apply:

```bash
cd ../aws-terraform
terraform apply \
  -var-file=secrets.tfvars \
  -var-file=teammate-access.local.tfvars \
  -var='application_alb_dns_name=<ALB DNS name>'
```

This creates the Route 53 ALB alias for `api.ddm.keiyam.me`.

`scripts/deploy-aws.sh` remains as a compatibility wrapper that runs bootstrap
and verification, but it no longer applies workload manifests directly.

## Promotion Workflow

The active EKS services promote images through shared GitHub Actions:

```text
sts
session-manager
audit-service
agent-controlplane
proxy-controlplane
proxy-dataplane
incident-agent
nest-backend
angular
```

Set `GITOPS_TOKEN` in each of those repositories to a fine-scoped GitHub App
token or equivalent credential that can push a branch and open a PR in
`NUS-MTech-Capstone/kubernetes`. The promotion workflow updates exactly one
image tag, renders the dev overlay, and opens or updates a PR. Argo CD deploys
only after that PR is merged.

The incident-agent image also drives the `incident-agent-migrate` PreSync hook.
The same immutable image runs the coordinator, private A2A Reasoning Agent, and
private MCP Tool Gateway with different `INCIDENT_AGENT_COMPONENT` values.
Argo CD uses the `DATABASE_URL` from the pre-bootstrapped
`dendenmushi-database` Kubernetes Secret before rolling out the worker. Images
that include `incident_agent.migrate` run Alembic. Older restorable images that
predate that entrypoint run a read-only compatibility check against their own
SQLAlchemy metadata instead. The hook does not depend on the application
service account existing before the normal sync phase. A migration or schema
compatibility failure, including detection of duplicate active incident group
keys by the current migration, blocks the sync instead of starting code against
an incompatible schema.

## Ingress

Static content, APIs, and WebSockets use one HTTPS ALB:

```text
https://api.ddm.keiyam.me/                    -> Angular
https://api.ddm.keiyam.me/ddm/auth/login      -> Nest Backend with ALB login
https://api.ddm.keiyam.me/ddm/*               -> Nest Backend
https://api.ddm.keiyam.me/sessions/*          -> Proxy Control Plane
wss://api.ddm.keiyam.me/sessions/*/ws         -> Proxy Dataplane
https://api.ddm.keiyam.me/agentic-ai/health   -> Agent Control Plane
https://api.ddm.keiyam.me/alerts*             -> Agent Control Plane
https://api.ddm.keiyam.me/incidents*          -> Agent Control Plane
```

The WebSocket rule has higher ALB group priority. Sharing a hostname lets the
browser send the Cognito ALB session cookie during the WebSocket upgrade.

The shared HTTPS listener adds HSTS, MIME-sniffing protection, and framing
protection to every public response, including Cognito denials generated by
the ALB, and suppresses the ALB server banner. The load balancer drops invalid
HTTP header fields. Angular retains ownership of its application-specific CSP,
permissions policy, and referrer policy. Public APIs remain same-origin and do
not enable CORS. Proxy Dataplane additionally validates browser WebSocket
origins against `WEBSOCKET_ALLOWED_ORIGINS` before authentication or session
lookup.

`scripts/verify-aws.sh` checks both the Angular document headers and the
listener headers on a Cognito-denied route. If the deployed AWS Load Balancer
Controller does not support listener attributes, do not upgrade it implicitly;
retain the application-level headers and schedule a reviewed controller
upgrade before relying on ALB-generated response coverage.

`scripts/verify-csp.sh` checks the Angular document CSP independently: its
per-response nonce must match the HTML `ngCspNonce`, change between requests,
and accompany `Cache-Control: no-store`. Connections must use the explicit
production WebSocket origin, without broad scheme or inline-style allowances.
The Angular CSP remains application-owned. ALB listener CSP insertion would
overwrite its dynamic nonce policy on all responses, so it is not enabled.

## Post-Deployment DAST

The `ZAP DAST` GitHub Actions workflow performs a safe, unauthenticated passive
scan of the deployed public ingress after every merge to `main`. A manual
`workflow_dispatch` trigger is also available for reruns. Push-triggered scans
wait three minutes for the normal Argo CD reconciliation window, then require
the public `/healthz` and `/readyz` endpoints to respond before starting ZAP.

The scan uses the ZAP client spider for the Angular application and seeds only
`GET` requests for the externally reachable Nest Backend, Proxy Control Plane,
Proxy Dataplane WebSocket route, and Agent Control Plane boundaries. It does
not perform an active scan, submit forms, create test data, or use AWS or
Cognito credentials. Findings are evidence for manual review and do not fail
the workflow; target unavailability, a ZAP execution error, or a missing report
does fail it.

Each workflow run uploads `zap-report.html` in the
`zap-dast-html-<run-id>` artifact for 30 days. Review high and medium findings,
record false-positive reasoning, and rerun the workflow after remediating a
confirmed issue.

CI pins ZAP 2.17.0 to match the retained 7 October 2026 baseline. The CSP header
finding on ALB-generated 401 denials is reviewed separately from the application
findings: the fixed HTML error page contains no scripts, forms or reflected
request data, and retains HSTS, `X-Frame-Options: DENY` and `nosniff`. Its missing
CSP remains visible in the unfiltered scan report. Authentication is not relaxed
and protected routes are not removed from scan scope to change this result.

To run the same scan locally, start Docker and run:

```bash
./scripts/run-zap-dast.sh
```

The default report is `dast-results/zap-report.html`. The origin, image, and
output directory can be overridden without changing the checked-in plan:

```bash
TARGET_URL=https://api.ddm.keiyam.me \
ZAP_IMAGE=ghcr.io/zaproxy/zaproxy:stable \
REPORT_DIR=/tmp/dendenmushi-zap \
./scripts/run-zap-dast.sh
```

This public scan validates Angular content and the external ALB/Cognito denial
boundary for protected routes. It does not exercise authenticated behavior
behind Cognito. STS, Session Manager, Audit Service, and Incident Agent remain
internal-only and are intentionally not exposed or scanned through the public
ingress. An authenticated or active DAST stage would require a dedicated test
identity, isolated test data, and additional safety controls.

The three-minute delay is pragmatic rather than an exact deployment
attestation: the report describes the revision live at scan time. If Argo CD
takes longer to reconcile, verify the rollout and use the manual trigger to
produce a report for the final revision.

## Observability Defaults

The AWS deployment is tuned for a low-cost school project:

- Application containers emit JSON logs to stdout.
- `LOG_FORMAT=json` is set for services that support it.
- `CLOUDWATCH_NAMESPACE=DenDenMushi` is set for services that emit EMF metrics.
- HTTP services propagate `X-Request-ID` across synchronous calls. Browser
  WebSocket clients cannot set custom headers, so the Angular terminal app also
  appends a correlation-only `requestId` query parameter to dataplane WebSocket
  URLs. Authorization still comes only from ALB identity and STS tokens.
- `OTEL_TRACES_EXPORTER=none`, `OTEL_METRICS_EXPORTER=none`, and
  `OTEL_LOGS_EXPORTER=none` are the default ConfigMap values.
- The CloudWatch add-on excludes the metadata-only Agent Tool Gateway from
  Application Signals auto-instrumentation. Container Insights and structured
  logs still cover it without injecting four unused language runtimes. Its
  Python MCP runtime is capped at `256Mi` after live discovery probes showed
  that `128Mi` could be OOM-killed during request handling.
- The dev overlay sets `LANGSMITH_TRACING=true` only for Incident Reasoning Agent and passes
  only the Terraform-created Secrets Manager secret ID plus optional project,
  endpoint, and workspace settings. The LangSmith API key itself is not written
  to Kubernetes YAML or ConfigMaps.
- Custom EMF metrics include `AuthFailures`, `STSRequestLatencyMs`,
  `STSErrors`, `SessionStartFailures`, `AssignmentFailures`, `StaleProxyPods`,
  `HeartbeatMisses`, `WebSocketDisconnects`, `SSHFailures`, `ActiveSessions`,
  `ProxyPodCapacity`, `AvailableProxyPods`, `IncidentReceived`,
  `IncidentTriaged`, `EvidenceCollected`, `PlanProposed`, `PlanApproved`,
  `PlanRejected`, `RemediationExecuted`, `RemediationFailed`,
  `AgentDelegated`, `ToolCallAllowed`, `ToolCallDenied`, `ToolCallCompleted`,
  `ToolCallFailed`, `BedrockRequestLatencyMs`, `BedrockErrors`, `SessionAuditAppendFailures`,
  `SessionAuditDropped`, `SessionAuditTruncated`, `DDMOperationLatencyMs`,
  `DDMOperationErrors`, and `SQSMessageFailures`. Use low-cardinality
  dimensions only: `Service`, `Environment`, and optional component/reason
  fields in the log payload.
- Nest Backend monitoring reads from
  `/aws/containerinsights/dendenmushi-cluster-dev/application`, which Terraform
  pre-creates with one-day retention.
- Successful Nest Backend CloudWatch alarm and metric reads are cached for 60
  seconds by one internal Redis pod in `dendenmushi-webapp`. Redis is capped at
  64 MiB with all-keys LRU eviction, has no persistent volume or ingress, and
  accepts traffic only from Nest Backend through NetworkPolicy. Redis failures
  fall back to CloudWatch and do not affect Nest readiness.
- Logs should contain only metadata such as `requestId`, `sessionId`, `userId`,
  `hostId`, `crId`, `podId`, `instanceId`, `incidentId`, `runId`, `action`,
  `mode`, `operation`, `planHash`, `status`, and `durationMs`. Do not log STS
  tokens, private keys, passwords, model prompts containing sensitive data,
  command bodies, or terminal streams.

STS, Proxy Control Plane, Session Manager, and Agent Control Plane publish
non-blocking sanitized lifecycle events when `EVENT_PUBLISHER_ENABLED=true` and
`EVENTS_TOPIC_ARN` is present. Audit Service consumes the subscribed SQS queue
when `AUDIT_EVENT_CONSUMER_ENABLED=true` and `AUDIT_EVENTS_QUEUE_URL` is
present. These settings are enabled in the AWS dev overlay and remain inert for
local runs unless explicitly configured.

Verification after Terraform and Argo CD sync:

```bash
aws logs describe-log-groups \
  --region ap-southeast-1 \
  --log-group-name-prefix /aws/containerinsights/dendenmushi-cluster-dev \
  --query 'logGroups[].{name:logGroupName,retention:retentionInDays}'

kubectl exec -n dendenmushi-ssh deploy/sts -- printenv OTEL_TRACES_EXPORTER
kubectl logs deployment/proxy-controlplane -n dendenmushi-ssh | head
```

## Checks

```bash
kubectl get application dendenmushi-dev -n argocd
kubectl get pods,ingress -n dendenmushi-ssh
kubectl get pods,ingress -n dendenmushi-agentic
kubectl get pods,ingress -n dendenmushi-webapp
kubectl describe serviceaccount proxy-dataplane -n dendenmushi-ssh
kubectl logs deployment/proxy-dataplane -n dendenmushi-ssh
./scripts/verify-network-policies.sh
curl -fsS https://api.ddm.keiyam.me/healthz
```

The root and Angular health endpoint are public. Data and control routes require
the ALB Cognito session.

The two agent protocol services are internal only. The Reasoning Agent exposes
A2A discovery and JSON-RPC on port 8093. The Tool Gateway exposes MCP
Streamable HTTP on port 8094 with a GitOps-managed default-deny policy. Neither
has an Ingress, ALB route, public DNS record, or separate managed AWS service.
`verify-aws.sh` requires all twelve deployments, A2A discovery, caller-filtered
MCP discovery, a representative MCP denial, and the NetworkPolicy matrix.
Protocol checks run in a short-lived pod with the coordinator image, service
account, projected token, and network identity so verification cannot exhaust
the live coordinator's bounded memory cgroup.
The matrix also reaches Proxy Dataplane through the Tool Gateway's allowed
network path and requires an invalid WebSocket origin to receive `403` before
authentication.
The probe pods wait briefly before opening connections because VPC CNI
`standard` enforcement permits a newly created pod until its policy rules have
been programmed. This tests the steady enforced state instead of that startup
interval.

## Digest and identity rollout verification

Before the strict dataplane image is promoted, deploy `ALB_ARN`,
`COGNITO_USER_POOL_ID`, and `COGNITO_CLIENT_ID` using the existing overlay
replacements. `AWS_REGION` is already configured. Check active sessions and
allow them to finish before either configuration or image changes trigger its
`Recreate` rollout. The verified ALB identity must match the STS capability.

Promotion callers require the build digest and update only their Kustomize
image entry. Bootstrap refreshes environment/inventory files and leaves image
references untouched. No ECR mutability change or Terraform apply is required.

```bash
ruby test/image_digests_test.rb
ruby scripts/verify-image-digests.rb
AWS_PROFILE=capstone ruby scripts/verify-image-digests.rb --live
```

The verifier checks Deployment and migration Job images. Live verification
matches rendered GitOps images, ready pod declarations and runtime image IDs.
When a runtime reports an architecture-specific digest, it verifies membership
in the exact ECR image index pinned by GitOps. Sanitized JSON output records both
identities without credentials or application logs. During the initial migration
only, `--allow-tags` permits offline rendering checks of the old release.

Rollback uses a reviewed GitOps PR restoring a previously verified digest,
followed by Argo health and SSH checks. Restore the final digest through another
PR and repeat verification. Record both GitOps commits and runtime identities
in the release evidence index; do not rely on retagging an ECR image.

All nine project image callers now require the successful build digest. Manifest
CI rejects tag-only Deployment and migration Job images. `verify-aws.sh` also
compares the rendered declarations with ready pods and verifies ECR index/child
relationships before accepting a release. The `--allow-tags` verifier option
exists only for historical migration evidence and is not used by normal CI.
