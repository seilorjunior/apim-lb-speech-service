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
round-robin pool, retry + circuit-breaker policy, jobId→backend cache pinning
for batch transcription (backed by **Azure Managed Redis** as the APIM external
cache), and authenticates to Speech with its **managed identity** — no shared
keys anywhere.

**At a glance**

| | |
|---|---|
| 🏗️ **IaC** | Bicep, modular, deployable with `azd up` |
| 🌎 **Regions** | Brazil South (primary) + South Central US (secondary), configurable |
| 🔀 **Load balancing** | APIM Basic v2 backend pool, round-robin, equal weight |
| 🧠 **State** | jobId→backend in Azure Managed Redis (TTL 24 h, `prefer-external` fallback) |
| 🔐 **Auth** | Managed identity end-to-end (`Cognitive Services User`, `Storage Blob Data Owner`); `disableLocalAuth: true` on Speech |
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
   |  + external cache (Azure Managed Redis):                    |
   |      jobId -> backend-id, TTL 24h                           |
   |      (set on submit, read on status/files/delete)           |
   +-----+----------------------------+--------------------------+
         |                            |
         v                            v
  +------+---------+           +------+----------+
  | Speech         |           | Speech          |
  | Brazil South   |           | South Central US|
  | S0, MI-only    |           | S0, MI-only     |
  +----------------+           +-----------------+

   +-----------------------------+
   | Azure Managed Redis (AMR)   |  <-- registered as APIM external cache
   | redisEnterprise             |       used by cache-store / cache-lookup
   | SKU: Balanced_B0 (default)  |
   +-----------------------------+
```

### Key design choices

- **Flex Consumption (FC1)** for the Function App — best practice for
  Python serverless, scales to zero. Deployment storage uses managed
  identity (no shared keys).
- **APIM Basic v2** — supports load-balanced backend pools (GA in API
  version `2024-05-01`). Round-robin with equal weight + priority.
- **JobId-to-backend cache pinning** — Speech batch transcription jobs
  live on the account that accepted the `POST`. APIM stores
  `jobId -> backendId` in **Azure Managed Redis** (registered as the APIM
  external cache) on submit, then routes all subsequent `GET`/`DELETE`
  calls for that jobId to the same backend (TTL 24 h). The policies use
  `caching-type="prefer-external"`, so they fall back to the APIM
  internal cache if AMR is unreachable. A 404 on a poll is the
  load-test failure signal.
- **Managed identity end-to-end** —
  - APIM MI → `Cognitive Services User` on each Speech account
  - Function MI → `Storage Blob Data Owner` on the deployment storage
  - Speech accounts have `disableLocalAuth: true` (keys are not usable)
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
│       ├── redis.bicep         # Azure Managed Redis (APIM external cache)
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
# Cheapest AMR tier; bump for prod (e.g. Balanced_B10, MemoryOptimized_M10)
azd env set AZURE_REDIS_SKU Balanced_B0

# 4. (Optional) Grant your user Cognitive Services User on the Speech
#    accounts to test directly with `az rest`.
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

| Route                          | Method | Purpose                                                                    |
| ------------------------------ | ------ | -------------------------------------------------------------------------- |
| `/api/submit-batch`            | POST   | Submit a job (audio URL in JSON body); APIM caches `jobId -> backendId`    |
| `/api/batch-status/{jobId}`    | GET    | Poll status; APIM uses the cache to pin to the original backend            |
| `/api/batch-files/{jobId}`     | GET    | List result files; same pin                                                |
| `/api/batch/{jobId}`           | DELETE | Delete the job; same pin                                                   |

The APIM `submit-batch` policy parses `id` from the upstream response
and calls `cache-store-value`; the stateful policy used by
status/files/delete reads it back with `cache-lookup-value` and sets
`backend-id` accordingly. See
[`infra/modules/policies/`](infra/modules/policies/).

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
- The template provisions an **Azure Managed Redis** cluster
  (`Balanced_B0` by default, ~\$80/month, no SLA) and registers it as
  the APIM external cache. The cluster takes 10-20 minutes to deploy.
  Override the SKU via `AZURE_REDIS_SKU`. APIM connects via access-key
  auth (the Bicep grabs the key with `listKeys()` and stores it in the
  APIM `caches/redis` connection string) — Microsoft Entra auth between
  APIM and AMR is not yet supported.

## Contributing & community

- [Contributing guide](CONTRIBUTING.md) — dev setup, style, PR checklist
- [Code of conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md) — how to report vulnerabilities
- [License](LICENSE) — MIT

Issues and PRs are welcome. Bugs go through the
[bug report template](.github/ISSUE_TEMPLATE/bug_report.yml); features
through the [feature request template](.github/ISSUE_TEMPLATE/feature_request.yml).
