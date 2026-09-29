# DenDenMushi Kubernetes Architecture And Operations

## Scope

DenDenMushi runs as one Argo CD application across three EKS namespaces. The
split limits credentials, network reachability, resource consumption, and
operator access without changing public APIs or the direct terminal path.

```text
Browser -> ALB -> Proxy Dataplane -> target SSH host
```

Proxy Control Plane, Session Manager, and Agent Control Plane remain control
services. They do not carry terminal input or output.

## Namespace Ownership

| Namespace | Workloads |
| --- | --- |
| `dendenmushi-ssh` | STS, Session Manager, Audit Service, Proxy Control Plane, Proxy Dataplane |
| `dendenmushi-agentic` | Agent Control Plane, Incident Agent coordinator, Incident Reasoning Agent, Agent Tool Gateway, incident database migration |
| `dendenmushi-webapp` | Nest Backend, Angular, Redis monitoring cache, webapp database bootstrap and migration |

The `ddm-agent` manifest belongs to `dendenmushi-ssh`, but it is intentionally
absent from the base kustomization and is not deployed.

Terraform creates the namespaces so IAM and operator RBAC can depend on them.
The GitOps source also declares the same labels so Argo CD verifies their
desired state. Terraform ignores only Argo CD's tracking annotation.

All namespaces enforce Pod Security `baseline` at Kubernetes `v1.35` and audit
and warn against `restricted`. A restricted warning is not an enforcement
failure; review it before moving enforcement to `restricted`.

## Services And Internal DNS

Cross-namespace callers use fully qualified service names. Short service names
are used only when the caller and service share a namespace.

| Service | Namespace | Port | Internal DNS |
| --- | --- | ---: | --- |
| Proxy Control Plane | SSH | 8080 | `proxy-controlplane.dendenmushi-ssh.svc.cluster.local` |
| Session Manager | SSH | 8081 | `session-manager.dendenmushi-ssh.svc.cluster.local` |
| STS | SSH | 8082 | `sts.dendenmushi-ssh.svc.cluster.local` |
| Proxy Dataplane | SSH | 8083 | `proxy-dataplane.dendenmushi-ssh.svc.cluster.local` |
| Audit Service | SSH | 8085 | `audit-service.dendenmushi-ssh.svc.cluster.local` |
| Incident Agent | Agentic | 8091 | `incident-agent.dendenmushi-agentic.svc.cluster.local` |
| Agent Control Plane | Agentic | 8092 | `agent-controlplane.dendenmushi-agentic.svc.cluster.local` |
| Incident Reasoning Agent | Agentic | 8093 | `incident-reasoning-agent.dendenmushi-agentic.svc.cluster.local` |
| Agent Tool Gateway | Agentic | 8094 | `agent-tool-gateway.dendenmushi-agentic.svc.cluster.local` |
| Nest Backend | Webapp | 3000 | `nest-backend.dendenmushi-webapp.svc.cluster.local` |
| Angular | Webapp | 8080 | `angular.dendenmushi-webapp.svc.cluster.local` |
| Redis | Webapp | 6379 | `redis.dendenmushi-webapp.svc.cluster.local` |

There is one `dendenmushi-config` ConfigMap in each namespace. Each contains
only values needed by that namespace. Static target inventory exists only in
the SSH copy.

## Public ALB And Identity Boundary

Ingresses in all three namespaces join the `dendenmushi-dev` ALB group and use
one public hostname, `api.ddm.keiyam.me`.

| Route | Backend | Authentication |
| --- | --- | --- |
| `/` | Angular | Public static application |
| `/ddm/auth/login` | Nest Backend | Cognito redirect |
| `/ddm/*` | Nest Backend | Cognito deny when unauthenticated |
| `/sessions/*` | Proxy Control Plane | Cognito deny when unauthenticated |
| `/sessions/*/ws` | Proxy Dataplane | Cognito deny plus STS session capability |
| `/agentic-ai/health`, `/alerts*`, `/incidents*` | Agent Control Plane | Cognito deny when unauthenticated |

The WebSocket route continues directly from the ALB to Proxy Dataplane. The
namespace split does not introduce an intermediary in the live traffic path.

## Workload Identity, RBAC, And Secrets

IRSA trust is bound to the full service-account subject, including namespace.
Moving a workload without updating Terraform causes AWS credential failures.

| Namespace | AWS-enabled service accounts |
| --- | --- |
| SSH | `sts`, `session-manager`, `audit-service`, `proxy-controlplane`, `proxy-dataplane` |
| Agentic | `agent-controlplane`, `incident-agent`, `incident-reasoning-agent` |
| Webapp | `nest-backend` |

STS has the cluster-scoped TokenReview permission through
`system:serviceaccount:dendenmushi-ssh:sts`. Workload identity validation
accepts only the `incident-agent` and `agent-controlplane` identities in
`dendenmushi-agentic`. Automation capability issuance accepts only
`agent-tool-gateway`. All use the existing projected-token audience. The Tool
Gateway has no AWS role; it receives fresh capabilities from STS only through
Agent Control Plane's state-aware token route. The Reasoning Agent IRSA role is
limited to Bedrock model invocation and the optional tracing secret.

Secret ownership is deliberately narrow:

| Secret | Namespace | Consumers |
| --- | --- | --- |
| `dendenmushi-runtime` | SSH | STS and Proxy Dataplane JWT validation |
| `dendenmushi-database` | SSH | Session Manager and Audit Service |
| `dendenmushi-database` | Agentic | Agent Control Plane, Incident Agent, migration |
| `dendenmushi-webapp-database` | Webapp | Nest Backend and migration |
| `dendenmushi-webapp-bootstrap` | Webapp | Temporary bootstrap job; deleted after completion |

The optional `dendenmushi:database-shell` operator group can create temporary
database pods only in the SSH and webapp namespaces. Maintenance pods must use
`component=database-maintenance` so NetworkPolicy grants only database access.

## NetworkPolicy

Terraform enables AWS VPC CNI NetworkPolicy support with standard enforcement.
Every application namespace then applies default-deny ingress and egress.
Policies use the namespace label `dendenmushi.io/tier` and the workload's
`component` pod label.

Allowed application paths are:

| Source | Destination |
| --- | --- |
| ALB addresses in `10.0.0.0/16` | Angular 8080, Nest 3000, Agent Control Plane 8092, Proxy Control Plane 8080, Proxy Dataplane 8083 |
| Proxy Control Plane | Session Manager 8081, STS 8082 |
| Proxy Dataplane | Session Manager 8081, Audit Service 8085, STS 8082, target SSH 22 |
| Audit Service | Session Manager 8081 |
| STS | Nest Backend 3000 |
| Nest Backend | Proxy Control Plane 8080, Audit Service 8085, Redis 6379 |
| Agent Control Plane | STS 8082, Session Manager 8081, Incident Agent 8091, Agent Tool Gateway 8094 |
| Incident Agent | Agent Control Plane 8092, Incident Reasoning Agent 8093, Agent Tool Gateway 8094 |
| Incident Reasoning Agent | STS 8082, external HTTPS for Bedrock and optional tracing |
| Agent Tool Gateway | STS 8082, Agent Control Plane 8092, Proxy Dataplane 8083 |
| Database clients and labeled migration/maintenance jobs | RDS in `10.0.0.0/16` on 5432 |
| AWS-integrated workloads and SSH keyscan | External TCP 443 |
| Every pod | CoreDNS TCP/UDP 53 |
| Instrumented application pods | CloudWatch agent in `amazon-cloudwatch` on TCP 4316 and 2000 |

NetworkPolicy is additive: both source egress and destination ingress must
permit an internal path. `scripts/verify-network-policies.sh` creates temporary
pods carrying a source component label, checks representative allowed paths,
and confirms representative denied paths time out. Its Redis checks require
Nest-to-Redis access to succeed and Angular-to-Redis access to fail.

The metadata-only Agent Tool Gateway is intentionally excluded from CloudWatch
Application Signals auto-instrumentation. Container Insights and structured
application logs remain enabled, while the exclusion prevents four unused
language runtimes from exhausting its bounded `128Mi` container limit.

Troubleshooting order:

1. Confirm `aws-node` exposes `ENABLE_NETWORK_POLICY=true` and the node agent is
   healthy.
2. Confirm both namespaces have the expected `dendenmushi.io/tier` label.
3. Confirm the pod has the expected `component` label.
4. Resolve the destination's fully qualified DNS name from the source pod.
5. Inspect source egress and destination ingress policies together.
6. Check whether an external endpoint uses a port other than explicitly
   allowed TCP 443.

Do not bypass a failure with a broad allow-all policy. Add a specific source,
destination, and port after confirming the application requirement.

## Quotas And Defaults

Each namespace has a LimitRange with container request defaults of `25m` CPU
and `64Mi` memory, limit defaults of `500m` CPU and `512Mi` memory, minimums of
`10m` and `16Mi`, and maximums of `2` CPU and `2Gi`.

| Namespace | Requests | Limits | Pods | Deployments | Jobs | Services | Secrets | ConfigMaps |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| SSH | 1.5 CPU, 3Gi | 6 CPU, 6Gi | 30 | 10 | 10 | 10 | 10 | 10 |
| Agentic | 1 CPU, 2Gi | 4 CPU, 4Gi | 15 | 5 | 10 | 5 | 8 | 5 |
| Webapp | 1 CPU, 2Gi | 4 CPU, 4Gi | 15 | 5 | 10 | 5 | 10 | 5 |

Inspect current usage with:

```bash
for ns in dendenmushi-ssh dendenmushi-agentic dendenmushi-webapp; do
  kubectl describe resourcequota dendenmushi-quota -n "$ns"
done
```

## GitOps And Deployment

One restricted AppProject permits only the Kubernetes repository, the three
application namespaces, and the required Namespace, ClusterRole, and
ClusterRoleBinding cluster resources. One `dendenmushi-dev` Application tracks
`apps/dendenmushi/overlays/dev` on `main` with prune and self-heal enabled.

Normal deployment order:

1. Apply `aws-terraform` with `secrets.tfvars` and
   `teammate-access.local.tfvars`.
2. Bootstrap `target-hosts-setup`.
3. Publish immutable images and merge image-promotion changes.
4. Run `kubernetes/scripts/bootstrap-aws.sh` to create secrets, bootstrap the
   webapp database, keyscan the target, refresh generated overlay values, and
   apply the AppProject and Application.
5. Commit and push generated `env.properties` and target inventory changes.
6. Run `kubernetes/scripts/verify-aws.sh`.
7. Apply Terraform again with the reported ALB hostname to update only the
   existing Route 53 application alias.

The incident and Nest database migrations are Argo CD PreSync hooks. A failed
migration blocks workload reconciliation. Inspect the Job logs in its owning
namespace before retrying.

Redis is a single-replica, internal cache on existing EKS capacity. It uses no
PVC, append-only file, or snapshot; `emptyDir` data can disappear on restart,
rescheduling, suspension, or restore. The server is capped at 64 MiB and uses
all-keys LRU eviction. Only successful CloudWatch alarm and metric reads are
cached for 60 seconds. Authentication, authorization, logs, alerts, Postgres
data, sessions, audit records, and terminal traffic are never cached. Redis is
not a readiness dependency: Nest falls back to CloudWatch after connection,
read, or write failures. The ClusterIP has no ingress and NetworkPolicy permits
only Nest Backend on TCP 6379, so no Redis password or Kubernetes secret is
used.

The Agentic namespace has four Deployments but only two application images.
The Incident Agent image selects `coordinator`, `reasoning`, or `tool_gateway`
at startup. A2A discovery is available only inside the cluster; A2A JSON-RPC
and MCP Streamable HTTP require projected-token authentication through STS.
The Tool Gateway mounts `agent-tool-policy/policy.json`, which is versioned in
Git, defaults to deny, and exposes only caller-approved operation IDs. Runtime
tool registration is not supported. Bedrock remains the managed model endpoint;
no custom LLM gateway or AgentCore resource is deployed. A2A and MCP preserve
a standards-compatible future migration path to AgentCore Runtime and Gateway.

## Maintenance Cutover And Rollback

A namespace or IRSA change requires a coordinated maintenance window. Active
SSH sessions are not migrated.

1. Back up both databases and record table counts.
2. Close active SSH sessions.
3. Delete the Argo CD Application and all application ingresses, then wait for
   the shared ALB to be removed.
4. Publish the coordinated Terraform and Kubernetes revisions.
5. Apply Terraform to enable CNI policy enforcement, create the three
   namespaces, update IRSA/RBAC, and remove the legacy namespace.
6. Run bootstrap, publish generated values, and apply the AppProject and
   Application.
7. Wait for migrations, twelve deployments, ALB creation, and Argo CD
   `Synced`/`Healthy`.
8. Update the existing Route 53 application alias and run verification.

Rollback is also a maintenance operation. Revert both repositories to a known
coordinated revision, remove the current Application/ingresses, apply the
matching Terraform revision, bootstrap its expected secrets, and reconcile its
matching GitOps revision. Never roll back only Kubernetes when IRSA subjects or
namespace-scoped secrets changed.

## Suspend And Restore

`aws-terraform/scripts/suspend-costly-aws.sh` is the single lifecycle script.
It inventories all three namespaces, backs up both databases through labeled
maintenance pods, deletes ingresses in all three namespaces, and preserves the
Route 53 hosted zone.

Restore uses the same backup and explicit AWS account guard:

```bash
AWS_PROFILE=capstone \
BACKUP_DIR=/absolute/path/to/backup \
EXPECTED_AWS_ACCOUNT_ID=891377133321 \
PUBLISH_GITOPS=true \
./scripts/suspend-costly-aws.sh up
```

The restore recreates infrastructure and namespaces, bootstraps namespace
secrets, restores databases before workloads start, publishes generated GitOps
values, starts Argo CD, waits for the ALB, publishes its ARN, updates only the
application alias, and runs deployment and NetworkPolicy verification.
Redis is recreated empty by GitOps; it is intentionally excluded from backup
and restore because it contains only disposable CloudWatch query results.

## Verification

Static checks:

```bash
kubectl kustomize apps/dendenmushi/overlays/dev >/tmp/dendenmushi.yaml
bash -n scripts/*.sh
git diff --check
```

Runtime checks:

```bash
kubectl get application dendenmushi-dev -n argocd
kubectl get pods,svc,ingress -n dendenmushi-ssh
kubectl get pods,svc,ingress -n dendenmushi-agentic
kubectl get pods,svc,ingress -n dendenmushi-webapp
./scripts/verify-aws.sh
```

Verification must confirm all twelve deployments, Argo CD health, shared ALB and
DNS readiness, quota and policy objects, representative allowed and denied
network paths, public health/readiness and headers, database table counts,
target SSH reachability, A2A discovery, caller-filtered MCP discovery, default
denial, and authenticated start/rejoin/observe behavior. A successful live
remediation is not claimed unless a genuine incident is separately approved;
protocol success is covered by automated integration tests and non-mutating
live discovery/authentication checks.

## Common Failures

| Symptom | Likely cause | Action |
| --- | --- | --- |
| AWS API calls return access denied | IRSA subject still names the old namespace | Compare ServiceAccount namespace with Terraform OIDC subject and reapply Terraform |
| Internal service name does not resolve | Caller uses a short name across namespaces | Use the full `service.namespace.svc.cluster.local` name |
| Connection times out after DNS succeeds | Missing source egress or destination ingress rule | Inspect both policies and component/namespace labels |
| ALB has unhealthy targets | ALB CIDR ingress rule or health path/port mismatch | Check target health, ingress annotations, and the `10.0.0.0/16` policy |
| Migration pod is pending or forbidden | Quota exhausted or secret absent in owning namespace | Describe the Job, ResourceQuota, and secret names |
| Monitoring cache reports unavailable | Redis pod unavailable or Nest-to-Redis policy/DNS failure | Check the Redis rollout and service, then run the NetworkPolicy probes; Nest should continue reading CloudWatch |
| A2A returns 401/403 | Coordinator projected token, STS allowlist, or TokenReview audience mismatch | Check the coordinator token projection, `WORKLOAD_IDENTITY_SERVICE_ACCOUNTS`, and STS logs without printing the token |
| MCP tool list is empty | Caller is not in the default-deny policy or workload identity validation failed | Compare the normalized subject with `agent-tool-policy`; do not add wildcard callers |
| MCP operation is denied after approval | Incident/run phase or exact plan hash changed | Read sanitized Agent Control Plane events and incident state; do not bypass the stale-state check |
| Argo CD reports a forbidden cluster resource | AppProject whitelist is missing a required resource | Review the rendered kind before changing the project whitelist |
| Temporary database pod cannot connect | Missing `component=database-maintenance` label | Recreate the pod with the documented label and bounded resources |
