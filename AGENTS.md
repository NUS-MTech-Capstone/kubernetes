# AGENTS.md

## Repository Scope

This repository owns Kubernetes manifests for DenDenMushi workloads.

Primary responsibilities:

- Namespaces, ConfigMaps, Deployments, Services, and Ingresses.
- Kustomize bases and environment overlays.
- Argo CD Application manifests.
- Runtime configuration that belongs in Kubernetes rather than Terraform.

Do not provision AWS infrastructure here. AWS resources such as EKS, VPC, IAM,
ACM, and the AWS Load Balancer Controller belong in `aws-terraform`.

## Current Direction

Use this repository as the Argo CD GitOps source.

The Phase 1 deployment should stay explicit and reviewable:

- One namespace: `dendenmushi`.
- Internal services use `ClusterIP`.
- Public control traffic enters through ALB ingress.
- Public WebSocket terminal traffic enters through ALB ingress and goes directly
  to the proxy dataplane service.
- Incident Agent routes are exposed only behind the authenticated ALB boundary.
- Internal automation calls use workload identity and projected service-account
  tokens where required by STS.
- No broker or service mesh for live terminal traffic.

Keep replica and routing changes conservative. Do not scale stateful control or
dataplane components beyond their tested ownership, lease, and persistence
semantics.

## Phase 2 Agent Guardrails

- AI agents may consume alarm/event queues and call bounded internal automation
  APIs; they must not carry terminal keystrokes, stdout, stderr, or resize
  packets.
- Agent Deployments must use least-privilege service accounts, explicit
  environment variables, conservative resources, and probes.
- Mount projected workload tokens only for services that need STS automation
  capability issuance or validation.
- Keep Bedrock, LangSmith, database, queue, and Secrets Manager configuration
  explicit. Do not add broad shared secrets to ConfigMaps or plain YAML.
- Do not expose incident approval, rejection, or remediation routes through an
  unauthenticated ingress.
- Preserve `LOG_FORMAT=json`, request ID propagation, and low-cardinality metric
  dimensions for agent workloads.

## Manifest Rules

- Prefer Kustomize base plus overlays over copied environment manifests.
- Use clear labels:

```yaml
app: dendenmushi
component: <service-name>
```

- Keep image tags easy for GitOps tooling to patch.
- Do not put secrets in plain YAML. Use placeholders or reference Kubernetes
  Secrets that are created separately.
- Keep probes on `/healthz`.
- Use conservative resource requests and limits.
- Do not add advanced autoscaling, service mesh, custom controllers, or complex
  ingress routing until the basic flow works.

## EKS / ALB Assumptions

These manifests may assume:

- AWS Load Balancer Controller exists.
- `ingressClassName: alb`.
- ALB target type `ip`.
- Region is currently `ap-southeast-1`.

If these assumptions change, update the README and overlays together.

## Validation

Before completing manifest changes, run when possible:

```bash
kubectl kustomize apps/dendenmushi/overlays/dev
```

Also parse YAML if available:

```bash
ruby -e 'require "yaml"; Dir["**/*.yaml"].sort.each { |f| YAML.load_stream(File.read(f)); puts "ok #{f}" }'
```

`kubectl apply --dry-run=client` may still contact the configured cluster for
OpenAPI discovery, so a failing dry-run due to unreachable EKS is not by itself
a manifest-render failure.
