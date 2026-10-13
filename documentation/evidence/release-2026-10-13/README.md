# DenDenMushi release evidence 13 October 2026

This index records the implementation and acceptance of review items **1, 3, 5, 7 and 9**: enforced security gates, nine usable API contracts, published evaluated source, verified dataplane identity and deployment by digest. It supports the capstone submission's system design, API design, CI/CD, testing and reproducibility claims.

The final tested application release is Kubernetes commit [`508c2e1ae56add8d16ef2b33f9b9b5447439c7df`](https://github.com/NUS-MTech-Capstone/kubernetes/commit/508c2e1ae56add8d16ef2b33f9b9b5447439c7df). Argo CD was **Synced/Healthy**, all twelve deployments were ready, all declared/runtime digests agreed and all nine application image revision labels matched their merged source commits. Later documentation-only commits do not change these application identities.

Live terminal traffic remains browser → assigned Proxy Dataplane → SSH target. STS capabilities, both ownership identifiers and human approval over the exact stored remediation plan hash remain enforced. No Terraform apply or ECR mutability change was needed.

## Source to release chain

The service name links to its merged source PR. CI and Image links are successful runs at the exact merged source SHA. Every project image caller pins shared workflows at [`0a2ab816ffd50e835f0d3553343f544f59f4b41b`](https://github.com/NUS-MTech-Capstone/github-actions-shared/commit/0a2ab816ffd50e835f0d3553343f544f59f4b41b). Commit tags remain traceability labels; GitOps deploys the digest returned by the image build.

| Service source PR | Merged source SHA | Deployed image digest | Passing runs | Promotion PR |
|---|---|---|---|---|
| [agent-controlplane](https://github.com/NUS-MTech-Capstone/agent-controlplane/pull/5) | [`7db45a38a69cd55b929e8523d8a26e272d7baf11`](https://github.com/NUS-MTech-Capstone/agent-controlplane/commit/7db45a38a69cd55b929e8523d8a26e272d7baf11) | `sha256:bfc9b2bf6d33099d5f084b7cf849e7b841f900387eaeb3756c9a7a31c8161939` | [CI](https://github.com/NUS-MTech-Capstone/agent-controlplane/actions/runs/38339757805) / [Image](https://github.com/NUS-MTech-Capstone/agent-controlplane/actions/runs/38340037112) | [#189](https://github.com/NUS-MTech-Capstone/kubernetes/pull/189) |
| [incident-agent](https://github.com/NUS-MTech-Capstone/incident-agent/pull/6) | [`a1791818c6d57e46de8825e3c56df7b0742c99a7`](https://github.com/NUS-MTech-Capstone/incident-agent/commit/a1791818c6d57e46de8825e3c56df7b0742c99a7) | `sha256:dd1d6b1197cdbf48aadb62fc7dd55a1b4ba7c6e26c7eef958ed4e537974c880b` | [CI](https://github.com/NUS-MTech-Capstone/incident-agent/actions/runs/38342957769) / [Image](https://github.com/NUS-MTech-Capstone/incident-agent/actions/runs/38343060292) | [#194](https://github.com/NUS-MTech-Capstone/kubernetes/pull/194) |
| [audit-service](https://github.com/NUS-MTech-Capstone/audit-service/pull/4) | [`5790b111d85fbf413bd39177f25f22cc2b81033f`](https://github.com/NUS-MTech-Capstone/audit-service/commit/5790b111d85fbf413bd39177f25f22cc2b81033f) | `sha256:0e17fc217812a8fe0877579a2ac5335ec520ef1cd74f7f6228c50bd8fdfda1a0` | [CI](https://github.com/NUS-MTech-Capstone/audit-service/actions/runs/38339746053) / [Image](https://github.com/NUS-MTech-Capstone/audit-service/actions/runs/38339983068) | [#188](https://github.com/NUS-MTech-Capstone/kubernetes/pull/188) |
| [proxy-controlplane](https://github.com/NUS-MTech-Capstone/proxy-controlplane/pull/6) | [`39159c3c56a2899291894275abc78ccd52820cbb`](https://github.com/NUS-MTech-Capstone/proxy-controlplane/commit/39159c3c56a2899291894275abc78ccd52820cbb) | `sha256:55f717ba988bf86e9091cc14b4c196c56ea8f6d97f61daebf0f8f5798d421d5e` | [CI](https://github.com/NUS-MTech-Capstone/proxy-controlplane/actions/runs/38340307448) / [Image](https://github.com/NUS-MTech-Capstone/proxy-controlplane/actions/runs/38340484117) | [#191](https://github.com/NUS-MTech-Capstone/kubernetes/pull/191) |
| [proxy-dataplane](https://github.com/NUS-MTech-Capstone/proxy-dataplane/pull/4) | [`ae0e0a2841b8c91c12ef71118889158600d6a577`](https://github.com/NUS-MTech-Capstone/proxy-dataplane/commit/ae0e0a2841b8c91c12ef71118889158600d6a577) | `sha256:519eea110ce4a4a8f091fef291e6ceb4b4d7ef97f62afd6fedc90643cfa48521` | [CI](https://github.com/NUS-MTech-Capstone/proxy-dataplane/actions/runs/38339751945) / [Image](https://github.com/NUS-MTech-Capstone/proxy-dataplane/actions/runs/38339949438) | [#186](https://github.com/NUS-MTech-Capstone/kubernetes/pull/186) |
| [session-manager](https://github.com/NUS-MTech-Capstone/session-manager/pull/3) | [`9948d1e1ddeda365b6da140d6928f2143c86ff2a`](https://github.com/NUS-MTech-Capstone/session-manager/commit/9948d1e1ddeda365b6da140d6928f2143c86ff2a) | `sha256:744d259cd756e6584a5eb902d3be27e278f77e8d8f13c352d54dd3576edbb0b0` | [CI](https://github.com/NUS-MTech-Capstone/session-manager/actions/runs/38339739695) / [Image](https://github.com/NUS-MTech-Capstone/session-manager/actions/runs/38339934389) | [#187](https://github.com/NUS-MTech-Capstone/kubernetes/pull/187) |
| [sts](https://github.com/NUS-MTech-Capstone/sts/pull/7) | [`4298602090628793d72be806b19cbe64989f5562`](https://github.com/NUS-MTech-Capstone/sts/commit/4298602090628793d72be806b19cbe64989f5562) | `sha256:da7a33090476e906d214101b0ea1375651f49d59f2c54ac4f99acfa898fb97d2` | [CI](https://github.com/NUS-MTech-Capstone/sts/actions/runs/38339732648) / [Image](https://github.com/NUS-MTech-Capstone/sts/actions/runs/38339941651) | [#184](https://github.com/NUS-MTech-Capstone/kubernetes/pull/184) |
| [angular](https://github.com/NUS-MTech-Capstone/angular/pull/11) | [`34e7f3fda050bc7b2f401570825fe2ed1b9cd742`](https://github.com/NUS-MTech-Capstone/angular/commit/34e7f3fda050bc7b2f401570825fe2ed1b9cd742) | `sha256:d7a39cd1372b8d3f69eb0db94bdcf70de6eaf116333aef2993375f4a84454a32` | [CI](https://github.com/NUS-MTech-Capstone/angular/actions/runs/38339769853) / [Image](https://github.com/NUS-MTech-Capstone/angular/actions/runs/38339937785) | [#185](https://github.com/NUS-MTech-Capstone/kubernetes/pull/185) |
| [nest-backend](https://github.com/NUS-MTech-Capstone/nest-backend/pull/4) | [`879a6b540cdcccff9c58f9fc0f52de9e35ad9fa6`](https://github.com/NUS-MTech-Capstone/nest-backend/commit/879a6b540cdcccff9c58f9fc0f52de9e35ad9fa6) | `sha256:ef36e4cb4579a9a656b093ee1f40a11c2ba072aea3eadf54a2d48aa91e31cec1` | [CI](https://github.com/NUS-MTech-Capstone/nest-backend/actions/runs/38340301464) / [Image](https://github.com/NUS-MTech-Capstone/nest-backend/actions/runs/38340362918) | [#190](https://github.com/NUS-MTech-Capstone/kubernetes/pull/190) |

Incident Agent's image is used by the coordinator, Reasoning Agent and Tool Gateway. Redis retained `sha256:2d3814be5e9b06a30a0be54770b7e12052e7e79ec85271aefd34875c1f393b23`. DDM Agent source/contracts were merged in [PR #3](https://github.com/NUS-MTech-Capstone/ddm-agent/pull/3), commit `437c7a7b404a46550643bc901d2746a37d7b466e`, with [passing CI](https://github.com/NUS-MTech-Capstone/ddm-agent/actions/runs/38339763448); it is not deployed in the working SSH path.

Full machine-readable records: [source labels](image-source-labels.json), [CI runs](ci-runs.json), [source/configuration PRs](merged-services.json), [initial promotion commits](merged-promotions.json), [promotion diffs](promotions/), [rendered final manifests](final-manifests.yaml) and [runtime digest verification](runtime-digests-final.txt).

| Shared or deployment change | Merged PR and revision |
|---|---|
| Fail-closed scan gates, API validation and promotion foundations | [Shared #2](https://github.com/NUS-MTech-Capstone/github-actions-shared/pull/2), `83d1109e7fe45f82af48b0060bb6f25039327020` |
| Digest migration compatibility and caller pin | [Shared #3](https://github.com/NUS-MTech-Capstone/github-actions-shared/pull/3), `0a2ab816ffd50e835f0d3553343f544f59f4b41b` |
| Controlled CI gate acceptance fixtures | [Shared #4](https://github.com/NUS-MTech-Capstone/github-actions-shared/pull/4), `586452037bb072ea3e774bcbe49e12a811cd68e1` |
| Identity configuration deployed before strict dataplane | [Kubernetes #183](https://github.com/NUS-MTech-Capstone/kubernetes/pull/183), `5cbf62a8a3ab49038340191f6bf490b2f307d7af` |
| Strict rendered/runtime digest verification | [Kubernetes #193](https://github.com/NUS-MTech-Capstone/kubernetes/pull/193), `1340d72e2cb7766bc86cfb463bdea98fa7adfa35` |
| Installed-wheel API resource fix and final Incident image | [Incident #6](https://github.com/NUS-MTech-Capstone/incident-agent/pull/6), [Kubernetes #194](https://github.com/NUS-MTech-Capstone/kubernetes/pull/194), `715fffc31e12aa1f56f1f76335dc729c513d3f49` |

## Acceptance matrix

**Live** means executed against AWS dev or the authenticated browser. **Isolated** means deterministic fixtures, actual local handlers or disposable PostgreSQL. Results are bounded to the stated scenarios, not a claim that every possible failure was tested.

| Acceptance scenario | Result and scope | Evidence |
|---|---|---|
| Relevant Go tests and races | PASS, seven Go repositories; patched Go 1.26.9 and compatible dependencies; no reachable govulncheck findings | [Repository logs and scan JSON](repository-checks/) and source CI above |
| Session Manager PostgreSQL | PASS, race-enabled suite using disposable PostgreSQL 16; store tests executed | [PostgreSQL log](session-manager-postgres-isolated.txt) |
| Incident lint, types, tests, migrations and evaluations | PASS; local pre-wheel suite 146 passed/7 environment skips; final packaging revision's CI also passed, including dedicated PostgreSQL migrations/claims and wheel regression | [Local suite](incident-agent-tests.txt), [final CI](https://github.com/NUS-MTech-Capstone/incident-agent/actions/runs/38342957769), evaluations below |
| Nest tests/build and Angular tests/build | PASS: Nest 40 suites/284 tests; Angular 28 files/211 tests; both builds passed | [Nest tests](nest-tests.txt), [build](nest-build.txt), [Angular tests](angular-tests.txt), [build](angular-build.txt) |
| Shared workflows and rendered manifests | PASS: shared 30 tests/268 assertions; Kubernetes image identity tests and strict Kustomize verification passed | [Shared CI](https://github.com/NUS-MTech-Capstone/github-actions-shared/actions/runs/38340436334), [release manifest CI](https://github.com/NUS-MTech-Capstone/kubernetes/actions/runs/38343878106) |
| Security clean, finding, malformed and scanner-error cases | PASS: clean gates succeeded; each negative fixture failed both Go/Node gates, retained artifacts and skipped downstream release eligibility | [Fixture runs and retained artifacts](security-gates/) |
| Failed CI cannot publish/promote | PASS within controlled gate fixture and caller workflow conditions: image requires successful CI on main; promotion needs a successful image build. Fixtures have no image publishing credentials | [Shared fixture workflow](https://github.com/NUS-MTech-Capstone/github-actions-shared/blob/586452037bb072ea3e774bcbe49e12a811cd68e1/.github/workflows/security-gate-acceptance.yaml), [run/job outcomes](security-gates/runs.json) |
| All nine OpenAPI specifications | PASS, `openapi-spec-validator==0.9.0` in every owning CI; handler response schemas and served bytes covered in contract tests | Source CI above; [Go contract logs](repository-checks/), [Nest suite](nest-tests.txt), [Incident final CI](https://github.com/NUS-MTech-Capstone/incident-agent/actions/runs/38342957769) |
| Live API success/errors, versions and served specs | PASS, 37 checks across eight deployed APIs: health/readiness exemptions, exact served spec bytes, missing/invalid versions, dataplane missing/forged identity | [Live API results](live-api-contracts.json); DDM's ninth spec covered locally/CI |
| Missing/invalid approval and rejection hashes; stale plan | PASS, isolated actual handlers/service tests reject absent/malformed/stale hashes; no live mutation with forged approval | [Agent contract log](agent-controlplane-final-contracts.txt), [R12 contracts](evaluations/r12-contracts-committed-02/) |
| Verified terminal identity | PASS, signed fixtures cover absent/forged/expired identities, wrong signer/client/issuer/algorithm, subject/header mismatch and key failures; valid STS capability cannot substitute for verified identity | [Dataplane identity log](proxy-dataplane-final-identity.txt), [signed test fixtures](https://github.com/NUS-MTech-Capstone/proxy-dataplane/blob/ae0e0a2841b8c91c12ef71118889158600d6a577/internal/httpapi/cognito_test.go), [race suite](repository-checks/proxy-dataplane-race-tests.txt) |
| Identity/STS/session/action/mode and both owner IDs | PASS, isolated mismatched-user, stale-instance, token/action/mode and observer-write denials | [Dataplane service tests](https://github.com/NUS-MTech-Capstone/proxy-dataplane/tree/ae0e0a2841b8c91c12ef71118889158600d6a577/internal/service), [race suite](repository-checks/proxy-dataplane-race-tests.txt) |
| Cognito browser SSH start, I/O and resize | PASS, live; PTY resized from 19×80 to 28×98 | [Browser results](browser-ssh.json) |
| Detach/rejoin and read-only observe | PASS, live; shell state preserved, observer received output and attempted input did not change owner state | [Browser results](browser-ssh.json) |
| Termination, capacity release, retained audit | PASS, live; session CLOSED, activeSessions 0, 31 retained audit records with sequence 1–31; terminal contents excluded | [Lifecycle metadata](live-lifecycle-metadata.json) |
| Incident reads and exact-plan approved execution | PASS, live real CloudWatch demo-app alarm; explicitly approved stored hash, one `recover_demo_app`, fixed `service_status`/`health_check`, all exit 0 | [Agent browser results](live-agent-browser.json) |
| Rejection and cleanup | PASS, live separate synthetic incident REJECTED with zero remediation; approved automation run CLOSED. Failure cleanup/TTL fallback covered in isolated tests | [Agent results](live-agent-browser.json), [lifecycle metadata](live-lifecycle-metadata.json), [R12 contracts](evaluations/r12-contracts-committed-02/) |
| Committed source → CI → digest → GitOps → healthy runtime | PASS, live; nine OCI revision labels match merged source, twelve runtime/declared digest matches | Release table, [image labels](image-source-labels.json), [runtime digests](runtime-digests-final.txt), [AWS verifier](verify-aws-final.txt) |
| Image index versus platform digest relationship | PASS isolated resolver tests; live runtimes reported the declared digest directly, so no different platform-child digest was observed | [Kubernetes tests](https://github.com/NUS-MTech-Capstone/kubernetes/blob/1340d72e2cb7766bc86cfb463bdea98fa7adfa35/test/image_digests_test.rb) |
| Controlled rollback and restore | PASS, live Angular-only rollback through PR #195 then restoration through #196; Argo health and authenticated SSH I/O passed on both | [Rollback results](rollback-browser.json), [restored results](restored-browser.json) |

### Security gate fixtures

These runs invoke the production gate steps with synthetic scanner outputs. They test gate semantics and job dependencies without publishing a deliberately vulnerable image. Missing reports, package-only findings, caller overrides and digest migration also have local workflow behavioural coverage.

| Fixture | Run | Expected result | Retained Go and Node artifacts |
|---|---|---|---|
| Clean | [38340490738](https://github.com/NUS-MTech-Capstone/github-actions-shared/actions/runs/38340490738) | Gates and release eligibility pass | Yes |
| Reachable vulnerability / Semgrep finding | [38340494359](https://github.com/NUS-MTech-Capstone/github-actions-shared/actions/runs/38340494359) | Gates fail; release eligibility skipped | Yes |
| Malformed report | [38340498025](https://github.com/NUS-MTech-Capstone/github-actions-shared/actions/runs/38340498025) | Gates fail; release eligibility skipped | Yes |
| Scanner error | [38340500897](https://github.com/NUS-MTech-Capstone/github-actions-shared/actions/runs/38340500897) | Gates fail; release eligibility skipped | Yes |

Go evaluates symbol-level reachability after retaining the JSON stream and fails closed on scanner/report errors. Semgrep findings-as-errors remain enforced even with caller overrides. LangGraph SDK was updated to 0.4.7 after the newly enforced audit exposed the earlier version. Nest retains four moderate transitive Umzug CLI-chain findings under an exact reviewed exception expiring **7 November 2026**; they are not blanket-suppressed or described as fixed. See [native audit](nest-audit-native.json), [retained audit](nest-audit-retained.json), [policy tests](nest-audit-policy.txt) and [Incident audit](incident-agent-patched-audit.json).

## Evaluations

The published Incident Agent evaluation/model-tracing implementation is identifiable as commit [`ec816d4`](https://github.com/NUS-MTech-Capstone/incident-agent/commit/ec816d4). Agent Control Plane's bounded cleanup and executor tests are identifiable as [`c23ffb7`](https://github.com/NUS-MTech-Capstone/agent-controlplane/commit/c23ffb7). Existing local work was backed up, then relevant changes were carried onto remote default branches; unrelated edits were not published.

| Campaign | Result | Exact source identity | Durable evidence |
|---|---|---|---|
| R12 deterministic rules | 24/24, no provider calls | Incident `3c73fc077878986cba9c206f6a7b96f4178ef1cb` | [Manifest and results](evaluations/r12-rules-committed/) |
| R12 contracts first attempt | 55/56; disposable database naming guard rejected the fixture database | Incident `aca8833d7e2bf37ad7706bb879a25a93cbfb9c8b` | [Preserved failed attempt](evaluations/r12-contracts-committed/) |
| R12 contracts corrected fixture | 56/56, including all 30 role/category cases and PostgreSQL boundaries | Incident `aca8833d7e2bf37ad7706bb879a25a93cbfb9c8b` | [Manifest and results](evaluations/r12-contracts-committed-02/) |
| R12 bounded gateway | 72/72 stages, 12 scenarios × 3 repetitions × triage/plan, no fallback | Incident `3c73fc077878986cba9c206f6a7b96f4178ef1cb` | [Manifest and results](evaluations/r12-gateway-committed/) |
| R16 rules and pinned models | Rules 20/20; GPT-5.4 20/20; GPT-5.5 20/20; 40 scored provider calls, no fallback | Incident `aca8833d7e2bf37ad7706bb879a25a93cbfb9c8b` | [Manifest and results](evaluations/r16-models-committed/) |
| Metadata-only tracing | Six spans submitted/read back; empty inputs/outputs, no errors or dropped spans | Same R16 source; two controlled replay roots | [Readback](evaluations/r16-models-committed/trace-readback.json), [export](evaluations/r16-models-committed/trace-export.json) |

R12 companion sources are Agent Control Plane `321d6d4b142f3589fedaa5daa6f7c8aa5d193569` and Proxy Dataplane `6a98eda4d96f0d842dbf0a4628f5181d03772114`; all manifests record clean working trees and per-file source/corpus/prompt/catalog hashes. These are evaluated commits, not relabelled as later merge commits.

[The evaluated-to-deployed comparison](evaluated-source-comparison.json) confirms all recorded Agent Control Plane and Proxy Dataplane files are identical to the deployed source. Incident Agent differs only in `api/web.py`, `tests/test_openapi_contract.py` and `pyproject.toml`, for the separately tested installed-wheel specification fix. Its recorded reasoning, evaluation, prompt and catalog files are identical. A private sibling-repository CI checkout attempt failed and was reverted; cross-repository contracts were run against committed local checkouts and disposable PostgreSQL instead. Deployment credentials were not repurposed for checkout access.

### Historical evidence

[October 7 manifests and sanitized results](historical-2026-10-07/) retain their original revisions, dirty-state/source hashes and outcomes. In particular, the earlier GPT-5.5 **19/20** result is preserved separately from October 13's **20/20**. Historical results must not be attributed to the new release. Each curated results file includes a hash of the original result bytes in its summary.

## Live release and recovery sequence

1. Applied authentication configuration via PR #183 before the strict dataplane image. [Pre-rollout session metadata](pre-rollout-sessions.json) confirmed no active sessions before the `Recreate` rollout.
2. Merged passing digest promotions #184–#192. Argo reconciled the release; the first live contract pass exposed the Incident Agent wheel's missing API resource. PR #6 fixed packaging and added an installed-wheel regression; promotion #194 deployed it. The final live contract run passed 37/37.
3. Used explicitly approved **CR-D2D67FEE**, 13 October 11:25–17:25 SGT, for existing Admin/demo-operator access to `host-dev-1`. Session `sess-16f25b2c2f6cb89dd829fd706501067b` passed the SSH acceptance matrix and was closed.
4. Human confirmation approved incident `inc-0546b7d99bd1e255fb21db6d2de2daaa` over exact hash `4c0b8593381e5dd589e7349ee0c8d7e1a9b200b1b91f523bf5046d6c0c347891` before expiry. One bounded recovery operation and fixed verification completed. Run `run-d7c855d6c33b2060d132996c8fc4f71b` closed. Separate synthetic incident `inc-daec9024997764c3e584fcfa065afad1` was rejected without remediation.
5. [Rollback PR #195](https://github.com/NUS-MTech-Capstone/kubernetes/pull/195), merge `a4d9ef13a4d5467e318d87e0fafc7f8ccc3b8015`, restored Angular to known-good `sha256:bdbd890a2a5a13c179b1a214d0761decd549ad0f1f8b2b910e95a80117cfc4e0`. Argo Synced/Healthy and browser SSH I/O passed.
6. [Restore PR #196](https://github.com/NUS-MTech-Capstone/kubernetes/pull/196), merge `508c2e1ae56add8d16ef2b33f9b9b5447439c7df`, restored the final Angular digest. Health, authenticated browser SSH I/O and twelve runtime digest relationships passed. `verify-aws.sh` exited 0, including network-policy allow/deny and inventory checks. [Passive DAST run](https://github.com/NUS-MTech-Capstone/kubernetes/actions/runs/38343878208) also succeeded; this is not a penetration-test claim.

Browser captures retain the [completed incident](screenshots/live-incident-completed.jpg) and [released SSH capacity](screenshots/ssh-capacity-released.jpg), without terminal contents.

The recovery exercise changed Angular only. Backend and strict dataplane identity stayed deployed. It does not demonstrate full-stack rollback, database restoration or disaster recovery.

## Reproduction

Check out the exact source SHAs above into sibling repositories. For the historical/evaluation campaigns, use the distinct SHAs recorded by that campaign's manifest. Follow the owning README prerequisites; do not run destructive database tests against application databases.

```bash
# From each Go service repository, with its patched toolchain:
go test -race ./...
# From Session Manager, using disposable PostgreSQL:
make test-postgres
# From Nest Backend:
npm ci
npm test -- --runInBand
npm run build
# From Angular:
npm ci
npm test -- --watch=false
npm run build
# From Incident Agent:
uv sync --all-extras
uv run ruff check .
uv run mypy src
uv run pytest
# From github-actions-shared:
ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |file| require File.expand_path(file) }'
# From Kubernetes:
ruby test/image_digests_test.rb
kubectl kustomize apps/dendenmushi/overlays/dev > /tmp/ddm-rendered.yaml
ruby scripts/verify-image-digests.rb /tmp/ddm-rendered.yaml
AWS_PROFILE=capstone ./scripts/verify-aws.sh
```

API specs live at `api/openapi.yaml` in their owning repositories. Their CI installs the pinned validator and validates the same served file. [Incident Agent's README](https://github.com/NUS-MTech-Capstone/incident-agent/blob/a1791818c6d57e46de8825e3c56df7b0742c99a7/README.md#evaluation-baseline) provides the opt-in bounded provider/evaluation commands, fresh output-directory rule, pacing, hard budgets and disposable database requirements. Live browser scenarios require an approved access window; live remediation requires a fresh human-approved stored hash. Re-running evidence collection is not permission to reuse an expired approval.

## Scope and limitations

- Error/destructive cases use isolated fixtures; no broad AWS outage injection or separate SSH stress campaign was performed.
- The evaluation corpus is small and synthetic with fixed engineering assertions. It does not establish human-labelled accuracy, production capacity or statistical model superiority. Stage durations include pacing.
- DDM Agent has contract/CI coverage but is not the live SSH/PTY transport.
- Runtime parent/index digest references matched directly in this deployment. The different platform-child resolution branch is covered by isolated tests only.
- Docker's local storage limitation was handled with a disposable, memory-backed PostgreSQL pod in AWS dev. The fixture pod was deleted; no application data was pruned.
- The Nest moderate dependency exception remains time-limited as described above. Scanner artifacts retain the findings.
- The failed private checkout attempt and the database-guard failed run remain distinguishable from successful reruns.
- Original local user changes and unrelated pending promotions were left untouched.

## Submission artifacts and sanitization

[AGENTIC_AI_FEATURES.md](../../AGENTIC_AI_FEATURES.md) records the updated boundaries, evaluated behavior and release evidence. The affected API, identity, CI/CD, evaluation and release sections of **Fully Merged 10 Updated.docx** were edited, rendered and visually inspected across all 173 pages. [Report hashes and QA record](report-artifact.json) distinguish the updated deliverable from the preserved original. The DOCX is delivered separately; it is not embedded in this Git repository.

This bundle contains metadata, assertion outcomes, test logs, scan reports and rendered public configuration references. It excludes credential values, tokens, private keys, raw terminal input/output, raw model/provider payloads and captured audit content. Local workspace/kubeconfig paths in copied logs are normalized. Evaluation manifests preserve their original identities; result bodies are reduced to allowlisted metadata, with original-byte hashes retained. Malformed scanner reports are intentionally malformed fixture artifacts.

[SHA256SUMS](SHA256SUMS) covers every retained file except itself. Git history binds the index and evidence to the documentation commit. GitHub artifacts have finite retention; the sanitized files here remain part of the repository submission.
