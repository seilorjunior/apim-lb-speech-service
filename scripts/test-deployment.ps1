<#
.SYNOPSIS
    Smoke-tests the deployed APIM-load-balanced Speech service.

.DESCRIPTION
    1. Reads endpoint values from `azd env get-values`.
    2. Calls GET /api/health on the Function App.
    3. Sends an audio file to POST /api/transcribe (which forwards to APIM,
       which load-balances across the two Speech accounts).
    4. Optionally fires N concurrent transcribe calls so you can observe
       round-robin distribution in App Insights / APIM analytics.

.PARAMETER AudioFile
    Path to a WAV/MP3/OGG audio file to transcribe.
    If omitted, only the /health check runs.

.PARAMETER Locale
    BCP-47 locale code passed to the Speech Fast Transcription API.
    Defaults to pt-BR (Brazilian Portuguese, matching the primary region).

.PARAMETER Concurrency
    Number of parallel transcribe calls to issue. Default: 1.
    Use 10+ to validate that traffic spreads across both backends.

.EXAMPLE
    pwsh ./scripts/test-deployment.ps1

.EXAMPLE
    pwsh ./scripts/test-deployment.ps1 -AudioFile .\sample.wav

.EXAMPLE
    pwsh ./scripts/test-deployment.ps1 -AudioFile .\sample.wav -Concurrency 10 -Locale en-US
#>
[CmdletBinding()]
param(
    [string] $AudioFile,
    [string] $Locale = 'pt-BR',
    [int]    $Concurrency = 1,
    [switch] $Batch,
    [string] $BatchAudioUrl = 'https://github.com/Azure-Samples/cognitive-services-speech-sdk/raw/master/sampledata/audiofiles/aboutSpeechSdk.wav'
)

$ErrorActionPreference = 'Stop'

# --- Locate repo root (script is in <repo>/scripts/) ---
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    # --- 1. Read azd environment values ---
    Write-Host '== Reading azd environment ==' -ForegroundColor Cyan
    $envLines = & azd env get-values 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $envLines) {
        throw "Failed to read azd env. Run 'azd up' first."
    }

    $envMap = @{}
    foreach ($line in $envLines) {
        if ($line -match '^([A-Z0-9_]+)="?(.*?)"?$') {
            $envMap[$Matches[1]] = $Matches[2]
        }
    }

    $functionHost = $envMap['FUNCTION_APP_HOSTNAME']
    $apimUrl      = $envMap['APIM_GATEWAY_URL']
    if (-not $functionHost) { throw 'FUNCTION_APP_HOSTNAME missing from azd env.' }

    $functionBase = "https://$functionHost"
    Write-Host "Function App : $functionBase" -ForegroundColor Green
    Write-Host "APIM Gateway : $apimUrl"      -ForegroundColor Green
    Write-Host ''

    # --- 2. Health check ---
    Write-Host '== GET /api/health ==' -ForegroundColor Cyan
    $health = Invoke-RestMethod -Uri "$functionBase/api/health" -Method Get -TimeoutSec 30
    $health | ConvertTo-Json -Depth 4 | Write-Host
    Write-Host ''

    # --- 2b. Batch transcription mode (deterministic backend pinning) ---
    if ($Batch) {
        Write-Host '== Batch transcription (POST + poll + files) ==' -ForegroundColor Cyan
        Write-Host "Audio URL : $BatchAudioUrl"
        Write-Host "Locale    : $Locale"
        Write-Host ''

        $payload = @{
            displayName = "test-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            locale      = $Locale
            contentUrls = @($BatchAudioUrl)
            properties  = @{ wordLevelTimestampsEnabled = $true }
        } | ConvertTo-Json -Depth 5

        Write-Host '-> POST /api/submit-batch' -ForegroundColor Cyan
        $submitResp = Invoke-WebRequest `
            -Uri "$functionBase/api/submit-batch" `
            -Method Post `
            -Body $payload `
            -ContentType 'application/json' `
            -TimeoutSec 60 `
            -SkipHttpErrorCheck

        Write-Host "Status: $([int]$submitResp.StatusCode)"
        if ([int]$submitResp.StatusCode -ne 201) {
            Write-Host $submitResp.Content -ForegroundColor Red
            return
        }

        $submit = $submitResp.Content | ConvertFrom-Json
        $jobId = $submit.jobId
        Write-Host "jobId       : $jobId" -ForegroundColor Green
        Write-Host "speechSelf  : $($submit.speechSelf)" -ForegroundColor Gray
        Write-Host ''

        # --- Poll status. Each call MUST hit the same Speech backend, otherwise 404 ---
        Write-Host '-> Polling /api/batch-status/{jobId}' -ForegroundColor Cyan
        $polls   = 0
        $sw      = [Diagnostics.Stopwatch]::StartNew()
        $status  = 'NotStarted'
        $statusObj = $null
        while ($true) {
            $polls++
            Start-Sleep -Seconds 5
            $statusResp = Invoke-WebRequest `
                -Uri "$functionBase/api/batch-status/$jobId" `
                -Method Get `
                -TimeoutSec 30 `
                -SkipHttpErrorCheck

            $code = [int]$statusResp.StatusCode
            if ($code -eq 404) {
                Write-Host ("[poll {0,2}] HTTP 404 - backend pinning FAILED" -f $polls) -ForegroundColor Red
                return
            }
            if ($code -ne 200) {
                Write-Host ("[poll {0,2}] HTTP {1}: {2}" -f $polls, $code, $statusResp.Content) -ForegroundColor Yellow
                if ($sw.Elapsed.TotalSeconds -gt 600) { return }
                continue
            }

            $statusObj = $statusResp.Content | ConvertFrom-Json
            $status    = $statusObj.status
            Write-Host ("[poll {0,2} | {1,3}s] status={2}" -f $polls, [int]$sw.Elapsed.TotalSeconds, $status)
            if ($status -in 'Succeeded','Failed') { break }
            if ($sw.Elapsed.TotalSeconds -gt 600) {
                Write-Host 'Timeout after 10 minutes' -ForegroundColor Yellow
                return
            }
        }
        $sw.Stop()
        Write-Host ''
        $finalColor = if ($status -eq 'Succeeded') { 'Green' } else { 'Yellow' }
        Write-Host ("Final status : {0} after {1} polls in {2}s" -f $status, $polls, [int]$sw.Elapsed.TotalSeconds) -ForegroundColor $finalColor

        if ($status -ne 'Succeeded') {
            Write-Host ($statusObj | ConvertTo-Json -Depth 6)
            return
        }

        # --- Get files (also pinned via cache) ---
        Write-Host ''
        Write-Host '-> GET /api/batch-files/{jobId}' -ForegroundColor Cyan
        $filesResp = Invoke-WebRequest `
            -Uri "$functionBase/api/batch-files/$jobId" `
            -Method Get `
            -TimeoutSec 30 `
            -SkipHttpErrorCheck
        if ([int]$filesResp.StatusCode -ne 200) {
            Write-Host "files HTTP $([int]$filesResp.StatusCode): $($filesResp.Content)" -ForegroundColor Yellow
            return
        }
        $files = $filesResp.Content | ConvertFrom-Json
        Write-Host ("File count   : {0}" -f $files.values.Count)

        # --- Download the transcription file (SAS URL on Speech-managed storage; goes direct, not via APIM) ---
        $transcript = $files.values | Where-Object { $_.kind -eq 'Transcription' } | Select-Object -First 1
        if ($transcript) {
            Write-Host ''
            Write-Host '== Transcript ==' -ForegroundColor Cyan
            $tr = (Invoke-WebRequest -Uri $transcript.links.contentUrl -Method Get -TimeoutSec 60).Content | ConvertFrom-Json
            $text = ($tr.combinedRecognizedPhrases | Select-Object -First 1).display
            if (-not $text) {
                $text = ($tr.recognizedPhrases | ForEach-Object { $_.nBest[0].display }) -join ' '
            }
            Write-Host $text -ForegroundColor Green
        }
        return
    }

    if (-not $AudioFile) {
        Write-Host 'No -AudioFile provided. Skipping transcribe test.' -ForegroundColor Yellow
        Write-Host 'Re-run with: ./scripts/test-deployment.ps1 -AudioFile <path-to-audio>' -ForegroundColor Yellow
        return
    }

    if (-not (Test-Path -LiteralPath $AudioFile)) {
        throw "Audio file not found: $AudioFile"
    }

    # --- 3. Resolve content-type from extension ---
    $ext = [IO.Path]::GetExtension($AudioFile).ToLowerInvariant()
    $contentType = switch ($ext) {
        '.wav'  { 'audio/wav' }
        '.mp3'  { 'audio/mpeg' }
        '.ogg'  { 'audio/ogg' }
        '.opus' { 'audio/ogg' }
        '.flac' { 'audio/flac' }
        '.m4a'  { 'audio/mp4' }
        default { 'application/octet-stream' }
    }

    $audioBytes  = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $AudioFile))
    $audioSizeKB = [Math]::Round($audioBytes.Length / 1KB, 2)
    $transcribeUrl = "$functionBase/api/transcribe?locale=$Locale"

    Write-Host '== POST /api/transcribe ==' -ForegroundColor Cyan
    Write-Host "File         : $AudioFile ($audioSizeKB KB, $contentType)"
    Write-Host "Locale       : $Locale"
    Write-Host "Concurrency  : $Concurrency"
    Write-Host ''

    # --- 4. Define the single-call worker ---
    $invokeOne = {
        param($url, $bytes, $ctype, $index)

        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $resp = Invoke-WebRequest `
                -Uri $url `
                -Method Post `
                -Body $bytes `
                -ContentType $ctype `
                -TimeoutSec 180 `
                -SkipHttpErrorCheck
            $sw.Stop()

            $body = $null
            try { $body = $resp.Content | ConvertFrom-Json -ErrorAction Stop } catch { $body = $resp.Content }

            [pscustomobject]@{
                Index      = $index
                Status     = [int]$resp.StatusCode
                DurationMs = [int]$sw.ElapsedMilliseconds
                Body       = $body
                Error      = $null
            }
        }
        catch {
            $sw.Stop()
            [pscustomobject]@{
                Index      = $index
                Status     = -1
                DurationMs = [int]$sw.ElapsedMilliseconds
                Body       = $null
                Error      = $_.Exception.Message
            }
        }
    }

    # --- 5. Run sequentially or in parallel ---
    $results =
        if ($Concurrency -le 1) {
            ,(& $invokeOne $transcribeUrl $audioBytes $contentType 1)
        }
        else {
            1..$Concurrency | ForEach-Object -ThrottleLimit $Concurrency -Parallel {
                $sw = [Diagnostics.Stopwatch]::StartNew()
                try {
                    $resp = Invoke-WebRequest `
                        -Uri $using:transcribeUrl `
                        -Method Post `
                        -Body $using:audioBytes `
                        -ContentType $using:contentType `
                        -TimeoutSec 180 `
                        -SkipHttpErrorCheck
                    $sw.Stop()
                    $body = $null
                    try { $body = $resp.Content | ConvertFrom-Json -ErrorAction Stop } catch { $body = $resp.Content }
                    [pscustomobject]@{
                        Index      = $_
                        Status     = [int]$resp.StatusCode
                        DurationMs = [int]$sw.ElapsedMilliseconds
                        Body       = $body
                        Error      = $null
                    }
                }
                catch {
                    $sw.Stop()
                    [pscustomobject]@{
                        Index      = $_
                        Status     = -1
                        DurationMs = [int]$sw.ElapsedMilliseconds
                        Body       = $null
                        Error      = $_.Exception.Message
                    }
                }
            }
        }

    # --- 6. Print per-call summary ---
    Write-Host '== Results ==' -ForegroundColor Cyan
    $results |
        Sort-Object Index |
        Select-Object Index, Status, DurationMs, @{
            n = 'Transcript'; e = {
                if ($_.Body -is [pscustomobject] -and $_.Body.combinedPhrases) {
                    ($_.Body.combinedPhrases | Select-Object -First 1).text
                }
                elseif ($_.Error) { "ERROR: $($_.Error)" }
                else { ($_.Body | Out-String).Trim().Substring(0, [Math]::Min(120, ($_.Body | Out-String).Trim().Length)) }
            }
        } |
        Format-Table -AutoSize -Wrap

    # --- 7. Aggregate stats ---
    $ok   = ($results | Where-Object { $_.Status -eq 200 }).Count
    $fail = $results.Count - $ok
    $avg  = [int](($results | Measure-Object DurationMs -Average).Average)
    $p95  = ($results | Sort-Object DurationMs)[[int]([Math]::Ceiling($results.Count * 0.95) - 1)].DurationMs

    $okColor   = if ($fail -eq 0) { 'Green' } else { 'Yellow' }
    $failColor = if ($fail -eq 0) { 'Green' } else { 'Red' }

    Write-Host ''
    Write-Host '== Summary ==' -ForegroundColor Cyan
    Write-Host ("OK     : {0}/{1}" -f $ok, $results.Count) -ForegroundColor $okColor
    Write-Host ("Failed : {0}"      -f $fail)              -ForegroundColor $failColor
    Write-Host ("Avg ms : {0}"      -f $avg)
    Write-Host ("P95 ms : {0}"      -f $p95)

    if ($Concurrency -gt 1) {
        Write-Host ''
        Write-Host 'Tip: open APIM analytics or App Insights and filter by ' -NoNewline
        Write-Host '`backend-id`' -ForegroundColor Yellow -NoNewline
        Write-Host ' to confirm both Speech accounts received traffic.'
    }
}
finally {
    Pop-Location
}
