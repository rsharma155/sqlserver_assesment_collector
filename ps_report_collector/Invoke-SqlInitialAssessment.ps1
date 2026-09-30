<#
.SYNOPSIS
    Initial SQL Server architectural assessment collector for V2 / modernization engagements.

.DESCRIPTION
    Connects with SQL authentication through built-in ADO.NET (dbatools is not required).
    Collects current-state, schema, index, code-quality, compatibility, performance
    baseline, HA/DR/sync, security, and capacity evidence, then writes a self-contained HTML report and/or Excel
    workbook plus an audit log.

    Designed for Phase-1 / initial assessment collection so findings can later feed
    architecture, sync, migration, and remediation documents.

.PARAMETER ServerIP
    SQL Server host/IP, optionally including instance or port.
.PARAMETER Credential
    SQL Server PSCredential (normally sa).
.PARAMETER OutputPath
    Output directory. Defaults to .\output beside this script.
.PARAMETER DaysToAnalyze
    Historical lookback window in days for capacity/backup trends.
.PARAMETER FullBackupSlaHours
    Maximum acceptable full-backup age in hours.
.PARAMETER LogBackupSlaMinutes
    Maximum acceptable log-backup age for FULL/BULK_LOGGED databases.
.PARAMETER Database
    Optional database scope. One name, or a comma-separated list (alias:
    DatabaseList). When set, per-database collectors and DatabaseName-scoped
    instance queries run only for those ONLINE accessible user databases.
    Empty/omitted = all user databases (instance-wide collectors unchanged).
.PARAMETER OutputFormat
    Primary output artifact(s). Alias: -o.
    Html  = HTML report only (default).
    Excel = Excel workbook only (requires ImportExcel; still writes the .log).
    Both  = HTML report and Excel workbook.
.PARAMETER ExportExcel
    Backward-compatible switch: when set with the default Html OutputFormat,
    behaves as -OutputFormat Both (HTML + Excel). Requires ImportExcel.
.PARAMETER OpenReport
    Opens the primary report after generation (HTML when produced; otherwise the .xlsx).

.EXAMPLE
    $cred = Get-Credential -UserName sa
    .\Invoke-SqlInitialAssessment.ps1 -ServerIP '192.168.1.100' -Credential $cred -OpenReport

.EXAMPLE
    $cred = Get-Credential -UserName sa
    .\Invoke-SqlInitialAssessment.ps1 -ServerIP '192.168.1.100' -Credential $cred -o Excel
    # Excel-first shareable workbook (requires ImportExcel). No HTML file is written.

.EXAMPLE
    $cred = Get-Credential -UserName sa
    .\Invoke-SqlInitialAssessment.ps1 -ServerIP '192.168.1.100' -Credential $cred -OutputFormat Both
    # Same as -ExportExcel with default Html: HTML + Excel.

.EXAMPLE
    $cred = Get-Credential -UserName sa
    .\Invoke-SqlInitialAssessment.ps1 -ServerIP '192.168.1.100' -Credential $cred `
        -Database 'AdventureWorks2025,ETLWorkshopDB' -o Excel
#>

#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory, HelpMessage = 'SQL Server IP, instance, or IP,port')]
    [Alias('ServerInstance', 'SqlInstance')]
    [ValidateNotNullOrEmpty()]
    [string]$ServerIP,

    [Parameter(Mandatory, HelpMessage = 'SQL Server login credential (normally sa)')]
    [Alias('SqlCredential')]
    [ValidateNotNull()]
    [PSCredential]$Credential,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath = (Join-Path $PSScriptRoot 'output'),

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
    [Alias('DatabaseList')]
    [string]$Database,

    [Parameter()]
    [Alias('o')]
    [ValidateSet('Html', 'Excel', 'Both')]
    [string]$OutputFormat = 'Html',

    [Parameter()]
    [switch]$ExportExcel,

    [Parameter()]
    [switch]$OpenReport
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -ExportExcel with default Html is treated as Both for backward compatibility.
$ResolvedOutputFormat = $OutputFormat
if ($ExportExcel -and $OutputFormat -eq 'Html') {
    $ResolvedOutputFormat = 'Both'
}
$WantHtml = $ResolvedOutputFormat -in @('Html', 'Both')
$WantExcel = $ResolvedOutputFormat -in @('Excel', 'Both')

#region ============================================================================
# INITIALIZATION
# =================================================================================

$ScriptVersion = '1.4.0'
$AssessmentSqlClientPath = Join-Path $PSScriptRoot 'AssessmentSqlClient.ps1'
if (-not (Test-Path -LiteralPath $AssessmentSqlClientPath)) {
    throw "SQL client helper not found: $AssessmentSqlClientPath"
}
. $AssessmentSqlClientPath
$SqlServer = $null
trap {
    Close-AssessmentSqlConnection -Connection $SqlServer
    throw $_
}
$SqlClientName = 'System.Data.SqlClient'
$SqlServer = $null

if (-not (Test-Path -LiteralPath $OutputPath)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

$ReportTimestamp = Get-Date
$SafeServerName = $ServerIP -replace '[\\/:*?"<>|,]', '_'
$ReportBaseName = 'SQL_Initial_Assessment_{0}_{1}' -f $SafeServerName, $ReportTimestamp.ToString('yyyyMMdd_HHmmss')
$ReportFilePath = Join-Path $OutputPath ($ReportBaseName + '.html')
$LogFilePath = Join-Path $OutputPath ($ReportBaseName + '.log')

function Write-AssessmentLog {
    [CmdletBinding()]
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Severity = 'INFO',
        [string]$Section = '',
        [string]$Database = '',
        [string]$Message = '',
        [AllowNull()][System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    try {
        $detail = $Message
        if ($null -ne $ErrorRecord) {
            $exception = $ErrorRecord.Exception
            $exceptionText = if ($null -ne $exception) { $exception.Message } else { [string]$ErrorRecord }
            $detail = if ([string]::IsNullOrWhiteSpace($Message)) { $exceptionText } else { "$Message :: $exceptionText" }
            if ($null -ne $exception) {
                $sqlException = $exception
                while ($null -ne $sqlException -and $sqlException.GetType().Name -ne 'SqlException') {
                    $sqlException = $sqlException.InnerException
                }
                if ($null -ne $sqlException -and $sqlException.PSObject.Properties['Number']) {
                    $detail = "$detail [SqlErrorNumber=$($sqlException.Number)]"
                }
            }
        }
        $detail = ($detail -replace '[\r\n]+', ' ').Trim()
        $line = '{0} | {1} | {2} | {3} | {4}' -f `
            (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Severity.PadRight(5), $Section, $Database, $detail
        Add-Content -LiteralPath $LogFilePath -Value $line -Encoding UTF8
    }
    catch {
        Write-Verbose ("Log write skipped: {0}" -f $_.Exception.Message)
    }
}

$ParameterSummary = (@(
        "OutputPath=$OutputPath",
        "DaysToAnalyze=$DaysToAnalyze",
        "FullBackupSlaHours=$FullBackupSlaHours",
        "LogBackupSlaMinutes=$LogBackupSlaMinutes",
        "Database=$(if ([string]::IsNullOrWhiteSpace($Database)) { 'ALL' } else { $Database })",
        "OutputFormat=$ResolvedOutputFormat",
        "ExportExcel=$([bool]$ExportExcel)",
        "OpenReport=$([bool]$OpenReport)",
        'Credential=[redacted]'
    ) -join ', ')

try {
    Set-Content -LiteralPath $LogFilePath -Value @(
        '============================================================',
        ' SQL Server Initial Assessment - execution log',
        '============================================================',
        ('Script version : {0}' -f $ScriptVersion),
        ('Target server  : {0}' -f $ServerIP),
        ('Start time     : {0}' -f $ReportTimestamp.ToString('yyyy-MM-dd HH:mm:ss')),
        ('PowerShell     : {0}' -f $PSVersionTable.PSVersion.ToString()),
        ('SQL client     : {0} (Encrypt=true, TrustServerCertificate=true)' -f $SqlClientName),
        ('Parameters     : {0}' -f $ParameterSummary),
        ('Report file    : {0}' -f $ReportFilePath),
        'Entry format   : TIMESTAMP | SEVERITY | SECTION | DATABASE | MESSAGE',
        '------------------------------------------------------------'
    ) -Encoding UTF8
}
catch {
    Write-Warning ("Could not initialize log '{0}': {1}" -f $LogFilePath, $_.Exception.Message)
}
Write-AssessmentLog -Severity INFO -Section 'Startup' -Message 'Assessment run started.'

$CriticalIssues = [System.Collections.Generic.List[object]]::new()
$WarningIssues = [System.Collections.Generic.List[object]]::new()
$InformationItems = [System.Collections.Generic.List[object]]::new()
$CollectionErrors = [System.Collections.Generic.List[object]]::new()
$Sections = [ordered]@{}

$AssessmentSqlFiles = [ordered]@{
    InventoryQuery            = '01_current_state/server_instance_inventory.sql'
    ServiceQuery              = '01_current_state/sql_services.sql'
    InfrastructureQuery       = '01_current_state/infrastructure_snapshot.sql'
    DatabaseQuery             = '01_current_state/database_landscape.sql'
    ConfigQuery               = '01_current_state/instance_configuration.sql'
    TraceFlagQuery            = '01_current_state/trace_flags.sql'
    DbScopedConfigQuery       = '01_current_state/database_scoped_configurations.sql'
    ObjectInventoryQuery      = '02_schema_data_model/object_inventory.sql'
    TableStructureQuery       = '02_schema_data_model/table_structure.sql'
    DataTypesQuery            = '02_schema_data_model/data_types_review.sql'
    ConstraintsQuery          = '02_schema_data_model/constraints_analysis.sql'
    FkIndexCoverageQuery      = '02_schema_data_model/fk_index_coverage.sql'
    NullabilityDefaultsQuery  = '02_schema_data_model/column_nullability_defaults.sql'
    IdentitySequenceQuery     = '02_schema_data_model/identity_sequences.sql'
    SpecialFeaturesQuery      = '02_schema_data_model/special_table_features.sql'
    SchemaRisksQuery          = '02_schema_data_model/schema_design_risks.sql'
    CrossDbDependencyQuery    = '02_schema_data_model/cross_database_dependencies.sql'
    NamingConventionQuery     = '02_schema_data_model/naming_convention_review.sql'
    IndexInventoryQuery       = '03_indexes/index_inventory.sql'
    IndexUsageQuery           = '03_indexes/index_usage.sql'
    ManyIndexesQuery          = '03_indexes/tables_with_many_indexes.sql'
    MissingIndexQuery         = '03_indexes/missing_index_indicators.sql'
    DuplicateIndexQuery       = '03_indexes/duplicate_overlapping_indexes.sql'
    FragmentationQuery        = '03_indexes/index_fragmentation_limited.sql'
    HotTableQuery             = '03_indexes/hot_table_access.sql'
    CodeInventoryQuery        = '04_code_quality/code_object_inventory.sql'
    FunctionRiskQuery         = '04_code_quality/function_risk_analysis.sql'
    TriggerQuery              = '04_code_quality/trigger_analysis.sql'
    CodeSmellQuery            = '04_code_quality/code_smells.sql'
    CompatQuery               = '05_deprecated_compat/compatibility_levels.sql'
    DeprecatedQuery           = '05_deprecated_compat/deprecated_features.sql'
    DeprecatedInstanceQuery   = '05_deprecated_compat/deprecated_features_instance.sql'
    WaitQuery                 = '06_performance_baseline/wait_statistics.sql'
    TopQuery                  = '06_performance_baseline/top_resource_consumers.sql'
    QueryStoreQuery           = '06_performance_baseline/query_store_status.sql'
    QueryStoreForcedQuery     = '06_performance_baseline/query_store_forced_plans.sql'
    ImplicitConversionQuery   = '06_performance_baseline/implicit_conversion_candidates.sql'
    TempDbQuery               = '06_performance_baseline/tempdb_health.sql'
    BlockingQuery             = '06_performance_baseline/blocking_long_running.sql'
    PressureQuery             = '06_performance_baseline/cpu_memory_pressure.sql'
    AgQuery                   = '07_ha_dr_sync/availability_group_status.sql'
    SyncFeatureQuery          = '07_ha_dr_sync/replication_cdc_ct.sql'
    BackupQuery               = '07_ha_dr_sync/backup_status.sql'
    LinkedBrokerQuery         = '07_ha_dr_sync/linked_servers_broker.sql'
    SecurityQuery             = '08_security/server_security.sql'
    EncryptionQuery           = '08_security/encryption_and_surface.sql'
    DbPrincipalsQuery         = '08_security/database_principals.sql'
    OrphanedUsersQuery        = '08_security/orphaned_users.sql'
    ServerRoleQuery           = '08_security/server_role_membership.sql'
    StatisticsHealthQuery     = '08_statistics/statistics_health.sql'
    StatisticsOptionsQuery    = '08_statistics/statistics_database_options.sql'
    CapacityQuery             = '09_capacity/capacity_growth_trends.sql'
    FilegroupQuery            = '09_capacity/filegroups_and_files.sql'
    VlfQuery                  = '09_capacity/vlf_assessment.sql'
    AutogrowthQuery           = '09_capacity/autogrowth_events.sql'
    CompressionOppQuery       = '09_capacity/compression_opportunities.sql'
    AgentJobsQuery            = '10_maintenance_ops/agent_jobs.sql'
    AgentFailuresQuery        = '10_maintenance_ops/agent_job_failures.sql'
    AlertsOperatorsQuery      = '10_maintenance_ops/alerts_operators.sql'
    DatabaseMailQuery         = '10_maintenance_ops/database_mail_status.sql'
}

function Get-AssessmentSql {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Tokens = @{}
    )

    if (-not $AssessmentSqlFiles.Contains($Name)) {
        throw "Unknown assessment SQL dependency '$Name'."
    }
    $sqlPath = Join-Path (Join-Path $PSScriptRoot 'sql_scripts') $AssessmentSqlFiles[$Name]
    if (-not (Test-Path -LiteralPath $sqlPath -PathType Leaf)) {
        throw "Required assessment SQL file is missing: '$sqlPath'."
    }
    $sql = Get-Content -Raw -LiteralPath $sqlPath
    if ([string]::IsNullOrWhiteSpace($sql)) {
        throw "Required assessment SQL file is empty: '$sqlPath'."
    }
    foreach ($tokenName in $Tokens.Keys) {
        $tokenValue = $Tokens[$tokenName]
        if ($tokenName -eq 'DatabaseFilter') {
            if ($null -eq $tokenValue) { $tokenValue = '' }
            if ($tokenValue -isnot [string]) {
                throw "SQL token 'DatabaseFilter' must be a string (safe filter fragment or empty)."
            }
            $sql = $sql.Replace('{{' + $tokenName + '}}', $tokenValue)
            continue
        }
        if ($tokenValue -isnot [byte] -and $tokenValue -isnot [int16] -and
            $tokenValue -isnot [int32] -and $tokenValue -isnot [int64]) {
            throw "SQL token '$tokenName' must be a validated integer."
        }
        $sql = $sql.Replace('{{' + $tokenName + '}}', [string]$tokenValue)
    }
    if ($sql -match '\{\{[A-Za-z0-9_]+\}\}') {
        throw "Unresolved token in assessment SQL '$Name'."
    }
    return $sql
}

function ConvertTo-AssessmentDatabaseNameList {
    [CmdletBinding()]
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }

    $names = [System.Collections.Generic.List[string]]::new()
    $seen = @{}
    foreach ($part in ($Value -split ',')) {
        $trimmed = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            throw "Database list contains an empty name. Use a comma-separated list with no empty tokens (e.g. -Database 'Sales,HR')."
        }
        $key = $trimmed.ToUpperInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $names.Add($trimmed)
        }
    }
    return @($names)
}

function New-AssessmentDatabaseFilter {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()][string[]]$DatabaseNames,
        [Parameter(Mandatory)][string]$Expression,
        [switch]$KeepNull
    )

    if ($null -eq $DatabaseNames -or @($DatabaseNames).Count -eq 0) { return '' }

    $quoted = foreach ($name in $DatabaseNames) {
        "N'{0}'" -f ($name -replace "'", "''")
    }
    $inList = $quoted -join ', '
    if ($KeepNull) {
        return (' AND ({0} IS NULL OR {0} IN ({1}))' -f $Expression, $inList)
    }
    return (' AND {0} IN ({1})' -f $Expression, $inList)
}

function Get-AssessmentSqlWithDbFilter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Expression,
        [hashtable]$Tokens = @{},
        [switch]$KeepNull
    )

    $merged = @{}
    foreach ($key in $Tokens.Keys) { $merged[$key] = $Tokens[$key] }
    $merged['DatabaseFilter'] = New-AssessmentDatabaseFilter `
        -DatabaseNames $AssessmentDatabaseFilterNames `
        -Expression $Expression `
        -KeepNull:$KeepNull
    return (Get-AssessmentSql -Name $Name -Tokens $merged)
}

foreach ($sqlDependency in $AssessmentSqlFiles.Keys) {
    $dependencyTokens = @{ DatabaseFilter = '' }
    if ($sqlDependency -in @('CapacityQuery', 'AutogrowthQuery', 'AgentFailuresQuery')) {
        $dependencyTokens['DaysToAnalyze'] = $DaysToAnalyze
    }
    [void](Get-AssessmentSql -Name $sqlDependency -Tokens $dependencyTokens)
}

function Add-Finding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Critical', 'Warning', 'Info')][string]$Severity,
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][string]$Detail,
        [string]$Recommendation = ''
    )

    $finding = [PSCustomObject]@{
        Severity       = $Severity
        Category       = $Category
        Item           = $Item
        Detail         = $Detail
        Recommendation = $Recommendation
    }
    switch ($Severity) {
        'Critical' { $CriticalIssues.Add($finding) }
        'Warning'  { $WarningIssues.Add($finding) }
        'Info'     { $InformationItems.Add($finding) }
    }
}

function Test-HasValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return $false }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $false }
    return $true
}

function Test-HasNumericValue {
    param([AllowNull()][object]$Value)
    if (-not (Test-HasValue $Value)) { return $false }
    $parsed = 0.0
    return [double]::TryParse([string]$Value, [ref]$parsed)
}

function Compare-Numeric {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][ValidateSet('gt', 'lt', 'ge', 'le', 'eq')][string]$Operator,
        [Parameter(Mandatory)][double]$Threshold
    )
    if (-not (Test-HasNumericValue $Value)) { return $false }
    $number = [double]$Value
    switch ($Operator) {
        'gt' { return $number -gt $Threshold }
        'lt' { return $number -lt $Threshold }
        'ge' { return $number -ge $Threshold }
        'le' { return $number -le $Threshold }
        'eq' { return $number -eq $Threshold }
    }
    return $false
}

function Invoke-AssessmentQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Query,
        [string]$Database = 'master',
        [int]$QueryTimeout = 180
    )

    Write-Host ("Collecting {0}..." -f $Name) -NoNewline
    try {
        $result = @(Invoke-AssessmentSqlQuery -Connection $SqlServer `
            -Database $Database -Query $Query -QueryTimeout $QueryTimeout)
        $Sections[$Name] = $result
        Write-Host ' DONE' -ForegroundColor Green
        return $result
    }
    catch {
        $Sections[$Name] = @()
        $CollectionErrors.Add([PSCustomObject]@{ Section = $Name; Error = $_.Exception.Message })
        Write-AssessmentLog -Severity ERROR -Section $Name -Message 'Collector query failed.' -ErrorRecord $_
        Write-Host ' FAILED' -ForegroundColor Yellow
        return @()
    }
}

function Invoke-PerDatabaseAssessmentQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$DatabaseNames,
        [int]$QueryTimeout = 180
    )

    Write-Host ("Collecting {0}..." -f $Name) -NoNewline
    $collected = [System.Collections.Generic.List[object]]::new()
    foreach ($databaseName in $DatabaseNames) {
        try {
            $rows = @(Invoke-AssessmentSqlQuery -Connection $SqlServer -Database $databaseName `
                -Query $Query -QueryTimeout $QueryTimeout)
            foreach ($row in $rows) { $collected.Add($row) }
        }
        catch {
            $CollectionErrors.Add([PSCustomObject]@{
                Section = "$Name - $databaseName"
                Error   = $_.Exception.Message
            })
            Write-AssessmentLog -Severity ERROR -Section $Name -Database $databaseName `
                -Message 'Per-database collector failed.' -ErrorRecord $_
        }
    }
    $result = @($collected)
    $Sections[$Name] = $result
    Write-Host ' DONE' -ForegroundColor Green
    return $result
}

function Invoke-AssessmentAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )
    try { . $ScriptBlock }
    catch {
        $CollectionErrors.Add([PSCustomObject]@{ Section = $Name; Error = $_.Exception.Message })
        Write-AssessmentLog -Severity ERROR -Section $Name -Message 'Findings analysis failed.' -ErrorRecord $_
        Write-Host ("Analysis '{0}' failed: {1}" -f $Name, $_.Exception.Message) -ForegroundColor Yellow
    }
}

function ConvertTo-HtmlEncoded {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return 'N/A' }
    if ($Value -is [datetime]) { $Value = $Value.ToString('yyyy-MM-dd HH:mm:ss') }
    elseif ($Value -is [timespan]) { $Value = '{0}d {1}h {2}m' -f $Value.Days, $Value.Hours, $Value.Minutes }
    elseif ($Value -is [bool]) { $Value = if ($Value) { '1' } else { '0' } }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-HtmlTable {
    [CmdletBinding()]
    param(
        [AllowNull()][object[]]$Data,
        [string]$TableId = '',
        [int]$LongTextThreshold = 120
    )

    $rows = @(@($Data) | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) { return "<p class='no-data'>No data available.</p>" }
    $properties = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append("<div class='table-wrap'><table id='$(ConvertTo-HtmlEncoded $TableId)' class='data-table'><thead><tr>")
    foreach ($property in $properties) {
        [void]$builder.Append("<th>$(ConvertTo-HtmlEncoded ($property -replace '_', ' '))</th>")
    }
    [void]$builder.Append('</tr></thead><tbody>')
    foreach ($row in $rows) {
        [void]$builder.Append('<tr>')
        foreach ($property in $properties) {
            $raw = $row.$property
            if ($null -eq $raw -or $raw -is [System.DBNull]) {
                $text = ''
            }
            elseif ($raw -is [datetime]) { $text = $raw.ToString('yyyy-MM-dd HH:mm:ss') }
            elseif ($raw -is [bool]) { $text = if ($raw) { '1' } else { '0' } }
            else { $text = [string]$raw }

            $cellClass = if ($text.Length -gt $LongTextThreshold) { " class='long-text'" } else { '' }
            [void]$builder.Append("<td$cellClass>$(ConvertTo-HtmlEncoded $raw)</td>")
        }
        [void]$builder.Append('</tr>')
    }
    [void]$builder.Append('</tbody></table></div>')
    return $builder.ToString()
}

Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' SQL Server Initial Assessment' -ForegroundColor Cyan
Write-Host " Target: $ServerIP" -ForegroundColor Cyan
Write-Host '========================================' -ForegroundColor Cyan

Write-Host "Connecting to $ServerIP..." -NoNewline
try {
    $SqlServer = Connect-AssessmentSqlInstance -ServerInstance $ServerIP -Credential $Credential
    Write-Host ' SUCCESS' -ForegroundColor Green
    Write-AssessmentLog -Severity INFO -Section 'Connection' -Message ("Connected to '{0}'." -f $ServerIP)
}
catch {
    Write-AssessmentLog -Severity ERROR -Section 'Connection' `
        -Message ("Connection to '{0}' failed." -f $ServerIP) -ErrorRecord $_
    throw "Cannot connect to '$ServerIP'. $($_.Exception.Message)"
}

#endregion

#region ============================================================================
# DATA COLLECTION
# =================================================================================

$Inventory = @(Invoke-AssessmentQuery -Name 'Server and Instance Inventory' -Query (Get-AssessmentSql -Name 'InventoryQuery'))
$Services = @(Invoke-AssessmentQuery -Name 'SQL Services' -Query (Get-AssessmentSql -Name 'ServiceQuery'))
$Volumes = @(Invoke-AssessmentQuery -Name 'Infrastructure Volumes' -Query (Get-AssessmentSql -Name 'InfrastructureQuery'))
$AllDatabases = @(Invoke-AssessmentQuery -Name 'Database Landscape' -Query (Get-AssessmentSql -Name 'DatabaseQuery' -Tokens @{ DatabaseFilter = '' }))
$Configs = @(Invoke-AssessmentQuery -Name 'Instance Configuration' -Query (Get-AssessmentSql -Name 'ConfigQuery'))
[void](Invoke-AssessmentQuery -Name 'Trace Flags' -Query (Get-AssessmentSql -Name 'TraceFlagQuery'))

$AccessibleUserDatabaseNames = @($AllDatabases | Where-Object {
        $_.Status -eq 'ONLINE' -and
        $_.DatabaseName -notin @('master', 'model', 'msdb', 'tempdb') -and
        -not (Test-HasValue $_.SourceDatabaseId) -and
        ([int]$_.HasDbAccess -eq 1)
    } | Select-Object -ExpandProperty DatabaseName)

$RequestedDatabaseNames = @(ConvertTo-AssessmentDatabaseNameList -Value $Database)
$DatabaseScopeExplicit = $RequestedDatabaseNames.Count -gt 0
if ($DatabaseScopeExplicit) {
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($requested in $RequestedDatabaseNames) {
        $match = @($AllDatabases | Where-Object { $_.DatabaseName -eq $requested })
        if ($match.Count -eq 0) {
            $missing.Add("'$requested' (not found on instance)")
            continue
        }
        $row = $match[0]
        if ($row.Status -ne 'ONLINE') {
            $missing.Add("'$requested' (state=$($row.Status), not ONLINE)")
        }
        elseif ($row.DatabaseName -in @('master', 'model', 'msdb', 'tempdb')) {
            $missing.Add("'$requested' (system database; pass a user database)")
        }
        elseif (Test-HasValue $row.SourceDatabaseId) {
            $missing.Add("'$requested' (database snapshot)")
        }
        elseif ([int]$row.HasDbAccess -ne 1) {
            $missing.Add("'$requested' (not accessible to the login)")
        }
    }
    if ($missing.Count -gt 0) {
        throw ("Database scope validation failed: {0}. Fix -Database / -DatabaseList typos or restore access, then retry." -f ($missing -join '; '))
    }
    $UserDatabaseNames = @(foreach ($requested in $RequestedDatabaseNames) {
            ($AllDatabases | Where-Object { $_.DatabaseName -eq $requested } | Select-Object -First 1).DatabaseName
        })
    $Databases = @($AllDatabases | Where-Object { $_.DatabaseName -in $UserDatabaseNames })
    $DatabaseScopeLabel = $UserDatabaseNames -join ', '
}
else {
    $UserDatabaseNames = @($AccessibleUserDatabaseNames)
    $Databases = @($AllDatabases)
    $DatabaseScopeLabel = 'All user databases'
}
$Sections['Database Landscape'] = $Databases
$AssessmentDatabaseFilterNames = if ($DatabaseScopeExplicit) { @($UserDatabaseNames) } else { @() }

Write-AssessmentLog -Severity INFO -Section 'Database Scope' `
    -Message ("Database scope: {0} ({1} user database(s) for per-DB collectors)." -f $DatabaseScopeLabel, $UserDatabaseNames.Count)
Write-Host ("Database scope: {0}" -f $DatabaseScopeLabel) -ForegroundColor Cyan
Write-Host ("Assessing {0} user database(s)." -f $UserDatabaseNames.Count) -ForegroundColor Cyan
Add-Finding -Severity Info -Category 'Collection Scope' -Item 'Database scope' `
    -Detail ("Run scoped to: {0}." -f $DatabaseScopeLabel) `
    -Recommendation 'Omit -Database to assess all accessible ONLINE user databases.'

[void](Invoke-PerDatabaseAssessmentQuery -Name 'Database Scoped Configurations' -Query (Get-AssessmentSql -Name 'DbScopedConfigQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Object Inventory' -Query (Get-AssessmentSql -Name 'ObjectInventoryQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Table Structure' -Query (Get-AssessmentSql -Name 'TableStructureQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Data Types Review' -Query (Get-AssessmentSql -Name 'DataTypesQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Constraints Analysis' -Query (Get-AssessmentSql -Name 'ConstraintsQuery') -DatabaseNames $UserDatabaseNames -QueryTimeout 300)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'FK Index Coverage' -Query (Get-AssessmentSql -Name 'FkIndexCoverageQuery') -DatabaseNames $UserDatabaseNames -QueryTimeout 300)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Column Nullability and Defaults' -Query (Get-AssessmentSql -Name 'NullabilityDefaultsQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Identity and Sequences' -Query (Get-AssessmentSql -Name 'IdentitySequenceQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Special Table Features' -Query (Get-AssessmentSql -Name 'SpecialFeaturesQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Schema Design Risks' -Query (Get-AssessmentSql -Name 'SchemaRisksQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Cross Database Dependencies' -Query (Get-AssessmentSql -Name 'CrossDbDependencyQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Naming Convention Review' -Query (Get-AssessmentSql -Name 'NamingConventionQuery') -DatabaseNames $UserDatabaseNames)

[void](Invoke-PerDatabaseAssessmentQuery -Name 'Index Inventory' -Query (Get-AssessmentSql -Name 'IndexInventoryQuery') -DatabaseNames $UserDatabaseNames -QueryTimeout 300)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Index Usage' -Query (Get-AssessmentSql -Name 'IndexUsageQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Hot Table Access' -Query (Get-AssessmentSql -Name 'HotTableQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Tables With Many Indexes' -Query (Get-AssessmentSql -Name 'ManyIndexesQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Missing Index Indicators' -Query (Get-AssessmentSql -Name 'MissingIndexQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Duplicate Overlapping Indexes' -Query (Get-AssessmentSql -Name 'DuplicateIndexQuery') -DatabaseNames $UserDatabaseNames -QueryTimeout 300)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Index Fragmentation' -Query (Get-AssessmentSql -Name 'FragmentationQuery') -DatabaseNames $UserDatabaseNames -QueryTimeout 600)

[void](Invoke-PerDatabaseAssessmentQuery -Name 'Statistics Database Options' -Query (Get-AssessmentSql -Name 'StatisticsOptionsQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Statistics Health' -Query (Get-AssessmentSql -Name 'StatisticsHealthQuery') -DatabaseNames $UserDatabaseNames -QueryTimeout 300)

[void](Invoke-PerDatabaseAssessmentQuery -Name 'Code Object Inventory' -Query (Get-AssessmentSql -Name 'CodeInventoryQuery') -DatabaseNames $UserDatabaseNames -QueryTimeout 300)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Function Risk Analysis' -Query (Get-AssessmentSql -Name 'FunctionRiskQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Trigger Analysis' -Query (Get-AssessmentSql -Name 'TriggerQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Code Smells' -Query (Get-AssessmentSql -Name 'CodeSmellQuery') -DatabaseNames $UserDatabaseNames -QueryTimeout 300)

[void](Invoke-AssessmentQuery -Name 'Compatibility Levels' -Query (Get-AssessmentSqlWithDbFilter -Name 'CompatQuery' -Expression 'd.name'))
$DeprecatedDb = @(Invoke-PerDatabaseAssessmentQuery -Name 'Deprecated Features DB' -Query (Get-AssessmentSql -Name 'DeprecatedQuery') -DatabaseNames $UserDatabaseNames -QueryTimeout 300)
$DeprecatedInstance = @(Invoke-AssessmentQuery -Name 'Deprecated Features Instance' -Query (Get-AssessmentSql -Name 'DeprecatedInstanceQuery') -Database 'msdb')
$Sections['Deprecated Features'] = @($DeprecatedDb + $DeprecatedInstance)
if ($Sections.Contains('Deprecated Features DB')) { [void]$Sections.Remove('Deprecated Features DB') }
if ($Sections.Contains('Deprecated Features Instance')) { [void]$Sections.Remove('Deprecated Features Instance') }

[void](Invoke-AssessmentQuery -Name 'Wait Statistics' -Query (Get-AssessmentSql -Name 'WaitQuery'))
[void](Invoke-AssessmentQuery -Name 'Top Resource Consumers' -Query (Get-AssessmentSqlWithDbFilter -Name 'TopQuery' -Expression 'DB_NAME(CONVERT(int, epa.value))'))
[void](Invoke-AssessmentQuery -Name 'Implicit Conversion Candidates' -Query (Get-AssessmentSqlWithDbFilter -Name 'ImplicitConversionQuery' -Expression 'DB_NAME(CONVERT(int, epa.value))'))
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Query Store Status' -Query (Get-AssessmentSql -Name 'QueryStoreQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Query Store Forced Plans' -Query (Get-AssessmentSql -Name 'QueryStoreForcedQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-AssessmentQuery -Name 'TempDB Health' -Query (Get-AssessmentSql -Name 'TempDbQuery') -Database 'tempdb')
[void](Invoke-AssessmentQuery -Name 'Blocking and Long Running' -Query (Get-AssessmentSqlWithDbFilter -Name 'BlockingQuery' -Expression 'DB_NAME(er.database_id)'))
[void](Invoke-AssessmentQuery -Name 'CPU Memory Pressure' -Query (Get-AssessmentSql -Name 'PressureQuery'))

[void](Invoke-AssessmentQuery -Name 'Availability Group Status' -Query (Get-AssessmentSql -Name 'AgQuery'))
[void](Invoke-AssessmentQuery -Name 'Replication CDC Change Tracking' -Query (Get-AssessmentSqlWithDbFilter -Name 'SyncFeatureQuery' -Expression 'd.name'))
$Backups = @(Invoke-AssessmentQuery -Name 'Backup Status' -Query (Get-AssessmentSqlWithDbFilter -Name 'BackupQuery' -Expression 'd.name') -Database 'msdb')
[void](Invoke-AssessmentQuery -Name 'Linked Servers and Broker' -Query (Get-AssessmentSql -Name 'LinkedBrokerQuery'))

[void](Invoke-AssessmentQuery -Name 'Server Security' -Query (Get-AssessmentSql -Name 'SecurityQuery'))
[void](Invoke-AssessmentQuery -Name 'Server Role Membership' -Query (Get-AssessmentSql -Name 'ServerRoleQuery'))
[void](Invoke-AssessmentQuery -Name 'Encryption and Surface Area' -Query (Get-AssessmentSql -Name 'EncryptionQuery'))
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Database Principals' -Query (Get-AssessmentSql -Name 'DbPrincipalsQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Orphaned Users' -Query (Get-AssessmentSql -Name 'OrphanedUsersQuery') -DatabaseNames $UserDatabaseNames)

[void](Invoke-AssessmentQuery -Name 'Capacity Growth Trends' -Query (Get-AssessmentSqlWithDbFilter -Name 'CapacityQuery' -Expression 'database_name' -Tokens @{ DaysToAnalyze = $DaysToAnalyze }) -Database 'msdb')
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Filegroups and Files' -Query (Get-AssessmentSql -Name 'FilegroupQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-PerDatabaseAssessmentQuery -Name 'VLF Assessment' -Query (Get-AssessmentSql -Name 'VlfQuery') -DatabaseNames $UserDatabaseNames)
[void](Invoke-AssessmentQuery -Name 'Autogrowth Events' -Query (Get-AssessmentSqlWithDbFilter -Name 'AutogrowthQuery' -Expression 'DatabaseName' -Tokens @{ DaysToAnalyze = $DaysToAnalyze }))
[void](Invoke-PerDatabaseAssessmentQuery -Name 'Compression Opportunities' -Query (Get-AssessmentSql -Name 'CompressionOppQuery') -DatabaseNames $UserDatabaseNames)

[void](Invoke-AssessmentQuery -Name 'Agent Jobs' -Query (Get-AssessmentSql -Name 'AgentJobsQuery') -Database 'msdb')
[void](Invoke-AssessmentQuery -Name 'Agent Job Failures' -Query (Get-AssessmentSql -Name 'AgentFailuresQuery' -Tokens @{ DaysToAnalyze = $DaysToAnalyze }) -Database 'msdb')
[void](Invoke-AssessmentQuery -Name 'Alerts and Operators' -Query (Get-AssessmentSql -Name 'AlertsOperatorsQuery') -Database 'msdb')
[void](Invoke-AssessmentQuery -Name 'Database Mail Status' -Query (Get-AssessmentSql -Name 'DatabaseMailQuery') -Database 'msdb')

#endregion

#region ============================================================================
# FINDINGS ANALYSIS
# =================================================================================

Invoke-AssessmentAnalysis -Name 'Current state analysis' -ScriptBlock {
    if ($Inventory.Count -gt 0) {
        $inv = $Inventory[0]
        Add-Finding -Severity Info -Category 'Current State' -Item 'Instance' `
            -Detail ("{0} | Edition={1} | CPU={2} | MemoryMB={3} | HADR={4}" -f `
                $inv.ServerName, $inv.Edition, $inv.LogicalCpuCount, $inv.PhysicalMemoryMB, $inv.IsHadrEnabled) `
            -Recommendation 'Confirm version/edition support for V2 target features (Query Store, IQP, AG, CDC).'
        if (Compare-Numeric -Value $inv.UptimeMinutes -Operator lt -Threshold 1440) {
            Add-Finding -Severity Warning -Category 'Current State' -Item 'Uptime' `
                -Detail ("Instance uptime is only {0} minutes; DMV baselines may be incomplete." -f $inv.UptimeMinutes) `
                -Recommendation 'Re-run collectors after a representative production window.'
        }
    }

    foreach ($svc in $Services) {
        if ($svc.Status -ne 'Running') {
            Add-Finding -Severity Critical -Category 'Infrastructure' -Item $svc.ServiceName `
                -Detail ("Service status is {0}." -f $svc.Status) `
                -Recommendation 'Start the service and investigate startup failures.'
        }
    }

    foreach ($vol in $Volumes) {
        if (Compare-Numeric -Value $vol.FreePct -Operator lt -Threshold 15) {
            Add-Finding -Severity Critical -Category 'Infrastructure' -Item $vol.VolumeMountPoint `
                -Detail ("Free space is {0}% ({1} GB free)." -f $vol.FreePct, $vol.FreeSpaceGB) `
                -Recommendation 'Free disk space or expand storage before growth/migration work.'
        }
        elseif (Compare-Numeric -Value $vol.FreePct -Operator lt -Threshold 25) {
            Add-Finding -Severity Warning -Category 'Infrastructure' -Item $vol.VolumeMountPoint `
                -Detail ("Free space is {0}%." -f $vol.FreePct) `
                -Recommendation 'Plan capacity expansion; include in 5/10-year growth model.'
        }
    }

    $userDbCount = @($Databases | Where-Object { $_.DatabaseName -notin @('master','model','msdb','tempdb') }).Count
    Add-Finding -Severity Info -Category 'Database Landscape' -Item 'User databases' `
        -Detail ("Accessible landscape includes {0} non-system database(s)." -f $userDbCount) `
        -Recommendation 'Map each database to application ownership, sync role, and V2 service boundary.'

    foreach ($db in $Databases) {
        if ($db.DatabaseName -in @('master','model','msdb','tempdb')) { continue }
        if ($db.Status -ne 'ONLINE') {
            Add-Finding -Severity Critical -Category 'Database Landscape' -Item $db.DatabaseName `
                -Detail ("Database state is {0}." -f $db.Status) `
                -Recommendation 'Confirm whether offline/restoring state is planned.'
        }
        if ([int]$db.AutoClose -eq 1 -or [int]$db.AutoShrink -eq 1) {
            Add-Finding -Severity Warning -Category 'Database Landscape' -Item $db.DatabaseName `
                -Detail ("AUTO_CLOSE={0}, AUTO_SHRINK={1}." -f $db.AutoClose, $db.AutoShrink) `
                -Recommendation 'Disable AUTO_CLOSE/AUTO_SHRINK on production OLTP databases.'
        }
        if ([int]$db.Trustworthy -eq 1) {
            Add-Finding -Severity Warning -Category 'Security' -Item $db.DatabaseName `
                -Detail 'TRUSTWORTHY is ON.' `
                -Recommendation 'Review necessity; prefer certificate-based elevation patterns.'
        }
        if ([int]$db.QueryStoreEnabled -ne 1) {
            Add-Finding -Severity Warning -Category 'Performance' -Item $db.DatabaseName `
                -Detail 'Query Store is not enabled.' `
                -Recommendation 'Enable Query Store before compatibility or V2 performance changes.'
        }
        if ([int]$db.RcsiEnabled -ne 1 -and $db.RecoveryModel -eq 'FULL') {
            Add-Finding -Severity Info -Category 'Concurrency' -Item $db.DatabaseName `
                -Detail 'READ_COMMITTED_SNAPSHOT is OFF.' `
                -Recommendation 'Evaluate RCSI for blocking reduction in high-concurrency insurance workloads.'
        }
    }
}

Invoke-AssessmentAnalysis -Name 'Backup and HA analysis' -ScriptBlock {
    foreach ($backup in $Backups) {
        if ($backup.DatabaseName -eq 'tempdb') { continue }
        $fullMissing = -not (Test-HasValue $backup.LastFullBackup)
        $fullOverdue = Compare-Numeric -Value $backup.FullAgeHours -Operator gt -Threshold $FullBackupSlaHours
        if ($fullMissing -or $fullOverdue) {
            Add-Finding -Severity Critical -Category 'HA/DR' -Item $backup.DatabaseName `
                -Detail ("Full backup missing or older than {0}h (age={1})." -f $FullBackupSlaHours, $backup.FullAgeHours) `
                -Recommendation 'Restore backup coverage before architecture cutover planning.'
        }
        if ($backup.RecoveryModel -in @('FULL', 'BULK_LOGGED')) {
            $logMissing = -not (Test-HasValue $backup.LastLogBackup)
            $logOverdue = Compare-Numeric -Value $backup.LogAgeMinutes -Operator gt -Threshold $LogBackupSlaMinutes
            if ($logMissing -or $logOverdue) {
                Add-Finding -Severity Critical -Category 'HA/DR' -Item $backup.DatabaseName `
                    -Detail ("Log backup missing or older than {0}m (age={1})." -f $LogBackupSlaMinutes, $backup.LogAgeMinutes) `
                    -Recommendation 'Align log backup cadence to RPO targets.'
            }
        }
    }

    $agRows = @($Sections['Availability Group Status'])
    if ($agRows.Count -eq 0 -and $Inventory.Count -gt 0 -and [int]$Inventory[0].IsHadrEnabled -eq 1) {
        Add-Finding -Severity Warning -Category 'HA/DR' -Item 'Always On' `
            -Detail 'HADR is enabled but no AG replica rows were returned.' `
            -Recommendation 'Verify AG configuration and permissions (VIEW SERVER STATE / AG views).'
    }
    foreach ($ag in $agRows) {
        if ($ag.SynchronizationHealth -and $ag.SynchronizationHealth -ne 'HEALTHY') {
            Add-Finding -Severity Critical -Category 'HA/DR' -Item $ag.AvailabilityGroupName `
                -Detail ("Replica {0} health={1}, state={2}." -f $ag.ReplicaServerName, $ag.SynchronizationHealth, $ag.ConnectedState) `
                -Recommendation 'Resolve AG sync issues before relying on it for V2 DR.'
        }
    }
}

Invoke-AssessmentAnalysis -Name 'Schema and code analysis' -ScriptBlock {
    $schemaRisks = @($Sections['Schema Design Risks'])
    $noPk = @($schemaRisks | Where-Object { $_.Issue -eq 'NoPrimaryKey' })
    if ($noPk.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Schema' -Item 'Tables without PK' `
            -Detail ("{0} table(s) have no primary key." -f $noPk.Count) `
            -Recommendation 'Define natural/surrogate keys before microservice data ownership work.'
    }
    $heaps = @($schemaRisks | Where-Object { $_.Issue -eq 'HeapTable' })
    if ($heaps.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Schema' -Item 'Heap tables' `
            -Detail ("{0} heap table(s) detected." -f $heaps.Count) `
            -Recommendation 'Review clustering strategy for large OLTP tables.'
    }
    $guidKeys = @($schemaRisks | Where-Object { $_.Issue -eq 'GuidClusteredKey' })
    if ($guidKeys.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Schema' -Item 'GUID clustered keys' `
            -Detail ("{0} table(s) use uniqueidentifier in the clustered key." -f $guidKeys.Count) `
            -Recommendation 'Prefer ever-increasing BIGINT/INT clustering keys for write scalability.'
    }
    $untrusted = @($schemaRisks | Where-Object { $_.Issue -in @('UntrustedForeignKey', 'UntrustedOrDisabledCheck') })
    if ($untrusted.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Schema' -Item 'Untrusted constraints' `
            -Detail ("{0} untrusted/disabled constraint(s)." -f $untrusted.Count) `
            -Recommendation 'Re-trust or remediate before migration validation.'
    }
    $wide = @($schemaRisks | Where-Object { $_.Issue -in @('WideTable', 'VeryWideTable') })
    if ($wide.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Schema' -Item 'Wide tables' `
            -Detail ("{0} table(s) exceed 50 columns." -f $wide.Count) `
            -Recommendation 'Assess normalization / vertical split opportunities for V2.'
    }

    $fkCoverage = @($Sections['FK Index Coverage'] | Where-Object { [string]$_.HasSupportingIndex -eq '0' -or $_.HasSupportingIndex -eq 0 })
    if ($fkCoverage.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Indexes' -Item 'Missing FK indexes' `
            -Detail ("{0} foreign key(s) appear to lack a supporting index." -f $fkCoverage.Count) `
            -Recommendation 'Add nonclustered indexes on FK columns to reduce lock/deadlock risk.'
    }

    $fragRebuild = @($Sections['Index Fragmentation'] | Where-Object { $_.Assessment -eq 'Rebuild candidate' })
    if ($fragRebuild.Count -gt 0) {
        Add-Finding -Severity Info -Category 'Indexes' -Item 'Fragmentation rebuild candidates' `
            -Detail ("{0} index partition(s) >= 30% fragmented with >= 1000 pages." -f $fragRebuild.Count) `
            -Recommendation 'Plan targeted rebuild/reorganize during a maintenance window; validate with workload.'
    }

    $deprecatedTypes = @($Sections['Data Types Review'] | Where-Object {
            $_.AssessmentFlag -match 'Deprecated|SQL_VARIANT|MONEY'
        })
    if ($deprecatedTypes.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Data Types' -Item 'Risky/deprecated types' `
            -Detail ("{0} column(s) flagged for type remediation." -f $deprecatedTypes.Count) `
            -Recommendation 'Prioritize TEXT/IMAGE/NTEXT removal and financial DECIMAL standards.'
    }

    $deprecatedFeatures = @($Sections['Deprecated Features'])
    $criticalDeprecated = @($deprecatedFeatures | Where-Object { [string]$_.Severity -eq 'CRITICAL' })
    $highDeprecated = @($deprecatedFeatures | Where-Object { [string]$_.Severity -eq 'HIGH' })
    if ($criticalDeprecated.Count -gt 0) {
        Add-Finding -Severity Critical -Category 'Deprecated Features' -Item 'Critical upgrade blockers' `
            -Detail ("{0} CRITICAL deprecated/removed feature finding(s). See Deprecated Features section for why flagged and remediation." -f $criticalDeprecated.Count) `
            -Recommendation 'Remediate CRITICAL items before upgrade/cutover (removed procedures, TEXT/NTEXT/IMAGE, SET ROWCOUNT, DATABASEPROPERTY, etc.).'
    }
    elseif ($highDeprecated.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Deprecated Features' -Item 'High-priority deprecations' `
            -Detail ("{0} HIGH deprecated feature finding(s)." -f $highDeprecated.Count) `
            -Recommendation 'Schedule remediation for HIGH items (old joins, legacy catalogs, weak crypto, mirroring, Agent job syntax).'
    }
    elseif ($deprecatedFeatures.Count -gt 0) {
        Add-Finding -Severity Info -Category 'Deprecated Features' -Item 'Modernization candidates' `
            -Detail ("{0} deprecated-feature finding(s) recorded." -f $deprecatedFeatures.Count) `
            -Recommendation 'Review WhyFlagged and RecommendedAction columns in the Deprecated Features evidence section.'
    }

    $scalarUdf = @($Sections['Function Risk Analysis'] | Where-Object { $_.FunctionType -match 'SQL_SCALAR' -or $_.RiskNote -match 'Scalar' })
    if ($scalarUdf.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Code Quality' -Item 'Scalar UDFs' `
            -Detail ("{0} scalar UDF(s) found." -f $scalarUdf.Count) `
            -Recommendation 'Plan inline TVF / set-based rewrites; test Scalar UDF Inlining on target compat level.'
    }

    $manyIdx = @($Sections['Tables With Many Indexes'] | Where-Object { Compare-Numeric -Value $_.IndexCount -Operator gt -Threshold 10 })
    if ($manyIdx.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Indexes' -Item 'Over-indexed tables' `
            -Detail ("{0} table(s) have more than 10 indexes." -f $manyIdx.Count) `
            -Recommendation 'Consolidate overlapping indexes before write-heavy V2 workflows.'
    }

    $compat = @($Sections['Compatibility Levels'] | Where-Object {
            $_.Assessment -match 'Below engine max'
        })
    if ($compat.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Compatibility' -Item 'Compatibility lag' `
            -Detail ("{0} database(s) run below engine max compatibility." -f $compat.Count) `
            -Recommendation 'Use Query Store + staged compat upgrades for V2.'
    }

    foreach ($cfg in $Configs) {
        if ($cfg.ConfigName -eq 'xp_cmdshell' -and [int]$cfg.ValueInUse -eq 1) {
            Add-Finding -Severity Critical -Category 'Security' -Item 'xp_cmdshell' `
                -Detail 'xp_cmdshell is enabled.' `
                -Recommendation 'Disable unless a documented, controlled need exists.'
        }
        if ($cfg.ConfigName -eq 'max server memory (MB)' -and (Compare-Numeric -Value $cfg.ValueInUse -Operator eq -Threshold 2147483647)) {
            Add-Finding -Severity Warning -Category 'Configuration' -Item 'max server memory' `
                -Detail 'max server memory appears at default/unlimited.' `
                -Recommendation 'Cap max server memory to leave headroom for OS and other services.'
        }
        if ($cfg.ConfigName -eq 'optimize for ad hoc workloads' -and [int]$cfg.ValueInUse -eq 0) {
            Add-Finding -Severity Info -Category 'Configuration' -Item 'optimize for ad hoc workloads' `
                -Detail 'Ad hoc workload optimization is OFF.' `
                -Recommendation 'Consider enabling if plan cache bloat is observed.'
        }
    }

    $saDisabled = @($Sections['Server Security'] | Where-Object { $_.IsSa -eq 1 -and $_.IsDisabled -eq 1 })
    $saEnabled = @($Sections['Server Security'] | Where-Object { $_.IsSa -eq 1 -and $_.IsDisabled -eq 0 })
    if ($saEnabled.Count -gt 0) {
        Add-Finding -Severity Info -Category 'Security' -Item 'sa account' `
            -Detail 'sa login is enabled.' `
            -Recommendation 'Prefer renamed/disabled sa with least-privilege operational logins.'
    }
    $sysadmins = @($Sections['Server Security'] | Where-Object { $_.IsSysadmin -eq 1 -and $_.IsDisabled -eq 0 })
    if ($sysadmins.Count -gt 5) {
        Add-Finding -Severity Warning -Category 'Security' -Item 'sysadmin membership' `
            -Detail ("{0} enabled sysadmin principals." -f $sysadmins.Count) `
            -Recommendation 'Reduce standing sysadmin access; use role-based operations.'
    }

    $orphans = @($Sections['Orphaned Users'])
    if ($orphans.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Security' -Item 'Orphaned users' `
            -Detail ("{0} orphaned database user(s) detected." -f $orphans.Count) `
            -Recommendation 'Remap or drop orphaned users after migration/restore.'
    }

    $highVlf = @($Sections['VLF Assessment'] | Where-Object { $_.Assessment -match 'CRITICAL|HIGH' })
    if ($highVlf.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Storage' -Item 'Elevated VLF counts' `
            -Detail ("{0} log file(s) have elevated VLF counts." -f $highVlf.Count) `
            -Recommendation 'Plan controlled shrink/regrow to reduce VLFs and improve recovery/log reuse.'
    }

    $staleStats = @($Sections['Statistics Health'] | Where-Object {
        ([string]$_.RequiresUpdate -eq 'Yes') -or ([string]$_.Assessment -match 'UPDATE REQUIRED|Stale')
    })
    $tablesNeedingStats = @(
        $staleStats |
            ForEach-Object { '{0}.{1}.{2}' -f $_.DatabaseName, $_.SchemaName, $_.TableName } |
            Select-Object -Unique
    )
    if ($staleStats.Count -gt 20) {
        Add-Finding -Severity Warning -Category 'Statistics' -Item 'Statistics requiring update' `
            -Detail ("{0} statistics object(s) on {1} table(s) require UPDATE STATISTICS." -f $staleStats.Count, $tablesNeedingStats.Count) `
            -Recommendation 'Validate maintenance jobs and run targeted UPDATE STATISTICS on flagged tables.'
    }
    elseif ($staleStats.Count -gt 0) {
        Add-Finding -Severity Info -Category 'Statistics' -Item 'Statistics requiring update' `
            -Detail ("{0} statistics object(s) on {1} table(s) flagged for UPDATE STATISTICS." -f $staleStats.Count, $tablesNeedingStats.Count) `
            -Recommendation 'Review Statistics Health section before compatibility changes.'
    }

    $statsOff = @($Sections['Statistics Database Options'] | Where-Object { $_.Assessment -match 'WARNING' })
    if ($statsOff.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Statistics' -Item 'Auto stats disabled' `
            -Detail ("{0} database(s) have auto create/update stats disabled." -f $statsOff.Count) `
            -Recommendation 'Enable auto create/update statistics unless a controlled alternative exists.'
    }

    $jobFails = @($Sections['Agent Job Failures'])
    if ($jobFails.Count -gt 0) {
        Add-Finding -Severity Warning -Category 'Maintenance' -Item 'Recent Agent job failures' `
            -Detail ("{0} failed job history row(s) in the lookback window." -f $jobFails.Count) `
            -Recommendation 'Triage failed maintenance/backup jobs before upgrade windows.'
    }

    $crossDb = @($Sections['Cross Database Dependencies'])
    if ($crossDb.Count -gt 0) {
        Add-Finding -Severity Info -Category 'Architecture' -Item 'Cross-database dependencies' `
            -Detail ("{0} cross-database/linked dependency reference(s) found." -f $crossDb.Count) `
            -Recommendation 'Map ownership boundaries for V2 services and migration sequencing.'
    }

    $forcedPlans = @($Sections['Query Store Forced Plans'])
    if ($forcedPlans.Count -gt 0) {
        Add-Finding -Severity Info -Category 'Performance' -Item 'Forced Query Store plans' `
            -Detail ("{0} forced plan(s) present." -f $forcedPlans.Count) `
            -Recommendation 'Validate forced plans still help after upgrade; watch force_failure_count.'
    }

    foreach ($wait in (@($Sections['Wait Statistics']) | Where-Object {
                (Compare-Numeric -Value $_.WaitPercent -Operator ge -Threshold 15) -and
                (Test-HasValue $_.Recommendation) -and
                [string]$_.Recommendation -ne 'Investigate based on workload.'
            })) {
        Add-Finding -Severity Warning -Category 'Wait Statistics' -Item $wait.WaitType `
            -Detail "$($wait.WaitPercent)% of non-idle waits. $($wait.Recommendation)" `
            -Recommendation 'Correlate with current workload and baseline before tuning.'
    }
}

#endregion

#region ============================================================================
# REPORT OUTPUT PREPARATION
# =================================================================================

$allFindings = @($CriticalIssues + $WarningIssues + $InformationItems)
$criticalCount = $CriticalIssues.Count
$warningCount = $WarningIssues.Count
$infoCount = $InformationItems.Count
$errorCount = $CollectionErrors.Count
$healthScore = [Math]::Max(0, 100 - ($criticalCount * 12) - ($warningCount * 4) - ($errorCount * 2))
# Avoid labeling overall health as "Critical" — that word is reserved for finding severity KPIs.
$healthStatus = if ($healthScore -ge 85) { 'Good' } elseif ($healthScore -ge 65) { 'Fair' } elseif ($healthScore -ge 40) { 'At Risk' } else { 'Poor' }
$healthClass = if ($healthScore -ge 85) { 'good' } elseif ($healthScore -ge 65) { 'warn' } else { 'bad' }
$CategoryGroups = @(@($CriticalIssues) + @($WarningIssues) | Group-Object -Property Category | Sort-Object -Property Count -Descending)
$PopulatedSectionCount = @($Sections.Keys | Where-Object { @($Sections[$_]).Count -gt 0 }).Count

#endregion

#region ============================================================================
# HTML REPORT
# =================================================================================

if ($WantHtml) {

$alwaysShowSections = @('Deprecated Features')

# Enterprise assessment sidebar groups (nav headers + section panels).
$ReportGroups = [ordered]@{
    'Current Architecture / Landscape' = @(
        'Server and Instance Inventory',
        'SQL Services',
        'Infrastructure Volumes',
        'Database Landscape'
    )
    'SQL Server Instance' = @(
        'Instance Configuration',
        'Trace Flags',
        'Database Scoped Configurations',
        'Agent Jobs',
        'Agent Job Failures',
        'Alerts and Operators',
        'Database Mail Status'
    )
    'Database Design' = @(
        'Object Inventory',
        'Table Structure',
        'Data Types Review',
        'Constraints Analysis',
        'FK Index Coverage',
        'Column Nullability and Defaults',
        'Identity and Sequences',
        'Special Table Features',
        'Schema Design Risks',
        'Cross Database Dependencies',
        'Naming Convention Review',
        'Code Object Inventory',
        'Function Risk Analysis',
        'Trigger Analysis',
        'Code Smells'
    )
    'Storage' = @(
        'Filegroups and Files',
        'VLF Assessment',
        'Autogrowth Events',
        'Compression Opportunities',
        'TempDB Health'
    )
    'Tables / Indexes / Objects' = @(
        'Index Inventory',
        'Index Usage',
        'Hot Table Access',
        'Tables With Many Indexes',
        'Missing Index Indicators',
        'Duplicate Overlapping Indexes',
        'Index Fragmentation',
        'Statistics Database Options',
        'Statistics Health'
    )
    'Performance' = @(
        'Wait Statistics',
        'Top Resource Consumers',
        'Implicit Conversion Candidates',
        'Query Store Status',
        'Query Store Forced Plans',
        'Blocking and Long Running',
        'CPU Memory Pressure'
    )
    'Security' = @(
        'Server Security',
        'Server Role Membership',
        'Encryption and Surface Area',
        'Database Principals',
        'Orphaned Users'
    )
    'HA/DR and Synchronization' = @(
        'Availability Group Status',
        'Replication CDC Change Tracking',
        'Backup Status',
        'Linked Servers and Broker'
    )
    'Scalability / Capacity' = @(
        'Capacity Growth Trends'
    )
    'Migration / Modernization Signals' = @(
        'Compatibility Levels',
        'Deprecated Features'
    )
}

$ReportGroupPurpose = [ordered]@{
    'Current Architecture / Landscape' = @{
        Why     = 'You cannot redesign or migrate what you have not inventoried.'
        Purpose = 'Capture the physical/logical footprint: edition, hardware signals, services, disk volumes, and database estate.'
        Helps   = 'Sets the baseline for sizing, hosting choices, and which databases belong in scope for V2 / upgrade work.'
    }
    'SQL Server Instance' = @{
        Why     = 'Instance settings and ops plumbing drive behavior, risk, and day-2 operability.'
        Purpose = 'Review configuration, trace flags, DB-scoped toggles, Agent jobs, alerts, and Database Mail.'
        Helps   = 'Finds misconfiguration, missing maintenance, and weak alerting before you change compatibility or cut over.'
    }
    'Database Design' = @{
        Why     = 'Schema and code quality determine migration cost, service boundaries, and rewrite effort.'
        Purpose = 'Inventory tables/objects, data-model risks, naming, cross-DB coupling, and T-SQL code smells.'
        Helps   = 'Prioritizes redesign vs lift-and-shift, and highlights blockers for microservice or multi-tenant splits.'
    }
    'Storage' = @{
        Why     = 'File layout and growth patterns are a top cause of outages and slow recoveries.'
        Purpose = 'Assess filegroups, VLFs, autogrowth, compression candidates, and TempDB health.'
        Helps   = 'Informs storage architecture, pre-growth plans, and TempDB redesign before load testing.'
    }
    'Tables / Indexes / Objects' = @{
        Why     = 'Indexes and statistics dominate query cost and maintenance windows.'
        Purpose = 'Map index inventory/usage, hot tables, missing/duplicate indexes, fragmentation, and stats health.'
        Helps   = 'Builds a practical performance remediation backlog and reduces surprise regressions after upgrades.'
    }
    'Performance' = @{
        Why     = 'A current-state performance snapshot is required before claiming upgrade or architecture success.'
        Purpose = 'Collect waits, top consumers, conversion heuristics, Query Store depth, blocking, and memory pressure.'
        Helps   = 'Establishes a before baseline and points to the first performance risks to validate after cutover.'
    }
    'Security' = @{
        Why     = 'Privilege and surface-area issues travel with the platform into any new environment.'
        Purpose = 'Review logins/roles, encryption/surface area, database principals, and orphaned users.'
        Helps   = 'Reduces blast radius and cleanup work during migration; supports security workshop preparation.'
    }
    'HA/DR and Synchronization' = @{
        Why     = 'Availability and sync features constrain RPO/RTO options and target architecture.'
        Purpose = 'Detect AG, CDC/CT/replication, backup posture, and linked-server/broker dependencies.'
        Helps   = 'Feeds HA/DR and integration design discussions with facts instead of assumptions.'
    }
    'Scalability / Capacity' = @{
        Why     = 'Growth trends decide whether the current platform will hold through the modernization window.'
        Purpose = 'Track capacity growth signals from backup/history evidence.'
        Helps   = 'Supports sizing, retention, and cost conversations without inventing business forecasts.'
    }
    'Migration / Modernization Signals' = @{
        Why     = 'Compatibility and deprecated features are hard blockers for version and CE moves.'
        Purpose = 'Surface compatibility levels and deprecated/removed feature usage.'
        Helps   = 'Builds a sequenced remediation list before raising compatibility level or moving to a newer engine.'
    }
}

$SectionPurpose = [ordered]@{
    'Server and Instance Inventory' = @{
        Why = 'Edition, version, and hardware limits frame every later recommendation.'
        Purpose = 'Collect instance identity, version/edition, CPU, memory, and NUMA-related signals.'
        Helps = 'Confirms whether the platform can support target features and expected workload scale.'
    }
    'SQL Services' = @{
        Why = 'Stopped or misaligned services break Agent, Full-Text, and related capabilities.'
        Purpose = 'List SQL-related Windows services and start-mode/state.'
        Helps = 'Catches operational gaps that look like “SQL problems” but are service configuration.'
    }
    'Infrastructure Volumes' = @{
        Why = 'Disk free space and volume layout drive outage risk and file placement decisions.'
        Purpose = 'Report volume free space and mount points visible to the instance.'
        Helps = 'Prioritizes storage remediation and validates data/log/TempDB separation assumptions.'
    }
    'Database Landscape' = @{
        Why = 'You need a complete estate map before scoping assessment or migration waves.'
        Purpose = 'Inventory databases with recovery model, size, status, and key options.'
        Helps = 'Defines in-scope databases and highlights outliers (huge, simple recovery, offline, etc.).'
    }
    'Instance Configuration' = @{
        Why = 'sp_configure values strongly affect concurrency, memory, and security posture.'
        Purpose = 'Capture important instance configuration settings currently in use.'
        Helps = 'Flags risky defaults (MAXDOP, memory, xp_cmdshell, etc.) before change windows.'
    }
    'Trace Flags' = @{
        Why = 'Startup/session trace flags can alter optimizer and engine behavior silently.'
        Purpose = 'List enabled trace flags and categorize common vs unusual ones.'
        Helps = 'Prevents surprise behavior differences after upgrade when flags are missing or obsolete.'
    }
    'Database Scoped Configurations' = @{
        Why = 'Modern optimizer/IQP behavior is often controlled per database.'
        Purpose = 'Collect database-scoped configuration toggles relevant to CE/IQP.'
        Helps = 'Supports controlled compatibility upgrades and isolates feature side effects.'
    }
    'Agent Jobs' = @{
        Why = 'Maintenance and business jobs are part of the operational contract.'
        Purpose = 'Inventory SQL Agent jobs, owners, enabled state, and schedules.'
        Helps = 'Shows what must be rewritten, reowned, or validated on the target platform.'
    }
    'Agent Job Failures' = @{
        Why = 'Recent failures indicate broken maintenance before you add more change risk.'
        Purpose = 'Pull failed job history for the configured lookback window.'
        Helps = 'Creates an immediate ops triage list that blocks “green” upgrade claims.'
    }
    'Alerts and Operators' = @{
        Why = 'Without alerts/operators, severity and job failures may go unnoticed.'
        Purpose = 'Review Agent alerts, operators, and notification wiring.'
        Helps = 'Assesses observability readiness for production and cutover monitoring.'
    }
    'Database Mail Status' = @{
        Why = 'Many alerts and job notifications depend on Database Mail.'
        Purpose = 'Show mail profiles, accounts, config, and related XP settings.'
        Helps = 'Confirms whether notification paths will work after migration or hardening.'
    }
    'Object Inventory' = @{
        Why = 'Object counts reveal complexity and modernization surface area.'
        Purpose = 'Count tables, views, procedures, functions, and related object types per database.'
        Helps = 'Sizes assessment effort and highlights unusually code-heavy databases.'
    }
    'Table Structure' = @{
        Why = 'Physical table design affects storage, partitioning, and access patterns.'
        Purpose = 'Baseline table storage, row counts, heaps vs clustered, and partition signals.'
        Helps = 'Identifies large/hot structures that need special migration or redesign attention.'
    }
    'Data Types Review' = @{
        Why = 'Legacy and oversized types create upgrade and application friction.'
        Purpose = 'Flag deprecated or risky data types (TEXT/IMAGE, float misuse, wide LOBs, etc.).'
        Helps = 'Feeds a concrete type-modernization backlog before ORM/API redesign.'
    }
    'Constraints Analysis' = @{
        Why = 'Constraints encode business rules the app may also assume.'
        Purpose = 'Inventory PK/FK/check/unique/default constraints and trust state.'
        Helps = 'Surfaces integrity gaps and untrusted constraints that hurt plans and data quality.'
    }
    'FK Index Coverage' = @{
        Why = 'Unindexed FKs cause deletes/updates and joins to escalate into scans/blocking.'
        Purpose = 'Check whether foreign keys have supporting indexes.'
        Helps = 'Quick wins for write and join performance during remediation.'
    }
    'Column Nullability and Defaults' = @{
        Why = 'Nullability/defaults affect ETL, APIs, and insert paths.'
        Purpose = 'Review nullable columns and default constraints on key tables.'
        Helps = 'Highlights schema contracts that apps and migrations must preserve.'
    }
    'Identity and Sequences' = @{
        Why = 'Identity/sequence strategy impacts merge, multi-tenant, and HA designs.'
        Purpose = 'List identity columns and sequence objects with range/usage signals.'
        Helps = 'Informs key redesign and collision risk for distributed or consolidated targets.'
    }
    'Special Table Features' = @{
        Why = 'Temporal, in-memory, FILESTREAM, and similar features change migration options.'
        Purpose = 'Detect special engine table features in use.'
        Helps = 'Prevents feature-support surprises on Azure MI/SQL DB or newer on-prem editions.'
    }
    'Schema Design Risks' = @{
        Why = 'Heaps, missing PKs, and similar smells predict operational pain.'
        Purpose = 'Heuristic scan for common schema anti-patterns.'
        Helps = 'Prioritizes design workshops with evidence instead of opinion.'
    }
    'Cross Database Dependencies' = @{
        Why = 'Cross-DB coupling blocks clean service extraction and DB moves.'
        Purpose = 'Map partial cross-database and three-part dependency references.'
        Helps = 'Guides boundary decisions and migration sequencing (partial evidence only).'
    }
    'Naming Convention Review' = @{
        Why = 'Inconsistent naming raises onboarding and automation cost.'
        Purpose = 'Heuristic naming checks on schemas/tables/objects.'
        Helps = 'Starts a standards conversation; not a substitute for project naming policy.'
    }
    'Code Object Inventory' = @{
        Why = 'Procedures/functions/views/triggers are major modernization cost drivers.'
        Purpose = 'Inventory code objects by type and basic metadata.'
        Helps = 'Scopes rewrite vs reuse decisions for V2 services.'
    }
    'Function Risk Analysis' = @{
        Why = 'Scalar UDFs and some TVFs are common performance cliffs.'
        Purpose = 'Flag function types and risk notes tied to execution patterns.'
        Helps = 'Targets high-impact refactor candidates before compatibility changes.'
    }
    'Trigger Analysis' = @{
        Why = 'Triggers hide side effects that break migrations and APIs.'
        Purpose = 'List triggers and basic patterns (nested/complex signals where available).'
        Helps = 'Makes invisible business logic visible for redesign workshops.'
    }
    'Code Smells' = @{
        Why = 'NOLOCK, cursors, dynamic SQL, and similar patterns increase risk.'
        Purpose = 'Heuristic scan of module text for common anti-patterns.'
        Helps = 'Builds a code-quality backlog tied to real objects, not generic advice.'
    }
    'Filegroups and Files' = @{
        Why = 'File placement and growth settings affect availability and I/O.'
        Purpose = 'Detail filegroups, files, sizes, and autogrowth settings.'
        Helps = 'Supports storage redesign and pre-sizing before cutover.'
    }
    'VLF Assessment' = @{
        Why = 'Excess VLFs slow recovery and can hurt log reuse.'
        Purpose = 'Count VLFs per log file and rate severity.'
        Helps = 'Identifies log hygiene work that should precede heavy load or migration.'
    }
    'Autogrowth Events' = @{
        Why = 'Frequent autogrowth causes stalls and fragmentation of free space.'
        Purpose = 'Show recent autogrowth activity from the default trace / lookback.'
        Helps = 'Proves whether growth is reactive and needs proactive sizing.'
    }
    'Compression Opportunities' = @{
        Why = 'Large uncompressed tables waste I/O and buffer pool.'
        Purpose = 'Find large tables without compression as candidates.'
        Helps = 'Prioritizes storage/I/O wins; still requires sampling before enablement.'
    }
    'TempDB Health' = @{
        Why = 'TempDB is a shared bottleneck for sorts, hashes, version store, and spills.'
        Purpose = 'Review TempDB files, sizing equality, and basic health signals.'
        Helps = 'Guides TempDB redesign before performance or upgrade tests.'
    }
    'Index Inventory' = @{
        Why = 'You cannot tune what you have not inventoried.'
        Purpose = 'List indexes with keys, includes, type, and size signals.'
        Helps = 'Foundation for usage, duplicate, and maintenance analysis.'
    }
    'Index Usage' = @{
        Why = 'Unused and write-heavy indexes waste CPU, I/O, and storage.'
        Purpose = 'Show seeks/scans/lookups/updates from index usage stats.'
        Helps = 'Ranks drop/keep candidates (resets on restart; treat as ranking evidence).'
    }
    'Hot Table Access' = @{
        Why = 'A few tables usually dominate read/write load.'
        Purpose = 'Aggregate index usage to highlight frequently accessed tables.'
        Helps = 'Focuses design, indexing, and caching effort on real hotspots.'
    }
    'Tables With Many Indexes' = @{
        Why = 'Over-indexed tables slow writes and complicate plans.'
        Purpose = 'Find tables with unusually high index counts.'
        Helps = 'Targets consolidation workshops for write-heavy schemas.'
    }
    'Missing Index Indicators' = @{
        Why = 'DMV suggestions often point to expensive scan patterns.'
        Purpose = 'Surface missing-index DMV recommendations with impact ranking.'
        Helps = 'Seed for index design review — not ready-to-run CREATE INDEX scripts.'
    }
    'Duplicate Overlapping Indexes' = @{
        Why = 'Overlapping indexes duplicate maintenance cost with little benefit.'
        Purpose = 'Detect duplicate/overlapping key patterns.'
        Helps = 'Quick storage and write-path savings after validation.'
    }
    'Index Fragmentation' = @{
        Why = 'Severe fragmentation can inflate I/O on large indexes.'
        Purpose = 'Limited fragmentation sample with rebuild/reorganize hints.'
        Helps = 'Feeds maintenance planning; not a full estate rebuild mandate.'
    }
    'Statistics Database Options' = @{
        Why = 'Auto create/update/async settings change plan stability.'
        Purpose = 'Check database-level statistics options.'
        Helps = 'Flags disabled auto-stats before blaming the optimizer or CE.'
    }
    'Statistics Health' = @{
        Why = 'Stale stats are a leading cause of bad plans after data growth or restore.'
        Purpose = 'Highlight statistics that look stale or risky.'
        Helps = 'Prioritizes UPDATE STATISTICS work before compatibility upgrades.'
    }
    'Wait Statistics' = @{
        Why = 'Waits explain where time is spent since the last reset.'
        Purpose = 'Top non-idle waits with resource/signal split, percent of total, and recommendations.'
        Helps = 'Points assessment toward I/O, CPU, locking, memory, or other systemic themes.'
    }
    'Top Resource Consumers' = @{
        Why = 'A small set of queries usually drives CPU and duration.'
        Purpose = 'Rank plan-cache consumers by CPU/duration/execution.'
        Helps = 'Creates a focused query-tuning shortlist for before/after baselines.'
    }
    'Implicit Conversion Candidates' = @{
        Why = 'Type mismatches silently destroy index usage.'
        Purpose = 'Heuristic scan of plan cache text for CAST/CONVERT/COLLATE patterns.'
        Helps = 'Starts conversion cleanup; not guaranteed CONVERT_IMPLICIT proof for every plan.'
    }
    'Query Store Status' = @{
        Why = 'Query Store is the safest way to compare plans across upgrades.'
        Purpose = 'Report whether QS is on and basic configuration/state.'
        Helps = 'Confirms you can capture regressions before compatibility changes.'
    }
    'Query Store Forced Plans' = @{
        Why = 'Forced plans may hide regressions or fail after upgrade.'
        Purpose = 'List forced Query Store plans and failure signals where available.'
        Helps = 'Validates which band-aids must be retested after CE/IQP changes.'
    }
    'Blocking and Long Running' = @{
        Why = 'Current blockers show concurrency pain under real load.'
        Purpose = 'Capture active blocking chains and long-running requests.'
        Helps = 'Evidence for locking/isolation redesign and cutover risk.'
    }
    'CPU Memory Pressure' = @{
        Why = 'Sustained CPU/memory pressure limits scalability claims.'
        Purpose = 'Snapshot pressure-related counters and signals.'
        Helps = 'Supports sizing and workload isolation recommendations.'
    }
    'Server Security' = @{
        Why = 'Standing high privilege is a migration and audit risk.'
        Purpose = 'Review logins, sa/sysadmin posture, and disabled state.'
        Helps = 'Builds a privilege-reduction list before handing off environments.'
    }
    'Server Role Membership' = @{
        Why = 'Broad server roles often exceed least-privilege needs.'
        Purpose = 'Map principals to server roles.'
        Helps = 'Supports role rationalization in security workshops.'
    }
    'Encryption and Surface Area' = @{
        Why = 'TDE, trustworthy, and surface-area settings affect compliance and risk.'
        Purpose = 'Collect encryption and surface-area configuration signals.'
        Helps = 'Flags hardening work required for target platforms and audits.'
    }
    'Database Principals' = @{
        Why = 'Database users/roles define the app security contract.'
        Purpose = 'Inventory database principals and membership signals.'
        Helps = 'Prepares remap/cleanup plans for restore and environment promotion.'
    }
    'Orphaned Users' = @{
        Why = 'Orphans break app connectivity after restore/migration.'
        Purpose = 'Detect database users without matching logins.'
        Helps = 'Must-fix checklist item for any database move.'
    }
    'Availability Group Status' = @{
        Why = 'AG topology constrains failover and read-scale options.'
        Purpose = 'Report AG/replica health signals when present.'
        Helps = 'Feeds HA design with current-state facts, not assumptions.'
    }
    'Replication CDC Change Tracking' = @{
        Why = 'Sync features dictate integration and near-real-time options.'
        Purpose = 'Detect replication, CDC, change tracking, mirroring, and related flags.'
        Helps = 'Informs Kafka/outbox/CDC workshops with capability signals only.'
    }
    'Backup Status' = @{
        Why = 'Backup age is the practical RPO signal available from SQL.'
        Purpose = 'Show last full/diff/log backup ages against SLA thresholds.'
        Helps = 'Assesses backup strategy health; restore-test proof remains workshop work.'
    }
    'Linked Servers and Broker' = @{
        Why = 'External dependencies complicate isolation and cloud moves.'
        Purpose = 'Inventory linked servers and Service Broker usage signals.'
        Helps = 'Maps integration coupling that architecture diagrams must include.'
    }
    'Capacity Growth Trends' = @{
        Why = 'Growth velocity decides whether the estate will outrun current hardware.'
        Purpose = 'Trend capacity using backup-size history over the lookback window.'
        Helps = 'Supports sizing and cost talks with measured growth, not guesses.'
    }
    'Compatibility Levels' = @{
        Why = 'Compatibility level controls CE and many modern optimizer behaviors.'
        Purpose = 'List database compatibility levels versus instance capability.'
        Helps = 'Sequences upgrade waves and identifies lagging databases.'
    }
    'Deprecated Features' = @{
        Why = 'Deprecated/removed features break upgrades and block modernization.'
        Purpose = 'Scan for removed/deprecated types, T-SQL, jobs, and configs (2012-2022).'
        Helps = 'Produces a severity-ranked remediation list before raising compat or moving engines.'
    }
}

function Get-PurposeHtml {
    param(
        $Info,
        [string]$Title = 'Why this is collected'
    )
    if (-not $Info) { return '' }
    $why = ConvertTo-HtmlEncoded ([string]$Info.Why)
    $purpose = ConvertTo-HtmlEncoded ([string]$Info.Purpose)
    $helps = ConvertTo-HtmlEncoded ([string]$Info.Helps)
    return @"
<div class='purpose'>
  <div class='purpose-title'>$Title</div>
  <div class='purpose-grid'>
    <div><span>Why</span><p>$why</p></div>
    <div><span>Purpose</span><p>$purpose</p></div>
    <div><span>Assessment value</span><p>$helps</p></div>
  </div>
</div>
"@
}

function Get-DeprecatedFeaturesSummaryHtml {
    param([object[]]$Rows)

    $rows = @($Rows)
    if ($rows.Count -eq 0) { return '' }

    $severityRank = @{
        'CRITICAL' = 1
        'HIGH'     = 2
        'MEDIUM'   = 3
        'LOW'      = 4
        'INFO'     = 5
    }

    $summaryRows = @(
        $rows |
            Group-Object -Property DeprecatedFeature |
            ForEach-Object {
                $worst = @(
                    $_.Group |
                        ForEach-Object { [string]$_.Severity } |
                        Sort-Object { if ($severityRank.ContainsKey($_)) { $severityRank[$_] } else { 99 } }
                ) | Select-Object -First 1
                if (-not $worst) { $worst = 'INFO' }
                [pscustomobject]@{
                    DeprecatedFeature = [string]$_.Name
                    OccurrenceCount   = $_.Count
                    Criticality       = $worst
                    DatabasesTouched  = @($_.Group | ForEach-Object { [string]$_.DatabaseName } | Select-Object -Unique).Count
                }
            } |
            Sort-Object @{ Expression = { if ($severityRank.ContainsKey([string]$_.Criticality)) { $severityRank[[string]$_.Criticality] } else { 99 } } },
                        @{ Expression = 'OccurrenceCount'; Descending = $true },
                        DeprecatedFeature
    )

    $criticalCount = @($summaryRows | Where-Object { $_.Criticality -eq 'CRITICAL' }).Count
    $highCount = @($summaryRows | Where-Object { $_.Criticality -eq 'HIGH' }).Count
    $totalHits = $rows.Count
    $distinctFeatures = $summaryRows.Count
    $summaryTable = ConvertTo-HtmlTable -Data $summaryRows -TableId 'deprecated-features-summary'

    return @"
<div class='summary-box'>
  <h3>Deprecated features summary</h3>
  <p class='note'><strong>$distinctFeatures</strong> distinct deprecated/removed feature(s) across <strong>$totalHits</strong> finding(s)
  | Critical features: <strong>$criticalCount</strong>
  | High features: <strong>$highCount</strong>.
  Fix Critical first, then High, before upgrade or compatibility changes.</p>
  $summaryTable
</div>
"@
}

function Get-StatisticsUpdateSummaryHtml {
    param([object[]]$Rows)

    $rows = @($Rows)
    $needsUpdate = @(
        $rows | Where-Object {
            ([string]$_.RequiresUpdate -eq 'Yes') -or
            ([string]$_.Assessment -match 'UPDATE REQUIRED|Stale')
        }
    )
    if ($needsUpdate.Count -eq 0) {
        return "<div class='summary-box'><h3>Statistics update summary</h3><p class='good-text'>No tables are currently flagged as requiring UPDATE STATISTICS.</p></div>"
    }

    $tableSummary = @(
        $needsUpdate |
            Group-Object -Property DatabaseName, SchemaName, TableName |
            ForEach-Object {
                $sample = $_.Group[0]
                $reasons = @($_.Group | ForEach-Object { [string]$_.Assessment } | Select-Object -Unique) -join '; '
                $maxMods = ($_.Group | ForEach-Object {
                    $v = $_.ModificationPercent
                    if ($null -eq $v -or $v -eq '') { 0 } else { [double]$v }
                } | Measure-Object -Maximum).Maximum
                [pscustomobject]@{
                    DatabaseName           = [string]$sample.DatabaseName
                    SchemaName             = [string]$sample.SchemaName
                    TableName              = [string]$sample.TableName
                    StatsRequiringUpdate   = $_.Count
                    MaxModificationPercent = [math]::Round([double]$maxMods, 2)
                    Action                 = 'UPDATE STATISTICS'
                    Reason                 = $reasons
                }
            } |
            Sort-Object @{ Expression = 'MaxModificationPercent'; Descending = $true }, DatabaseName, SchemaName, TableName
    )

    $summaryTable = ConvertTo-HtmlTable -Data $tableSummary -TableId 'statistics-update-summary'
    return @"
<div class='summary-box'>
  <h3>Tables requiring statistics update</h3>
  <p class='note'><strong>$($tableSummary.Count)</strong> table(s) flagged for <strong>UPDATE STATISTICS</strong>
  across <strong>$($needsUpdate.Count)</strong> statistics object(s). Prioritize high modification percent and large stale tables before compatibility or CE changes.</p>
  $summaryTable
</div>
"@
}

function Get-SectionId {
    param([string]$Name)
    return ($Name -replace '[^A-Za-z0-9]+', '-').Trim('-').ToLowerInvariant()
}

function Get-ScopeSectionLink {
    param([string]$SectionName)
    $id = Get-SectionId $SectionName
    return "<a href='#$id' data-target='$id' class='scope-link'>$(ConvertTo-HtmlEncoded $SectionName)</a>"
}

$dbFilterOptions = New-Object System.Collections.Generic.List[string]
$dbFilterOptions.Add("<option value=''>All databases</option>")
foreach ($name in ($UserDatabaseNames | Sort-Object)) {
    $selectedAttr = if ($DatabaseScopeExplicit -and $UserDatabaseNames.Count -eq 1 -and $name -eq $UserDatabaseNames[0]) { ' selected' } else { '' }
    $dbFilterOptions.Add("<option value='$(ConvertTo-HtmlEncoded $name)'$selectedAttr>$(ConvertTo-HtmlEncoded $name)</option>")
}

$navHtml = [System.Text.StringBuilder]::new()
$panelHtml = [System.Text.StringBuilder]::new()

[void]$navHtml.Append("<div class='nav-group'>1. Executive Summary</div>")
[void]$navHtml.Append("<a class='nav-item active' href='#summary' data-target='summary'>Summary of Findings<span class='badge'>$criticalCount / $warningCount</span></a>")

$findingsTable = if ($allFindings.Count -eq 0) {
    "<p class='good-text'>No automated findings were raised. Review evidence sections for architecture decisions.</p>"
} else {
    ConvertTo-HtmlTable -Data $allFindings -TableId 'allFindings'
}

[void]$panelHtml.Append(@"
<section class='panel active' id='summary'>
  <div class='header'>
    <h1>SQL Server Initial Assessment</h1>
    <div class='meta'>$(ConvertTo-HtmlEncoded $ServerIP) | $($ReportTimestamp.ToString('yyyy-MM-dd HH:mm')) | v$ScriptVersion | Database scope: $(ConvertTo-HtmlEncoded $DatabaseScopeLabel)</div>
  </div>
  <div class='score-row'>
    <div class='kpis'>
      <button type='button' class='kpi bad' data-kpi='Critical' title='Show Critical findings'>
        <div class='num'>$criticalCount</div><div class='lbl'>Critical</div>
      </button>
      <button type='button' class='kpi warn' data-kpi='Warning' title='Show Warning findings'>
        <div class='num'>$warningCount</div><div class='lbl'>Warning</div>
      </button>
      <button type='button' class='kpi info' data-kpi='Info' title='Show Info findings'>
        <div class='num'>$infoCount</div><div class='lbl'>Info</div>
      </button>
      <button type='button' class='kpi muted' data-kpi='CollectionErrors' title='Show Collection Errors'>
        <div class='num'>$errorCount</div><div class='lbl'>Collection Errors</div>
      </button>
    </div>
  </div>
  <div class='section'>
    <h2>Prioritized Findings</h2>
    <p id='findingsFilterNote' class='note'>Click a KPI card above to filter findings by severity.</p>
    <div class='purpose'>
      <div class='purpose-title'>Why this summary exists</div>
      <div class='purpose-grid'>
        <div><span>Why</span><p>Stakeholders need a ranked entry point before diving into evidence tables.</p></div>
        <div><span>Purpose</span><p>Roll Critical/Warning/Info findings and collection gaps into one executive view.</p></div>
        <div><span>Assessment value</span><p>Drives workshop agenda and remediation sequencing from automated SQL evidence only.</p></div>
      </div>
    </div>
    $findingsTable
  </div>
</section>
"@)

$groupIndex = 2
foreach ($groupName in $ReportGroups.Keys) {
    $groupSections = @($ReportGroups[$groupName])
    $visibleInGroup = New-Object System.Collections.Generic.List[string]
    foreach ($sectionName in $groupSections) {
        $rows = @($Sections[$sectionName])
        $forceShow = $alwaysShowSections -contains $sectionName
        if ($rows.Count -eq 0 -and -not $forceShow) { continue }
        $visibleInGroup.Add($sectionName)
    }
    if ($visibleInGroup.Count -eq 0) { continue }

    [void]$navHtml.Append("<div class='nav-group'>$groupIndex. $(ConvertTo-HtmlEncoded $groupName)</div>")
    $groupPurposeHtml = Get-PurposeHtml -Info $ReportGroupPurpose[$groupName] -Title ("Category: {0}" -f $groupName)
    $isFirstSectionInGroup = $true
    foreach ($sectionName in $visibleInGroup) {
        $rows = @($Sections[$sectionName])
        $sectionId = Get-SectionId $sectionName
        $countLabel = if ($rows.Count -eq 0) { '0' } else { [string]$rows.Count }
        [void]$navHtml.Append("<a class='nav-item' href='#$sectionId' data-target='$sectionId'>$(ConvertTo-HtmlEncoded $sectionName)<span class='count'>$countLabel</span></a>")
        $sectionPurposeHtml = Get-PurposeHtml -Info $SectionPurpose[$sectionName] -Title 'Section intent'
        $categoryBanner = if ($isFirstSectionInGroup) { $groupPurposeHtml } else {
            "<p class='category-chip'>Category: $(ConvertTo-HtmlEncoded $groupName)</p>"
        }
        $sectionBody = if ($rows.Count -eq 0) {
            if ($sectionName -eq 'Deprecated Features') {
                @"
$categoryBanner
$sectionPurposeHtml
<p class='note'><strong>What this section covers:</strong> removed and deprecated SQL Server features (2012-2022) that can break upgrades or block modernization — data types, T-SQL syntax, legacy procedures, crypto, Agent jobs, and deprecated configuration options.</p>
<p class='no-data'>No deprecated or discontinued feature markers were detected. That is good for upgrade readiness; still review Data Types Review / Code Smells for related risks.</p>
"@
            }
            else {
                @"
$categoryBanner
$sectionPurposeHtml
<p class='no-data'>No data available.</p>
"@
            }
        } else {
            $tableHtml = ConvertTo-HtmlTable -Data $rows -TableId $sectionId
            if ($sectionName -eq 'Deprecated Features') {
                $deprecatedSummaryHtml = Get-DeprecatedFeaturesSummaryHtml -Rows $rows
                @"
$categoryBanner
$sectionPurposeHtml
$deprecatedSummaryHtml
<p class='note'>
<strong>Reading guide:</strong> CRITICAL = removed/must-fix before upgrade; HIGH = fix before or soon after; MEDIUM/LOW = plan remediation; INFO = awareness.<br/>
<strong>Detail table below:</strong> one row per occurrence. Use the summary above for feature-level triage.
</p>
$tableHtml
"@
            }
            elseif ($sectionName -eq 'Statistics Health') {
                $statsSummaryHtml = Get-StatisticsUpdateSummaryHtml -Rows $rows
                @"
$categoryBanner
$sectionPurposeHtml
$statsSummaryHtml
<p class='note'><strong>RequiresUpdate = Yes</strong> means that statistics object should be refreshed with UPDATE STATISTICS. Detail rows below include every statistics object; focus on flagged tables first.</p>
$tableHtml
"@
            }
            else {
                @"
$categoryBanner
$sectionPurposeHtml
$tableHtml
"@
            }
        }
        [void]$panelHtml.Append(@"
<section class='panel' id='$sectionId'>
  <div class='section'>
    <h2>$(ConvertTo-HtmlEncoded $sectionName)</h2>
    $sectionBody
  </div>
</section>
"@)
        $isFirstSectionInGroup = $false
    }
    $groupIndex++
}

$autoScopeRows = @(
    @{ Area = 'Landscape / instance'; Evidence = 'Inventory, services, volumes, database landscape, configuration, trace flags, DB scoped config' },
    @{ Area = 'Schema / design'; Evidence = 'Table structure, types, constraints, FK indexes, nullability, identity, special features, design risks, naming, cross-DB deps' },
    @{ Area = 'Indexes / statistics'; Evidence = 'Inventory, usage, hot tables, many indexes, missing/duplicate, fragmentation, stats options/health' },
    @{ Area = 'Code quality'; Evidence = 'Object inventory, scalar UDF risk, triggers, code smells' },
    @{ Area = 'Performance'; Evidence = 'Waits, top queries, implicit-conversion heuristic, Query Store status/forced plans, TempDB, blocking, memory' },
    @{ Area = 'Storage / capacity'; Evidence = 'Filegroups, VLF, autogrowth, compression opportunities, capacity growth' },
    @{ Area = 'Security'; Evidence = 'Logins/sysadmins, role membership, encryption/surface, principals, orphaned users' },
    @{ Area = 'HA/DR / sync signals'; Evidence = 'AG, CDC/CT/replication, backups, linked servers/broker' },
    @{ Area = 'Maintenance ops'; Evidence = 'Agent jobs/failures, alerts/operators, Database Mail' },
    @{ Area = 'Migration signals'; Evidence = 'Compatibility levels, deprecated features' }
)
$partialScopeRows = @(
    @{ Area = 'Cross-database dependency map'; Note = 'Partial from sys.sql_expression_dependencies / three-part names; not full app call graph' },
    @{ Area = 'Naming conventions'; Note = 'Heuristic pattern checks only; project standards need interview confirmation' },
    @{ Area = 'Implicit conversions'; Note = 'Plan-cache / query-text heuristic; not guaranteed CONVERT_IMPLICIT proof for every plan' },
    @{ Area = 'Hot table access'; Note = 'Based on index usage DMVs since last restart; not business criticality' },
    @{ Area = 'Compression opportunities'; Note = 'Size/uncompressed signals; estimate savings with real sampling before change' },
    @{ Area = 'Backup strategy review'; Note = 'Age/SLA signals only; restore-test evidence is workshop work' }
)
$workshopScopeRows = @(
    @{ Area = 'Architecture diagrams / module ownership'; Why = 'Cannot invent application topology from DMVs' },
    @{ Area = 'RPO/RTO / SLA targets'; Why = 'Business targets, not discoverable from SQL alone' },
    @{ Area = 'Multi-tenant strategy'; Why = 'Requires domain/workshop decisions' },
    @{ Area = 'Kafka / Debezium / outbox readiness'; Why = 'Integration design; CDC flags are signals only' },
    @{ Area = 'ORM / EF / N+1 review'; Why = 'Application-layer evidence required' },
    @{ Area = 'Restore-test / DR drill evidence'; Why = 'Operational proof outside collector' },
    @{ Area = 'Cost/benefit and roadmap costing'; Why = 'Consulting narrative, not SQL evidence' },
    @{ Area = 'Target architecture / cloud MI-DB scoring'; Why = 'Capability signals only; no fake readiness scores' }
)

$autoScopeHtml = ($autoScopeRows | ForEach-Object {
    "<tr><td>$(ConvertTo-HtmlEncoded $_.Area)</td><td>$(ConvertTo-HtmlEncoded $_.Evidence)</td></tr>"
}) -join ''
$partialScopeHtml = ($partialScopeRows | ForEach-Object {
    "<tr><td>$(ConvertTo-HtmlEncoded $_.Area)</td><td>$(ConvertTo-HtmlEncoded $_.Note)</td></tr>"
}) -join ''
$workshopScopeHtml = ($workshopScopeRows | ForEach-Object {
    "<tr><td>$(ConvertTo-HtmlEncoded $_.Area)</td><td>$(ConvertTo-HtmlEncoded $_.Why)</td></tr>"
}) -join ''

$sectionLinkList = @(
    'Trace Flags', 'Database Scoped Configurations', 'VLF Assessment', 'Autogrowth Events',
    'Statistics Health', 'Implicit Conversion Candidates', 'Agent Jobs', 'Orphaned Users',
    'Cross Database Dependencies', 'Hot Table Access', 'Compression Opportunities', 'Query Store Forced Plans'
) | ForEach-Object { '<li>' + (Get-ScopeSectionLink $_) + '</li>' }
$sectionLinksHtml = $sectionLinkList -join [Environment]::NewLine

[void]$navHtml.Append("<div class='nav-group'>$groupIndex. Assessment Scope</div>")
[void]$navHtml.Append("<a class='nav-item' href='#scope' data-target='scope'>Assessment Scope</a>")

[void]$panelHtml.Append(@"
<section class='panel' id='scope'>
  <div class='section'>
    <h2>Assessment Scope</h2>
    <div class='purpose'>
      <div class='purpose-title'>Why scope is documented</div>
      <div class='purpose-grid'>
        <div><span>Why</span><p>Assessment checklists mix SQL-provable facts with interview-only topics.</p></div>
        <div><span>Purpose</span><p>Separate automated evidence, heuristics, and workshop items so the report stays truthful.</p></div>
        <div><span>Assessment value</span><p>Prevents false readiness scores and clarifies what still needs architecture workshops.</p></div>
      </div>
    </div>
    <p class='note'>This matrix keeps the collector truthful: SQL evidence is linked below; workshop-only checklist items are listed explicitly and are <strong>not</strong> scored as readiness.</p>

    <h3>Collected automatically</h3>
    <table class='data'><thead><tr><th>Area</th><th>Evidence in this report</th></tr></thead><tbody>$autoScopeHtml</tbody></table>
    <p>Key new evidence sections:</p>
    <ul>$sectionLinksHtml</ul>

    <h3>Partial / heuristic only</h3>
    <table class='data'><thead><tr><th>Area</th><th>Limitation</th></tr></thead><tbody>$partialScopeHtml</tbody></table>

    <h3>Requires interviews / workshops</h3>
    <table class='data'><thead><tr><th>Checklist item</th><th>Why not automated</th></tr></thead><tbody>$workshopScopeHtml</tbody></table>
  </div>
</section>
"@)

# Always include Collection Errors so the KPI can navigate here.
[void]$navHtml.Append("<a class='nav-item' href='#collection-errors' data-target='collection-errors'>Collection Errors<span class='badge'>$($CollectionErrors.Count)</span></a>")
$collectionErrorsBody = if ($CollectionErrors.Count -gt 0) {
    ConvertTo-HtmlTable -Data @($CollectionErrors) -TableId 'collection-errors'
} else {
    "<p class='good-text'>No collection errors.</p>"
}
[void]$panelHtml.Append(@"
<section class='panel' id='collection-errors'>
  <div class='section'>
    <h2>Collection Errors</h2>
    <div class='purpose'>
      <div class='purpose-title'>Why collection errors are listed</div>
      <div class='purpose-grid'>
        <div><span>Why</span><p>Some collectors fail on permissions, version gaps, or missing features.</p></div>
        <div><span>Purpose</span><p>Isolate failures per section/database so the rest of the report still ships.</p></div>
        <div><span>Assessment value</span><p>Shows evidence gaps honestly instead of silently omitting checklist areas.</p></div>
      </div>
    </div>
    $collectionErrorsBody
  </div>
</section>
"@)

$HtmlReport = @"
<!DOCTYPE html>
<html lang='en'>
<head>
<meta charset='utf-8'/>
<meta name='viewport' content='width=device-width, initial-scale=1'/>
<title>SQL Initial Assessment - $(ConvertTo-HtmlEncoded $ServerIP)</title>
<style>
:root{--navy:#17243a;--blue:#2563eb;--card:#fff;--bg:#eef2f7;--line:#d8e0ea;--muted:#64748b;--bad:#b91c1c;--warn:#b45309;--good:#15803d;--info:#1d4ed8}
*{box-sizing:border-box}body{margin:0;font-family:Segoe UI,Tahoma,sans-serif;background:var(--bg);color:#0f172a}
.sidebar{position:fixed;top:0;left:0;bottom:0;width:280px;background:var(--navy);color:#e2e8f0;overflow:auto;padding:16px 12px;z-index:20}
.sidebar-title{font-weight:700;font-size:15px;margin:0 8px 14px}.sidebar-title small{display:block;font-weight:400;color:#94a3b8;margin-top:4px}
.nav-group{margin:14px 8px 4px;padding-top:8px;border-top:1px solid #334155;color:#94a3b8;font-size:11px;font-weight:700;letter-spacing:.04em;text-transform:uppercase}
.nav-group:first-child{margin-top:0;padding-top:0;border-top:none}
.nav-item{display:flex;justify-content:space-between;gap:8px;align-items:center;color:#cbd5e1;text-decoration:none;padding:8px 10px;border-radius:8px;margin:2px 0;font-size:13px}
.nav-item:hover,.nav-item.active{background:#243552;color:#fff}
.scope-link{color:#38bdf8;text-decoration:none}
.scope-link:hover{text-decoration:underline}
.purpose{background:#f8fafc;border:1px solid var(--line);border-left:4px solid var(--blue);border-radius:8px;padding:12px 14px;margin:0 0 14px}
.purpose-title{font-size:12px;font-weight:700;color:#334155;text-transform:uppercase;letter-spacing:.03em;margin:0 0 8px}
.purpose-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px}
.purpose-grid span{display:block;font-size:11px;font-weight:700;color:#64748b;text-transform:uppercase;margin-bottom:4px}
.purpose-grid p{margin:0;font-size:13px;line-height:1.4;color:#0f172a}
.category-chip{display:inline-block;margin:0 0 10px;padding:4px 10px;border-radius:999px;background:#e2e8f0;color:#334155;font-size:12px;font-weight:600}
.summary-box{background:#fff7ed;border:1px solid #fdba74;border-radius:8px;padding:12px 14px;margin:0 0 14px}
.summary-box h3{margin:0 0 8px;font-size:15px;color:#9a3412}
.summary-box .note{margin-bottom:10px}
.summary-box .good-text{margin:0}
@media (max-width:1100px){.purpose-grid{grid-template-columns:1fr}}
table.data{width:100%;border-collapse:collapse;margin:10px 0 18px}
table.data th,table.data td{border:1px solid #dbe3ef;padding:8px 10px;text-align:left;vertical-align:top;font-size:13px}
table.data th{background:#eef3f9}
.badge,.count{background:#334155;border-radius:999px;padding:1px 8px;font-size:11px}
.db-filter{margin:8px;padding:10px;background:#1f2f4a;border-radius:8px}
.db-filter label{display:block;font-size:12px;margin-bottom:6px;color:#94a3b8}
.db-filter select,.db-filter input[type='text']{width:100%;padding:6px;border-radius:6px;border:1px solid #475569;background:#0f172a;color:#e2e8f0;margin-bottom:8px}
.db-filter input[type='text']::placeholder{color:#64748b}
.db-filter .filter-hint{display:block;font-size:11px;color:#94a3b8;margin:-4px 0 8px;line-height:1.35}
.db-filter .filter-actions{display:flex;gap:6px}
.db-filter .filter-actions button{flex:1;padding:6px 8px;border-radius:6px;border:1px solid #475569;background:#243552;color:#e2e8f0;cursor:pointer;font-size:12px}
.db-filter .filter-actions button:hover{background:#334155}
.filter-active{display:none;margin-top:6px;font-size:11px;color:#93c5fd}.filter-active.active{display:block}
.main{margin-left:280px;padding:18px}
.panel{display:none}.panel.active{display:block}
.header,.section{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:18px;margin-bottom:16px}
.header h1{margin:0 0 6px;font-size:24px;color:var(--navy)}.meta{color:var(--muted);font-size:13px}
.score-row{display:flex;gap:18px;flex-wrap:wrap;margin:16px 0}
.score{background:linear-gradient(135deg,#1e3a8a,#2563eb);color:#fff;border-radius:14px;padding:18px 24px;min-width:140px;text-align:center}
.score-value{font-size:42px;font-weight:700;line-height:1}.score-label{opacity:.9;margin-top:4px;font-size:13px}
.score-status{margin-top:6px;font-size:12px;font-weight:600;opacity:.95}
.kpis{display:flex;gap:10px;flex-wrap:wrap}
.kpi{background:#fff;border:1px solid var(--line);border-radius:12px;padding:14px 18px;min-width:110px;cursor:pointer;font:inherit;text-align:left}
.kpi:hover,.kpi:focus{outline:2px solid #93c5fd;outline-offset:2px;box-shadow:0 2px 8px #17243a22}
.kpi.active-filter{border-color:var(--blue);box-shadow:0 0 0 2px #93c5fd}
.kpi .num{font-size:28px;font-weight:700}.kpi .lbl{color:var(--muted);font-size:12px}
.kpi.bad .num{color:var(--bad)}.kpi.warn .num{color:var(--warn)}.kpi.info .num{color:var(--info)}
.section h2{margin:0 0 12px;font-size:18px;color:var(--navy)}
.note{background:#eff6ff;border-left:4px solid var(--blue);padding:12px;margin:0 0 14px}
.table-wrap{width:100%;overflow:auto;max-height:72vh}
.data-table{border-collapse:collapse;width:max-content;min-width:100%;font-size:12px}
.data-table th{position:sticky;top:0;background:var(--navy);color:#fff;text-align:left;padding:9px;cursor:pointer;white-space:nowrap}
.data-table td{padding:8px;border-bottom:1px solid var(--line);white-space:nowrap;word-break:normal;max-width:none;vertical-align:top}
.data-table td.long-text{white-space:normal;max-width:80ch;word-break:break-word}
.data-table tr:nth-child(even){background:#f8fafc}
.data-table th.sort-asc::after{content:' \25B2';font-size:9px}.data-table th.sort-desc::after{content:' \25BC';font-size:9px}
.pagination-controls{display:flex;gap:8px;align-items:center;flex-wrap:wrap;padding:10px 0}
.pagination-controls[hidden],.table-empty-state[hidden]{display:none}
.pagination-controls button,.pagination-controls select{border:1px solid #b8c4d6;border-radius:5px;background:#fff;padding:5px 9px}
.no-data,.table-empty-state{color:var(--muted);font-style:italic}.good-text{color:var(--good)}
.footer{text-align:center;color:var(--muted);padding:24px}
.export-btn{position:fixed;top:14px;right:22px;z-index:30;background:linear-gradient(130deg,var(--blue),#1e40af);color:#fff;border:0;border-radius:8px;padding:9px 16px;font-weight:600;cursor:pointer}
@media(max-width:900px){.sidebar{position:static;width:auto}.main{margin-left:0}.export-btn{position:static;margin:10px}}
@media print{.sidebar,.export-btn,.pagination-controls{display:none!important}.main{margin-left:0}.panel{display:block}.table-wrap{max-height:none}}
</style>
</head>
<body>
<button type='button' id='exportExcelButton' class='export-btn'>Export to Excel</button>
<nav class='sidebar'>
  <div class='sidebar-title'>SQL Initial Assessment<small>$(ConvertTo-HtmlEncoded $ServerIP) | $($ReportTimestamp.ToString('yyyy-MM-dd HH:mm'))</small></div>
  <div class='db-filter'>
    <label for='databaseFilter'>Filter evidence by database</label>
    <select id='databaseFilter'>$($dbFilterOptions -join '')</select>
    <label for='schemaNameFilter'>Filter by SchemaName</label>
    <input type='text' id='schemaNameFilter' placeholder='e.g. dbo' autocomplete='off' spellcheck='false' />
    <label for='tableNameFilter'>Filter by TableName</label>
    <input type='text' id='tableNameFilter' placeholder='e.g. Policy' autocomplete='off' spellcheck='false' />
    <span class='filter-hint'>Schema/Table filters apply to table-level sections (structure, types, constraints, FK coverage, nullability, design risks, naming, cross-DB deps, indexes, hot tables, stats, compression, fragmentation, deprecated features).</span>
    <div class='filter-actions'>
      <button type='button' id='applyObjectFilter'>Apply</button>
      <button type='button' id='clearObjectFilter'>Clear</button>
    </div>
    <span id='databaseFilterActive' class='filter-active'>Filter active</span>
  </div>
  $($navHtml.ToString())
</nav>
<main class='main'>
$($panelHtml.ToString())
<footer class='footer'>SQL Server Initial Assessment report | generated $($ReportTimestamp.ToString('yyyy-MM-dd HH:mm')) | v$ScriptVersion</footer>
</main>
<script>
(function () {
  var links = document.querySelectorAll('.nav-item');
  var panels = document.querySelectorAll('.panel');
  function show(id) {
    panels.forEach(function (p) { p.classList.toggle('active', p.id === id); });
    links.forEach(function (l) { l.classList.toggle('active', l.getAttribute('data-target') === id); });
    window.scrollTo(0, 0);
  }
  links.forEach(function (link) {
    link.addEventListener('click', function (e) {
      e.preventDefault();
      show(link.getAttribute('data-target'));
    });
  });
  document.querySelectorAll('.scope-link').forEach(function (link) {
    link.addEventListener('click', function (e) {
      e.preventDefault();
      show(link.getAttribute('data-target'));
    });
  });

  var DATE_RE = /^\d{4}-\d{2}-\d{2}([ T]\d{2}:\d{2}(:\d{2})?)?$/;
  var NUM_RE = /^-?\d+(\.\d+)?\s*(%|ms|mb|gb|kb|days?)?$/i;
  var databaseFilter = document.getElementById('databaseFilter');
  var schemaNameFilter = document.getElementById('schemaNameFilter');
  var tableNameFilter = document.getElementById('tableNameFilter');
  var applyObjectFilter = document.getElementById('applyObjectFilter');
  var clearObjectFilter = document.getElementById('clearObjectFilter');
  var filterIndicator = document.getElementById('databaseFilterActive');
  var findingsFilterNote = document.getElementById('findingsFilterNote');
  var controllers = [];
  var findingsSeverityFilter = '';
  var schemaFilterValue = '';
  var tableFilterValue = '';
  var OBJECT_FILTER_SECTIONS = {
    'table-structure': true,
    'data-types-review': true,
    'constraints-analysis': true,
    'fk-index-coverage': true,
    'column-nullability-and-defaults': true,
    'identity-and-sequences': true,
    'special-table-features': true,
    'schema-design-risks': true,
    'cross-database-dependencies': true,
    'naming-convention-review': true,
    'index-inventory': true,
    'index-usage': true,
    'hot-table-access': true,
    'tables-with-many-indexes': true,
    'duplicate-overlapping-indexes': true,
    'index-fragmentation': true,
    'statistics-health': true,
    'compression-opportunities': true,
    'deprecated-features': true
  };
  function isBlank(t) { return t === '' || t === 'N/A'; }
  function cellText(row, index) { return row.cells[index] ? row.cells[index].textContent.trim() : ''; }
  function normalizeHeader(text) { return text.trim().replace(/\s+/g, '').toLowerCase(); }
  function updateFilterIndicator() {
    var parts = [];
    if (databaseFilter && databaseFilter.value) parts.push('Database=' + databaseFilter.value);
    if (schemaFilterValue) parts.push('SchemaName contains "' + schemaFilterValue + '"');
    if (tableFilterValue) parts.push('TableName contains "' + tableFilterValue + '"');
    filterIndicator.classList.toggle('active', parts.length > 0);
    filterIndicator.textContent = parts.length ? ('Filter active: ' + parts.join(' | ')) : 'Filter inactive';
  }
  function refreshObjectFilteredTables() {
    controllers.forEach(function (c) {
      if (c.supportsObjectFilter || c.databaseColumn >= 0) {
        c.page = 1;
        c.render();
      }
    });
    updateFilterIndicator();
  }

  function TableController(table) {
    this.table = table;
    this.tbody = table.tBodies[0];
    this.headers = table.tHead && table.tHead.rows.length ? table.tHead.rows[0].cells : [];
    this.rows = this.tbody ? Array.prototype.slice.call(this.tbody.rows) : [];
    this.page = 1; this.pageSize = 25; this.sortColumn = null; this.sortDirection = 'asc'; this.printing = false;
    this.databaseColumn = -1;
    this.severityColumn = -1;
    this.schemaColumn = -1;
    this.tableColumn = -1;
    this.supportsObjectFilter = !!OBJECT_FILTER_SECTIONS[table.id];
    for (var h = 0; h < this.headers.length; h++) {
      var headerName = normalizeHeader(this.headers[h].textContent);
      if (headerName === 'databasename') this.databaseColumn = h;
      if (headerName === 'severity') this.severityColumn = h;
      if (headerName === 'schemaname') this.schemaColumn = h;
      if (headerName === 'tablename' || headerName === 'tableorsequencename') this.tableColumn = h;
      if (this.supportsObjectFilter && this.tableColumn < 0 && headerName === 'objectname') this.tableColumn = h;
    }
    this.buildControls(); this.bindSorting(); this.render();
  }
  TableController.prototype.buildControls = function () {
    var self = this;
    this.emptyState = document.createElement('p');
    this.emptyState.className = 'table-empty-state';
    this.emptyState.textContent = 'No rows for selected filter.';
    this.emptyState.hidden = true;
    this.table.parentNode.appendChild(this.emptyState);
    this.controls = document.createElement('div');
    this.controls.className = 'pagination-controls';
    this.controls.hidden = true;
    this.previous = document.createElement('button'); this.previous.type = 'button'; this.previous.textContent = 'Previous';
    this.next = document.createElement('button'); this.next.type = 'button'; this.next.textContent = 'Next';
    this.status = document.createElement('span');
    this.size = document.createElement('select');
    [20,25,30,50].forEach(function (v) {
      var o = document.createElement('option'); o.value = String(v); o.textContent = String(v);
      if (v === 25) o.selected = true; self.size.appendChild(o);
    });
    this.controls.appendChild(this.previous); this.controls.appendChild(this.next);
    this.controls.appendChild(this.status); this.controls.appendChild(this.size);
    this.table.parentNode.appendChild(this.controls);
    this.previous.addEventListener('click', function () { if (self.page > 1) { self.page--; self.render(); } });
    this.next.addEventListener('click', function () { self.page++; self.render(); });
    this.size.addEventListener('change', function () { self.pageSize = parseInt(self.size.value, 10); self.page = 1; self.render(); });
  };
  TableController.prototype.bindSorting = function () {
    var self = this;
    for (var i = 0; i < this.headers.length; i++) {
      (function (th, index) {
        th.tabIndex = 0;
        function activate() {
          self.sortDirection = self.sortColumn === index && self.sortDirection === 'asc' ? 'desc' : 'asc';
          self.sortColumn = index; self.page = 1; self.render();
        }
        th.addEventListener('click', activate);
        th.addEventListener('keydown', function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); activate(); } });
      })(this.headers[i], i);
    }
  };
  TableController.prototype.filteredRows = function () {
    var rows = this.rows.slice();
    var selected = databaseFilter ? databaseFilter.value : '';
    if (selected && this.databaseColumn >= 0) {
      var dbColumn = this.databaseColumn;
      rows = rows.filter(function (row) { return cellText(row, dbColumn).toLowerCase() === selected.toLowerCase(); });
    }
    if (this.table.id === 'allFindings' && findingsSeverityFilter && this.severityColumn >= 0) {
      var sevColumn = this.severityColumn;
      var wanted = findingsSeverityFilter.toLowerCase();
      rows = rows.filter(function (row) { return cellText(row, sevColumn).toLowerCase() === wanted; });
    }
    if (this.supportsObjectFilter) {
      if (schemaFilterValue && this.schemaColumn >= 0) {
        var schemaColumn = this.schemaColumn;
        var schemaNeedle = schemaFilterValue.toLowerCase();
        rows = rows.filter(function (row) {
          return cellText(row, schemaColumn).toLowerCase().indexOf(schemaNeedle) !== -1;
        });
      }
      if (tableFilterValue && this.tableColumn >= 0) {
        var tableColumn = this.tableColumn;
        var tableNeedle = tableFilterValue.toLowerCase();
        rows = rows.filter(function (row) {
          return cellText(row, tableColumn).toLowerCase().indexOf(tableNeedle) !== -1;
        });
      }
    }
    return rows;
  };
  TableController.prototype.sortedRows = function (rows) {
    if (this.sortColumn === null) return rows;
    var index = this.sortColumn, direction = this.sortDirection, isDate = true, isNumeric = true, seen = false;
    rows.forEach(function (row) {
      var text = cellText(row, index); if (isBlank(text)) return; seen = true;
      if (!DATE_RE.test(text)) isDate = false;
      if (!NUM_RE.test(text.replace(/,/g, ''))) isNumeric = false;
    });
    if (!seen) { isDate = false; isNumeric = false; }
    function key(row) {
      var text = cellText(row, index); if (isBlank(text)) return null;
      if (isDate) return Date.parse(text.replace(' ', 'T'));
      if (isNumeric) return parseFloat(text.replace(/,/g, ''));
      return text.toLowerCase();
    }
    var m = direction === 'asc' ? 1 : -1;
    return rows.map(function (row, i) { return { row: row, key: key(row), i: i }; })
      .sort(function (a, b) {
        if (a.key === null && b.key === null) return a.i - b.i;
        if (a.key === null) return -1 * m; if (b.key === null) return 1 * m;
        if (a.key < b.key) return -1 * m; if (a.key > b.key) return 1 * m; return a.i - b.i;
      }).map(function (x) { return x.row; });
  };
  TableController.prototype.render = function () {
    var rows = this.sortedRows(this.filteredRows());
    this.rows.forEach(function (row) { row.style.display = 'none'; });
    for (var i = 0; i < this.headers.length; i++) {
      var active = i === this.sortColumn;
      this.headers[i].classList.toggle('sort-asc', active && this.sortDirection === 'asc');
      this.headers[i].classList.toggle('sort-desc', active && this.sortDirection === 'desc');
    }
    var total = rows.length, paginate = total > 50 && !this.printing;
    var pageCount = Math.max(1, Math.ceil(total / this.pageSize));
    this.page = Math.min(Math.max(1, this.page), pageCount);
    var start = paginate ? (this.page - 1) * this.pageSize : 0;
    var end = paginate ? Math.min(start + this.pageSize, total) : total;
    for (var r = start; r < end; r++) { this.tbody.appendChild(rows[r]); rows[r].style.display = ''; }
    this.table.style.display = total === 0 ? 'none' : '';
    var objectFilterActive = this.supportsObjectFilter && (
      (schemaFilterValue && this.schemaColumn >= 0) ||
      (tableFilterValue && this.tableColumn >= 0)
    );
    var filteredEmpty = total === 0 && (
      (this.databaseColumn >= 0 && databaseFilter && databaseFilter.value) ||
      (this.table.id === 'allFindings' && findingsSeverityFilter) ||
      objectFilterActive
    );
    this.emptyState.hidden = !filteredEmpty;
    this.controls.hidden = !paginate;
    this.status.textContent = 'Page ' + this.page + ' of ' + pageCount + ' | ' + total + ' rows';
    this.previous.disabled = this.page <= 1; this.next.disabled = this.page >= pageCount;
  };

  function setFindingsSeverityFilter(severity) {
    findingsSeverityFilter = severity || '';
    document.querySelectorAll('.kpi[data-kpi]').forEach(function (btn) {
      var isActive = severity && btn.getAttribute('data-kpi') === severity;
      btn.classList.toggle('active-filter', !!isActive);
    });
    if (findingsFilterNote) {
      findingsFilterNote.innerHTML = findingsSeverityFilter
        ? ('Showing <strong>' + findingsSeverityFilter + '</strong> findings only. Click the same KPI again to clear the filter.')
        : 'Click a KPI card above to filter findings by severity.';
    }
    controllers.forEach(function (c) {
      if (c.table.id === 'allFindings') { c.page = 1; c.render(); }
    });
  }

  document.querySelectorAll('.kpi[data-kpi]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var kpi = btn.getAttribute('data-kpi');
      if (kpi === 'CollectionErrors') {
        setFindingsSeverityFilter('');
        show('collection-errors');
        return;
      }
      show('summary');
      if (findingsSeverityFilter === kpi) setFindingsSeverityFilter('');
      else setFindingsSeverityFilter(kpi);
    });
  });

  function applySchemaTableFilters() {
    schemaFilterValue = schemaNameFilter ? schemaNameFilter.value.trim() : '';
    tableFilterValue = tableNameFilter ? tableNameFilter.value.trim() : '';
    refreshObjectFilteredTables();
  }
  if (applyObjectFilter) {
    applyObjectFilter.addEventListener('click', applySchemaTableFilters);
  }
  if (clearObjectFilter) {
    clearObjectFilter.addEventListener('click', function () {
      if (schemaNameFilter) schemaNameFilter.value = '';
      if (tableNameFilter) tableNameFilter.value = '';
      schemaFilterValue = '';
      tableFilterValue = '';
      refreshObjectFilteredTables();
    });
  }
  [schemaNameFilter, tableNameFilter].forEach(function (input) {
    if (!input) return;
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        applySchemaTableFilters();
      }
    });
  });

  var exportSheets = [];
  (function () {
    var used = {};
    function sheetName(raw) {
      var clean = raw.replace(/[\[\]:*?\/\\']/g, ' ').replace(/\s+/g, ' ').trim() || 'Sheet';
      if (clean.length > 31) clean = clean.substring(0, 31).trim();
      var candidate = clean, n = 2;
      while (used[candidate.toLowerCase()]) { var t = '_' + n; candidate = clean.substring(0, Math.min(clean.length, 31 - t.length)) + t; n++; }
      used[candidate.toLowerCase()] = true; return candidate;
    }
    document.querySelectorAll('.data-table').forEach(function (table) {
      if (!table.tHead || !table.tBodies.length) return;
      var section = table.closest('section');
      var heading = section ? section.querySelector('h2') : null;
      var title = table.id === 'allFindings' ? 'Findings Summary' : (heading ? heading.textContent.trim() : (table.id || 'Sheet'));
      exportSheets.push({
        name: sheetName(title),
        headers: Array.prototype.map.call(table.tHead.rows[0].cells, function (c) { return c.textContent.trim(); }),
        rows: Array.prototype.map.call(table.tBodies[0].rows, function (row) {
          return Array.prototype.map.call(row.cells, function (c) { return c.textContent.trim(); });
        })
      });
    });
  })();
  function xmlEscape(t) {
    return String(t).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;')
      .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/g,'');
  }
  var STRICT_NUM_RE = /^-?\d{1,15}(\.\d+)?$/;
  document.getElementById('exportExcelButton').addEventListener('click', function () {
    var parts = ['<?xml version="1.0"?>','<?mso-application progid="Excel.Sheet"?>',
      '<Workbook xmlns="urn:schemas-microsoft-com:office:spreadsheet" xmlns:ss="urn:schemas-microsoft-com:office:spreadsheet">',
      '<Styles><Style ss:ID="hdr"><Font ss:Bold="1"/><Interior ss:Color="#87CEFA" ss:Pattern="Solid"/></Style></Styles>'];
    exportSheets.forEach(function (sheet) {
      parts.push('<Worksheet ss:Name="' + xmlEscape(sheet.name) + '"><Table><Row>');
      sheet.headers.forEach(function (h) { parts.push('<Cell ss:StyleID="hdr"><Data ss:Type="String">' + xmlEscape(h) + '</Data></Cell>'); });
      parts.push('</Row>');
      sheet.rows.forEach(function (row) {
        parts.push('<Row>');
        row.forEach(function (value) {
          var n = value.replace(/,/g, '');
          if (value !== '' && STRICT_NUM_RE.test(n)) parts.push('<Cell><Data ss:Type="Number">' + n + '</Data></Cell>');
          else parts.push('<Cell><Data ss:Type="String">' + xmlEscape(value) + '</Data></Cell>');
        });
        parts.push('</Row>');
      });
      parts.push('</Table></Worksheet>');
    });
    parts.push('</Workbook>');
    var blob = new Blob([parts.join('')], { type: 'application/vnd.ms-excel' });
    var url = URL.createObjectURL(blob);
    var a = document.createElement('a'); a.href = url; a.download = '$ReportBaseName.xls';
    document.body.appendChild(a); a.click(); document.body.removeChild(a);
    setTimeout(function () { URL.revokeObjectURL(url); }, 2000);
  });

  document.querySelectorAll('.data-table').forEach(function (table) {
    if (table.tHead && table.tBodies.length) controllers.push(new TableController(table));
  });
  if (databaseFilter) {
    databaseFilter.addEventListener('change', function () {
      refreshObjectFilteredTables();
    });
    if (databaseFilter.value) {
      databaseFilter.dispatchEvent(new Event('change'));
    }
  }
  updateFilterIndicator();
  window.addEventListener('beforeprint', function () { controllers.forEach(function (c) { c.printing = true; c.render(); }); });
  window.addEventListener('afterprint', function () { controllers.forEach(function (c) { c.printing = false; c.render(); }); });
})();
</script>
</body>
</html>
"@

$HtmlReport | Set-Content -LiteralPath $ReportFilePath -Encoding UTF8
Write-AssessmentLog -Severity INFO -Section 'HTML Report' -Message ("HTML report written to '{0}'." -f $ReportFilePath)

}
else {
    Write-AssessmentLog -Severity INFO -Section 'HTML Report' -Message 'HTML report skipped (OutputFormat=Excel).'
    $ReportFilePath = $null
}

#endregion

#region =============================================================================
# EXCEL EXPORT (ImportExcel module, no Microsoft Excel/COM required)
# Worksheets are grouped under top-level categories with prefixed sheet names.
# =================================================================================

$ExcelReportPath = $null

function ConvertTo-ExportObject {
    # Normalizes rows to plain PSCustomObjects: DataRows are reduced to their query
    # columns and DBNull values become $null, so Excel cells stay clean.
    param([AllowNull()][object[]]$Data)

    foreach ($row in @($Data)) {
        if ($null -eq $row) { continue }
        $item = [ordered]@{}
        if ($row -is [System.Data.DataRow]) {
            foreach ($column in $row.Table.Columns) {
                $value = $row[$column]
                $item[$column.ColumnName] = if ($value -is [System.DBNull]) { $null } else { $value }
            }
        }
        else {
            foreach ($property in $row.PSObject.Properties) {
                $item[$property.Name] = if ($property.Value -is [System.DBNull]) { $null } else { $property.Value }
            }
        }
        [PSCustomObject]$item
    }
}

function Get-SafeWorksheetName {
    # Excel worksheet names: max 31 chars, no : \ / ? * [ ] ', unique per workbook.
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$UsedNames
    )

    $clean = ($Name -replace "[:\\/\?\*\[\]']", ' ') -replace '\s+', ' '
    $clean = $clean.Trim()
    if (-not $clean) { $clean = 'Sheet' }
    if ($clean.Length -gt 31) { $clean = $clean.Substring(0, 31).Trim() }
    $candidate = $clean
    $suffix = 2
    while ($UsedNames.ContainsKey($candidate.ToLowerInvariant())) {
        $tail = "_$suffix"
        $candidate = $clean.Substring(0, [Math]::Min($clean.Length, 31 - $tail.Length)) + $tail
        $suffix++
    }
    $UsedNames[$candidate.ToLowerInvariant()] = $true
    return $candidate
}

function Set-ExcelChartColors {
    # Best effort: EPPlus 4 (bundled with ImportExcel) does not expose series/point
    # fill colors, so inject DrawingML solidFill nodes into the chart XML. A failure
    # only means the chart keeps the default palette.
    param(
        [Parameter(Mandatory)][object]$Chart,
        [string[]]$PointColors,
        [string]$SeriesColor
    )

    try {
        $chartXml = $Chart.ChartXml
        $nsChart = 'http://schemas.openxmlformats.org/drawingml/2006/chart'
        $nsDraw = 'http://schemas.openxmlformats.org/drawingml/2006/main'
        $nsm = New-Object System.Xml.XmlNamespaceManager($chartXml.NameTable)
        $nsm.AddNamespace('c', $nsChart)
        $nsm.AddNamespace('a', $nsDraw)
        $series = $chartXml.SelectSingleNode('//c:ser', $nsm)
        if ($null -eq $series) { return }

        if ($SeriesColor) {
            $spPr = $chartXml.CreateElement('c', 'spPr', $nsChart)
            $fill = $chartXml.CreateElement('a', 'solidFill', $nsDraw)
            $color = $chartXml.CreateElement('a', 'srgbClr', $nsDraw)
            $color.SetAttribute('val', $SeriesColor.TrimStart('#'))
            [void]$fill.AppendChild($color)
            [void]$spPr.AppendChild($fill)
            $anchor = $series.SelectSingleNode('c:tx', $nsm)
            if ($null -eq $anchor) { $anchor = $series.SelectSingleNode('c:order', $nsm) }
            if ($anchor) { [void]$series.InsertAfter($spPr, $anchor) } else { [void]$series.PrependChild($spPr) }
        }

        if ($PointColors) {
            $insertBefore = $series.SelectSingleNode('c:cat', $nsm)
            if ($null -eq $insertBefore) { $insertBefore = $series.SelectSingleNode('c:val', $nsm) }
            for ($pointIndex = 0; $pointIndex -lt $PointColors.Count; $pointIndex++) {
                $dPt = $chartXml.CreateElement('c', 'dPt', $nsChart)
                $idx = $chartXml.CreateElement('c', 'idx', $nsChart)
                $idx.SetAttribute('val', [string]$pointIndex)
                [void]$dPt.AppendChild($idx)
                $bubble = $chartXml.CreateElement('c', 'bubble3D', $nsChart)
                $bubble.SetAttribute('val', '0')
                [void]$dPt.AppendChild($bubble)
                $spPr = $chartXml.CreateElement('c', 'spPr', $nsChart)
                $fill = $chartXml.CreateElement('a', 'solidFill', $nsDraw)
                $color = $chartXml.CreateElement('a', 'srgbClr', $nsDraw)
                $color.SetAttribute('val', $PointColors[$pointIndex].TrimStart('#'))
                [void]$fill.AppendChild($color)
                [void]$dPt.AppendChild($spPr)
                if ($insertBefore) { [void]$series.InsertBefore($dPt, $insertBefore) } else { [void]$series.AppendChild($dPt) }
            }
        }
    }
    catch {
        Write-Verbose ("Chart color styling skipped: {0}" -f $_.Exception.Message)
    }
}

function Get-AssessmentExcelCategoryMap {
    # Ordered category -> section mapping for the Phase-1 initial assessment workbook.
    # Categories mirror the HTML sidebar groups with short sheet prefixes.
    @(
        [PSCustomObject]@{ Category = 'SQL Landscape'; Section = 'Server and Instance Inventory'; Sheet = 'SL-Inventory' }
        [PSCustomObject]@{ Category = 'SQL Landscape'; Section = 'SQL Services'; Sheet = 'SL-Services' }
        [PSCustomObject]@{ Category = 'SQL Landscape'; Section = 'Infrastructure Volumes'; Sheet = 'SL-Volumes' }
        [PSCustomObject]@{ Category = 'SQL Landscape'; Section = 'Database Landscape'; Sheet = 'SL-DB Landscape' }

        [PSCustomObject]@{ Category = 'SQL Instance'; Section = 'Instance Configuration'; Sheet = 'SI-Config' }
        [PSCustomObject]@{ Category = 'SQL Instance'; Section = 'Trace Flags'; Sheet = 'SI-Trace Flags' }
        [PSCustomObject]@{ Category = 'SQL Instance'; Section = 'Database Scoped Configurations'; Sheet = 'SI-DB Scoped Config' }
        [PSCustomObject]@{ Category = 'SQL Instance'; Section = 'Agent Jobs'; Sheet = 'SI-Agent Jobs' }
        [PSCustomObject]@{ Category = 'SQL Instance'; Section = 'Agent Job Failures'; Sheet = 'SI-Job Failures' }
        [PSCustomObject]@{ Category = 'SQL Instance'; Section = 'Alerts and Operators'; Sheet = 'SI-Alerts' }
        [PSCustomObject]@{ Category = 'SQL Instance'; Section = 'Database Mail Status'; Sheet = 'SI-DB Mail' }

        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Object Inventory'; Sheet = 'DB-Object Inventory' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Table Structure'; Sheet = 'DB-Table Structure' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Data Types Review'; Sheet = 'DB-Data Types' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Constraints Analysis'; Sheet = 'DB-Constraints' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'FK Index Coverage'; Sheet = 'DB-FK Indexes' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Column Nullability and Defaults'; Sheet = 'DB-Nullability' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Identity and Sequences'; Sheet = 'DB-Identity Seq' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Special Table Features'; Sheet = 'DB-Special Features' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Schema Design Risks'; Sheet = 'DB-Schema Risks' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Cross Database Dependencies'; Sheet = 'DB-Cross-DB Deps' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Naming Convention Review'; Sheet = 'DB-Naming' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Code Object Inventory'; Sheet = 'DB-Code Inventory' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Function Risk Analysis'; Sheet = 'DB-Function Risk' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Trigger Analysis'; Sheet = 'DB-Triggers' }
        [PSCustomObject]@{ Category = 'DB Design'; Section = 'Code Smells'; Sheet = 'DB-Code Smells' }

        [PSCustomObject]@{ Category = 'Storage'; Section = 'Filegroups and Files'; Sheet = 'ST-Filegroups' }
        [PSCustomObject]@{ Category = 'Storage'; Section = 'VLF Assessment'; Sheet = 'ST-VLF' }
        [PSCustomObject]@{ Category = 'Storage'; Section = 'Autogrowth Events'; Sheet = 'ST-Autogrowth' }
        [PSCustomObject]@{ Category = 'Storage'; Section = 'Compression Opportunities'; Sheet = 'ST-Compression' }
        [PSCustomObject]@{ Category = 'Storage'; Section = 'TempDB Health'; Sheet = 'ST-TempDB' }

        [PSCustomObject]@{ Category = 'Tables, Index, Objects'; Section = 'Index Inventory'; Sheet = 'IDX-Inventory' }
        [PSCustomObject]@{ Category = 'Tables, Index, Objects'; Section = 'Index Usage'; Sheet = 'IDX-Usage' }
        [PSCustomObject]@{ Category = 'Tables, Index, Objects'; Section = 'Hot Table Access'; Sheet = 'IDX-Hot Tables' }
        [PSCustomObject]@{ Category = 'Tables, Index, Objects'; Section = 'Tables With Many Indexes'; Sheet = 'IDX-Many Indexes' }
        [PSCustomObject]@{ Category = 'Tables, Index, Objects'; Section = 'Missing Index Indicators'; Sheet = 'IDX-Missing' }
        [PSCustomObject]@{ Category = 'Tables, Index, Objects'; Section = 'Duplicate Overlapping Indexes'; Sheet = 'IDX-Duplicates' }
        [PSCustomObject]@{ Category = 'Tables, Index, Objects'; Section = 'Index Fragmentation'; Sheet = 'IDX-Fragmentation' }
        [PSCustomObject]@{ Category = 'Tables, Index, Objects'; Section = 'Statistics Database Options'; Sheet = 'IDX-Stats Options' }
        [PSCustomObject]@{ Category = 'Tables, Index, Objects'; Section = 'Statistics Health'; Sheet = 'IDX-Stats Health' }

        [PSCustomObject]@{ Category = 'Performance'; Section = 'Wait Statistics'; Sheet = 'PERF-Wait Stats' }
        [PSCustomObject]@{ Category = 'Performance'; Section = 'Top Resource Consumers'; Sheet = 'PERF-Top Consumers' }
        [PSCustomObject]@{ Category = 'Performance'; Section = 'Implicit Conversion Candidates'; Sheet = 'PERF-Implicit Conv' }
        [PSCustomObject]@{ Category = 'Performance'; Section = 'Query Store Status'; Sheet = 'PERF-Query Store' }
        [PSCustomObject]@{ Category = 'Performance'; Section = 'Query Store Forced Plans'; Sheet = 'PERF-QS Forced' }
        [PSCustomObject]@{ Category = 'Performance'; Section = 'Blocking and Long Running'; Sheet = 'PERF-Blocking' }
        [PSCustomObject]@{ Category = 'Performance'; Section = 'CPU Memory Pressure'; Sheet = 'PERF-CPU Memory' }

        [PSCustomObject]@{ Category = 'Security'; Section = 'Server Security'; Sheet = 'SEC-Server Security' }
        [PSCustomObject]@{ Category = 'Security'; Section = 'Server Role Membership'; Sheet = 'SEC-Role Members' }
        [PSCustomObject]@{ Category = 'Security'; Section = 'Encryption and Surface Area'; Sheet = 'SEC-Encryption' }
        [PSCustomObject]@{ Category = 'Security'; Section = 'Database Principals'; Sheet = 'SEC-DB Principals' }
        [PSCustomObject]@{ Category = 'Security'; Section = 'Orphaned Users'; Sheet = 'SEC-Orphaned Users' }

        [PSCustomObject]@{ Category = 'Architecture / HA-DR'; Section = 'Availability Group Status'; Sheet = 'Arch-AG Status' }
        [PSCustomObject]@{ Category = 'Architecture / HA-DR'; Section = 'Replication CDC Change Tracking'; Sheet = 'Arch-CDC CT Repl' }
        [PSCustomObject]@{ Category = 'Architecture / HA-DR'; Section = 'Backup Status'; Sheet = 'Arch-Backup Status' }
        [PSCustomObject]@{ Category = 'Architecture / HA-DR'; Section = 'Linked Servers and Broker'; Sheet = 'Arch-Linked Broker' }

        [PSCustomObject]@{ Category = 'Capacity'; Section = 'Capacity Growth Trends'; Sheet = 'CAP-Growth Trends' }

        [PSCustomObject]@{ Category = 'Migration'; Section = 'Compatibility Levels'; Sheet = 'MIG-Compat Levels' }
        [PSCustomObject]@{ Category = 'Migration'; Section = 'Deprecated Features'; Sheet = 'MIG-Deprecated' }
    )
}

function Export-AssessmentExcel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExcelPath,
        [Parameter(Mandatory)][string]$ServerName,
        [Parameter(Mandatory)][datetime]$GeneratedAt,
        [Parameter(Mandatory)][int]$LookbackDays,
        [Parameter(Mandatory)][int]$HealthScore,
        [Parameter(Mandatory)][string]$HealthLabel,
        [Parameter(Mandatory)][string]$HealthClass,
        [Parameter(Mandatory)][int]$PopulatedSections,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Findings,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CategoryGroups,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CriticalFindings,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$WarningFindings,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$InfoFindings,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$CollectionErrors,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Sections,
        [AllowEmptyCollection()][object[]]$Disks,
        [AllowEmptyCollection()][object[]]$Waits,
        [string]$DatabaseScopeLabel = 'All user databases'
    )

    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue

    $skyBlue = [System.Drawing.ColorTranslator]::FromHtml('#87CEFA')
    $paleBlue = [System.Drawing.ColorTranslator]::FromHtml('#E6F4FD')
    $darkBlue = [System.Drawing.ColorTranslator]::FromHtml('#17243A')
    $criticalColor = [System.Drawing.ColorTranslator]::FromHtml('#B91C1C')
    $warningColor = [System.Drawing.ColorTranslator]::FromHtml('#B45309')
    $goodColor = [System.Drawing.ColorTranslator]::FromHtml('#15803D')
    $thinBorder = [OfficeOpenXml.Style.ExcelBorderStyle]::Thin
    $subtitle = "Server: $ServerName | Generated: $($GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss'))"

    $usedSheetNames = @{}
    [void](Get-SafeWorksheetName -Name 'Summary' -UsedNames $usedSheetNames)
    [void](Get-SafeWorksheetName -Name 'Contents' -UsedNames $usedSheetNames)
    [void](Get-SafeWorksheetName -Name 'ChartData' -UsedNames $usedSheetNames)

    $excel = $null
    $excel = Open-ExcelPackage -Path $ExcelPath -Create
    try {
        $summarySheet = Add-Worksheet -ExcelPackage $excel -WorksheetName 'Summary'

        $summarySheet.Cells['A1'].Value = 'SQL Server Initial Assessment'
        Set-ExcelRange -Worksheet $summarySheet -Range 'A1:E1' -Merge -Bold -FontSize 18 `
            -FontColor $darkBlue -BackgroundColor $skyBlue -HorizontalAlignment Left
        $summarySheet.Row(1).Height = 30

        $kpiRows = @(
            @('Server', [string]$ServerName),
            @('Generated', $GeneratedAt.ToString('yyyy-MM-dd HH:mm:ss')),
            @('Lookback (days)', $LookbackDays),
            @('Database scope', $DatabaseScopeLabel),
            @('Health Score', "$HealthScore / 100"),
            @('Health Status', $HealthLabel),
            @('Critical Findings', @($CriticalFindings).Count),
            @('Warnings', @($WarningFindings).Count),
            @('Info Notes', @($InfoFindings).Count),
            @('Collection Errors', @($CollectionErrors).Count),
            @('Assessment Sections', $PopulatedSections)
        )
        $rowIndex = 3
        foreach ($kpi in $kpiRows) {
            $summarySheet.Cells[$rowIndex, 1].Value = $kpi[0]
            $summarySheet.Cells[$rowIndex, 2].Value = $kpi[1]
            $rowIndex++
        }
        $kpiEndRow = $rowIndex - 1
        Set-ExcelRange -Worksheet $summarySheet -Range "A3:A$kpiEndRow" -Bold -FontColor $darkBlue -BackgroundColor $paleBlue
        $kpiRange = $summarySheet.Cells["A3:B$kpiEndRow"]
        foreach ($side in 'Top', 'Bottom', 'Left', 'Right') { $kpiRange.Style.Border.$side.Style = $thinBorder }
        $healthColor = switch ($HealthClass) { 'good' { $goodColor } 'warn' { $warningColor } default { $criticalColor } }
        Set-ExcelRange -Worksheet $summarySheet -Range 'B7:B8' -Bold -FontColor $healthColor
        if (@($CriticalFindings).Count -gt 0) { Set-ExcelRange -Worksheet $summarySheet -Range 'B9' -Bold -FontColor $criticalColor }
        if (@($WarningFindings).Count -gt 0) { Set-ExcelRange -Worksheet $summarySheet -Range 'B10' -Bold -FontColor $warningColor }
        if (@($CollectionErrors).Count -gt 0) { Set-ExcelRange -Worksheet $summarySheet -Range 'B12' -Bold -FontColor $criticalColor }
        $summarySheet.Column(1).Width = 22
        $summarySheet.Column(2).Width = 30

        $findingsTitleRow = $kpiEndRow + 2
        $summarySheet.Cells[$findingsTitleRow, 1].Value = 'All Findings (Critical, then Warning, then Info)'
        Set-ExcelRange -Worksheet $summarySheet -Range "A${findingsTitleRow}:E${findingsTitleRow}" -Merge -Bold `
            -FontSize 13 -FontColor $darkBlue -BackgroundColor $skyBlue
        $findingRows = @(ConvertTo-ExportObject -Data $Findings |
            Select-Object Severity, Category, Item, Detail, Recommendation)
        if ($findingRows.Count -gt 0) {
            $excel = $findingRows | Export-Excel -ExcelPackage $excel -WorksheetName 'Summary' `
                -StartRow ($findingsTitleRow + 1) -TableName 'Findings' -TableStyle 'Medium2' -PassThru
            $summarySheet.Column(3).Width = 34
            $summarySheet.Column(4).Width = 70
            $summarySheet.Column(4).Style.WrapText = $true
            $summarySheet.Column(5).Width = 55
            $summarySheet.Column(5).Style.WrapText = $true
            $findingsRange = $summarySheet.Cells[($findingsTitleRow + 1), 1, ($findingsTitleRow + 1 + $findingRows.Count), 5]
            foreach ($side in 'Top', 'Bottom', 'Left', 'Right') { $findingsRange.Style.Border.$side.Style = $thinBorder }
        }
        else {
            $summarySheet.Cells[($findingsTitleRow + 1), 1].Value = 'No findings were recorded.'
        }

        $contentsSheet = Add-Worksheet -ExcelPackage $excel -WorksheetName 'Contents'
        $contentsSheet.Cells[1, 1].Value = 'Workbook Contents by Category'
        Set-ExcelRange -Worksheet $contentsSheet -Range 'A1:D1' -Merge -Bold -FontSize 13 `
            -FontColor $darkBlue -BackgroundColor $skyBlue
        $contentsSheet.Cells[2, 1].Value = $subtitle
        Set-ExcelRange -Worksheet $contentsSheet -Range 'A2:D2' -Merge -FontColor $darkBlue
        $contentsRows = [System.Collections.Generic.List[object]]::new()
        $categoryMap = @(Get-AssessmentExcelCategoryMap)
        foreach ($entry in $categoryMap) {
            $sectionRows = @(ConvertTo-ExportObject -Data $Sections[$entry.Section])
            if ($sectionRows.Count -eq 0) { continue }
            $contentsRows.Add([PSCustomObject]@{
                    Category  = $entry.Category
                    Worksheet = $entry.Sheet
                    Section   = $entry.Section
                    RowCount  = $sectionRows.Count
                })
        }
        if (@($CollectionErrors).Count -gt 0) {
            $contentsRows.Add([PSCustomObject]@{
                    Category  = 'SQL Instance'
                    Worksheet = 'SI-Collection Errs'
                    Section   = 'Collection Errors'
                    RowCount  = @($CollectionErrors).Count
                })
        }
        if ($contentsRows.Count -gt 0) {
            $excel = @($contentsRows) | Export-Excel -ExcelPackage $excel -WorksheetName 'Contents' `
                -StartRow 3 -TableName 'tbl_Contents' -TableStyle 'Medium2' -PassThru
            $contentsSheet.View.FreezePanes(4, 1)
            $contentsSheet.Column(1).Width = 24
            $contentsSheet.Column(2).Width = 24
            $contentsSheet.Column(3).Width = 42
            $contentsSheet.Column(4).Width = 12
        }
        else {
            $contentsSheet.Cells[3, 1].Value = 'No evidence sections had data.'
        }

        $chartSheet = Add-Worksheet -ExcelPackage $excel -WorksheetName 'ChartData'
        $chartSheet.Cells['A1'].Value = 'Severity'
        $chartSheet.Cells['B1'].Value = 'Count'
        $chartSheet.Cells['A2'].Value = 'Critical'; $chartSheet.Cells['B2'].Value = @($CriticalFindings).Count
        $chartSheet.Cells['A3'].Value = 'Warning';  $chartSheet.Cells['B3'].Value = @($WarningFindings).Count
        $chartSheet.Cells['A4'].Value = 'Info';     $chartSheet.Cells['B4'].Value = @($InfoFindings).Count

        $chartSheet.Cells['D1'].Value = 'Category'
        $chartSheet.Cells['E1'].Value = 'Count'
        $categoryForChart = @($CategoryGroups | Select-Object -First 12 | Sort-Object -Property Count)
        $rowIndex = 2
        foreach ($group in $categoryForChart) {
            $chartSheet.Cells[$rowIndex, 4].Value = $group.Name
            $chartSheet.Cells[$rowIndex, 5].Value = $group.Count
            $rowIndex++
        }
        $categoryEndRow = $rowIndex - 1

        $diskForChart = @($Disks | Where-Object { (Test-HasValue $_.VolumeMountPoint) -and (Test-HasNumericValue $_.FreePct) })
        $chartSheet.Cells['G1'].Value = 'Volume'
        $chartSheet.Cells['H1'].Value = 'FreePct'
        $rowIndex = 2
        foreach ($disk in $diskForChart) {
            $chartSheet.Cells[$rowIndex, 7].Value = [string]$disk.VolumeMountPoint
            $chartSheet.Cells[$rowIndex, 8].Value = [double]$disk.FreePct
            $rowIndex++
        }
        $diskEndRow = $rowIndex - 1

        $waitsForChart = @($Waits | Where-Object { (Test-HasValue $_.WaitType) -and (Test-HasNumericValue $_.WaitPercent) } |
            Select-Object -First 10 | Sort-Object -Property { [double]$_.WaitPercent })
        $chartSheet.Cells['J1'].Value = 'WaitType'
        $chartSheet.Cells['K1'].Value = 'WaitPercent'
        $rowIndex = 2
        foreach ($wait in $waitsForChart) {
            $chartSheet.Cells[$rowIndex, 10].Value = [string]$wait.WaitType
            $chartSheet.Cells[$rowIndex, 11].Value = [double]$wait.WaitPercent
            $rowIndex++
        }
        $waitsEndRow = $rowIndex - 1
        Set-ExcelRange -Worksheet $chartSheet -Range 'A1:K1' -Bold -FontColor $darkBlue -BackgroundColor $paleBlue
        $chartSheet.Hidden = [OfficeOpenXml.eWorkSheetHidden]::Hidden

        if ((@($CriticalFindings).Count + @($WarningFindings).Count + @($InfoFindings).Count) -gt 0) {
            $severityChart = Add-ExcelChart -Worksheet $summarySheet -Title 'Findings by Severity' `
                -ChartType Doughnut -XRange 'ChartData!A2:A4' -YRange 'ChartData!B2:B4' `
                -Row 1 -Column 6 -Width 360 -Height 250 -LegendPosition Right -PassThru
            Set-ExcelChartColors -Chart $severityChart -PointColors @('B91C1C', 'B45309', '2563EB')
        }
        if ($categoryForChart.Count -gt 0) {
            $categoryChart = Add-ExcelChart -Worksheet $summarySheet -Title 'Critical + Warning Findings by Category' `
                -ChartType BarClustered -XRange "ChartData!D2:D$categoryEndRow" -YRange "ChartData!E2:E$categoryEndRow" `
                -Row 1 -Column 12 -Width 420 -Height 250 -NoLegend -PassThru
            Set-ExcelChartColors -Chart $categoryChart -SeriesColor '17243A'
        }
        if ($diskForChart.Count -gt 0) {
            $diskChart = Add-ExcelChart -Worksheet $summarySheet -Title 'Disk Free % by Volume (warning below 15%)' `
                -ChartType ColumnClustered -XRange "ChartData!G2:G$diskEndRow" -YRange "ChartData!H2:H$diskEndRow" `
                -Row 15 -Column 6 -Width 360 -Height 250 -NoLegend -PassThru
            Set-ExcelChartColors -Chart $diskChart -SeriesColor '2563EB'
        }
        if ($waitsForChart.Count -gt 0) {
            $waitChart = Add-ExcelChart -Worksheet $summarySheet -Title 'Top Wait Types (% of non-idle waits)' `
                -ChartType BarClustered -XRange "ChartData!J2:J$waitsEndRow" -YRange "ChartData!K2:K$waitsEndRow" `
                -Row 15 -Column 12 -Width 420 -Height 250 -NoLegend -PassThru
            Set-ExcelChartColors -Chart $waitChart -SeriesColor '0369A1'
        }

        foreach ($entry in $categoryMap) {
            $rows = @(ConvertTo-ExportObject -Data $Sections[$entry.Section])
            if ($rows.Count -eq 0) { continue }
            $sheetName = Get-SafeWorksheetName -Name $entry.Sheet -UsedNames $usedSheetNames
            $tableName = 'tbl_' + (($entry.Category + '_' + $entry.Section) -replace '\W', '_')
            if ($tableName.Length -gt 250) { $tableName = $tableName.Substring(0, 250) }
            $excel = $rows | Export-Excel -ExcelPackage $excel -WorksheetName $sheetName `
                -StartRow 3 -TableName $tableName -TableStyle 'Medium2' -PassThru
            $sectionSheet = $excel.Workbook.Worksheets[$sheetName]
            $sectionSheet.Cells[1, 1].Value = ('{0} - {1}' -f $entry.Category, $entry.Section)
            $lastColumn = $sectionSheet.Dimension.End.Column
            Set-ExcelRange -Worksheet $sectionSheet -Range ($sectionSheet.Cells[1, 1, 1, [Math]::Max($lastColumn, 4)].Address) `
                -Merge -Bold -FontSize 13 -FontColor $darkBlue -BackgroundColor $skyBlue
            $sectionSheet.Cells[2, 1].Value = $subtitle
            Set-ExcelRange -Worksheet $sectionSheet -Range ($sectionSheet.Cells[2, 1, 2, [Math]::Max($lastColumn, 4)].Address) `
                -Merge -FontColor $darkBlue
            $sectionSheet.View.FreezePanes(4, 1)
            $sectionSheet.Cells[$sectionSheet.Dimension.Address].AutoFitColumns(10, 55)
            for ($columnIndex = 1; $columnIndex -le $lastColumn; $columnIndex++) {
                $headerText = [string]$sectionSheet.Cells[3, $columnIndex].Value
                if ($sectionSheet.Column($columnIndex).Width -ge 54.5 -or
                    $headerText -match 'Detail|Query|Message|Recommendation|Text|Error|Definition|Command|Smell|Risk') {
                    $sectionSheet.Column($columnIndex).Style.WrapText = $true
                }
            }
            $dataRange = $sectionSheet.Cells[3, 1, $sectionSheet.Dimension.End.Row, $lastColumn]
            foreach ($side in 'Top', 'Bottom', 'Left', 'Right') { $dataRange.Style.Border.$side.Style = $thinBorder }
        }

        $errorRows = @(ConvertTo-ExportObject -Data @($CollectionErrors))
        if ($errorRows.Count -gt 0) {
            $errorSheetName = Get-SafeWorksheetName -Name 'SI-Collection Errs' -UsedNames $usedSheetNames
            $excel = $errorRows | Export-Excel -ExcelPackage $excel -WorksheetName $errorSheetName `
                -StartRow 3 -TableName 'tbl_Collection_Errors' -TableStyle 'Medium2' -PassThru
            $errorSheet = $excel.Workbook.Worksheets[$errorSheetName]
            $errorSheet.Cells[1, 1].Value = 'SQL Instance - Collection Errors'
            Set-ExcelRange -Worksheet $errorSheet -Range 'A1:B1' -Merge -Bold -FontSize 13 `
                -FontColor $darkBlue -BackgroundColor $skyBlue
            $errorSheet.Cells[2, 1].Value = $subtitle
            Set-ExcelRange -Worksheet $errorSheet -Range 'A2:B2' -Merge -FontColor $darkBlue
            $errorSheet.View.FreezePanes(4, 1)
            $errorSheet.Column(1).Width = 40
            $errorSheet.Column(2).Width = 90
            $errorSheet.Column(2).Style.WrapText = $true
        }

        Close-ExcelPackage $excel
        return $ExcelPath
    }
    catch {
        if ($excel) {
            try { Close-ExcelPackage $excel -NoSave } catch { Write-Verbose 'Excel package cleanup failed.' }
        }
        throw
    }
}

if ($WantExcel) {
    Write-Host 'Exporting Excel workbook...' -NoNewline
    if (-not (Get-Module -ListAvailable -Name ImportExcel)) {
        $installHint = 'Install-Module ImportExcel -Scope CurrentUser'
        if ($WantHtml) {
            Write-Host 'SKIPPED' -ForegroundColor Yellow
            Write-AssessmentLog -Severity WARN -Section 'Excel Export' `
                -Message ("Skipped: ImportExcel module not installed ($installHint). HTML report was still generated.")
            Write-Warning ("Excel export skipped: the ImportExcel module is not installed. Run: {0}. The HTML report was still generated." -f $installHint)
        }
        else {
            Write-Host 'FAILED' -ForegroundColor Red
            Write-AssessmentLog -Severity ERROR -Section 'Excel Export' `
                -Message ("Required for OutputFormat=Excel but ImportExcel is not installed. Run: $installHint")
            throw ("Excel output was requested (-OutputFormat Excel / -o Excel) but the ImportExcel module is not installed. Run: {0}" -f $installHint)
        }
    }
    else {
        try {
            Import-Module ImportExcel -ErrorAction Stop
            $excelPath = Join-Path $OutputPath ($ReportBaseName + '.xlsx')
            if (Test-Path -LiteralPath $excelPath) { Remove-Item -LiteralPath $excelPath -Force }

            $null = Export-AssessmentExcel `
                -ExcelPath $excelPath `
                -ServerName $ServerIP `
                -GeneratedAt $ReportTimestamp `
                -LookbackDays $DaysToAnalyze `
                -HealthScore $healthScore `
                -HealthLabel $healthStatus `
                -HealthClass $healthClass `
                -PopulatedSections $PopulatedSectionCount `
                -Findings $allFindings `
                -CategoryGroups $CategoryGroups `
                -CriticalFindings @($CriticalIssues) `
                -WarningFindings @($WarningIssues) `
                -InfoFindings @($InformationItems) `
                -CollectionErrors @($CollectionErrors) `
                -Sections $Sections `
                -Disks @($Volumes) `
                -Waits @($Sections['Wait Statistics']) `
                -DatabaseScopeLabel $DatabaseScopeLabel

            $ExcelReportPath = $excelPath
            Write-AssessmentLog -Severity INFO -Section 'Excel Export' -Message ("Excel workbook written to '{0}'." -f $excelPath)
            Write-Host 'DONE' -ForegroundColor Green
        }
        catch {
            Write-Host 'FAILED' -ForegroundColor Yellow
            if ($WantHtml) {
                Write-AssessmentLog -Severity ERROR -Section 'Excel Export' `
                    -Message 'Excel export failed; HTML report was still generated.' -ErrorRecord $_
                Write-Warning ("Excel export failed: {0} The HTML report was still generated." -f $_.Exception.Message)
            }
            else {
                Write-AssessmentLog -Severity ERROR -Section 'Excel Export' `
                    -Message 'Excel export failed (Excel-only run).' -ErrorRecord $_
                throw
            }
        }
    }
}

#endregion

#region =============================================================================
# COMPLETION
# =================================================================================

Write-Host ''
Write-Host '========================================' -ForegroundColor Cyan
Write-Host ' Assessment complete' -ForegroundColor Cyan
Write-Host (" Format       : {0}" -f $ResolvedOutputFormat)
Write-Host (" Critical     : {0}" -f $criticalCount)
Write-Host (" Warning      : {0}" -f $warningCount)
Write-Host (" Info         : {0}" -f $infoCount)
Write-Host (" Errors       : {0}" -f $errorCount)
if ($ReportFilePath) { Write-Host (" Report       : {0}" -f $ReportFilePath) }
if ($ExcelReportPath) { Write-Host (" Excel        : {0}" -f $ExcelReportPath) }
Write-Host (" Log          : {0}" -f $LogFilePath)
Write-Host (" Health       : {0}/100 ({1})" -f $healthScore, $healthStatus)
Write-Host '========================================' -ForegroundColor Cyan

Write-AssessmentLog -Severity INFO -Section 'Completion' -Message (
    "Finished. Format={0}; HealthScore={1} ({2}); Critical={3}; Warning={4}; Info={5}; CollectionErrors={6}; HTML='{7}'; Excel='{8}'." -f `
        $ResolvedOutputFormat, $healthScore, $healthStatus, $criticalCount, $warningCount, $infoCount, $errorCount,
        $(if ($ReportFilePath) { $ReportFilePath } else { 'not generated' }),
        $(if ($ExcelReportPath) { $ExcelReportPath } else { 'not exported' })
)

if ($OpenReport) {
    if ($ReportFilePath -and (Test-Path -LiteralPath $ReportFilePath)) {
        Invoke-Item -LiteralPath $ReportFilePath
    }
    elseif ($ExcelReportPath -and (Test-Path -LiteralPath $ExcelReportPath)) {
        Invoke-Item -LiteralPath $ExcelReportPath
    }
}

Close-AssessmentSqlConnection -Connection $SqlServer

[PSCustomObject]@{
    Server            = $ServerIP
    OutputFormat      = $ResolvedOutputFormat
    ReportPath        = $ReportFilePath
    ExcelReportPath   = $ExcelReportPath
    LogFilePath       = $LogFilePath
    HealthScore       = $healthScore
    HealthStatus      = $healthStatus
    CriticalIssues    = $criticalCount
    WarningIssues     = $warningCount
    InformationItems  = $infoCount
    CollectionErrors  = $errorCount
    DatabasesAssessed = @($UserDatabaseNames)
    DatabaseCount     = $UserDatabaseNames.Count
}

#endregion
