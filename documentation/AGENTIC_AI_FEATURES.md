# DenDenMushi Agentic AI Features

This document summarizes the implemented Agentic AI features in DenDenMushi.
It is intended as a reference for the final capstone report and should be kept
in sync with future Agentic AI feature, workflow, API, safety, and deployment
changes.

## Purpose And Scope

Agentic AI is the Phase 2 extension of DenDenMushi. It adds bounded incident
triage, operator assistance, approval tracking, and constrained remediation
around the existing SSH access platform.

The Agentic AI features do not replace the Phase 1 terminal path. Live terminal
traffic remains direct:

```text
Browser / Angular
  <-> Proxy Dataplane
  <-> Target Host or future streaming DDM Agent
```

Agentic AI is limited to non-interactive incident workflows:

```text
CloudWatch/SQS alert
-> incident-agent durable coordination
-> Incident Reasoning Agent triage over A2A
-> Agent Tool Gateway bounded diagnostics over MCP
-> Incident Reasoning Agent plan proposal over A2A
-> agent-controlplane human approval or rejection
-> Agent Tool Gateway state-checked STS capability
-> Proxy Dataplane or DDM Agent allowlisted operation execution
-> verification and post-incident record
```

Model output is advisory. It does not grant authority by itself and cannot
create arbitrary shell commands, terminal streams, Kubernetes commands,
Terraform commands, IAM changes, or SQL mutations for direct execution.

## End-To-End Workflow

1. **Alert ingestion**
   - Managed-server CloudWatch alarms publish notifications to the incident
     queue.
   - The target-host Terraform reads the central Incident Agent SNS topic from
     the platform remote state by default, so target-local alarm notifications
     and central incident ingestion are both configured during the target-host
     apply. The topic can still be overridden for isolated testing.
   - The central Incident Agent SNS topic is encrypted with a customer-managed
     KMS key that explicitly allows CloudWatch Alarms to publish notifications.
   - `incident-agent` consumes SQS messages and accepts only managed-server
     alerts with the expected alarm description metadata.
   - Duplicate active alarms are grouped with an existing incident instead of
     starting another active workflow for the same deterministic group.
     Postgres enforces one active incident per group, while a renewable fenced
     processing lease prevents concurrent diagnosis during SQS redelivery and
     allows recovery after a worker crash.
   - The consumer receives one message at a time so queued messages are not
     hidden without a visibility heartbeat. A live-claim collision keeps the
     message and shortens its visibility to the claim-renew interval.
   - Matching CloudWatch `OK` transitions can recover active incidents and mark
     related alerts resolved.

2. **Incident creation and triage**
   - `incident-agent` creates sanitized alert and incident records in Postgres.
   - The coordinator delegates sanitized incident context to a stateless
     Reasoning Agent through the official A2A JSON-RPC interface. The Reasoning
     Agent uses pinned `gpt-5.4-2026-03-05` through an IAM-authenticated
     AgentCore inference gateway in `ap-southeast-1` to produce structured
     triage metadata. The gateway injects the external OpenAI credential from
     Secrets Manager; the key is never copied into a Kubernetes Secret or
     exposed directly to the Reasoning Agent. There is no Bedrock/Nova fallback.
   - If the OpenAI gateway invocation fails because of availability, quota, or
     throttling errors, the Reasoning Agent falls back to deterministic rule-based triage and plan
     generation. The resulting plan still passes through the same
     operation allowlist, plan-hash validation, and human approval gate.
   - LangSmith tracing can be enabled for explicit dev/debug windows through a
     Secrets Manager API key. The evaluated exporter retains allowlisted metadata
     with empty inputs and outputs; tracing is not required for approval or remediation.
   - Prompts and model outputs are constrained to incident context and
     supported operation IDs.
   - Each incident stores safe explainability metadata: model provider/type/ID,
     region, prompt template hashes, catalog version, operation-selection
     reasons, guardrail outcomes, and responsibility boundaries.

3. **Evidence collection**
   - The coordinator starts a bounded automation run through `agent-controlplane`.
   - `agent-controlplane` coordinates with Session Manager for run assignment
     and with STS for short-lived automation capability tokens.
   - Evidence is gathered only through diagnostic operation IDs exposed to the
     coordinator by the default-deny MCP Tool Gateway policy. Model suggestions
     are intersected with the catalog, `service_status` and `health_check` are
     mandatory, and the complete set is capped at five.
   - Operation outputs are bounded by timeout and byte limits before they are
     stored or displayed.

4. **Plan proposal**
   - The coordinator delegates sanitized context and bounded evidence to the
     Reasoning Agent through a second A2A task. GPT-5.4 proposes one structured
     remediation candidate without receiving execution authority.
   - The deterministic supervisor validates that the plan uses only supported
     operations and rejects command-like or prompt-injected content.
   - A plan hash is computed and stored with the incident.
   - Plans that require mutation move to `AWAITING_APPROVAL`. Plans without
     mutating actions can complete as triaged information.

5. **Human approval or rejection**
   - Operators view the deep-linkable Angular Incident workspace through
     `/agentic-ai/incidents/:incidentId`; Alerts remain concise supporting
     context under `/agentic-ai/alerts/:alertId`.
   - Approval and rejection require a Cognito user with `Manager` or `Admin`.
   - The approval request must submit the exact stored plan hash.
   - Stale, missing, expired, or mismatched plan hashes are rejected and
     recorded in the approval audit.

6. **Bounded remediation**
   - After approval, `agent-controlplane` asks the MCP Tool Gateway to execute
     only the single approved v1 remediation operation.
   - The gateway revalidates run phase and exact plan hash through Agent Control
     Plane, then obtains a fresh run-scoped STS capability. Runtime authority
     comes from workload identity and STS, not from the model.
   - The execution target validates run, incident, host, phase, operation
     allowlist, assigned pod ownership, and plan hash before running anything.

7. **Verification and closeout**
   - The workflow runs fixed verification operations after remediation.
   - The incident transitions to a resolved, failed, rejected, recovered, or
     completed state depending on the outcome.
   - A post-incident record captures root-cause summary, action taken,
     verification summary, final state, timestamps, and duration where
     available.
   - Automation runs are closed idempotently.
   - Agent Control Plane publishes sanitized approval and remediation metadata
     events to the platform SNS/SQS timeline when event publication is enabled.
     This is non-blocking and does not affect the approved execution path.

## Component Responsibilities

| Component | Agentic AI responsibility |
| --- | --- |
| `incident-agent` | Consumes SQS alerts, owns durable workflow/claim state, coordinates A2A handoffs, gathers evidence through MCP, and stores sanitized incident state. It has no model-provider credential access. |
| `incident-reasoning-agent` | Stateless A2A specialist for the `triage` and `plan` stages. It can invoke only the IAM-authenticated AgentCore gateway and has no OpenAI secret, database, SQS, Kubernetes, or operation authority. |
| `agent-tool-gateway` | Private Streamable HTTP MCP server for caller-filtered tool discovery, default-deny authorization, state validation, per-call capability acquisition, bounded invocation, and metadata-only audit events. |
| `agent-controlplane` | Exposes Cognito-protected APIs, records approval/rejection, owns automation-run policy, and requests approved remediation/verification through the Tool Gateway. It does not call Proxy Dataplane operations directly. |
| `sts` | Normalizes allowlisted projected workload identities and issues short-lived automation capabilities only to the Tool Gateway. Tokens bind run, incident, host, phase, operation allowlist, assigned pod instance, and plan hash. |
| `session-manager` | Stores automation run assignment, assigned dataplane ownership, lifecycle, and TTL. It does not route prompts, terminal streams, or remediation decisions. |
| `proxy-dataplane` | Owns live SSH PTY sessions and separately exposes assigned-pod automation operations. Automation accepts operation IDs only, never command text. |
| `ddm-agent` | Provides bounded target-side request/response command execution for allowlisted operations. It is not a streaming terminal transport. |
| `angular` | Provides the Agentic AI operator UI for alerts, incidents, triage, evidence, plan review, approval/rejection, timeline, approval audit, and post-incident report views. |
| `kubernetes` | Routes only public operator APIs to Agent Control Plane and deploys four private Agentic workloads with projected identities, IRSA separation, default-deny NetworkPolicies, quotas, and GitOps-managed MCP policy. |

Agent Control Plane emits `PlanApproved`, `PlanRejected`,
`RemediationExecuted`, and `RemediationFailed` to the shared metadata event lane
after the existing Postgres timeline writes. Audit Service consumes those events
from SQS for cross-service operations timelines. Event payloads include
correlation metadata such as `incidentId`, `runId`, `hostId`, `userId`, and
`planHash`, but never include model prompts, raw model responses, tokens,
command bodies, terminal streams, or secrets.

## Multi-Agent Design

The durable coordinator and stateless Reasoning Agent are independent private
workloads that communicate using the official A2A SDK. The role table remains
the explainability view of the workflow, while the A2A boundary is the actual
multi-agent process boundary. This preserves approval, audit, and terminal
traffic boundaries.

| Agent | Purpose and responsibilities | Input | Output | Planning / reasoning | Memory | Tools | Interactions |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Incident Manager Agent | Coordinates the LangGraph workflow, preserves handoff order, and keeps terminal traffic outside the agent path. | Managed-server alert record. | Workflow state transitions. | Deterministic LangGraph state machine. | Short-term incident workflow state only. | LangGraph. | Receives alert state from ingestion and hands to Triage Agent. |
| Triage Agent | Classifies incident priority/category and writes a safe triage summary. | Alarm name, host ID, sanitized alarm reason. | `TriageResult` and suggested diagnostic IDs. | Pinned GPT-5.4 through the AgentCore OpenAI connector, or deterministic fallback after bounded availability failures. | Disposable A2A task context only. | A2A, AgentCore inference gateway, OpenAI Responses API, prompt templates, rule fallback. | Receives an A2A triage task from the coordinator and returns structured data. |
| Evidence Collector Agent | Starts a bounded automation run and gathers diagnostic operation outputs. | Incident ID, host ID, catalog-filtered diagnostic IDs. | Bounded `OperationResult` list. | Deterministic default-deny policy; mandatory diagnostics plus up to three reviewed suggestions. | Incident-local evidence only. | Agent Control Plane automation API and MCP Tool Gateway. | Receives triage output and supplies bounded evidence to the planning A2A handoff. |
| Action Plan Agent | Proposes a structured remediation plan from sanitized context and bounded evidence. | Incident metadata and diagnostic evidence. | Candidate `Plan`. | Pinned GPT-5.4 structured reasoning in the Reasoning Agent, with deterministic fallback for availability failures. | Disposable A2A task context only. | A2A, AgentCore inference gateway, OpenAI Responses API, prompt templates, rule fallback. | Returns a candidate to the coordinator; it cannot discover or execute tools. |
| Action Plan Reviewer Agent | Converts advisory model output into a validated plan or rejects it. | Candidate `Plan`. | Validated plan, canonical plan hash, guardrail metadata. | Deterministic safety rules. | None beyond the candidate plan. | Operation catalog, plan-hash function, command-like content guardrail. | Sends approved-for-review plan to Manager/Admin approval flow. |
| Remediation Executor Agent | Executes only the human-approved operation and fixed verification. | Approved incident and exact approved plan hash. | Remediation result, verification result, post-incident report. | Deterministic execution policy. | Incident execution state and verification results. | Agent Control Plane plus MCP Tool Gateway; STS capability remains internal to the gateway path. | Runs only after Agent Control Plane records Manager/Admin approval. |

Incident detail responses expose these roles through the additive
`explanation.agents` array. The metadata is safe for report and UI display: it
contains role descriptions, reasoning type, memory scope, tool names, inputs,
outputs, and handoffs, but not rendered prompts, raw model responses, tokens,
secrets, command bodies, or terminal streams.

The additive `explanation.trace` contract is the per-run audit projection:

```text
schemaVersion: v1
agentActions[]: eventId, stage, fromAgent, toAgent, protocol, actorType,
                status, summary, durationMs, fallbackUsed, occurredAt
toolCalls[]:    eventId, operationId, phase, selectedBy, status, reason,
                durationMs, exitCode, resultDigest, outputTruncated, occurredAt
```

`AgentDelegated`, `OperationExecuted`, and
`VerificationOperationExecuted` records in append-only `incident_events` are
the source of truth. Agent Control Plane orders and projects those events and
joins selection reasons from stored `toolDecisions`. Older incidents receive a
useful diagnostic trace reconstructed from their bounded evidence. The trace
records successful, failed, and deterministic-fallback attempts without
including chain-of-thought, prompts, provider responses, tokens, unrestricted
arguments, command text, secrets, or terminal traffic.

## Implemented GoF Design Patterns

The incident planning implementation uses **Strategy** and **Adapter** from the
Gang of Four catalogue. `planning/planner.py::Planner` defines the interchangeable
triage/plan contract used by `TriageAgent` and `ActionPlanAgent`;
`RuleBasedPlanner`, `OpenAIPlanner` and `BedrockPlanner` implement its algorithms.
`planning/a2a_client.py::A2APlanner` adapts that domain contract to authenticated
A2A messages and structured artifacts, validating returned domain results.
Strategy separates algorithm choice from workflow; Adapter separates the domain
interface from the remote protocol. Both implementations already existed; the
pattern documentation and class docstrings make their roles explicit without
changing execution or approval behavior.

See `incident-agent/README.md`, section **GoF Design Patterns**, for participant
diagrams, call flow, trade-offs and existing test references. The merge-ready
report's Design Patterns section contains the corresponding academic analysis.

## User-Facing Features

The Angular web application includes an Agentic AI area for operators.

Implemented views and actions:

- **Persistent workspace tabs**: `/agentic-ai` redirects to Incidents, while
  Incidents and Alerts remain visible as peer tabs. Legacy `?incidentId=` links
  redirect to the dedicated incident route.
- **Alerts list and detail page**: shows managed-server source, grouping,
  reason, time, state, and a clear link to the related incident without
  duplicating the incident workspace.
- **Incidents list and detail page**: shows readable state labels, host, alarm,
  impact, current workflow step, next required action, and final outcome. The
  previous alert and incident drawers are removed.
- **Agent triage view**: shows priority, category, triage summary, and
  rationale generated through the bounded triage workflow.
- **Proposed plan view**: shows plan summary, rationale, and operation IDs
  proposed for remediation.
- **Agent activity**: shows the clickable Alert → Triage → Diagnose → Plan →
  Human approval → Remediate → Verify → Closed flow and actor legend. Selecting
  a stage shows its configured contributors, responsibilities, reasoning and
  memory boundaries, inputs, outputs, next handoff, and matching per-run A2A or
  tool activity; the complete trace remains available below for audit.
- **Numbered tool activity**: groups calls under Diagnose, Remediate, and Verify
  with readable labels plus operation IDs, selection authority, execution
  outcome, duration, exit code, truncation, and digest.
- **Evidence and safety**: keeps bounded diagnostic output, model/catalog/
  gateway identifiers, plan hashes, digests, responsibility boundaries, and
  guardrail detail expandable and collapsed by default.
- **Approval and rejection**: lets `Manager` or `Admin` users approve or reject
  the exact stored plan hash.
- **Timeline**: displays incident lifecycle events such as alert receipt,
  agent delegation, evidence collection, plan proposal, approval, remediation,
  verification, failure, fallback, and recovery.
- **Audit log query**: the Audit area includes an Agentic AI tab that queries
  alerts, incidents, and timeline metadata by incident ID, alert ID, host,
  state/status, event type, actor, and time window.
- **SSH audit cross-links**: Agentic AI alert and incident views can open the
  SSH audit search filtered by host and a bounded time window. SSH audit rows
  do not store incident or alert IDs in this version.
- **Approval audit**: displays approval/rejection attempts, submitted plan
  hashes, actors, outcomes, errors, and timestamps.
- **Post-incident report**: shows final state, root-cause summary, action taken,
  verification summary, resolution time, and duration where available.

Relevant states exposed to the UI include:

```text
DIAGNOSING
AWAITING_APPROVAL
EXECUTING
COMPLETED
REJECTED
RECOVERED
FAILED
```

Relevant alert statuses include:

```text
RECEIVED
TRIAGING
TRIAGED
PENDING_APPROVAL
EXECUTING
RESOLVED
REJECTED
FAILED
```

## Operation Catalog

Agentic AI operations are cataloged by operation ID. The model may recommend
supported operations through a structured plan, but execution is controlled by
validated code paths and STS capability tokens.

Diagnostic operations:

```text
system_overview
disk_usage
memory_usage
top_processes
service_status
service_logs
health_check
target_probe
```

Remediation operations:

```text
restart_service
recover_demo_app
reload_service
```

Verification operations:

```text
service_status
health_check
```

The v1 workflow executes at most one approved remediation operation, followed
by fixed verification operations.

`target_probe` is read-only. It verifies the target-side automation helper,
configured service, and health URL without accepting parameters or executing
free-form commands.

## API Reference

Public Agentic AI routes are served by Agent Control Plane and require the
authenticated ALB/Cognito boundary. Business routes require
`x-api-version: 1`; health, readiness, and spec routes are exempt.

```http
GET  /agentic-ai/health
GET  /alerts?incidentId=&hostId=&status=&cloudwatchState=&from=&to=&limit=&cursor=
GET  /alerts/{alertId}
GET  /incidents?incidentId=&alertId=&hostId=&state=&from=&to=&limit=&cursor=
GET  /incidents/events?incidentId=&alertId=&eventType=&actor=&from=&to=&limit=&cursor=
GET  /incidents/{incidentId}
POST /incidents/{incidentId}/approve
POST /incidents/{incidentId}/reject
```

Agentic AI event queries return structured metadata only. They do not expose
prompts, secrets, tokens, private keys, raw terminal streams, or arbitrary
command bodies.

Internal automation routes are served by Agent Control Plane and require
projected workload bearer tokens. Start/close accept only the coordinator;
capability issuance is reserved to the Tool Gateway through STS trust.

```http
POST /automation/runs/start
POST /automation/runs/{runId}/token
POST /automation/runs/{runId}/close
```

The assigned Proxy Dataplane instance exposes the internal operation execution
endpoint:

```http
POST /automation/runs/{runId}/operations
```

DDM Agent exposes a bounded target-side execution endpoint:

```http
POST /execute
```

Worker-only Incident Agent routes:

```http
GET /healthz
GET /readyz
GET /internal/worker/health
```

Private standards-based agent interfaces:

```http
GET  /.well-known/agent-card.json  # Reasoning Agent, port 8093
POST /                             # A2A JSON-RPC, port 8093
POST /mcp                          # MCP Streamable HTTP, port 8094
```

The A2A card advertises one `analyze_incident` skill with `triage` and `plan`
stages. The MCP catalog presents each reviewed operation ID as a separate tool.
Inputs are limited to `runId` and the required `planHash`; arbitrary commands,
target addresses, credentials, URLs, and parameters are rejected.

`GET /internal/worker/health` is a business route and requires
`x-api-version: 1`. `GET /healthz`, `GET /readyz`, and `GET /openapi.yaml` are
probe/spec routes and remain unversioned.

## Security And Safety Controls

The Agentic AI implementation preserves the original DenDenMushi trust
boundaries:

- Live terminal traffic is never routed through Incident Agent, Agent Control
  Plane, Session Manager, Kafka, Redis, or a model workflow.
- Agents do not execute free-form autonomous shell commands.
- Model output is advisory until deterministic validation and human approval
  convert it into an allowed operation.
- Mutating remediation requires approval of the exact stored plan hash.
- Approval and rejection require authenticated Cognito users in `Manager` or
  `Admin`.
- Public Agent Control Plane responses are non-cacheable and include
  MIME-sniffing, framing, and referrer protections. Browser calls remain
  same-origin and the API does not emit CORS allow headers.
- Automation authority comes from short-lived STS capability tokens plus
  authenticated workload identity.
- A2A and MCP callers use projected service-account tokens validated through
  STS TokenReview. Workload identity and capability-issuer allowlists are
  separate even though they retain the existing token audience.
- STS rereads its mounted Kubernetes reviewer token for every TokenReview
  because projected service-account credentials rotate while pods are running.
  Missing or empty reviewer credentials fail closed and neither reviewer nor
  caller tokens are logged.
- MCP policy is GitOps-managed and defaults to deny. The coordinator can use
  diagnostics, Agent Control Plane can use approved remediation and fixed
  verification, and the Reasoning Agent has no tool permissions.
- Agent Control Plane validates current incident/run phase and exact stored
  plan hash before the gateway can receive a fresh capability.
- Tokens bind run ID, incident ID, host ID, phase, operation allowlist, owner
  pod/instance assignment, and plan hash.
- Proxy Dataplane automation accepts operation IDs only and maps them to the
  code-reviewed operations path. It never accepts arbitrary command text.
- DDM Agent validates STS tokens and operation allowlists before execution.
- Operation inputs, outputs, retries, and runtime are bounded.
- Transient diagnostics and verification permit one retry; remediation is
  never retried automatically. Authentication, validation, policy, and stale
  state failures fail closed.
- Explainability records contain safe metadata only: model identifiers, prompt
  template hashes, operation IDs, guardrail names/outcomes, and responsibility
  boundaries.
- Prompts, logs, traces, audit records, and metrics must not contain secrets,
  tokens, private keys, passwords, raw command bodies, or terminal streams.
  LangSmith tracing is optional observability only; it must not be required for
  incident processing, approval, remediation, or audit correctness.
- Logs and metrics use metadata fields such as `requestId`, `incidentId`,
  `runId`, `hostId`, `operation`, `planHash`, `state`, `status`, `durationMs`,
  and `errorKind`.

## Explainable And Responsible AI Practices

DenDenMushi aligns Agentic AI development and deployment with explainable and
responsible AI principles by keeping model output advisory, bounded, auditable,
and subject to human approval before mutation.

- **Explainability**: Incident records store model provider/type/ID, prompt
  template hashes, agent roles, reasoning type, operation-selection reasons,
  guardrail outcomes, responsibility boundaries, and plan hash. Operators can
  inspect why a plan was proposed without exposing prompts, tokens, secrets, or
  raw terminal content.
- **Human oversight**: Mutating remediation requires a Manager/Admin approving
  the exact stored plan hash. The model cannot approve, execute, or mint
  authority by itself.
- **Fairness and bias mitigation**: The workflow uses infrastructure signals
  such as host ID, alarm state, service health, and bounded diagnostics, not
  demographic or personal attributes. Access to approval actions is based on
  Cognito role membership. Future model changes should evaluate whether alert
  prioritization unfairly favors particular hosts, environments, or teams.
- **Accountability and auditability**: Timeline events, approval-decision audit
  rows, metrics, and structured logs record incident lifecycle, plan proposal,
  approval/rejection, remediation, verification, and failure states.
- **Robustness and safety**: Deterministic guardrails reject unsupported
  operation IDs, command-like content, multiple remediation actions, stale or
  mismatched plan hashes, and execution outside the v1 catalog.
- **IMDA Model AI Governance Framework alignment**: The implementation maps to
  internal governance through clear roles and responsibility, model
  transparency through explanation metadata, human-in-the-loop approval,
  controlled operations, audit records, and security controls around data
  minimization and access control.

## AI Security Risk Register

| Risk | Impact | Mitigation / security control |
| --- | --- | --- |
| Prompt injection in alarm reason or diagnostic output | Model may propose unsafe or irrelevant actions. | Sanitized context, bounded prompt size, structured plan schema, deterministic reviewer, command-like content rejection, operation allowlist. |
| Tool confusion or hallucinated operation ID | Model may suggest a tool the system does not support. | Reviewer accepts only v1 remediation catalog operation IDs; Proxy Dataplane also validates operation IDs. |
| A2A caller spoofing | An unauthorized workload could submit reasoning tasks. | Projected service-account token, STS TokenReview, exact coordinator subject, and no public service exposure. |
| Rotated TokenReview credential | A long-running STS pod could reject valid A2A and automation callers after its reviewer credential rotates. | Read the mounted reviewer token for every validation, fail closed when unavailable, and verify rotation with a focused STS test. |
| MCP policy bypass or cross-run access | A caller could discover or invoke another phase, run, or plan. | Caller-filtered discovery, default-deny Git policy, strict arguments, Agent Control Plane phase/run/hash validation, and fresh per-call STS capabilities. |
| Plan-hash drift | Operator may approve a plan different from the one executed. | Canonical plan hash is stored; approval and execution require exact hash match. |
| Stale incident state | Approval may apply after recovery, expiry, or state change. | Plan expiry, state-checked updates, conflict responses, approval audit rows. |
| Secret or token leakage | Sensitive values could appear in prompts, logs, traces, or UI. | Redaction/truncation, metadata-only logs, no raw prompts/model responses in stored explanations, no OpenAI secret in the pod, and optional tracing disabled by default. |
| Excessive autonomy | Agent could mutate systems without human intent. | Model output is advisory; Manager/Admin approval is required before mutating remediation; STS tokens provide scoped runtime authority. |
| Approval bypass | Unprivileged user could approve or reject plans. | Public routes use ALB/Cognito identity; approval and rejection require `Manager` or `Admin`; all attempts are audited. |
| Free-form command execution | Agent could run arbitrary shell, Kubernetes, Terraform, IAM, or SQL commands. | Automation uses operation IDs only; DDM Agent and Proxy Dataplane validate capability tokens and allowlists. |
| Oversized or malicious output | Diagnostic output could exhaust storage or hide prompt attacks. | Operation timeouts, output byte limits, redaction, bounded retries, structured evidence storage. |
| Audit gaps | Operators may not be able to explain what happened. | Incident events, approval decisions, post-incident reports, metrics, request IDs, and explanation metadata are retained. |
| Duplicate incident processing | SQS redelivery or multiple replicas could start overlapping workflows and allow stale writes. | Transactional exact-group claiming, a partial unique Postgres index, renewable leases, opaque fencing tokens on diagnosis writes, and visibility extension. |

## Observability And Audit

Agentic AI emits metadata-only operational signals:

- JSON application logs when configured with `LOG_FORMAT=json`.
- `X-Request-ID` propagation for synchronous service calls.
- Correlation IDs for SQS-driven workflow processing.
- CloudWatch EMF metrics in the `DenDenMushi` namespace.
- Timeline events for incident lifecycle milestones.
- A2A task ID, stage, latency, outcome, and fallback metadata through
  `AgentDelegated`; prompts and artifacts are excluded.
- Diagnostic, remediation, and verification attempts with phase, duration,
  status, exit code, truncation, and SHA-256 result digest. Stored trace events
  omit result bodies; only the separate bounded/redacted evidence record may be
  expanded in the UI.
- MCP `ToolCallAllowed`, `ToolCallDenied`, `ToolCallCompleted`, and
  `ToolCallFailed` metadata without capabilities or output bodies.
- Approval-decision audit rows for successful and failed approval/rejection
  attempts.
- Optional LangSmith traces for explicit Reasoning Agent debugging
  when `LANGSMITH_TRACING=true`.

LangSmith is disabled by default in the service. When enabled, Incident Reasoning Agent
loads `LANGSMITH_API_KEY` from the process environment or from AWS Secrets
Manager using `LANGSMITH_API_KEY_SECRET_ID`, then sets the LangSmith runtime
environment before constructing the selected planner. If the API key is
missing or Secrets Manager lookup fails, the worker sets tracing to false and
continues incident processing. Optional trace routing metadata is configured
with `LANGSMITH_PROJECT`, `LANGSMITH_ENDPOINT`, and
`LANGSMITH_WORKSPACE_ID`.

The OpenAI planner explicitly exports metadata-only reasoning, provider-attempt
and schema-validation spans. Deterministic fallback has a separate trace with
the same incident ID and stage. Inputs and outputs are empty; an allowlist admits
safe incident IDs, stage, model IDs, prompt-template hashes, durations, usage,
outcome and fallback only. SDK runtime-environment capture is disabled; LangSmith
adds trace-depth metadata. Prompts, model responses, diagnostic output, headers,
credentials and raw exceptions never enter these spans.

One daemon worker drains a bounded 128-span queue with no retries and short
network timeouts. A full queue or exporter failure loses telemetry only; the
planner and exact-plan approval boundary retain their existing behavior. Shutdown
joins for at most five seconds. A2A, evidence collection, deterministic review,
approval, execution and verification remain represented by application audit
records, not these reasoning spans. Use tracing only for explicit debug windows;
production remains disabled by default.

Representative metrics include:

```text
IncidentReceived
IncidentTriaged
EvidenceCollected
PlanProposed
PlanApproved
PlanRejected
RemediationExecuted
RemediationFailed
A2ARequestLatencyMs
A2AFallbacks
ToolCallFailures
BedrockRequestLatencyMs
BedrockErrors
OpenAIRequestLatencyMs
OpenAIErrors
OpenAITokens
AgentCoreGatewayThrottles
ProviderFallbacks
DDMOperationLatencyMs
DDMOperationErrors
SQSMessageFailures
SQSVisibilityExtensionFailures
IncidentClaimContended
IncidentClaimReclaimed
IncidentClaimLost
```

Representative incident events include:

```text
AlertReceived
AlertGrouped
IncidentCreated
IncidentProcessingReclaimed
AgentDelegated
AgentTriaged
EvidenceCollected
PlanProposed
PlanExpired
PlanApproved
PlanRejected
RemediationStarted
AutomationTokenIssued
OperationExecuted
RemediationExecuted
RemediationFailed
VerificationOperationExecuted
AutomationRunClosed
VerificationPassed
VerificationFailed
IncidentRecovered
```

## Deployment And Routing

The AWS deployment runs the Agentic AI components alongside the Phase 1 SSH
path:

- `agent-controlplane`
- `incident-agent`
- `incident-reasoning-agent`
- `agent-tool-gateway`
- `sts`
- `session-manager`
- `proxy-dataplane`
- `angular`

All four Agentic workloads run in `dendenmushi-agentic`. Their workload
identities, database secret, quota, and default-deny policies are
namespace-scoped. Coordinator-to-Reasoning A2A and coordinator/control-plane to
Tool Gateway MCP paths stay private. Only the Tool Gateway can reach Proxy
Dataplane operations; Agent Control Plane's old direct path is denied by
NetworkPolicy. Moving a pod or reusing a service-account name in another
namespace does not grant authority. Operational details are documented in
`KUBERNETES_ARCHITECTURE_AND_OPERATIONS.md`.

Ingress ownership for Agentic AI routes:

```text
/agentic-ai/health -> Agent Control Plane
/alerts*           -> Agent Control Plane
/incidents*        -> Agent Control Plane
```

Incident Agent remains an internal coordinator for ingestion and durable
workflow state. The Reasoning Agent and Tool Gateway have no Ingress, ALB route,
or public DNS. Public Agentic AI reads and approval actions remain owned by
Agent Control Plane.

Roll out this trace and workspace change in compatibility order: Agent Control
Plane first, Incident Agent second, and Angular last. The API fields are
additive, Agent Control Plane reconstructs legacy diagnostics when trace event
metadata is absent, and the Angular client treats missing trace arrays as
empty. Mixed-version deployment therefore preserves incident reads and the
existing exact plan-hash approval path.

The Agentic AI deployment depends on:

- Cognito and ALB authentication for public operator routes.
- IRSA/workload identity for model access and internal automation token issuance.
- Postgres for incident, alert, event, and approval state.
- SQS for CloudWatch alarm ingestion.
- An IAM-authenticated AgentCore gateway with the built-in `openai` inference
  connector as the only deployed LLM path. It routes qualified model
  `openai/gpt-5.4-2026-03-05`; no Bedrock/Nova fallback is configured.
- Session Manager and Proxy Dataplane for bounded automation run assignment
  and operation execution.
- Optional LangSmith API access for temporary Reasoning Agent prompt debugging.

Terraform creates the
`dendenmushi/incident-agent/openai-api-key-<env>` secret container. It is a
customer-managed external secret for the AgentCore Identity API-key credential
provider and must contain a JSON `api_key` field. The
Reasoning Agent role is intentionally not granted `secretsmanager:GetSecretValue`
for this secret. The gateway execution role can retrieve only that exact
credential and secret. AgentCore additionally requires credential retrieval on
its service-owned `default` token vault and workload-identity directory; the
execution policy includes those required parents plus the gateway identity and
explicitly denies all other resources. The gateway injects the key into
outbound OpenAI requests. The
existing private MCP Tool Gateway is unchanged and remains the separate
authority boundary for bounded diagnostics and remediation operations;
AgentCore is only the LLM inference path.

Requests use the Responses API with `reasoning.effort=low`, low verbosity,
`max_output_tokens=4096`, `store=false`, a 60-second timeout, and two bounded
attempts. The dedicated OpenAI project is intentionally opted into input/output
sharing for complimentary daily usage. That is an OpenAI project policy, not a
gateway guarantee: `store=false` limits Responses application storage but does
not override the sharing opt-in. All prompts and evidence remain sanitized and
bounded. The AgentCore per-target limits of 10 requests/minute and 100,000
tokens/minute fail open and reduce spikes; they do not enforce the 250,000-token
daily complimentary allowance.

LangSmith deployment/configuration is split across the infrastructure and
GitOps repositories:

- `aws-terraform` defines `langsmith_api_key`, `langsmith_project`,
  `langsmith_endpoint`, and `langsmith_workspace_id` variables. It creates the
  `dendenmushi/incident-agent/langsmith-api-key-<env>` Secrets Manager secret,
  writes a secret version only when `langsmith_api_key` is supplied, grants
  Incident Reasoning Agent `secretsmanager:GetSecretValue` for that secret, and exposes
  the secret ID plus project, endpoint, and workspace values as Terraform
  outputs.
- `kubernetes/scripts/bootstrap-aws.sh` reads those Terraform outputs and
  writes the dev overlay values for `INCIDENT_AGENT_LANGSMITH_TRACING`,
  `INCIDENT_AGENT_LANGSMITH_API_KEY_SECRET_ID`,
  `INCIDENT_AGENT_LANGSMITH_PROJECT`,
  `INCIDENT_AGENT_LANGSMITH_ENDPOINT`, and
  `INCIDENT_AGENT_LANGSMITH_WORKSPACE_ID`.
- The Kubernetes Incident Reasoning Agent manifest maps those overlay values to the
  runtime environment variables `LANGSMITH_TRACING`,
  `LANGSMITH_API_KEY_SECRET_ID`, `LANGSMITH_PROJECT`,
  `LANGSMITH_ENDPOINT`, and `LANGSMITH_WORKSPACE_ID`. The LangSmith API key
  itself is not written to Kubernetes YAML or ConfigMaps.
- The Incident Agent PreSync hook reads `DATABASE_URL` from the pre-bootstrapped
  `dendenmushi-database` Kubernetes Secret. Migration-capable images run
  Alembic; older restorable images run a read-only compatibility check against
  their own SQLAlchemy metadata. The hook does not depend on the Incident Agent
  workload identity service account being created during the later normal sync
  phase.
- Incident Agent runtime startup never creates or mutates tables. Its Alembic
  entrypoint upgrades empty and versioned databases normally. An unversioned
  database is stamped at revision 0004 only after its managed table, column,
  primary-key, and source-ID uniqueness signature matches the known legacy
  layout; the entrypoint restores the historical baseline indexes omitted by
  the old `create_all` path before applying revision 0005. Unknown, partial, or
  conflicting layouts fail closed without exposing row values or group keys.

The dev overlay currently enables `LANGSMITH_TRACING=true` so traces appear
after Terraform has created the API key secret version. Other environments
should keep tracing disabled by default and enable it only for short,
intentional debugging windows. Terraform state and local plan files must be
treated as sensitive when `langsmith_api_key` is provided because Terraform
stores secret values in state even for sensitive variables.

The coordinator, Reasoning Agent, Tool Gateway, and migration command use one
Incident Agent repository and immutable image. A2A task state is disposable;
Postgres remains authoritative. A2A and MCP remain the workload communication
and bounded-tool standards. AgentCore Gateway is used only for model inference;
AgentCore Runtime is not used.

The auto-instrumented coordinator requests `128Mi` and is limited to `512Mi`.
The earlier `256Mi` limit produced live OOM restarts, so operational checks use
HTTP or dedicated probe pods instead of starting another instrumented Python
runtime inside the coordinator pod.

## Current Limitations And Future Work

Current limitations:

- No autonomous free-form shell execution.
- No terminal traffic through Agentic AI components.
- No brokered live terminal path.
- DDM Agent is request/response command execution only, not a streaming PTY.
- `connectionType=agent` is not part of the working end-to-end terminal path.
- The v1 remediation workflow executes only one approved remediation operation.
- MCP tools are registered only through reviewed catalog code and explicit
  GitOps policy; arbitrary runtime registration is intentionally unsupported.
- A2A and MCP run on EKS. AgentCore Gateway provides only the OpenAI inference
  path; the existing MCP Tool Gateway and approval/execution path are unchanged.
- There is no cross-incident vector memory. Exact incident grouping is
  deterministic; any future semantic incident retrieval must remain read-only,
  redacted, evaluated, and separate from ownership, authorization, or execution.
- Durable audit querying and full session recording remain deferred.

Future capabilities should only be added after preserving the bounded
incident-agent path and Phase 1 terminal baseline:

- Persistent streaming PTY transport for DDM Agent.
- More complete operator/admin workflows.
- Durable audit event storage and querying.
- Session recording with explicit security, retention, and access controls.

## R12 six-role evaluation — 7 October 2026

The isolated R12 evaluation exercises all six role implementations, with actual
Agent Control Plane service code for remediation and simulated operational
dependencies. All 30 role/category cases and 26 supporting checks passed.
The frozen 12-scenario rule corpus passed 24/24 stage checks after fixes.
Three repetitions through the existing IAM-authenticated AgentCore
`openai/gpt-5.4-2026-03-05` route passed 72/72 stages with 72 requests and no
fallback. Only triage and planning are model-backed; other roles enforce
deterministic workflow and authority rules.

The evaluation preserves initial failures and records expected/actual outputs,
source/corpus/prompt/catalog hashes, revisions, provider attempts and per-stage
fallback. Its safety corpus uses synthetic inputs; tools and approvals are
fixtures, and claim/fencing tests use disposable local Postgres. Neither live
remediation nor deployed end-to-end correctness is claimed. Full evidence and
reproduction commands are in [the retained R12 evidence](evidence/release-2026-10-13/README.md#evaluations).

Verified fixes make rule fallback distinguish whole-word active/inactive
service state and use only current service-status/health-check stdout, excluding
transport-failure evidence. Provider authorization/configuration failures and
malformed outputs fail explicitly rather than retrying or falling back; transient
408/429/5xx and transport failures retain bounded fallback. Failed diagnoses
close their automation runs best-effort. Agent Control Plane closes validated
execution runs on success or failure with a separate bounded cleanup context;
it emits `AutomationRunCloseFailed` when cleanup fails and retains run TTL as
the fallback. Mutations are never retried automatically.

These local changes add no API or schema requirement and require normal image
promotion to affect deployments. STS and live terminal routing are unchanged.
A06 human review and A08/R15 human calibration remain open; these results are
engineering assertions, not human-labelled accuracy.
- More complete change-request and server-inventory integrations.

## R10 tracing evidence and R16 model comparison — 7 October 2026

The controlled replay used the final local Reasoning Agent code and the existing
IAM-authenticated AgentCore route. LangSmith readback verified two correlated
roots and six spans for R12-S01, with empty inputs/outputs and 14-day base
retention. No live incident, remediation or terminal commands were executed.
The monthly preflight found zero visible current-month roots across two accessible
projects; this task added two, within the 100-trace ceiling and 5,000-trace allowance.

Ten preselected R12 cases were run once for triage and planning on each pinned
snapshot. GPT-5.4-2026-03-05 passed 20/20 stage checks; GPT-5.5-2026-04-23 passed
19/20; the separate rules baseline passed 20/20. GPT-5.5 selected the wrong
allowlisted recovery operation for one stopped-service case. There were no
structural safety violations, provider failures, retries or scored fallbacks.
All 40 requests reported usage; the list-price estimate was USD0.1417725 against
a USD5 ceiling, including the two traced provider calls. This small descriptive
pilot does not establish statistical superiority or change the deployed model.

The snapshot allowlist, optional exporter and evaluation harness require normal
image promotion for deployed use. There are no public API or database changes.
See [the retained R16 evidence](evidence/release-2026-10-13/README.md#historical-evidence) for source manifests,
privacy findings, limitations, verification and reproduction instructions.

## Capstone contract and release hardening — 13 October 2026

The evaluated Incident Agent harness and metadata-only model tracing, together
with Agent Control Plane bounded cleanup, are published as identifiable
commits from current remote default branches (Incident Agent `ec816d4`, Agent
Control Plane `c23ffb7`). Historical October 7 results keep
their original source identities; they are not relabelled as results of the new
release. Fresh evaluations and deployed acceptance results belong to the
cross-repository evidence index in Kubernetes.

All nine checked-in OpenAPI documents now validate with the pinned
`openapi-spec-validator==0.9.0`. Agent Control Plane contracts include incident,
alert, explanation, automation-run and error envelopes. Both approval and
rejection require the exact `planHash`; real handler tests reject missing,
blank and malformed values. Probe and specification routes remain exempt from
`x-api-version: 1`. No approval or operation authority comes from model output.

The shared Go scan gate explicitly evaluates symbol-level JSON findings and
retains failed scan artifacts. Node Semgrep findings fail CI. Project image
workflows require successful main-push CI, preserve the tested source identity,
and pass the build digest to GitOps promotion. Dataplane terminal upgrades now
require cryptographically verified ALB identity in addition to the STS token;
automation endpoints retain their existing workload-capability boundary.

The October 13 rerun passed 24/24 deterministic cases, 56/56 cross-service
contract checks and 72/72 gateway stage checks without fallback. The R16 replay
passed 20/20 for rules and each pinned model (40 provider calls). Six stored
LangSmith spans were read back with empty inputs and outputs. Full source hashes
and original run manifests are retained; the earlier 19/20 GPT-5.5 result remains
historical evidence and is not overwritten.

AWS dev release `508c2e1ae56add8d16ef2b33f9b9b5447439c7df` reconciled
Synced/Healthy. All twelve deployments use verified digest references; nine
service OCI revision labels match the merged source. Live API checks passed
37/37 across eight deployed API services. A live check exposed an installed-wheel
specification path bug; Incident Agent PR #6 packages the OpenAPI resource and
adds an installed-wheel response test. DDM Agent is validated locally/CI and is
not the live SSH transport.

Authenticated browser acceptance passed SSH start, I/O, resize, detach/rejoin
with shell state preserved, read-only observation, termination and zero active
sessions. Retained audit was verified by metadata/counts only. The human-approved
plan for `inc-0546b7d99bd1e255fb21db6d2de2daaa` executed one `recover_demo_app`
action, successful fixed verification and run closure. The separate synthetic
rejection incident executed no remediation. Hash drift and execution failure
cleanup are covered in isolated tests; no forged approval was sent to a live
mutation endpoint.

A controlled Angular rollback (Kubernetes PR #195) and restore (#196) both
passed authenticated browser SSH I/O and Argo health. Strict dataplane identity
remained enabled. No Terraform apply or ECR mutability change was performed.
The disposable PostgreSQL fixture was deleted after testing. Durable sanitized
results and reproduction instructions are in the Kubernetes repository at
[`documentation/evidence/release-2026-10-13/README.md`](https://github.com/NUS-MTech-Capstone/kubernetes/blob/main/documentation/evidence/release-2026-10-13/README.md).
These bounded engineering evaluations do not establish human-labelled accuracy,
production load capacity or statistical superiority between models.
