#Requires -Version 5.1
<#
.SYNOPSIS
    Demo launcher for Invoke-SqlInitialAssessment.ps1
#>

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

Write-Host 'SQL Server Initial Assessment - demo runner' -ForegroundColor Cyan
Write-Host 'You will be prompted for the SQL login (e.g. sa).' -ForegroundColor Yellow

$server = Read-Host 'SQL Server (IP, host\instance, or host,port)'
if ([string]::IsNullOrWhiteSpace($server)) {
    throw 'Server is required.'
}

$credential = Get-Credential -UserName 'sa' -Message 'SQL login for assessment'
& (Join-Path $PSScriptRoot 'Invoke-SqlInitialAssessment.ps1') `
    -ServerIP $server `
    -Credential $credential `
    -DaysToAnalyze 90 `
    -OpenReport
