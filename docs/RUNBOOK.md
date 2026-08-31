# Runbook

Everything needed to stand the platform up, deploy to it, watch it, and tear it
down. Written to be followed in order the first time.

---

## 0. Before you start

You need:

- An Azure account. The free tier gives **USD 200 of credit valid for 30 days**,
  plus a set of always-free service allowances that continue afterwards.
- **Azure CLI** — `az version` should print something.
- A GitHub account with push access to the three repos.

Log in and confirm which subscription you are pointed at, because this is the
single easiest thing to get wrong:

```bash
az login
az account show --output table
az account set --subscription "<subscription-id>"    # only if you have several
```

Register the resource providers this platform uses. First-time subscriptions do
not have them enabled, and the failure mode is a confusing `MissingSubscription
Registration` error several minutes into the first deploy:

```bash
for provider in Microsoft.App Microsoft.ContainerRegistry Microsoft.KeyVault \
                Microsoft.OperationalInsights Microsoft.Insights \
                Microsoft.ManagedIdentity; do
  az provider register --namespace "$provider"
done

# Registration is asynchronous. Wait until every row reads "Registered".
az provider list --query "[?namespace=='Microsoft.App'].registrationState" -o tsv
```

---

## 1. Put a spending guard in place first

Do this **before** deploying anything. A budget alert is not a hard stop, but it
is the difference between noticing on day two and noticing when the credit is
gone.

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)

az consumption budget create \
  --budget-name smart-factory-guard \
  --amount 50 \
  --time-grain Monthly \
  --category Cost \
  --start-date "$(date -u +%Y-%m-01)" \
  --end-date "$(date -u -d '+1 year' +%Y-%m-01)" \
  --scope "/subscriptions/${SUBSCRIPTION_ID}"
```

If that CLI command is unavailable on your version, set it in the portal:
**Cost Management + Billing → Budgets → Add**. Add an email alert at 50%.

**What actually costs money here**

| Resource | Cost posture |
|---|---|
| Container Apps | Consumption plan, `minReplicas: 0`. Idle apps cost nothing. There is a monthly free grant of request and compute time. |
| Container Registry | Basic SKU, a fixed few francs per month. The one guaranteed line item. |
| Log Analytics | Per GB ingested, with a free monthly allowance. Capped at **1 GB/day** in `monitoring.bicep`. |
| Key Vault | Per-operation, effectively free at this volume. |
| Managed identities | Free. |

The realistic bill for an idle portfolio platform is a few francs a month,
dominated by ACR. The `dailyQuotaGb` cap exists because a container stuck in a
crash-restart loop writing to stderr is a genuine way to lose a trial credit
overnight.

---

## 2. Wire up GitHub → Azure authentication

```bash
git clone https://github.com/SelenaG4/smart-factory-platform.git
cd smart-factory-platform
chmod +x scripts/bootstrap_oidc.sh
./scripts/bootstrap_oidc.sh
```

Follow the instructions it prints: add the three values as repository secrets in
**all three** repos, and create a `production` environment with yourself as a
required reviewer in each.

No secret ever leaves Azure. The three values are identifiers; they are useless
without a token GitHub mints for one of the registered federated subjects.

---

## 3. Deploy the platform

```bash
az deployment group create \
  --resource-group rg-smart-factory \
  --template-file infra/main.bicep \
  --parameters infra/main.bicepparam \
  --output table
```

Roughly 3–5 minutes. Both apps come up running the Microsoft placeholder image —
that is expected. Real images arrive when each service's CD pipeline runs.

Read the outputs back at any time:

```bash
az deployment group show \
  --resource-group rg-smart-factory \
  --name <deployment-name> \
  --query properties.outputs
```

**If the deployment fails on a role assignment** with `PrincipalNotFound`: the
managed identity has not replicated through Entra yet. Wait sixty seconds and
re-run the same command. The template is idempotent, so re-running is safe and
is the correct response.

---

## 4. Deploy the services

Push to `main` in either service repo, or trigger manually:

```bash
gh workflow run CD --repo SelenaG4/manufacturing-maintenance-rag
gh workflow run CD --repo SelenaG4/surface-defect-inspector
```

The RAG pipeline runs its retrieval gate first and will refuse to deploy if
retrieval quality regressed. Then both go through the shared workflow: build in
ACR → deploy a revision → smoke-test with cold-start retries → roll back if the
new revision is unhealthy.

Get the live URLs:

```bash
az containerapp list \
  --resource-group rg-smart-factory \
  --query "[].{name:name, url:properties.configuration.ingress.fqdn}" \
  -o table
```

---

## 5. Optional: enable the LLM path

The RAG service answers fine without this — it falls back to offline extractive
generation. To use Azure OpenAI instead:

```bash
VAULT=$(az keyvault list --resource-group rg-smart-factory --query "[0].name" -o tsv)

# Grant yourself secret-write access. The vault uses RBAC, not access policies,
# so being subscription Owner is not by itself enough to read or write secrets.
az role assignment create \
  --role "Key Vault Secrets Officer" \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --scope "$(az keyvault show --name "$VAULT" --query id -o tsv)"

az keyvault secret set \
  --vault-name "$VAULT" \
  --name azure-openai-api-key \
  --value "<your-key>"
```

Then set `enableOpenAiSecret = true` in `infra/main.bicepparam`, re-deploy, and
also set `AZURE_OPENAI_ENDPOINT` and `AZURE_OPENAI_DEPLOYMENT` on the app —
`app/rag.py` requires the endpoint as well as the key before it will take the
Azure path.

Confirm which tier is actually serving:

```bash
curl -s https://<rag-fqdn>/health | jq .generation_mode
```

---

## 6. Watch it

Application Insights → **Logs**. The queries worth having.

**Is retrieval or generation the slow half?**

```kusto
dependencies
| where name in ("rag.retrieve", "rag.generate")
| summarize p50 = percentile(duration, 50),
            p95 = percentile(duration, 95),
            count() by name
```

**How often is the guardrail refusing to answer?**

```kusto
dependencies
| where name == "rag.guardrail_refused"
| summarize refusals = count() by bin(timestamp, 1h)
| render timechart
```

A climbing refusal rate means people are asking about machines the knowledge
base does not cover — a content gap, not a bug, and invisible without this.

**Is the LLM path silently falling back?**

```kusto
dependencies
| where name == "rag.generate"
| extend mode = tostring(customDimensions["rag.mode"])
| summarize count() by mode, bin(timestamp, 1h)
```

If this reads `offline_extractive` while a key is configured, the Azure OpenAI
call is failing and being swallowed by the fallback. The service returns 200
throughout, so nothing else would tell you.

**Do the two defect models agree on live traffic?**

```kusto
dependencies
| where name == "inspect.deep"
| extend agrees = tobool(customDimensions["inspect.agrees_with_baseline"])
| summarize agreement_rate = 100.0 * countif(agrees) / count(),
            n = count() by bin(timestamp, 1d)
```

The 97.1% baseline and the 99.6% CNN were measured on a static held-out split.
Their agreement rate on real images is a different question, and a falling rate
is an early drift signal.

**Which commit is a revision running?**

```kusto
requests
| summarize count() by tostring(customDimensions["service.instance.id"])
```

`REVISION_SHA` is set by the CD pipeline, so a latency change can be attributed
to a specific commit.

---

## 7. Tear it down

Everything lives in one resource group, so:

```bash
az group delete --name rg-smart-factory --yes --no-wait
```

Key Vault soft-delete keeps the vault recoverable for 7 days and its name
reserved. To reuse the exact name immediately:

```bash
az keyvault purge --name <vault-name>
```

Clean up the CI identity too if you are finished with the project:

```bash
az ad app delete --id "$(az ad app list --display-name smart-factory-platform-ci --query '[0].appId' -o tsv)"
```

---

## Troubleshooting

**App stuck `Activating`, or `ImagePullFailure`** — the AcrPull role assignment
has not propagated, or the image tag does not exist. Check what it is trying to
pull and what is actually in the registry:

```bash
az containerapp show --name smartfactory-rag --resource-group rg-smart-factory \
  --query "properties.template.containers[0].image" -o tsv
az acr repository show-tags --name <registry> --repository rag -o table
```

**Smoke test times out** — a cold start plus model load can exceed the retry
window on a first deploy. Check whether the container is even starting:

```bash
az containerapp logs show --name smartfactory-rag \
  --resource-group rg-smart-factory --tail 100
```

**`az acr build` fails on quota** — Basic SKU includes limited build minutes.
Build locally and push instead:

```bash
az acr login --name <registry>
docker build --build-arg WITH_TELEMETRY=true -t <registry>.azurecr.io/rag:local .
docker push <registry>.azurecr.io/rag:local
```

**Nothing appears in Application Insights** — traces are batched and take 2–5
minutes to surface. Confirm the app believes telemetry is on:

```bash
curl -s https://<rag-fqdn>/health | jq .telemetry_configured
```

`false` means the connection string did not reach the container, or the image
was built without `WITH_TELEMETRY=true`.
