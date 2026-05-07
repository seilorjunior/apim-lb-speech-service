# Scripts

PowerShell helpers for smoke-testing, load-testing, and validating the APIM-load-balanced Speech service. All scripts read endpoints from `azd env get-values`, so run `azd up` (or `azd env refresh`) first.

| Script | Purpose | Mutates Azure? |
|---|---|---|
| [test-deployment.ps1](test-deployment.ps1) | Smoke test: `/health` + a single (or N concurrent) `/transcribe` or `/submit-batch` call. | No |
| [load-test.ps1](load-test.ps1) | Stress test: submit + poll N parallel batch jobs and validate pool round-robin + cache pinning. | No |
| [test-circuit-breaker.ps1](test-circuit-breaker.ps1) | Failure-injection test: temporarily breaks the primary backend URL to trigger the APIM circuit breaker, then verifies failover + auto-recovery. | **Yes** (auto-reverted in `finally{}`) |
| [PSScriptAnalyzerSettings.psd1](PSScriptAnalyzerSettings.psd1) | Lint config. Excludes `PSAvoidUsingWriteHost` (Write-Host is intentional in CLI scripts). | n/a |

## Prerequisites

- **PowerShell 7+** (`pwsh`) — scripts use `ForEach-Object -Parallel`, ternary operators, and null-conditional access.
- **Azure CLI** (`az`) logged in and pointed at the right subscription.
- **Azure Developer CLI** (`azd`) initialized in this repo (`azd env get-values` must succeed).
- **Contributor** on the APIM resource (only required by `test-circuit-breaker.ps1`).

## Linting

All scripts pass against the bundled `PSScriptAnalyzerSettings.psd1`:

```powershell
Invoke-ScriptAnalyzer -Path scripts -Settings scripts/PSScriptAnalyzerSettings.psd1 -Recurse
```

---

## test-deployment.ps1

Smoke-tests an existing deployment. Reads endpoints from `azd env get-values`, calls `/health`, and optionally fires N concurrent transcribe/batch calls so you can watch round-robin in App Insights / APIM analytics.

### Parameters

| Name | Type | Default | Description |
|---|---|---|---|
| `AudioFile` | string | _(omitted → only /health runs)_ | Local WAV/MP3/OGG file passed to `/api/transcribe`. |
| `Locale` | string | `pt-BR` | BCP-47 locale forwarded to Speech Fast Transcription. |
| `Concurrency` | int | `1` | Number of parallel transcribe calls. Use 10+ to validate pool spread. |
| `Batch` | switch | `$false` | If set, exercises the batch endpoint (`/api/submit-batch`) instead of `/transcribe`. |
| `BatchAudioUrl` | string | Microsoft sample WAV URL | Audio URL used when `-Batch` is set. |

### Examples

```powershell
# Health check only
pwsh ./scripts/test-deployment.ps1

# Single transcription
pwsh ./scripts/test-deployment.ps1 -AudioFile .\sample.wav

# Round-robin smoke check
pwsh ./scripts/test-deployment.ps1 -AudioFile .\sample.wav -Concurrency 10 -Locale en-US

# Batch path
pwsh ./scripts/test-deployment.ps1 -Batch
```

---

## load-test.ps1

Submits N batch transcription jobs in parallel through the Function App, then polls every job concurrently until terminal state. Designed to validate three things simultaneously:

1. **Pool round-robin** — primary vs. secondary should land roughly 50/50.
2. **Cache pinning** — every poll for `jobId X` must hit the same backend that accepted the original POST. A single `404` on poll proves a pinning failure.
3. **Throughput** — Function App, plan, and Speech accounts must absorb the concurrent submit + poll load without throttling.

### Parameters

| Name | Type | Default | Description |
|---|---|---|---|
| `Count` | int | `10` | Number of parallel batch jobs to submit. |
| `PollIntervalSec` | int | `5` | Seconds between status polls per job. |
| `TimeoutSec` | int | `600` | Per-job hard timeout. |
| `Locale` | string | `en-US` | BCP-47 locale (matches the public sample audio). |
| `BatchAudioUrls` | string[] | 3 MS sample WAVs | Audio URLs cycled round-robin (`job N -> URL N % len`). |
| `MaxParallel` | int | `10` | Cap on concurrent submit + poll threads. |

### Output

A summary table with:
- Backend distribution (primary vs. secondary count).
- Success / failure counts.
- Poll counts per job (min/avg/max).
- End-to-end durations (min/avg/max).
- **Any 404 on poll = pin failure** (highlighted).

### Examples

```powershell
# Default: 10 jobs
pwsh ./scripts/load-test.ps1

# Heavy run
pwsh ./scripts/load-test.ps1 -Count 100 -MaxParallel 8

# Custom audio mix
pwsh ./scripts/load-test.ps1 -Count 9 -BatchAudioUrls @(
    'https://example.com/short.wav',
    'https://example.com/medium.wav',
    'https://example.com/long.wav'
)
```

### Validated baseline

100-job run completed with **100/100 PASS**, primary=50 / secondary=50, audio mix 34/33/33, **0 pin-failure 404s**.

---

## test-circuit-breaker.ps1

Verifies the APIM backend circuit breaker by temporarily breaking the primary Speech backend URL and observing pool failover + auto-recovery.

### How it works

The CB on each `speech-*` backend ([infra/modules/apim.bicep](../infra/modules/apim.bicep)) is configured as:

| Setting | Value |
|---|---|
| `failureCondition` | HTTP 429 or 500-599 |
| `count` | 5 within `PT1M` |
| `tripDuration` | `PT30S` |
| `acceptRetryAfter` | `true` |

The `submit-batch` policy retries 429/5xx up to 3 times, so a single POST hitting a broken backend can burn ~4 failure counts. With primary deliberately broken, **~2 POSTs are enough to trip primary**; after that, the pool's CB-aware load balancer routes 100% to secondary until the 30-s `tripDuration` elapses.

### Phases

| Phase | What it does | Pass criteria |
|---|---|---|
| **A** — Trip | `TripPosts` sequential POSTs while primary is broken. | At least one response served by secondary; client sees 201 throughout (in-request retry hides upstream failure). |
| **B** — Verify open | `VerifyPosts` parallel POSTs while CB should be open. | 100% of responses served by **secondary** (`primary == 0`). |
| **C** — Wait | Sleep `RecoveryWaitSec` (must be ≥ `tripDuration`). | n/a |
| **D** — Verify recovered | Restore primary URL, sleep 5s for APIM refresh, send `RecoveryPosts` parallel POSTs. | Round-robin resumes (`primary > 0 && secondary > 0`). |

The original primary URL is captured up front and **always** restored in `finally{}` — safe on Ctrl-C / unexpected failure.

### Parameters

| Name | Type | Default | Description |
|---|---|---|---|
| `TripPosts` | int | `8` | Sequential POSTs in Phase A. |
| `VerifyPosts` | int | `10` | Parallel POSTs in Phase B. |
| `RecoveryWaitSec` | int | `35` | Seconds to sleep before verifying recovery. Must be ≥ `tripDuration` (`PT30S`). |
| `RecoveryPosts` | int | `10` | Parallel POSTs in Phase D. |
| `BadUrl` | string | `https://httpstat.us/500` | Failure injector. Any fast 5xx host works. |
| `MaxParallel` | int | `8` | Cap on parallel POSTs in Phases B and D. |
| `Yes` | switch | `$false` | Skip interactive confirmation. |

### Examples

```powershell
# Interactive (prompts before mutating APIM)
pwsh ./scripts/test-circuit-breaker.ps1

# Unattended
pwsh ./scripts/test-circuit-breaker.ps1 -Yes

# Conservative recovery wait
pwsh ./scripts/test-circuit-breaker.ps1 -Yes -RecoveryWaitSec 45
```

### Validated baseline

| Phase | Result |
|---|---|
| **A** (8 sequential, primary broken) | 8/8 → secondary, 201 (in-request retry hid the upstream 500) |
| **B** (10 parallel, CB open) | 9 secondary / 0 primary / 1 transient |
| **D** (10 parallel, after restore) | 5 primary / 5 secondary |

**Verdict:** PASS — CB tripped on primary, pool failed over to secondary, then auto-recovered.

### Safety notes

- **Mutates APIM backend configuration.** Run only in dev/test.
- The change is reverted in `finally{}`. If the script crashes between `PATCH` and `finally`, re-run it (it captures the current URL on entry — but if that's already the bad URL, restore manually with the original from your `azd env`).
- Requires Contributor on the APIM resource.

---

## PowerShell gotchas (lessons from building these scripts)

These bit us during development; documented here so the next script doesn't repeat them.

### `?` in interpolated strings

PowerShell 7's null-conditional operator (`$var?.member`) is greedy in interpolated strings:

```powershell
# WRONG — eats $primaryBackend?api as one token, URI loses the variable + "?api"
"$baseUri/backends/$primaryBackend?api-version=2024-05-01"

# RIGHT — explicit braces terminate the variable name
"$baseUri/backends/${primaryBackend}?api-version=2024-05-01"
```

### Native command stdout capture with `2>$null`

```powershell
# UNRELIABLE — can return $null for $x even when az succeeds
$x = az ... 2>$null

# RELIABLE
$x = az ... 2>&1
if ($LASTEXITCODE -ne 0) { throw "$x" }
$obj = $x | Out-String | ConvertFrom-Json
```

### `[Attribute(...)]` placement on functions

PSScriptAnalyzer suppression attributes must go **inside** the `param()` block, not above the `function` keyword (the latter is a parser error).

```powershell
function Set-PrimaryBackendUrl {
    param(
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
            'PSUseShouldProcessForStateChangingFunctions', '',
            Justification = '...')]
        [string]$Url
    )
    ...
}
```

### `ForEach-Object -Parallel` function propagation

Functions defined in the parent scope are NOT visible inside a parallel scriptblock. Capture and re-define:

```powershell
$funcDef = ${function:Invoke-X}.ToString()

1..10 | ForEach-Object -Parallel {
    ${function:Invoke-X} = $using:funcDef
    Invoke-X -Idx $_
} -ThrottleLimit 8
```
