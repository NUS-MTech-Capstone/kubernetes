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
- Nest Backend
- Angular

DDM Agent remains reserved and is not deployed in the SSH-only path.

## AWS Prerequisites

Apply the main infrastructure and target host first:

```bash
cd ../aws-terraform
aws sts get-caller-identity
terraform init -reconfigure
terraform apply -var-file=secrets.tfvars

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
workflow publishes both the immutable commit SHA and the `main` tag. Verify:

```bash
aws ecr describe-images \
  --region ap-southeast-1 \
  --repository-name dendenmushi/proxy-dataplane \
  --query 'imageDetails[].imageTags'
```

## GitOps Deploy

Argo CD owns normal workload reconciliation from this repository. Service
repositories publish immutable ECR image tags, then open promotion PRs that
update `apps/dendenmushi/overlays/dev/kustomization.yaml`. Merging a promotion
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
7. Refreshes non-secret AWS, Cognito, IRSA, SNS, SQS, and Incident Agent
   LangSmith identifiers in the dev overlay.
8. Applies the Argo CD Application manifest.

```bash
cd ../kubernetes
./scripts/bootstrap-aws.sh
```

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
- The dev overlay sets `LANGSMITH_TRACING=true` for Incident Agent and passes
  only the Terraform-created Secrets Manager secret ID plus optional project,
  endpoint, and workspace settings. The LangSmith API key itself is not written
  to Kubernetes YAML or ConfigMaps.
- Custom EMF metrics include `AuthFailures`, `STSRequestLatencyMs`,
  `STSErrors`, `SessionStartFailures`, `AssignmentFailures`, `StaleProxyPods`,
  `HeartbeatMisses`, `WebSocketDisconnects`, `SSHFailures`, `ActiveSessions`,
  `ProxyPodCapacity`, `AvailableProxyPods`, `IncidentReceived`,
  `IncidentTriaged`, `EvidenceCollected`, `PlanProposed`, `PlanApproved`,
  `PlanRejected`, `RemediationExecuted`, `RemediationFailed`,
  `BedrockRequestLatencyMs`, `BedrockErrors`, `SessionAuditAppendFailures`,
  `SessionAuditDropped`, `SessionAuditTruncated`, `DDMOperationLatencyMs`,
  `DDMOperationErrors`, and `SQSMessageFailures`. Use low-cardinality
  dimensions only: `Service`, `Environment`, and optional component/reason
  fields in the log payload.
- Nest Backend monitoring reads from
  `/aws/containerinsights/dendenmushi-cluster-dev/application`, which Terraform
  pre-creates with one-day retention.
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

kubectl exec -n dendenmushi deploy/sts -- printenv OTEL_TRACES_EXPORTER
kubectl logs deployment/proxy-controlplane -n dendenmushi | head
```

## Checks

```bash
kubectl get application dendenmushi-dev -n argocd
kubectl get pods,ingress -n dendenmushi
kubectl describe serviceaccount proxy-dataplane -n dendenmushi
kubectl logs deployment/proxy-dataplane -n dendenmushi
curl -fsS https://api.ddm.keiyam.me/healthz
```

The root and Angular health endpoint are public. Data and control routes require
the ALB Cognito session.
