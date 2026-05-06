# apim-lb-speech-service

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![CI](https://github.com/seilorjunior/apim-lb-speech-service/actions/workflows/validate.yml/badge.svg)](https://github.com/seilorjunior/apim-lb-speech-service/actions/workflows/validate.yml)

End-to-end **azd** template that load-balances Azure Speech-to-Text across
**two regional Speech accounts** through Azure API Management. A Python
Azure Function (Flex Consumption) is the front door; APIM owns the
load-balancing logic, retry policy, jobId-to-backend cache pinning for
batch transcription, and authenticates to Speech with its managed
identity.

> **Public dev sample.** Not production-hardened. APIM has no auth, the
> Function uses anonymous authorization, and every resource is on the
> public network. See [Notes & limitations](#notes--limitations) before
> reusing.

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
   |  + internal cache: jobId -> backend-id, TTL 24h             |
   |    (set on submit, read on status/files/delete)             |
   +-----+----------------------------+--------------------------+
         |                            |
         v                            v
  +------+---------+           +------+----------+
  | Speech         |           | Speech          |
  | Brazil South   |           | South Central US|
  | S0, MI-only    |           | S0, MI-only     |
  +----------------+           +-----------------+
```

### Key design choices

- **Flex Consumption (FC1)** for the Function App — best practice for
  Python serverless, scales to zero. Deployment storage uses managed
  identity (no shared keys).
- **APIM Basic v2** — supports load-balanced backend pools (GA in API
  version `2024-05-01`). Round-robin with equal weight + priority.
- **JobId-to-backend cache pinning** — Speech batch transcription jobs
  live on the account that accepted the `POST`. APIM stores
  `jobId -> backendId` in its internal cache on submit, then routes all
  subsequent `GET`/`DELETE` calls for that jobId to the same backend
  (TTL 24 h). A 404 on a poll is the load-test failure signal.
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

## Contributing & community

- [Contributing guide](CONTRIBUTING.md) — dev setup, style, PR checklist
- [Code of conduct](CODE_OF_CONDUCT.md)
- [Security policy](SECURITY.md) — how to report vulnerabilities
- [License](LICENSE) — MIT

Issues and PRs are welcome. Bugs go through the
[bug report template](.github/ISSUE_TEMPLATE/bug_report.yml); features
through the [feature request template](.github/ISSUE_TEMPLATE/feature_request.yml).
