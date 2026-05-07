# APIM LOAD BALANCER SPEECH SERVICES

> **Multi-region Azure Speech-to-Text, load-balanced through API Management — with jobId-to-backend pinning for stateful batch transcription.**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/seilorjunior/apim-lb-speech-service/actions/workflows/validate.yml/badge.svg)](https://github.com/seilorjunior/apim-lb-speech-service/actions/workflows/validate.yml)
[![Deploy with azd](https://img.shields.io/badge/azd-deployable-blue?logo=microsoftazure)](https://aka.ms/azd)
[![Bicep](https://img.shields.io/badge/IaC-Bicep-2560E0?logo=azurepipelines&logoColor=white)](infra/main.bicep)
[![Python 3.11](https://img.shields.io/badge/python-3.11-3776AB?logo=python&logoColor=white)](src/api/requirements.txt)

End-to-end [**azd**](https://aka.ms/azd) template that fans Azure Speech-to-Text
traffic across **two regional Speech accounts** through **Azure API Management**.
A Python **Flex Consumption** Function App is the front door; APIM owns the
round-robin pool, retry + circuit-breaker policy, and jobId→backend cache
pinning for batch transcription. The pinning cache uses APIM's **internal
cache** by default and can be upgraded to **Azure Managed Redis** as the APIM
external cache (opt-in via `AZURE_USE_EXTERNAL_CACHE=true`); when opted-in, the
AMR connection string is stored in **Azure Key Vault** and flowed into APIM via
a `@secure()` parameter (no Bicep lint suppressions, secret inspectable / rotatable
from KV). APIM authenticates to Speech with its **managed identity** — no shared
keys anywhere. The submit-batch operation honours an optional **`Idempotency-Key`**
header (validated for shape, then bound to a SHA-256 fingerprint of the request
body) so a retried POST returns the original 201 instead of submitting a duplicate
batch job — and a same-key-different-body retry is rejected with `422`.

**At a glance**

| | |
|---|---|
| 🏗️ **IaC** | Bicep, modular, deployable with `azd up` |
| 🌎 **Regions** | Brazil South (primary) + South Central US (secondary), configurable |
| 🔀 **Load balancing** | APIM Basic v2 backend pool, round-robin, equal weight |
| 🧠 **State** | jobId→backend pinning, TTL 24 h, `caching-type="prefer-external"`. APIM internal cache by default; optional Azure Managed Redis (`AZURE_USE_EXTERNAL_CACHE=true`) |
| 🔁 **Idempotency** | Optional `Idempotency-Key` header on `POST /submit-batch` (validated `1-128 chars`, `^[A-Za-z0-9._-]+$`). Same key + same body replays the cached 201 with `X-Idempotent-Replay: true`; same key + different body returns `422 IdempotencyKeyConflict`. TTL configurable via `AZURE_IDEMPOTENCY_TTL_SECONDS` (default 3600) |
| 🔐 **Auth** | Managed identity end-to-end (`Cognitive Services User`, `Storage Blob Data Owner`); `disableLocalAuth: true` on Speech; storage `allowSharedKeyAccess: false`; Function `httpsOnly: true`, TLS 1.2 min |
| 🔑 **Secrets** | AMR connection string stored in Azure Key Vault (only when `AZURE_USE_EXTERNAL_CACHE=true`); flowed into APIM via Bicep `@secure()` param — no lint suppressions |
| 🛡️ **Resilience** | Retry on 429/5xx (3x), circuit breaker 5 fail/min → 30 s trip |
| 📈 **Observability** | Log Analytics + Application Insights, W3C correlation, 100 % sampling |
| 🐍 **Runtime** | Python 3.11 on Function Flex Consumption (FC1) |

> ⚠️ **Public dev sample — not production-hardened.** APIM has no auth, the
> Function uses anonymous authorization, and every resource is on the public
> network. Read [Notes & limitations](#notes--limitations) before reusing.

## Architecture

```
  Stateless: Fast Transcription                Stateful: Batch v3.2 (with cache pin)
  -----------------------------                ------------------------------------
  POST /api/transcribe                         POST /api/submit-batch
  GET  /api/health                             GET  /api/batch-status/{jobId}
                                               GET  /api/batch-files/{jobId}
                                               DEL  /api/batch/{jobId}
          |                                              |
          v                                              v
   +----------------------+                +----------------------+
   |  Function App        |                |  Function App        |
   |  Python, FC1, MI     |                |  Python, FC1, MI     |
   +----------+-----------+                +----------+-----------+
              |                                       |
              v                                       v
   +-------------------------------------------------------------+
   |              API Management (Basic v2)                      |
   |    speech-stt API + speech-pool backend (round-robin)       |
   |  + retry 429/5xx 3x   + circuit breaker 5/min               |
   |  + system-assigned MI -> Cognitive Services User on each    |
   |  + jobId -> backend-id pinning cache (TTL 24h):             |
   |      caching-type="prefer-external"                         |
   |      default: APIM internal cache (free, per-instance)      |
   |      opt-in:  Azure Managed Redis (cross-instance, durable) |
   +-----+----------------------------+--------------------------+
         |                            |
         v                            v
  +------+---------+           +------+----------+
  | Speech         |           | Speech          |
  | Brazil South   |           | South Central US|
  | S0, MI-only    |           | S0, MI-only     |
  +----------------+           +-----------------+

   OPT-IN BLOCK (provisioned only when AZURE_USE_EXTERNAL_CACHE=true):

   +-----------------------------+        +------------------------------+
   | Azure Managed Redis (AMR)   |        | Azure Key Vault              |
   | redisEnterprise             |        | secret:                      |
   | SKU: Balanced_B0 (default)  |        |   redis-connection-string    |
   +--------------+--------------+        +--------------+---------------+
                  ^                                      |
                  | TLS :10000 (data plane)              | Bicep getSecret() ->
                  |                                      v @secure() param ->
                  |                            APIM caches/redis (deploy-time)
                  |                                      |
                  +----------- bound as APIM <-----------+
                              external cache
```

### Key design choices

- **Flex Consumption (FC1)** for the Function App — best practice for
  Python serverless, scales to zero. Deployment storage uses managed
  identity (no shared keys).
- **APIM Basic v2** — supports load-balanced backend pools (GA in API
  version `2024-05-01`). Round-robin with equal weight + priority.
- **JobId-to-backend cache pinning** — Speech batch transcription jobs
  live on the account that accepted the `POST`. APIM stores
  `jobId -> backendId` in its pinning cache on submit, then routes all
  subsequent `GET`/`DELETE` calls for that jobId to the same backend
  (TTL 24 h). The policies use `caching-type="prefer-external"`, so
  they read from the external cache when one is bound and fall back
  to the APIM internal cache otherwise. By default the template uses
  the **APIM internal cache** (free, per-instance) — sufficient for a
  single APIM instance. Set `AZURE_USE_EXTERNAL_CACHE=true` to also
  provision **Azure Managed Redis** and bind it as the APIM external
  cache (cross-instance sharing, durability across APIM restarts).
  A 404 on a poll is the load-test failure signal.
- **Managed identity end-to-end** —
  - APIM MI → `Cognitive Services User` on each Speech account
  - Function MI → `Storage Blob Data Owner` on the deployment storage
  - Speech accounts have `disableLocalAuth: true` (keys are not usable)
  - Storage account has `allowSharedKeyAccess: false` (RBAC/MI only)
  - Function App is `httpsOnly: true` with TLS 1.2 minimum, FTPS disabled
- **Centralized secret in Key Vault** (when `AZURE_USE_EXTERNAL_CACHE=true`)
  — the AMR connection string is written to a Key Vault secret
  (`redis-connection-string`) and flowed into the APIM module via a
  `@secure()` parameter. The Bicep `use-secure-value-for-secure-inputs`
  lint rule passes natively (no `#disable-next-line` suppression). The
  secret can be inspected / rotated from the Key Vault side, but note
  that runtime rotation of the APIM cache `connectionString` requires a
  redeploy — the ARM property is a literal field, not a runtime
  `@Microsoft.KeyVault(...)` reference.
- **Idempotency on submit-batch** — clients can include an optional
  `Idempotency-Key` request header on `POST /api/submit-batch`. The
  APIM inbound policy validates the key (length `1-128`, charset
  `^[A-Za-z0-9._-]+$`); malformed keys are rejected with
  `400 InvalidIdempotencyKey`. On a fresh successful submit, APIM
  stores two cache entries (using the same `prefer-external` cache as
  the jobId pin): the `201 Created` response body keyed by
  `speech-idem-<key>`, and a SHA-256 fingerprint of the request body
  keyed by `speech-idem-hash-<key>`. A retried POST with the same key
  and the same body short-circuits in the inbound policy and returns
  the cached body with an extra `X-Idempotent-Replay: true` header —
  no duplicate job is submitted upstream. A retried POST with the
  same key but a *different* body is rejected with
  `422 IdempotencyKeyConflict` to prevent silent reuse of a key
  across distinct requests. The TTL is configurable via the APIM
  named value `idempotency-ttl-seconds`
  (`AZURE_IDEMPOTENCY_TTL_SECONDS`, default 3600, range 60-604800).
- **Resilience** — circuit breaker on each backend (5 failures / minute
  → 30 s trip), retry on 429/5xx in the API policy (3 attempts,
  exponential-ish backoff).
- **Observability** — Log Analytics + Application Insights wired to APIM
  (W3C correlation, 100 % sampling) and the Function App.

## Repository layout

```
.
├── azure.yaml                  # azd project descriptor
├── infra/
│   ├── main.bicep              # subscription scope (creates RG)
│   ├── main-resources.bicep    # resource-group scope orchestrator
│   ├── main.parameters.json    # azd-bound parameters
│   └── modules/
│       ├── monitoring.bicep    # Log Analytics + App Insights
│       ├── storage.bicep       # FC1 deployment storage
│       ├── speech.bicep        # one Speech account (deployed twice)
│       ├── redis.bicep         # Azure Managed Redis (APIM external cache, opt-in)
│       ├── keyvault.bicep      # Key Vault for the AMR connection string (opt-in)
│       ├── apim.bicep          # APIM + backends + pool + STT API
│       ├── function.bicep      # Flex Consumption Function App
│       └── rbac.bicep          # role assignments
└── src/api/
    ├── function_app.py         # Python v2 model
    ├── host.json
    ├── requirements.txt
    └── local.settings.json.example
```

## Prerequisites

- [Azure Developer CLI (`azd`)](https://aka.ms/azd) ≥ 1.10
- [Azure Functions Core Tools v4](https://learn.microsoft.com/azure/azure-functions/functions-run-local) (for local debugging)
- Python 3.11
- Azure subscription with quota for: APIM Basic v2, Speech S0 (Brazil
  South + South Central US), Function Flex Consumption (Brazil South)

## Deploy

```pwsh
# 1. Authenticate
azd auth login

# 2. Initialize the environment (asks for env name + subscription)
azd env new dev

# 3. (Optional) Override defaults
azd env set AZURE_LOCATION brazilsouth
azd env set AZURE_SECONDARY_SPEECH_LOCATION southcentralus
# (Optional) Provision Azure Managed Redis and bind it as the APIM external
# cache. Default is `false` (APIM internal cache, free, per-instance). Set to
# `true` for cross-instance cache sharing or higher durability — adds ~$80/mo
# (Balanced_B0) and ~6-10 min to provisioning.
azd env set AZURE_USE_EXTERNAL_CACHE true
# Only used when AZURE_USE_EXTERNAL_CACHE=true. Bump for prod (e.g. Balanced_B10,
# MemoryOptimized_M10).
azd env set AZURE_REDIS_SKU Balanced_B0
# (Optional) Override the idempotency cache TTL (seconds, range 60-604800).
azd env set AZURE_IDEMPOTENCY_TTL_SECONDS 3600
# (Optional, prod) Enable irreversible Key Vault purge protection. Leave
# `false` in dev — once enabled the vault cannot be hard-deleted within
# its soft-delete retention window.
azd env set AZURE_USE_PRODUCTION_GUARDS false

# 4. (Optional) Grant your user Cognitive Services User on the Speech
#    accounts (and Key Vault Secrets User on the KV when external cache is on)
#    so you can test directly with `az rest` / inspect AMR connection string.
azd env set AZURE_PRINCIPAL_ID (az ad signed-in-user show --query id -o tsv)

# 5. Preview the deployment (best practice — never deploy blind)
azd provision --preview

# 6. Provision + deploy
azd up
```

When `azd up` completes the post-provision hook prints the APIM gateway URL.

## Test

Two helper scripts ship with the repo (PowerShell 7+):

```pwsh
# Smoke test: health + Fast Transcription (and optionally Batch)
pwsh ./scripts/test-deployment.ps1
pwsh ./scripts/test-deployment.ps1 -Batch

# Load test: validates round-robin + cache pinning under concurrency.
# PASS = roughly 50/50 backend split AND zero 404s on polls.
pwsh ./scripts/load-test.ps1 -Count 10
```

Direct API calls work too:

```pwsh
$func = (azd env get-values | Select-String FUNCTION_APP_HOSTNAME).Line.Split('=')[1].Trim('"')

# Health check
curl "https://$func/api/health"

# Fast Transcription (stateless, audio in body)
curl -X POST "https://$func/api/transcribe?locale=pt-BR" `
     -H "Content-Type: audio/wav" `
     --data-binary "@./sample.wav"
```

## Batch transcription

Speech [Batch Transcription][batch-stt] (`v3.2`) is stateful: the job
lives on the Speech account that accepted the `POST`. The Function
exposes four routes that flow through APIM:

| Route                          | Method | Purpose                                                                                                                                                                  |
| ------------------------------ | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `/api/submit-batch`            | POST   | Submit a job (audio URL in JSON body); APIM caches `jobId -> backendId`. Honours optional `Idempotency-Key` header (TTL `AZURE_IDEMPOTENCY_TTL_SECONDS`, default 1 h)    |
| `/api/batch-status/{jobId}`    | GET    | Poll status; APIM uses the cache to pin to the original backend                                                                                                          |
| `/api/batch-files/{jobId}`     | GET    | List result files; same pin                                                                                                                                              |
| `/api/batch/{jobId}`           | DELETE | Delete the job; same pin                                                                                                                                                 |

The APIM `submit-batch` policy parses `id` from the upstream response
and calls `cache-store-value`; the stateful policy used by
status/files/delete reads it back with `cache-lookup-value` and sets
`backend-id` accordingly. See
[`infra/modules/policies/`](infra/modules/policies/).

**Idempotent submit example** — pass any unique string matching
`^[A-Za-z0-9._-]+$` (1-128 chars; UUID, hash of the payload, etc.) as
`Idempotency-Key`. A retried POST with the same key *and* the same body
returns the original 201 body with `X-Idempotent-Replay: true`. A
retried POST with the same key but a *different* body is rejected
with `422 IdempotencyKeyConflict`. Malformed keys are rejected with
`400 InvalidIdempotencyKey`.

```pwsh
$key = [guid]::NewGuid().ToString('N')   # 32 hex chars, matches the regex
$body = @{
  displayName = 'demo'
  locale      = 'en-US'
  contentUrls = @('https://example.com/audio.wav')
} | ConvertTo-Json

# First POST: submits the job, returns 201
Invoke-WebRequest -Uri "https://$func/api/submit-batch" -Method Post `
  -Headers @{ 'Idempotency-Key' = $key } -Body $body -ContentType 'application/json'

# Retry within TTL (default 1 h, configurable via AZURE_IDEMPOTENCY_TTL_SECONDS):
# returns the same 201 body, no duplicate job submitted
Invoke-WebRequest -Uri "https://$func/api/submit-batch" -Method Post `
  -Headers @{ 'Idempotency-Key' = $key } -Body $body -ContentType 'application/json'
# -> X-Idempotent-Replay: true

# Same key, DIFFERENT body within TTL: 422 IdempotencyKeyConflict
# (guards against silent reuse of an Idempotency-Key for a different request)
```

The Fast Transcription path is stateless and does not need pinning.
It round-robins across both Speech accounts using
[`POST /speechtotext/transcriptions:transcribe?api-version=2024-11-15`][fast-stt].

[fast-stt]: https://learn.microsoft.com/azure/ai-services/speech-service/fast-transcription-create
[batch-stt]: https://learn.microsoft.com/azure/ai-services/speech-service/batch-transcription

## Tear down

```pwsh
azd down --purge --force
```

## Notes & limitations

- This template is **dev-only** by design (open APIM API, public network
  access on all resources). Before going to production:
  - Add a subscription key requirement or Entra JWT validation on the
    `speech-stt` API.
  - Lock down public network access; add VNet integration + private
    endpoints for APIM, Function, Storage, and Speech.
  - Move the Function App's storage into the same VNet.
- Brazil South is the primary region; the secondary Speech account is
  in South Central US (Brazil South's paired region) to maximise
  geo-redundancy. Adjust via `AZURE_SECONDARY_SPEECH_LOCATION`.
- Backend round-robin requires at least APIM SKU `BasicV2`. Don't
  downgrade to Consumption — it does not support backend pools.
- The template provisions an **Azure Managed Redis** cluster + an
  **Azure Key Vault** ONLY when `AZURE_USE_EXTERNAL_CACHE=true` is set.
  Default is `false`, in which case APIM uses its built-in internal
  cache for jobId pinning (free, per-instance, lost on APIM restart)
  and no Key Vault is deployed. When opted in, AMR defaults to
  `Balanced_B0` (~\$80/month, no SLA) and the full opt-in stack takes
  6–20 minutes to deploy. Override the SKU via `AZURE_REDIS_SKU`.
- APIM connects to AMR via **access-key auth** — Bicep calls
  `listKeys()` on the AMR database, writes the resulting connection
  string to a Key Vault secret (`redis-connection-string`), and flows
  it into the APIM module via a `@secure()` parameter. The cache
  resource (`Microsoft.ApiManagement/service/caches`) takes a literal
  string for `connectionString`, **not** a runtime
  `@Microsoft.KeyVault(...)` reference, so rotating the secret in Key
  Vault still requires a redeploy (or a manual REST PATCH on the cache
  resource) for APIM to pick up the new value. Microsoft Entra auth
  between APIM and AMR is not yet supported.
- The **idempotency cache** for submit-batch (`speech-idem-<key>` for
  the response body, `speech-idem-hash-<key>` for the SHA-256
  fingerprint of the request body) shares the same
  `caching-type="prefer-external"` backing store as the jobId pin.
  The TTL is sourced from the APIM named value
  `idempotency-ttl-seconds` (`AZURE_IDEMPOTENCY_TTL_SECONDS`,
  default 3600, allowed range 60-604800). Clients should not assume
  idempotency holds beyond the configured TTL.
- Setting `AZURE_USE_PRODUCTION_GUARDS=true` enables Key Vault
  `enablePurgeProtection`. This is **irreversible**: once true, the
  vault cannot be purged within its soft-delete retention window
  (7 days in this template). Leave the guard off in dev so a botched
  deploy can be torn down with `azd down --purge --force`; turn it on
  for prod environments only.
- When `AZURE_PRINCIPAL_ID` is set *and* `AZURE_USE_EXTERNAL_CACHE=true`,
  the template grants that principal `Key Vault Secrets User` on the
  Key Vault scope automatically (no manual `az role assignment` step
  needed to inspect / rotate `redis-connection-string`).

## Contributing & community

- [Contributing guide](CONTRIBUTING.md) — dev setup, style, PR checklist
- [Code of conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md) — how to report vulnerabilities
- [License](LICENSE) — MIT

Issues and PRs are welcome. Bugs go through the
[bug report template](.github/ISSUE_TEMPLATE/bug_report.yml); features
through the [feature request template](.github/ISSUE_TEMPLATE/feature_request.yml).
