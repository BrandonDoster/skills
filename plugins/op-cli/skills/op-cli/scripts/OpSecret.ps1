<#
.SYNOPSIS
    Resolve 1Password secret references once per Claude Code session.

.DESCRIPTION
    1Password authorizes per process and every Claude tool call is a new
    process. Every reference not yet cached for this session is read inside this
    one process, so a call naming eight references prompts once. Values are cached DPAPI-encrypted
    (CurrentUser) under %LOCALAPPDATA%\claude-opcache\<session id>, so later
    tool calls in the same session never prompt.

    A cache folder belongs to the Claude process that created it (CLAUDE_PID
    plus that process's start time). A new session, or a resumed one (new
    process), gets nothing from it. Folders whose owning process is gone are
    wiped by the next call from any session; the SessionEnd hook wipes a
    session's own folder when it ends.

    One reference returns a string; several return a hashtable keyed by
    reference. Always assign the result - never let it print.

    Windows PowerShell 5.1 and PowerShell 7. Windows only (DPAPI).

.EXAMPLE
    . "<skill base directory>\scripts\OpSecret.ps1"
    $pw = Get-OpSecret 'op://Private/Example Login/password'

.EXAMPLE
    $c = Get-OpSecret 'op://A/vcenter/username', 'op://A/vcenter/password'   # one prompt
    $cred = [pscredential]::new($c['op://A/vcenter/username'], (ConvertTo-SecureString $c['op://A/vcenter/password'] -AsPlainText -Force))

.EXAMPLE
    $pw = Get-OpSecret 'op://Private/Example Login/password' -Force   # after a rotation
#>

function Get-OpCacheRoot {
    if ($env:CLAUDE_OPCACHE_DIR){
        return $env:CLAUDE_OPCACHE_DIR
    }
    return (Join-Path $env:LOCALAPPDATA 'claude-opcache')
}

## "<pid>|<start ticks>" for a live process, $null when it is gone
function Get-OpProcessStamp {
    param([int]$ProcessId)

    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $proc){
        return $null
    }
    try {
        return "$ProcessId|$($proc.StartTime.ToUniversalTime().Ticks)"
    }catch{
        return "$ProcessId|unknown"
    }
}

function Remove-OpCacheFolder {
    param([string]$Path)

    # Secrets must not go to the Recycle Bin, so this is a real delete. Ciphertext only.
    try {
        [System.IO.Directory]::Delete($Path, $true)
    }catch{
        Write-Warning "Could not wipe op cache folder $Path : $($_.Exception.Message)"
    }
}

## Returns this session's cache folder, claimed for this Claude process; wipes dead sessions' folders
function Initialize-OpSessionCache {
    if ($env:OS -ne 'Windows_NT'){
        throw 'Get-OpSecret caches with DPAPI and runs on Windows only.'
    }
    $sessionId = $env:CLAUDE_CODE_SESSION_ID
    if ([string]::IsNullOrEmpty($sessionId) -or [string]::IsNullOrEmpty($env:CLAUDE_PID)){
        throw 'CLAUDE_CODE_SESSION_ID / CLAUDE_PID not set - Get-OpSecret only runs inside a Claude Code tool call.'
    }
    $sessionId = $sessionId -replace '[^\w-]', ''
    $owner = Get-OpProcessStamp ([int]$env:CLAUDE_PID)
    $root = Get-OpCacheRoot
    $dir = Join-Path $root $sessionId
    $ownerFile = Join-Path $dir 'owner'
    $marker = Join-Path $dir '.skill-loaded'

    ## Own folder: keep only if this same Claude process created it (a resume is a new process).
    ## The gate hook's marker may be fresh from this process, so it survives the wipe.
    if (Test-Path $ownerFile){
        if ((Get-Content -Path $ownerFile -Raw).Trim() -ne $owner){
            $hadMarker = Test-Path $marker
            Remove-OpCacheFolder $dir
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            if ($hadMarker -eq $true){
                New-Item -ItemType File -Path $marker | Out-Null
            }
        }
    }
    if ((Test-Path $dir) -eq $false){
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    if ((Test-Path $ownerFile) -eq $false){
        Set-Content -Path $ownerFile -Value $owner -NoNewline -Encoding ascii
    }

    ## Other sessions: wipe only when the owning process is gone. Running sessions are never touched.
    foreach ($other in (Get-ChildItem -Path $root -Directory)){
        if ($other.Name -eq $sessionId){
            continue
        }
        $otherOwner = Join-Path $other.FullName 'owner'
        if ((Test-Path $otherOwner) -eq $false){
            continue    # no secrets cached there yet; its SessionEnd hook cleans it
        }
        $stamp = (Get-Content -Path $otherOwner -Raw).Trim()
        $otherPid = 0
        if ([int]::TryParse(($stamp -split '\|')[0], [ref]$otherPid) -eq $false -or $stamp -ne (Get-OpProcessStamp $otherPid)){
            Remove-OpCacheFolder $other.FullName
        }
    }
    return $dir
}

function Get-OpRefHash {
    param([string]$Reference)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Reference))
    $sha.Dispose()
    return ([System.BitConverter]::ToString($bytes).Replace('-', '').Substring(0, 32))
}

function Get-OpSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [ValidatePattern('^op://')]
        [string[]]$Reference,

        ## Ignore cached copies and re-read from 1Password (use after a rotation)
        [switch]$Force
    )

    $dir = Initialize-OpSessionCache
    $values = @{}
    $misses = @()

    ## Cache hits: decrypt, no prompt
    foreach ($ref in $Reference){
        $file = Join-Path $dir ((Get-OpRefHash $ref) + '.bin')
        if ($Force -eq $false -and (Test-Path $file)){
            $secure = (Get-Content -Path $file -Raw).Trim() | ConvertTo-SecureString
            $values[$ref] = [System.Net.NetworkCredential]::new('', $secure).Password
        }else{
            $misses += $ref
        }
    }

    ## Misses: all read in this one process. 1Password authorizes per process, so the whole
    ## loop is one prompt (verified 2026-10-23: two `op read`s in one tool call, one prompt).
    $failed = @()
    foreach ($ref in $misses){
        $value = @(op read $ref) -join "`n"
        if ($LASTEXITCODE -ne 0){
            $failed += $ref
            continue
        }
        $values[$ref] = $value
        if ($value -eq ''){
            continue    # SecureString cannot hold empty; nothing worth caching
        }
        $file = Join-Path $dir ((Get-OpRefHash $ref) + '.bin')
        ConvertTo-SecureString -String $value -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -Path $file -NoNewline -Encoding ascii
    }
    $value = $null

    if ($failed.Count -gt 0){
        throw "op read failed for: $($failed -join ', '). Approve the 1Password prompt / unlock the desktop app, or check the reference. Others in this call were cached."
    }
    if ($Reference.Count -eq 1){
        return $values[$Reference[0]]
    }
    return $values
}

## Wipe this session's cached secrets now
function Clear-OpSecretCache {
    [CmdletBinding()]
    param()

    $dir = Join-Path (Get-OpCacheRoot) ($env:CLAUDE_CODE_SESSION_ID -replace '[^\w-]', '')
    if ($env:CLAUDE_CODE_SESSION_ID -and (Test-Path $dir)){
        Remove-OpCacheFolder $dir
        Write-Host 'op secret cache cleared for this session.' -ForegroundColor Green
    }else{
        Write-Host 'op secret cache already empty for this session.' -ForegroundColor Green
    }
}
