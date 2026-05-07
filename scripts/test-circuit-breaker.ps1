<#
.SYNOPSIS
    Verifies the APIM backend circuit breaker by temporarily breaking the
    primary Speech backend URL and observing pool failover + auto-recovery.

.DESCRIPTION
    The CB on each speech-* backend (apim.bicep) is configured as:
        - failureCondition : HTTP 429 or 500-599
        - count            : 5 within PT1M
        - tripDuration     : PT30S
        - acceptRetryAfter : true

    The submit-batch policy retries 429/5xx up to 3 times, so a single
    POST that hits a broken backend can burn ~4 failure counts. With
    primary deliberately broken, ~2 POSTs are enough to trip primary;
    after that, the pool's CB-aware load balancer routes 100% to
    secondary until the 30-s tripDuration elapses.

    The script:
      1. Reads the primary backend's current URL via Azure REST.
      2. PATCHes it to https://httpstat.us/500 (returns HTTP 500 fast).
      3. Phase A: sends sequential POSTs and watches each response's
         backend (parsed from the speechSelf host) to spot the moment
         the breaker trips.
      4. Phase B: sends parallel POSTs while the CB is open and asserts
         100% land on secondary.
      5. Phase C: sleeps past tripDuration (default 35 s).
      6. Phase D: restores the primary URL and verifies round-robin
         resumes.
      7. ALWAYS restores the primary URL in a finally{} block, even on
         Ctrl-C / failure.

    SAFETY: this script mutates an APIM backend configuration. The
    change is reverted at exit. Run only in dev/test environments.

.PARAMETER TripPosts
    Sequential POSTs sent in Phase A (trip the breaker). Default: 8.

.PARAMETER VerifyPosts
    Parallel POSTs sent in Phase B (verify CB is open). Default: 10.

.PARAMETER RecoveryWaitSec
    Sleep between restoring the URL and the round-robin re-check.
    Must be >= tripDuration (PT30S in apim.bicep). Default: 35.

.PARAMETER RecoveryPosts
    Parallel POSTs sent in Phase D (verify round-robin restored).
    Default: 10.

.PARAMETER BadUrl
    Backend URL injected as the "broken" target during the test.
    Must respond with 5xx fast. Default: https://httpstat.us/500.

.PARAMETER MaxParallel
    Cap on concurrent POSTs in Phases B and D. Default: 8.

.PARAMETER Yes
    Skip the interactive confirmation prompt.

.EXAMPLE
    pwsh ./scripts/test-circuit-breaker.ps1

.EXAMPLE
    pwsh ./scripts/test-circuit-breaker.ps1 -Yes -RecoveryWaitSec 40
#>
[CmdletBinding()]
param(
    [int]    $TripPosts       = 8,
    [int]    $VerifyPosts     = 10,
    [int]    $RecoveryWaitSec = 35,
    [int]    $RecoveryPosts   = 10,
    [string] $BadUrl          = 'https://httpstat.us/500',
    [int]    $MaxParallel     = 8,
    [switch] $Yes
)

$ErrorActionPreference = 'Stop'

$AudioUrl = 'https://github.com/Azure-Samples/cognitive-services-speech-sdk/raw/master/sampledata/audiofiles/aboutSpeechSdk.wav'

# ---------------------------------------------------------------------
# 1. Resolve azd env values + derive APIM name + backend ids.
# ---------------------------------------------------------------------
Write-Host '== Reading azd environment ==' -ForegroundColor Cyan
$envOutput = azd env get-values 2>&1
if ($LASTEXITCODE -ne 0) { throw "azd env get-values failed: $envOutput" }
$envValues = @{}
foreach ($line in $envOutput) {
    if ($line -match '^([A-Z0-9_]+)="?(.*?)"?$') {
        $envValues[$Matches[1]] = $Matches[2]
    }
}

$rg          = $envValues['AZURE_RESOURCE_GROUP']
$gatewayUrl  = $envValues['APIM_GATEWAY_URL']
$funcHost    = $envValues['FUNCTION_APP_HOSTNAME']
$primaryName = $envValues['SPEECH_PRIMARY_NAME']

foreach ($pair in @{ AZURE_RESOURCE_GROUP=$rg; APIM_GATEWAY_URL=$gatewayUrl; FUNCTION_APP_HOSTNAME=$funcHost; SPEECH_PRIMARY_NAME=$primaryName }.GetEnumerator()) {
    if (-not $pair.Value) { throw "$($pair.Key) not found in azd env. Run `azd up` first." }
}

# https://apim-XXXXX.azure-api.net/  ->  apim-XXXXX
$apimName        = ([uri]$gatewayUrl).Host.Split('.')[0]
$primaryBackend  = "speech-$primaryName"
$functionBase    = "https://$funcHost"
$subId           = (az account show --query id -o tsv)
if (-not $subId) { throw 'Could not resolve current Azure subscription. Run `az login` first.' }

$backendUri = "https://management.azure.com/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.ApiManagement/service/$apimName/backends/${primaryBackend}?api-version=2024-05-01"

Write-Host "Subscription   : $subId"
Write-Host "Resource Group : $rg"
Write-Host "APIM service   : $apimName"
Write-Host "Function base  : $functionBase"
Write-Host "Target backend : $primaryBackend"
Write-Host "Bad URL inject : $BadUrl"
Write-Host ''

if (-not $Yes) {
    $confirm = Read-Host 'This will TEMPORARILY break the primary Speech backend in APIM. Continue? [y/N]'
    if ($confirm -notmatch '^[Yy]') { Write-Host 'Aborted.' -ForegroundColor Yellow; exit 1 }
}

# ---------------------------------------------------------------------
# 2. Snapshot the primary backend URL so we can restore it in finally{}.
# ---------------------------------------------------------------------
try {
    $snapshotJson = az rest --method get --uri $backendUri --output json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "az rest GET failed: $snapshotJson" }
    $snapshot     = $snapshotJson | Out-String | ConvertFrom-Json
    $originalUrl  = $snapshot.properties.url
} catch {
    throw "Failed to read backend $primaryBackend. $($_.Exception.Message)"
}
if (-not $originalUrl) { throw "Backend $primaryBackend has no .properties.url; aborting." }
Write-Host "Original URL   : $originalUrl" -ForegroundColor Green
Write-Host ''

# ---------------------------------------------------------------------
# Helper: classify a single submit-batch POST response.
# Returns a pscustomobject with HttpCode + Backend (primary/secondary/unknown/none).
# ---------------------------------------------------------------------
function Invoke-SubmitProbe {
    param(
        [int]    $Idx,
        [string] $FunctionBase,
        [string] $AudioUrl
    )
    $payload = @{
        displayName = "cb-test-$Idx-$(Get-Date -Format 'HHmmssfff')"
        locale      = 'en-US'
        contentUrls = @($AudioUrl)
        properties  = @{ wordLevelTimestampsEnabled = $false }
    } | ConvertTo-Json -Depth 5
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest `
            -Uri "$FunctionBase/api/submit-batch" `
            -Method Post `
            -Body $payload `
            -ContentType 'application/json' `
            -TimeoutSec 60 `
            -SkipHttpErrorCheck
        $sw.Stop()
        $code = [int]$resp.StatusCode
        $backend = 'none'
        if ($code -eq 201) {
            $obj  = $resp.Content | ConvertFrom-Json
            $self = [string]$obj.speechSelf
            $backend = if     ($self -match 'spch-[^.]+-primary\.')   { 'primary' }
                       elseif ($self -match 'spch-[^.]+-secondary\.') { 'secondary' }
                       else                                           { 'unknown' }
        }
        return [pscustomobject]@{
            Idx       = $Idx
            HttpCode  = $code
            Backend   = $backend
            ElapsedMs = $sw.ElapsedMilliseconds
        }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{
            Idx       = $Idx
            HttpCode  = -1
            Backend   = 'error'
            ElapsedMs = $sw.ElapsedMilliseconds
        }
    }
}

# ---------------------------------------------------------------------
# Helper: PATCH the primary backend URL.
# Uses az rest because `az apim backend update` does not expose --url
# for an already-existing backend cleanly.
# ---------------------------------------------------------------------
function Set-PrimaryBackendUrl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSUseShouldProcessForStateChangingFunctions', '',
        Justification = 'Test script wraps each call in an explicit -Yes interactive confirmation and a try/finally restore.'
    )]
    param([string] $Url)
    $body = @{ properties = @{ url = $Url } } | ConvertTo-Json -Depth 5 -Compress
    $tmp  = New-TemporaryFile
    try {
        $body | Out-File -FilePath $tmp.FullName -Encoding utf8 -NoNewline
        az rest --method patch --uri $backendUri --headers 'Content-Type=application/json' --body "@$($tmp.FullName)" | Out-Null
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }
}

try {
    # ---------------------------------------------------------------------
    # 3. Inject the bad URL on the primary backend.
    # ---------------------------------------------------------------------
    Write-Host "== Injecting bad URL on $primaryBackend ==" -ForegroundColor Yellow
    Set-PrimaryBackendUrl -Url $BadUrl
    Write-Host '   PATCH applied. Waiting 5 s for APIM to refresh backend config...'
    Start-Sleep -Seconds 5

    # ---------------------------------------------------------------------
    # PHASE A: Sequential trip-the-breaker probes.
    # ---------------------------------------------------------------------
    Write-Host ''
    Write-Host "== Phase A: $TripPosts sequential POSTs (trip the breaker) ==" -ForegroundColor Cyan
    $phaseA = 1..$TripPosts | ForEach-Object {
        $r = Invoke-SubmitProbe -Idx $_ -FunctionBase $functionBase -AudioUrl $AudioUrl
        $marker = switch ($r.Backend) {
            'primary'   { 'P' }
            'secondary' { 'S' }
            'none'      { '!' }
            default     { '?' }
        }
        Write-Host ("   [{0,2}] http={1,4} backend={2,-9} {3,5}ms  {4}" -f $r.Idx, $r.HttpCode, $r.Backend, $r.ElapsedMs, $marker)
        $r
    }

    # ---------------------------------------------------------------------
    # PHASE B: Parallel verification that CB is open (100% secondary).
    # ---------------------------------------------------------------------
    Write-Host ''
    Write-Host "== Phase B: $VerifyPosts parallel POSTs (CB should be open) ==" -ForegroundColor Cyan
    $funcDef = ${function:Invoke-SubmitProbe}.ToString()
    $phaseB = 1..$VerifyPosts | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
        ${function:Invoke-SubmitProbe} = $using:funcDef
        Invoke-SubmitProbe -Idx $_ -FunctionBase $using:functionBase -AudioUrl $using:AudioUrl
    }
    $bSec = ($phaseB | Where-Object Backend -eq 'secondary').Count
    $bPri = ($phaseB | Where-Object Backend -eq 'primary').Count
    $bErr = $phaseB.Count - $bSec - $bPri
    Write-Host ("   secondary={0}  primary={1}  other={2}" -f $bSec, $bPri, $bErr)

    # ---------------------------------------------------------------------
    # PHASE C: Wait past tripDuration.
    # ---------------------------------------------------------------------
    Write-Host ''
    Write-Host "== Phase C: sleeping ${RecoveryWaitSec}s for CB to reset (tripDuration=PT30S) ==" -ForegroundColor Cyan
    Start-Sleep -Seconds $RecoveryWaitSec

    # ---------------------------------------------------------------------
    # 4. Restore the primary URL BEFORE Phase D so primary becomes healthy.
    # ---------------------------------------------------------------------
    Write-Host ''
    Write-Host "== Restoring $primaryBackend URL ==" -ForegroundColor Yellow
    Set-PrimaryBackendUrl -Url $originalUrl
    Write-Host '   PATCH applied. Waiting 5 s for APIM to refresh backend config...'
    Start-Sleep -Seconds 5
    $restored = $true   # signal finally{} no second restore is needed

    # ---------------------------------------------------------------------
    # PHASE D: Parallel POSTs verify round-robin distribution resumes.
    # ---------------------------------------------------------------------
    Write-Host ''
    Write-Host "== Phase D: $RecoveryPosts parallel POSTs (round-robin should resume) ==" -ForegroundColor Cyan
    $phaseD = 1..$RecoveryPosts | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
        ${function:Invoke-SubmitProbe} = $using:funcDef
        Invoke-SubmitProbe -Idx $_ -FunctionBase $using:functionBase -AudioUrl $using:AudioUrl
    }
    $dSec = ($phaseD | Where-Object Backend -eq 'secondary').Count
    $dPri = ($phaseD | Where-Object Backend -eq 'primary').Count
    $dErr = $phaseD.Count - $dSec - $dPri
    Write-Host ("   primary={0}  secondary={1}  other={2}" -f $dPri, $dSec, $dErr)

    # ---------------------------------------------------------------------
    # 5. Verdict.
    # ---------------------------------------------------------------------
    Write-Host ''
    Write-Host '== Verdict ==' -ForegroundColor Cyan
    $aPri  = ($phaseA | Where-Object Backend -eq 'primary').Count
    $aSec  = ($phaseA | Where-Object Backend -eq 'secondary').Count
    $aFail = ($phaseA | Where-Object HttpCode -ne 201).Count

    Write-Host ("Phase A : {0} primary  / {1} secondary / {2} non-201 (expected: some primary 5xx, then 100% secondary)" -f $aPri, $aSec, $aFail)
    Write-Host ("Phase B : {0} secondary / {1} primary  (expected: 100% secondary while CB open)" -f $bSec, $bPri)
    Write-Host ("Phase D : {0} primary  / {1} secondary (expected: roughly even round-robin)" -f $dPri, $dSec)

    $passB = ($bPri -eq 0 -and $bSec -gt 0)
    $passD = ($dPri -gt 0 -and $dSec -gt 0)

    if ($passB -and $passD) {
        Write-Host ''
        Write-Host 'PASS: CB tripped on primary, pool failed over to secondary, then auto-recovered.' -ForegroundColor Green
        $script:exitCode = 0
    } else {
        Write-Host ''
        if (-not $passB) { Write-Host "FAIL: Phase B saw primary traffic ($bPri); CB did not open." -ForegroundColor Red }
        if (-not $passD) { Write-Host "FAIL: Phase D distribution not round-robin (primary=$dPri secondary=$dSec)." -ForegroundColor Red }
        $script:exitCode = 1
    }
} finally {
    if (-not $restored) {
        Write-Host ''
        Write-Host "== finally{}: restoring $primaryBackend URL ==" -ForegroundColor Yellow
        try { Set-PrimaryBackendUrl -Url $originalUrl } catch { Write-Host "WARN: restore failed: $_" -ForegroundColor Red }
    }
}

exit ([int]($script:exitCode | ForEach-Object { $_ }))
