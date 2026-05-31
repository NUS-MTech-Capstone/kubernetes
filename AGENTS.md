# AGENTS.md

## Repository Scope

This repository owns Kubernetes manifests for DenDenMushi workloads.

Primary responsibilities:

- Namespaces, ConfigMaps, Deployments, Services, and Ingresses.
- Kustomize bases and environment overlays.
- Future ArgoCD Application manifests.
- Runtime configuration that belongs in Kubernetes rather than Terraform.

Do not provision AWS infrastructure here. AWS resources such as EKS, VPC, IAM,
ACM, and the AWS Load Balancer Controller belong in `aws-terraform`.

## Current Direction

Use this repository as the future ArgoCD GitOps source.

The MVP deployment should stay simple:

- One namespace: `dendenmushi`.
- Internal services use `ClusterIP`.
- Public control traffic enters through ALB ingress.
- Public WebSocket terminal traffic enters through ALB ingress and goes directly
  to the proxy dataplane service.
- No broker or service mesh for live terminal traffic.

Keep `session-manager`, `sts`, and `proxy-dataplane` at one replica while their
state is in-memory and dataplane routing is still MVP-level.

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
- Use conservative resource requests and limits for the MVP.
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
