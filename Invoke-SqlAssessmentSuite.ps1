#Requires -Version 5.1
<#
.SYNOPSIS
    One entry point for the SQL Server upgrade advisor and both assessment collectors.

.DESCRIPTION
    Interactive mode shows a menu when -Tool is omitted. Unattended mode requires -Tool
    and the values that tool needs, and never prompts.

    Engines stay in ps_report_collector. This script validates input, builds an explicit
    parameter splat, and returns one result object. SQL connectivity for the assessment
    tools is built-in ADO.NET. The upgrade advisor already uses ADO.NET. dbatools is
    not required. Assessment Excel still needs the ImportExcel module.

.PARAMETER Tool
    UpgradeAdvisor, AssessmentLight, or AssessmentFull. Required when prompts are not allowed.

.PARAMETER ServerInstance
    SQL Server host, host\instance, or host,port. Aliases: ServerIP, SqlInstance.

.PARAMETER Credential
    SQL authentication credential. Never written to the log, manifest, or result object.

.PARAMETER UseWindowsAuthentication
    Upgrade Advisor only. Assessment tools stay on SQL authentication.

.PARAMETER Database
    Database names. Comma-separated text and arrays are both accepted.
    Aliases: DatabaseList, Databases. Blank means all eligible user databases.
    AssessmentLight accepts at most one name. Upgrade Advisor also accepts wildcards.

.PARAMETER OutputFormat
    Html, Excel, or Both. Alias: o. Default Html.
    For the upgrade advisor, Both writes HTML and Excel only. JSON and SARIF stay
    behind -AdditionalOutputFormat.

.PARAMETER OutputPath
    Parent folder for this run. The script creates a timestamped subdirectory inside it.

.PARAMETER OpenReport
    Open the HTML report when one was written, otherwise the Excel workbook.

.PARAMETER NonInteractive
    Never prompt. Missing required values are a terminating validation error.

.PARAMETER DemoMode
    Upgrade Advisor only. Builds the sample report without a SQL Server.

.EXAMPLE
    .\Invoke-SqlAssessmentSuite.ps1

.EXAMPLE
    $cred = Get-Credential
    .\Invoke-SqlAssessmentSuite.ps1 -Tool AssessmentFull -ServerInstance 'sql01' -Credential $cred -OutputFormat Both -NonInteractive

.EXAMPLE
    .\Invoke-SqlAssessmentSuite.ps1 -Tool UpgradeAdvisor -DemoMode -TargetVersion 2025 -OutputFormat Both -NonInteractive
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateSet('UpgradeAdvisor', 'AssessmentLight', 'AssessmentFull')]
    [string]$Tool,

    [Parameter()]
    [Alias('ServerIP', 'SqlInstance')]
    [string]$ServerInstance,

    [Parameter()]
    [Alias('SqlCredential')]
    [pscredential]$Credential,

    [Parameter()]
    [switch]$UseWindowsAuthentication,

    [Parameter()]
    [Alias('DatabaseList', 'Databases')]
    [string[]]$Database,

    [Parameter()]
    [Alias('o')]
    [ValidateSet('Html', 'Excel', 'Both')]
    [string]$OutputFormat = 'Html',

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$OpenReport,

    [Parameter()]
    [switch]$NonInteractive,

    [Parameter()]
    [ValidateRange(1, 3650)]
    [int]$DaysToAnalyze = 90,

    [Parameter()]
    [ValidateRange(1, 720)]
    [int]$FullBackupSlaHours = 24,

    [Parameter()]
    [ValidateRange(1, 1440)]
    [int]$LogBackupSlaMinutes = 30,

    [Parameter()]
    [ValidateSet('2022', '2025')]
    [string]$TargetVersion = '2022',

    [Parameter()]
    [int]$TargetCompatibilityLevel = 0,

    [Parameter()]
    [ValidateSet('Full', 'HashOnly')]
    [string]$DefinitionsMode = 'Full',

    [Parameter()]
    [switch]$IncludeSystemDatabases,

    [Parameter()]
    [switch]$ExportAllFindings,

    [Parameter()]
    [string]$RulesPath,

    [Parameter()]
    [string]$SqlPath,

    [Parameter()]
    [int]$MaxFindingsInReport = 5000,

    [Parameter()]
    [bool]$Encrypt = $true,

    [Parameter()]
    [switch]$TrustServerCertificate,

    [Parameter()]
    [int]$QueryTimeoutSec = 300,

    [Parameter()]
    [switch]$DemoMode,

    [Parameter()]
    [ValidateSet('Json', 'Sarif')]
    [string[]]$AdditionalOutputFormat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SuiteBoundParameters = @{}
foreach ($boundName in @($PSBoundParameters.Keys)) {
    $script:SuiteBoundParameters[$boundName] = $true
}

$script:SuiteStartedAt = [datetime]::UtcNow
$script:SuiteExitCode = 0
$script:SuiteRunDirectory = $null
$script:SuiteWarnings = New-Object System.Collections.Generic.List[string]
$script:SuiteErrors = New-Object System.Collections.Generic.List[string]
$script:SuitePhase = 'Validation'

$SuiteRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SuiteRoot)) {
    $SuiteRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$CollectorRoot = Join-Path $SuiteRoot 'ps_report_collector'
$EnginePath = @{
    AssessmentFull  = Join-Path $CollectorRoot 'Invoke-SqlInitialAssessment.ps1'
    AssessmentLight = Join-Path $CollectorRoot 'Invoke-SqlInitialAssessment_minimal.ps1'
    UpgradeAdvisor  = Join-Path $CollectorRoot 'sql_version_compatiblity_checker\Invoke-SqlUpgradeAdvisor.ps1'
}

function Test-SuiteCanPrompt {
    if ($NonInteractive) { return $false }
    try {
        if ([Console]::IsInputRedirected) { return $false }
    }
    catch { }
    return $true
}

function Read-SuiteChoice {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string[]]$Allowed,
        [string]$BlankValue
    )
    while ($true) {
        $answer = Read-Host $Prompt
        if ([string]::IsNullOrWhiteSpace($answer)) {
            if ($PSBoundParameters.ContainsKey('BlankValue')) { return $BlankValue }
            Write-Host 'Enter one of the listed choices.' -ForegroundColor Yellow
            continue
        }
        foreach ($item in $Allowed) {
            if ($answer.Trim().Equals($item, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $item
            }
        }
        Write-Host ("Choose: {0}" -f ($Allowed -join ', ')) -ForegroundColor Yellow
    }
}

function Read-SuiteText {
    param([Parameter(Mandatory)][string]$Prompt, [switch]$Required)
    while ($true) {
        $answer = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($answer)) { return $answer.Trim() }
        if (-not $Required) { return '' }
        Write-Host 'A value is required.' -ForegroundColor Yellow
    }
}

function Resolve-SuiteDatabaseList {
    param([string[]]$Names)
    $list = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($item in @($Names)) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        foreach ($part in $item.Split(',')) {
            $name = $part.Trim()
            if (-not $name) { continue }
            $key = $name.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            $list.Add($name)
        }
    }
    return @($list.ToArray())
}

function Get-SuiteSafeName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'demo' }
    $invalid = @([System.IO.Path]::GetInvalidFileNameChars()) + @(',', ' ')
    $builder = New-Object System.Text.StringBuilder
    foreach ($char in $Name.ToCharArray()) {
        $skip = $false
        foreach ($bad in $invalid) {
            if ($char -eq $bad) { $skip = $true; break }
        }
        if ($skip) { [void]$builder.Append('_') } else { [void]$builder.Append($char) }
    }
    $text = $builder.ToString().Trim('_')
    if ([string]::IsNullOrWhiteSpace($text)) { return 'server' }
    return $text
}

function Write-SuiteLog {
    param([string]$Message)
    if ([string]::IsNullOrWhiteSpace($script:SuiteRunDirectory)) { return }
    $path = Join-Path $script:SuiteRunDirectory 'suite-run.log'
    $line = '{0} {1}' -f ([datetime]::UtcNow.ToString('yyyy-MM-dd HH:mm:ss\Z')), $Message
    Add-Content -LiteralPath $path -Value $line -Encoding UTF8
}

function Get-SuiteToolLabel {
    param([string]$Name)
    switch ($Name) {
        'UpgradeAdvisor' { return 'Server Upgrade Advisor' }
        'AssessmentLight' { return 'SQL Assessment - Lightweight' }
        'AssessmentFull' { return 'SQL Assessment - Full' }
        default { return $Name }
    }
}

function Test-SuiteAssessmentAssets {
    param(
        [Parameter(Mandatory)][string]$Engine,
        [Parameter(Mandatory)][string]$SqlRoot
    )

    $source = Get-Content -LiteralPath $Engine -Raw -Encoding UTF8
    $relativePaths = @(
        [regex]::Matches($source, "'([^']+\.sql)'") |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -match '^[0-9]{2}_[^\\/]+[\\/]' } |
            Sort-Object -Unique
    )
    if ($relativePaths.Count -eq 0) {
        throw "No assessment SQL asset references were found in engine: $Engine"
    }
    $missing = @(
        foreach ($relative in $relativePaths) {
            $candidate = Join-Path $SqlRoot ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { $candidate }
        }
    )
    if ($missing.Count -gt 0) {
        throw ("Assessment SQL assets are missing: {0}" -f ($missing -join '; '))
    }
}

function Test-SuiteJsonFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label not found: $Path"
    }
    try {
        $null = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "$Label is not valid JSON: $Path. $($_.Exception.Message)"
    }
}

function Assert-SuiteToolParameters {
    param([string]$SelectedTool)
    $advisorOnly = @(
        'TargetVersion', 'TargetCompatibilityLevel', 'DefinitionsMode', 'IncludeSystemDatabases',
        'ExportAllFindings', 'RulesPath', 'SqlPath', 'MaxFindingsInReport', 'Encrypt',
        'TrustServerCertificate', 'QueryTimeoutSec', 'DemoMode', 'AdditionalOutputFormat',
        'UseWindowsAuthentication'
    )
    $assessmentOnly = @('DaysToAnalyze', 'FullBackupSlaHours', 'LogBackupSlaMinutes')
    $foreign = if ($SelectedTool -eq 'UpgradeAdvisor') { $assessmentOnly } else { $advisorOnly }
    $used = @()
    foreach ($name in $foreign) {
        if ($script:SuiteBoundParameters.ContainsKey($name)) { $used += ('-' + $name) }
    }
    if ($used.Count -gt 0) {
        throw ("{0} cannot be used with -Tool {1}." -f ($used -join ', '), $SelectedTool)
    }
}

function Invoke-SuiteMenu {
    Write-Host ''
    Write-Host 'SQL Server Assessment Suite' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '1. Server Upgrade Advisor'
    Write-Host '   Compatibility findings for a move to SQL Server 2022 or 2025.'
    Write-Host '2. SQL Assessment - Lightweight'
    Write-Host '   Faster health report. One database, or all. Some sections stay instance-wide.'
    Write-Host '3. SQL Assessment - Full'
    Write-Host '   Full evidence report. A database list also filters instance queries.'
    Write-Host 'Q. Quit'
    Write-Host ''
    $choice = Read-SuiteChoice -Prompt 'Select a tool' -Allowed @('1', '2', '3', 'Q')
    switch ($choice) {
        '1' { return 'UpgradeAdvisor' }
        '2' { return 'AssessmentLight' }
        '3' { return 'AssessmentFull' }
        default { return 'Quit' }
    }
}

function Complete-SuiteRun {
    param($Result)
    if ($null -ne $Result) {
        Write-Output $Result
    }
    $commandLine = [Environment]::GetCommandLineArgs() -join ' '
    if ($commandLine -match '(?i)(^|\s)-File(\s|$)') {
        exit $script:SuiteExitCode
    }
}

$canPrompt = Test-SuiteCanPrompt
$selectedTool = $Tool
if ([string]::IsNullOrWhiteSpace($selectedTool)) {
    if (-not $canPrompt) {
        throw 'Tool is required when prompts are disabled. Pass -Tool UpgradeAdvisor, AssessmentLight, or AssessmentFull.'
    }
    $selectedTool = Invoke-SuiteMenu
    if ($selectedTool -eq 'Quit') {
        Write-Host 'Cancelled. No files were written.'
        Complete-SuiteRun -Result $null
        return
    }
}

Assert-SuiteToolParameters -SelectedTool $selectedTool

if ($DemoMode -and $selectedTool -ne 'UpgradeAdvisor') {
    throw '-DemoMode is only valid with -Tool UpgradeAdvisor.'
}
if ($UseWindowsAuthentication -and $selectedTool -ne 'UpgradeAdvisor') {
    throw '-UseWindowsAuthentication is only valid with -Tool UpgradeAdvisor. Assessment tools use a SQL login.'
}

$useDemo = [bool]$DemoMode
if ($selectedTool -eq 'UpgradeAdvisor' -and $canPrompt -and -not $PSBoundParameters.ContainsKey('DemoMode') -and -not $PSBoundParameters.ContainsKey('ServerInstance')) {
    $demoChoice = Read-SuiteChoice -Prompt 'Run the built-in demo instead of a live instance? [y/N]' -Allowed @('Y', 'N', 'y', 'n') -BlankValue 'N'
    $useDemo = $demoChoice.Equals('Y', [System.StringComparison]::OrdinalIgnoreCase)
}

$server = $ServerInstance
if (-not $useDemo -and [string]::IsNullOrWhiteSpace($server)) {
    if (-not $canPrompt) {
        throw 'ServerInstance is required unless -Tool UpgradeAdvisor -DemoMode is set.'
    }
    $server = Read-SuiteText -Prompt 'SQL Server (host, host\instance, or host,port)' -Required
}

$windowsAuth = [bool]$UseWindowsAuthentication
if ($selectedTool -eq 'UpgradeAdvisor' -and -not $useDemo -and $canPrompt -and -not $PSBoundParameters.ContainsKey('UseWindowsAuthentication') -and -not $PSBoundParameters.ContainsKey('Credential')) {
    Write-Host 'Authentication: 1 = SQL login, 2 = Windows integrated'
    $authChoice = Read-SuiteChoice -Prompt 'Authentication' -Allowed @('1', '2')
    $windowsAuth = $authChoice -eq '2'
}

$sqlCredential = $Credential
if (-not $useDemo -and -not $windowsAuth -and $null -eq $sqlCredential) {
    if (-not $canPrompt) {
        throw 'Credential is required for SQL authentication. Pass -Credential, or -UseWindowsAuthentication for the Upgrade Advisor.'
    }
    $sqlCredential = Get-Credential -Message ("SQL login for {0}" -f (Get-SuiteToolLabel $selectedTool))
    if ($null -eq $sqlCredential) {
        throw 'SQL credential is required.'
    }
}

$databaseFilter = @(Resolve-SuiteDatabaseList -Names $Database)
if ($databaseFilter.Count -eq 0 -and $canPrompt -and -not $PSBoundParameters.ContainsKey('Database')) {
    $typed = Read-SuiteText -Prompt 'Databases (comma-separated, blank = all eligible user databases)'
    $databaseFilter = @(Resolve-SuiteDatabaseList -Names @($typed))
}
if ($selectedTool -eq 'AssessmentLight' -and $databaseFilter.Count -gt 1) {
    throw 'SQL Assessment - Lightweight accepts one database name. Use -Tool AssessmentFull for more than one database.'
}

$target = $TargetVersion
if ($selectedTool -eq 'UpgradeAdvisor' -and $canPrompt -and -not $PSBoundParameters.ContainsKey('TargetVersion')) {
    Write-Host 'Target version: 1 = 2022, 2 = 2025'
    $versionChoice = Read-SuiteChoice -Prompt 'Target SQL Server version' -Allowed @('1', '2')
    $target = if ($versionChoice -eq '2') { '2025' } else { '2022' }
}

$format = $OutputFormat
if ($canPrompt -and -not $PSBoundParameters.ContainsKey('OutputFormat')) {
    Write-Host 'Output: 1 = HTML, 2 = Excel, 3 = Both'
    $formatChoice = Read-SuiteChoice -Prompt 'Output format' -Allowed @('1', '2', '3')
    $format = switch ($formatChoice) {
        '2' { 'Excel' }
        '3' { 'Both' }
        default { 'Html' }
    }
}

$parentOutput = $OutputPath
if ([string]::IsNullOrWhiteSpace($parentOutput)) {
    $parentOutput = Join-Path $CollectorRoot 'output'
}
if ($canPrompt -and -not $PSBoundParameters.ContainsKey('OutputPath')) {
    $typedPath = Read-SuiteText -Prompt ("Output folder [{0}]" -f $parentOutput)
    if (-not [string]::IsNullOrWhiteSpace($typedPath)) { $parentOutput = $typedPath }
}
try {
    $parentOutput = [System.IO.Path]::GetFullPath($parentOutput)
}
catch {
    throw "OutputPath is not a valid path: $parentOutput"
}

if ($canPrompt) {
    $authLabel = if ($useDemo) { 'demo (no connection)' } elseif ($windowsAuth) { 'Windows integrated' } else { 'SQL login' }
    $dbLabel = if ($databaseFilter.Count -eq 0) { 'all eligible user databases' } else { $databaseFilter -join ', ' }
    Write-Host ''
    Write-Host 'Review' -ForegroundColor Cyan
    Write-Host ("Tool     : {0}" -f (Get-SuiteToolLabel $selectedTool))
    Write-Host ("Server   : {0}" -f $(if ($useDemo) { '(demo)' } else { $server }))
    Write-Host ("Auth     : {0}" -f $authLabel)
    Write-Host ("Database : {0}" -f $dbLabel)
    Write-Host ("Output   : {0}" -f $format)
    Write-Host ("Folder   : {0}" -f $parentOutput)
    if ($selectedTool -eq 'AssessmentLight') {
        Write-Host 'Note     : A lightweight database filter does not narrow every instance-wide section.' -ForegroundColor Yellow
    }
    if ($selectedTool -ne 'UpgradeAdvisor') {
        Write-Host 'Note     : Assessment connections encrypt and trust the server certificate.' -ForegroundColor Yellow
    }
    elseif (-not $useDemo) {
        Write-Host ("Note     : Upgrade Advisor Encrypt={0}, TrustServerCertificate={1}." -f $Encrypt, [bool]$TrustServerCertificate)
    }
    $go = Read-SuiteChoice -Prompt 'Run now? [Y/n]' -Allowed @('Y', 'N', 'y', 'n') -BlankValue 'Y'
    if ($go.Equals('N', [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host 'Cancelled. No files were written.'
        Complete-SuiteRun -Result $null
        return
    }
}

$script:SuitePhase = 'Validation'
try {
    if (-not (Test-Path -LiteralPath $EnginePath[$selectedTool] -PathType Leaf)) {
        throw "Engine script not found: $($EnginePath[$selectedTool])"
    }
    if ($selectedTool -ne 'UpgradeAdvisor') {
        $sqlClient = Join-Path $CollectorRoot 'AssessmentSqlClient.ps1'
        if (-not (Test-Path -LiteralPath $sqlClient -PathType Leaf)) {
            throw "SQL client helper not found: $sqlClient"
        }
        $sqlScripts = Join-Path $CollectorRoot 'sql_scripts'
        if (-not (Test-Path -LiteralPath $sqlScripts -PathType Container)) {
            throw "Assessment SQL folder not found: $sqlScripts"
        }
        Test-SuiteAssessmentAssets -Engine $EnginePath[$selectedTool] -SqlRoot $sqlScripts
        if ($format -in @('Excel', 'Both')) {
            if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
                throw 'Excel output for the assessment tools needs the ImportExcel module. Run: Install-Module ImportExcel -Scope CurrentUser'
            }
        }
    }
    else {
        $advisorSql = if ($PSBoundParameters.ContainsKey('SqlPath')) { $SqlPath } else { Join-Path (Split-Path -Parent $EnginePath['UpgradeAdvisor']) 'sql' }
        $advisorRules = Join-Path (Split-Path -Parent $EnginePath['UpgradeAdvisor']) 'rules'
        if (-not (Test-Path -LiteralPath $advisorSql -PathType Container)) {
            throw "Upgrade Advisor SQL folder not found: $advisorSql"
        }
        foreach ($sqlFile in @('collect_instance.sql', 'collect_database.sql')) {
            $candidate = Join-Path $advisorSql $sqlFile
            if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                throw "Upgrade Advisor SQL asset not found: $candidate"
            }
        }
        if (-not (Test-Path -LiteralPath $advisorRules -PathType Container)) {
            throw "Upgrade Advisor rules folder not found: $advisorRules"
        }
        $defaultRules = Join-Path $advisorRules 'default-rules.json'
        if (Test-Path -LiteralPath $defaultRules -PathType Leaf) {
            Test-SuiteJsonFile -Path $defaultRules -Label 'Upgrade Advisor default rules'
        }
        if ($PSBoundParameters.ContainsKey('RulesPath')) {
            Test-SuiteJsonFile -Path $RulesPath -Label 'Upgrade Advisor custom rules'
        }
        if ($format -in @('Excel', 'Both')) {
            if (-not ('System.IO.Compression.ZipFile' -as [type])) {
                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            }
            if (-not ('System.IO.Compression.ZipFile' -as [type])) {
                throw 'System.IO.Compression.ZipFile is unavailable; Upgrade Advisor Excel export cannot run in this host.'
            }
        }
        if (-not $useDemo) {
            if (-not ('System.Data.SqlClient.SqlConnection' -as [type])) {
                Add-Type -AssemblyName System.Data -ErrorAction SilentlyContinue
            }
            if (-not ('System.Data.SqlClient.SqlConnection' -as [type])) {
                throw 'System.Data.SqlClient is not available in this PowerShell host.'
            }
        }
    }

    if (-not (Test-Path -LiteralPath $parentOutput)) {
        New-Item -Path $parentOutput -ItemType Directory -Force | Out-Null
    }
    $probe = Join-Path $parentOutput ('.suite-write-probe-' + [guid]::NewGuid().ToString('N'))
    Set-Content -LiteralPath $probe -Value 'ok' -Encoding ASCII
    Remove-Item -LiteralPath $probe -Force

    $safeServer = Get-SuiteSafeName -Name $(if ($useDemo) { 'demo' } else { $server })
    $stamp = [datetime]::Now.ToString('yyyyMMdd_HHmmss')
    $script:SuiteRunDirectory = Join-Path $parentOutput ('{0}_{1}_{2}' -f $safeServer, $selectedTool, $stamp)
    New-Item -Path $script:SuiteRunDirectory -ItemType Directory -Force | Out-Null
    Write-SuiteLog ("Tool={0} Format={1} Auth={2}" -f $selectedTool, $format, $(if ($useDemo) { 'Demo' } elseif ($windowsAuth) { 'Windows' } else { 'SQL' }))

    $script:SuitePhase = 'Engine'
    $splat = @{}
    if ($selectedTool -eq 'UpgradeAdvisor') {
        $advisorFormat = switch ($format) {
            'Excel' { 'Excel' }
            'Both' { 'Both' }
            default { 'HTML' }
        }
        $splat = @{
            TargetVersion            = $target
            TargetCompatibilityLevel = $TargetCompatibilityLevel
            OutputPath               = $script:SuiteRunDirectory
            Format                   = $advisorFormat
            DefinitionsMode          = $DefinitionsMode
            MaxFindingsInReport      = $MaxFindingsInReport
            Encrypt                  = $Encrypt
            QueryTimeoutSec          = $QueryTimeoutSec
            PassThru                 = $true
        }
        if ($TrustServerCertificate) { $splat['TrustServerCertificate'] = $true }
        if ($IncludeSystemDatabases) { $splat['IncludeSystemDatabases'] = $true }
        if ($ExportAllFindings) { $splat['ExportAllFindings'] = $true }
        if ($OpenReport) { $splat['OpenReport'] = $true }
        if ($useDemo) { $splat['DemoMode'] = $true }
        elseif ($windowsAuth) { $splat['ServerInstance'] = $server }
        else {
            $splat['ServerInstance'] = $server
            $splat['Credential'] = $sqlCredential
        }
        if ($databaseFilter.Count -gt 0) { $splat['Databases'] = $databaseFilter }
        if ($PSBoundParameters.ContainsKey('RulesPath')) { $splat['RulesPath'] = $RulesPath }
        if ($PSBoundParameters.ContainsKey('SqlPath')) { $splat['SqlPath'] = $SqlPath }
        $also = @()
        foreach ($extra in @($AdditionalOutputFormat)) {
            if ($extra -eq 'Json') { $also += 'JSON' }
            elseif ($extra -eq 'Sarif') { $also += 'SARIF' }
        }
        if ($also.Count -gt 0) { $splat['AlsoExport'] = $also }
    }
    else {
        $splat = @{
            ServerIP             = $server
            Credential           = $sqlCredential
            OutputPath           = $script:SuiteRunDirectory
            OutputFormat         = $format
            DaysToAnalyze        = $DaysToAnalyze
            FullBackupSlaHours   = $FullBackupSlaHours
            LogBackupSlaMinutes  = $LogBackupSlaMinutes
        }
        if ($OpenReport) { $splat['OpenReport'] = $true }
        if ($databaseFilter.Count -gt 0) {
            $splat['Database'] = if ($selectedTool -eq 'AssessmentLight') { $databaseFilter[0] } else { ($databaseFilter -join ',') }
        }
    }

    Write-Host ("Running {0}..." -f (Get-SuiteToolLabel $selectedTool)) -ForegroundColor Cyan
    $engineOutput = @(& $EnginePath[$selectedTool] @splat)
    $engineResult = $null
    foreach ($item in $engineOutput) {
        if ($null -eq $item) { continue }
        $names = @($item.PSObject.Properties.Name)
        if ($names -contains 'OutputFiles' -or $names -contains 'ReportPath') {
            $engineResult = $item
        }
    }
    if ($null -eq $engineResult) {
        $engineResult = $engineOutput | Select-Object -Last 1
    }

    $reportFiles = New-Object System.Collections.Generic.List[string]
    $logFiles = New-Object System.Collections.Generic.List[string]
    $suiteLog = Join-Path $script:SuiteRunDirectory 'suite-run.log'
    if (Test-Path -LiteralPath $suiteLog) { $logFiles.Add($suiteLog) }

    if ($null -ne $engineResult) {
        foreach ($propName in @('ReportPath', 'ExcelReportPath')) {
            if (@($engineResult.PSObject.Properties.Name) -contains $propName) {
                $candidate = $engineResult.$propName
                if ($candidate -and (Test-Path -LiteralPath $candidate)) { $reportFiles.Add([string]$candidate) }
            }
        }
        if ($engineResult.PSObject.Properties.Name -contains 'OutputFiles') {
            foreach ($candidate in @($engineResult.OutputFiles)) {
                if ($candidate -and (Test-Path -LiteralPath $candidate)) {
                    $full = [string]$candidate
                    if (-not $reportFiles.Contains($full)) { $reportFiles.Add($full) }
                }
            }
        }
        if ($engineResult.PSObject.Properties.Name -contains 'LogFilePath' -and $engineResult.LogFilePath -and (Test-Path -LiteralPath $engineResult.LogFilePath)) {
            $logFiles.Add([string]$engineResult.LogFilePath)
        }
    }

    $hasHtml = @($reportFiles | Where-Object { $_.EndsWith('.html', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    $hasExcel = @($reportFiles | Where-Object { $_.EndsWith('.xlsx', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    $hasJson = @($reportFiles | Where-Object { $_.EndsWith('.json', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    $hasSarif = @($reportFiles | Where-Object { $_.EndsWith('.sarif', [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
    if ($format -eq 'Both' -and -not $hasHtml -and -not $hasExcel) {
        $script:SuiteExitCode = 3
        $script:SuiteErrors.Add('Neither the requested HTML report nor Excel workbook was created.')
    }
    elseif ($format -eq 'Both' -and ($hasHtml -xor $hasExcel)) {
        $script:SuiteExitCode = 4
        $missingPrimary = if ($hasHtml) { 'Excel' } else { 'HTML' }
        $script:SuiteWarnings.Add(("{0} output was not created. Partial success." -f $missingPrimary))
    }
    elseif ($format -eq 'Html' -and -not $hasHtml) {
        $script:SuiteExitCode = 3
        $script:SuiteErrors.Add('HTML report was not created.')
    }
    elseif ($format -eq 'Excel' -and -not $hasExcel) {
        $script:SuiteExitCode = 3
        $script:SuiteErrors.Add('Excel workbook was not created.')
    }
    foreach ($extra in @($AdditionalOutputFormat)) {
        if ($extra -eq 'Json' -and -not $hasJson) {
            $script:SuiteExitCode = 3
            $script:SuiteErrors.Add('The requested JSON report was not created.')
        }
        elseif ($extra -eq 'Sarif' -and -not $hasSarif) {
            $script:SuiteExitCode = 3
            $script:SuiteErrors.Add('The requested SARIF report was not created.')
        }
    }

    if ($selectedTool -ne 'UpgradeAdvisor' -and $null -ne $engineResult -and $engineResult.PSObject.Properties.Name -contains 'CollectionErrors') {
        $errorCount = 0
        try { $errorCount = [int]$engineResult.CollectionErrors } catch { $errorCount = 0 }
        if ($errorCount -gt 0) {
            $script:SuiteWarnings.Add(("{0} collector section error(s) were recorded in the assessment log." -f $errorCount))
        }
    }

    $summary = $null
    if ($selectedTool -eq 'UpgradeAdvisor' -and $null -ne $engineResult -and $engineResult.PSObject.Properties.Name -contains 'Summary') {
        $summary = $engineResult.Summary
    }
    elseif ($null -ne $engineResult) {
        $summary = [pscustomobject]@{
            HealthScore       = $engineResult.HealthScore
            HealthStatus      = $engineResult.HealthStatus
            CriticalIssues    = $engineResult.CriticalIssues
            WarningIssues     = $engineResult.WarningIssues
            InformationItems  = $engineResult.InformationItems
            CollectionErrors  = $engineResult.CollectionErrors
            DatabasesAssessed = $engineResult.DatabasesAssessed
        }
    }

    $actualDatabases = @($databaseFilter)
    if ($null -ne $engineResult) {
        if ($selectedTool -eq 'UpgradeAdvisor' -and $engineResult.PSObject.Properties.Name -contains 'DatabaseData') {
            $actualDatabases = @($engineResult.DatabaseData | ForEach-Object { $_.Database } | Where-Object { $_ } | Sort-Object -Unique)
        }
        elseif ($engineResult.PSObject.Properties.Name -contains 'DatabasesAssessed') {
            $actualDatabases = @($engineResult.DatabasesAssessed)
        }
    }

    $finished = [datetime]::UtcNow
    $result = [pscustomobject]@{
        Tool              = $selectedTool
        Succeeded         = ($script:SuiteExitCode -eq 0)
        PartialSuccess    = ($script:SuiteExitCode -eq 4)
        ExitCode          = $script:SuiteExitCode
        ServerInstance    = $(if ($useDemo) { 'demo' } else { $server })
        DatabasesAssessed = @($actualDatabases)
        OutputFormat      = $format
        OutputDirectory   = $script:SuiteRunDirectory
        ReportFiles       = @($reportFiles)
        LogFiles          = @($logFiles)
        StartedAt         = $script:SuiteStartedAt
        FinishedAt        = $finished
        DurationSeconds   = [int]($finished - $script:SuiteStartedAt).TotalSeconds
        Summary           = $summary
        Warnings          = @($script:SuiteWarnings)
        Errors            = @($script:SuiteErrors)
    }
    Write-SuiteLog ("Completed ExitCode={0} Reports={1}" -f $script:SuiteExitCode, $reportFiles.Count)
}
catch {
    $message = $_.Exception.Message
    $script:SuiteErrors.Add($message)
    if ($script:SuitePhase -eq 'Validation') {
        $script:SuiteExitCode = 1
    }
    elseif ($_.CategoryInfo.Category -eq 'ParameterBinding' -or $message -match 'Missing an argument for parameter|Cannot process argument') {
        $script:SuiteExitCode = 1
    }
    elseif ($message -match 'Excel export failed|workbook|Export') {
        $script:SuiteExitCode = 3
    }
    elseif ($message -match 'Cannot connect|Login failed|network-related|certificate|provider:|authentication') {
        $script:SuiteExitCode = 2
    }
    else {
        $script:SuiteExitCode = 2
    }
    Write-SuiteLog ("FAILED ExitCode={0} {1}" -f $script:SuiteExitCode, $message)
    $finished = [datetime]::UtcNow
    $failureLogs = @()
    if ($script:SuiteRunDirectory) {
        $failureLog = Join-Path $script:SuiteRunDirectory 'suite-run.log'
        if (Test-Path -LiteralPath $failureLog) { $failureLogs = @($failureLog) }
    }
    $result = [pscustomobject]@{
        Tool              = $selectedTool
        Succeeded         = $false
        PartialSuccess    = $false
        ExitCode          = $script:SuiteExitCode
        ServerInstance    = $(if ($useDemo) { 'demo' } else { $server })
        DatabasesAssessed = @($databaseFilter)
        OutputFormat      = $format
        OutputDirectory   = $script:SuiteRunDirectory
        ReportFiles       = @()
        LogFiles          = $failureLogs
        StartedAt         = $script:SuiteStartedAt
        FinishedAt        = $finished
        DurationSeconds   = [int]($finished - $script:SuiteStartedAt).TotalSeconds
        Summary           = $null
        Warnings          = @($script:SuiteWarnings)
        Errors            = @($script:SuiteErrors)
    }
    Write-Host ("FAILED: {0}" -f $message) -ForegroundColor Red
}
finally {
    if ($script:SuiteRunDirectory -and (Test-Path -LiteralPath $script:SuiteRunDirectory) -and (Test-Path -LiteralPath 'variable:result')) {
        $manifest = [ordered]@{
            Tool              = $result.Tool
            Succeeded         = $result.Succeeded
            PartialSuccess    = $result.PartialSuccess
            ExitCode          = $result.ExitCode
            ServerInstance    = $result.ServerInstance
            DatabasesAssessed = @($result.DatabasesAssessed)
            OutputFormat      = $result.OutputFormat
            OutputDirectory   = $result.OutputDirectory
            ReportFiles       = @($result.ReportFiles)
            LogFiles          = @($result.LogFiles)
            StartedAt         = $result.StartedAt
            FinishedAt        = $result.FinishedAt
            DurationSeconds   = $result.DurationSeconds
            Warnings          = @($result.Warnings)
            Errors            = @($result.Errors)
            Summary           = $result.Summary
        }
        $manifestPath = Join-Path $script:SuiteRunDirectory 'run-manifest.json'
        $json = $manifest | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($manifestPath, $json, (New-Object System.Text.UTF8Encoding $false))
        if ($result.LogFiles -notcontains $manifestPath) {
            # Manifest is recorded by its presence in the run folder. Keep it out of LogFiles.
        }
    }
}

Complete-SuiteRun -Result $result
