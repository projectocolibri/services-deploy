param(
    [ValidateSet("check", "update", "run")]
    [string]$Command = "run"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$versionFile = Join-Path $root ".version"

Set-Location $root

function Invoke-Git {
    param([string[]]$Arguments)
    & git @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Git command failed: git $($Arguments -join ' ')"
    }
}

function Get-LatestTag {
    $tags = @(git tag --list "v*" |
        Where-Object { $_ -match '^v\d+\.\d+\.\d+$' } |
        ForEach-Object {
            [PSCustomObject]@{ Name = $_; Version = [version]$_.Substring(1) }
        } |
        Sort-Object Version)
    if ($tags.Count -eq 0) {
        throw "No semantic version tags (vMAJOR.MINOR.PATCH) were found."
    }
    return $tags[-1].Name
}

function Get-CurrentVersion {
    if (-not (Test-Path $versionFile)) {
        return ""
    }
    return (Get-Content $versionFile -Raw).Trim()
}

Invoke-Git @("fetch", "origin", "--tags", "--prune")
$latest = Get-LatestTag
$current = Get-CurrentVersion
$shouldRun = $Command -eq "run"

if ($Command -eq "check") {
    if ([string]::IsNullOrWhiteSpace($current)) {
        Write-Host "No deployed version recorded. Latest available: $latest"
    } elseif ($current -eq $latest) {
        Write-Host "Already running $current"
    } else {
        Write-Host "Update available: $current -> $latest"
    }
    exit 0
}

if ($Command -eq "run" -and ([string]::IsNullOrWhiteSpace($current) -or $current -ne $latest)) {
    $prompt = if ([string]::IsNullOrWhiteSpace($current)) {
        "No deployed version recorded. Deploy $latest now? [y/N]"
    } else {
        "Update from $current to $latest before starting? [y/N]"
    }
    $answer = Read-Host $prompt
    if ($answer -notmatch '^(y|yes)$') {
        if ([string]::IsNullOrWhiteSpace($current)) {
            throw "Cannot run without a deployed version. Use update or confirm deployment."
        }
        Write-Host "Starting the current version $current"
    } else {
        $Command = "update"
    }
}

if ($Command -eq "update") {
    $previous = & git rev-parse --verify HEAD
    Invoke-Git @("reset", "--hard", $latest)
    try {
        & docker compose config --quiet
        if ($LASTEXITCODE -ne 0) {
            throw "Compose validation failed for $latest"
        }
        Set-Content -Path $versionFile -Value $latest -NoNewline
        Write-Host "Updated infrastructure to $latest"
    } catch {
        Invoke-Git @("reset", "--hard", $previous)
        throw
    }
}

& docker compose config --quiet
if ($LASTEXITCODE -ne 0) {
    throw "Compose validation failed"
}

if ($shouldRun) {
    & docker compose up -d
    if ($LASTEXITCODE -ne 0) {
        throw "Compose deployment failed"
    }
    Write-Host "Deployment is running"
}
