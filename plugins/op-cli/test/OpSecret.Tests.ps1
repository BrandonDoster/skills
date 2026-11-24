# Offline checks for OpSecret.ps1. `op` is stubbed; nothing touches 1Password or the real cache.
# Run: powershell -NoProfile -File plugins/op-cli/test/OpSecret.Tests.ps1   (and with pwsh)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\skills\op-cli\scripts\OpSecret.ps1')

$root = Join-Path ([System.IO.Path]::GetTempPath()) "opcache-test-$PID"
$env:CLAUDE_OPCACHE_DIR = $root
$env:CLAUDE_CODE_SESSION_ID = 'test-session'
$env:CLAUDE_PID = "$PID"
$script:opCalls = @()

## Stub `op read`: functions win over op.exe in command resolution. Records each ref read.
function op {
    $script:opCalls += $args[1]
    if ($args[1] -like '*missing*'){
        $global:LASTEXITCODE = 1
        return
    }
    $global:LASTEXITCODE = 0
    if ($args[1] -like '*/multi'){
        return @('line1', 'line2')    # native multi-line output arrives as an array
    }
    return "secret-for-$($args[1])"
}

$failures = 0
function Check {
    param([string]$Name, [bool]$Ok)
    if ($Ok -eq $true){
        Write-Host "PASS  $Name" -ForegroundColor Green
    }else{
        Write-Warning "FAIL  $Name"
        $script:failures++
    }
}

try {
    $dir = Join-Path $root 'test-session'

    ## 1. miss reads once, hit reads never
    $v = Get-OpSecret 'op://V/a/password'
    $v2 = Get-OpSecret 'op://V/a/password'
    Check 'single miss then hit: one op call' ($script:opCalls.Count -eq 1 -and $v -eq 'secret-for-op://V/a/password' -and $v2 -eq $v)

    ## 2. batch: only the misses are read, result keyed by reference
    $script:opCalls = @()
    $c = Get-OpSecret 'op://V/a/password', 'op://V/b/password', 'op://V/c/password'
    Check 'batch reads only the misses' ($script:opCalls.Count -eq 2 -and $c['op://V/c/password'] -eq 'secret-for-op://V/c/password' -and $c['op://V/a/password'] -eq 'secret-for-op://V/a/password' -and $c.Count -eq 3)
    $script:opCalls = @()
    $null = Get-OpSecret 'op://V/a/password', 'op://V/b/password', 'op://V/c/password'
    Check 'batch all cached: zero op calls' ($script:opCalls.Count -eq 0)

    ## 3. nothing plaintext on disk
    $plain = Get-ChildItem $dir -Filter '*.bin' | Where-Object { (Get-Content $_.FullName -Raw) -like '*secret-for*' }
    Check 'cache files hold no plaintext' ($null -eq $plain -and (Get-ChildItem $dir -Filter '*.bin').Count -eq 3)

    ## 4. -Force re-reads
    $script:opCalls = @()
    $null = Get-OpSecret 'op://V/a/password' -Force
    Check '-Force re-reads' ($script:opCalls.Count -eq 1)

    ## 5. failure: throws naming the bad ref, still caches the good one
    $threw = $false
    try { $null = Get-OpSecret 'op://V/missing/password', 'op://V/d/password' }catch{ $threw = $_.Exception.Message -like '*op://V/missing/password*' }
    $script:opCalls = @()
    $null = Get-OpSecret 'op://V/d/password'
    Check 'failure throws with ref, good one cached' ($threw -eq $true -and $script:opCalls.Count -eq 0)

    ## 5b. multi-line value survives the fence split and the cache
    $m1 = Get-OpSecret 'op://V/x/multi', 'op://V/e/password'
    $m2 = Get-OpSecret 'op://V/x/multi'
    Check 'multi-line value intact' ($m1['op://V/x/multi'] -eq "line1`nline2" -and $m2 -eq "line1`nline2" -and $m1['op://V/e/password'] -eq 'secret-for-op://V/e/password')

    ## 6. another process's folder (a resume): wiped, re-prompts, marker survives
    Set-Content -Path (Join-Path $dir 'owner') -Value "$PID|1" -NoNewline
    New-Item -ItemType File -Path (Join-Path $dir '.skill-loaded') -Force | Out-Null
    $script:opCalls = @()
    $null = Get-OpSecret 'op://V/a/password'
    Check 'resumed session re-prompts' ($script:opCalls.Count -eq 1 -and (Get-ChildItem $dir -Filter '*.bin').Count -eq 1)
    Check 'gate marker survives the wipe' (Test-Path (Join-Path $dir '.skill-loaded'))

    ## 7. dead session wiped, live session and unowned folder kept
    $dead = Join-Path $root 'dead-session'; $live = Join-Path $root 'live-session'; $unowned = Join-Path $root 'unowned-session'
    New-Item -ItemType Directory -Path $dead, $live, $unowned -Force | Out-Null
    Set-Content -Path (Join-Path $dead 'owner') -Value '999999|1' -NoNewline
    Set-Content -Path (Join-Path $live 'owner') -Value (Get-OpProcessStamp $PID) -NoNewline
    $null = Get-OpSecret 'op://V/a/password'
    Check 'dead session wiped' ((Test-Path $dead) -eq $false)
    Check 'live session kept' (Test-Path $live)
    Check 'unowned folder kept' (Test-Path $unowned)

    ## 8. Clear-OpSecretCache
    Clear-OpSecretCache | Out-Null
    Check 'Clear-OpSecretCache wipes this session' ((Test-Path $dir) -eq $false)
}finally{
    if (Test-Path $root){
        [System.IO.Directory]::Delete($root, $true)
    }
}

if ($failures -gt 0){
    throw "$failures check(s) failed"
}
Write-Host 'All OpSecret checks passed.' -ForegroundColor Green
