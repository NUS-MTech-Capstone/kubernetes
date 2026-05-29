# Kubernetes

Bare minimal EKS manifests for the DenDenMushi MVP.

## Layout

```text
apps/dendenmushi/base
apps/dendenmushi/overlays/dev
```

This repository is the right place for manifests because it can become the
ArgoCD GitOps source later. Service repositories should build and push images;
this repository should decide what runs in the cluster.

## Assumptions

These manifests match the current Terraform direction:

- EKS in `ap-southeast-1`
- AWS Load Balancer Controller installed
- `ingressClassName: alb`
- ALB target type `ip`
- public HTTP listener on port 80 for the MVP

Before applying, replace the placeholder ECR account/repository names in the
image fields or patch them through Kustomize:

```text
000000000000.dkr.ecr.ap-southeast-1.amazonaws.com/dendenmushi/<service>:dev
```

The default public hosts are:

```text
api.ddm.keiyam.me
ws.ddm.keiyam.me
```

Create DNS records for those names pointing to the ALB created by the ingress,
or patch the ingress hosts for your environment.

## Apply

```bash
kubectl apply -k apps/dendenmushi/overlays/dev
```

## ArgoCD Later

An optional starter Application manifest is available at:

```text
argocd/dendenmushi-dev-application.yaml
```

Apply it only after ArgoCD is installed. It is intentionally not referenced by
the app Kustomization because clusters without ArgoCD will not have the
`Application` CRD.

## MVP Notes

- `session-manager`, `sts`, and `proxy-dataplane` run as one replica because
  their current MVP state is in-memory.
- `proxy-dataplane` is also one replica so the public WebSocket service maps to
  the single registered dataplane instance. Later, direct per-pod routing can be
  implemented with pod-specific reachable URLs or a more deliberate ingress
  design.
- Control traffic uses `api.ddm.keiyam.me`.
- WebSocket terminal traffic uses `ws.ddm.keiyam.me` and goes directly to the
  proxy dataplane service, not through the control plane.
