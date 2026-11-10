# Phase 10 — Azure infrastructure and CI/CD (3–5 pw) → Milestone F

> **Roadmap status: 🔭 planned, not started.** **Nothing in this phase is implemented.** Punit has
> no Azure deployment, no Bicep, no managed identities, no Front Door and no deployment workflow.
> GitHub Actions CI exists ([ci.yml](../../.github/workflows/ci.yml)) but only builds and tests.
> Today's self-hosting path is Docker ([deploy.md](../deploy.md)).

**Goal:** everything that ran in Docker Compose now runs in Azure, created from code, and deployed by GitHub Actions without any stored passwords.

**New concepts:** Infrastructure as Code (Bicep), resource groups, managed identities, GitHub OIDC federation, Container Apps revisions.

> 💰 Azure costs money. Use the smallest SKUs in `dev`, set a **budget alert** (Cost Management → Budgets) before creating anything, and delete the dev resource group when you are not using it.

Branch: `git switch -c phase-10-azure`.

---

## 10.1 Tools and login

**Do:**

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az login
az account set --subscription "<your subscription>"
az bicep install
```

**Decision (write ADR-0011):** Bicep or Terraform. **Recommended: Bicep.** It is Azure-native, has no state file to manage, and is simpler for a single-cloud beginner project.

---

## 10.2 Resource layout

One resource group per environment: `rg-ota-dev`, `rg-ota-staging`, `rg-ota-prod`.

| Resource | Purpose | Dev SKU | Prod notes |
|---|---|---|---|
| Log Analytics + Application Insights | Logs, traces | Pay-as-you-go | Set retention and a daily cap |
| Container Registry (ACR) | Docker images | Basic | Standard |
| Container Apps environment + `ota-api` + `ota-worker` | Run the containers | Consumption | Min replicas ≥ 2 |
| PostgreSQL Flexible Server | Database | Burstable B1ms | General Purpose, zone-redundant HA, **PgBouncer on** |
| Storage account (+ `artifacts` container) | Patch files | Standard LRS | GRS/ZRS, versioning + soft delete, **public access off** |
| Front Door **Premium** + WAF | CDN for artifacts, edge for API | Standard is OK in dev | Premium for Private Link to storage |
| Key Vault | Signing key, JWT and cohort secrets | Standard | Premium (HSM keys), purge protection on |
| Event Hubs namespace + hub `ota-events` | Telemetry | Standard, 1 TU | Auto-inflate |
| Azure Managed Redis | *Only if Phase 11 shows you need it* | — | Not the retiring "Azure Cache for Redis" |

---

## 10.3 Write the Bicep modules

**Do:** folder `infra/`:

```
infra/
├── main.bicep                  # wires the modules together
├── modules/
│   ├── monitoring.bicep        # Log Analytics + App Insights
│   ├── registry.bicep
│   ├── postgres.bicep
│   ├── storage.bicep
│   ├── keyvault.bicep
│   ├── eventhubs.bicep
│   ├── containerapps.bicep     # environment + api + worker, with managed identities
│   └── frontdoor.bicep
└── environments/
    ├── dev.bicepparam
    ├── staging.bicepparam
    └── prod.bicepparam
```

Write **one module at a time**, deploy it, and check it in the portal before writing the next:

```bash
az group create -n rg-ota-dev -l centralindia
az deployment group create -g rg-ota-dev -f infra/main.bicep -p infra/environments/dev.bicepparam
```

Use `az deployment group what-if ...` before every deploy to preview changes.

Microsoft's docs have a Bicep reference for every resource type. Search "Microsoft.App/containerApps bicep", for example.

---

## 10.4 Managed identities (no passwords)

**Why:** a managed identity is an Azure-provided identity for your container. Azure grants it access to other resources, so no connection strings or keys live in your code or settings.

**Do** (in Bicep, via role assignments):

| Identity | Gets role on | Role |
|---|---|---|
| `ota-api` | Storage account | Storage Blob Data Contributor + Storage Blob Delegator |
| `ota-api` | Key Vault | Key Vault Crypto User (sign) + Key Vault Secrets User |
| `ota-api` | Event Hubs | Azure Event Hubs Data Sender |
| `ota-worker` | Event Hubs | Azure Event Hubs Data Receiver |
| `ota-worker` | Storage (checkpoints) | Storage Blob Data Contributor |
| both | ACR | AcrPull |

For Postgres, enable **Microsoft Entra authentication** and create a database role for the API's identity. The app gets a token with `DefaultAzureCredential` and uses it as the password. There is a short guide in the Azure Postgres docs: "Connect with managed identity".

In code this is only settings. `DefaultAzureCredential()` already works everywhere you used it.

---

## 10.5 GitHub → Azure with OIDC

**Why:** GitHub Actions needs to deploy to Azure. Instead of storing an Azure password in GitHub, Azure trusts GitHub's short-lived OIDC token for **your repo and environment only**.

**Do** (once per environment):

```bash
az ad app create --display-name gh-ota-deploy-dev
APP_ID=$(az ad app list --display-name gh-ota-deploy-dev --query [0].appId -o tsv)
az ad sp create --id $APP_ID

az ad app federated-credential create --id $APP_ID --parameters '{
  "name": "github-dev",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<github-user>/flutter_ota_system:environment:dev",
  "audiences": ["api://AzureADTokenExchange"]
}'

az role assignment create --assignee $APP_ID --role Contributor \
  --scope /subscriptions/<sub-id>/resourceGroups/rg-ota-dev
```

> Deployments that create role assignments (10.4) also need **User Access Administrator** (or **Role Based Access Control Administrator**) on the resource group.

In GitHub → Settings → **Environments**: create `dev` and `production`. For `production`, add **required reviewers**. Add these variables: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`. They are identifiers, not secrets.

---

## 10.6 Deployment workflows

**Do:** `.github/workflows/deploy-dev.yml` (on push to `main`) and `deploy-prod.yml` (manual or on tag, `environment: production`):

```yaml
permissions:
  contents: read
  id-token: write          # required for OIDC

jobs:
  deploy:
    runs-on: ubuntu-latest
    environment: dev
    steps:
      - uses: actions/checkout@v4
      - uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      # 1. infra:     az deployment group create ... (idempotent)
      # 2. image:     az acr build -r <acr> -t ota-api:${{ github.sha }} backend/
      # 3. migrate:   run a Container Apps *job* that executes `alembic upgrade head`
      # 4. deploy:    az containerapp update -n ota-api -g rg-ota-dev --image <acr>/ota-api:${{ github.sha }}
      # 5. smoke:     curl https://<api-host>/readyz must return 200
```

Migrations must be **backward compatible**: the old version keeps running while the new one starts. Add columns as nullable first, and remove old columns only in a later release.

---

## 10.7 Scaling rules

**Do** (in `containerapps.bicep`):
- `ota-api`: HTTP scale rule, for example 100 concurrent requests per replica; min 1 (dev) / 2 (prod), max 30. Phase 11 measures the right number.
- `ota-worker`: scale rule on Event Hubs lag (KEDA `azure-eventhub` scaler); min 1.
- Health probes: liveness `/healthz`, readiness `/readyz`.

---

## 10.8 Front Door

**Do:**
- Route `/objects/*` → storage origin (via **Private Link** in Premium). Caching **on**, and honour origin cache headers.
- Route `/v1/*` → `ota-api` origin, with caching **off**.
- WAF policy: managed rule set + a rate limit rule on `/v1/devices/register` and `/v1/devices/token/refresh` (for example 30/min per IP).
- Set the API setting `cdn_base_url` to `https://<frontdoor-host>/objects`.

---

## 10.9 Patch pipeline workflow

**Do:** `.github/workflows/patch.yml` (manual trigger with inputs: release ID, file path, channel):

```
build patch → hash → sign with Key Vault (OIDC identity with "Key Vault Crypto User")
→ upload (prepare/commit) → validate → publish to `qa` channel at 100%
→ [production environment approval] → production rollout at 1%
```

Further promotion (10% → 100%) is done from the admin console, guarded by the health gates.

---

## 10.10 End-to-end in Azure

**Check:** 🎉 **Milestone F**: point the example app at the Front Door host, then repeat the Phase 5 demo against Azure. Delete and recreate `rg-ota-dev` from scratch with the workflow, and everything should come back.

---

## Phase 10 is done when

- [ ] No secrets in GitHub or app settings (only IDs). Everything uses managed identity or OIDC
- [ ] One workflow creates the entire dev environment from nothing
- [ ] Production deploys require approval
- [ ] Patch bytes are served by Front Door. Storage has no public access
