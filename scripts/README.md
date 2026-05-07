# Scripts

PowerShell helpers for validating, exercising, and stress-testing the deployed
APIM Speech Service stack. All scripts are written for **PowerShell 7+**
(`pwsh`) and use the **Az PowerShell** module to obtain access tokens via the
already-signed-in Azure context — no secrets in code, no secrets on disk.

| Script | What it does | When to run |
| --- | --- | --- |
| [`test-deployment.ps1`](./test-deployment.ps1) | End-to-end smoke test — health probes, fast transcription, optional batch round-trip with cache-pin verification | After every `azd up` / `azd deploy`, after policy XML edits |
| [`load-test.ps1`](./load-test.ps1) | Parallel synthetic load against `/api/transcribe` to confirm round-robin distribution and surface latency outliers | Before a release; when validating capacity changes |
| [`test-circuit-breaker.ps1`](./test-circuit-breaker.ps1) | Forces 5xx responses through APIM to verify the per-backend circuit breaker (5 fail/min → 30 s trip) opens, then closes after the cooldown | After modifying retry/circuit-breaker policy in `infra/modules/policies/*.xml` |
| [`PSScriptAnalyzerSettings.psd1`](./PSScriptAnalyzerSettings.psd1) | Lint configuration consumed by the `powershell` job in [.github/workflows/validate.yml](../.github/workflows/validate.yml) and by local `Invoke-ScriptAnalyzer` runs | n/a (config) |

## Prerequisites

- **PowerShell 7+** — `winget install --id Microsoft.PowerShell` on Windows.
- **Az PowerShell** — `Install-Module Az -Scope CurrentUser`.
- **Logged-in context** — `Connect-AzAccount` (and `Set-AzContext -Subscription <id>` if you have multiple).
- **Resource group + APIM gateway URL** — every script accepts these as parameters; defaults match `azd env get-values` output.

> Need to inspect lint findings before pushing? Run:
>
> ```powershell
> Install-Module PSScriptAnalyzer -Scope CurrentUser
> Invoke-ScriptAnalyzer -Path scripts/ -Settings scripts/PSScriptAnalyzerSettings.psd1 -Recurse
> ```

## `test-deployment.ps1`

Validated baseline check executed against a fresh deployment.

```powershell
# Health + fast transcription (default)
pwsh ./scripts/test-deployment.ps1 `
  -ResourceGroup <rg> `
  -ApimGatewayUrl https://<apim>.azure-api.net

# Include the stateful batch round-trip (submit → poll → verify backend pin → delete)
pwsh ./scripts/test-deployment.ps1 -Batch
```

What it asserts:

1. `GET /api/health` → 200 from both backends.
2. `POST /api/transcribe` with a public sample WAV → 200 + non-empty transcript.
3. (`-Batch`) `POST /api/submit-batch` → 201; subsequent `GET /api/batch-status/{jobId}` returns the same `X-Backend-Id` header (cache pin proven).
4. (`-Batch`) `DELETE /api/batch/{jobId}` → 204.

Exit codes: `0` = all pass, non-zero = first failed step (printed in red).

## `load-test.ps1`

Round-robin distribution probe.

```powershell
pwsh ./scripts/load-test.ps1 `
  -ApimGatewayUrl https://<apim>.azure-api.net `
  -Count 50 `
  -Concurrency 5
```

Output is a table grouped by `X-Backend-Id` showing request count and p50/p95
latency per backend. A balanced run shows ≈ 50/50 split (±10 %) across the two
Speech regions. A skew of > 20 % typically means one backend is in circuit-
breaker cooldown — re-run after 30 s.

## `test-circuit-breaker.ps1`

Forces a backend into `Tripped` state by replaying a payload that the upstream
deliberately rejects, then verifies the second backend continues to serve while
the first is unavailable, then waits the 30 s cool-down and confirms recovery.

```powershell
pwsh ./scripts/test-circuit-breaker.ps1 `
  -ResourceGroup <rg> `
  -ApimGatewayUrl https://<apim>.azure-api.net
```

Validated baseline (last run): **PASS** — breaker opens after 5 consecutive 5xx
within 60 s, closes 30 s later, no spillover failures on the surviving backend.

## PowerShell gotchas (project-specific)

These have caught us out before — keep them in mind when editing the scripts:

- **`-ErrorAction Stop` everywhere** — without it, `Invoke-RestMethod` swallows
  4xx/5xx and the script lies about success. Every HTTP call in this folder
  uses `try { ... } catch { ... }` with explicit `$_.Exception.Response`
  inspection.
- **`Get-AzAccessToken` returns a `SecureString` on Az 12+** — use
  `(Get-AzAccessToken -ResourceUrl <url> -AsSecureString).Token | ConvertFrom-SecureString -AsPlainText`
  inside the request, never log the token.
- **Headers are case-sensitive over HTTP/2** — `X-Backend-Id` is what APIM
  emits; do not lowercase it when comparing.
- **`ConvertTo-Json -Depth` defaults to 2** — for the batch submit body that's
  fine, but if you extend the payload, bump to `-Depth 10`.
- **Parallel runs (`ForEach-Object -Parallel`)** — share `$using:` variables
  only; the parallel runspace cannot see the parent scope's `Az` context, so
  capture the token once before fan-out and pass it in.

## Running them in CI

These scripts are **not** part of the GitHub Actions matrix today — they are
manual / on-demand. The CI workflow only runs static analysis:

- Bicep build + PSRule for Azure
- Python lint (ruff) + import smoke test
- PowerShell lint (`Invoke-ScriptAnalyzer` against this folder)
- APIM policy XML well-formedness + attribute-escape checks
- Markdown lint + link check
- CodeQL (Python) + gitleaks + dependency-review (PRs)

See [.github/workflows/validate.yml](../.github/workflows/validate.yml) for the
full matrix.
