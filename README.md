# Smart-Factory AI Platform

Azure infrastructure and deployment machinery for the smart-factory suite. Two
ML services share one substrate, one identity model, and one deployment
pipeline — defined as code, deployed by CI, and observable in production.

This repo does not contain a model. It contains what the models run on.

```
                       ┌──────────────────────────────────────────┐
   GitHub Actions      │            Resource group                │
   (OIDC, no secret)   │                                          │
          │            │   ACR ──────┐                            │
          │  az acr    │             │ AcrPull (managed identity) │
          ├──build────►│             ▼                            │
          │            │   Container Apps environment             │
          │            │     ├── rag      (maintenance RAG)       │
          │  az        │     └── defect   (surface inspection)    │
          ├──deploy───►│             │                            │
          │            │             │ Key Vault Secrets User     │
          │            │   Key Vault ┘                            │
          │            │                                          │
          │            │   Log Analytics ◄── App Insights ◄── OTel│
          └────────────┤                                          │
            smoke test │                                          │
            + rollback └──────────────────────────────────────────┘
```

## What is actually here

**Infrastructure as code** — `infra/`, Bicep, five modules and one entrypoint.
The whole platform is `az deployment group create` and one parameter file.
Adding a third service is one `module` block, not a new stack.

**Identity-based auth throughout** — ACR has its admin account disabled. Each
service holds a user-assigned managed identity with exactly two role
assignments: pull its images, read its own secrets. GitHub authenticates by
OIDC federated credential. **There is no password, connection string, or
service-principal secret anywhere in these three repositories.**

**A reusable deployment workflow** — `.github/workflows/deploy-service.yml` is
called by each service repo. Deployment policy is defined once: SHA-tagged
images, never `:latest`; a smoke test that retries through cold starts and
checks the response body rather than trusting a 200; automatic rollback to the
previous revision when a new one comes up unhealthy.

**A retrieval-quality gate** — `manufacturing-maintenance-rag` cannot deploy if
retrieval regressed. Full rationale below.

**Distributed tracing** — both services emit OpenTelemetry spans to Application
Insights, instrumented where the interesting questions are rather than
everywhere. Degrades to a no-op when unconfigured, so local runs, CI and the
existing Render deployments are unchanged.

**Cost control as a design constraint** — scale-to-zero, capped max replicas,
a 1 GB/day log ingestion cap, `/health` excluded from tracing. Documented in
[`docs/RUNBOOK.md`](docs/RUNBOOK.md).

## The quality gate

A RAG service can degrade badly without failing a single test. Re-chunk the
corpus, change the embedding dimension, add a document — the API still returns
200, the guardrail still fires, the suite is still green, and retrieval quality
has silently dropped. There is no exception for a unit test to catch.

So retrieval quality is a release criterion, checked by
`scripts/gate_retrieval.py` in CI and again before deploy:

- an **absolute floor** (MRR ≥ 0.75, hit@3 ≥ 0.85), so slow drift downward
  cannot be ratified one acceptable-looking step at a time;
- a **relative tolerance** against the committed baseline (no metric may fall
  more than 0.05), so a single change that makes things suddenly worse fails
  even while still above the floor;
- **every metric** is compared, not just the headline — a change can leave MRR
  flat while hollowing out recall@5.

Measured baseline: **MRR 0.853, hit@3 0.933** over 30 labelled questions.
Improving retrieval means re-running with `--update-baseline` and committing the
new numbers in the same PR — so a quality change is always visible in review.

## What the tracing is for

Instrumented at the decision points, not uniformly:

| Span | Attributes | Question it answers |
|---|---|---|
| `rag.retrieve` | `top_score`, `hit_count`, `k` | Is retrieval the slow half? |
| `rag.generate` | `mode` | Which fallback tier actually served this? |
| `rag.guardrail_refused` | `top_score`, `min_score` | What are users asking that the corpus doesn't cover? |
| `inspect.baseline` | `label`, `confidence` | What does the classical model cost? |
| `inspect.deep` | `label`, `confidence`, `agrees_with_baseline` | Do the two models still agree on live traffic? |

Two of these earn their place on their own. `rag.generate.mode` reading
`offline_extractive` while an API key is configured means the LLM call is
failing and being swallowed by the fallback — the service returns 200
throughout, so nothing else would tell you. And `inspect.agrees_with_baseline`
turns a 97.1%-vs-99.6% comparison measured on a static split into something
monitorable on live traffic, where a falling agreement rate is an early drift
signal.

KQL for all of these is in [`docs/RUNBOOK.md`](docs/RUNBOOK.md).

## Repository layout

```
infra/
  main.bicep              the platform, composed
  main.bicepparam         parameters
  modules/
    monitoring.bicep      Log Analytics + workspace-based App Insights
    registry.bicep        ACR, admin account disabled
    keyvault.bicep        RBAC vault (no secret values in any template)
    environment.bicep     Container Apps managed environment
    service.bicep         one service: identity, 2 role assignments, app
.github/workflows/
  infra.yml               build + lint on PR, what-if preview, apply from main
  deploy-service.yml      reusable; called by each service repo
scripts/
  bootstrap_oidc.sh       one-time GitHub↔Azure federation setup
docs/
  RUNBOOK.md              deploy, observe, troubleshoot, tear down
```

## Getting started

See [`docs/RUNBOOK.md`](docs/RUNBOOK.md). Short version:

```bash
az login
./scripts/bootstrap_oidc.sh                     # one-time
az deployment group create \
  --resource-group rg-smart-factory \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam
```

Then push to either service repo and CD takes over.

## Services on the platform

| Service | Repo | What it does |
|---|---|---|
| `rag` | [manufacturing-maintenance-rag](https://github.com/SelenaG4/manufacturing-maintenance-rag) | FAISS retrieval over maintenance guides, grounded cited answers, MRR 0.853 |
| `defect` | [surface-defect-inspector](https://github.com/SelenaG4/surface-defect-inspector) | NEU steel-surface defect classification, LBP+SVM 97.1% vs EfficientNet 99.6% |

## Validation status

Templates compile and lint clean (`bicep build`, `bicep lint`, zero warnings).
Workflows lint clean (`actionlint`). Service test suites: RAG 27/27, defect
15/15, both including new tests for the gate and the tracing no-op path.

**Not yet deployed to a live subscription.** Everything here is validated
statically and the application layer is tested end to end, but the Azure
resources have not been stood up. See the runbook.

## What I would add next

- **Staging as a real environment.** Right now `production` is the only gated
  environment and staging is a parameter value. A second resource group with
  traffic-split revisions would make the promotion path real rather than
  nominal.
- **Alerts, not just dashboards.** The KQL queries in the runbook have to be
  run by a human. The guardrail-refusal rate and the model agreement rate both
  deserve to page someone instead.
- **Per-secret Key Vault scoping.** Secrets User is granted at vault scope,
  which is proportionate for two services that trust each other and would not
  be for twenty.
- **A cost dashboard.** Ingestion is capped, but nothing currently reports spend
  per service.
