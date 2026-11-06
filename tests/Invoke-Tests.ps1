# tests\Invoke-Tests.ps1
# Lance les tests Pester de l'agent.

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot

if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge '5.0' })) {
    Write-Host "Pester 5+ requis. Installation..." -ForegroundColor Yellow
    Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0 -Force -SkipPublisherCheck
}

Import-Module Pester -MinimumVersion 5.0

$config = New-PesterConfiguration
$config.Run.Path       = Join-Path $here "AutoSaveGit.Tests.ps1"
$config.Output.Verbosity = "Detailed"
$config.Run.Exit       = $false

Invoke-Pester -Configuration $config