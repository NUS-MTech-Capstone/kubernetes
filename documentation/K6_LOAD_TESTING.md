# DenDenMushi AWS performance evaluation

The A01/A07/R13 campaign evaluates the existing AWS dev deployment. The agreed
acceptance target is **40 concurrent interactive SSH sessions**, replacing the
original 1,000+ session target. A target is not a measured outcome. The [7 October API evidence](evidence/ssh-2026-10-15/historical-api/) and
[15 October SSH preflight evidence](evidence/ssh-2026-10-15/) retain each
attempt separately. **The SSH campaign stopped before timed load because
capacity did not release after browser-session closure.** The 40-session
target, terminal latency, repetitions, soak and saturation remain unmeasured.

## Deployment and measurement boundary

The observed deployment has one ready Proxy Dataplane replica, a 50-session
limit, and container limits of 500m CPU / 128 MiB memory. The executable ceiling
is `min(40, 50 - 10 - existing active sessions)`. No capacity, public API, token,
database schema or STS changes form part of this evaluation.

Session control uses Proxy Control Plane and STS. Each terminal-capacity VU
holds a real SSH PTY through its assigned direct Proxy Dataplane WebSocket.
API-read VUs do not represent SSH sessions. The generator is a local arm64
macOS host accessing the Singapore deployment over the public authenticated
ALB path; network conditions are part of the measured latency.

## Workload and acceptance

| Workload | Planned shape | Acceptance / interpretation |
| --- | --- | --- |
| Baseline / smoke | Idle resource capture; one authenticated lifecycle | Healthy deployment and zero remaining campaign sessions |
| Terminal discovery | 5, 10, 20, 30, 40 sessions; 60-second ramp and five-minute plateau per level | Actual concurrency; echo p95 <200 ms; start p95 <2 s; connection/probe success ≥99% |
| Repeatability | Two further runs at 20 and the highest passing level | Three measurements at selected levels; retain failed attempts |
| Soak | Highest passing level for 20 minutes plus ramp | Same terminal thresholds and resource guardrails |
| Lifecycle | Five VUs, three minutes, three repetitions | Attach, detach, rejoin, read-only observer and close |
| Start stress | Five VUs, two minutes plus 30-second ramps | At most two new sessions/s; cleanup mandatory |
| Agentic reads | Ten VUs, five minutes, three repetitions | HTTP p50 and p95 <1 s, error rate <1% |
| Audit reads | Ten VUs, five minutes, three repetitions | Same read thresholds; separate workload |
| Recovery | Inventory, deployment and resources after each run | Zero campaign sessions, stable readiness/revisions, resource recovery |

API iterations pause one second. Campaign session creation passes through a
shared limiter capped at two starts per second. Cooldown is at least one minute,
extending to five minutes for resource recovery. The full planned measurement
schedule is approximately 2–3 hours, excluding preparation.

A terminal probe types a unique printable marker every two seconds and clears
the input line with Ctrl-U without submitting a command. Only terminal-output
packets can satisfy the current marker; fragmented output is supported.
Banners, events, errors and stale markers cannot count as successful echo.
Timeouts and disconnects are recorded separately. Matching buffers are
transient; no terminal stream is exported. This measures transport/PTY echo,
not browser rendering or heavy command throughput.

Each run exports p50/p95/p99 and sample counts, remote request throughput,
errors, starts, client concurrency, disconnects and cleanup. A fixed five-second
authenticated `/ddm/auth/me` probe measures availability during later runs.
Exact timestamps, successes, failures and actual cadence are reported. The
observed gaps were approximately five seconds, with per-window ranges retained
in results.json. A 99.9% objective applies only to the observed test window and
does not establish long-term uptime.

## Guardrails

Before every terminal run, the runner checks the approved CR's time window and
host scope through authenticated APIs. Expired authorization stops testing;
the runner cannot create/approve requests or bypass STS. Read profiles use
normal operator authorization without creating SSH sessions.

The campaign stops on loss of readiness, new restart, deployment change,
authorization failure, failed cleanup, unexpected disconnect, >5% rolling
request failures, >1% probe failures or echo p95 >1 s. Resource checks stop after
two consecutive one-minute samples above 85% CPU or 80% memory for critical SSH
containers, or above 85% CPU on the target/RDS and 80% memory on the target. Container ratios use their
limits. Required telemetry older than three minutes stops execution. Failed
levels stop escalation and remain visible. Only identified campaign sessions are closed.
Unattributed sessions after uncertain starts stop the campaign for review. Revision/image changes
invalidate affected comparisons.

## Reproduction

From `k6-load-tests/`, with AWS profile `capstone`, kubectl access and k6:

```bash
make test
make inspect
python3 tools/campaign.py --ssh-only --cr APPROVED_DEDICATED_CR_ID \
  --output ../documentation/performance-evidence/YYYY-MM-DD/ssh-campaign
python3 tools/campaign.py --reads-only \
  --output ../documentation/performance-evidence/YYYY-MM-DD/api-campaign
```

The runner accepts `DDM_ALB_COOKIE_HEADER` in its process environment. On macOS
it can sign in through the existing Cognito hosted login using the dedicated
E2E Keychain entry. Credentials stay in memory or the child environment; they
are not printed or saved. Do not enable HTTP debug logging. Local integration
tests require permission to bind a loopback listener.

Static inspection covers all seven profiles. Tests exercise fragmented echo,
stale markers, timeouts, packet constants, workload bounds, interruption
cleanup, resource checks and nonzero/aborted report status. Real local k6 runs
validate the WebSocket fixture and failure reporting before AWS execution.

## Evidence and limitations

Run directories contain `run.json`, `result.json`, `summary.json`,
`metrics.jsonl`, `report.html`, `k6.log`, resource samples, availability probes,
authenticated inventory and cleanup/recovery records. `result.json` is the
process outcome: thresholds cannot override an abort or nonzero exit.
Source snapshots, hashes, deployed image digests and UTC timestamps provide
reproduction context. `tools/build_evidence.py` derives comparable run tables.

CloudWatch is captured at fixed ranges matching runs. The exporter saves
original widget definitions, native chart images and underlying metric data.
Supplemental charts use verified Container Insights dimensions for CPU/memory
relative to container limits and `DendenMushi/TargetHost` dimensions for target
resources. The original dashboard is preserved. Its node-utilization,
target-host and some ALB health/error series are missing for the pilot interval;
absent series are not measured zeros. The custom `DenDenMushi` namespace has no
available metrics and `kubectl top` is unavailable. Concurrency therefore uses
authenticated session inventory plus client connection accounting.

The evidence index, screenshots and labelled video walkthrough describe only
recorded results. A01, A07 and R13 stay individually open wherever required
measurements are missing. R14 fault injection remains separate. “No saturation
observed within the tested range” applies only after the bounded terminal range
completes without saturation.


## 15 October result and rerun prerequisite

Browser echo, retained input after rejoin and read-only observation passed.
Both attributed session records are CLOSED. Capacity recovery failed: zero
active metadata coexisted with one accounted slot beyond five minutes. The
runner now rejects this mismatch during baseline and records
`baseline-capacity.json`; no new session is opened by that check.

There are zero timed SSH runs and zero latency samples. Browser resize and the
post-campaign check remain unverified. No application image or resource limit
was changed. The final harness passes 31 local tests and all seven profiles
inspect successfully; those fixture results are not AWS capacity evidence.

Resolve the accounting defect, verify zero attributed sessions and correctly
released capacity, then use a fresh approved window and output directory for
a new campaign. Preserve this failed attempt. Historical API repetitions remain
incomplete (Agentic 1/3, Audit 2/3), despite all 37,856 completed requests succeeding.
