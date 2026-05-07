<#
.SYNOPSIS
    Load-tests the APIM-load-balanced Speech batch transcription pipeline.

.DESCRIPTION
    Submits N batch transcription jobs in parallel through the Function App,
    then polls every job concurrently until each reaches a terminal state.

    What this validates:
      * APIM pool round-robins submissions across both Speech accounts
        (you should see jobs split roughly 50/50 between primary & secondary).
      * APIM jobId -> backend cache reliably pins each poll to the same
        Speech account that accepted the original POST. A single 404 on
        a poll proves a pinning failure (the cache missed and the request
        was sent to the wrong account).
      * The Function App, plan, and Speech accounts handle the concurrent
        submit + poll load without throttling.

    Output: summary table with backend distribution, success counts,
    poll counts, end-to-end durations (min/avg/max), and any 404 hits.

.PARAMETER Count
    Number of batch jobs to submit in parallel. Default: 10.

.PARAMETER PollIntervalSec
    Seconds between status polls per job. Default: 5.

.PARAMETER TimeoutSec
    Per-job hard timeout. Default: 600 (10 min).

.PARAMETER Locale
    BCP-47 locale. Default: en-US (matches the public sample audio).

.PARAMETER BatchAudioUrls
    One or more public audio URLs used as input for the jobs. Jobs are
    assigned round-robin across the list (job N uses URL N modulo Count).
    Defaults to three Microsoft Speech SDK sample files (en-US):
        aboutSpeechSdk.wav, katiesteve.wav, speechService.wav.
    Pass a single URL to use the same file for every job, or supply your
    own list to exercise a wider mix of durations / voices / content.

.PARAMETER MaxParallel
    Cap on concurrent submit + poll threads. Default: 10
    (PowerShell ForEach-Object -Parallel default sweet spot).

.EXAMPLE
    pwsh ./scripts/load-test.ps1 -Count 10

.EXAMPLE
    pwsh ./scripts/load-test.ps1 -Count 25 -MaxParallel 8 -Locale en-US

.EXAMPLE
    # Use a custom audio mix (URL list cycled round-robin per job)
    pwsh ./scripts/load-test.ps1 -Count 9 -BatchAudioUrls @(
        'https://example.com/short.wav',
        'https://example.com/medium.wav',
        'https://example.com/long.wav'
    )
#>
[CmdletBinding()]
param(
    [int]      $Count           = 10,
    [int]      $PollIntervalSec = 5,
    [int]      $TimeoutSec      = 600,
    [string]   $Locale          = 'en-US',
    [string[]] $BatchAudioUrls  = @(
        'https://github.com/Azure-Samples/cognitive-services-speech-sdk/raw/master/sampledata/audiofiles/aboutSpeechSdk.wav',
        'https://github.com/Azure-Samples/cognitive-services-speech-sdk/raw/master/sampledata/audiofiles/katiesteve.wav',
        'https://github.com/Azure-Samples/cognitive-services-speech-sdk/raw/master/sampledata/audiofiles/speechService.wav'
    ),
    [int]      $MaxParallel     = 10
)

$ErrorActionPreference = 'Stop'

# --- 1. Resolve endpoints from azd ---
Write-Host '== Reading azd environment ==' -ForegroundColor Cyan
$envOutput  = azd env get-values 2>$null
$envValues  = @{}
foreach ($line in $envOutput) {
    if ($line -match '^([A-Z0-9_]+)="?(.*?)"?$') {
        $envValues[$Matches[1]] = $Matches[2]
    }
}
$functionHost = $envValues['FUNCTION_APP_HOSTNAME']
if (-not $functionHost) {
    throw 'FUNCTION_APP_HOSTNAME not found in azd env. Run `azd up` first.'
}
$functionBase = "https://$functionHost"

Write-Host "Function App : $functionBase" -ForegroundColor Green
Write-Host "Jobs         : $Count (max parallel: $MaxParallel)"
Write-Host "Locale       : $Locale"
Write-Host "Audio mix    : $($BatchAudioUrls.Count) URL(s) cycled round-robin"
$BatchAudioUrls | ForEach-Object { Write-Host "               - $_" }
Write-Host ''

# --- 2. Pre-flight health ---
$health = Invoke-RestMethod -Uri "$functionBase/api/health" -Method Get -TimeoutSec 30
if ($health.status -ne 'ok') {
    throw "Health check failed: $($health | ConvertTo-Json -Compress)"
}

# ---------------------------------------------------------------------
# Phase A: Submit N jobs in parallel.
# ---------------------------------------------------------------------
Write-Host "== Phase A: submitting $Count jobs in parallel ==" -ForegroundColor Cyan
$swSubmit = [Diagnostics.Stopwatch]::StartNew()

$submitResults = 1..$Count | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
    $idx           = $_
    $functionBase  = $using:functionBase
    $locale        = $using:Locale
    $audioUrls     = $using:BatchAudioUrls
    # Round-robin assignment: job N picks URL (N-1) mod Count(URLs).
    $audioUrl      = $audioUrls[($idx - 1) % $audioUrls.Count]
    $audioName     = ($audioUrl -split '/')[-1]
    $payload = @{
        displayName = "loadtest-$idx-$audioName-$(Get-Date -Format 'HHmmssfff')"
        locale      = $locale
        contentUrls = @($audioUrl)
        properties  = @{ wordLevelTimestampsEnabled = $false }
    } | ConvertTo-Json -Depth 5

    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest `
            -Uri "$functionBase/api/submit-batch" `
            -Method Post `
            -Body $payload `
            -ContentType 'application/json' `
            -TimeoutSec 60 `
            -SkipHttpErrorCheck
        $sw.Stop()
        $code = [int]$resp.StatusCode
        if ($code -ne 201) {
            return [pscustomobject]@{
                Index    = $idx
                Status   = 'submit_failed'
                HttpCode = $code
                Body     = $resp.Content
                Backend  = $null
                JobId    = $null
                Audio    = $audioName
                ElapsedMs = $sw.ElapsedMilliseconds
            }
        }
        $obj      = $resp.Content | ConvertFrom-Json
        $self     = [string]$obj.speechSelf
        $backend  = if     ($self -match 'spch-[^.]+-primary\.')   { 'primary' }
                    elseif ($self -match 'spch-[^.]+-secondary\.') { 'secondary' }
                    else                                           { 'unknown' }
        return [pscustomobject]@{
            Index     = $idx
            Status    = 'submitted'
            HttpCode  = $code
            Backend   = $backend
            JobId     = $obj.jobId
            SpeechSelf= $obj.speechSelf
            Audio     = $audioName
            ElapsedMs = $sw.ElapsedMilliseconds
        }
    } catch {
        $sw.Stop()
        return [pscustomobject]@{
            Index     = $idx
            Status    = 'submit_error'
            HttpCode  = -1
            Backend   = $null
            JobId     = $null
            Audio     = $audioName
            ElapsedMs = $sw.ElapsedMilliseconds
            Error     = $_.Exception.Message
        }
    }
}

$swSubmit.Stop()
$submitted = $submitResults | Where-Object { $_.Status -eq 'submitted' }
$failedSub = $submitResults | Where-Object { $_.Status -ne 'submitted' }

Write-Host ("Submit phase  : {0}/{1} accepted in {2}s ({3} ms median)" -f `
    $submitted.Count, $Count, [int]($swSubmit.Elapsed.TotalSeconds),
    [int](($submitResults.ElapsedMs | Measure-Object -Average).Average))

$primaryCount   = ($submitted | Where-Object Backend -eq 'primary'  ).Count
$secondaryCount = ($submitted | Where-Object Backend -eq 'secondary').Count
Write-Host ("Distribution  : primary={0}  secondary={1}" -f $primaryCount, $secondaryCount) -ForegroundColor Green

if ($failedSub) {
    Write-Host "Failed submits:" -ForegroundColor Red
    $failedSub | Format-Table Index, HttpCode, Status, Error, Body -AutoSize | Out-String | Write-Host
}

if (-not $submitted -or $submitted.Count -eq 0) {
    Write-Host 'No jobs submitted; aborting.' -ForegroundColor Red
    return
}

# ---------------------------------------------------------------------
# Phase B: Poll all submitted jobs in parallel until terminal state.
# Each thread loops Get /api/batch-status/{jobId}.
# A 404 anywhere = cache pinning failure.
# ---------------------------------------------------------------------
Write-Host ''
Write-Host "== Phase B: polling $($submitted.Count) jobs in parallel ==" -ForegroundColor Cyan
$swPoll = [Diagnostics.Stopwatch]::StartNew()

$pollResults = $submitted | ForEach-Object -ThrottleLimit $MaxParallel -Parallel {
    $job             = $_
    $functionBase    = $using:functionBase
    $pollIntervalSec = $using:PollIntervalSec
    $timeoutSec      = $using:TimeoutSec

    $sw           = [Diagnostics.Stopwatch]::StartNew()
    $polls        = 0
    $not_found_404 = 0
    $other_errors  = 0
    $finalStatus  = 'Unknown'

    while ($true) {
        Start-Sleep -Seconds $pollIntervalSec
        $polls++
        try {
            $resp = Invoke-WebRequest `
                -Uri "$functionBase/api/batch-status/$($job.JobId)" `
                -Method Get `
                -TimeoutSec 30 `
                -SkipHttpErrorCheck
        } catch {
            $other_errors++
            if ($sw.Elapsed.TotalSeconds -gt $timeoutSec) { $finalStatus = 'PollException'; break }
            continue
        }
        $code = [int]$resp.StatusCode
        if ($code -eq 404) {
            $not_found_404++
            $finalStatus = 'PinFailure404'
            break
        }
        if ($code -ne 200) {
            $other_errors++
            if ($sw.Elapsed.TotalSeconds -gt $timeoutSec) { $finalStatus = 'PollHttpError'; break }
            continue
        }
        $obj = $resp.Content | ConvertFrom-Json
        if ($obj.status -in 'Succeeded','Failed') { $finalStatus = $obj.status; break }
        if ($sw.Elapsed.TotalSeconds -gt $timeoutSec) { $finalStatus = 'Timeout'; break }
    }
    $sw.Stop()

    [pscustomobject]@{
        Index         = $job.Index
        JobId         = $job.JobId
        Backend       = $job.Backend
        Audio         = $job.Audio
        Polls         = $polls
        Not_Found_404 = $not_found_404
        Other_Errors  = $other_errors
        FinalStatus   = $finalStatus
        ElapsedSec    = [int]$sw.Elapsed.TotalSeconds
    }
}

$swPoll.Stop()

# ---------------------------------------------------------------------
# Phase C: Report.
# ---------------------------------------------------------------------
Write-Host ''
Write-Host '== Results ==' -ForegroundColor Cyan
$pollResults |
    Sort-Object Index |
    Format-Table Index, Backend, Audio, FinalStatus, Polls, Not_Found_404, Other_Errors, ElapsedSec, JobId -AutoSize |
    Out-String | Write-Host

$succeeded = ($pollResults | Where-Object FinalStatus -eq 'Succeeded').Count
$failed    = ($pollResults | Where-Object FinalStatus -eq 'Failed').Count
$pin404    = ($pollResults | Where-Object FinalStatus -eq 'PinFailure404').Count
$timeouts  = ($pollResults | Where-Object FinalStatus -eq 'Timeout').Count
$other     = $pollResults.Count - $succeeded - $failed - $pin404 - $timeouts
$total404  = ($pollResults | Measure-Object Not_Found_404 -Sum).Sum
$pollDur   = $pollResults | Measure-Object ElapsedSec -Min -Max -Average

Write-Host '== Summary ==' -ForegroundColor Cyan
Write-Host ('Submit wall   : {0}s for {1} POSTs' -f [int]$swSubmit.Elapsed.TotalSeconds, $Count)
Write-Host ('Poll wall     : {0}s for {1} jobs' -f [int]$swPoll.Elapsed.TotalSeconds, $pollResults.Count)
Write-Host ('Distribution  : primary={0}  secondary={1}' -f $primaryCount, $secondaryCount)
Write-Host  'Audio mix     :'
$pollResults |
    Group-Object Audio |
    Sort-Object Name |
    ForEach-Object {
        $okCount = ($_.Group | Where-Object FinalStatus -eq 'Succeeded').Count
        Write-Host ("                {0,-30} jobs={1,3}  succeeded={2,3}" -f $_.Name, $_.Count, $okCount)
    }
Write-Host ("Succeeded     : $succeeded / $($pollResults.Count)") -ForegroundColor Green
if ($failed)   { Write-Host ("Failed        : $failed")          -ForegroundColor Yellow }
if ($timeouts) { Write-Host ("Timeouts      : $timeouts")        -ForegroundColor Yellow }
if ($other)    { Write-Host ("Other         : $other")           -ForegroundColor Yellow }
if ($pin404)   { Write-Host ("PINNING FAIL  : $pin404 (got 404 - cache miss routed to wrong backend)") -ForegroundColor Red }
Write-Host ("Total 404s    : $total404")
Write-Host ("Poll duration : min={0}s avg={1}s max={2}s" -f `
    [int]$pollDur.Minimum, [int]$pollDur.Average, [int]$pollDur.Maximum)

if ($pin404 -gt 0 -or $total404 -gt 0) {
    Write-Host ''
    Write-Host 'FAIL: Cache pinning is not working - at least one poll was routed to the wrong backend.' -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host 'PASS: Pool round-robin + jobId cache pinning are working under load.' -ForegroundColor Green
