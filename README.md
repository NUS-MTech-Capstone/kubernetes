# Kubernetes

EKS manifests and deployment tooling for the DenDenMushi SSH access platform.

The AWS deployment runs these services:

- Session Manager
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
NUS-MTech-Capstone/proxy-dataplane
NUS-MTech-Capstone/agent-controlplane
NUS-MTech-Capstone/incident-agent
NUS-MTech-Capstone/nest-backend
NUS-MTech-Capstone/angular
```

With GitHub CLI:

```bash
ROLE_ARN=$(terraform output -raw github_ecr_push_role_arn)
for repo in sts proxy-controlplane session-manager proxy-dataplane agent-controlplane incident-agent nest-backend angular; do
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
7. Refreshes non-secret AWS and Cognito identifiers in the dev overlay.
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
- Custom EMF metrics include `AuthFailures`, `STSRequestLatencyMs`,
  `STSErrors`, `SessionStartFailures`, `AssignmentFailures`, `StaleProxyPods`,
  `HeartbeatMisses`, `WebSocketDisconnects`, `SSHFailures`, `ActiveSessions`,
  `ProxyPodCapacity`, `AvailableProxyPods`, `IncidentReceived`,
  `IncidentTriaged`, `EvidenceCollected`, `PlanProposed`, `PlanApproved`,
  `PlanRejected`, `RemediationExecuted`, `RemediationFailed`,
  `BedrockRequestLatencyMs`, `BedrockErrors`, `DDMOperationLatencyMs`,
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
