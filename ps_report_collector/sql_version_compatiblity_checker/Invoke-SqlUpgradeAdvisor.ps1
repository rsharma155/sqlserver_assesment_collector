<#
.SYNOPSIS
    SQL Upgrade Advisor - SQL Server version compatibility & modernization assessment.

.DESCRIPTION
    Connects to a source SQL Server instance (2016 or earlier, or any supported version),
    inventories every database object (tables, views, procedures, functions, triggers, CLR,
    synonyms, sequences, legacy defaults/rules, linked servers, Agent jobs, PolyBase, Full-Text,
    replication, log shipping, mirroring, configuration), runs a versioned rules engine derived
    from Microsoft's official "Deprecated / Discontinued / Breaking changes" documentation, and
    produces an HTML + Excel (+ JSON) report that answers, per object, from static metadata
    and regular-expression scans (not a T-SQL parser, and not a workload replay):

        1. Is there a known static reason it would fail on the target (2022 / 2025)?
        2. What is deprecated there and should be modernized?
        3. What behavior / plan changes should be expected?
        4. What is the evidence (matched line + snippet) and recommended fix?
        5. What could NOT be assessed (encrypted modules, dynamic SQL, non-TSQL job steps)?

    "No static findings" means the regex and metadata rules did not match. It does not mean
    the object was compiled on the target or proven compatible at runtime.

    The report includes line-level evidence, blast radius (fan-in), runtime hotness
    (plan cache), runtime deprecated-feature counters, explicit blind spots, and a remediation
    backlog with risk scores. All rules are data-driven (see -RulesPath to extend/override).

    Zero dependencies: pure ADO.NET + built-in .NET classes. Runs on PowerShell 5.1 and 7+.

.PARAMETER ServerInstance
    Source SQL Server instance to assess (e.g. 'SRV01' or 'SRV01\INST2,1433').

.PARAMETER Credential
    SQL authentication credential. Omit to use Windows integrated authentication.
    Example: -Credential (Get-Credential)

.PARAMETER TargetVersion
    Migration target: 2022 (compat 160) or 2025 (compat 170).

.PARAMETER TargetCompatibilityLevel
    Target compatibility level override (e.g. 150). 0 = default for target version.

.PARAMETER Databases
    Optional list of database names to assess (wildcards allowed). Default: all online user databases.

.PARAMETER OutputPath
    Output folder. Default: .\Assessment_<server>_<timestamp>

.PARAMETER Format
    HTML, Excel, JSON, SARIF, Both (HTML + Excel), or All (default).
    Both does not write JSON or SARIF. Pass -AlsoExport JSON and/or SARIF to add those
    after the same collection pass. All still writes every format.

.PARAMETER DefinitionsMode
    Full loads module text for the regex rules. HashOnly inventories objects and reports
    whether a definition exists, but does not copy module source into the assessment.

.PARAMETER IncludeSystemDatabases
    Also assess master. tempdb, model and msdb stay excluded.

.PARAMETER ExportAllFindings
    Write every finding to Excel, JSON and SARIF. By default those exports follow
    -MaxFindingsInReport, highest risk first.

.PARAMETER WriteDefaultRules
    Write rules\default-rules.json from the built-in rule set and exit. The advisor
    loads that file on later runs when it is present.

.PARAMETER RulesPath
    Optional JSON file with custom/override rules (array of rule objects, matched by rule id).

.PARAMETER SqlPath
    Folder holding the read-only T-SQL collectors. Default: the 'sql' folder next to this script.
    Queries live in collect_instance.sql and collect_database.sql, one "-- section: <name>"
    block each, so a DBA can review every statement before the assessment runs.
    CreateAdvisorUser.sql is the login setup script and is never executed by the advisor.

.PARAMETER IncludeDefinitions
    Include full module source text in the JSON export.

.PARAMETER MaxFindingsInReport
    Max rows in the HTML findings table (Excel/JSON always contain everything). 0 = unlimited.

.PARAMETER Encrypt
    Use TLS encryption for the SQL connection. Default is $true.
    Pass -Encrypt:$false only for a lab instance that has no certificate.

.PARAMETER TrustServerCertificate
    Accept any SQL Server certificate without validation. Default is off.
    Turn this on only when the instance uses a self-signed certificate you already trust.

.PARAMETER QueryTimeoutSec
    Command timeout for collection queries (default 300s).

.PARAMETER DemoMode
    Run without a server, using a built-in synthetic SQL 2016 inventory. Useful to preview
    the report format and to test the rules engine.

.PARAMETER OpenReport
    Open the generated HTML report in the default browser.

.PARAMETER PassThru
    Return the full assessment object to the pipeline.

.EXAMPLE
    .\Invoke-SqlUpgradeAdvisor.ps1 -ServerInstance SRV01 -TargetVersion 2022

.EXAMPLE
    .\Invoke-SqlUpgradeAdvisor.ps1 -ServerInstance SRV01 -Credential (Get-Credential) -TargetVersion 2025 -Format All

.EXAMPLE
    .\Invoke-SqlUpgradeAdvisor.ps1 -DemoMode -TargetVersion 2025 -OpenReport

.EXAMPLE
    # First run only: create a least-privilege login for the assessment (review sql\CreateAdvisorUser.sql first)
    Invoke-Sqlcmd -ServerInstance SRV01 -InputFile .\sql\CreateAdvisorUser.sql

.NOTES
    Rules verified against Microsoft Learn documentation on 2026-09-29:
      - Deprecated Database Engine features in SQL Server 2016 / 2017 / 2019 / 2022 / 2025
      - Discontinued Database Engine functionality in SQL Server
      - Breaking changes to Database Engine features in SQL Server 2025
      - Server Configuration: clr strict security
    Static analysis only - always validate in a test environment before upgrading.
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$ServerInstance,
    [pscredential]$Credential,
    [ValidateSet('2022','2025')][string]$TargetVersion = '2022',
    [int]$TargetCompatibilityLevel = 0,
    [string[]]$Databases,
    [string]$OutputPath,
    [ValidateSet('HTML','Excel','JSON','SARIF','All','Both')][string]$Format = 'All',
    [ValidateSet('JSON','SARIF')][string[]]$AlsoExport,
    [ValidateSet('Full','HashOnly')][string]$DefinitionsMode = 'Full',
    [switch]$IncludeSystemDatabases,
    [switch]$ExportAllFindings,
    [switch]$WriteDefaultRules,
    [string]$RulesPath,
    [string]$SqlPath,
    [switch]$IncludeDefinitions,
    [int]$MaxFindingsInReport = 5000,
    [bool]$Encrypt = $true,
    [switch]$TrustServerCertificate,
    [int]$QueryTimeoutSec = 300,
    [switch]$DemoMode,
    [switch]$OpenReport,
    [switch]$PassThru
)

Set-Variable -Name AdvToolVersion -Value '0.1.0' -Option ReadOnly -Scope Script -Force -ErrorAction SilentlyContinue
# This engine reads optional properties that are absent on some inventory rows.
# A caller with Set-StrictMode enabled must not change that behavior.
Set-StrictMode -Off
$script:AdvCoverage = [System.Collections.Generic.List[object]]::new()
$script:AdvStartTime = Get-Date

# --------------------------------------------------------------------------------
# READ-ONLY T-SQL COLLECTORS
# Every statement the tool runs against the source instance lives in
#   sql\collect_instance.sql
#   sql\collect_database.sql
# (override the folder with -SqlPath). Each query is a "-- section: <name>" block so a DBA
# reviews one file per scope instead of dozens of tiny scripts. The advisor never writes
# these files and never executes CreateAdvisorUser.sql.
# --------------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($SqlPath)) {
    $advScriptDir = ''
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $advScriptDir = $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { $advScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
    if ([string]::IsNullOrWhiteSpace($advScriptDir)) { $advScriptDir = (Get-Location).Path }
    $SqlPath = Join-Path -Path $advScriptDir -ChildPath 'sql'
}
$script:AdvSqlPath    = $SqlPath
$script:AdvSqlCatalog = $null

$script:AdvSqlScripts = @(
    'inst_instance_properties', 'inst_config_options', 'inst_databases', 'owner_permissions',
    'inst_linked_servers', 'inst_mirroring', 'inst_availability_groups', 'inst_availability_groups_cluster',
    'inst_has_distribution_db', 'inst_repl_distributor', 'inst_log_shipping',
    'inst_agent_jobs', 'inst_agent_notifications', 'inst_trace_status', 'inst_deprecated_counters',
    'db_query_store_state', 'db_objects', 'db_ddl_triggers', 'db_clr_modules', 'db_columns',
    'db_indexes', 'db_synonyms', 'db_assemblies', 'db_crypto', 'db_external_sources',
    'db_external_tables', 'db_fulltext', 'db_dependencies', 'db_procedure_stats', 'db_trigger_stats',
    'db_objects_hash', 'db_sku_features', 'db_feature_surface', 'db_query_store_baseline',
    'inst_endpoints', 'inst_server_triggers', 'inst_trusted_assemblies',
    'inst_credentials', 'inst_agent_proxies', 'inst_linked_logins'
)

# --------------------------------------------------------------------------------
# Documentation URLs (verified 2026-09-29)
# --------------------------------------------------------------------------------
$script:Doc = @{
    Dep2016 = 'https://learn.microsoft.com/en-us/sql/previous-versions/sql/database-engine/deprecated-database-engine-features-in-sql-server-2016'
    Dep2017 = 'https://learn.microsoft.com/en-us/sql/database-engine/deprecated-database-engine-features-in-sql-server-2017'
    Dep2019 = 'https://learn.microsoft.com/en-us/sql/database-engine/deprecated-database-engine-features-in-sql-server-2019'
    Dep2022 = 'https://learn.microsoft.com/en-us/sql/database-engine/deprecated-database-engine-features-in-sql-server-2022'
    Dep2025 = 'https://learn.microsoft.com/en-us/sql/database-engine/deprecated-database-engine-features-in-sql-server-2025'
    Disc    = 'https://learn.microsoft.com/en-us/sql/database-engine/discontinued-database-engine-functionality-in-sql-server'
    Brk2025 = 'https://learn.microsoft.com/en-us/sql/database-engine/breaking-changes-to-database-engine-features-in-sql-server-2025'
    Whats25 = 'https://learn.microsoft.com/en-us/sql/sql-server/what-s-new-in-sql-server-2025'
    Whats22 = 'https://learn.microsoft.com/en-us/sql/sql-server/what-s-new-in-sql-server-2022'
    Clr     = 'https://learn.microsoft.com/en-us/sql/database-engine/configure-windows/clr-strict-security'
    Ft      = 'https://learn.microsoft.com/en-us/sql/relational-databases/search/full-text-index-version-upgrade'
    Compat  = 'https://learn.microsoft.com/en-us/sql/t-sql/statements/alter-database-transact-sql-compatibility-level'
    Qs      = 'https://learn.microsoft.com/en-us/sql/relational-databases/performance/query-store-usage-scenarios'
    Xevent  = 'https://learn.microsoft.com/en-us/sql/relational-databases/extended-events/extended-events'
}

# --------------------------------------------------------------------------------
# Small utilities
# --------------------------------------------------------------------------------
function Write-AdvLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('HH:mm:ss')
    $color = switch ($Level) {
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        'OK'    { 'Green' }
        default { 'Gray' }
    }
    Write-Host "[$ts] $Message" -ForegroundColor $color
}

function Add-AdvCoverage {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    $script:AdvCoverage.Add([pscustomobject]@{ Step = $Name; Status = $(if ($Ok) { 'Collected' } else { 'Failed / skipped' }); Detail = $Detail })
}

function Truncate-Adv {
    param([string]$Text, [int]$Max = 260)
    if ($null -eq $Text) { return '' }
    $t = $Text -replace '\s+', ' '
    if ($t.Length -le $Max) { return $t }
    return ($t.Substring(0, $Max) + '...')
}

function ConvertTo-HtmlEnc {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $s = $Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'
    return ($s -replace '"', '&quot;')
}

function ConvertFrom-DataTable {
    param([System.Data.DataTable]$Table)
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($row in $Table.Rows) {
        $h = [ordered]@{}
        foreach ($col in $Table.Columns) {
            $v = $row[$col]
            if ($v -is [System.DBNull]) { $v = $null }
            $h[$col.ColumnName] = $v
        }
        $list.Add([pscustomobject]$h)
    }
    return , $list
}

function Get-SafeFileName {
    param([string]$Name)
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $out = $Name
    foreach ($c in $invalid) { $out = $out.Replace([string]$c, '_') }
    return $out
}

# --------------------------------------------------------------------------------
# SQL helpers (pure ADO.NET - no modules required)
# --------------------------------------------------------------------------------
function New-AdvConnection {
    param([string]$Instance, [pscredential]$Cred, [bool]$UseEncrypt, [bool]$TrustCert = $false, [string]$Database = 'master')
    $b = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $b['Data Source']       = $Instance
    $b['Initial Catalog']   = $Database
    $b['Connect Timeout']   = 15
    $b['ApplicationName']   = 'SQL Upgrade Advisor'
    $b['Encrypt']           = [bool]$UseEncrypt
    $b['TrustServerCertificate'] = [bool]$TrustCert
    if ($Cred) {
        $b['Integrated Security'] = $false
        $b['User ID']   = $Cred.UserName
        $b['Password']  = [System.Net.NetworkCredential]::new('', $Cred.Password).Password
    } else {
        $b['Integrated Security'] = $true
    }
    $conn = [System.Data.SqlClient.SqlConnection]::new($b.ConnectionString)
    $conn.Open()
    return $conn
}

function Invoke-AdvQuery {
    param($Connection, [string]$Query, [int]$Timeout = 300)
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText  = $Query
    $cmd.CommandTimeout = $Timeout
    $da = [System.Data.SqlClient.SqlDataAdapter]::new($cmd)
    $dt = [System.Data.DataTable]::new()
    [void]$da.Fill($dt)
    $cmd.Dispose()
    return , $dt
}

function Invoke-AdvScalar {
    param($Connection, [string]$Query, [int]$Timeout = 60)
    $cmd = $Connection.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = $Timeout
    try {
        $v = $cmd.ExecuteScalar()
        if ($v -is [System.DBNull]) { return $null }
        return $v
    } finally { $cmd.Dispose() }
}

# --------------------------------------------------------------------------------
# Read-only .sql script loader
#   Get-AdvSql  -Name 'inst_databases'            -> text of sql\inst_databases.sql
#                -Name 'owner_permissions' -Sub @{'{owner}'='dbo'}  -> with substitution
# Scripts are read once and cached; they are never written or regenerated at run time.
# --------------------------------------------------------------------------------
function Hide-AdvSecret {
    # Redact credential-shaped text before it is stored in evidence or exports.
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text
    $t = [regex]::Replace($t, '(?i)(password\s*=\s*)(''[^'']*''|"[^"]*"|\S+)', '$1***')
    $t = [regex]::Replace($t, '(?i)(pwd\s*=\s*)(''[^'']*''|"[^"]*"|\S+)', '$1***')
    $t = [regex]::Replace($t, '(?i)(\b(?:-p|/p)\s+)(\S+)', '$1***')
    return $t
}

function Initialize-AdvSqlCatalog {
    # Split collect_instance.sql and collect_database.sql on "-- section: <name>" lines.
    # Each section is one statement batch. The catalog is built once per run.
    if ($script:AdvSqlCatalog) { return }
    $script:AdvSqlCatalog = @{}
    $script:AdvSqlSources = @('collect_instance.sql', 'collect_database.sql')
    foreach ($fileName in $script:AdvSqlSources) {
        $file = Join-Path -Path $script:AdvSqlPath -ChildPath $fileName
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        $text = [System.IO.File]::ReadAllText($file, [System.Text.UTF8Encoding]::new($false))
        $parts = [regex]::Split($text, '(?m)^-- section:\s*')
        for ($i = 1; $i -lt $parts.Length; $i++) {
            $chunk = $parts[$i]
            $nl = $chunk.IndexOf("`n")
            if ($nl -lt 0) { continue }
            $name = $chunk.Substring(0, $nl).Trim()
            if ($name -notmatch '^[A-Za-z0-9_]+$') { continue }
            $script:AdvSqlCatalog[$name] = $chunk.Substring($nl + 1).Trim()
        }
    }
}

function Get-AdvSql {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [hashtable]$Sub
    )
    if ($Name -notmatch '^[A-Za-z0-9_]+$') { throw "Invalid SQL script name: $Name" }
    Initialize-AdvSqlCatalog
    if (-not $script:AdvSqlCatalog.ContainsKey($Name)) {
        throw ("SQL section not found: {0}`r`nExpected folder: {1}`r" +
               "Collection queries are '-- section:' blocks inside collect_instance.sql and collect_database.sql.") -f $Name, $script:AdvSqlPath
    }
    $sql = $script:AdvSqlCatalog[$Name]
    if ($Sub) {
        foreach ($k in $Sub.Keys) { $sql = $sql.Replace([string]$k, [string]$Sub[$k]) }
    }
    return $sql
}

function Test-AdvSqlScripts {
    # Fail fast before touching the server: every section the run needs must be present
    # and must not start with a writing statement.
    param([string[]]$Names)
    Initialize-AdvSqlCatalog
    $missing = [System.Collections.Generic.List[string]]::new()
    $badName = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $Names) {
        if (-not $script:AdvSqlCatalog.ContainsKey($n)) { $missing.Add($n); continue }
        $firstBad = ''
        foreach ($line in ($script:AdvSqlCatalog[$n] -split "`r?`n")) {
            $t = $line.Trim()
            if ($t.Length -eq 0) { continue }
            if ($t.StartsWith('--')) { continue }
            if ($t -match '(?i)^\s*(insert|update|delete|merge|drop|alter|truncate|create|exec|execute|grant|revoke|dbcc\s+trace(on|off))\b') { $firstBad = $t; break }
        }
        if ($firstBad) { $badName.Add(('{0}: {1}' -f $n, $firstBad)) }
    }
    return [pscustomobject]@{
        Folder   = $script:AdvSqlPath
        Missing  = @($missing)
        ReadOnly = @($badName)
        Ok       = (@($missing).Count -eq 0 -and @($badName).Count -eq 0)
    }
}

# --------------------------------------------------------------------------------
# T-SQL noise removal (comment / string-literal stripper)
# Produces text of EXACTLY the same length as the input, so that match indexes
# map 1:1 onto original line numbers. Newlines are preserved.
# --------------------------------------------------------------------------------
function Hide-SqlNoise {
    param([string]$Text, [bool]$KeepStrings)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $pattern = if ($KeepStrings) {
        '(?s)/\*.*?\*/|--[^\r\n]*'
    } else {
        "(?s)/\*.*?\*/|--[^\r\n]*|'(?:[^']|'')*'"
    }
    $evaluator = [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $sb = [System.Text.StringBuilder]::new($m.Length)
        foreach ($ch in $m.Value.ToCharArray()) {
            if ($ch -eq "`n") { [void]$sb.Append($ch) } else { [void]$sb.Append(' ') }
        }
        $sb.ToString()
    }
    return [System.Text.RegularExpressions.Regex]::Replace($Text, $pattern, $evaluator)
}

function New-LineIndex {
    # Returns sorted int[] of newline positions for binary-search line lookup.
    param([string]$Text)
    $list = New-Object System.Collections.Generic.List[int]
    $pos = $Text.IndexOf("`n")
    while ($pos -ge 0) { $list.Add($pos); $pos = $Text.IndexOf("`n", $pos + 1) }
    return , $list.ToArray()
}

function Get-LineFromIndex {
    param([int[]]$NewLines, [int]$Index)
    if ($null -eq $NewLines -or $NewLines.Length -eq 0) { return 1 }
    $r = [Array]::BinarySearch($NewLines, $Index)
    if ($r -ge 0) { return ($r + 2) }   # index lands exactly on a newline -> next line
    return ((-1 - $r) + 1)              # number of newlines before index, +1
}

# --------------------------------------------------------------------------------
# Finding factory
# --------------------------------------------------------------------------------
function New-AdvFinding {
    param(
        $Rule,
        [string]$Database, [string]$Schema = '', [string]$Object = '',
        [string]$ObjType = '', [string]$ObjTypeDesc = '',
        [int]$Line = 0,
        [string]$Evidence = '',
        [string]$Confidence,
        [int]$TotalMatches = 1
    )
    if (-not $Confidence) { $Confidence = $Rule.Confidence }
    return [pscustomobject]@{
        RuleId         = $Rule.Id
        Title          = $Rule.Title
        Category       = $Rule.Category
        Severity       = $Rule.Severity
        Scope          = $Rule.Scope
        Database       = $Database
        Schema         = $Schema
        Object         = $Object
        ObjType        = $ObjType
        ObjTypeDesc    = $ObjTypeDesc
        Key            = ('{0}|{1}|{2}|{3}' -f $Database, $Schema, $Object, $ObjType)
        Line           = $Line
        Evidence       = $Evidence
        Recommendation = $Rule.Recommendation
        Confidence     = $Confidence
        Deterministic  = [bool]$Rule.Deterministic
        DocUrl         = $Rule.Doc
        Effort         = $Rule.Effort
        TotalMatches   = $TotalMatches
        BlastRadius    = 0
        Hotness        = [long]0
        Status         = ''
        Risk           = 0
    }
}

# --------------------------------------------------------------------------------
# THE KNOWLEDGE BASE
# Every rule is data, not code: severity / category / evidence / fix / doc / effort.
#   MinTarget/MaxTarget: applicable target major (16 = 2022, 17 = 2025; 0..99 = always)
#   Scope:  Module | TriggerResult | Table | Database | Assembly | Synonym |
#           LinkedServer | Instance | Object
#   Scan:   Code       = comments + string literals blanked
#           NoComments = comments blanked, string literals kept (for literals like 'md5')
#   Pattern is a .NET regex matched against the whole module text in one pass.
# --------------------------------------------------------------------------------
function Get-DefaultRules {
    $D = $script:Doc
    $rules = [System.Collections.Generic.List[object]]::new()

    $add = { param($Id,$Title,$Category,$Severity,$Scope,$MinTarget,$MaxTarget,$Pattern,$Scan,
                    $Confidence,$Deterministic,$Recommendation,$Doc,$Effort,
                    $AppliesTo,$Once,$LineExclusion,
                    $Description)
        $rules.Add([pscustomobject]@{
            Id=$Id; Title=$Title; Category=$Category; Severity=$Severity; Scope=$Scope
            MinTarget=$MinTarget; MaxTarget=$MaxTarget
            Pattern=$(if ($Pattern) { $Pattern } else { '' })
            Scan=$(if ($Scan) { $Scan } else { 'Code' })
            Confidence=$Confidence; Deterministic=$Deterministic
            Recommendation=$Recommendation; Doc=$Doc; Effort=$Effort
            AppliesTo=$(if ($AppliesTo) { $AppliesTo } else { @('ANY') })
            Once=[bool]$Once
            LineExclusion=$(if ($LineExclusion) { $LineExclusion } else { '' })
            Description=$(if ($Description) { $Description } else { $Title })
            TargetRange = ('{0}..{1}' -f $(if ($MinTarget -le 0) { '*' } else { Get-AdvProductLabel -Major $MinTarget }), $(if ($MaxTarget -ge 99) { 'latest' } else { Get-AdvProductLabel -Major $MaxTarget }))
        })
    }

    # ---- deprecated data types (text/ntext/image in module code) ------------------
    & $add 'DEPR-TYPE-001' 'Legacy LOB data types in code (text/ntext/image)' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)(?:\bcast\s*\(\s*[^()]*?\s+as\s+(?:n?text|image)\b|\bconvert\s*\(\s*(?:n?text|image)\s*,|\bdeclare\s+@\w+\s+(?:n?text|image)\b|@\w+\s+(?:n?text|image)\b|\b(?:n?text|image)\s+collate\b)' `
        'Code' 'High' $true 'Replace text/ntext/image with varchar(max)/nvarchar(max)/varbinary(max); update casts, declares and parameters accordingly.' $D.Dep2016 'M' @('ANY') $false '' `
        'Deprecated since SQL Server 2016; still works on 2022/2025 but blocks modern features (JSON, some string functions, in-memory, columnstore on those columns).'
    & $add 'DEPR-TYPE-002' 'Legacy LOB data types in inline DDL (CREATE TABLE #temp ...)' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)(?<=[\w\]\[])\s+(?:n?text|image)\b\s*(?:,|\))' `
        'Code' 'Medium' $true 'Use varchar(max)/nvarchar(max)/varbinary(max) in temporary and dynamic DDL.' $D.Dep2016 'M' @('ANY') $false `
        '(?i)^\s*(?:select|insert|update|delete|values|merge|print|raiserror|set)\b|@\w+\s+(?:n?text|image)\b' `
        'Legacy type declarations inside CREATE TABLE / ALTER TABLE statements.'
    # ---- deprecated system stored procedures -------------------------------------
    & $add 'DEPR-SEC-001' 'Deprecated security / ownership stored procedures' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)\b(?:sp_addlogin|sp_droplogin|sp_grantlogin|sp_revokelogin|sp_denylogin|sp_adduser|sp_dropuser|sp_grantdbaccess|sp_revokedbaccess|sp_addrole|sp_droprole|sp_addapprole|sp_dropapprole|sp_approlepassword|sp_password|sp_change_users_login|sp_changedbowner|sp_changeobjectowner|sp_defaultdb|sp_defaultlanguage|sp_srvrolepermission|sp_dbfixedrolepermission|xp_grantlogin|xp_revokelogin|xp_loginconfig|sp_addextendedproc|sp_dropextendedproc|sp_helpextendedproc|setuser)\b' `
        'NoComments' 'High' $true 'Replace with CREATE/ALTER/DROP LOGIN, USER and ROLE, ALTER AUTHORIZATION and EXECUTE AS. Legacy procedures do not reflect the post-2008 permissions model.' $D.Dep2016 'M' @('ANY') $false '' `
        'Legacy security procedures: deprecated, behave incorrectly against the modern permissions hierarchy.'
    & $add 'DEPR-META-001' 'Deprecated metadata / database-management stored procedures' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)\b(?:sp_depends|sp_lock|sp_indexoption|sp_helpdevice|sp_addumpdevice|sp_resetstatus|sp_attach_db|sp_attach_single_file_db|sp_dbremove|sp_renamedb|sp_dbcmptlevel|sp_getbindtoken|sp_bindsession|sp_addtype|sp_droptype|sp_bindefault|sp_unbindefault|sp_bindrule|sp_unbindrule|sp_db_increased_partitions|sp_estimated_rowsize_reduction_for_vardecimal|sp_db_vardecimal_storage_format|sp_certify_removable|sp_create_removable|sp_changeobjectowner|sp_helpreplicationoption|sp_dbcmptlevel)\b' `
        'Code' 'High' $true 'Replace with the documented modern equivalent (ALTER INDEX, sys.dm_tran_locks, sys.dm_sql_referencing_entities, CREATE/DROP TYPE, ALTER DATABASE ... MODIFY NAME, etc.).' $D.Dep2016 'M' @('ANY') $false '' `
        'Deprecated system procedures still callable but scheduled for removal.'
    & $add 'DEPR-META-002' 'Deprecated metadata / security built-in functions' 'Deprecated' 'Low' 'Module' 16 99 `
        '(?i)\b(?:user_id|file_id|indexkey_property|permissions|fn_get_sql|fn_virtualservernodes|fn_servershareddrives)\s*\(' `
        'Code' 'High' $true 'Use DATABASE_PRINCIPAL_ID(), FILE_IDEX()/sys.index_columns, sys.fn_my_permissions, sys.dm_exec_sql_text and the corresponding DMVs.' $D.Dep2016 'S' @('ANY') $false '' `
        'Deprecated built-in functions.'
    & $add 'DEPR-SYS-001' 'Legacy system compatibility views (sysobjects, syscomments, ...)' 'Deprecated' 'Low' 'Module' 16 99 `
        '(?i)\b(?:sysobjects|syscolumns|syscomments|sysindexes|sysusers|sysdepends|sysconstraints|sysdatabases|sysdevices|sysfilegroups|sysfiles|sysforeignkeys|sysfulltextcatalogs|sysindexkeys|syslockinfo|syslogins|sysmembers|sysmessages|sysoledbusers|sysopentapes|sysperfinfo|syspermissions|sysprocesses|sysprotects|sysreferences|sysremotelogins|sysservers|systypes|sysaltfiles|syscacheobjects|sysconfigures|syscurconfigs|syssegments|sysintegergroups|sysrowsets|sysextendedprocedures)\b' `
        'Code' 'High' $true 'Migrate to sys catalog views (sys.tables, sys.columns, sys.sql_modules, ...). Compatibility views do not expose metadata for post-2005 features.' $D.Dep2016 'M' @('ANY') $false '' `
        'SQL Server 2000-era compatibility views: deprecated, incomplete metadata.'
    & $add 'DEPR-TRACE-001' 'SQL Trace / legacy dependency catalog objects' 'Deprecated' 'Low' 'Module' 16 99 `
        '(?i)\b(?:sp_trace_create|sp_trace_setevent|sp_trace_setfilter|sp_trace_setstatus|fn_trace_geteventinfo|fn_trace_getfilterinfo|fn_trace_getinfo|fn_trace_gettable)\b|\b(?:sys\.traces|sys\.trace_events|sys\.trace_event_bindings|sys\.trace_categories|sys\.trace_columns|sys\.trace_subclass_values|sys\.sql_dependencies)\b' `
        'Code' 'High' $true 'Replace SQL Trace with Extended Events; replace sys.sql_dependencies with sys.sql_expression_dependencies.' $D.Dep2016 'M' @('ANY') $false '' `
        'SQL Trace APIs and sys.sql_dependencies are deprecated in favour of Extended Events.'
    & $add 'DEPR-REMOTE-001' 'Remote-server (pre-linked-server) constructs' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)\b(?:sp_addremotelogin|sp_dropremotelogin|sp_helpremotelogin|sp_remoteoption|sp_addserver)\b|@@remserver\b|\bset\s+remote_proc_transactions\b' `
        'NoComments' 'High' $true 'Replace remote servers with linked servers.' $D.Dep2016 'M' @('ANY') $false '' `
        'Remote server APIs deprecated in favour of linked servers.'
    # ---- deprecated T-SQL constructs ---------------------------------------------
    & $add 'DEPR-DBCC-001' 'Deprecated DBCC commands' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)\bdbcc\s+(?:dbreindex|indexdefrag|showcontig|pintable|unpintable)\b' `
        'Code' 'High' $true 'DBCC DBREINDEX -> ALTER INDEX ... REBUILD; DBCC INDEXDEFRAG -> ALTER INDEX ... REORGANIZE; DBCC SHOWCONTIG -> sys.dm_db_index_physical_stats; PINTABLE has no effect.' $D.Dep2016 'M' @('ANY') $false '' `
        'Deprecated DBCC commands with documented modern replacements.'
    & $add 'DEPR-ROWCOUNT-001' 'SET ROWCOUNT used to limit DML' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)\bset\s+rowcount\b' `
        'Code' 'High' $true 'Use the TOP keyword on the individual INSERT/UPDATE/DELETE statement instead of SET ROWCOUNT.' $D.Dep2016 'S' @('ANY') $false '' `
        'SET ROWCOUNT for INSERT/UPDATE/DELETE is deprecated (feature id 109).'
    & $add 'DEPR-SET-001' 'Deprecated SET options (ANSI_NULLS OFF, OFFSETS, FMTONLY ...)' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)\bset\s+(?:ansi_nulls\s+off|ansi_padding\s+off|concat_null_yields_null\s+off|offsets\b|fmtonly\s+(?:on|off))' `
        'Code' 'High' $true 'ANSI_NULLS/ANSI_PADDING/CONCAT_NULL_YIELDS_NULL are permanently ON in a future version; SET OFFSETS will be unavailable; use sp_describe_first_result_set instead of SET FMTONLY.' $D.Dep2016 'M' @('ANY') $false '' `
        'Deprecated SET options documented in the 2016/2017 deprecation list.'
    & $add 'DEPR-QUAL-001' 'Legacy :: function-call syntax' 'Deprecated' 'Low' 'Module' 16 99 `
        '(?i)\:\:\s*(?:dbo\.)?\w+\s*\(' `
        'Code' 'High' $true "Replace `"`::fn_name()`" with `"`SELECT ... FROM sys.fn_name()`"." $D.Dep2016 'S' @('ANY') $false '' `
        'The :: function-calling sequence is deprecated.'
    & $add 'DEPR-GRPBY-001' 'GROUP BY ALL' 'Deprecated' 'Low' 'Module' 16 99 `
        '(?i)\bgroup\s+by\s+all\b' `
        'Code' 'High' $true 'Rewrite using explicit GROUP BY values, UNION/derived tables.' $D.Dep2016 'S' @('ANY') $false '' `
        'GROUP BY ALL is deprecated with no direct replacement.'
    & $add 'DEPR-HINT-001' 'Deprecated table-hint syntax (no WITH keyword / hint without parentheses)' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)\b(?:from|join|update|into)\s+(?:\[?\w+\]?\s*\.\s*)?\[?\w+\]?(?:\s+(?:as\s+)?(?!with\b)\[?\w+\]?)?\s*\(\s*(?:nolock|readcommitted|repeatableread|serializable|paglock|rowlock|xlock|updlock|tablock|tablockx)\b|\bwith\s+(?:holdlock|serializable|rowlock|tablockx|tablock|xlock|updlock|paglock|readcommitted|repeatableread|nolock|readuncommitted)\b' `
        'Code' 'High' $true 'Use the current syntax: FROM t WITH (HOLDLOCK, NOLOCK). Hints applied without WITH or without parentheses are deprecated.' $D.Dep2016 'S' @('ANY') $false '' `
        'Table hints specified without the WITH keyword or without parentheses.'
    & $add 'DEPR-HINT-002' 'NOLOCK/READUNCOMMITTED inside UPDATE ... FROM / DELETE ... FROM' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)\b(?:update|delete)\b[^;]{0,700}?\bfrom\b[^;]{0,700}?\b(?:nolock|readuncommitted)\b' `
        'Code' 'Medium' $true 'Remove NOLOCK/READUNCOMMITTED from the FROM clause of UPDATE/DELETE statements (documented deprecation, feature id 1).' $D.Dep2016 'M' @('ANY') $false '' `
        'NOLOCK or READUNCOMMITTED in the FROM clause of an UPDATE or DELETE statement.'
    & $add 'DEPR-ALIAS-001' "String-literal column alias ('alias' = expression)" 'Deprecated' 'Low' 'Module' 16 99 `
        "(?i)\x27[^\x27\r\n]{1,60}\x27\s*=\s*(?:[a-z_@\(\[]|\d)" `
        'NoComments' 'Medium' $true 'Use expression AS [alias] syntax instead of a quoted string on the left of =.' $D.Dep2016 'S' @('ANY') $false '' `
        "A quoted string used as a column alias for an expression ('x' = expr) is deprecated."
    & $add 'DEPR-DMLNAME-001' 'ROWGUIDCOL / IDENTITYCOL referenced as a column name in DML' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)\b(?:select|update)\b[^;]{0,400}?\b(?:rowguidcol|identitycol)\b|\binsert\s+into\b[^;]{0,300}?\b(?:rowguidcol|identitycol)\b' `
        'Code' 'Medium' $true 'Use $rowguid / $identity pseudo-columns instead of naming ROWGUIDCOL/IDENTITYCOL columns directly in DML.' $D.Dep2016 'S' @('ANY') $false '' `
        'ROWGUIDCOL/IDENTITYCOL used as column names in DML statements.'
    & $add 'DEPR-DROPIDX-001' 'DROP INDEX using table_name.index_name syntax' 'Deprecated' 'Low' 'Module' 16 99 `
        '(?i)\bdrop\s+index\s+\[?\w+\]?\s*\.\s*\[?\w+\]?\b' `
        'Code' 'High' $true 'Use DROP INDEX index_name ON table_name.' $D.Dep2016 'S' @('ANY') $false '' `
        'DROP INDEX with two-part table.index name is deprecated.'
    & $add 'DEPR-TXTPT-001' 'Text-pointer operations (WRITETEXT/UPDATETEXT/READTEXT/TEXTPTR/TEXTVALID)' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)\b(?:writetext|updatetext|readtext)\b|\b(?:textptr|textvalid)\s*\(' `
        'Code' 'High' $true 'These only exist for text/ntext/image columns - convert the columns to (n)varchar(max)/varbinary(max) and use normal UPDATE/INSERT.' $D.Dep2016 'M' @('ANY') $false '' `
        'Text-pointer APIs tied to deprecated text/ntext/image columns.'
    & $add 'DEPR-XML-001' 'FOR XML ... XMLDATA (inline XDR schema)' 'Deprecated' 'Low' 'Module' 16 99 `
        '(?i)\bfor\s+xml\b[^;]{0,500}?\bxmldata\b' `
        'Code' 'High' $true 'Use XSD generation (remove XMLDATA) for RAW/AUTO modes.' $D.Dep2016 'S' @('ANY') $false '' `
        'The XMLDATA directive to FOR XML is deprecated.'
    & $add 'DEPR-NUMPROC-001' 'Numbered procedures (CREATE PROCEDURE name;2)' 'Deprecated' 'Low' 'Module' 16 99 `
        '(?i)\bcreate\s+(?:proc|procedure)\s+[^\s;]+;\s*\d+' `
        'Code' 'High' $true 'Numbered procedures are deprecated - do not use; split into separate procedures.' $D.Dep2016 'S' @('ANY') $false '' `
        'Numbered procedures (ProcNums) are deprecated with no replacement.'
    & $add 'DEPR-BKP-001' 'BACKUP/RESTORE to tape or with PASSWORD' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)\b(?:backup|restore)\b[^;]{0,600}?\b(?:to\s+tape\b|password\s*=)' `
        'Code' 'High' $true 'Backup to DISK/URL instead of TO TAPE; RESTORE ... WITH PASSWORD / MEDIAPASSWORD is deprecated (BACKUP with password is discontinued).' $D.Dep2016 'M' @('P','JOB') $false '' `
        'Backup/restore to tape and with password options are deprecated/discontinued.'
    & $add 'DEPR-HASH-001' 'Weak hash algorithm in HASHBYTES (MD2/MD4/MD5/SHA/SHA1)' 'Deprecated' 'Medium' 'Module' 16 99 `
        "(?i)\bhashbytes\s*\(\s*\x27(?:md2|md4|md5|sha|sha1)\x27" `
        'NoComments' 'High' $true 'Use SHA2_256 or SHA2_512. Older algorithms raise a deprecation event and are cryptographically broken.' $D.Dep2016 'S' @('ANY') $false '' `
        'MD2/MD4/MD5/SHA/SHA1 in HASHBYTES are deprecated.'
    & $add 'DEPR-ENC-001' 'Deprecated encryption algorithms (RC4/RC4_128/DESX)' 'Deprecated' 'Medium' 'Module' 16 99 `
        "(?i)\x27\s*(?:rc4|rc4_128|desx)\s*\x27" `
        'NoComments' 'High' $true 'Use AES (ENCRYPTBYKEY with a certificate/Asymmetric key or AES-based symmetric keys).' $D.Dep2016 'M' @('ANY') $false '' `
        'RC4/RC4_128/DESX encryption algorithms are deprecated (decryption still supported).'
    & $add 'DEPR-SOAP-001' 'Native XML Web Service endpoints (FOR SOAP)' 'Deprecated' 'Medium' 'Module' 16 99 `
        '(?i)\bcreate\s+endpoint\b[^;]{0,500}?\bfor\s+soap\b' `
        'Code' 'High' $true 'Replace SOAP endpoints with WCF/ASP.NET services.' $D.Dep2016 'L' @('ANY') $false '' `
        'CREATE ENDPOINT ... FOR SOAP / sys.soap_endpoints are deprecated.'
    & $add 'DEPR-GRANTALL-001' 'GRANT/DENY/REVOKE ALL' 'Deprecated' 'Low' 'Module' 16 99 `
        '(?i)\b(?:grant|deny|revoke)\s+all\b' `
        'Code' 'Medium' $true 'Grant/deny/revoke specific permissions instead of ALL - new permissions are silently included/excluded by ALL.' $D.Dep2016 'S' @('ANY') $false '' `
        'GRANT/DENY/REVOKE ALL is deprecated.'
    & $add 'DEPR-CFG-001' 'Deprecated sp_configure options' 'Deprecated' 'Medium' 'Module' 16 99 `
        "(?i)\bsp_configure\b[^;]{0,150}?\x27(?:allow updates|locks|open objects|set working set size|priority boost|remote proc trans|c2 audit mode|default trace enabled)\x27" `
        'NoComments' 'High' $true 'Remove no-effect legacy options; replace c2 audit mode / default trace with Extended Events + common criteria option.' $D.Dep2016 'M' @('P','JOB') $false '' `
        'Legacy sp_configure options that are deprecated or have no effect.'
    & $add 'DEPR-TRG-001' 'Trigger returns a result set' 'Deprecated' 'Medium' 'TriggerResult' 16 99 `
        '(?i)\bselect\b' `
        'Code' 'Medium' $false 'Remove result-set-returning SELECT statements from triggers - returning result sets from triggers is deprecated with no replacement (use tables/temp tables + OUTPUT).' $D.Dep2016 'S' @('TR') $false '' `
        'Heuristic detector: SELECT statements in triggers that are not assignments, EXISTS/expressions or INSERT...SELECT.'
    # ---- blind spots & security & modernization -----------------------------------
    & $add 'BLIND-DYN-001' 'Dynamic SQL detected (not statically verifiable)' 'BlindSpot' 'Info' 'Module' 0 99 `
        '(?i)\bexec(?:ute)?\s*(?:\(|@|sys\.sp_executesql\b|sp_executesql\b)' `
        'Code' 'High' $true 'Review dynamically generated text manually (or enable the deprecated-features Extended Events session to capture runtime usage).' $D.Xevent 'M' @('ANY') $true '' `
        'Dynamic SQL hides code from static analysis - flagged explicitly instead of silently passing.'
    & $add 'BLIND-ENC-001' 'Encrypted module definition unavailable' 'BlindSpot' 'Info' 'Module' 0 99 `
        '' 'Code' 'High' $false 'Obtain the definition from source control or decrypt with the original owner; encrypted modules cannot be assessed.' $D.Dep2016 'S' @('ANY') $false '' `
        'WITH ENCRYPTION modules cannot be parsed - reported as not assessable.'
    & $add 'SEC-XPCMD-001' 'xp_cmdshell usage' 'SecurityRisk' 'High' 'Module' 0 99 `
        '(?i)\bxp_cmdshell\b' `
        'Code' 'High' $true 'Remove xp_cmdshell where possible; replace with External Tools / PowerShell / CLR / xp_cmdshell-free patterns; if kept, restrict via proxy accounts.' $D.Whats22 'M' @('ANY') $false '' `
        'xp_cmdshell is a privilege-escalation surface; keep disabled on the target.'
    & $add 'SEC-OLE-001' 'OLE Automation (sp_OA*) usage' 'SecurityRisk' 'Medium' 'Module' 0 99 `
        '(?i)\bsp_oa(?:create|destroy|geterror|geterrorstring|method|setproperty|getproperty|stoperror)\b' `
        'Code' 'High' $true 'Replace OLE Automation with CLR, External Tools, or modern scripting (PowerShell); enable only if still required.' $D.Whats22 'M' @('ANY') $false '' `
        'OLE Automation procedures are a legacy automation surface.'
    & $add 'SEC-ADHOC-001' 'Ad-hoc distributed query (OPENROWSET/OPENDATASOURCE)' 'SecurityRisk' 'Low' 'Module' 0 99 `
        '(?i)\b(?:openrowset|opendatasource)\s*\(' `
        'Code' 'Medium' $true 'Prefer linked servers or external tools; ensure Ad Hoc Distributed Queries stays disabled unless required.' $D.Whats22 'S' @('ANY') $false '' `
        'Ad-hoc distributed queries often rely on deprecated/legacy providers.'
    & $add 'MOD-CURSOR-001' 'Cursor usage (modernization candidate)' 'Modernization' 'Low' 'Module' 0 99 `
        '(?i)\bdeclare\s+@\w+\s+(?:(?:fast_forward|static|dynamic|keyset|scroll)\s+)?cursor\b' `
        'Code' 'High' $true 'Consider set-based alternatives - cursors usually regress badly under newer cardinality-estimation models.' $D.Compat 'S' @('ANY') $false '' `
        'Set-based rewrite opportunity.'
    & $add 'MOD-NOLOCK-001' 'NOLOCK / READUNCOMMITTED hints (modernization)' 'Modernization' 'Low' 'Module' 0 99 `
        '(?i)\b(?:nolock|readuncommitted)\b' `
        'Code' 'High' $true 'Consider READ_COMMITTED_SNAPSHOT (RCSI) and remove NOLOCK: dirty/non-repeatable reads disappear and hint-driven plans become stable across compatibility levels.' $D.Compat 'M' @('ANY') $false '' `
        'NOLOCK is a frequent source of plan instability and dirty reads.'
    & $add 'MOD-SELSTAR-001' 'SELECT * usage (schema-change fragility)' 'Modernization' 'Low' 'Module' 0 99 `
        '(?i)\bselect\s+\*\s+from\b' `
        'Code' 'Medium' $true 'Name columns explicitly - SELECT * breaks result sets when the target schema evolves and defeats columnstore/covering indexes.' $D.Compat 'S' @('ANY') $false '' `
        'SELECT * makes schema changes risky during/after migration.'
    # ---- structural & instance rules ---------------------------------------------
    & $add 'DB-CMPT-001' 'Database compatibility level below target' 'BehaviorChange' 'Medium' 'Database' 16 99 `
        '' 'Code' 'High' $true 'Raise the compatibility level in stages on the target, with Query Store baseline before/after each step; CE model and IQP features change with compatibility level.' $D.Compat 'M' @() $false '' `
        'Engine version and compatibility level are separate: staying on 130 on a 2022 engine changes nothing until the level moves - and when it moves, plans can change.'
    & $add 'DB-CMPT-002' 'Very old compatibility level (<=120) is deprecated' 'Deprecated' 'Medium' 'Database' 16 99 `
        '' 'Code' 'High' $true 'Plan an upgrade path to a supported compatibility level; levels 100 (and 110/120) are documented as deprecated.' $D.Dep2016 'M' @() $false '' `
        'Compatibility levels 100/110/120 are deprecated per Microsoft documentation.'
    & $add 'DB-OPT-001' 'Deprecated database options (ANSI_NULLS OFF / CONCAT_NULL_YIELDS_NULL OFF / ANSI_PADDING OFF)' 'Deprecated' 'Medium' 'Database' 16 99 `
        '' 'Code' 'High' $true 'Set the option back to ON and validate dependent code - these are permanently ON in a future version of SQL Server.' $D.Dep2016 'M' @() $false '' `
        'Database-level ANSI options set OFF are deprecated (they will always be ON).'
    & $add 'DB-QS-001' 'Query Store is OFF (no upgrade baseline)' 'Informational' 'Info' 'Database' 0 99 `
        '' 'Code' 'High' $true 'Enable Query Store (READ_WRITE) on the source now to capture a plan/runtime baseline; compare it after the compatibility-level change.' $D.Qs 'S' @() $false '' `
        'Microsoft-recommended way to detect plan regressions caused by a version/compat upgrade.'
    & $add 'DB-TRUST-001' 'TRUSTWORTHY database enabled' 'SecurityRisk' 'Low' 'Database' 0 99 `
        '' 'Code' 'High' $true 'Prefer signed assemblies + explicit permissions over TRUSTWORTHY; restrict TRUSTWORTHY to databases that require it.' $D.Clr 'S' @() $false '' `
        'TRUSTWORTHY widens the privilege-escalation surface and is the legacy workaround for CLR trust.'
    & $add 'DB-STRETCH-001' 'Stretch Database enabled (discontinued)' 'Blocker' 'High' 'Database' 16 99 `
        '' 'Code' 'High' $true 'Stretch Database was discontinued in all supported SQL Server versions (July 2024). Disable remote data archive and choose an alternative archive design before upgrading.' $D.Disc 'L' @() $false '' `
        'Stretch Database is discontinued - the feature will not be available on the target.'
    & $add 'DB-FT-001' 'Full-Text index present (SQL Server 2025 word-breaker/filter removal)' 'BreakingChange' 'High' 'Database' 17 99 `
        '' 'Code' 'High' $true 'After upgrading to SQL Server 2025, rebuild/recreate Full-Text indexes so they use version 2 components - queries and populations on legacy indexes fail immediately after upgrade.' $D.Brk2025 'M' @() $false '' `
        'SQL 2025 removes legacy word-breaker/filter binaries; existing (version 1) Full-Text indexes fail until rebuilt.'
    & $add 'DB-PB-001' 'PolyBase external data source using Hadoop / wasb / abfs (unsupported on 2022+)' 'Blocker' 'Critical' 'Database' 16 99 `
        '' 'Code' 'High' $true 'Recreate the external data source with the new connectors (wasb[s] -> abs, abfs[s] -> adls). TYPE = HADOOP external sources are unsupported in SQL Server 2022 and later.' $D.Disc 'L' @() $false '' `
        'Hadoop (HDFS) external data sources are no longer supported in SQL Server 2022+; external tables using them must be recreated.'
    & $add 'DB-MIRROR-001' 'Database Mirroring configured (deprecated)' 'Deprecated' 'Medium' 'Database' 16 99 `
        '' 'Code' 'High' $true 'Move to Always On availability groups (or log shipping when the edition does not support AGs).' $D.Dep2016 'L' @() $false '' `
        'Database mirroring is deprecated in favour of Always On availability groups.'
    & $add 'TBL-LOBCOL-001' 'Table columns with deprecated LOB types (text/ntext/image)' 'Deprecated' 'Medium' 'Table' 16 99 `
        '' 'Code' 'High' $true 'Migrate columns to varchar(max)/nvarchar(max)/varbinary(max): requires ALTER COLUMN plus data movement (SSMA/DMA can script it) and application driver review.' $D.Dep2016 'L' @() $false '' `
        'text/ntext/image are deprecated; conversion is a schema+data change, not a flag change.'
    & $add 'TBL-TSCOL-001' 'Columns declared with the timestamp (rowversion) synonym' 'Deprecated' 'Low' 'Table' 16 99 `
        '' 'Code' 'High' $true 'Rename the type to rowversion (identical semantics) for clarity and future compatibility.' $D.Dep2016 'S' @() $false '' `
        'The timestamp syntax for rowversion is deprecated.'
    & $add 'OBJ-DEFRULE-001' 'Legacy CREATE DEFAULT / CREATE RULE objects' 'Deprecated' 'Medium' 'Object' 16 99 `
        '' 'Code' 'High' $true 'Replace old-style defaults/rules with DEFAULT constraints and CHECK constraints, then drop the legacy objects.' $D.Dep2016 'M' @() $false '' `
        'CREATE/DROP DEFAULT, sp_bindefault, CREATE/DROP RULE, sp_bindrule are deprecated.'
    & $add 'SYN-CROSS-001' 'Synonym targets a cross-database or linked-server object' 'Informational' 'Info' 'Synonym' 0 99 `
        '' 'Code' 'Medium' $true 'Confirm the remote database/server also exists on the target side; four-part names are a common silent break during migration.' $D.Dep2016 'S' @() $false '' `
        'Cross-part references move scope outside the database being migrated.'
    & $add 'CLR-001' 'CLR assembly may fail to load (CLR strict security, default since 2017)' 'BreakingChange' 'High' 'Assembly' 14 99 `
        '' 'Code' 'High' $true 'Sign every assembly with a certificate/asymmetric key whose login has UNSAFE ASSEMBLY in master, or register it with sys.sp_add_trusted_assembly. Unsigned assemblies fail to load on the target.' $D.Clr 'M' @() $false '' `
        'clr strict security = 1 (default on 2017+) makes the engine treat all assemblies as UNSAFE; unsigned assemblies fail to load.'
    & $add 'CLR-002' 'CLR assembly with EXTERNAL_ACCESS / UNSAFE permission' 'SecurityRisk' 'Medium' 'Assembly' 14 99 `
        '' 'Code' 'High' $true 'Re-validate permissions: with clr strict security enabled PERMISSION_SET is ignored at run time - all assemblies need trust, and UNSAFE code needs explicit approval.' $D.Clr 'M' @() $false '' `
        'Permission set metadata is preserved but ignored at runtime when strict security is on.'
    & $add 'LS-SQLOLEDB-001' 'Linked server uses the deprecated SQLOLEDB provider' 'Deprecated' 'High' 'LinkedServer' 16 99 `
        '' 'Code' 'High' $true 'Migrate the linked server to Microsoft OLE DB Driver (MSOLEDBSQL) or ODBC (MSODBCSQL); SQLOLEDB is deprecated and not recommended.' $D.Dep2016 'M' @() $false '' `
        'Specifying SQLOLEDB for linked servers is deprecated.'
    & $add 'LS-SNAC-001' 'Linked server uses the removed SQL Server Native Client (SQLNCLI) provider' 'BreakingChange' 'Medium' 'LinkedServer' 16 99 `
        '' 'Code' 'High' $true 'SQLNCLI/SQLNCLI11 (SNAC) is no longer shipped with SQL Server 2022+ or SSMS 19+ - move the provider to MSOLEDBSQL/MSODBCSQL before or during the upgrade.' $D.Whats22 'M' @() $false '' `
        'SNAC was removed from SQL Server 2022 and later.'
    & $add 'LS-ENC-001' 'Linked server may break on SQL Server 2025 (OLE DB 19 encryption defaults)' 'BreakingChange' 'Medium' 'LinkedServer' 17 99 `
        '' 'Code' 'Medium' $true 'Test every linked server after upgrade: MSOLEDBSQL19 secure defaults (TrustServerCertificate=False) break existing configurations unless a valid certificate is configured or the Encrypt parameter is set explicitly.' $D.Brk2025 'M' @() $false '' `
        'SQL Server 2025 introduces encryption changes that break existing linked-server configurations.'
    & $add 'REP-001' 'Replication topology (remote distributor) affected by SQL Server 2025 encryption changes' 'BreakingChange' 'High' 'Instance' 17 99 `
        '' 'Code' 'Medium' $true 'Before upgrading: configure a trusted certificate on publisher/distributor (recommended) or set trust_distributor_certificate=yes. Without it, publication changes and Replication Monitor fail after upgrade.' $D.Brk2025 'M' @() $false '' `
        'Remote-distributor replication fails after upgrade without a trusted certificate.'
    & $add 'LSH-001' 'Log shipping with a remote monitor affected by SQL Server 2025 encryption changes' 'BreakingChange' 'Medium' 'Instance' 17 99 `
        '' 'Code' 'Medium' $true 'Ensure the monitor uses trusted certificates before upgrading any node to SQL Server 2025.' $D.Brk2025 'M' @() $false '' `
        'Remote log shipping monitoring can break after upgrade to SQL Server 2025.'
    & $add 'DQS-001' 'Data Quality Services present - DISCONTINUED in SQL Server 2025' 'Blocker' 'Critical' 'Instance' 17 99 `
        '' 'Code' 'High' $true 'Remove DQS before upgrading (upgrade fails if DQS is installed) and migrate DQS knowledge to an external service; DQS remains supported only on 2022 and earlier.' $D.Whats25 'L' @() $false '' `
        'DQS is removed in SQL Server 2025; the documented upgrade path fails while DQS is installed.'
    & $add 'DQS-002' 'Data Quality Services deprecated (removed in 2025)' 'Deprecated' 'Medium' 'Instance' 16 16 `
        '' 'Code' 'High' $true 'DQS has been deprecated since SQL Server 2016 and is removed in 2025 - plan the replacement now while upgrading to 2022.' $D.Dep2016 'L' @() $false '' `
        'DQS is on the deprecated list since 2016.'
    & $add 'MDS-001' 'Master Data Services present - DISCONTINUED in SQL Server 2025' 'Blocker' 'Critical' 'Instance' 17 99 `
        '' 'Code' 'Medium' $true 'MDS is removed in SQL Server 2025 - migrate MDS models to another MDM solution or Azure before targeting 2025.' $D.Whats25 'L' @() $false '' `
        'MDS is removed in SQL Server 2025.'
    & $add 'MDS-002' 'Master Data Services deprecated (removed in 2025)' 'Deprecated' 'Medium' 'Instance' 16 16 `
        '' 'Code' 'Medium' $true 'MDS has been deprecated since SQL Server 2016 and is removed in 2025 - plan the replacement while upgrading to 2022.' $D.Dep2016 'L' @() $false '' `
        'MDS is on the deprecated list since 2016.'
    & $add 'MLS-001' 'Machine Learning Services external scripts enabled (packages/runtimes changed)' 'Deprecated' 'Medium' 'Instance' 16 99 `
        '' 'Code' 'High' $true 'SQL Server 2022 setup no longer installs R/Python runtimes or the microsoftml/olapR/sqlrutils/MicrosoftML packages - reinstall required custom runtimes/packages after upgrade and re-test sp_execute_external_script.' $D.Disc 'M' @() $false '' `
        'ML Services packages are no longer included with SQL Server 2022 installation; Machine Learning Server itself is deprecated in 2022.'
    & $add 'POOL-001' 'Lightweight pooling (fiber mode) enabled - deprecated in SQL Server 2025' 'Deprecated' 'Medium' 'Instance' 17 99 `
        '' 'Code' 'High' $true 'Disable lightweight pooling before moving to SQL Server 2025 - it is deprecated and planned for removal.' $D.Dep2025 'S' @() $false '' `
        'Lightweight pooling / fiber mode is deprecated in SQL Server 2025.'
    & $add 'TF-001' 'Startup/active trace flags detected' 'Informational' 'Info' 'Instance' 0 99 `
        '' 'Code' 'Medium' $true 'Verify each trace flag is still required and supported on the target version - flags silently lose meaning across releases.' $D.Whats22 'S' @() $false '' `
        'Trace flags are version-specific configuration that upgrades carry over blindly.'
    & $add 'RUNTIME-DEPR-001' 'Deprecated feature observed at RUNTIME on this instance' 'Deprecated' 'Medium' 'Instance' 16 99 `
        '' 'Code' 'High' $true 'The deprecated-features counter shows real usage (often inside dynamic SQL that static analysis cannot see) - track down the caller and remediate it.' $D.Xevent 'M' @() $false '' `
        'Runtime evidence from sys.dm_os_performance_counters (Deprecated Features object).'
    & $add 'JOB-BLIND-001' 'Non-T-SQL Agent job steps not analyzed (SSIS/CmdExec/PowerShell)' 'BlindSpot' 'Info' 'Instance' 0 99 `
        '' 'Code' 'High' $true 'Review SSIS packages, CmdExec and PowerShell steps separately - they may embed connection strings, drivers (SNAC/SQLOLEDB) and legacy SQL.' $D.Whats22 'M' @() $false '' `
        'Only T-SQL job steps can be parsed by this tool.'
    & $add 'JOB-NOTIF-001' 'SQL Agent net send / pager notifications (deprecated)' 'Deprecated' 'Low' 'Instance' 16 99 `
        '' 'Code' 'High' $true 'Replace net send / pager notifications with e-mail notifications.' $D.Dep2016 'S' @() $false '' `
        'net send and pager notifications are deprecated.'
    & $add 'INST-DQSDB-001' 'Database name suggests DQS/MDS content' 'Informational' 'Info' 'Instance' 0 99 `
        '' 'Code' 'Low' $true 'Confirm whether this database belongs to Data Quality Services or Master Data Services (both are removed in SQL Server 2025).' $D.Whats25 'S' @() $false '' `
        'Name-based heuristic - verify manually.'
    & $add 'DB-SKU-001' 'Persisted edition-sensitive feature in use' 'Informational' 'Medium' 'Database' 0 99 `
        '' 'Code' 'High' $true 'Confirm the target edition supports every feature listed in sys.dm_db_persisted_sku_features before restore or migration. These features survive upgrade and can block a lower edition.' $D.Disc 'M' @() $false '' `
        'SKU features such as compression, partitioning, CDC, columnstore, In-Memory OLTP and TDE.'
    & $add 'DB-CDC-001' 'Change Data Capture is enabled' 'Informational' 'Medium' 'Database' 0 99 `
        '' 'Code' 'High' $true 'Plan the CDC capture and cleanup jobs across the upgrade. Capture jobs are SQL Agent jobs and must be rechecked on the target.' $D.Disc 'M' @() $false '' `
        'CDC tables and the database CDC flag.'
    & $add 'DB-CT-001' 'Change Tracking is enabled' 'Informational' 'Info' 'Database' 0 99 `
        '' 'Code' 'High' $true 'Confirm change-tracking retention and the application that consumes the version still work after the compatibility-level change.' $D.Compat 'S' @() $false '' `
        'Tables registered with change tracking.'
    & $add 'DB-IMOLTP-001' 'In-Memory OLTP tables present' 'Informational' 'Medium' 'Database' 0 99 `
        '' 'Code' 'High' $true 'In-Memory OLTP has its own checkpoint filegroup and version limits. Validate natively compiled modules on the target; do not assume a disk-based upgrade covers them.' $D.Compat 'M' @() $false '' `
        'Memory-optimized tables.'
    & $add 'DB-FILE-001' 'FILESTREAM or FileTable is in use' 'Informational' 'Medium' 'Database' 0 99 `
        '' 'Code' 'High' $true 'FILESTREAM filegroups and FileTables need the same filesystem share and Windows feature on the target host. They are not moved by a database-only backup unless the share is recreated.' $D.Disc 'M' @() $false '' `
        'Filestream filegroups and FileTables.'
    & $add 'DB-BROKER-001' 'Service Broker queues present' 'Informational' 'Medium' 'Database' 0 99 `
        '' 'Code' 'High' $true 'Broker routes, endpoints and dialog security must be recreated or altered on the target. A restored database does not keep remote routes valid.' $D.Disc 'M' @() $false '' `
        'User Service Broker queues.'
    & $add 'DB-PART-001' 'Partition functions present' 'Informational' 'Info' 'Database' 0 99 `
        '' 'Code' 'High' $true 'Partition schemes move with the database. Confirm filegroups exist on the target and that sliding-window jobs still match the new engine.' $D.Compat 'S' @() $false '' `
        'Partition functions.'
    & $add 'DB-XML-001' 'XML schema collections present' 'Informational' 'Info' 'Database' 0 99 `
        '' 'Code' 'High' $true 'XML schema collections move with the database. Re-test typed XML columns if the application depends on schema validation behavior.' $D.Dep2016 'S' @() $false '' `
        'User XML schema collections.'
    & $add 'DB-DMK-001' 'Database master key present' 'Informational' 'Medium' 'Database' 0 99 `
        '' 'Code' 'High' $true 'After restore, open the database master key with its password or regenerate it from the new service master key. Encrypted data stays unavailable until the key opens.' $D.Disc 'M' @() $false '' `
        '##MS_DatabaseMasterKey## exists.'
    & $add 'DB-AE-001' 'Always Encrypted keys present' 'Informational' 'High' 'Database' 0 99 `
        '' 'Code' 'High' $true 'Column master keys and column encryption keys must stay reachable from the application. Moving the database does not move the CMK store (certificate, Azure Key Vault, or Windows store).' $D.Disc 'M' @() $false '' `
        'Always Encrypted column master keys or column encryption keys.'
    & $add 'DB-QSFORCE-001' 'Query Store has forced plans' 'BehaviorChange' 'Medium' 'Database' 0 99 `
        '' 'Code' 'High' $true 'Forced plans are a baseline, not a guarantee. Re-evaluate them after the compatibility-level change; a plan forced on the old cardinality estimator can become a regression on the target.' $D.Qs 'M' @() $false '' `
        'sys.query_store_plan.is_forced_plan = 1. Plan XML is not copied into this report.'
    & $add 'EP-SOAP-001' 'SOAP or HTTP endpoint still defined' 'BreakingChange' 'High' 'Instance' 16 99 `
        '' 'Code' 'High' $true 'Native SOAP endpoints are discontinued. Remove the endpoint and replace it with an application service before upgrade.' $D.Dep2016 'L' @() $false '' `
        'sys.endpoints type SOAP or HTTP.'
    & $add 'EP-OTHER-001' 'Non-TSQL endpoint present (Service Broker, mirroring, or availability group)' 'Informational' 'Info' 'Instance' 0 99 `
        '' 'Code' 'High' $true 'Record every endpoint. HADR, mirroring and Service Broker endpoints must exist, with matching certificates, on the target before cutover.' $D.Disc 'S' @() $false '' `
        'Endpoints other than TSQL and SOAP.'
    & $add 'SRV-TRG-001' 'Server-scoped DDL trigger present' 'Informational' 'Medium' 'Instance' 0 99 `
        '' 'Code' 'High' $true 'Server triggers do not move with a database backup. Script them explicitly and re-test them on the target instance.' $D.Disc 'M' @() $false '' `
        'sys.server_triggers.'
    & $add 'CRED-001' 'Server credential present' 'Informational' 'Medium' 'Instance' 0 99 `
        '' 'Code' 'High' $true 'Credentials do not restore with a user database. Recreate each credential on the target. This assessment does not read the secret.' $D.Disc 'M' @() $false '' `
        'sys.credentials name and identity only.'
    & $add 'PROXY-001' 'SQL Agent proxy present' 'Informational' 'Medium' 'Instance' 0 99 `
        '' 'Code' 'High' $true 'Agent proxies reference credentials. Recreate the proxy and its subsystems on the target before jobs that use it will run.' $D.Disc 'S' @() $false '' `
        'msdb.dbo.sysproxies. The credential secret is not read.'
    & $add 'LS-LOGIN-001' 'Linked-server login mapping is not a self-mapping' 'Informational' 'Info' 'LinkedServer' 0 99 `
        '' 'Code' 'Medium' $true 'A remote SQL login or an unmapped linked login fails after the remote security principal changes. Recreate the mapping on the target. No password is collected.' $D.Dep2016 'S' @() $false '' `
        'sys.linked_logins where uses_self_credential = 0.'
    return , $rules
}

function Import-CustomRules {
    param([array]$BaseRules, [string]$Path)
    if (-not $Path) { return $BaseRules }
    if (-not (Test-Path -LiteralPath $Path)) { throw "RulesPath not found: $Path" }
    $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $custom = $json | ConvertFrom-Json
    $byId = @{}
    foreach ($r in $BaseRules) { $byId[$r.Id] = $r }
    $count = 0
    foreach ($c in $custom) {
        if (-not $c.Id) { continue }
        if ($byId.ContainsKey($c.Id)) {
            # override existing rule fields that were provided
            $orig = $byId[$c.Id]
            $props = @{}
            foreach ($p in $orig.PSObject.Properties.Name) { $props[$p] = $orig.$p }
            foreach ($p in $c.PSObject.Properties.Name) { if ($null -ne $c.$p -and $c.$p -ne '') { $props[$p] = $c.$p } }
            $byId[$c.Id] = [pscustomobject]$props
        } else {
            $props = @{
                Id = [string]$c.Id; Title = [string]$c.Id; Category = 'Informational'; Severity = 'Info'
                Scope = 'Module'; MinTarget = 0; MaxTarget = 99; Pattern = ''; Scan = 'Code'
                Confidence = 'Medium'; Deterministic = $true; Recommendation = ''; Doc = ''
                Effort = 'M'; AppliesTo = @('ANY'); Once = $false; LineExclusion = ''; Description = [string]$c.Id
            }
            foreach ($p in $c.PSObject.Properties.Name) {
                if ($null -ne $c.$p -and [string]$c.$p -ne '') { $props[$p] = $c.$p }
            }
            if ($null -eq $props.MinTarget) { $props.MinTarget = 0 }
            if ($null -eq $props.MaxTarget) { $props.MaxTarget = 99 }
            $byId[$c.Id] = [pscustomobject]$props
        }
        $count++
    }
    Write-AdvLog "Loaded $count custom rule(s) from $Path" 'OK'
    return , @($byId.Values)
}

# --------------------------------------------------------------------------------
# COLLECTOR - instance level (read-only)
# --------------------------------------------------------------------------------
function Get-AdvInstanceData {
    param($Conn, [int]$Timeout)

    $data = @{
        Instance       = $null
        Configs        = @()
        Databases      = @()
        LinkedServers  = @()
        AgentJobs      = @()
        AgentNotifCount= 0
        TraceFlags     = @()
        DeprecatedCounters = @()
        Mirroring      = @()
        AvailabilityGroups = @()
        HasDistributionDb  = $false
        DistributionDatabases = ''
        HasReplicationDist = $false
        HasReplicationPublication = $false
        ReplicationDistributorSource = ''
        LogShippingPrimary = 0
        LogShippingSecondary = 0
        LogShippingRemoteMonitor = 0
        OwnerPerms     = @{}
    }

    # -- instance properties -------------------------------------------------------
    try {
        $q = Get-AdvSql -Name 'inst_instance_properties'
        $rows = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $Conn -Query $q -Timeout $Timeout)
        if ($rows.Count -gt 0) { $data.Instance = $rows[0] }
        Add-AdvCoverage -Name 'Instance properties (version, edition, collation)' -Ok $true
    } catch { Add-AdvCoverage -Name 'Instance properties (version, edition, collation)' -Ok $false -Detail (Truncate-Adv $_.Exception.Message 180) }

    # -- configuration options -----------------------------------------------------
    try {
        $q = Get-AdvSql -Name 'inst_config_options'
        $data.Configs = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $Conn -Query $q -Timeout $Timeout)
        Add-AdvCoverage -Name 'Server configuration options' -Ok $true
    } catch { Add-AdvCoverage -Name 'Server configuration options' -Ok $false -Detail (Truncate-Adv $_.Exception.Message 180) }

    # -- databases -----------------------------------------------------------------
    try {
        $q = Get-AdvSql -Name 'inst_databases'
        $data.Databases = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $Conn -Query $q -Timeout $Timeout)
        Add-AdvCoverage -Name 'Database list + options (compat, trust, stretch, ANSI)' -Ok $true
    } catch { Add-AdvCoverage -Name 'Database list + options (compat, trust, stretch, ANSI)' -Ok $false -Detail (Truncate-Adv $_.Exception.Message 180) }

    # -- owner permission checks (CLR trust evidence) -------------------------------
    $ownerFail = 0
    foreach ($db in $data.Databases) {
        if (-not $db.owner_name) { continue }
        $key = $db.owner_name.ToLowerInvariant()
        if ($data.OwnerPerms.ContainsKey($key)) { continue }
        $entry = [pscustomobject]@{ Owner = $db.owner_name; IsSysadmin = 0; HasUnsafe = 0; Ok = $true }
        try {
            $safe = $db.owner_name -replace "'", "''"
            $q = Get-AdvSql -Name 'owner_permissions' -Sub @{ '{owner}' = $safe }
            $dt = Invoke-AdvQuery -Connection $Conn -Query $q -Timeout 30
            if ($dt.Rows.Count -gt 0) {
                $a = $dt.Rows[0][0]; $b = $dt.Rows[0][1]
                $entry.IsSysadmin = $(if ($a -is [System.DBNull] -or $null -eq $a) { 0 } else { [int]$a })
                $entry.HasUnsafe  = $(if ($b -is [System.DBNull] -or $null -eq $b) { 0 } else { [int]$b })
            }
        } catch { $entry.Ok = $false; $ownerFail++ }
        $data.OwnerPerms[$key] = $entry
    }
    Add-AdvCoverage -Name 'Database owner permission checks (CLR trust evidence)' -Ok ($ownerFail -eq 0) `
        -Detail $(if ($ownerFail -eq 0) { '' } else { "$ownerFail owner check(s) failed" })

    # -- linked servers -------------------------------------------------------------
    try {
        $q = Get-AdvSql -Name 'inst_linked_servers'
        $data.LinkedServers = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $Conn -Query $q -Timeout $Timeout)
        Add-AdvCoverage -Name 'Linked servers' -Ok $true
    } catch { Add-AdvCoverage -Name 'Linked servers' -Ok $false -Detail (Truncate-Adv $_.Exception.Message 180) }

    # -- database mirroring ----------------------------------------------------------
    try {
        $q = Get-AdvSql -Name 'inst_mirroring'
        $data.Mirroring = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $Conn -Query $q -Timeout $Timeout)
        Add-AdvCoverage -Name 'Database mirroring configuration' -Ok $true
    } catch { Add-AdvCoverage -Name 'Database mirroring configuration' -Ok $false -Detail (Truncate-Adv $_.Exception.Message 180) }

    # -- availability groups ---------------------------------------------------------
    # cluster_type_desc exists only on SQL Server 2017+ (major 14). Referencing it on 2016
    # fails at compile time, so the 2016-safe script is the default.
    try {
        $productMajor = 0
        if ($data.Instance -and $null -ne $data.Instance.ProductMajorVersion) {
            $fromProp = Get-AdvInt $data.Instance.ProductMajorVersion
            if ($fromProp -gt 0) { $productMajor = $fromProp }
        }
        if ($productMajor -le 0 -and $data.Instance -and $data.Instance.ProductVersion) {
            $verHead = ([string]$data.Instance.ProductVersion).Split('.')[0]
            $parsedMajor = 0
            if ([int]::TryParse($verHead, [ref]$parsedMajor)) { $productMajor = $parsedMajor }
        }
        $agScript = 'inst_availability_groups'
        if ($productMajor -ge 14) { $agScript = 'inst_availability_groups_cluster' }
        try {
            $q = Get-AdvSql -Name $agScript
            $data.AvailabilityGroups = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $Conn -Query $q -Timeout 30)
        } catch {
            if ($agScript -eq 'inst_availability_groups') { throw }
            $q = Get-AdvSql -Name 'inst_availability_groups'
            $data.AvailabilityGroups = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $Conn -Query $q -Timeout 30)
        }
        Add-AdvCoverage -Name 'Availability groups' -Ok $true -Detail $agScript
    } catch { Add-AdvCoverage -Name 'Availability groups (not present or no permission)' -Ok $false -Detail (Truncate-Adv $_.Exception.Message 140) }

    # -- replication publication flags (renamed distribution DB, remote distributor) --
    foreach ($db in @($data.Databases)) {
        if ((Get-AdvInt $db.is_distributor) -eq 1) {
            $data.HasDistributionDb = $true
            if ($db.name) {
                if ($data.DistributionDatabases) { $data.DistributionDatabases += ', ' + [string]$db.name }
                else { $data.DistributionDatabases = [string]$db.name }
            }
        }
        if ((Get-AdvInt $db.is_published) -eq 1 -or (Get-AdvInt $db.is_subscribed) -eq 1 -or (Get-AdvInt $db.is_merge_published) -eq 1) {
            $data.HasReplicationPublication = $true
        }
    }

    # -- replication / log shipping / distribution -----------------------------------
    try {
        $dt = Invoke-AdvQuery -Connection $Conn -Query (Get-AdvSql -Name 'inst_has_distribution_db') -Timeout 30
        if ($dt.Rows.Count -gt 0) {
            $data.HasDistributionDb = ($data.HasDistributionDb -or ([int]$dt.Rows[0][0] -eq 1))
            if ($dt.Columns.Count -gt 1 -and $dt.Rows[0][1] -isnot [System.DBNull] -and $null -ne $dt.Rows[0][1]) {
                $data.DistributionDatabases = [string]$dt.Rows[0][1]
            }
        }
        $dt2 = Invoke-AdvQuery -Connection $Conn -Query (Get-AdvSql -Name 'inst_repl_distributor') -Timeout 30
        if ($dt2.Rows.Count -gt 0) {
            $data.HasReplicationDist = ([int]$dt2.Rows[0][0] -gt 0)
            if ($dt2.Columns.Count -gt 1 -and $dt2.Rows[0][1] -isnot [System.DBNull] -and $null -ne $dt2.Rows[0][1]) {
                $data.ReplicationDistributorSource = [string]$dt2.Rows[0][1]
            }
        }
        Add-AdvCoverage -Name 'Replication topology detection' -Ok $true `
            -Detail ("distributor={0} ({1}); repl_distributor={2}; published_or_subscribed={3}" -f `
                [bool]$data.HasDistributionDb, $data.DistributionDatabases, [bool]$data.HasReplicationDist, [bool]$data.HasReplicationPublication)
    } catch { Add-AdvCoverage -Name 'Replication topology detection' -Ok $false -Detail (Truncate-Adv $_.Exception.Message 140) }

    try {
        $q = Get-AdvSql -Name 'inst_log_shipping'
        $rows = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $Conn -Query $q -Timeout 30)
        $localName = ''
        if ($data.Instance -and $data.Instance.ServerName) { $localName = [string]$data.Instance.ServerName }
        foreach ($r in @($rows)) {
            if ([string]$r.role -eq 'PRIMARY') { $data.LogShippingPrimary++ } else { $data.LogShippingSecondary++ }
            $mon = [string]$r.monitor_server
            if ($mon -and $localName -and ($mon -ne $localName)) { $data.LogShippingRemoteMonitor++ }
        }
        Add-AdvCoverage -Name 'Log shipping configuration' -Ok $true `
            -Detail ("primaries={0}; secondaries={1}; remote monitors={2}" -f $data.LogShippingPrimary, $data.LogShippingSecondary, $data.LogShippingRemoteMonitor)
    } catch { Add-AdvCoverage -Name 'Log shipping configuration (not present or no permission)' -Ok $false -Detail (Truncate-Adv $_.Exception.Message 140) }

    # -- SQL Agent jobs ---------------------------------------------------------------
    try {
        $q = Get-AdvSql -Name 'inst_agent_jobs'
        $data.AgentJobs = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $Conn -Query $q -Timeout $Timeout)
        Add-AdvCoverage -Name 'SQL Agent jobs + steps' -Ok $true
    } catch { Add-AdvCoverage -Name 'SQL Agent jobs + steps (no msdb permission)' -Ok $false -Detail (Truncate-Adv $_.Exception.Message 140) }

    try {
        $dt = Invoke-AdvQuery -Connection $Conn -Query (Get-AdvSql -Name 'inst_agent_notifications') -Timeout 30
        $data.AgentNotifCount = [int]$dt.Rows[0][0]
        Add-AdvCoverage -Name 'SQL Agent notifications (net send / pager)' -Ok $true
    } catch { Add-AdvCoverage -Name 'SQL Agent notifications (net send / pager)' -Ok $false -Detail (Truncate-Adv $_.Exception.Message 140) }

    # -- trace flags ------------------------------------------------------------------
    try {
        $dt = Invoke-AdvQuery -Connection $Conn -Query (Get-AdvSql -Name 'inst_trace_status') -Timeout 30
        $tf = @()
        foreach ($r in $dt.Rows) {
            $tf += [pscustomobject]@{ Flag = [int]$r[0]; Status = [int]$r[1]; Global = [int]$r[2]; Session = [int]$r[3] }
        }
        $data.TraceFlags = $tf
        $flagNote = if ($tf.Count -eq 0) { 'no flags visible to this login' } else { ('{0} flag(s)' -f $tf.Count) }
        Add-AdvCoverage -Name 'Global/session trace flags' -Ok $true -Detail $flagNote
    } catch {
        Add-AdvCoverage -Name 'Global/session trace flags' -Ok $false `
            -Detail ('DBCC TRACESTATUS needs ALTER TRACE or sysadmin, which the assessment login does not have. Empty is not the same as no flags. ' + (Truncate-Adv $_.Exception.Message 120))
    }

    # -- RUNTIME deprecated-feature evidence ------------------------------------------
    try {
        $q = Get-AdvSql -Name 'inst_deprecated_counters'
        $data.DeprecatedCounters = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $Conn -Query $q -Timeout 30)
        Add-AdvCoverage -Name 'Runtime deprecated-feature counters (sys.dm_os_performance_counters)' -Ok $true
    } catch { Add-AdvCoverage -Name 'Runtime deprecated-feature counters (sys.dm_os_performance_counters)' -Ok $false -Detail (Truncate-Adv $_.Exception.Message 140) }

    # -- endpoints, server triggers, credentials, proxies, linked logins ----------
    foreach ($pair in @(
        @{ Name = 'inst_endpoints';          Key = 'Endpoints';       Label = 'Non-TSQL endpoints' },
        @{ Name = 'inst_server_triggers';    Key = 'ServerTriggers';  Label = 'Server DDL triggers' },
        @{ Name = 'inst_credentials';        Key = 'Credentials';     Label = 'Server credentials (names only)' },
        @{ Name = 'inst_agent_proxies';      Key = 'AgentProxies';    Label = 'SQL Agent proxies (names only)' },
        @{ Name = 'inst_linked_logins';      Key = 'LinkedLogins';    Label = 'Linked-server login mappings' }
    )) {
        try {
            $data[$pair.Key] = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $Conn -Query (Get-AdvSql -Name $pair.Name) -Timeout 30)
            Add-AdvCoverage -Name $pair.Label -Ok $true -Detail ('{0} row(s)' -f @($data[$pair.Key]).Count)
        } catch {
            $data[$pair.Key] = @()
            Add-AdvCoverage -Name $pair.Label -Ok $false -Detail (Truncate-Adv $_.Exception.Message 140)
        }
    }

    $trustMajor = 0
    if ($data.Instance -and $null -ne $data.Instance.ProductMajorVersion) { $trustMajor = Get-AdvInt $data.Instance.ProductMajorVersion }
    if ($trustMajor -le 0 -and $data.Instance -and $data.Instance.ProductVersion) {
        $head = ([string]$data.Instance.ProductVersion).Split('.')[0]
        $parsed = 0
        if ([int]::TryParse($head, [ref]$parsed)) { $trustMajor = $parsed }
    }
    if ($trustMajor -ge 14) {
        try {
            $data.TrustedAssemblies = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $Conn -Query (Get-AdvSql -Name 'inst_trusted_assemblies') -Timeout 30)
            Add-AdvCoverage -Name 'Trusted assemblies (sys.trusted_assemblies)' -Ok $true -Detail ('{0} registered' -f @($data.TrustedAssemblies).Count)
        } catch {
            $data.TrustedAssemblies = @()
            Add-AdvCoverage -Name 'Trusted assemblies (sys.trusted_assemblies)' -Ok $false -Detail (Truncate-Adv $_.Exception.Message 140)
        }
    } else {
        $data.TrustedAssemblies = @()
        Add-AdvCoverage -Name 'Trusted assemblies (sys.trusted_assemblies)' -Ok $true -Detail 'not available before SQL Server 2017'
    }

    return $data
}

# --------------------------------------------------------------------------------
# COLLECTOR - database selection
# --------------------------------------------------------------------------------
function Select-AdvDatabases {
    param($AllDatabases, [string[]]$Filter, [bool]$IncludeMaster = $false)
    $system = @('model','msdb','tempdb')
    if (-not $IncludeMaster) { $system += 'master' }
    $patterns = @()
    foreach ($f in @($Filter)) { foreach ($p in ([string]$f).Split(',')) { if (-not [string]::IsNullOrWhiteSpace($p)) { $patterns += $p.Trim() } } }
    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($db in $AllDatabases) {
        if ($system -contains $db.name) { continue }
        if ($patterns.Count -gt 0) {
            $match = $false
            foreach ($f in $patterns) { if ($db.name -like $f) { $match = $true; break } }
            if (-not $match) { continue }
        }
        $selected.Add($db)
    }
    return , $selected
}

# --------------------------------------------------------------------------------
# COLLECTOR - one database (deep, read-only)
# --------------------------------------------------------------------------------
function Get-AdvDatabaseData {
    param($Instance, [pscredential]$Cred, [bool]$UseEncrypt, [bool]$TrustCert = $false, $DbRow, [int]$Timeout, [string]$DefinitionsMode = 'Full')

    $db = $DbRow.name
    $out = @{
        Database    = $db
        QueryStore  = 'unknown'
        OwnerIsSysadmin = 0
        OwnerHasUnsafe  = 0
        Objects     = @()
        Columns     = @()
        Indexes     = @()
        Assemblies  = @()
        Crypto      = @()
        Synonyms    = @()
        ExternalSources = @()
        ExternalTables  = @()
        FullText    = @()
        Dependencies= @()
        ObjectStats = @()
        FeatureSurface = $null
        SkuFeatures = @()
        QueryStoreBaseline = $null
        Ok          = $true
        Error       = ''
    }

    $conn = $null
    try {
        $conn = New-AdvConnection -Instance $Instance -Cred $Cred -UseEncrypt $UseEncrypt -TrustCert $TrustCert -Database $db
    } catch {
        $out.Ok = $false
        $out.Error = Truncate-Adv $_.Exception.Message 200
        Add-AdvCoverage -Name "[$db] connection" -Ok $false -Detail $out.Error
        return $out
    }

    try {
        # Query Store state -------------------------------------------------------
        try {
            $dt = Invoke-AdvQuery -Connection $conn -Query (Get-AdvSql -Name 'db_query_store_state') -Timeout 30
            if ($dt.Rows.Count -gt 0) { $out.QueryStore = [string]$dt.Rows[0][0] } else { $out.QueryStore = 'not found' }
        } catch { $out.QueryStore = 'unknown' }

        # Owner permission evidence ------------------------------------------------
        if ($DbRow.owner_name) {
            $key = $DbRow.owner_name.ToLowerInvariant()
            try {
                $safe = $DbRow.owner_name -replace "'", "''"
                $dt = Invoke-AdvQuery -Connection $conn -Query (Get-AdvSql -Name 'owner_permissions' -Sub @{ '{owner}' = $safe }) -Timeout 30
                if ($dt.Rows.Count -gt 0) {
                    $out.OwnerIsSysadmin = $(if ($dt.Rows[0][0] -is [System.DBNull] -or $null -eq $dt.Rows[0][0]) { 0 } else { [int]$dt.Rows[0][0] })
                    $out.OwnerHasUnsafe  = $(if ($dt.Rows[0][1] -is [System.DBNull] -or $null -eq $dt.Rows[0][1]) { 0 } else { [int]$dt.Rows[0][1] })
                }
            } catch { }
        }

        # Objects + module definitions ---------------------------------------------
        try {
            $objScript = 'db_objects'
            if ($DefinitionsMode -eq 'HashOnly') { $objScript = 'db_objects_hash' }
            $q = Get-AdvSql -Name $objScript
            $out.Objects = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout $Timeout)
            Add-AdvCoverage -Name "[$db] objects + module definitions" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] objects + module definitions" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160); $out.Ok = $false }

        $knownIds = @{}
        foreach ($o in $out.Objects) { $knownIds[[string]$o.object_id] = $true }

        # Database DDL triggers ------------------------------------------------------
        try {
            $q = Get-AdvSql -Name 'db_ddl_triggers'
            $extra = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout $Timeout)
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($o in $out.Objects) { $list.Add($o) }
            foreach ($t in $extra) {
                if (-not $knownIds.ContainsKey([string]$t.object_id)) { $list.Add($t); $knownIds[[string]$t.object_id] = $true }
            }
            $out.Objects = $list
            Add-AdvCoverage -Name "[$db] database DDL triggers" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] database DDL triggers" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }

        # CLR assembly modules --------------------------------------------------------
        try {
            $q = Get-AdvSql -Name 'db_clr_modules'
            $clr = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout $Timeout)
            $list = [System.Collections.Generic.List[object]]::new()
            foreach ($o in $out.Objects) { $list.Add($o) }
            foreach ($c in $clr) {
                if ($knownIds.ContainsKey([string]$c.object_id)) { continue }
                $list.Add([pscustomobject]@{
                    object_id = $c.object_id; schema_name = $c.schema_name; name = $c.name
                    type = $c.type; type_desc = $c.type_desc
                    create_date = $c.create_date; modify_date = $c.modify_date
                    definition = $null; is_clr = $true
                    assembly_name = $c.assembly_name; assembly_class = $c.assembly_class; permission_set = $c.permission_set
                })
            }
            $out.Objects = $list
            Add-AdvCoverage -Name "[$db] CLR assembly modules" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] CLR assembly modules" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }

        # Columns -----------------------------------------------------------------------
        try {
            $q = Get-AdvSql -Name 'db_columns'
            $out.Columns = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout $Timeout)
            Add-AdvCoverage -Name "[$db] table columns" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] table columns" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }

        # Notable indexes -----------------------------------------------------------------
        try {
            $q = Get-AdvSql -Name 'db_indexes'
            $out.Indexes = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout $Timeout)
            Add-AdvCoverage -Name "[$db] notable indexes (filtered/XML/spatial/disabled/columnstore)" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] notable indexes" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }

        # Synonyms --------------------------------------------------------------------------
        try {
            $q = Get-AdvSql -Name 'db_synonyms'
            $out.Synonyms = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout $Timeout)
            Add-AdvCoverage -Name "[$db] synonyms" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] synonyms" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }

        # Assemblies + trust material --------------------------------------------------------
        try {
            $q = Get-AdvSql -Name 'db_assemblies'
            $out.Assemblies = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout $Timeout)
            Add-AdvCoverage -Name "[$db] CLR assemblies" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] CLR assemblies" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }

        try {
            $q = Get-AdvSql -Name 'db_crypto'
            $out.Crypto = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout 30)
            Add-AdvCoverage -Name "[$db] certificates / asymmetric keys" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] certificates / asymmetric keys" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }

        # PolyBase external objects ------------------------------------------------------------
        try {
            $q = Get-AdvSql -Name 'db_external_sources'
            $out.ExternalSources = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout 30)
            $q2 = Get-AdvSql -Name 'db_external_tables'
            $out.ExternalTables = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q2 -Timeout 30)
            Add-AdvCoverage -Name "[$db] PolyBase external sources/tables" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] PolyBase external sources/tables" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }

        # Full-Text ------------------------------------------------------------------------
        try {
            $q = Get-AdvSql -Name 'db_fulltext'
            $out.FullText = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout 30)
            Add-AdvCoverage -Name "[$db] Full-Text indexes" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] Full-Text indexes" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }

        # Dependencies (blast radius) ----------------------------------------------------------
        try {
            $q = Get-AdvSql -Name 'db_dependencies'
            $out.Dependencies = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout $Timeout)
            Add-AdvCoverage -Name "[$db] object dependencies (blast radius)" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] object dependencies (blast radius)" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }

        # Hotness: plan cache ---------------------------------------------------------------
        $stats = @{}
        try {
            $q = Get-AdvSql -Name 'db_procedure_stats'
            foreach ($r in (ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout 60))) {
                $stats[[string]$r.object_id] = $r
            }
        } catch { }
        try {
            $q = Get-AdvSql -Name 'db_trigger_stats'
            foreach ($r in (ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query $q -Timeout 60))) {
                $k = [string]$r.object_id
                if ($stats.ContainsKey($k)) {
                    $p = $stats[$k]
                    $stats[$k] = [pscustomobject]@{
                        object_id = $r.object_id
                        exec_count = [long]$p.exec_count + [long]$r.exec_count
                        total_reads = [long]$p.total_reads + [long]$r.total_reads
                        total_cpu = [long]$p.total_cpu + [long]$r.total_cpu
                    }
                } else { $stats[$k] = $r }
            }
            Add-AdvCoverage -Name "[$db] runtime hotness (plan cache execution counts)" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] runtime hotness (plan cache)" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }
        $out.ObjectStats = @($stats.Values)

        try {
            $rows = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query (Get-AdvSql -Name 'db_feature_surface') -Timeout 60)
            if ($rows.Count -gt 0) { $out.FeatureSurface = $rows[0] }
            Add-AdvCoverage -Name "[$db] feature surface (CDC, In-Memory, Broker, FILESTREAM, AE)" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] feature surface" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }
        try {
            $out.SkuFeatures = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query (Get-AdvSql -Name 'db_sku_features') -Timeout 30)
            Add-AdvCoverage -Name "[$db] persisted SKU features" -Ok $true -Detail ('{0} feature(s)' -f @($out.SkuFeatures).Count)
        } catch { Add-AdvCoverage -Name "[$db] persisted SKU features" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }
        try {
            $rows = ConvertFrom-DataTable (Invoke-AdvQuery -Connection $conn -Query (Get-AdvSql -Name 'db_query_store_baseline') -Timeout 60)
            if ($rows.Count -gt 0) { $out.QueryStoreBaseline = $rows[0] }
            Add-AdvCoverage -Name "[$db] Query Store baseline counts" -Ok $true
        } catch { Add-AdvCoverage -Name "[$db] Query Store baseline counts" -Ok $false -Detail (Truncate-Adv $_.Exception.Message 160) }

        # objects seen in assembly_modules must not be reported as "encrypted" ---------------
        foreach ($o in $out.Objects) {
            $o | Add-Member -NotePropertyName is_clr -NotePropertyValue ([bool]$o.is_clr) -Force -ErrorAction SilentlyContinue
        }
    } finally {
        if ($conn) { $conn.Close(); $conn.Dispose() }
    }
    return $out
}

# --------------------------------------------------------------------------------
# RULE ENGINE - target gating, module scanning, structural checks, scoring
# --------------------------------------------------------------------------------
function Get-AdvProductLabel {
    # Engine major version to the product year shown in reports.
    # 16 is SQL Server 2022, not calendar year 2016.
    param([int]$Major)
    switch ($Major) {
        10 { return '2008' }
        11 { return '2012' }
        12 { return '2014' }
        13 { return '2016' }
        14 { return '2017' }
        15 { return '2019' }
        16 { return '2022' }
        17 { return '2025' }
        default { return ('major ' + $Major) }
    }
}

function Get-AdvTargetMajor {
    param([string]$TargetVersion)
    if ($TargetVersion -eq '2025') { return 17 }
    return 16
}

function Get-AdvDefaultCompat {
    param([string]$TargetVersion)
    if ($TargetVersion -eq '2025') { return 170 }
    return 160
}

function Get-AdvInt {
    param($Value)
    if ($null -eq $Value -or $Value -is [System.DBNull]) { return -1 }
    try { return [int]$Value } catch { return -1 }
}

function Get-AdvTypeToken {
    # Maps sys.types codes onto the AppliesTo tokens used by rules (P / FN / TR / V / ...).
    param([string]$Type)
    $t = ([string]$Type).Trim().ToUpperInvariant()
    if ($t -eq 'PC') { return 'P' }
    if ($t -eq 'FN' -or $t -eq 'IF' -or $t -eq 'TF') { return 'FN' }
    return $t
}

function Get-AdvRuleStatus {
    # Status vocabulary is derived from rule category, with per-finding overrides allowed.
    param($Rule, [string]$Override = '')
    if ($Override) { return $Override }
    switch ([string]$Rule.Category) {
        'Blocker'        { return 'Will break' }
        'BreakingChange' { return 'Will break' }
        'BehaviorChange' { return 'Needs adjustment' }
        'SecurityRisk'   { return 'Security concern' }
        'Deprecated'     { return 'Deprecated usage' }
        'Modernization'  { return 'Modernization' }
        'BlindSpot'      { return 'Not assessable' }
        'Informational'  { return 'Needs review' }
        default          { return 'Needs review' }
    }
}

function Test-AdvAppliesTo {
    param($Rule, [string]$ObjType)
    $raw = $Rule.AppliesTo
    if ($null -eq $raw) { return $true }
    # A single string must stay one token. Wrapping a string in @() enumerates its characters.
    if ($raw -is [string]) { $ap = ,$raw } else { $ap = @($raw) }
    if ($ap.Count -eq 0) { return $true }
    foreach ($a in $ap) { if ($a -eq 'ANY' -or $a -eq $ObjType) { return $true } }
    return $false
}

function Get-AdvSqlFragments {
    # Pull string literals that look like T-SQL so dynamic SQL is scanned instead of ignored.
    param([string]$Text)
    $list = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrEmpty($Text)) { return ,$list }
    # Walk quotes so a doubled quote stays inside the literal. A greedy regex
    # swallows later strings in the same module.
    $i = 0
    $n = 0
    while ($i -lt $Text.Length -and $n -lt 20) {
        $q = $Text.IndexOf([char]39, $i)
        if ($q -lt 0) { break }
        $sb = New-Object System.Text.StringBuilder
        $j = $q + 1
        $closed = $false
        while ($j -lt $Text.Length -and $sb.Length -le 4000) {
            if ($Text[$j] -eq [char]39) {
                if (($j + 1) -lt $Text.Length -and $Text[$j + 1] -eq [char]39) {
                    [void]$sb.Append([char]39)
                    $j += 2
                    continue
                }
                $closed = $true
                $j++
                break
            }
            [void]$sb.Append($Text[$j])
            $j++
        }
        $i = $j
        if (-not $closed) { continue }
        $lit = $sb.ToString()
        if ($lit.Length -lt 8) { continue }
        if ($lit -match '(?i)\b(?:select|insert|update|delete|merge|exec|execute|create|alter|dbcc)\b') {
            $list.Add($lit)
            $n++
        }
    }
    return ,$list
}

function Find-AdvTriggerResultSelects {
    <#
      Heuristic: locate SELECT statements in a trigger body that plausibly RETURN a result set
      to the client (deprecated - "returning result sets from triggers" has no replacement).
      Skipped:
        - SELECTs that sit inside an expression (preceding non-space char in ( = , + - * / % < > ! & | )
        - tails starting with digit / @ / count( / top / exists   (assignments & expressions)
        - SELECT ... INTO ... FROM (no result set returned)
        - statements whose lookback since the last ';' contains insert|union|values|case|set|cursor
          (INSERT ... SELECT, UNION branches, cursor bodies, SET-then-SELECT chains).
      Runs on comment/string-stripped text so literals cannot produce matches.
    #>
    param([string]$Text)
    $result = New-Object System.Collections.Generic.List[int]
    if ([string]::IsNullOrEmpty($Text)) { return , $result }
    $scan = Hide-SqlNoise -Text $Text -KeepStrings $false
    $rx = [regex]::new('(?i)\bselect\b')
    foreach ($m in $rx.Matches($scan)) {
        $idx = $m.Index

        # 1) inside an expression?
        $j = $idx - 1
        while ($j -ge 0 -and [char]::IsWhiteSpace($scan[$j])) { $j-- }
        if ($j -ge 0) {
            $prev = [string]$scan[$j]
            if ('(),+-*/%<>!&|'.Contains($prev)) { continue }
        }

        # 2) expression-ish tail, or SELECT ... INTO ... FROM
        $tailStart = $idx + 6
        if ($tailStart -lt $scan.Length) {
            $tail = $scan.Substring($tailStart, [Math]::Min(600, $scan.Length - $tailStart))
            $tt = [regex]::Replace($tail, '^\s+', '')
            if ($tt -match '^\d' -or $tt -match '^@' -or $tt -match '(?i)^count\s*\(' -or
                $tt -match '(?i)^top\b' -or $tt -match '(?i)^exists\b') { continue }
            if ($tt -match '(?i)\binto\b[^;]*?\bfrom\b') { continue }
        }

        # 3) statement context since the last batch separator
        $semi = -1
        if ($idx -gt 0) { $semi = $scan.LastIndexOf(';', ($idx - 1)) }
        $lbStart = 0
        if ($semi -ge 0) { $lbStart = $semi + 1 }
        if ($idx -gt $lbStart) {
            $lookback = $scan.Substring($lbStart, $idx - $lbStart)
            # SET NOCOUNT ON / SET STATISTICS ... are housekeeping, not assignment context
            $lookback = [regex]::Replace($lookback, '(?i)\bset\s+(?:nocount|statistics|identity_insert|user_options)\b[^;]*', '')
            if ($lookback -match '(?i)\b(?:insert|union|values|case|set|cursor)\b') { continue }
        }
        $result.Add($idx)
    }
    return , $result
}

# --------------------------------------------------------------------------------
# Scoring: risk = severity base + hotness + blast radius + repetition, capped 0..100
# --------------------------------------------------------------------------------
function Get-AdvSeverityScore {
    param([string]$Severity)
    switch ($Severity) {
        'Critical' { return 40 }
        'High'     { return 30 }
        'Medium'   { return 20 }
        'Low'      { return 10 }
        'Info'     { return 5 }
        default    { return 15 }
    }
}

function Update-AdvRisk {
    param($Findings)
    foreach ($f in $Findings) {
        $risk = Get-AdvSeverityScore -Severity ([string]$f.Severity)

        $h = [long]$f.Hotness
        if     ($h -ge 1000000) { $risk += 20 }
        elseif ($h -ge 100000)   { $risk += 15 }
        elseif ($h -ge 10000)    { $risk += 10 }
        elseif ($h -ge 1000)     { $risk += 5 }
        elseif ($h -gt 0)        { $risk += 2 }

        $b = [int]$f.BlastRadius
        if     ($b -ge 100) { $risk += 15 }
        elseif ($b -ge 25)  { $risk += 10 }
        elseif ($b -ge 10)  { $risk += 6 }
        elseif ($b -ge 3)   { $risk += 3 }
        elseif ($b -ge 1)   { $risk += 1 }

        $m = [int]$f.TotalMatches
        if     ($m -ge 50) { $risk += 8 }
        elseif ($m -ge 10) { $risk += 5 }
        elseif ($m -ge 3)  { $risk += 3 }
        elseif ($m -gt 1)  { $risk += 1 }

        if (-not $f.Deterministic) { $risk -= 3 }   # heuristic rules score lower
        if ($f.Confidence -eq 'Low') { $risk -= 3 } elseif ($f.Confidence -eq 'Medium') { $risk -= 1 }

        $f.Risk = [Math]::Max(0, [Math]::Min(100, $risk))
    }
}

function Set-AdvDerivedScores {
    # Blast radius = dependency fan-in (who references this object), database object counts
    # for database-scope findings, database counts for instance-scope findings, and module
    # fan-out for linked servers. Hotness = plan-cache executions (already set for modules),
    # backfilled from database/instance totals for scope-wide findings.
    param($Findings, [array]$DatabaseData, $InstanceData)

    # -- dependency fan-in map: "db|schema.name" -> distinct referencing entities ----
    $fanIn = @{}
    foreach ($dbd in $DatabaseData) {
        foreach ($dep in @($dbd.Dependencies | Where-Object { $_ })) {
            if ($dep.referenced_server_name) { continue }
            $tDb = [string]$dbd.Database
            if ($dep.referenced_database_name) { $tDb = [string]$dep.referenced_database_name }
            $rSchema = 'dbo'
            if ($dep.referenced_schema_name) { $rSchema = [string]$dep.referenced_schema_name }
            $rName = [string]$dep.referenced_entity_name
            if (-not $rName) { continue }
            $key = ('{0}|{1}.{2}' -f $tDb, $rSchema, $rName).ToLowerInvariant()
            $src = ('{0}.{1}' -f [string]$dep.referencing_schema_name, [string]$dep.referencing_entity_name).ToLowerInvariant()
            if (-not $fanIn.ContainsKey($key)) { $fanIn[$key] = @{} }
            $fanIn[$key][$src] = $true
        }
    }

    # -- per-database totals ---------------------------------------------------------
    $objCount = @{}
    $dbHot    = @{}
    $totalObjects = 0
    $totalHot     = [long]0
    foreach ($dbd in $DatabaseData) {
        $n = [string]$dbd.Database
        $cnt = @($dbd.Objects | Where-Object { $_ }).Count
        $objCount[$n] = $cnt
        $totalObjects += $cnt
        $h = [long]0
        foreach ($st in @($dbd.ObjectStats | Where-Object { $_ })) { $h += [long]$st.exec_count }
        $dbHot[$n] = $h
        $totalHot += $h
    }
    $dbCount = @($DatabaseData).Count

    foreach ($f in $Findings) {
        switch ([string]$f.Scope) {
            'Instance' {
                # Do not copy the estate-wide execution total onto every instance finding.
                # That made trace flags and config notes look as hot as the busiest procedure.
            }
            'Database' {
                # Object count is inventory size, not dependency fan-in. Leave BlastRadius
                # at 0 unless a later rule sets a real fan-in.
            }
            'LinkedServer' {
                # fan-out: how many modules / job steps reference this linked server
                $hits = 0
                $nm = [string]$f.Object
                if ($nm) {
                    $esc = [regex]::Escape($nm)
                    foreach ($dbd in $DatabaseData) {
                        foreach ($o in @($dbd.Objects | Where-Object { $_ })) {
                            if (-not $o.definition) { continue }
                            if ([string]$o.definition -match ("(?i)\b{0}\b" -f $esc)) { $hits++ }
                        }
                    }
                    foreach ($j in @($InstanceData.AgentJobs | Where-Object { $_ })) {
                        if ($j.command -and ([string]$j.command -match ("(?i)\b{0}\b" -f $esc))) { $hits++ }
                    }
                }
                $f.BlastRadius = $hits
            }
            default {
                $key = ('{0}|{1}.{2}' -f $f.Database, $f.Schema, $f.Object).ToLowerInvariant()
                if (-not $fanIn.ContainsKey($key)) { $key = ('{0}|{1}' -f $f.Database, $f.Object).ToLowerInvariant() }
                if ($fanIn.ContainsKey($key)) { $f.BlastRadius = [int]$fanIn[$key].Count }
            }
        }
    }
}

function New-AdvInventory {
    # Every assessed object gets a row. No rule match is "No static findings",
    # which is not a claim that the object was proven compatible on the target.
    # so the report can answer "what will work" as explicitly as "what will break".
    param($Findings, [array]$DatabaseData)
    $map = @{}
    foreach ($f in $Findings) {
        if (-not $f.Database) { continue }        # instance/job findings are not object-scoped
        $k = [string]$f.Key
        $k = $k.ToLowerInvariant()
        if ($map.ContainsKey($k)) {
            $e = $map[$k]
        } else {
            $e = [pscustomobject]@{ FindingCount = 0; MaxRisk = 0; Status = ''; RuleIds = (New-Object System.Collections.Generic.List[string]) }
            $map[$k] = $e
        }
        $e.FindingCount++
        $e.RuleIds.Add([string]$f.RuleId)
        if ([int]$f.Risk -ge $e.MaxRisk) { $e.MaxRisk = [int]$f.Risk; $e.Status = [string]$f.Status }
    }

    $inv = [System.Collections.Generic.List[object]]::new()
    foreach ($dbd in $DatabaseData) {
        $db = [string]$dbd.Database
        $candidates = [System.Collections.Generic.List[object]]::new()
        $candidates.Add([pscustomobject]@{ Database = $db; Schema = ''; Object = $db; ObjType = 'DB'; ObjTypeDesc = 'DATABASE' })
        foreach ($o in @($dbd.Objects | Where-Object { $_ })) {
            $candidates.Add([pscustomobject]@{
                Database = $db; Schema = [string]$o.schema_name; Object = [string]$o.name
                ObjType = (Get-AdvTypeToken -Type $o.type); ObjTypeDesc = [string]$o.type_desc
            })
        }
        foreach ($a in @($dbd.Assemblies | Where-Object { $_ })) {
            $candidates.Add([pscustomobject]@{ Database = $db; Schema = ''; Object = [string]$a.name; ObjType = 'ASM'; ObjTypeDesc = 'ASSEMBLY' })
        }
        foreach ($c in $candidates) {
            $k = ('{0}|{1}|{2}|{3}' -f $c.Database, $c.Schema, $c.Object, $c.ObjType).ToLowerInvariant()
            if ($map.ContainsKey($k)) {
                $e = $map[$k]
                $inv.Add([pscustomobject]@{
                    Database = $c.Database; Schema = $c.Schema; Object = $c.Object
                    ObjType = $c.ObjType; ObjTypeDesc = $c.ObjTypeDesc
                    FindingCount = $e.FindingCount; MaxRisk = $e.MaxRisk; Status = $e.Status
                    RuleIds = (@($e.RuleIds) -join ', ')
                })
            } else {
                $inv.Add([pscustomobject]@{
                    Database = $c.Database; Schema = $c.Schema; Object = $c.Object
                    ObjType = $c.ObjType; ObjTypeDesc = $c.ObjTypeDesc
                    FindingCount = 0; MaxRisk = 0; Status = 'No static findings'; RuleIds = ''
                })
            }
        }
    }
    return , @($inv)
}

function Get-AdvSummary {
    param($Findings, $Inventory, [array]$DatabaseData, $InstanceData,
          [string]$TargetVersion, [int]$TargetCompat, $ActiveRules)

    $serverName = ''; $srcVersion = ''
    if ($InstanceData -and $InstanceData.Instance) {
        $serverName  = [string]$InstanceData.Instance.ServerName
        $srcVersion  = [string]$InstanceData.Instance.ProductVersion
    }

    $byStatus = [ordered]@{}
    foreach ($s in @('Will break', 'Needs adjustment', 'Security concern', 'Deprecated usage', 'Needs review', 'Modernization', 'Not assessable')) { $byStatus[$s] = 0 }
    $bySeverity = [ordered]@{ 'Critical' = 0; 'High' = 0; 'Medium' = 0; 'Low' = 0; 'Info' = 0 }
    $byCategory = [ordered]@{}
    $riskBands  = [ordered]@{ 'Critical (70-100)' = 0; 'High (50-69)' = 0; 'Medium (30-49)' = 0; 'Low (0-29)' = 0 }

    foreach ($f in $Findings) {
        $st = [string]$f.Status
        if ($byStatus.Contains($st)) { $byStatus[$st] = $byStatus[$st] + 1 } else { $byStatus[$st] = 1 }
        $sv = [string]$f.Severity
        if ($bySeverity.Contains($sv)) { $bySeverity[$sv] = $bySeverity[$sv] + 1 } else { $bySeverity[$sv] = 1 }
        $cat = [string]$f.Category
        if ($byCategory.Contains($cat)) { $byCategory[$cat] = $byCategory[$cat] + 1 } else { $byCategory[$cat] = 1 }
        $r = [int]$f.Risk
        if     ($r -ge 70) { $riskBands['Critical (70-100)'] = $riskBands['Critical (70-100)'] + 1 }
        elseif ($r -ge 50) { $riskBands['High (50-69)']       = $riskBands['High (50-69)'] + 1 }
        elseif ($r -ge 30) { $riskBands['Medium (30-49)']     = $riskBands['Medium (30-49)'] + 1 }
        else               { $riskBands['Low (0-29)']         = $riskBands['Low (0-29)'] + 1 }
    }

    $objs = @($Inventory | Where-Object { $_.ObjType -ne 'DB' })
    $compatible = @($objs | Where-Object { $_.Status -eq 'No static findings' }).Count
    $withFindings = $objs.Count - $compatible
    $highRisk = @($Findings | Where-Object { $_.Risk -ge 50 }).Count

    $topRules = @()
    foreach ($g in @($Findings | Group-Object -Property RuleId | Sort-Object Count -Descending | Select-Object -First 10)) {
        $max = ($g.Group | Measure-Object -Property Risk -Maximum).Maximum
        $topRules += [pscustomobject]@{
            RuleId  = [string]$g.Name
            Title   = [string]($g.Group[0].Title)
            Status  = [string]($g.Group[0].Status)
            Count   = [int]$g.Count
            MaxRisk = [int]$max
        }
    }

    $perDb = @()
    foreach ($dbd in $DatabaseData) {
        $n = [string]$dbd.Database
        $fs  = @($Findings | Where-Object { $_.Database -eq $n })
        $dbs = @($objs   | Where-Object { $_.Database -eq $n })
        $maxRisk = 0
        if ($fs.Count -gt 0) { $maxRisk = ($fs | Measure-Object -Property Risk -Maximum).Maximum }
        $perDb += [pscustomobject]@{
            Name               = $n
            Objects            = $dbs.Count
            CompatibleObjects  = @($dbs | Where-Object { $_.Status -eq 'No static findings' }).Count
            Findings           = $fs.Count
            WillBreak          = @($fs | Where-Object { $_.Status -eq 'Will break' }).Count
            Deprecated         = @($fs | Where-Object { $_.Status -eq 'Deprecated usage' }).Count
            MaxRisk            = [int]$maxRisk
        }
    }

    $cov = @($script:AdvCoverage)
    $covOk = @($cov | Where-Object { $_.Status -eq 'Collected' }).Count
    $covFail = $cov.Count - $covOk

    return [pscustomobject]@{
        Tool                = 'SQL Upgrade Advisor'
        ToolVersion         = [string]$script:AdvToolVersion
        Server              = $serverName
        SourceVersion       = $srcVersion
        Target              = $TargetVersion
        TargetCompat        = $TargetCompat
        GeneratedAt         = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ElapsedSec          = [int]((Get-Date) - $script:AdvStartTime).TotalSeconds
        TotalFindings       = @($Findings).Count
        ByStatus            = $byStatus
        BySeverity          = $bySeverity
        ByCategory          = $byCategory
        RiskBands           = $riskBands
        WillBreak           = [int]$byStatus['Will break']
        NeedsAdjustment     = [int]$byStatus['Needs adjustment']
        SecurityConcern     = [int]$byStatus['Security concern']
        DeprecatedUsage     = [int]$byStatus['Deprecated usage']
        NeedsReview         = [int]$byStatus['Needs review']
        Modernization       = [int]$byStatus['Modernization']
        BlindSpots          = [int]$byStatus['Not assessable']
        HighRisk            = $highRisk
        DatabasesAssessed   = @($DatabaseData).Count
        ObjectsAssessed     = $objs.Count
        ObjectsWithFindings = $withFindings
        ObjectsCompatible   = $compatible
        RulesActive         = @($ActiveRules).Count
        RulesFired          = @($Findings | ForEach-Object { $_.RuleId } | Sort-Object -Unique).Count
        TopRules            = $topRules
        PerDatabase         = $perDb
        Coverage            = [pscustomobject]@{ Steps = $cov.Count; Collected = $covOk; Failed = $covFail }
    }
}

function Get-AdvBacklog {
    # Remediation backlog: one row per rule (work item), sorted by worst risk then reach.
    param($Findings)
    $items = @()
    foreach ($g in @($Findings | Group-Object -Property RuleId)) {
        $first = $g.Group[0]
        $risks = @($g.Group | ForEach-Object { [int]$_.Risk })
        $maxRisk = ($risks | Measure-Object -Maximum).Maximum
        $avgRisk = [int][Math]::Round(($risks | Measure-Object -Average).Average)
        $dbs = @($g.Group | ForEach-Object { [string]$_.Database } | Where-Object { $_ } | Sort-Object -Unique)
        $samples = @($g.Group | Sort-Object Risk -Descending | Select-Object -First 5 | ForEach-Object {
            $p = [string]$_.Object
            if ($_.Schema) { $p = '{0}.{1}' -f $_.Schema, $_.Object }
            if ($_.Database) { '{0}:{1}' -f $_.Database, $p } else { $p }
        })
        $sumMatches = ($g.Group | ForEach-Object { [int]$_.TotalMatches } | Measure-Object -Sum).Sum
        if ($null -eq $sumMatches) { $sumMatches = $g.Count }
        $items += [pscustomobject]@{
            RuleId         = [string]$g.Name
            Title          = [string]$first.Title
            Category       = [string]$first.Category
            Severity       = [string]$first.Severity
            Status         = [string]$first.Status
            Effort         = [string]$first.Effort
            Deterministic  = [bool]$first.Deterministic
            Objects        = [int]$g.Count
            TotalMatches   = [int]$sumMatches
            MaxRisk        = [int]$maxRisk
            AvgRisk        = $avgRisk
            Databases      = $dbs.Count
            SampleTargets  = ($samples -join '; ')
            Recommendation = [string]$first.Recommendation
            DocUrl         = [string]$first.DocUrl
        }
    }
    return , @($items | Sort-Object -Property @{Expression = 'MaxRisk'; Descending = $true}, @{Expression = 'Objects'; Descending = $true})
}

function Invoke-AdvRuleEngine {
    param(
        $InstanceData,
        [array]$DatabaseData,
        [array]$Rules,
        [int]$TargetMajor,
        [string]$TargetVersion,
        [int]$TargetCompat
    )

    $findings  = [System.Collections.Generic.List[object]]::new()
    $dedup     = @{}
    $ruleMap   = @{}
    $active    = [System.Collections.Generic.List[object]]::new()
    $rxCache   = @{}
    $rxFailed  = @{}
    $rxTimeout = [TimeSpan]::FromSeconds(5)

    # ---- target gating ------------------------------------------------------------
    foreach ($r in $Rules) {
        if ($TargetMajor -ge [int]$r.MinTarget -and $TargetMajor -le [int]$r.MaxTarget) {
            $ruleMap[$r.Id] = $r
            $active.Add($r)
        }
    }
    Write-AdvLog "Rules active for SQL Server ${TargetVersion}: $($active.Count) of $($Rules.Count)" 'OK'
    Add-AdvCoverage -Name 'Rule engine (target-gated knowledge base)' -Ok $true `
        -Detail "$($active.Count)/$($Rules.Count) rules applicable to target $TargetVersion (compat $TargetCompat)"

    # ---- emit helper: one finding per (rule, object), merged TotalMatches ----------
    function Add-AdvResult {
        param(
            [string]$RuleId,
            [string]$Database = '',
            [string]$Schema = '',
            [string]$Object = '',
            [string]$ObjType = '',
            [string]$ObjTypeDesc = '',
            [int]$Line = 0,
            [string]$Evidence = '',
            [string]$StatusOverride = '',
            [string]$SeverityOverride = '',
            [string]$Confidence = '',
            [long]$Hotness = 0,
            [int]$TotalMatches = 1
        )
        if (-not $ruleMap.ContainsKey($RuleId)) { return }   # not applicable to this target
        $rule = $ruleMap[$RuleId]
        $key = '{0}|{1}|{2}|{3}|{4}' -f $RuleId, $Database, $Schema, $Object, $ObjType
        if ($dedup.ContainsKey($key)) {
            $f = $dedup[$key]
            if ($TotalMatches -gt 1) { $f.TotalMatches = [int]$f.TotalMatches + ($TotalMatches - 1) }
            if ($Hotness -gt $f.Hotness) { $f.Hotness = $Hotness }
            return
        }
        $f = New-AdvFinding -Rule $rule -Database $Database -Schema $Schema -Object $Object `
            -ObjType $ObjType -ObjTypeDesc $ObjTypeDesc -Line $Line -Evidence $Evidence `
            -Confidence $Confidence -TotalMatches $TotalMatches
        $f.Status = Get-AdvRuleStatus -Rule $rule -Override $StatusOverride
        if ($SeverityOverride) { $f.Severity = $SeverityOverride }
        $f.Hotness = $Hotness
        $dedup[$key] = $f
        $findings.Add($f)
    }

    # ---- module scanner: regex over comment/string-stripped text ------------------
    function Add-AdvScanFindings {
        param(
            [array]$RulesToScan,
            [string]$Text,
            [string]$Database,
            [string]$Schema,
            [string]$Object,
            [string]$ObjType,
            [string]$ObjTypeDesc,
            [long]$Hotness,
            [string]$EvidencePrefix = ''
        )
        if (-not $RulesToScan) { return }
        if ([string]::IsNullOrWhiteSpace($Text)) { return }

        $nl    = New-LineIndex -Text $Text
        $lines = [regex]::Split($Text, "`r?`n")
        $cleanCode = Hide-SqlNoise -Text $Text -KeepStrings $false
        $cleanStr  = $null

        foreach ($rule in $RulesToScan) {
            if ([string]::IsNullOrEmpty($rule.Pattern)) { continue }        # structural rule
            if (-not (Test-AdvAppliesTo -Rule $rule -ObjType $ObjType)) { continue }

            if ($rule.Scan -eq 'NoComments') {
                if ($null -eq $cleanStr) { $cleanStr = Hide-SqlNoise -Text $Text -KeepStrings $true }
                $scanText = $cleanStr
            } else {
                $scanText = $cleanCode
            }
            if ([string]::IsNullOrEmpty($scanText)) { continue }

            $rx = $null
            if ($rxCache.ContainsKey($rule.Id)) {
                $rx = $rxCache[$rule.Id]
            } else {
                try {
                    $rx = [regex]::new($rule.Pattern,
                        ([Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::CultureInvariant),
                        $rxTimeout)
                } catch {
                    Write-AdvLog "Rule $($rule.Id): regex failed to compile - $($_.Exception.Message)" 'WARN'
                    $rx = $null
                }
                $rxCache[$rule.Id] = $rx
            }
            if ($null -eq $rx) { continue }

            $ms = $null
            try { $ms = $rx.Matches($scanText) }
            catch {
                if (-not $rxFailed.ContainsKey($rule.Id)) {
                    $rxFailed[$rule.Id] = $_.Exception.Message
                    Write-AdvLog "Rule $($rule.Id): regex timeout on $Database.$Schema.$Object" 'WARN'
                }
                continue
            }
            if ($ms.Count -eq 0) { continue }

            $count = 0; $firstLine = 0; $firstText = ''
            foreach ($m in $ms) {
                $li = Get-LineFromIndex -NewLines $nl -Index $m.Index
                $lt = ''
                if ($li -ge 1 -and $li -le $lines.Count) { $lt = $lines[$li - 1] }
                if ($rule.LineExclusion -and $lt -match $rule.LineExclusion) { continue }
                $count++
                if ($count -eq 1) { $firstLine = $li; $firstText = $lt.Trim() }
                if ($rule.Once) { break }
            }
            if ($count -eq 0) { continue }

            $ev = '{0}line {1}: {2}' -f $EvidencePrefix, $firstLine, (Truncate-Adv -Text (Hide-AdvSecret -Text $firstText) -Max 240)
            if ($count -gt 1) { $ev += " (+$($count - 1) more match(es))" }
            Add-AdvResult -RuleId $rule.Id -Database $Database -Schema $Schema -Object $Object `
                -ObjType $ObjType -ObjTypeDesc $ObjTypeDesc -Line $firstLine -Evidence $ev `
                -Hotness $Hotness -TotalMatches $count
        }
    }

    $moduleRules = @($active | Where-Object { $_.Scope -eq 'Module' })
    $trgRules    = @($active | Where-Object { $_.Scope -eq 'TriggerResult' })

    # =================================================================================
    # PER-DATABASE ANALYSIS
    # =================================================================================
    $dbRows = @{}
    foreach ($row in @($InstanceData.Databases | Where-Object { $_ })) {
        if ($row.name) { $dbRows[[string]$row.name] = $row }
    }

    foreach ($dbd in $DatabaseData) {
        $dbName = [string]$dbd.Database
        $row = $null
        if ($dbRows.ContainsKey($dbName)) { $row = $dbRows[$dbName] }
        Write-AdvLog "Analyzing database: $dbName"

        $hot = @{}
        $dbHot = [long]0
        foreach ($st in @($dbd.ObjectStats | Where-Object { $_ })) {
            $hot[[string]$st.object_id] = [long]$st.exec_count
            $dbHot += [long]$st.exec_count
        }
        $objById = @{}
        foreach ($o in @($dbd.Objects | Where-Object { $_ })) { $objById[[string]$o.object_id] = $o }

        # ---- database-level structural checks -----------------------------------
        if ($row) {
            $compat = Get-AdvInt $row.compatibility_level
            if ($compat -ge 0 -and $compat -lt $TargetCompat) {
                Add-AdvResult -RuleId 'DB-CMPT-001' -Database $dbName -Object $dbName -ObjType 'DB' `
                    -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence ('compatibility_level = {0}; default for SQL Server {1} is {2}. Raise in stages with a Query Store baseline before/after each step.' -f $compat, $TargetVersion, $TargetCompat)
            }
            if ($compat -ge 0 -and $compat -le 120) {
                Add-AdvResult -RuleId 'DB-CMPT-002' -Database $dbName -Object $dbName -ObjType 'DB' `
                    -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence ('compatibility_level = {0} (levels 100/110/120 are deprecated).' -f $compat)
            }
            $off = @()
            if ((Get-AdvInt $row.is_ansi_nulls_on) -eq 0)               { $off += 'ANSI_NULLS OFF' }
            if ((Get-AdvInt $row.is_ansi_padding_on) -eq 0)             { $off += 'ANSI_PADDING OFF' }
            if ((Get-AdvInt $row.is_concat_null_yields_null_on) -eq 0)  { $off += 'CONCAT_NULL_YIELDS_NULL OFF' }
            if ($off.Count -gt 0) {
                Add-AdvResult -RuleId 'DB-OPT-001' -Database $dbName -Object $dbName -ObjType 'DB' `
                    -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence ('deprecated database options set OFF: {0}' -f ($off -join ', '))
            }
            if ((Get-AdvInt $row.is_trustworthy_on) -eq 1) {
                Add-AdvResult -RuleId 'DB-TRUST-001' -Database $dbName -Object $dbName -ObjType 'DB' `
                    -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence 'TRUSTWORTHY = ON (privilege-escalation surface and the legacy CLR trust workaround)'
            }
            if ((Get-AdvInt $row.is_remote_data_archive_enabled) -eq 1) {
                Add-AdvResult -RuleId 'DB-STRETCH-001' -Database $dbName -Object $dbName -ObjType 'DB' `
                    -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence 'is_remote_data_archive_enabled = 1 - Stretch Database is discontinued (July 2024) and unavailable on the target'
            }
        }

        $qs = [string]$dbd.QueryStore
        if ($qs -ne 'READ_WRITE') {
            Add-AdvResult -RuleId 'DB-QS-001' -Database $dbName -Object $dbName -ObjType 'DB' `
                -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                -Evidence ("Query Store actual_state = '{0}' - no plan/runtime baseline for the upgrade" -f $qs)
        }

        $ftRows = @($dbd.FullText | Where-Object { $_ })
        if ($ftRows.Count -gt 0) {
            $ftList = ($ftRows | ForEach-Object { '{0}.{1}' -f $_.schema_name, $_.table_name }) -join ', '
            Add-AdvResult -RuleId 'DB-FT-001' -Database $dbName -Object $dbName -ObjType 'DB' `
                -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                -Evidence ('full-text indexes present; SQL Server 2025 removes legacy word breakers - rebuild required after upgrade: {0}' -f $ftList)
        }

        foreach ($es in @($dbd.ExternalSources | Where-Object { $_ })) {
            $loc = [string]$es.location
            $td  = [string]$es.type_desc
            if ($td -match '(?i)hadoop' -or $loc -match '(?i)hdfs|wasb|abfs|blob\.core|dfs\.core|namenode') {
                $used = @($dbd.ExternalTables | Where-Object { $_ -and $_.data_source_name -eq $es.name })
                $usedTxt = 'none'
                if ($used.Count -gt 0) { $usedTxt = ($used | ForEach-Object { '{0}.{1}' -f $_.schema_name, $_.table_name }) -join ', ' }
                Add-AdvResult -RuleId 'DB-PB-001' -Database $dbName -Object ([string]$es.name) -ObjType 'EXTSRC' `
                    -ObjTypeDesc 'EXTERNAL DATA SOURCE' -Hotness $dbHot `
                    -Evidence ('type = {0}, location = {1}; external tables using it: {2}' -f $td, $loc, $usedTxt)
            }
        }

        foreach ($m in @($InstanceData.Mirroring | Where-Object { $_ })) {
            if ([string]$m.database_name -ieq $dbName) {
                Add-AdvResult -RuleId 'DB-MIRROR-001' -Database $dbName -Object $dbName -ObjType 'DB' `
                    -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence ('mirroring {0} with partner {1} (state: {2})' -f $m.mirroring_role_desc, $m.mirroring_partner_name, $m.mirroring_state_desc)
            }
        }

        # ---- columns: deprecated LOB types / timestamp synonym -------------------
        $colMap = @{}
        foreach ($c in @($dbd.Columns | Where-Object { $_ })) {
            $oid = [string]$c.object_id
            if (-not $colMap.ContainsKey($oid)) { $colMap[$oid] = [System.Collections.Generic.List[object]]::new() }
            $colMap[$oid].Add($c)
        }
        foreach ($oid in $colMap.Keys) {
            if (-not $objById.ContainsKey($oid)) { continue }
            $o = $objById[$oid]
            $h = [long]0
            if ($hot.ContainsKey($oid)) { $h = $hot[$oid] }
            $lob = @($colMap[$oid] | Where-Object {
                $tn = if ($_.system_data_type) { [string]$_.system_data_type } else { [string]$_.data_type }
                $tn -eq 'text' -or $tn -eq 'ntext' -or $tn -eq 'image'
            })
            if ($lob.Count -gt 0) {
                $names = ($lob | ForEach-Object { $_.column_name }) -join ', '
                Add-AdvResult -RuleId 'TBL-LOBCOL-001' -Database $dbName -Schema ([string]$o.schema_name) `
                    -Object ([string]$o.name) -ObjType 'U' -ObjTypeDesc ([string]$o.type_desc) -Hotness $h `
                    -Evidence ('columns using deprecated LOB types (text/ntext/image): {0}' -f $names)
            }
            $tsc = @($colMap[$oid] | Where-Object {
                $tn = if ($_.system_data_type) { [string]$_.system_data_type } else { [string]$_.data_type }
                $tn -eq 'timestamp'
            })
            if ($tsc.Count -gt 0) {
                $names = ($tsc | ForEach-Object { $_.column_name }) -join ', '
                Add-AdvResult -RuleId 'TBL-TSCOL-001' -Database $dbName -Schema ([string]$o.schema_name) `
                    -Object ([string]$o.name) -ObjType 'U' -ObjTypeDesc ([string]$o.type_desc) -Hotness $h `
                    -Evidence ('columns declared with the deprecated timestamp (rowversion) synonym: {0}' -f $names)
            }
        }

        # ---- objects: legacy defaults/rules, modules, triggers, blind spots ------
        foreach ($o in @($dbd.Objects | Where-Object { $_ })) {
            $type  = [string]$o.type
            $token = Get-AdvTypeToken -Type $type
            $oid   = [string]$o.object_id
            $h = [long]0
            if ($hot.ContainsKey($oid)) { $h = $hot[$oid] }
            $schema = [string]$o.schema_name
            $name   = [string]$o.name

            if ($type -eq 'D' -or $type -eq 'R') {
                # type D covers both deprecated unbound CREATE DEFAULT objects (parent_object_id = 0)
                # and modern DEFAULT constraints (parent_object_id > 0). Only the unbound form is deprecated.
                if ($type -eq 'D' -and (Get-AdvInt $o.parent_object_id) -gt 0) { continue }
                $kind = 'RULE'
                if ($type -eq 'D') { $kind = 'DEFAULT' }
                Add-AdvResult -RuleId 'OBJ-DEFRULE-001' -Database $dbName -Schema $schema -Object $name `
                    -ObjType $type -ObjTypeDesc ([string]$o.type_desc) -Hotness $h `
                    -Evidence ('legacy unbound {0} object ''{1}.{2}'' (CREATE {0} / sp_bindefault / sp_bindrule). DEFAULT constraints are not flagged.' -f $kind, $schema, $name)
                continue
            }

            $isModule = ($type -eq 'P' -or $type -eq 'PC' -or $type -eq 'FN' -or $type -eq 'IF' -or
                         $type -eq 'TF' -or $type -eq 'TR' -or $type -eq 'V' -or $type -eq 'X')
            if (-not $isModule) { continue }

            $def   = [string]$o.definition
            $isClr = $false
            try { $isClr = [bool]$o.is_clr } catch { }

            $withheld = $false
            if ($o.PSObject.Properties.Name -contains 'has_definition') { $withheld = ((Get-AdvInt $o.has_definition) -eq 1) }
            if (-not $isClr -and [string]::IsNullOrWhiteSpace($def)) {
                if ($withheld) { continue }
                Add-AdvResult -RuleId 'BLIND-ENC-001' -Database $dbName -Schema $schema -Object $name `
                    -ObjType $token -ObjTypeDesc ([string]$o.type_desc) -Hotness $h -StatusOverride 'Not assessable' `
                    -Evidence ('definition is NULL in sys.sql_modules for ''{0}.{1}'' - module is encrypted (WITH ENCRYPTION) or not visible; its content was NOT assessed' -f $schema, $name)
                continue
            }
            if ([string]::IsNullOrWhiteSpace($def)) { continue }

            Add-AdvScanFindings -RulesToScan $moduleRules -Text $def -Database $dbName -Schema $schema `
                -Object $name -ObjType $token -ObjTypeDesc ([string]$o.type_desc) -Hotness $h
            $frags = Get-AdvSqlFragments -Text $def
            foreach ($frag in $frags) {
                Add-AdvScanFindings -RulesToScan $moduleRules -Text ([string]$frag) -Database $dbName -Schema $schema `
                    -Object $name -ObjType $token -ObjTypeDesc ([string]$o.type_desc) -Hotness $h `
                    -EvidencePrefix 'dynamic SQL literal, '
            }

            if ($type -eq 'TR' -and $trgRules.Count -gt 0) {
                $selIdx = Find-AdvTriggerResultSelects -Text $def
                if ($selIdx.Count -gt 0) {
                    $nlT    = New-LineIndex -Text $def
                    $linesT = [regex]::Split($def, "`r?`n")
                    $liT = Get-LineFromIndex -NewLines $nlT -Index $selIdx[0]
                    $ltT = ''
                    if ($liT -ge 1 -and $liT -le $linesT.Count) { $ltT = $linesT[$liT - 1] }
                    $evT = 'line {0}: {1}' -f $liT, (Truncate-Adv -Text $ltT.Trim() -Max 240)
                    if ($selIdx.Count -gt 1) { $evT += " (+$($selIdx.Count - 1) more result-set SELECT(s))" }
                    foreach ($trule in $trgRules) {
                        if (-not (Test-AdvAppliesTo -Rule $trule -ObjType 'TR')) { continue }
                        Add-AdvResult -RuleId $trule.Id -Database $dbName -Schema $schema -Object $name `
                            -ObjType 'TR' -ObjTypeDesc ([string]$o.type_desc) -Line $liT -Evidence $evT `
                            -Hotness $h -TotalMatches $selIdx.Count
                    }
                }
            }
        }

        # ---- synonyms ------------------------------------------------------------
        foreach ($s in @($dbd.Synonyms | Where-Object { $_ })) {
            $base = [string]$s.base_object_name
            $dots = ([regex]::Matches($base, '\.')).Count
            if ($dots -ge 2) {
                Add-AdvResult -RuleId 'SYN-CROSS-001' -Database $dbName -Schema ([string]$s.schema_name) `
                    -Object ([string]$s.name) -ObjType 'SN' -ObjTypeDesc 'SYNONYM' `
                    -Evidence ("base_object_name = '{0}' ({1}-part name crosses a database/server boundary)" -f $base, ($dots + 1))
            }
        }

        # ---- CLR assemblies: trust-path severity logic ---------------------------
        $ownerSysadmin = ((Get-AdvInt $dbd.OwnerIsSysadmin) -eq 1)
        $ownerUnsafe   = ((Get-AdvInt $dbd.OwnerHasUnsafe) -eq 1)
        $trustworthy   = $false
        if ($row) { $trustworthy = ((Get-AdvInt $row.is_trustworthy_on) -eq 1) }

        foreach ($a in @($dbd.Assemblies | Where-Object { $_ })) {
            $an = [string]$a.name
            $signed = $false
            try { $signed = [bool]$a.is_signed } catch { }
            $ps = [string]$a.permission_set_desc

            if ($signed) {
                Add-AdvResult -RuleId 'CLR-001' -Database $dbName -Object $an -ObjType 'ASM' `
                    -ObjTypeDesc 'ASSEMBLY' -SeverityOverride 'Medium' -StatusOverride 'Needs review' `
                    -Evidence ("assembly '{0}' is signed - verify its certificate/asymmetric-key principal has UNSAFE ASSEMBLY in master or its hash is registered in sys.trusted_assemblies" -f $an)
            } else {
                $legacy = ''
                if ($trustworthy -and $ownerSysadmin) {
                    $legacy = ' The legacy TRUSTWORTHY + sysadmin-owner trust path exists but is IGNORED when clr strict security = 1.'
                }
                if ($ownerUnsafe) {
                    $legacy += ' The owner holds UNSAFE ASSEMBLY - not sufficient for unsigned assemblies under clr strict security.'
                }
                Add-AdvResult -RuleId 'CLR-001' -Database $dbName -Object $an -ObjType 'ASM' `
                    -ObjTypeDesc 'ASSEMBLY' -SeverityOverride 'High' -StatusOverride 'Will break' `
                    -Evidence ("assembly '{0}' is UNSIGNED - with clr strict security = 1 (default since SQL Server 2017) the engine treats every assembly as UNSAFE; load/ALTER will fail on the target.{1} Trusted assemblies registered on this instance: {2}. The hash is not compared here because assembly bytes are not collected." -f $an, $legacy, @($InstanceData.TrustedAssemblies).Count)
            }
            if ($ps -match 'EXTERNAL_ACCESS|UNSAFE') {
                Add-AdvResult -RuleId 'CLR-002' -Database $dbName -Object $an -ObjType 'ASM' `
                    -ObjTypeDesc 'ASSEMBLY' -StatusOverride 'Security concern' `
                    -Evidence ("assembly '{0}' permission_set = {1} - PERMISSION_SET is ignored at runtime under clr strict security; re-validate trust and least privilege on the target" -f $an, $ps)
            }
        }

        $fs = $null
        if ($dbd.ContainsKey('FeatureSurface')) { $fs = $dbd.FeatureSurface }
        if ($fs) {
            if ((Get-AdvInt $fs.is_cdc_enabled) -eq 1 -or (Get-AdvInt $fs.cdc_tables) -gt 0) {
                Add-AdvResult -RuleId 'DB-CDC-001' -Database $dbName -Object $dbName -ObjType 'DB' -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence ('CDC enabled={0}; tracked tables={1}' -f (Get-AdvInt $fs.is_cdc_enabled), (Get-AdvInt $fs.cdc_tables))
            }
            if ((Get-AdvInt $fs.change_tracking_tables) -gt 0) {
                Add-AdvResult -RuleId 'DB-CT-001' -Database $dbName -Object $dbName -ObjType 'DB' -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence ('change-tracking tables={0}' -f (Get-AdvInt $fs.change_tracking_tables))
            }
            if ((Get-AdvInt $fs.memory_optimized_tables) -gt 0) {
                Add-AdvResult -RuleId 'DB-IMOLTP-001' -Database $dbName -Object $dbName -ObjType 'DB' -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence ('memory-optimized tables={0}' -f (Get-AdvInt $fs.memory_optimized_tables))
            }
            if ((Get-AdvInt $fs.filetables) -gt 0 -or (Get-AdvInt $fs.filestream_filegroups) -gt 0) {
                Add-AdvResult -RuleId 'DB-FILE-001' -Database $dbName -Object $dbName -ObjType 'DB' -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence ('FileTables={0}; FILESTREAM filegroups={1}' -f (Get-AdvInt $fs.filetables), (Get-AdvInt $fs.filestream_filegroups))
            }
            if ((Get-AdvInt $fs.broker_queues) -gt 0) {
                Add-AdvResult -RuleId 'DB-BROKER-001' -Database $dbName -Object $dbName -ObjType 'DB' -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence ('Service Broker queues={0}; broker enabled={1}' -f (Get-AdvInt $fs.broker_queues), (Get-AdvInt $fs.is_broker_enabled))
            }
            if ((Get-AdvInt $fs.partition_functions) -gt 0) {
                Add-AdvResult -RuleId 'DB-PART-001' -Database $dbName -Object $dbName -ObjType 'DB' -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence ('partition functions={0}' -f (Get-AdvInt $fs.partition_functions))
            }
            if ((Get-AdvInt $fs.xml_schema_collections) -gt 0) {
                Add-AdvResult -RuleId 'DB-XML-001' -Database $dbName -Object $dbName -ObjType 'DB' -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence ('XML schema collections={0}' -f (Get-AdvInt $fs.xml_schema_collections))
            }
            if ((Get-AdvInt $fs.has_database_master_key) -eq 1) {
                Add-AdvResult -RuleId 'DB-DMK-001' -Database $dbName -Object $dbName -ObjType 'DB' -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence 'database master key is present'
            }
            if ((Get-AdvInt $fs.column_master_keys) -gt 0 -or (Get-AdvInt $fs.column_encryption_keys) -gt 0) {
                Add-AdvResult -RuleId 'DB-AE-001' -Database $dbName -Object $dbName -ObjType 'DB' -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                    -Evidence ('column master keys={0}; column encryption keys={1}' -f (Get-AdvInt $fs.column_master_keys), (Get-AdvInt $fs.column_encryption_keys))
            }
        }
        foreach ($sku in @($dbd.SkuFeatures)) {
            if (-not $sku -or -not $sku.feature_name) { continue }
            Add-AdvResult -RuleId 'DB-SKU-001' -Database $dbName -Object ([string]$sku.feature_name) -ObjType 'SKU' -ObjTypeDesc 'SKU FEATURE' -Hotness $dbHot `
                -Evidence ('persisted SKU feature ''{0}'' (feature_id {1})' -f $sku.feature_name, $sku.feature_id)
        }
        $qsBase = $null
        if ($dbd.ContainsKey('QueryStoreBaseline')) { $qsBase = $dbd.QueryStoreBaseline }
        if ($qsBase -and (Get-AdvInt $qsBase.forced_plans) -gt 0) {
            Add-AdvResult -RuleId 'DB-QSFORCE-001' -Database $dbName -Object $dbName -ObjType 'DB' -ObjTypeDesc 'DATABASE' -Hotness $dbHot `
                -Evidence ('Query Store queries={0}; forced plans={1}. This is a baseline count, not a target comparison.' -f (Get-AdvInt $qsBase.query_count), (Get-AdvInt $qsBase.forced_plans))
        }
    }

    # =================================================================================
    # INSTANCE-LEVEL ANALYSIS
    # =================================================================================
    foreach ($ep in @($InstanceData.Endpoints)) {
        if (-not $ep) { continue }
        $kind = [string]$ep.type_desc
        $ev = ('endpoint {0}: type={1}, protocol={2}, state={3}' -f $ep.name, $kind, $ep.protocol_desc, $ep.state_desc)
        if ($kind -match '(?i)SOAP|HTTP') {
            Add-AdvResult -RuleId 'EP-SOAP-001' -Object ([string]$ep.name) -ObjType 'EP' -ObjTypeDesc 'ENDPOINT' -Evidence $ev
        } else {
            Add-AdvResult -RuleId 'EP-OTHER-001' -Object ([string]$ep.name) -ObjType 'EP' -ObjTypeDesc 'ENDPOINT' -Evidence $ev
        }
    }
    foreach ($trg in @($InstanceData.ServerTriggers)) {
        if (-not $trg) { continue }
        $body = [string]$trg.definition
        if ([string]::IsNullOrWhiteSpace($body)) {
            Add-AdvResult -RuleId 'SRV-TRG-001' -Object ([string]$trg.name) -ObjType 'SRVTRG' -ObjTypeDesc 'SERVER TRIGGER' `
                -Evidence ('server trigger {0} has no readable definition (disabled={1})' -f $trg.name, $trg.is_disabled)
        } else {
            Add-AdvScanFindings -RulesToScan $moduleRules -Text $body -Database '' -Schema '(server)' `
                -Object ([string]$trg.name) -ObjType 'SRVTRG' -ObjTypeDesc 'SERVER TRIGGER' `
                -EvidencePrefix ("server trigger '{0}', " -f $trg.name)
            Add-AdvResult -RuleId 'SRV-TRG-001' -Object ([string]$trg.name) -ObjType 'SRVTRG' -ObjTypeDesc 'SERVER TRIGGER' `
                -Evidence ('server trigger {0} is present (disabled={1}) and does not move with a database backup' -f $trg.name, $trg.is_disabled)
        }
    }
    foreach ($cred in @($InstanceData.Credentials)) {
        if (-not $cred -or -not $cred.name) { continue }
        Add-AdvResult -RuleId 'CRED-001' -Object ([string]$cred.name) -ObjType 'CRED' -ObjTypeDesc 'CREDENTIAL' `
            -Evidence ('credential {0}, identity {1}. The secret was not collected.' -f $cred.name, $cred.credential_identity)
    }
    foreach ($px in @($InstanceData.AgentProxies)) {
        if (-not $px -or -not $px.name) { continue }
        Add-AdvResult -RuleId 'PROXY-001' -Object ([string]$px.name) -ObjType 'PROXY' -ObjTypeDesc 'AGENT PROXY' `
            -Evidence ('proxy {0}, enabled={1}. Recreate it with its credential on the target.' -f $px.name, $px.enabled)
    }
    foreach ($ll in @($InstanceData.LinkedLogins)) {
        if (-not $ll) { continue }
        if ((Get-AdvInt $ll.uses_self_credential) -eq 0) {
            Add-AdvResult -RuleId 'LS-LOGIN-001' -Object ([string]$ll.server_name) -ObjType 'LS' -ObjTypeDesc 'LINKED SERVER' `
                -Evidence ('linked server {0} has a non-self login mapping (remote_name={1}). No password was collected.' -f $ll.server_name, $ll.remote_name)
        }
    }
    foreach ($ls in @($InstanceData.LinkedServers | Where-Object { $_ })) {
        if ((Get-AdvInt $ls.is_linked) -eq 0) { continue }
        $lsName = [string]$ls.name
        $prov = [string]$ls.provider
        $prod = [string]$ls.product
        $ev = ("provider = '{0}', product = '{1}', data_source = '{2}'" -f $prov, $prod, [string]$ls.data_source)
        if ($prov -match '(?i)sqloledb' -or $prod -match '(?i)sqloledb') {
            Add-AdvResult -RuleId 'LS-SQLOLEDB-001' -Object $lsName -ObjType 'LS' -ObjTypeDesc 'LINKED SERVER' -Evidence $ev
        }
        if ($prov -match '(?i)sqlncli' -or $prod -match '(?i)sqlncli|native client') {
            Add-AdvResult -RuleId 'LS-SNAC-001' -Object $lsName -ObjType 'LS' -ObjTypeDesc 'LINKED SERVER' -Evidence $ev
        }
        $sqlLinked = ($prov -match '(?i)msoledbsql|sqlncli|sqloledb') -or ($prod -match '(?i)sql server|sqlncli|sqloledb|msoledbsql')
        if ($sqlLinked) {
            Add-AdvResult -RuleId 'LS-ENC-001' -Object $lsName -ObjType 'LS' -ObjTypeDesc 'LINKED SERVER' `
                -StatusOverride 'Needs review' -SeverityOverride 'Medium' `
                -Evidence ("{0} - SQL linked server. SQL Server 2025 / OLE DB 19 secure defaults can break this when Encrypt is not explicit. Confirm the driver major version; this is not a proven break." -f $ev)
        }
    }

    $hasReplPublication = $false
    if ($InstanceData.ContainsKey('HasReplicationPublication')) { $hasReplPublication = [bool]$InstanceData.HasReplicationPublication }
    $distSource = ''
    if ($InstanceData.ContainsKey('ReplicationDistributorSource')) { $distSource = [string]$InstanceData.ReplicationDistributorSource }
    $localServer = ''
    if ($InstanceData.Instance -and $InstanceData.Instance.ServerName) { $localServer = [string]$InstanceData.Instance.ServerName }
    $remoteDistributor = $false
    if ($InstanceData.HasReplicationDist -and $distSource -and $localServer -and ($distSource -ne $localServer)) { $remoteDistributor = $true }
    if ($remoteDistributor -or $InstanceData.HasDistributionDb -or $InstanceData.HasReplicationDist -or $hasReplPublication) {
        $distNames = ''
        if ($InstanceData.ContainsKey('DistributionDatabases')) { $distNames = [string]$InstanceData.DistributionDatabases }
        if (-not $distNames) { $distNames = '(none listed)' }
        $replEvidence = ('distribution database present: {0} [{1}]; repl_distributor data source: {2}; published or subscribed database present: {3}.' -f [bool]$InstanceData.HasDistributionDb, $distNames, $(if ($distSource) { $distSource } else { '(not registered)' }), $hasReplPublication)
        if ($remoteDistributor) {
            Add-AdvResult -RuleId 'REP-001' -Object 'Replication' -ObjType 'INSTANCE' -ObjTypeDesc 'INSTANCE' `
                -Evidence ($replEvidence + ' Remote distributor confirmed — SQL Server 2025 requires a trusted certificate or trust_distributor_certificate.')
        } else {
            Add-AdvResult -RuleId 'REP-001' -Object 'Replication' -ObjType 'INSTANCE' -ObjTypeDesc 'INSTANCE' `
                -StatusOverride 'Needs review' -SeverityOverride 'Medium' `
                -Evidence ($replEvidence + ' A remote distributor was not confirmed, so this is not treated as a 2025 certificate break. Verify whether the distributor is remote.')
        }
    }
    $lsPri = Get-AdvInt $InstanceData.LogShippingPrimary
    $lsSec = Get-AdvInt $InstanceData.LogShippingSecondary
    $lsRemote = 0
    if ($InstanceData.ContainsKey('LogShippingRemoteMonitor')) { $lsRemote = Get-AdvInt $InstanceData.LogShippingRemoteMonitor }
    if ($lsRemote -gt 0) {
        Add-AdvResult -RuleId 'LSH-001' -Object 'Log shipping' -ObjType 'INSTANCE' -ObjTypeDesc 'INSTANCE' `
            -Evidence ('log shipping primaries: {0}, secondaries: {1}, remote monitors: {2} — a remote monitor can fail after upgrade to SQL Server 2025 without a trusted certificate' -f $lsPri, $lsSec, $lsRemote)
    } elseif (($lsPri + $lsSec) -gt 0) {
        Add-AdvResult -RuleId 'LSH-001' -Object 'Log shipping' -ObjType 'INSTANCE' -ObjTypeDesc 'INSTANCE' `
            -StatusOverride 'Needs review' -SeverityOverride 'Low' `
            -Evidence ('log shipping primaries: {0}, secondaries: {1}, remote monitors: 0 — monitor looks local or was not recorded. The 2025 certificate break applies to a remote monitor.' -f $lsPri, $lsSec)
    }

    $cfg = @{}
    foreach ($c in @($InstanceData.Configs | Where-Object { $_ })) {
        if ($c.name) { $cfg[[string]$c.name] = Get-AdvInt $c.value_in_use }
    }
    if ($cfg.ContainsKey('external scripts enabled') -and $cfg['external scripts enabled'] -ge 1) {
        Add-AdvResult -RuleId 'MLS-001' -Object 'Machine Learning Services' -ObjType 'INSTANCE' -ObjTypeDesc 'INSTANCE' `
            -Evidence 'external scripts enabled = 1 - SQL Server 2022+ setup no longer ships R/Python runtimes/packages; sp_execute_external_script fails until they are reinstalled'
    }
    if ($cfg.ContainsKey('lightweight pooling') -and $cfg['lightweight pooling'] -ge 1) {
        Add-AdvResult -RuleId 'POOL-001' -Object 'Lightweight pooling' -ObjType 'INSTANCE' -ObjTypeDesc 'INSTANCE' `
            -Evidence 'lightweight pooling (fiber mode) = 1 - deprecated in SQL Server 2025; disable before upgrade'
    }

    foreach ($drow in @($InstanceData.Databases | Where-Object { $_ })) {
        $n = [string]$drow.name
        if ([string]::IsNullOrEmpty($n)) { continue }
        $dqsExact = @('DQS_MAIN', 'DQS_PROJECTS', 'DQS_STAGING_DATA')
        if ($dqsExact -contains $n.ToUpperInvariant()) {
            $rid = 'DQS-002'
            if ($TargetMajor -ge 17) { $rid = 'DQS-001' }
            $verb = if ($TargetMajor -ge 17) { 'DQS is removed in SQL Server 2025 and setup fails while it is installed.' } else { 'DQS is deprecated and is removed in SQL Server 2025.' }
            Add-AdvResult -RuleId $rid -Database $n -Object $n -ObjType 'DB' -ObjTypeDesc 'DATABASE' `
                -Evidence ("database '{0}' is a Data Quality Services catalog. {1}" -f $n, $verb)
        } elseif ($n.ToUpperInvariant() -eq 'MDS') {
            $rid = 'MDS-002'
            if ($TargetMajor -ge 17) { $rid = 'MDS-001' }
            $verb = if ($TargetMajor -ge 17) { 'MDS is removed in SQL Server 2025.' } else { 'MDS is deprecated and is removed in SQL Server 2025.' }
            Add-AdvResult -RuleId $rid -Database $n -Object $n -ObjType 'DB' -ObjTypeDesc 'DATABASE' `
                -Evidence ("database '{0}' matches the default Master Data Services database name. {1} Confirm the mdm schema before treating this as a blocker." -f $n, $verb)
        } elseif ($n -match '(?i)dqs|mds|mdm|master\s*data') {
            Add-AdvResult -RuleId 'INST-DQSDB-001' -Database $n -Object $n -ObjType 'DB' -ObjTypeDesc 'DATABASE' `
                -Evidence ("database '{0}' only resembles a DQS or MDS name. This is not install evidence and is not a blocker. Confirm the catalog objects manually." -f $n)
        }
    }

    foreach ($tf in @($InstanceData.TraceFlags | Where-Object { $_ })) {
        Add-AdvResult -RuleId 'TF-001' -Object ('Trace flag {0}' -f $tf.Flag) -ObjType 'TF' -ObjTypeDesc 'TRACE FLAG' `
            -Evidence ('flag {0}: status={1}, global={2}, session={3} - flags are version-specific and are carried over blindly by upgrade' -f $tf.Flag, $tf.Status, $tf.Global, $tf.Session)
    }

    foreach ($dc in @($InstanceData.DeprecatedCounters | Where-Object { $_ })) {
        $hits = [long]0
        try { $hits = [long]$dc.hits } catch { }
        if ($hits -le 0) { continue }
        Add-AdvResult -RuleId 'RUNTIME-DEPR-001' -Object ([string]$dc.feature) -ObjType 'RT' -ObjTypeDesc 'RUNTIME COUNTER' `
            -Hotness $hits `
            -Evidence ("counter '{0}' = {1} hits since instance start - real runtime usage, often inside dynamic SQL that static analysis cannot see" -f $dc.feature, $hits)
    }

    # ---- SQL Agent jobs ---------------------------------------------------------
    $jobsByName = @{}
    foreach ($j in @($InstanceData.AgentJobs | Where-Object { $_ })) {
        $jn = [string]$j.job_name
        if (-not $jobsByName.ContainsKey($jn)) { $jobsByName[$jn] = [System.Collections.Generic.List[object]]::new() }
        $jobsByName[$jn].Add($j)
    }
    foreach ($jn in $jobsByName.Keys) {
        $steps = $jobsByName[$jn]
        $nonTsql = @($steps | Where-Object { [string]$_.subsystem -ine 'TSQL' })
        if ($nonTsql.Count -gt 0) {
            $subs = ($nonTsql | ForEach-Object { '{0} [{1}]' -f $_.step_name, $_.subsystem }) -join '; '
            Add-AdvResult -RuleId 'JOB-BLIND-001' -Schema '(agent)' -Object $jn -ObjType 'JOB-NONTS' `
                -ObjTypeDesc 'AGENT JOB' `
                -Evidence ("job '{0}' has non-T-SQL step(s) not analyzed by this tool: {1}" -f $jn, $subs)
        }
        foreach ($j in $steps) {
            if ([string]$j.subsystem -ine 'TSQL') { continue }
            $cmd = Hide-AdvSecret -Text ([string]$j.command)
            if ([string]::IsNullOrWhiteSpace($cmd)) { continue }
            Add-AdvScanFindings -RulesToScan $moduleRules -Text $cmd -Database '' -Schema '(agent)' `
                -Object ('[{0}] {1}' -f $jn, [string]$j.step_name) -ObjType 'JOB' -ObjTypeDesc 'TSQL step' `
                -Hotness 0 -EvidencePrefix ("job '{0}', step '{1}', " -f $jn, [string]$j.step_name)
        }
    }

    $notif = Get-AdvInt $InstanceData.AgentNotifCount
    if ($notif -gt 0) {
        Add-AdvResult -RuleId 'JOB-NOTIF-001' -Object 'SQL Agent notifications' -ObjType 'JOB' -ObjTypeDesc 'AGENT JOB' `
            -Evidence ('{0} SQL Agent notification(s) configured (net send / pager are deprecated)' -f $notif)
    }

    Write-AdvLog "Rule engine produced $(@($findings).Count) finding(s)" 'OK'
    Add-AdvCoverage -Name 'Rule engine execution (scan + structural checks)' -Ok $true `
        -Detail "$(@($findings).Count) findings before scoring"

    # ---- derived scores ---------------------------------------------------------
    Set-AdvDerivedScores -Findings $findings -DatabaseData $DatabaseData -InstanceData $InstanceData
    Update-AdvRisk -Findings $findings
    Add-AdvCoverage -Name 'Blast radius (dependency fan-in) + hotness + risk scoring' -Ok $true

    $inventory = New-AdvInventory -Findings $findings -DatabaseData $DatabaseData
    $summary   = Get-AdvSummary -Findings $findings -Inventory $inventory -DatabaseData $DatabaseData `
                    -InstanceData $InstanceData -TargetVersion $TargetVersion -TargetCompat $TargetCompat `
                    -ActiveRules $active
    $backlog   = Get-AdvBacklog -Findings $findings

    Write-AdvLog ("Summary: {0} findings | {1} will break | {2} deprecated | {3} blind spots" -f `
        $summary.TotalFindings, $summary.WillBreak, $summary.DeprecatedUsage, $summary.BlindSpots) 'OK'

    return [pscustomobject]@{
        Findings    = @($findings)
        Inventory   = @($inventory)
        Summary     = $summary
        Backlog     = @($backlog)
        ActiveRules = @($active)
    }
}

# --------------------------------------------------------------------------------
# DEMO INVENTORY - synthetic SQL Server 2016 fixture for -DemoMode
#   Shape matches Get-AdvInstanceData / Get-AdvDatabaseData exactly, so the engine
#   and the exporters behave identically with or without a live server.
# --------------------------------------------------------------------------------
function New-AdvDemoInventory {
    Write-AdvLog 'DemoMode: building synthetic SQL Server 2016 inventory (no server required)' 'OK'
    Add-AdvCoverage -Name '[Demo] synthetic inventory fixture' -Ok $true `
        -Detail '5 user databases, 4 linked servers, 5 Agent jobs, CLR, Stretch, Full-Text, PolyBase, DQS/MDS, replication, log shipping, mirroring'

    # ---- row builders -----------------------------------------------------------
    function New-DbRow {
        param([int]$Id, [string]$Name, [int]$Compat, [int]$Trustworthy = 0, [int]$Stretch = 0,
              [int]$AnsiNulls = 1, [int]$AnsiPadding = 1, [int]$Concat = 1,
              [string]$Owner = 'sa', [string]$Recovery = 'FULL', [int]$CreatedDaysAgo = 2400,
              [int]$Published = 0, [int]$Subscribed = 0, [int]$MergePublished = 0, [int]$Distributor = 0)
        [pscustomobject]@{
            database_id = $Id; name = $Name; compatibility_level = $Compat
            collation_name = 'SQL_Latin1_General_CP1_CI_AS'; state_desc = 'ONLINE'
            recovery_model_desc = $Recovery; is_trustworthy_on = $Trustworthy; is_read_only = 0
            user_access_desc = 'MULTI_USER'; is_auto_create_stats_on = 1; is_auto_update_stats_on = 1
            is_remote_data_archive_enabled = $Stretch; page_verify_option_desc = 'CHECKSUM'
            is_encrypted = 0; is_ansi_nulls_on = $AnsiNulls; is_ansi_padding_on = $AnsiPadding
            is_concat_null_yields_null_on = $Concat; owner_name = $Owner
            is_published = $Published; is_subscribed = $Subscribed
            is_merge_published = $MergePublished; is_distributor = $Distributor
        }
    }

    function New-ObjRow {
        param([int]$Id, [int]$ParentId = 0, [string]$Schema = 'dbo', [string]$Name, [string]$Type,
              [string]$TypeDef, $Definition = $null, [int]$CreatedDaysAgo = 1800, [int]$ModifiedDaysAgo = 45,
              [bool]$IsClr = $false, [string]$AssemblyName = '', [string]$AssemblyClass = '', [string]$PermSet = '')
        [pscustomobject]@{
            object_id = $Id; parent_object_id = $ParentId; schema_name = $Schema; name = $Name
            type = $Type; type_desc = $TypeDef
            create_date = (Get-Date).AddDays(-$CreatedDaysAgo)
            modify_date = (Get-Date).AddDays(-$ModifiedDaysAgo)
            definition = $Definition; is_clr = $IsClr
            assembly_name = $AssemblyName; assembly_class = $AssemblyClass; permission_set = $PermSet
        }
    }

    function New-ColRow {
        param([int]$TableId, [string]$Table, [int]$ColId, [string]$ColName, [string]$DType,
              [int]$Len = 8, [int]$Prec = 0, [int]$Scale = 0, [int]$Nullable = 1)
        [pscustomobject]@{
            object_id = $TableId; schema_name = 'dbo'; table_name = $Table; column_id = $ColId
            column_name = $ColName; data_type = $DType; max_length = $Len; precision = $Prec; scale = $Scale
            is_nullable = $Nullable; is_computed = 0; is_identity = 0; is_rowguidcol = 0; is_sparse = 0
            computed_definition = $null
        }
    }

    # ---- module sources ---------------------------------------------------------
    $sql_LegacyOrderProcess = @'
CREATE PROCEDURE dbo.usp_LegacyOrderProcess
    @OrderId INT,
    @Debug BIT = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET ROWCOUNT 100;

    DECLARE @Body TEXT, @Note NTEXT;

    -- deprecated: table hint on an aliased table, no WITH keyword
    SELECT *
      FROM Orders o (NOLOCK)
     WHERE OrderId = @OrderId;

    SELECT 'total' = COUNT(*)
      FROM OrderLines l WITH (NOLOCK)
     WHERE OrderId = @OrderId;

    UPDATE ol
       SET LineStatus = 1
      FROM dbo.OrderLines ol (NOLOCK)
     WHERE OrderId = @OrderId;

    SELECT @Body = Notes
      FROM dbo.OrderNotes WITH (NOLOCK)
     WHERE OrderId = @OrderId;

    EXEC xp_cmdshell 'dir C:\orders';

    EXEC sp_executesql
        N'SELECT LineId FROM dbo.OrderLines WHERE OrderId = @id',
        N'@id INT', @id = @OrderId;

    IF @Debug = 1
        EXEC sp_depends 'usp_LegacyOrderProcess';
END
'@

    $sql_RebuildIndexes = @'
CREATE PROCEDURE dbo.usp_RebuildIndexes
AS
BEGIN
    SET NOCOUNT ON;

    DBCC DBREINDEX ('dbo.Orders', ' ', 90);
    DBCC SHOWCONTIG WITH ALL_INDEXES;
    DBCC INDEXDEFRAG ('SalesDB', 'dbo.OrderLines');

    EXEC sp_lock;
    EXEC sp_indexoption 'dbo.Orders', 'LockEscalation', 'Disable';

    IF EXISTS (SELECT 1 FROM sysobjects WHERE name = 'Orders' AND xtype = 'U')
        PRINT 'legacy compatibility view in use';

    SELECT TOP 50 OrderId, Status FROM dbo.Orders ORDER BY OrderId DESC;
END
'@

    $sql_SecureAudit = @'
CREATE PROCEDURE dbo.usp_SecureAudit
    @Path NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @out TABLE (id INT, msg NVARCHAR(400));
    INSERT INTO @out
    EXEC master.dbo.xp_cmdshell @Path;

    CREATE TABLE #OleResult (id INT, val NVARCHAR(255));
    INSERT INTO #OleResult
    EXEC master.dbo.sp_OACreate 'SQLServer.DMO', 1;

    SELECT *
      FROM OPENROWSET('SQLNCLI', 'Server=LEGACY_ERP;Trusted_Connection=yes;', 'SELECT OrderId FROM ERPHR.dbo.Orders') AS src;
END
'@

    $sql_HashPasswords = @'
CREATE PROCEDURE dbo.usp_HashPasswords
    @Pw VARBINARY(8000)
AS
BEGIN
    DECLARE @md5 VARBINARY(128) = HASHBYTES('MD5', @Pw);
    DECLARE @sha VARBINARY(128) = HASHBYTES('SHA1', @Pw);

    IF EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE algorithm_desc = 'RC4')
        PRINT 'weak symmetric key algorithm in use';

    SELECT @md5, @sha;
END
'@

    $sql_XmlExport = @'
CREATE PROCEDURE dbo.usp_XmlExport
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @trace_id INT;

    SELECT OrderId, CustomerId
      FROM dbo.Orders
     GROUP BY ALL OrderId, CustomerId
    FOR XML RAW, XMLDATA;

    IF @@remserver IS NOT NULL
        PRINT 'remote server session detected';

    EXEC sp_trace_create @trace_id OUTPUT, 0, N'C:\traces\legacy.trc';
    EXEC sp_trace_setevent @trace_id, 10, 1, 1;
    EXEC sp_trace_setstatus @trace_id, 1;

    SELECT * FROM dbo.Orders FOR XML AUTO, TYPE;
END
'@

    $sql_GrantLegacy = @'
CREATE PROCEDURE dbo.usp_GrantLegacy
AS
BEGIN
    EXEC sp_addlogin 'legacy_app', '***';
    EXEC sp_adduser 'legacy_app';
    SETUSER 'dbo';

    GRANT  ALL ON dbo.Orders      TO legacy_app;
    REVOKE ALL ON dbo.OrderLines FROM legacy_app;

    EXEC sp_changedbowner 'sa';

    DECLARE @uid INT = dbo.user_id('legacy_app');
    IF dbo.permissions(1, 1) &4 = 4
        PRINT 'legacy permission bits present';
END
'@

    $sql_MigrateText = @'
CREATE PROCEDURE dbo.usp_MigrateTextData
AS
BEGIN
    SET NOCOUNT ON;

    CREATE TABLE #TextDump (Id INT, Body TEXT, OldNote NTEXT);

    DECLARE @ptr VARBINARY(16);
    SELECT @ptr = TEXTPTR(Body) FROM dbo.OrderNotes WHERE OrderId = 1;

    UPDATETEXT dbo.OrderNotes.Body @ptr NULL 4 N'new';
    WRITETEXT  dbo.OrderNotes.Body @ptr N'full body';

    UPDATE n
       SET Body = 'x'
      FROM dbo.OrderNotes n WITH (NOLOCK)
     WHERE OrderId = 2;

    DROP INDEX IX_Orders.OrderId;

    EXEC ::fn_trace_gettable(N'C:\traces\legacy.trc', DEFAULT);
END
'@

    $sql_DynamicLoader = @'
CREATE PROCEDURE dbo.usp_DynamicLoader
    @Table SYSNAME
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sql NVARCHAR(MAX) =
        N'SELECT LineId, OrderId FROM dbo.' + QUOTENAME(@Table) + N' WHERE Status <> ''X''';

    SET @sql = @sql + N' ORDER BY CreatedAt DESC;';

    EXEC sys.sp_executesql @sql;
    EXEC ('SELECT col1, col2 FROM ' + @Table + ' WHERE Active = 1');
    DECLARE @legacy nvarchar(400) = N'DBCC DBREINDEX (''dbo.Orders'', '' '', 80);';
    EXEC (@legacy);
END
'@

    $sql_LegacyView = @'
CREATE VIEW dbo.vw_LegacyCustomer
AS
    SELECT c.CustomerId,
           'name' = c.Name,
           c.ModifiedAt
      FROM dbo.Customers c
      JOIN sys.sysusers u ON u.name = USER_NAME()
     WHERE c.Status <> 'X'
       AND EXISTS (SELECT 1 FROM dbo.Orders o WHERE o.CustomerId = c.CustomerId);
'@

    $sql_Trigger = @'
CREATE TRIGGER dbo.trg_OrderAudit
ON dbo.Orders
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @cnt INT;
    SELECT @cnt = COUNT(*) FROM inserted;

    SELECT Id, Status INTO #Seen FROM inserted;

    INSERT INTO dbo.AuditEvents (EventData)
    SELECT CAST(p.Payload AS VARBINARY(MAX)) FROM inserted p;

    IF @cnt > 0
        SELECT * FROM dbo.AuditEvents;
END
'@

    $sql_ArchivePurge = @'
CREATE PROCEDURE dbo.usp_ArchivePurge
    @Days INT = 90
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id INT;
    DECLARE @c CURSOR;
    SET @c = CURSOR LOCAL FAST_FORWARD FOR
        SELECT ArchiveId FROM dbo.ArchiveLog WHERE ArchivedAt < DATEADD(DAY, -@Days, GETDATE());

    OPEN @c;
    FETCH NEXT FROM @c INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DELETE FROM dbo.ArchiveDetail WHERE ArchiveId = @id;
        FETCH NEXT FROM @c INTO @id;
    END
    CLOSE @c;
    DEALLOCATE @c;

    EXEC sp_attach_db N'LegacyArchive', N'C:\data\archive.mdf';
END
'@

    $sql_ModernHints = @'
CREATE PROCEDURE dbo.usp_ModernHints
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP 100 ArchiveId, ArchivedAt
      FROM dbo.ArchiveLog WITH (NOLOCK, ROWLOCK)
     WHERE ArchivedAt >= DATEADD(DAY, -7, GETDATE())
     ORDER BY ArchivedAt DESC;

    SELECT ArchiveId FROM dbo.ArchiveLog WITH (REPEATABLEREAD);
END
'@

    $sql_ArchiveView = @'
CREATE VIEW dbo.vw_ArchiveSummary
AS
    SELECT ArchiveId, BucketId, COUNT(*) AS NoteCount
      FROM dbo.ArchiveLog
     GROUP BY ArchiveId, BucketId;
'@

    $sql_DqsProc = @'
CREATE PROCEDURE dbo.usp_DQS_RunKnowledgeBase
AS
BEGIN
    SET NOCOUNT ON;
    SELECT * FROM dbo.DQS_Project;
    EXEC [DQS_Main].dbo.usp_RunKnowledgeBase;
END
'@

    $sql_MdmView = @'
CREATE VIEW dbo.vw_MdmMember
AS
    SELECT *
      FROM dbo.MdmMember m WITH (NOLOCK)
     WHERE m.IsActive = 1;
'@

    $job1Cmd = @'
SET NOCOUNT ON;

DECLARE @src NVARCHAR(400) =
    N'SELECT EmployeeId FROM [LEGACY_ERP].[ERPHR].[dbo].[Employees]';

BACKUP DATABASE SalesDB TO TAPE = '\\tape01\sales.bak' WITH PASSWORD = 'legacy', INIT;

EXEC sp_executesql @src;
UPDATE STATISTICS dbo.Orders WITH FULLSCAN;
'@

    $job2Cmd = @'
DBCC DBREINDEX ('dbo.ArchiveLog', ' ', 80);

EXEC sp_configure 'allow updates', 1;
RECONFIGURE;
'@

    # ---- instance-level fixture -------------------------------------------------
    $inst = [pscustomobject]@{
        ServerName = 'DEMO-SQL01'; ProductVersion = '13.0.4001.0'; ProductLevel = 'SP3'
        Edition = 'Developer Edition (64-bit)'; Collation = 'SQL_Latin1_General_CP1_CI_AS'
        EngineEdition = 3; IsClustered = 0; IsHadrEnabled = 1
    }

    $configs = @(
        [pscustomobject]@{ name = 'clr strict security';        value_in_use = 1 }
        [pscustomobject]@{ name = 'lightweight pooling';        value_in_use = 1 }
        [pscustomobject]@{ name = 'external scripts enabled';   value_in_use = 1 }
        [pscustomobject]@{ name = 'xp_cmdshell';                value_in_use = 1 }
        [pscustomobject]@{ name = 'Ole Automation Procedures';  value_in_use = 1 }
        [pscustomobject]@{ name = 'Ad Hoc Distributed Queries'; value_in_use = 1 }
        [pscustomobject]@{ name = 'clr enabled';                value_in_use = 1 }
        [pscustomobject]@{ name = 'max degree of parallelism';  value_in_use = 8 }
        [pscustomobject]@{ name = 'cost threshold for parallelism'; value_in_use = 5 }
    )

    $dbRows = @(
        (New-DbRow -Id 1 -Name 'master'      -Compat 130 -Recovery SIMPLE -CreatedDaysAgo 2400)
        (New-DbRow -Id 2 -Name 'model'       -Compat 130 -Recovery FULL  -CreatedDaysAgo 2400)
        (New-DbRow -Id 3 -Name 'msdb'        -Compat 130 -Recovery SIMPLE -CreatedDaysAgo 2400)
        (New-DbRow -Id 4 -Name 'tempdb'      -Compat 130 -Recovery SIMPLE -CreatedDaysAgo 1)
        (New-DbRow -Id 5 -Name 'SalesDB'     -Compat 130 -Trustworthy 1 -Owner 'sa' -Published 1)
        (New-DbRow -Id 6 -Name 'ArchiveDB'   -Compat 120 -Stretch 1 -Concat 0 -Owner 'svc_archive')
        (New-DbRow -Id 7 -Name 'DQS_Main'    -Compat 120 -Owner 'sa' -Recovery SIMPLE)
        (New-DbRow -Id 8 -Name 'MDM_Repo'    -Compat 130 -Trustworthy 1 -Owner 'sa')
        (New-DbRow -Id 9 -Name 'MDS_Catalog' -Compat 130 -Owner 'sa' -Recovery SIMPLE)
    )

    $linkedServers = @(
        [pscustomobject]@{ server_id = 1; name = 'LEGACY_ERP';       product = 'SQL Server';                  provider = 'SQLOLEDB.1';    data_source = 'erp-sql01';    is_linked = 1 }
        [pscustomobject]@{ server_id = 2; name = 'ARCHIVE_NC';       product = 'SQL Server Native Client 11.0'; provider = 'SQLNCLI11';    data_source = 'arc-sql02';    is_linked = 1 }
        [pscustomobject]@{ server_id = 3; name = 'repl_distributor'; product = 'SQL Server';                  provider = 'SQLOLEDB.1';    data_source = 'dist-sql03';   is_linked = 0 }
        [pscustomobject]@{ server_id = 4; name = 'ORACLE_HR';        product = 'Oracle';                      provider = 'OraOLEDB.1';    data_source = 'ora-hr01';     is_linked = 1 }
    )

    $mirroring = @(
        [pscustomobject]@{ database_name = 'ArchiveDB'; mirroring_state_desc = 'FULL'; mirroring_role_desc = 'PRINCIPAL'; mirroring_partner_name = 'DEMO-SQL02' }
    )

    $availabilityGroups = @(
        [pscustomobject]@{ name = 'AG-SALES'; cluster_type_desc = 'WSFC' }
    )

    $traceFlags = @(
        [pscustomobject]@{ Flag = 4199; Status = 1; Global = 1; Session = 0 }
        [pscustomobject]@{ Flag = 2371; Status = 1; Global = 1; Session = 0 }
        [pscustomobject]@{ Flag = 1117; Status = 1; Global = 1; Session = 0 }
    )

    $deprecatedCounters = @(
        [pscustomobject]@{ feature = 'text in row data type'; hits = 41003 }
        [pscustomobject]@{ feature = 'SQL Trace';             hits = 9552 }
        [pscustomobject]@{ feature = 'sp_depends';            hits = 771 }
        [pscustomobject]@{ feature = 'sql mail';              hits = 12 }
        [pscustomobject]@{ feature = 'allow updates';         hits = 0 }
    )

    $agentJobs = @(
        [pscustomobject]@{ job_name = 'Nightly Order ETL'; job_enabled = 1; step_id = 1; step_name = 'Build staging'; subsystem = 'TSQL';     command = $job1Cmd }
        [pscustomobject]@{ job_name = 'Nightly Order ETL'; job_enabled = 1; step_id = 2; step_name = 'Copy files';    subsystem = 'CmdExec';  command = 'xcopy C:\etl\*.csv \\file01\etl\ /Y' }
        [pscustomobject]@{ job_name = 'Archive Reindex';   job_enabled = 1; step_id = 1; step_name = 'Reindex';      subsystem = 'TSQL';     command = $job2Cmd }
        [pscustomobject]@{ job_name = 'Warehouse Load';    job_enabled = 1; step_id = 1; step_name = 'Load package'; subsystem = 'SSIS';     command = 'DTS /SETLOCAL; /FILE "C:\ssis\load.dtsx"' }
        [pscustomobject]@{ job_name = 'Nightly Cleanup';   job_enabled = 1; step_id = 1; step_name = 'Cleanup';      subsystem = 'PowerShell'; command = 'Remove-Item C:\temp\*.tmp -ErrorAction SilentlyContinue' }
    )

    $ownerPerms = @{
        'sa'            = [pscustomobject]@{ Owner = 'sa';            IsSysadmin = 1; HasUnsafe = 1; Ok = $true }
        'svc_archive'   = [pscustomobject]@{ Owner = 'svc_archive';   IsSysadmin = 0; HasUnsafe = 0; Ok = $true }
    }

    $instanceData = @{
        Instance            = $inst
        Configs             = $configs
        Databases           = $dbRows
        LinkedServers       = $linkedServers
        AgentJobs           = $agentJobs
        AgentNotifCount     = 4
        TraceFlags          = $traceFlags
        DeprecatedCounters  = $deprecatedCounters
        Mirroring           = $mirroring
        AvailabilityGroups  = $availabilityGroups
        HasDistributionDb   = $true
        DistributionDatabases = 'distribution'
        HasReplicationDist  = $true
        ReplicationDistributorSource = 'dist-sql03'
        HasReplicationPublication = $true
        LogShippingPrimary  = 1
        LogShippingSecondary= 1
        LogShippingRemoteMonitor = 1
        OwnerPerms          = $ownerPerms
        Endpoints           = @(
            [pscustomobject]@{ name = 'Hadr_endpoint'; type_desc = 'DATABASE_MIRRORING'; protocol_desc = 'TCP'; state_desc = 'STARTED' }
            [pscustomobject]@{ name = 'LegacySoap'; type_desc = 'SOAP'; protocol_desc = 'HTTP'; state_desc = 'STARTED' }
        )
        ServerTriggers      = @(
            [pscustomobject]@{ name = 'trg_block_drop'; is_disabled = 0; definition = "CREATE TRIGGER trg_block_drop ON ALL SERVER FOR DROP_DATABASE AS BEGIN RAISERROR('drop blocked', 16, 1); END" }
        )
        Credentials         = @([pscustomobject]@{ name = 'cred_etl'; credential_identity = 'DOMAIN\svc_etl' })
        AgentProxies        = @([pscustomobject]@{ name = 'proxy_etl'; enabled = 1 })
        LinkedLogins        = @([pscustomobject]@{ server_name = 'LEGACY_ERP'; uses_self_credential = 0; remote_name = 'etl_reader' })
        TrustedAssemblies   = @()
    }

    # ---- SalesDB ----------------------------------------------------------------
    $salesObjects = @(
        (New-ObjRow -Id 100101 -Name 'Orders'                  -Type 'U'  -TypeDef 'USER_TABLE')
        (New-ObjRow -Id 100102 -Name 'OrderLines'              -Type 'U'  -TypeDef 'USER_TABLE')
        (New-ObjRow -Id 100103 -Name 'OrderNotes'              -Type 'U'  -TypeDef 'USER_TABLE')
        (New-ObjRow -Id 100104 -Name 'Customers'               -Type 'U'  -TypeDef 'USER_TABLE')
        (New-ObjRow -Id 100105 -Name 'AuditEvents'             -Type 'U'  -TypeDef 'USER_TABLE')
        (New-ObjRow -Id 100110 -Name 'usp_LegacyOrderProcess'  -Type 'P'  -TypeDef 'SQL_STORED_PROCEDURE' -Definition $sql_LegacyOrderProcess -ModifiedDaysAgo 3)
        (New-ObjRow -Id 100111 -Name 'usp_EncryptedSummary'    -Type 'P'  -TypeDef 'SQL_STORED_PROCEDURE' -Definition $null -ModifiedDaysAgo 1500)
        (New-ObjRow -Id 100112 -Name 'usp_RebuildIndexes'      -Type 'P'  -TypeDef 'SQL_STORED_PROCEDURE' -Definition $sql_RebuildIndexes)
        (New-ObjRow -Id 100113 -Name 'usp_SecureAudit'         -Type 'P'  -TypeDef 'SQL_STORED_PROCEDURE' -Definition $sql_SecureAudit)
        (New-ObjRow -Id 100114 -Name 'usp_DynamicLoader'       -Type 'P'  -TypeDef 'SQL_STORED_PROCEDURE' -Definition $sql_DynamicLoader)
        (New-ObjRow -Id 100115 -Name 'usp_MigrateTextData'     -Type 'P'  -TypeDef 'SQL_STORED_PROCEDURE' -Definition $sql_MigrateText)
        (New-ObjRow -Id 100116 -Name 'usp_HashPasswords'       -Type 'P'  -TypeDef 'SQL_STORED_PROCEDURE' -Definition $sql_HashPasswords)
        (New-ObjRow -Id 100117 -Name 'usp_XmlExport'           -Type 'P'  -TypeDef 'SQL_STORED_PROCEDURE' -Definition $sql_XmlExport)
        (New-ObjRow -Id 100118 -Name 'usp_GrantLegacy'         -Type 'P'  -TypeDef 'SQL_STORED_PROCEDURE' -Definition $sql_GrantLegacy)
        (New-ObjRow -Id 100119 -Name 'vw_LegacyCustomer'       -Type 'V'  -TypeDef 'VIEW'                -Definition $sql_LegacyView)
        (New-ObjRow -Id 100120 -Name 'trg_OrderAudit'          -Type 'TR' -TypeDef 'SQL_TRIGGER' -ParentId 100101 -Definition $sql_Trigger -CreatedDaysAgo 1700 -ModifiedDaysAgo 12)
        (New-ObjRow -Id 100121 -Name 'df_OrderStatus'          -Type 'D'  -TypeDef 'DEFAULT_CONSTRAINT' -ParentId 100101)
        (New-ObjRow -Id 100122 -Name 'chk_QtyRule'             -Type 'R'  -TypeDef 'RULE')
        (New-ObjRow -Id 100128 -Name 'def_LegacyStatus'        -Type 'D'  -TypeDef 'DEFAULT' -ParentId 0)
        (New-ObjRow -Id 100123 -Name 'syn_RemoteOrders'        -Type 'SN' -TypeDef 'SYNONYM')
        (New-ObjRow -Id 100124 -Name 'syn_ERPPeople'           -Type 'SN' -TypeDef 'SYNONYM')
        (New-ObjRow -Id 100125 -Name 'syn_LocalOrders'         -Type 'SN' -TypeDef 'SYNONYM')
        (New-ObjRow -Id 100126 -Name 'fn_GeoDistance'          -Type 'FN' -TypeDef 'SQL_SCALAR_FUNCTION' -IsClr $true -AssemblyName 'LegacyGeo' -AssemblyClass 'GeoTools' -PermSet 'UNSAFE')
        (New-ObjRow -Id 100127 -Name 'usp_LoadFiles'           -Type 'PC' -TypeDef 'CLR_STORED_PROCEDURE' -IsClr $true -AssemblyName 'FileHelper' -AssemblyClass 'FileUtil' -PermSet 'EXTERNAL_ACCESS')
    )

    $salesColumns = @(
        (New-ColRow -TableId 100101 -Table 'Orders' -ColId 1 -ColName 'OrderId'        -DType 'int')
        (New-ColRow -TableId 100101 -Table 'Orders' -ColId 2 -ColName 'CustomerId'    -DType 'int')
        (New-ColRow -TableId 100101 -Table 'Orders' -ColId 3 -ColName 'Status'        -DType 'nvarchar' -Len 60)
        (New-ColRow -TableId 100101 -Table 'Orders' -ColId 4 -ColName 'CreatedAt'     -DType 'datetime2' -Len 8)
        (New-ColRow -TableId 100101 -Table 'Orders' -ColId 5 -ColName 'CustomerNotes' -DType 'text' -Len 16)
        (New-ColRow -TableId 100102 -Table 'OrderLines' -ColId 1 -ColName 'LineId'     -DType 'int')
        (New-ColRow -TableId 100102 -Table 'OrderLines' -ColId 2 -ColName 'OrderId'    -DType 'int')
        (New-ColRow -TableId 100102 -Table 'OrderLines' -ColId 3 -ColName 'Qty'        -DType 'int')
        (New-ColRow -TableId 100102 -Table 'OrderLines' -ColId 4 -ColName 'LineStatus' -DType 'int')
        (New-ColRow -TableId 100103 -Table 'OrderNotes' -ColId 1 -ColName 'NoteId'     -DType 'int')
        (New-ColRow -TableId 100103 -Table 'OrderNotes' -ColId 2 -ColName 'OrderId'    -DType 'int')
        (New-ColRow -TableId 100103 -Table 'OrderNotes' -ColId 3 -ColName 'Body'       -DType 'text' -Len 16)
        (New-ColRow -TableId 100103 -Table 'OrderNotes' -ColId 4 -ColName 'NoteTs'     -DType 'timestamp' -Len 8 -Nullable 0)
        (New-ColRow -TableId 100104 -Table 'Customers' -ColId 1 -ColName 'CustomerId' -DType 'int')
        (New-ColRow -TableId 100104 -Table 'Customers' -ColId 2 -ColName 'Name'       -DType 'nvarchar' -Len 400)
        (New-ColRow -TableId 100104 -Table 'Customers' -ColId 3 -ColName 'Email'      -DType 'nvarchar' -Len 640)
        (New-ColRow -TableId 100104 -Table 'Customers' -ColId 4 -ColName 'Status'     -DType 'char' -Len 1)
        (New-ColRow -TableId 100105 -Table 'AuditEvents' -ColId 1 -ColName 'EventId'   -DType 'bigint')
        (New-ColRow -TableId 100105 -Table 'AuditEvents' -ColId 2 -ColName 'EventData' -DType 'varbinary' -Len -1)
    )

    $salesStats = @(
        [pscustomobject]@{ object_id = 100110; exec_count = [long]4200000; total_reads = [long]9100000000; total_cpu = [long]5200000000 }
        [pscustomobject]@{ object_id = 100112; exec_count = [long]12400;   total_reads = [long]88000000;   total_cpu = [long]21000000 }
        [pscustomobject]@{ object_id = 100113; exec_count = [long]850000;  total_reads = [long]440000000;  total_cpu = [long]660000000 }
        [pscustomobject]@{ object_id = 100114; exec_count = [long]210000;  total_reads = [long]15000000;   total_cpu = [long]6600000 }
        [pscustomobject]@{ object_id = 100115; exec_count = [long]950;     total_reads = [long]3100000;    total_cpu = [long]840000 }
        [pscustomobject]@{ object_id = 100116; exec_count = [long]45;      total_reads = [long]120000;     total_cpu = [long]90000 }
        [pscustomobject]@{ object_id = 100117; exec_count = [long]12;      total_reads = [long]44000;      total_cpu = [long]31000 }
        [pscustomobject]@{ object_id = 100118; exec_count = [long]3;       total_reads = [long]900;        total_cpu = [long]400 }
        [pscustomobject]@{ object_id = 100120; exec_count = [long]6100000; total_reads = [long]2200000000; total_cpu = [long]1900000000 }
    )

    $salesDeps = [System.Collections.Generic.List[object]]::new()
    foreach ($i in 1..27)  { $salesDeps.Add([pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = "usp_OrderReader$i"; referenced_schema_name = 'dbo'; referenced_entity_name = 'Orders'; referenced_database_name = ''; referenced_server_name = '' }) }
    foreach ($i in 1..14)  { $salesDeps.Add([pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = "usp_FrontEnd$i"; referenced_schema_name = 'dbo'; referenced_entity_name = 'usp_LegacyOrderProcess'; referenced_database_name = ''; referenced_server_name = '' }) }
    foreach ($i in 1..8)   { $salesDeps.Add([pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = "usp_NoteReader$i"; referenced_schema_name = 'dbo'; referenced_entity_name = 'OrderNotes'; referenced_database_name = ''; referenced_server_name = '' }) }
    foreach ($i in 1..5)   { $salesDeps.Add([pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = "vw_Portal$i"; referenced_schema_name = 'dbo'; referenced_entity_name = 'vw_LegacyCustomer'; referenced_database_name = ''; referenced_server_name = '' }) }
    foreach ($i in 1..3)   { $salesDeps.Add([pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = "usp_AuditReader$i"; referenced_schema_name = 'dbo'; referenced_entity_name = 'AuditEvents'; referenced_database_name = ''; referenced_server_name = '' }) }
    $salesDeps.Add([pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = 'usp_ReportingPack'; referenced_schema_name = 'dbo'; referenced_entity_name = 'ArchiveLog'; referenced_database_name = 'ArchiveDB'; referenced_server_name = '' })
    $salesDeps.Add([pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = 'usp_LinkLoader'; referenced_schema_name = 'dbo'; referenced_entity_name = 'Employees'; referenced_database_name = ''; referenced_server_name = 'LEGACY_ERP' })

    $sales = @{
        Database = 'SalesDB'; QueryStore = 'OFF'
        OwnerIsSysadmin = 1; OwnerHasUnsafe = 1
        Objects = $salesObjects; Columns = $salesColumns
        Indexes = @(
            [pscustomobject]@{ schema_name = 'dbo'; table_name = 'Orders'; index_name = 'IX_Orders_CreatedAt'; type_desc = 'NONCLUSTERED'; is_disabled = 0; has_filter = 1; filter_definition = 'Status <> ''X''' }
            [pscustomobject]@{ schema_name = 'dbo'; table_name = 'Customers'; index_name = 'IX_Customers_Email'; type_desc = 'NONCLUSTERED'; is_disabled = 1; has_filter = 0; filter_definition = $null }
        )
        Assemblies = @(
            [pscustomobject]@{ assembly_id = 1; name = 'LegacyGeo';        permission_set_desc = 'UNSAFE';          is_loaded = 1; is_visible = 1; is_signed = 0 }
            [pscustomobject]@{ assembly_id = 2; name = 'SignedAnalytics';  permission_set_desc = 'SAFE';            is_loaded = 1; is_visible = 1; is_signed = 1 }
            [pscustomobject]@{ assembly_id = 3; name = 'FileHelper';       permission_set_desc = 'EXTERNAL_ACCESS'; is_loaded = 1; is_visible = 1; is_signed = 0 }
        )
        Crypto = @(
            [pscustomobject]@{ kind = 'CERTIFICATE'; name = 'SalesDbCert' }
            [pscustomobject]@{ kind = 'ASYMMETRIC KEY'; name = 'SalesAK' }
        )
        Synonyms = @(
            [pscustomobject]@{ schema_name = 'dbo'; name = 'syn_RemoteOrders'; base_object_name = 'ArchiveDB.dbo.Orders' }
            [pscustomobject]@{ schema_name = 'dbo'; name = 'syn_ERPPeople';    base_object_name = '[LEGACY_ERP].[ERPHR].[dbo].[Employees]' }
            [pscustomobject]@{ schema_name = 'dbo'; name = 'syn_LocalOrders';  base_object_name = 'dbo.Orders' }
        )
        ExternalSources = @(); ExternalTables = @(); FullText = @()
        Dependencies = $salesDeps
        ObjectStats = $salesStats
        FeatureSurface = [pscustomobject]@{
            is_cdc_enabled = 1; is_broker_enabled = 1; memory_optimized_tables = 1; filetables = 0
            cdc_tables = 2; change_tracking_tables = 1; broker_queues = 1; filestream_filegroups = 1
            partition_functions = 1; xml_schema_collections = 1; has_database_master_key = 1
            user_symmetric_keys = 0; column_master_keys = 1; column_encryption_keys = 1
        }
        SkuFeatures = @([pscustomobject]@{ feature_name = 'ChangeCapture'; feature_id = 100 })
        QueryStoreBaseline = [pscustomobject]@{ query_count = 120; forced_plans = 2 }
        Ok = $true; Error = ''
    }

    # ---- ArchiveDB --------------------------------------------------------------
    $archiveObjects = @(
        (New-ObjRow -Id 200101 -Name 'ArchiveLog'      -Type 'U' -TypeDef 'USER_TABLE' -CreatedDaysAgo 2600)
        (New-ObjRow -Id 200102 -Name 'ArchiveDetail'   -Type 'U' -TypeDef 'USER_TABLE' -CreatedDaysAgo 2600)
        (New-ObjRow -Id 200103 -Name 'usp_ArchivePurge' -Type 'P' -TypeDef 'SQL_STORED_PROCEDURE' -Definition $sql_ArchivePurge)
        (New-ObjRow -Id 200104 -Name 'usp_ModernHints' -Type 'P' -TypeDef 'SQL_STORED_PROCEDURE' -Definition $sql_ModernHints)
        (New-ObjRow -Id 200105 -Name 'vw_ArchiveSummary' -Type 'V' -TypeDef 'VIEW' -Definition $sql_ArchiveView)
    )
    $archiveColumns = @(
        (New-ColRow -TableId 200101 -Table 'ArchiveLog' -ColId 1 -ColName 'ArchiveId' -DType 'int')
        (New-ColRow -TableId 200101 -Table 'ArchiveLog' -ColId 2 -ColName 'ArchivedAt' -DType 'datetime2' -Len 8)
        (New-ColRow -TableId 200101 -Table 'ArchiveLog' -ColId 3 -ColName 'BucketId'  -DType 'int')
        (New-ColRow -TableId 200101 -Table 'ArchiveLog' -ColId 4 -ColName 'RawData'   -DType 'image' -Len 16)
        (New-ColRow -TableId 200102 -Table 'ArchiveDetail' -ColId 1 -ColName 'DetailId' -DType 'bigint')
        (New-ColRow -TableId 200102 -Table 'ArchiveDetail' -ColId 2 -ColName 'ArchiveId' -DType 'int')
        (New-ColRow -TableId 200102 -Table 'ArchiveDetail' -ColId 3 -ColName 'Payload' -DType 'varbinary' -Len -1)
    )
    $archiveDeps = [System.Collections.Generic.List[object]]::new()
    foreach ($i in 1..6) { $archiveDeps.Add([pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = "usp_ArchiveReader$i"; referenced_schema_name = 'dbo'; referenced_entity_name = 'ArchiveLog'; referenced_database_name = ''; referenced_server_name = '' }) }
    foreach ($i in 1..2) { $archiveDeps.Add([pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = "usp_DetailPurger$i"; referenced_schema_name = 'dbo'; referenced_entity_name = 'ArchiveDetail'; referenced_database_name = ''; referenced_server_name = '' }) }

    $archive = @{
        Database = 'ArchiveDB'; QueryStore = 'OFF'
        OwnerIsSysadmin = 0; OwnerHasUnsafe = 0
        Objects = $archiveObjects; Columns = $archiveColumns
        Indexes = @()
        Assemblies = @(); Crypto = @(); Synonyms = @()
        ExternalSources = @(
            [pscustomobject]@{ name = 'HadoopHR';     type_desc = 'HADOOP'; location = 'hdfs://namenode01:8020/user/hr' }
            [pscustomobject]@{ name = 'ArchiveBlob';  type_desc = 'HADOOP'; location = 'wasb://archive@archivestore.blob.core.windows.net/parquet' }
        )
        ExternalTables = @(
            [pscustomobject]@{ schema_name = 'dbo'; table_name = 'HR_External';      data_source_name = 'HadoopHR';    data_source_type = 'HADOOP'; data_source_location = 'hdfs://namenode01:8020/user/hr' }
            [pscustomobject]@{ schema_name = 'dbo'; table_name = 'ArchiveBlobExt';   data_source_name = 'ArchiveBlob'; data_source_type = 'HADOOP'; data_source_location = 'wasb://archive@archivestore.blob.core.windows.net/parquet' }
        )
        FullText = @(
            [pscustomobject]@{ schema_name = 'dbo'; table_name = 'ArchiveLog' }
        )
        Dependencies = $archiveDeps
        ObjectStats = @(
            [pscustomobject]@{ object_id = 200103; exec_count = [long]3300;   total_reads = [long]18000000; total_cpu = [long]9000000 }
            [pscustomobject]@{ object_id = 200104; exec_count = [long]98000;  total_reads = [long]64000000; total_cpu = [long]31000000 }
        )
        Ok = $true; Error = ''
    }

    # ---- DQS_Main / MDM_Repo / MDS_Catalog -------------------------------------
    $dqs = @{
        Database = 'DQS_Main'; QueryStore = 'OFF'
        OwnerIsSysadmin = 1; OwnerHasUnsafe = 1
        Objects = @(
            (New-ObjRow -Id 300101 -Name 'DQS_Project' -Type 'U' -TypeDef 'USER_TABLE')
            (New-ObjRow -Id 300102 -Name 'usp_DQS_RunKnowledgeBase' -Type 'P' -TypeDef 'SQL_STORED_PROCEDURE' -Definition $sql_DqsProc)
        )
        Columns = @(
            (New-ColRow -TableId 300101 -Table 'DQS_Project' -ColId 1 -ColName 'ProjectId'      -DType 'int')
            (New-ColRow -TableId 300101 -Table 'DQS_Project' -ColId 2 -ColName 'ProjectName'    -DType 'nvarchar' -Len 400)
            (New-ColRow -TableId 300101 -Table 'DQS_Project' -ColId 3 -ColName 'KnowledgeBase'  -DType 'varbinary' -Len -1)
        )
        Indexes = @(); Assemblies = @(); Crypto = @(); Synonyms = @()
        ExternalSources = @(); ExternalTables = @(); FullText = @()
        Dependencies = @(); ObjectStats = @()
        Ok = $true; Error = ''
    }

    $mdm = @{
        Database = 'MDM_Repo'; QueryStore = 'READ_WRITE'
        OwnerIsSysadmin = 1; OwnerHasUnsafe = 1
        Objects = @(
            (New-ObjRow -Id 400101 -Name 'MdmMember'   -Type 'U' -TypeDef 'USER_TABLE')
            (New-ObjRow -Id 400102 -Name 'vw_MdmMember' -Type 'V' -TypeDef 'VIEW' -Definition $sql_MdmView)
        )
        Columns = @(
            (New-ColRow -TableId 400101 -Table 'MdmMember' -ColId 1 -ColName 'MemberId'  -DType 'int')
            (New-ColRow -TableId 400101 -Table 'MdmMember' -ColId 2 -ColName 'Name'      -DType 'nvarchar' -Len 400)
            (New-ColRow -TableId 400101 -Table 'MdmMember' -ColId 3 -ColName 'IsActive'  -DType 'bit')
        )
        Indexes = @(); Assemblies = @(); Crypto = @(); Synonyms = @()
        ExternalSources = @(); ExternalTables = @(); FullText = @()
        Dependencies = @(
            [pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = "usp_MdmPortal1"; referenced_schema_name = 'dbo'; referenced_entity_name = 'MdmMember'; referenced_database_name = ''; referenced_server_name = '' }
            [pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = "usp_MdmPortal2"; referenced_schema_name = 'dbo'; referenced_entity_name = 'MdmMember'; referenced_database_name = ''; referenced_server_name = '' }
            [pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = "usp_MdmPortal3"; referenced_schema_name = 'dbo'; referenced_entity_name = 'MdmMember'; referenced_database_name = ''; referenced_server_name = '' }
            [pscustomobject]@{ referencing_schema_name = 'dbo'; referencing_entity_name = "vw_MdmBoard";  referenced_schema_name = 'dbo'; referenced_entity_name = 'MdmMember'; referenced_database_name = ''; referenced_server_name = '' }
        )
        ObjectStats = @()
        Ok = $true; Error = ''
    }

    $mds = @{
        Database = 'MDS_Catalog'; QueryStore = 'not found'
        OwnerIsSysadmin = 1; OwnerHasUnsafe = 1
        Objects = @(
            (New-ObjRow -Id 500101 -Name 'MdsEntity' -Type 'U' -TypeDef 'USER_TABLE')
        )
        Columns = @(
            (New-ColRow -TableId 500101 -Table 'MdsEntity' -ColId 1 -ColName 'EntityId'   -DType 'int')
            (New-ColRow -TableId 500101 -Table 'MdsEntity' -ColId 2 -ColName 'EntityCode' -DType 'nvarchar' -Len 100)
        )
        Indexes = @(); Assemblies = @(); Crypto = @(); Synonyms = @()
        ExternalSources = @(); ExternalTables = @(); FullText = @()
        Dependencies = @(); ObjectStats = @()
        Ok = $true; Error = ''
    }

    Write-AdvLog 'Demo inventory ready: SalesDB, ArchiveDB, DQS_Main, MDM_Repo, MDS_Catalog' 'OK'
    return @{
        InstanceData = $instanceData
        DatabaseData = @($sales, $archive, $dqs, $mdm, $mds)
    }
}

# --------------------------------------------------------------------------------
# REPORT - HTML (self-contained, filterable, no external assets)
# --------------------------------------------------------------------------------
function Get-AdvStatusClass {
    param([string]$Status)
    switch ($Status) {
        'Will break'       { return 'st-break' }
        'Needs adjustment' { return 'st-adjust' }
        'Security concern' { return 'st-security' }
        'Deprecated usage' { return 'st-depr' }
        'Needs review'     { return 'st-review' }
        'Modernization'    { return 'st-modern' }
        'Not assessable'   { return 'st-blind' }
        'No static findings' { return 'st-ok' }
        default            { return 'st-review' }
    }
}

function Get-AdvSeverityClass {
    param([string]$Severity)
    switch ($Severity) {
        'Critical' { return 'sev-critical' }
        'High'     { return 'sev-high' }
        'Medium'   { return 'sev-medium' }
        'Low'      { return 'sev-low' }
        'Info'     { return 'sev-info' }
        default    { return 'sev-medium' }
    }
}

function Get-AdvSeverityColor {
    param([string]$Severity)
    switch ($Severity) {
        'Critical' { return '#b71c1c' }
        'High'     { return '#c62828' }
        'Medium'   { return '#ef6c00' }
        'Low'      { return '#546e7a' }
        'Info'     { return '#1565c0' }
        default    { return '#ef6c00' }
    }
}

function Export-AdvHtml {
    param(
        $Engine,
        $InstanceData,
        [array]$DatabaseData,
        [array]$Coverage,
        [string]$Path,
        [string]$TargetVersion,
        [int]$TargetCompat,
        [int]$MaxFindings = 5000
    )

    $S = $Engine.Summary
    $enc = { param($t) ConvertTo-HtmlEnc ([string]$t) }

    # ---- shared projections (the sidebar tree and the charts need them early) ----
    $findings = @($Engine.Findings | Sort-Object -Property @{Expression = { [int]$_.Risk }; Descending = $true}, @{Expression = { [int]$_.TotalMatches }; Descending = $true})
    $shown = $findings
    $truncated = $false
    if ($MaxFindings -gt 0 -and $findings.Count -gt $MaxFindings) { $shown = @($findings | Select-Object -First $MaxFindings); $truncated = $true }
    $invAll   = @($Engine.Inventory | Sort-Object -Property @{Expression = { [int]$_.MaxRisk }; Descending = $true})
    $invBad   = @($invAll | Where-Object { $_.Status -ne 'No static findings' })
    $blind    = @($Engine.Findings | Where-Object { $_.Status -eq 'Not assessable' })
    $covFail  = @($Coverage | Where-Object { $_.Status -ne 'Collected' })

    # ---- scope tree: Database -> Schema -> Object, with finding counts -----------
    $scopeKey = { param($v) if ([string]::IsNullOrEmpty($v)) { '' } else { [string]$v } }
    $fCount = @{}          # 'db' | 'db|sch' | 'db|sch|obj' -> findings
    $incCount = { param($ht, $k) if ($ht.ContainsKey($k)) { $ht[$k] = [int]$ht[$k] + 1 } else { $ht[$k] = 1 } }
    foreach ($f in $findings) {
        $dbK = & $scopeKey $f.Database
        if (-not $dbK) { $dbK = '(instance/agent)' }
        $schK = & $scopeKey $f.Schema
        $objK = & $scopeKey $f.Object
        & $incCount $fCount $dbK
        if ($schK) { & $incCount $fCount ($dbK + '|' + $schK) }
        if ($objK) { & $incCount $fCount ($dbK + '|' + $schK + '|' + $objK) }
    }
    $getCount = { param($ht, $k) if ($ht.ContainsKey($k)) { [int]$ht[$k] } else { 0 } }

    # merge inventory (objects) with findings (counts) into a nested structure
    $T = [ordered]@{}
    $ensureDb = {
        param([string]$n)
        if (-not $T.Contains($n)) { $T[$n] = [pscustomobject]@{ Name = $n; Sch = [ordered]@{} } }
        $T[$n]
    }
    $ensureSch = {
        param([string]$d, [string]$s)
        $dbN = & $ensureDb $d
        if (-not $dbN.Sch.Contains($s)) {
            $dbN.Sch[$s] = [pscustomobject]@{ Name = $s; Objs = [System.Collections.Generic.List[object]]::new(); Seen = @{} }
        }
        $dbN.Sch[$s]
    }
    $addObj = {
        param([string]$d, [string]$s, [string]$n, [string]$ty, [string]$st, [int]$risk)
        if (-not $n) { return }
        $sN = & $ensureSch $d $s
        if ($sN.Seen.ContainsKey($n)) { return }
        $sN.Seen[$n] = $true
        $k = $d + '|' + $s + '|' + $n
        $sN.Objs.Add([pscustomobject]@{
            Name = $n; Type = $ty; Status = $st; Risk = [int]$risk; Find = (& $getCount $fCount $k)
        })
    }
    foreach ($o in $invAll) {
        if ([string]$o.ObjType -eq 'DB') { continue }
        $d = & $scopeKey $o.Database
        if (-not $d) { $d = '(instance/agent)' }
        & $addObj $d ([string]$o.Schema) ([string]$o.Object) ([string]$o.ObjType) ([string]$o.Status) ([int]$o.MaxRisk)
    }
    foreach ($f in $findings) {
        $d = & $scopeKey $f.Database
        if (-not $d) { $d = '(instance/agent)' }
        & $addObj $d ([string]$f.Schema) ([string]$f.Object) ([string]$f.ObjTypeDesc) ([string]$f.Status) ([int]$f.Risk)
    }
    foreach ($pd in @($S.PerDatabase)) { & $ensureDb ([string]$pd.Name) }
    if ($fCount.ContainsKey('(instance/agent)')) { & $ensureDb '(instance/agent)' }

    function Get-AdvScopeOrder {
        # databases / schemas with findings first, then alphabetically
        param($Keys)
        $out = @()
        foreach ($k in @($Keys)) {
            $n = 0
            $kk = [string]$k
            if ($fCount.ContainsKey($kk)) { $n = [int]$fCount[$kk] }
            $out += [pscustomobject]@{ Key = $kk; N = $n }
        }
        return , @($out | Sort-Object -Property @{Expression = { -[int]$_.N }}, @{Expression = { $_.Key }} | ForEach-Object { $_.Key })
    }

    function New-AdvGlyph {
        param([string]$Type)
        switch ([string]$Type.ToUpperInvariant()) {
            { $_ -in @('U', 'USER_TABLE') }                            { return 'T' }
            { $_ -in @('V', 'VIEW') }                                  { return 'V' }
            { $_ -in @('P', 'PC', 'SQL_STORED_PROCEDURE', 'CLR_STORED_PROCEDURE') } { return 'P' }
            { $_ -in @('FN', 'IF', 'TF', 'FS', 'FT', 'SQL_SCALAR_FUNCTION', 'SQL_INLINE_TABLE_VALUED_FUNCTION', 'SQL_TABLE_VALUED_FUNCTION') } { return 'f' }
            { $_ -in @('TR', 'A', 'SQL_TRIGGER', 'SQL_DDL_TRIGGER') }  { return '!' }
            { $_ -in @('SN', 'SYNONYM') }                              { return 's' }
            { $_ -in @('X', 'EXTENSION') }                             { return 'x' }
            { $_ -in @('D', 'DEFAULT_CONSTRAINT') }                    { return 'd' }
            { $_ -in @('R', 'RULE') }                                  { return 'r' }
            { $_ -in @('SO', 'OBJECT_TYPE_OR_USER_TABLE') }            { return 'o' }
            { $_ -in @('TT', 'TYPE_TABLE', 'USER_TABLE_TYPE') }        { return 't' }
            default                                                    { return '-' }
        }
    }
    function New-AdvGlyphClass {
        param([string]$Type)
        switch ([string]$Type.ToUpperInvariant()) {
            { $_ -in @('U', 'USER_TABLE') }                                     { return 'tg-tbl' }
            { $_ -in @('V', 'VIEW') }                                           { return 'tg-vw' }
            { $_ -in @('P', 'PC', 'SQL_STORED_PROCEDURE', 'CLR_STORED_PROCEDURE') } { return 'tg-prc' }
            { $_ -in @('FN', 'IF', 'TF', 'FS', 'FT', 'SQL_SCALAR_FUNCTION', 'SQL_INLINE_TABLE_VALUED_FUNCTION', 'SQL_TABLE_VALUED_FUNCTION') } { return 'tg-fn' }
            { $_ -in @('TR', 'A', 'SQL_TRIGGER', 'SQL_DDL_TRIGGER') }           { return 'tg-trg' }
            default                                                             { return 'tg-oth' }
        }
    }

    function New-AdvCell {
        param([string]$Text, [string]$Cls = '')
        $c = ''
        if ($Cls) { $c = ' class="' + $Cls + '"' }
        return ('<td{0}>{1}</td>' -f $c, (& $enc $Text))
    }
    function New-AdvTable {
        # Every grid is sortable out of the box: headers are buttons, the direction is
        # shown with an arrow, and $SortCol/$SortDir marks the order the rows are already in.
        # $Types marks numeric columns ('n') so they compare as numbers instead of text.
        param(
            [string[]]$Headers,
            [string[]]$Rows,
            [string]$Id = '',
            [string[]]$Types = @(),
            [int]$SortCol = -1,
            [string]$SortDir = 'desc'
        )
        $sb = [System.Text.StringBuilder]::new()
        $idAttr = ''
        if ($Id) { $idAttr = ' id="' + $Id + '"' }
        [void]$sb.Append('<table' + $idAttr + ' class="tbl"><thead><tr>')
        for ($i = 0; $i -lt $Headers.Count; $i++) {
            $t = ''
            if ($i -lt $Types.Count) { $t = [string]$Types[$i] }
            $def = 'asc'
            if ($t -eq 'n') { $def = 'desc' }
            $cls = 'sortable'
            $dirAttr = ''
            $aria = ''
            if ($i -eq $SortCol) {
                $cls += ' s' + $SortDir
                $def = $SortDir
                $dirAttr = ' data-dir="' + $SortDir + '" data-active="1"'
                if ($SortDir -eq 'desc') { $aria = ' aria-sort="descending"' } else { $aria = ' aria-sort="ascending"' }
            }
            [void]$sb.Append('<th class="' + $cls + '" data-t="' + (& $enc $t) + '" data-def="' + $def + '"' + $dirAttr + $aria +
                ' tabindex="0" role="button" title="Click to sort">' + (& $enc $Headers[$i]) + '<span class="sarrow"></span></th>')
        }
        [void]$sb.Append('</tr></thead><tbody>')
        foreach ($r in $Rows) { [void]$sb.Append($r) }
        [void]$sb.Append('</tbody></table>')
        return $sb.ToString()
    }

    $H = [System.Text.StringBuilder]::new()
    $server   = ''
    $srcVer   = ''
    if ($InstanceData -and $InstanceData.Instance) {
        $server = [string]$InstanceData.Instance.ServerName
        $srcVer = [string]$InstanceData.Instance.ProductVersion
    }

    # ---- head + styles ----------------------------------------------------------
    [void]$H.Append('<!DOCTYPE html>' + "`n")
    [void]$H.Append('<html lang="en"><head><meta charset="utf-8">' + "`n")
    [void]$H.Append('<title>SQL Upgrade Advisor - ' + (& $enc $server) + ' to SQL Server ' + (& $enc $TargetVersion) + '</title>' + "`n")
    [void]$H.Append('<style>' + "`n")
    [void]$H.Append(@'
:root{--ink:#1f2937;--mut:#6b7280;--line:#e5e7eb;--bg:#f6f7f9;--hd:#1e3a5f}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
body{margin:0;font-family:'Segoe UI',Roboto,Helvetica,Arial,sans-serif;color:var(--ink);background:var(--bg);font-size:14px}
.shell{display:flex;align-items:flex-start;min-height:100vh}
/* ---------------- left sidebar: breadcrumb nav + object tree filter ---------------- */
aside.side{position:sticky;top:0;flex:0 0 306px;width:306px;max-height:100vh;overflow-y:auto;background:#fff;border-right:1px solid var(--line);padding:0 0 18px}
aside.side::-webkit-scrollbar{width:9px}aside.side::-webkit-scrollbar-thumb{background:#c7ced6;border-radius:5px}
.brand{background:linear-gradient(135deg,#1e3a5f,#2f5c8f);color:#fff;padding:16px 16px 14px;position:sticky;top:0;z-index:6}
.brand h1{margin:0 0 3px;font-size:16px;letter-spacing:.3px}
.brand .sub{font-size:11.5px;opacity:.92;line-height:1.45}
.brand .tgt{display:inline-block;margin-top:7px;background:rgba(255,255,255,.16);border:1px solid rgba(255,255,255,.3);border-radius:12px;padding:2px 10px;font-size:11.5px;font-weight:600}
.side-sec{padding:13px 14px 4px}
.side-h{font-size:10.5px;font-weight:700;letter-spacing:.9px;text-transform:uppercase;color:var(--mut);margin:0 0 8px;display:flex;justify-content:space-between;align-items:center}
.side-h .link{font-size:10.5px;font-weight:600;letter-spacing:0;text-transform:none;color:#1565c0;cursor:pointer;border:0;background:none;padding:0}
/* breadcrumb (report sections) */
nav.crumb{list-style:none;margin:0;padding:0;font-size:12.5px}
nav.crumb li{margin:0}
nav.crumb a{display:flex;gap:7px;align-items:baseline;text-decoration:none;color:#334155;padding:5px 7px;border-radius:5px;border-left:2px solid transparent}
nav.crumb a:hover{background:#eef4fb;color:#123c6b}
nav.crumb a .ix{font-size:10px;color:#94a3b8;min-width:14px;font-variant-numeric:tabular-nums}
nav.crumb a .lab{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
nav.crumb a .n{font-size:10.5px;background:#eef0f3;color:#475569;border-radius:9px;padding:0 7px;font-variant-numeric:tabular-nums}
nav.crumb a.on{background:#e8f0fa;border-left-color:#2f5c8f;color:#0f3f74;font-weight:600}
nav.crumb a.on .n{background:#2f5c8f;color:#fff}
nav.crumb a.done .ix{color:#2e7d32}
/* scope breadcrumb */
.scope-crumb{display:flex;flex-wrap:wrap;gap:3px;align-items:center;font-size:11.5px;background:#f5f7fa;border:1px solid var(--line);border-radius:6px;padding:6px 8px;min-height:30px}
.scope-crumb .seg{cursor:pointer;color:#1565c0;border-radius:4px;padding:1px 4px;white-space:nowrap}
.scope-crumb .seg:hover{background:#e3f0fd;text-decoration:underline}
.scope-crumb .sep{color:#94a3b8}
.scope-crumb .cur{font-weight:700;color:var(--hd)}
.scope-crumb .clr{margin-left:auto;cursor:pointer;color:#b71c1c;font-weight:600}
/* tree filter */
.tree-filter{font-size:12.5px;user-select:none}
.tree-filter input{width:100%;padding:6px 8px;border:1px solid #cbd2d9;border-radius:5px;font-size:12.5px;margin-bottom:7px}
.tnode{display:flex;align-items:center;gap:5px;padding:3px 5px;border-radius:5px;cursor:pointer;position:relative}
.tnode:hover{background:#eef4fb}
.tnode.sel{background:#dbe9fb;color:#0f3f74;font-weight:600;box-shadow:inset 2px 0 0 #2f5c8f}
.tnode .tw{width:11px;color:#8aa0b8;font-size:9px;text-align:center;flex:0 0 11px}
.tnode .tg{width:15px;height:15px;border-radius:3px;font-size:9.5px;font-weight:700;color:#fff;display:flex;align-items:center;justify-content:center;flex:0 0 15px}
.tnode .tn{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.tnode .tc{font-size:10.5px;background:#eef0f3;color:#475569;border-radius:9px;padding:0 6px;font-variant-numeric:tabular-nums}
.tnode .tc.hot{background:#fdecea;color:#b71c1c;font-weight:700}
.tnode .tc.obj{background:#f1f5f9;color:#64748b}
.tg-db{background:#2f5c8f}.tg-sch{background:#64748b}.tg-tbl{background:#7b5ea7}.tg-vw{background:#2e7d32}
.tg-prc{background:#ef6c00}.tg-fn{background:#00838f}.tg-trg{background:#b58900}.tg-oth{background:#90a4ae}
.tkids{margin-left:11px;border-left:1px solid #e6ebf1;padding-left:3px}
.tkids.hide{display:none}
.tcount{font-size:11px;color:var(--mut);padding:2px 5px 7px}
/* ---------------- main column ---------------- */
.content{flex:1 1 auto;min-width:0}
header.top{background:linear-gradient(135deg,#1e3a5f,#2f5c8f);color:#fff;padding:20px 26px}
header.top h1{margin:0 0 4px;font-size:21px;letter-spacing:.4px}
header.top .sub{opacity:.9;font-size:13px}
header.top .meta{margin-top:9px;font-size:12.5px;opacity:.92}
header.top .meta b{font-weight:600}
main{padding:18px 26px 40px;max-width:1720px;margin:0 auto}
section{background:#fff;border:1px solid var(--line);border-radius:8px;padding:16px 18px;margin-bottom:18px;box-shadow:0 1px 2px rgba(0,0,0,.04);scroll-margin-top:12px}
section h2{margin:0 0 12px;font-size:16px;color:var(--hd);border-bottom:2px solid var(--line);padding-bottom:8px;display:flex;align-items:center;gap:9px;flex-wrap:wrap}
section h2 .muted{font-weight:400;font-size:12.5px}
section h3{margin:16px 0 8px;font-size:14px;color:var(--hd)}
.cards{display:flex;flex-wrap:wrap;gap:12px}
.card{flex:1 1 170px;border:1px solid var(--line);border-left:5px solid #999;border-radius:6px;padding:10px 12px;background:#fbfbfc}
.card .cv{font-size:26px;font-weight:700;line-height:1.1}
.card .cl{font-size:12.5px;font-weight:600;margin-top:2px}
.card .cn{font-size:11px;color:var(--mut);margin-top:2px}
.c-break{border-left-color:#c62828}.c-adjust{border-left-color:#ef6c00}.c-sec{border-left-color:#6a1b9a}
.c-depr{border-left-color:#b58900}.c-review{border-left-color:#1565c0}.c-modern{border-left-color:#2e7d32}
.c-blind{border-left-color:#78909c}.c-ok{border-left-color:#43a047}
/* ---------------- charts (pure SVG/CSS, no external deps) ---------------- */
.viz{display:flex;flex-wrap:wrap;gap:16px;margin-top:6px}
.viz .vbox{flex:1 1 320px;min-width:290px;border:1px solid var(--line);border-radius:7px;padding:11px 13px 13px;background:#fdfdfe}
.viz .vbox.wide{flex:1 1 100%}
.viz .vt{font-size:12.5px;font-weight:700;color:var(--hd);margin-bottom:2px}
.viz .vs{font-size:11px;color:var(--mut);margin-bottom:9px}
.donut-wrap{display:flex;gap:14px;align-items:center;flex-wrap:wrap}
.donut-wrap svg{flex:0 0 auto}
.legend{font-size:12px;flex:1 1 190px;min-width:180px}
.legend .li{display:flex;align-items:center;gap:7px;padding:2px 0}
.legend .sw{width:11px;height:11px;border-radius:3px;flex:0 0 11px}
.legend .lb{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.legend .vl{font-variant-numeric:tabular-nums;font-weight:600;color:#334155}
.legend .pc{font-size:10.5px;color:var(--mut);min-width:34px;text-align:right}
.stack{display:flex;height:17px;border-radius:4px;overflow:hidden;background:#eef0f3;border:1px solid #e2e6ea}
.stack div{height:100%}
.dbar{display:flex;align-items:center;gap:9px;margin:6px 0;font-size:12px}
.dbar .dl{width:132px;flex:0 0 132px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#334155}
.dbar .dtr{flex:1;min-width:60px}
.dbar .dv{width:74px;flex:0 0 74px;text-align:right;color:var(--mut);font-variant-numeric:tabular-nums;font-size:11.5px}
.dbar .dmax{width:52px;flex:0 0 52px;text-align:right;font-weight:700;font-variant-numeric:tabular-nums}
.tbls{display:flex;flex-direction:column;gap:3px}
.tbls .tr2{display:flex;align-items:center;gap:8px;font-size:12px}
.tbls .tl2{width:170px;flex:0 0 170px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#334155}
.tbls .tk{flex:1;min-width:60px;height:15px;background:#eef0f3;border-radius:3px;overflow:hidden}
.tbls .tk i{display:block;height:100%;background:#2f5c8f;border-radius:3px}
.tbls .tv{width:34px;flex:0 0 34px;text-align:right;font-variant-numeric:tabular-nums;color:var(--mut);font-size:11.5px}
.sbar{display:flex;align-items:center;gap:8px;font-size:12px;margin:4px 0}
.sbar .sl{width:132px;flex:0 0 132px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.sbar .st{flex:1;height:15px;background:#eef0f3;border-radius:3px;overflow:hidden}
.sbar .st i{display:block;height:100%;border-radius:3px}
.sbar .sv{width:38px;flex:0 0 38px;text-align:right;font-variant-numeric:tabular-nums;color:var(--mut);font-size:11.5px}
.sbar .sp{width:42px;flex:0 0 42px;text-align:right;font-size:10.5px;color:#94a3b8;font-variant-numeric:tabular-nums}
/* ---------------- tables + sorting ---------------- */
table.tbl{border-collapse:collapse;width:100%;font-size:12.5px}
.tbl th{background:var(--hd);color:#fff;text-align:left;padding:7px 8px;position:sticky;top:0;font-weight:600;white-space:nowrap;cursor:pointer;user-select:none;outline:none}
.tbl th:hover{background:#2b5083}
.tbl th:focus-visible{box-shadow:inset 0 0 0 2px #ffd54f}
.tbl th .sarrow{display:inline-block;width:9px;margin-left:4px;color:#a9c4e2;font-size:9px;opacity:.65}
.tbl th[data-active="1"]{background:#0f3f74}
.tbl th[data-active="1"] .sarrow{opacity:1;color:#ffd54f}
.tbl th[data-dir="asc"] .sarrow::after{content:"\25B2"}
.tbl th[data-dir="desc"] .sarrow::after{content:"\25BC"}
.tbl th[data-dir]:not([data-active="1"]) .sarrow::after{content:"\25B2"}
.tbl td{border-bottom:1px solid var(--line);padding:6px 8px;vertical-align:top}
.tbl tbody tr:nth-child(even){background:#fafbfc}
.tbl tbody tr:hover{background:#eef4fb}
.tbl code{display:block;white-space:pre-wrap;word-break:break-word;font-family:Consolas,'Courier New',monospace;font-size:11.5px;background:#f4f6f8;border:1px solid #e8ebef;border-radius:4px;padding:4px 6px;max-width:520px}
.muted{color:var(--mut);font-size:11.5px}
.badge{display:inline-block;padding:2px 9px;border-radius:11px;font-size:11px;font-weight:700;white-space:nowrap}
.st-break{background:#fdecea;color:#b71c1c}.st-adjust{background:#fff3e0;color:#e65100}
.st-security{background:#f3e5f5;color:#6a1b9a}.st-depr{background:#fff8e1;color:#9e7c00}
.st-review{background:#e3f2fd;color:#0d47a1}.st-modern{background:#e8f5e9;color:#1b5e20}
.st-blind{background:#eceff1;color:#37474f}.st-ok{background:#e8f5e9;color:#2e7d32}
.sev-critical{color:#b71c1c;font-weight:700}.sev-high{color:#c62828;font-weight:600}
.sev-medium{color:#ef6c00}.sev-low{color:#546e7a}.sev-info{color:#1565c0}
.risk-hi{color:#b71c1c;font-weight:700}.risk-md{color:#ef6c00;font-weight:600}.risk-lo{color:var(--mut)}
.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.controls{display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-bottom:10px}
.controls input,.controls select{padding:6px 9px;border:1px solid #cbd2d9;border-radius:5px;font-size:13px;background:#fff}
.controls input{min-width:260px}
.controls .cnt{font-size:12px;color:var(--mut)}
.chip{display:inline-flex;align-items:center;gap:6px;background:#e8f0fa;border:1px solid #bcd4ee;color:#0f3f74;border-radius:13px;padding:3px 11px;font-size:11.5px;font-weight:600}
.chip .x{cursor:pointer;color:#b71c1c;font-weight:700}
.barrow{display:flex;align-items:center;gap:8px;margin:5px 0;font-size:12px}
.blabel{width:150px;color:var(--ink)}
.btrack{flex:1;background:#eef0f3;border-radius:4px;height:14px;overflow:hidden}
.bfill{height:100%;border-radius:4px}
.bval{width:46px;text-align:right;color:var(--mut);font-variant-numeric:tabular-nums}
.note{background:#fffbea;border:1px solid #f2e3ad;border-radius:6px;padding:8px 10px;font-size:12.5px;margin:10px 0}
a{color:#1565c0}
footer{color:var(--mut);font-size:11.5px;padding:6px 26px 26px;max-width:1720px;margin:0 auto}
.scroll{max-height:620px;overflow:auto;border:1px solid var(--line);border-radius:6px}
.scroll .tbl th{top:0;z-index:2}
@media (max-width:1080px){
  .shell{display:block}
  aside.side{position:static;width:auto;flex:none;max-height:none;border-right:0;border-bottom:1px solid var(--line)}
  .brand{position:static}
}
@media print{
  aside.side{display:none}
  body{background:#fff}
  section{break-inside:avoid;box-shadow:none}
}
'@)
    [void]$H.Append('</style></head><body>' + "`n")
    [void]$H.Append('<div class="shell">')

    # ---- sidebar: breadcrumb section nav + Database/Schema/Object tree filter ----
    $tree = [System.Text.StringBuilder]::new()
    $leafBudget = 3000
    $leafShown = 0
    [void]$tree.Append('<div class="tnode" data-lvl="all" onclick="setScope(this)">' +
        '<span class="tw"></span><span class="tg tg-db">A</span>' +
        '<span class="tn">All databases</span><span class="tc">' + [int]$S.TotalFindings + '</span></div>')
    if ($fCount.ContainsKey('(instance/agent)')) {
        $ic = [int]$fCount['(instance/agent)']
        [void]$tree.Append('<div class="tnode" data-lvl="db" data-db="(instance/agent)" onclick="setScope(this)">' +
            '<span class="tw"></span><span class="tg tg-oth">i</span>' +
            '<span class="tn">Instance / agent scope</span><span class="tc hot">' + $ic + '</span></div>')
    }
    $dbIdx = 0
    foreach ($dk in (Get-AdvScopeOrder -Keys @($T.Keys))) {
        $dbN = $T[$dk]
        $dCount = (& $getCount $fCount $dk)
        $dCls = ''
        if ($dCount -gt 0) { $dCls = ' hot' }
        $dbKId = 'k_d' + $dbIdx
        $dbIdx++
        [void]$tree.Append('<div class="tnode" data-lvl="db" data-db="' + (& $enc $dk) + '" onclick="setScope(this)">' +
            '<span class="tw" onclick="event.stopPropagation();toggleKids(''' + $dbKId + ''')">&#9656;</span>' +
            '<span class="tg tg-db">D</span><span class="tn">' + (& $enc $dbN.Name) + '</span>' +
            '<span class="tc' + $dCls + '">' + $dCount + '</span></div>')
        [void]$tree.Append('<div class="tkids" id="' + $dbKId + '">')
        $schIdx = 0
        foreach ($sk in (Get-AdvScopeOrder -Keys @($dbN.Sch.Keys))) {
            $sN = $dbN.Sch[$sk]
            $sCount = (& $getCount $fCount ($dk + '|' + $sk))
            $sCls = ''
            if ($sCount -gt 0) { $sCls = ' hot' }
            $sLbl = $sk
            if (-not $sLbl) { $sLbl = '(database level)' }
            $sKId = 'k_s' + $dbIdx + '_' + $schIdx
            $schIdx++
            $openCls = ''
            if ($sCount -gt 0) { $openCls = ' open' }
            [void]$tree.Append('<div class="tnode' + $openCls + '" data-lvl="sch" data-db="' + (& $enc $dk) +
                '" data-sch="' + (& $enc $sk) + '" onclick="setScope(this)">' +
                '<span class="tw" onclick="event.stopPropagation();toggleKids(''' + $sKId + ''')">&#9656;</span>' +
                '<span class="tg tg-sch">S</span><span class="tn">' + (& $enc $sLbl) + '</span>' +
                '<span class="tc' + $sCls + '">' + $sCount + '</span></div>')
            [void]$tree.Append('<div class="tkids" id="' + $sKId + '">')
            $objs = @($sN.Objs | Sort-Object -Property @{Expression = { -[int]$_.Find }}, @{Expression = { [string]$_.Name }})
            $objIdx = 0
            foreach ($o in $objs) {
                if ($leafShown -ge $leafBudget) { break }
                $objIdx++
                $leafShown++
                $oCls = ' obj'
                if ($o.Find -gt 0) { $oCls = ' hot' }
                $gClass = New-AdvGlyphClass -Type $o.Type
                $g = New-AdvGlyph -Type $o.Type
                [void]$tree.Append('<div class="tnode" data-lvl="obj" data-db="' + (& $enc $dk) + '" data-sch="' + (& $enc $sk) +
                    '" data-obj="' + (& $enc $o.Name) + '" onclick="setScope(this)">' +
                    '<span class="tw"></span><span class="tg ' + $gClass + '">' + (& $enc $g) + '</span>' +
                    '<span class="tn">' + (& $enc $o.Name) + '</span><span class="tc' + $oCls + '">' + $o.Find + '</span></div>')
            }
            if ($objs.Count -gt $objIdx) {
                [void]$tree.Append('<div class="tcount">... ' + ($objs.Count - $objIdx) + ' more object(s) not listed (tree cap ' + $leafBudget + ')</div>')
            }
            [void]$tree.Append('</div>')
        }
        [void]$tree.Append('</div>')
    }
    $treeHtml = $tree.ToString()

    $navItems = @(
        @{ Id = 'sec-summary';   Label = 'Executive summary';    N = [int]$S.TotalFindings }
        @{ Id = 'sec-databases'; Label = 'Databases assessed';   N = [int]$S.DatabasesAssessed }
        @{ Id = 'sec-findings';  Label = 'Findings';             N = $shown.Count }
        @{ Id = 'sec-backlog';   Label = 'Remediation backlog';  N = @($Engine.Backlog).Count }
        @{ Id = 'sec-blind';     Label = 'Blind spots';          N = $blind.Count }
        @{ Id = 'sec-inventory'; Label = 'Object inventory';     N = $invBad.Count }
        @{ Id = 'sec-rules';     Label = 'Rules catalog';        N = @($Engine.ActiveRules).Count }
        @{ Id = 'sec-coverage';  Label = 'Collection coverage';  N = @($Coverage).Count }
    )
    [void]$H.Append('<aside class="side">' + "`n")
    [void]$H.Append('<div class="brand"><h1>SQL Upgrade Advisor</h1>' +
        '<div class="sub">' + (& $enc $server) + ' &rarr; SQL Server ' + (& $enc $TargetVersion) + '</div>' +
        '<span class="tgt">compatibility level ' + $TargetCompat + '</span></div>')
    [void]$H.Append('<div class="side-sec"><div class="side-h">Report sections</div><nav class="crumb" id="secnav">')
    $ix = 0
    foreach ($n in $navItems) {
        $ix++
        [void]$H.Append('<a href="#' + $n.Id + '" data-sec="' + $n.Id + '"><span class="ix">' + $ix + '</span>' +
            '<span class="lab">' + (& $enc $n.Label) + '</span><span class="n">' + [int]$n.N + '</span></a>')
    }
    [void]$H.Append('</nav></div>' + "`n")
    [void]$H.Append('<div class="side-sec"><div class="side-h">Scope</div>' +
        '<div class="scope-crumb" id="scopeCrumb"></div></div>' + "`n")
    [void]$H.Append('<div class="side-sec"><div class="side-h">Database &rsaquo; schema &rsaquo; object</div>' +
        '<div class="tree-filter"><input id="tSearch" type="search" placeholder="Filter the tree..." oninput="filterTree()">' +
        '<div id="objTree">' + $treeHtml + '</div>' +
        '<div class="tcount" id="treeCount"></div></div></div>' + "`n")
    [void]$H.Append('</aside>' + "`n")

    [void]$H.Append('<div class="content">')

    # ---- header -----------------------------------------------------------------
    [void]$H.Append('<header class="top"><h1>SQL Upgrade Advisor</h1>')
    [void]$H.Append('<div class="sub">Version compatibility &amp; modernization assessment &mdash; ' +
        (& $enc $server) + ' &rarr; SQL Server ' + (& $enc $TargetVersion) + ' (compatibility level ' + $TargetCompat + ')</div>')
    [void]$H.Append('<div class="meta">Source engine: <b>' + (& $enc $srcVer) +
        '</b> &nbsp;|&nbsp; Databases assessed: <b>' + [int]$S.DatabasesAssessed +
        '</b> &nbsp;|&nbsp; Objects assessed: <b>' + [int]$S.ObjectsAssessed +
        '</b> &nbsp;|&nbsp; Rules active: <b>' + [int]$S.RulesActive +
        '</b> &nbsp;|&nbsp; Generated: <b>' + (& $enc $S.GeneratedAt) +
        ' (' + [int]$S.ElapsedSec + 's)</b> &nbsp;|&nbsp; Tool v' + (& $enc $S.ToolVersion) + '</div>')
    [void]$H.Append('</header><main>' + "`n")
    [void]$H.Append('<section><h2>What this assessment does not prove</h2><p class="muted">')
    [void]$H.Append('This report is a static metadata and regular-expression scan. It does not parse T-SQL with ScriptDom, ')
    [void]$H.Append('does not replay a workload, and does not compile objects on the target. ')
    [void]$H.Append('&quot;No static findings&quot; means no rule matched. Encrypted modules, dynamic SQL, and non-T-SQL Agent steps are blind spots. ')
    [void]$H.Append('Plan-cache hotness is since the last cache recycle, not lifetime usage. ')
    [void]$H.Append('Regex rules can miss SELECT DISTINCT *, nested dynamic SQL, and some hint forms, and can flag a pattern inside an unusual statement. ')
    [void]$H.Append('Deprecated-feature counters reset when the instance restarts. Validate every blocker in a test environment before upgrading.')
    [void]$H.Append('</p></section>')

    # ---- summary cards + visual overview ----------------------------------------
    $cards = @(
        @{ L = 'Will break';         V = $S.WillBreak;         C = 'c-break';   N = 'fails or is unavailable on target' }
        @{ L = 'Needs adjustment';   V = $S.NeedsAdjustment;   C = 'c-adjust';  N = 'behavior / plan changes expected' }
        @{ L = 'Security concern';   V = $S.SecurityConcern;   C = 'c-sec';     N = 'trust &amp; privilege surface' }
        @{ L = 'Deprecated usage';   V = $S.DeprecatedUsage;   C = 'c-depr';    N = 'works today, remove before deprecation' }
        @{ L = 'Needs review';       V = $S.NeedsReview;       C = 'c-review';  N = 'manual verification required' }
        @{ L = 'Modernization';      V = $S.Modernization;     C = 'c-modern';  N = 'quality &amp; performance wins' }
        @{ L = 'Blind spots';        V = $S.BlindSpots;        C = 'c-blind';   N = 'encrypted / dynamic / non-TSQL' }
        @{ L = 'No static findings'; V = $S.ObjectsCompatible; C = 'c-ok';      N = 'not proven compatible at runtime' }
    )
    [void]$H.Append('<section id="sec-summary"><h2>Executive summary</h2><div class="cards">')
    foreach ($c in $cards) {
        [void]$H.Append('<div class="card ' + $c.C + '"><div class="cv">' + [int]$c.V + '</div><div class="cl">' + $c.L + '</div><div class="cn">' + $c.N + '</div></div>')
    }
    [void]$H.Append('</div>')

    $total = [Math]::Max(1, [int]$S.TotalFindings)
    $fmt2 = { param($x) [string]::Format([cultureinfo]::InvariantCulture, '{0:0.00}', $x) }

    # ---- chart 1: status distribution donut (pure SVG) --------------------------
    $segs = @()
    foreach ($kv in $S.ByStatus.GetEnumerator()) {
        if ([int]$kv.Value -le 0) { continue }
        $segs += [pscustomobject]@{ Label = [string]$kv.Key; N = [int]$kv.Value; Color = (Get-AdvStatusColor -Status ([string]$kv.Key)) }
    }
    $segTotal = 0
    foreach ($sx in $segs) { $segTotal += $sx.N }
    if ($segTotal -le 0) { $segTotal = 1 }
    $R = 56.0
    $C = 2 * [Math]::PI * $R
    $svg = '<svg width="164" height="164" viewBox="0 0 164 164" role="img" aria-label="Findings by status">' +
        '<circle cx="82" cy="82" r="56" fill="none" stroke="#eef0f3" stroke-width="22"/>'
    $legend = ''
    $cum = 0.0
    foreach ($sx in $segs) {
        $frac = $sx.N / [double]$segTotal
        $len = ($frac * $C) - 1.6
        if ($len -lt 0.4) { $len = 0.4 }
        $off = -($cum * $C)
        $svg += '<circle cx="82" cy="82" r="56" fill="none" stroke="' + $sx.Color + '" stroke-width="22" stroke-dasharray="' +
            (& $fmt2 $len) + ' ' + (& $fmt2 ($C - $len)) + '" stroke-dashoffset="' + (& $fmt2 $off) +
            '" transform="rotate(-90 82 82)"><title>' + (& $enc $sx.Label) + ': ' + $sx.N + '</title></circle>'
        $cum += $frac
        $pct = [Math]::Round(($sx.N * 100.0) / $segTotal, 1)
        $legend += '<div class="li"><span class="sw" style="background:' + $sx.Color + '"></span>' +
            '<span class="lb">' + (& $enc $sx.Label) + '</span><span class="vl">' + $sx.N + '</span><span class="pc">' + $pct + '%</span></div>'
    }
    $svg += '<text x="82" y="79" text-anchor="middle" font-size="27" font-weight="700" fill="#1e3a5f">' + [int]$S.TotalFindings + '</text>' +
        '<text x="82" y="97" text-anchor="middle" font-size="10.5" fill="#6b7280">findings</text></svg>'

    # ---- chart 4: findings per database, stacked by status ----------------------
    $stOrder = @('Will break', 'Needs adjustment', 'Security concern', 'Deprecated usage', 'Needs review', 'Modernization', 'Not assessable')
    $dbStack = @()
    foreach ($pd in @($S.PerDatabase)) {
        $nm = [string]$pd.Name
        $fs = @($findings | Where-Object { [string]$_.Database -eq $nm })
        if ($fs.Count -eq 0) { continue }
        $parts = @()
        foreach ($stx in $stOrder) {
            $c = @($fs | Where-Object { [string]$_.Status -eq $stx }).Count
            if ($c -gt 0) { $parts += [pscustomobject]@{ N = $c; Status = $stx } }
        }
        $mx = [int]($fs | Measure-Object -Property Risk -Maximum).Maximum
        $dbStack += [pscustomobject]@{ Name = $nm; Total = $fs.Count; Parts = $parts; MaxRisk = $mx }
    }
    $dbStack = @($dbStack | Sort-Object -Property @{Expression = { [int]$_.Total }; Descending = $true})

    [void]$H.Append('<h3>Visual overview</h3><div class="viz">')

    [void]$H.Append('<div class="vbox"><div class="vt">Findings by status</div><div class="vs">where the work is concentrated</div>' +
        '<div class="donut-wrap">' + $svg + '<div class="legend">' + $legend + '</div></div></div>')

    # ---- chart 2: severity distribution ----------------------------------------
    $sevMax = 1
    foreach ($kv in $S.BySeverity.GetEnumerator()) { if ([int]$kv.Value -gt $sevMax) { $sevMax = [int]$kv.Value } }
    $sevHtml = ''
    foreach ($kv in $S.BySeverity.GetEnumerator()) {
        $pct = [Math]::Round(([int]$kv.Value * 100.0) / $sevMax, 2)
        $sevHtml += '<div class="sbar"><span class="sl">' + (& $enc $kv.Key) + '</span>' +
            '<span class="st"><i style="width:' + $pct + '%;background:' + (Get-AdvSeverityColor -Severity ([string]$kv.Key)) + '"></i></span>' +
            '<span class="sv">' + [int]$kv.Value + '</span>' +
            '<span class="sp">' + [Math]::Round(([int]$kv.Value * 100.0) / $total, 1) + '%</span></div>'
    }
    [void]$H.Append('<div class="vbox"><div class="vt">Severity mix</div><div class="vs">count and share of all findings</div>' + $sevHtml + '</div>')

    # ---- chart 3: risk bands ----------------------------------------------------
    $bandMax = 1
    foreach ($kv in $S.RiskBands.GetEnumerator()) { if ([int]$kv.Value -gt $bandMax) { $bandMax = [int]$kv.Value } }
    $bandColor = @{ 'Critical (70-100)' = '#b71c1c'; 'High (50-69)' = '#e53935'; 'Medium (30-49)' = '#ef6c00'; 'Low (0-29)' = '#546e7a' }
    $bandHtml = ''
    foreach ($kv in $S.RiskBands.GetEnumerator()) {
        $pct = [Math]::Round(([int]$kv.Value * 100.0) / $bandMax, 2)
        $col = '#1565c0'
        if ($bandColor.ContainsKey([string]$kv.Key)) { $col = $bandColor[[string]$kv.Key] }
        $bandHtml += '<div class="sbar"><span class="sl">' + (& $enc $kv.Key) + '</span>' +
            '<span class="st"><i style="width:' + $pct + '%;background:' + $col + '"></i></span>' +
            '<span class="sv">' + [int]$kv.Value + '</span>' +
            '<span class="sp">' + [Math]::Round(([int]$kv.Value * 100.0) / $total, 1) + '%</span></div>'
    }
    [void]$H.Append('<div class="vbox"><div class="vt">Risk bands</div><div class="vs">0&ndash;100 composite risk score</div>' + $bandHtml + '</div>')

    # ---- chart 4: per-database stacked bars -------------------------------------
    $stColors = @{}
    foreach ($stx in $stOrder) { $stColors[$stx] = Get-AdvStatusColor -Status $stx }
    $stHtml = ''
    foreach ($d2 in $dbStack) {
        $segHtml = ''
        foreach ($p in $d2.Parts) {
            $w = [Math]::Round(($p.N * 100.0) / $d2.Total, 2)
            $segHtml += '<div style="width:' + $w + '%;background:' + $stColors[[string]$p.Status] + '" title="' +
                (& $enc $p.Status) + ': ' + $p.N + '"></div>'
        }
        $stHtml += '<div class="dbar"><span class="dl">' + (& $enc $d2.Name) + '</span>' +
            '<span class="dtr"><span class="stack">' + $segHtml + '</span></span>' +
            '<span class="dv">' + $d2.Total + ' findings</span><span class="dmax risk-' +
            $(if ($d2.MaxRisk -ge 50) { 'hi' } elseif ($d2.MaxRisk -ge 30) { 'md' } else { 'lo' }) + '">' + $d2.MaxRisk + '</span></div>'
    }
    if (-not $stHtml) { $stHtml = '<div class="muted">No findings.</div>' }
    $legHtml = '<div class="vs" style="margin-top:8px">'
    foreach ($stx in $stOrder) {
        $legHtml += '<span class="li" style="display:inline-flex;gap:5px;margin-right:12px;align-items:center">' +
            '<span class="sw" style="background:' + $stColors[$stx] + '"></span>' + (& $enc $stx) + '</span>'
    }
    $legHtml += '</div>'
    [void]$H.Append('<div class="vbox wide"><div class="vt">Findings by database</div>' +
        '<div class="vs">stacked by status, last column is max risk</div>' + $stHtml + $legHtml + '</div>')

    # ---- chart 5: top rules -----------------------------------------------------
    $topRules = @($S.TopRules)
    $trMax = 1
    foreach ($t in $topRules) { if ([int]$t.Count -gt $trMax) { $trMax = [int]$t.Count } }
    $trHtml = ''
    foreach ($t in $topRules) {
        $w = [Math]::Round(([int]$t.Count * 100.0) / $trMax, 2)
        $trHtml += '<div class="tr2"><span class="tl2" title="' + (& $enc $t.Title) + '"><b>' + (& $enc $t.RuleId) + '</b> ' +
            (& $enc $t.Title) + '</span><span class="tk"><i style="width:' + $w + '%;background:' +
            (Get-AdvStatusColor -Status ([string]$t.Status)) + '"></i></span>' +
            '<span class="tv">' + [int]$t.Count + '</span></div>'
    }
    if (-not $trHtml) { $trHtml = '<div class="muted">No findings.</div>' }
    [void]$H.Append('<div class="vbox wide"><div class="vt">Rules firing most often</div>' +
        '<div class="vs">top 10 by finding count - each bar is one remediation work item</div><div class="tbls">' + $trHtml + '</div></div>')

    [void]$H.Append('</div>')

    # status distribution bars
    [void]$H.Append('<h3>Status distribution</h3>')
    foreach ($kv in $S.ByStatus.GetEnumerator()) {
        $cnt = [int]$kv.Value
        if ($cnt -le 0) { continue }
        $pct = [Math]::Round(($cnt * 100.0) / $total, 1)
        if ($pct -lt 1.5) { $pct = 1.5 }
        [void]$H.Append('<div class="barrow"><span class="blabel">' + (& $enc $kv.Key) + '</span>' +
            '<div class="btrack"><div class="bfill ' + (Get-AdvStatusClass -Status ([string]$kv.Key)) + '" style="width:' + $pct + '%;background:' + (Get-AdvStatusColor -Status ([string]$kv.Key)) + '"></div></div>' +
            '<span class="bval">' + $cnt + '</span></div>')
    }
    if ([int]$S.HighRisk -gt 0) {
        [void]$H.Append('<div class="note"><b>' + [int]$S.HighRisk + ' finding(s) carry risk &ge; 50</b> ' +
            '(severity weighted by plan-cache hotness, dependency fan-in and repetition). Full scoring detail is in the Findings table and the Excel export.</div>')
    }
    [void]$H.Append('</section>' + "`n")

    # ---- databases --------------------------------------------------------------
    $dbRows = @()
    foreach ($d in @($S.PerDatabase)) {
        $dbRows += ('<tr data-db="' + (& $enc $d.Name) + '">' +
            (New-AdvCell -Text $d.Name) +
            (New-AdvCell -Text $d.Objects -Cls 'num') +
            (New-AdvCell -Text $d.CompatibleObjects -Cls 'num') +
            (New-AdvCell -Text $d.Findings -Cls 'num') +
            (New-AdvCell -Text $d.WillBreak -Cls 'num') +
            (New-AdvCell -Text $d.Deprecated -Cls 'num') +
            (New-AdvCell -Text $d.MaxRisk -Cls 'num') + '</tr>')
    }
    [void]$H.Append('<section id="sec-databases"><h2>Databases assessed</h2>')
    [void]$H.Append((New-AdvTable -Id 'dbTable' -Headers @('Database', 'Objects', 'No static findings', 'Findings', 'Will break', 'Deprecated', 'Max risk') -Rows $dbRows `
        -Types @('', 'n', 'n', 'n', 'n', 'n', 'n') -SortCol 3 -SortDir 'desc'))
    [void]$H.Append('</section>' + "`n")

    # ---- findings ---------------------------------------------------------------
    $findings = @($Engine.Findings | Sort-Object -Property @{Expression = { [int]$_.Risk }; Descending = $true}, @{Expression = { [int]$_.TotalMatches }; Descending = $true})
    $shown = $findings
    $truncated = $false
    if ($MaxFindings -gt 0 -and $findings.Count -gt $MaxFindings) { $shown = @($findings | Select-Object -First $MaxFindings); $truncated = $true }

    $fRows = New-Object System.Collections.Generic.List[string]
    foreach ($f in $shown) {
        $riskCls = 'risk-lo'
        if ($f.Risk -ge 50) { $riskCls = 'risk-hi' } elseif ($f.Risk -ge 30) { $riskCls = 'risk-md' }
        $objP = ''
        if ($f.Schema) { $objP = $f.Schema + '.' + $f.Object } else { $objP = [string]$f.Object }
        $objMeta = [string]$f.ObjTypeDesc
        if ($f.Line -gt 0) { $objMeta += ' - line ' + $f.Line }
        $doc = ''
        if ($f.DocUrl) { $doc = '<a href="' + (& $enc $f.DocUrl) + '" target="_blank" rel="noopener">MS Learn</a>' } else { $doc = '-' }
        $row = '<tr data-status="' + (& $enc $f.Status) + '" data-severity="' + (& $enc $f.Severity) + '" data-db="' + (& $enc $f.Database) + '">' +
            (New-AdvCell -Text $f.Risk -Cls ($riskCls + ' num')) +
            '<td><span class="badge ' + (Get-AdvStatusClass -Status $f.Status) + '">' + (& $enc $f.Status) + '</span></td>' +
            '<td class="' + (Get-AdvSeverityClass -Severity $f.Severity) + '">' + (& $enc $f.Severity) + '</td>' +
            (New-AdvCell -Text $f.Category) +
            (New-AdvCell -Text $(if ($f.Database) { $f.Database } else { '(instance/agent)' })) +
            (New-AdvCell -Text $objP) +
            '<td class="muted">' + (& $enc $objMeta) + '</td>' +
            '<td><b>' + (& $enc $f.RuleId) + '</b><div class="muted">' + (& $enc $f.Title) + '</div></td>' +
            '<td><code>' + (& $enc $f.Evidence) + '</code></td>' +
            (New-AdvCell -Text $f.Recommendation) +
            (New-AdvCell -Text $f.TotalMatches -Cls 'num') +
            (New-AdvCell -Text $f.BlastRadius -Cls 'num') +
            (New-AdvCell -Text ('{0:n0}' -f $f.Hotness) -Cls 'num') +
            '<td>' + $doc + '</td></tr>'
        $fRows.Add($row)
    }

    $dbOpts = @($findings | ForEach-Object { [string]$_.Database } | Where-Object { $_ } | Sort-Object -Unique)
    [void]$H.Append('<section><h2>Findings <span class="muted">(' + $fRows.Count + ' of ' + [int]$S.TotalFindings +
        ' shown, sorted by risk)</span></h2>')
    if ($truncated) {
        [void]$H.Append('<div class="note">HTML preview is capped at ' + $MaxFindings +
            ' rows. The Excel and JSON exports always contain every finding.</div>')
    }
    [void]$H.Append('<div class="controls">' +
        '<input id="fSearch" type="search" placeholder="Search evidence, object, rule, recommendation..." oninput="filterFindings()">' +
        '<select id="fStatus" onchange="filterFindings()"><option value="">All statuses</option>')
    foreach ($stx in @('Will break', 'Needs adjustment', 'Security concern', 'Deprecated usage', 'Needs review', 'Modernization', 'Not assessable')) {
        [void]$H.Append('<option>' + $stx + '</option>')
    }
    [void]$H.Append('</select><select id="fSeverity" onchange="filterFindings()"><option value="">All severities</option>')
    foreach ($svx in @('Critical', 'High', 'Medium', 'Low', 'Info')) { [void]$H.Append('<option>' + $svx + '</option>') }
    [void]$H.Append('</select><select id="fDb" onchange="filterFindings()"><option value="">All databases</option>')
    foreach ($dx in $dbOpts) { [void]$H.Append('<option>' + (& $enc $dx) + '</option>') }
    [void]$H.Append('</select><span class="cnt" id="fCount">' + $fRows.Count + ' rows</span></div>')

    [void]$H.Append('<div class="scroll">')
    [void]$H.Append((New-AdvTable -Id 'findTable' -Headers @(
        'Risk', 'Status', 'Severity', 'Category', 'Database', 'Object', 'Location', 'Rule',
        'Evidence (line-level)', 'Recommendation', 'Matches', 'Fan-in', 'Executions', 'Docs') -Rows $fRows))
    [void]$H.Append('</div></section>' + "`n")

    # ---- backlog ----------------------------------------------------------------
    $bRows = @()
    $rank = 0
    foreach ($b in @($Engine.Backlog)) {
        $rank++
        $det = 'heuristic'
        if ($b.Deterministic) { $det = 'deterministic' }
        $doc = '-'
        if ($b.DocUrl) { $doc = '<a href="' + (& $enc $b.DocUrl) + '" target="_blank" rel="noopener">MS Learn</a>' }
        $bRows += ('<tr>' +
            (New-AdvCell -Text $rank -Cls 'num') +
            '<td><b>' + (& $enc $b.RuleId) + '</b><div class="muted">' + (& $enc $b.Title) + '</div></td>' +
            '<td><span class="badge ' + (Get-AdvStatusClass -Status $b.Status) + '">' + (& $enc $b.Status) + '</span></td>' +
            (New-AdvCell -Text $b.Severity) +
            (New-AdvCell -Text $b.Category) +
            (New-AdvCell -Text $b.Objects -Cls 'num') +
            (New-AdvCell -Text $b.TotalMatches -Cls 'num') +
            (New-AdvCell -Text $b.MaxRisk -Cls 'num') +
            (New-AdvCell -Text $b.AvgRisk -Cls 'num') +
            (New-AdvCell -Text $b.Databases -Cls 'num') +
            (New-AdvCell -Text $b.Effort) +
            (New-AdvCell -Text $det) +
            (New-AdvCell -Text $b.Recommendation) +
            (New-AdvCell -Text $b.SampleTargets) +
            '<td>' + $doc + '</td></tr>')
    }
    [void]$H.Append('<section><h2>Remediation backlog <span class="muted">(one work item per rule, worst risk first)</span></h2>')
    [void]$H.Append((New-AdvTable -Headers @(
        '#', 'Rule', 'Status', 'Severity', 'Category', 'Objects', 'Matches', 'Max risk', 'Avg risk',
        'Databases', 'Effort', 'Detection', 'Recommendation', 'Sample targets', 'Docs') -Rows $bRows))
    [void]$H.Append('</section>' + "`n")

    # ---- blind spots ------------------------------------------------------------
    $blind = @($Engine.Findings | Where-Object { $_.Status -eq 'Not assessable' })
    $blindRows = @()
    foreach ($f in $blind) {
        $p = [string]$f.Object
        if ($f.Schema) { $p = $f.Schema + '.' + $f.Object }
        $blindRows += ('<tr>' +
            (New-AdvCell -Text $(if ($f.Database) { $f.Database } else { '(instance/agent)' })) +
            (New-AdvCell -Text $p) +
            '<td><b>' + (& $enc $f.RuleId) + '</b><div class="muted">' + (& $enc $f.Title) + '</div></td>' +
            '<td><code>' + (& $enc $f.Evidence) + '</code></td>' +
            (New-AdvCell -Text $f.Recommendation) + '</tr>')
    }
    [void]$H.Append('<section><h2>Blind spots &amp; not assessable <span class="muted">(explicitly out of static scope)</span></h2>')
    if ($blind.Count -eq 0) {
        [void]$H.Append('<div class="muted">No blind spots recorded.</div>')
    } else {
        [void]$H.Append((New-AdvTable -Headers @('Database', 'Object', 'Rule', 'Why not assessable / next step', 'Recommendation') -Rows $blindRows))
    }
    $covFail = @($Coverage | Where-Object { $_.Status -ne 'Collected' })
    if ($covFail.Count -gt 0) {
        [void]$H.Append('<h3>Collection gaps (' + $covFail.Count + ')</h3>')
        $covFailRows = @()
        foreach ($cf in $covFail) {
            $covFailRows += ('<tr>' + (New-AdvCell -Text $cf.Step) + (New-AdvCell -Text $cf.Status) + (New-AdvCell -Text $cf.Detail) + '</tr>')
        }
        [void]$H.Append((New-AdvTable -Headers @('Collection step', 'Status', 'Detail') -Rows $covFailRows))
    }
    [void]$H.Append('</section>' + "`n")

    # ---- object inventory ---------------------------------------------------------
    $invAll = @($Engine.Inventory | Sort-Object -Property @{Expression = { [int]$_.MaxRisk }; Descending = $true})
    $invBad = @($invAll | Where-Object { $_.Status -ne 'No static findings' })
    $invRows = @()
    $invShown = $invBad
    if ($invShown.Count -gt 500) { $invShown = @($invShown | Select-Object -First 500) }
    foreach ($o in $invShown) {
        $p = [string]$o.Object
        if ($o.Schema) { $p = $o.Schema + '.' + $o.Object }
        $invRows += ('<tr>' +
            (New-AdvCell -Text $o.Database) +
            (New-AdvCell -Text $p) +
            (New-AdvCell -Text $o.ObjTypeDesc) +
            '<td><span class="badge ' + (Get-AdvStatusClass -Status $o.Status) + '">' + (& $enc $o.Status) + '</span></td>' +
            (New-AdvCell -Text $o.FindingCount -Cls 'num') +
            (New-AdvCell -Text $o.MaxRisk -Cls 'num') +
            (New-AdvCell -Text $o.RuleIds) + '</tr>')
    }
    [void]$H.Append('<section><h2>Object inventory <span class="muted">(' + [int]$S.ObjectsCompatible + ' of ' +
        [int]$S.ObjectsAssessed + ' objects have no static findings; showing ' + $invRows.Count + ' with findings)</span></h2>')
    [void]$H.Append((New-AdvTable -Headers @('Database', 'Object', 'Type', 'Status', 'Findings', 'Max risk', 'Rules fired') -Rows $invRows))
    [void]$H.Append('</section>' + "`n")

    # ---- rules catalog ------------------------------------------------------------
    $rRows = @()
    foreach ($r in @($Engine.ActiveRules)) {
        $det = 'no'
        if ($r.Deterministic) { $det = 'yes' }
        $doc = '-'
        if ($r.Doc) { $doc = '<a href="' + (& $enc $r.Doc) + '" target="_blank" rel="noopener">MS Learn</a>' }
        $rRows += ('<tr>' +
            '<td><b>' + (& $enc $r.Id) + '</b></td>' +
            (New-AdvCell -Text $r.Title) +
            (New-AdvCell -Text $r.Category) +
            (New-AdvCell -Text $r.Severity) +
            (New-AdvCell -Text $r.Scope) +
            (New-AdvCell -Text $r.TargetRange) +
            (New-AdvCell -Text $r.Confidence) +
            (New-AdvCell -Text $det) +
            (New-AdvCell -Text $r.Effort) +
            (New-AdvCell -Text $r.Recommendation) +
            '<td>' + $doc + '</td></tr>')
    }
    [void]$H.Append('<section><h2>Active rules catalog <span class="muted">(' + $rRows.Count +
        ' rules applicable to SQL Server ' + (& $enc $TargetVersion) + ' - data-driven, extensible via -RulesPath)</span></h2>')
    [void]$H.Append((New-AdvTable -Headers @(
        'Rule', 'Title', 'Category', 'Severity', 'Scope', 'Target range', 'Confidence', 'Deterministic',
        'Effort', 'Default recommendation', 'Docs') -Rows $rRows))
    [void]$H.Append('</section>' + "`n")

    # ---- coverage -----------------------------------------------------------------
    $covRows = @()
    foreach ($c in @($Coverage)) {
        $cls = 'st-ok'
        if ($c.Status -ne 'Collected') { $cls = 'st-break' }
        $covRows += ('<tr>' + (New-AdvCell -Text $c.Step) +
            '<td><span class="badge ' + $cls + '">' + (& $enc $c.Status) + '</span></td>' +
            (New-AdvCell -Text $c.Detail) + '</tr>')
    }
    $covOk = @($Coverage | Where-Object { $_.Status -eq 'Collected' }).Count
    $covFail = @($Coverage).Count - $covOk
    [void]$H.Append('<section><h2>Collection coverage <span class="muted">(' + $covOk + '/' +
        @($Coverage).Count + ' steps collected)</span></h2>')
    [void]$H.Append((New-AdvTable -Headers @('Step', 'Status', 'Detail') -Rows $covRows))
    [void]$H.Append('</section></main>' + "`n")

    # ---- footer + script -----------------------------------------------------------
    [void]$H.Append('<footer>Static analysis only &mdash; rules derived from Microsoft Learn documentation (deprecated / discontinued / breaking changes). ' +
        'Always validate in a test environment and compare Query Store baselines before and after the compatibility-level change. ' +
        'Generated by SQL Upgrade Advisor v' + (& $enc $S.ToolVersion) + ' on ' + (& $enc $S.GeneratedAt) + '.</footer>' + "`n")
    [void]$H.Append(@'
<script>
function filterFindings(){
  var q=(document.getElementById("fSearch").value||"").toLowerCase();
  var st=document.getElementById("fStatus").value;
  var sv=document.getElementById("fSeverity").value;
  var db=document.getElementById("fDb").value;
  var rows=document.querySelectorAll("#findTable tbody tr");
  var shown=0;
  for(var i=0;i<rows.length;i++){
    var r=rows[i];
    var ok=(!q||r.innerText.toLowerCase().indexOf(q)>=0)
      &&(!st||r.getAttribute("data-status")===st)
      &&(!sv||r.getAttribute("data-severity")===sv)
      &&(!db||r.getAttribute("data-db")===db);
    r.style.display=ok?"":"none";
    if(ok)shown++;
  }
  document.getElementById("fCount").textContent=shown+" rows";
}
</script>
</body></html>
'@)

    $html = $H.ToString()
    [System.IO.File]::WriteAllText($Path, $html, [System.Text.UTF8Encoding]::new($false))
    Write-AdvLog "HTML report: $Path" 'OK'
}

function Get-AdvStatusColor {
    param([string]$Status)    switch ($Status) {
        'Will break'       { return '#c62828' }
        'Needs adjustment' { return '#ef6c00' }
        'Security concern' { return '#6a1b9a' }
        'Deprecated usage' { return '#b58900' }
        'Needs review'     { return '#1565c0' }
        'Modernization'    { return '#2e7d32' }
        'Not assessable'   { return '#78909c' }
        'No static findings' { return '#43a047' }
        default            { return '#1565c0' }
    }
}

# --------------------------------------------------------------------------------
# REPORT - XLSX (native SpreadsheetML in a zip, no Excel COM / no modules)
# --------------------------------------------------------------------------------
function ConvertTo-XlsxText {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd HH:mm') }
    if ($Value -is [bool]) { if ($Value) { return 'TRUE' } else { return 'FALSE' } }
    $t = [string]$Value
    if ($t.Length -gt 32000) { $t = $t.Substring(0, 32000) + '...' }
    $t = $t -replace '[\x00-\x08\x0B\x0C\x0E-\x1F]', ''
    $t = $t.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;').Replace("'", '&apos;')
    return $t
}

function Get-XlsxColName {
    param([int]$Index)
    $n = $Index
    $name = ''
    while ($n -ge 0) {
        $name = [char](65 + ($n % 26)) + $name
        $n = [Math]::Floor($n / 26) - 1
    }
    return $name
}

function New-XlsxSheetXml {
    param(
        [System.Collections.Generic.List[object[]]]$Rows,
        [int]$StatusCol = -1,
        [int]$SeverityCol = -1,
        [hashtable]$StatusStyles,
        [hashtable]$SeverityStyles,
        [array]$Widths
    )
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')
    if ($Widths -and $Widths.Count -gt 0) {
        [void]$sb.Append('<cols>')
        for ($i = 0; $i -lt $Widths.Count; $i++) {
            [void]$sb.Append(('<col min="{0}" max="{0}" width="{1}" customWidth="1"/>' -f ($i + 1), $Widths[$i]))
        }
        [void]$sb.Append('</cols>')
    }
    [void]$sb.Append('<sheetData>')
    $ri = 0
    foreach ($row in $Rows) {
        $ri++
        [void]$sb.Append(('<row r="{0}">' -f $ri))
        $ci = -1
        foreach ($cell in $row) {
            $ci++
            if ($null -eq $cell) { continue }
            $style = 0
            if ($ri -eq 1) {
                $style = 1
            } elseif ($cell -is [string]) {
                if ($StatusCol -ge 0 -and $ci -eq $StatusCol -and $StatusStyles -and $StatusStyles.ContainsKey($cell)) {
                    $style = $StatusStyles[$cell]
                } elseif ($SeverityCol -ge 0 -and $ci -eq $SeverityCol -and $SeverityStyles -and $SeverityStyles.ContainsKey($cell)) {
                    $style = $SeverityStyles[$cell]
                }
            }
            $attr = ''
            if ($style -gt 0) { $attr = ' s="{0}"' -f $style }
            $ref = (Get-XlsxColName -Index $ci) + $ri

            if ($cell -is [string] -or $cell -is [bool] -or $cell -is [datetime]) {
                if ($cell -is [string] -and $cell.Length -eq 0) { continue }
                [void]$sb.Append(('<c r="{0}"{1} t="inlineStr"><is><t xml:space="preserve">{2}</t></is></c>' -f $ref, $attr, (ConvertTo-XlsxText -Value $cell)))
            } else {
                $num = ''
                if ($cell -is [ValueType]) {
                    $num = [Convert]::ToString($cell, [System.Globalization.CultureInfo]::InvariantCulture)
                } else {
                    $num = ConvertTo-XlsxText -Value $cell
                }
                [void]$sb.Append(('<c r="{0}"{1} t="inlineStr"><is><t xml:space="preserve">{2}</t></is></c>' -f $ref, $attr, (ConvertTo-XlsxText -Value $num)))
            }
        }
        [void]$sb.Append('</row>')
    }
    [void]$sb.Append('</sheetData></worksheet>')
    return $sb.ToString()
}

function Export-AdvXlsx {
    param(
        $Engine,
        $InstanceData,
        [array]$DatabaseData,
        [array]$Coverage,
        [string]$Path,
        [string]$TargetVersion,
        [int]$TargetCompat,
        [int]$MaxFindings = 0,
        [switch]$ExportAllFindings
    )
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }

    $S = $Engine.Summary
    # refresh the coverage snapshot from the live list (the engine's copy predates the export steps)
    $S.Coverage = [pscustomobject]@{
        Steps    = @($Coverage).Count
        Collected = @($Coverage | Where-Object { $_.Status -eq 'Collected' }).Count
        Failed   = @($Coverage | Where-Object { $_.Status -ne 'Collected' }).Count
    }
    $covOkLive = [int]$S.Coverage.Collected
    $covFailLive = [int]$S.Coverage.Failed
    $statusStyles = @{
        'Will break' = 3; 'Needs adjustment' = 4; 'Security concern' = 5; 'Deprecated usage' = 6
        'Needs review' = 7; 'Modernization' = 8; 'Not assessable' = 9; 'No static findings' = 10
    }
    $severityStyles = @{ 'Critical' = 11; 'High' = 11 }

    $server = ''; $srcVer = ''
    if ($InstanceData -and $InstanceData.Instance) {
        $server = [string]$InstanceData.Instance.ServerName
        $srcVer = [string]$InstanceData.Instance.ProductVersion
    }

    # ---- sheet 1: summary ------------------------------------------------------
    $s1 = New-Object 'System.Collections.Generic.List[object[]]'
    $s1.Add(@('Property', 'Value'))
    $s1.Add(@('Server', $server))
    $s1.Add(@('Source version', $srcVer))
    $s1.Add(@('Target version', 'SQL Server ' + $TargetVersion))
    $s1.Add(@('Target compatibility level', $TargetCompat))
    $s1.Add(@('Generated at', [string]$S.GeneratedAt))
    $s1.Add(@('Elapsed seconds', [int]$S.ElapsedSec))
    $s1.Add(@('Databases assessed', [int]$S.DatabasesAssessed))
    $s1.Add(@('Objects assessed', [int]$S.ObjectsAssessed))
    $s1.Add(@('Objects with findings', [int]$S.ObjectsWithFindings))
    $s1.Add(@('No static findings', [int]$S.ObjectsCompatible))
    $s1.Add(@('Total findings', [int]$S.TotalFindings))
    $s1.Add(@('High risk (score >= 50)', [int]$S.HighRisk))
    $s1.Add(@('Rules active', [int]$S.RulesActive))
    $s1.Add(@('Rules fired', [int]$S.RulesFired))
    $s1.Add(@('Coverage collected', $covOkLive))
    $s1.Add(@('Coverage failed / skipped', $covFailLive))
    $s1.Add(@('', ''))
    $s1.Add(@('Status', 'Count'))
    foreach ($kv in $S.ByStatus.GetEnumerator()) { $s1.Add(@([string]$kv.Key, [int]$kv.Value)) }
    $s1.Add(@('', ''))
    $s1.Add(@('Severity', 'Count'))
    foreach ($kv in $S.BySeverity.GetEnumerator()) { $s1.Add(@([string]$kv.Key, [int]$kv.Value)) }
    $s1.Add(@('', ''))
    $s1.Add(@('Risk band', 'Count'))
    foreach ($kv in $S.RiskBands.GetEnumerator()) { $s1.Add(@([string]$kv.Key, [int]$kv.Value)) }

    # ---- sheet 2: findings -----------------------------------------------------
    $s2 = New-Object 'System.Collections.Generic.List[object[]]'
    $s2.Add(@('Risk', 'Status', 'Severity', 'Category', 'Rule', 'Title', 'Database', 'Schema', 'Object',
        'Object type', 'Line', 'Matches', 'Fan-in', 'Hotness (executions)', 'Confidence', 'Deterministic',
        'Evidence', 'Recommendation', 'Effort', 'Doc URL'))
    foreach ($f in @(Select-AdvReportedFindings -Findings $Engine.Findings -Max $MaxFindings -ExportAll ([bool]$ExportAllFindings))) {
        $s2.Add(@(
            [int]$f.Risk, [string]$f.Status, [string]$f.Severity, [string]$f.Category,
            [string]$f.RuleId, [string]$f.Title, [string]$f.Database, [string]$f.Schema, [string]$f.Object,
            [string]$f.ObjTypeDesc, [int]$f.Line, [int]$f.TotalMatches, [int]$f.BlastRadius, [long]$f.Hotness,
            [string]$f.Confidence, [bool]$f.Deterministic, [string]$f.Evidence, [string]$f.Recommendation,
            [string]$f.Effort, [string]$f.DocUrl
        ))
    }

    # ---- sheet 3: backlog ------------------------------------------------------
    $s3 = New-Object 'System.Collections.Generic.List[object[]]'
    $s3.Add(@('Rule', 'Title', 'Status', 'Severity', 'Category', 'Objects', 'Matches', 'Max risk', 'Avg risk',
        'Databases', 'Effort', 'Detection', 'Sample targets', 'Recommendation', 'Doc URL'))
    foreach ($b in @($Engine.Backlog)) {
        $det = 'heuristic'
        if ($b.Deterministic) { $det = 'deterministic' }
        $s3.Add(@(
            [string]$b.RuleId, [string]$b.Title, [string]$b.Status, [string]$b.Severity, [string]$b.Category,
            [int]$b.Objects, [int]$b.TotalMatches, [int]$b.MaxRisk, [int]$b.AvgRisk, [int]$b.Databases,
            [string]$b.Effort, $det, [string]$b.SampleTargets, [string]$b.Recommendation, [string]$b.DocUrl
        ))
    }

    # ---- sheet 4: objects ------------------------------------------------------
    $s4 = New-Object 'System.Collections.Generic.List[object[]]'
    $s4.Add(@('Database', 'Schema', 'Object', 'Object code', 'Type', 'Status', 'Findings', 'Max risk', 'Rules fired'))
    foreach ($o in @($Engine.Inventory | Sort-Object -Property @{Expression = { [int]$_.MaxRisk }; Descending = $true})) {
        $s4.Add(@(
            [string]$o.Database, [string]$o.Schema, [string]$o.Object, [string]$o.ObjType, [string]$o.ObjTypeDesc,
            [string]$o.Status, [int]$o.FindingCount, [int]$o.MaxRisk, [string]$o.RuleIds
        ))
    }

    # ---- sheet 5: databases ----------------------------------------------------
    $s5 = New-Object 'System.Collections.Generic.List[object[]]'
    $s5.Add(@('Database', 'Objects', 'No static findings', 'Findings', 'Will break', 'Deprecated usage', 'Max risk'))
    foreach ($d in @($S.PerDatabase)) {
        $s5.Add(@([string]$d.Name, [int]$d.Objects, [int]$d.CompatibleObjects, [int]$d.Findings,
            [int]$d.WillBreak, [int]$d.Deprecated, [int]$d.MaxRisk))
    }

    # ---- sheet 6: coverage -----------------------------------------------------
    $s6 = New-Object 'System.Collections.Generic.List[object[]]'
    $s6.Add(@('Collection step', 'Status', 'Detail'))
    foreach ($c in @($Coverage)) { $s6.Add(@([string]$c.Step, [string]$c.Status, [string]$c.Detail)) }

    # ---- sheet 7: rules --------------------------------------------------------
    $s7 = New-Object 'System.Collections.Generic.List[object[]]'
    $s7.Add(@('Rule', 'Title', 'Category', 'Severity', 'Scope', 'Target range', 'Confidence', 'Deterministic',
        'Effort', 'Description', 'Default recommendation', 'Doc URL'))
    foreach ($r in @($Engine.ActiveRules)) {
        $s7.Add(@(
            [string]$r.Id, [string]$r.Title, [string]$r.Category, [string]$r.Severity, [string]$r.Scope,
            [string]$r.TargetRange, [string]$r.Confidence, [bool]$r.Deterministic, [string]$r.Effort,
            [string]$r.Description, [string]$r.Recommendation, [string]$r.Doc
        ))
    }

    $sheetDefs = @(
        @{ Name = 'Summary';  Rows = $s1; StatusCol = 0;  SeverityCol = -1; Widths = @(34, 92) }
        @{ Name = 'Findings'; Rows = $s2; StatusCol = 1;  SeverityCol = 2;  Widths = @(7, 18, 10, 15, 18, 40, 14, 12, 26, 20, 7, 9, 8, 14, 11, 12, 70, 70, 8, 34) }
        @{ Name = 'Backlog';  Rows = $s3; StatusCol = 2;  SeverityCol = 3;  Widths = @(18, 44, 18, 10, 15, 9, 9, 9, 9, 10, 8, 13, 50, 70, 34) }
        @{ Name = 'Objects';  Rows = $s4; StatusCol = 5;  SeverityCol = -1; Widths = @(14, 12, 34, 10, 22, 18, 9, 9, 40) }
        @{ Name = 'Databases';Rows = $s5; StatusCol = -1; SeverityCol = -1; Widths = @(16, 9, 11, 9, 11, 17, 9) }
        @{ Name = 'Coverage'; Rows = $s6; StatusCol = 1;  SeverityCol = -1; Widths = @(58, 18, 70) }
        @{ Name = 'Rules';    Rows = $s7; StatusCol = -1; SeverityCol = 3;  Widths = @(18, 46, 15, 10, 14, 14, 11, 13, 8, 60, 70, 34) }
    )

    $sheetXmls = @()
    foreach ($sd in $sheetDefs) {
        $sheetXmls += , (New-XlsxSheetXml -Rows $sd.Rows -StatusCol $sd.StatusCol -SeverityCol $sd.SeverityCol `
            -StatusStyles $statusStyles -SeverityStyles $severityStyles -Widths $sd.Widths)
    }

    # ---- package XML -------------------------------------------------------------
    $ct = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">' +
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>' +
        '<Default Extension="xml" ContentType="application/xml"/>' +
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>' +
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>'
    for ($i = 1; $i -le $sheetXmls.Count; $i++) {
        $ct += ('<Override PartName="/xl/worksheets/sheet{0}.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>' -f $i)
    }
    $ct += '</Types>'

    $rels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
        '</Relationships>'

    $wb = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' +
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>'
    for ($i = 0; $i -lt $sheetDefs.Count; $i++) {
        $wb += ('<sheet name="{0}" sheetId="{1}" r:id="rId{1}"/>' -f (ConvertTo-XlsxText -Value $sheetDefs[$i].Name), ($i + 1))
    }
    $wb += '</sheets></workbook>'

    $wrels = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    for ($i = 1; $i -le $sheetDefs.Count; $i++) {
        $wrels += ('<Relationship Id="rId{0}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet{0}.xml"/>' -f $i)
    }
    $wrels += ('<Relationship Id="rId{0}" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>' -f ($sheetDefs.Count + 1))
    $wrels += '</Relationships>'

    $styles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
        '<fonts count="4">' +
        '<font><sz val="11"/><name val="Calibri"/><family val="2"/></font>' +
        '<font><b/><sz val="11"/><color rgb="FFFFFFFF"/><name val="Calibri"/><family val="2"/></font>' +
        '<font><b/><sz val="11"/><name val="Calibri"/><family val="2"/></font>' +
        '<font><b/><sz val="11"/><color rgb="FFCC0000"/><name val="Calibri"/><family val="2"/></font>' +
        '</fonts>' +
        '<fills count="11">' +
        '<fill><patternFill patternType="none"/></fill>' +
        '<fill><patternFill patternType="gray125"/></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FF305496"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFF4CCCC"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFFCE4D6"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFE4DFEC"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFFFF2CC"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFDDEBF7"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFE2EFDA"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFEFEFEF"/></patternFill></fill>' +
        '<fill><patternFill patternType="solid"><fgColor rgb="FFDFF0D8"/></patternFill></fill>' +
        '</fills>' +
        '<borders count="2">' +
        '<border><left/><right/><top/><bottom/><diagonal/></border>' +
        '<border><left style="thin"><color rgb="FFD0D0D0"/></left><right style="thin"><color rgb="FFD0D0D0"/></right>' +
        '<top style="thin"><color rgb="FFD0D0D0"/></top><bottom style="thin"><color rgb="FFD0D0D0"/></bottom><diagonal/></border>' +
        '</borders>' +
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
        '<cellXfs count="12">' +
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' +
        '<xf numFmtId="0" fontId="1" fillId="2" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment horizontal="center" vertical="center" wrapText="1"/></xf>' +
        '<xf numFmtId="0" fontId="2" fillId="0" borderId="0" xfId="0" applyFont="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="3" borderId="1" xfId="0" applyFill="1" applyBorder="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="4" borderId="1" xfId="0" applyFill="1" applyBorder="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="5" borderId="1" xfId="0" applyFill="1" applyBorder="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="6" borderId="1" xfId="0" applyFill="1" applyBorder="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="7" borderId="1" xfId="0" applyFill="1" applyBorder="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="8" borderId="1" xfId="0" applyFill="1" applyBorder="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="9" borderId="1" xfId="0" applyFill="1" applyBorder="1"/>' +
        '<xf numFmtId="0" fontId="0" fillId="10" borderId="1" xfId="0" applyFill="1" applyBorder="1"/>' +
        '<xf numFmtId="0" fontId="3" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1"/>' +
        '</cellXfs>' +
        '</styleSheet>'

    # ---- write the zip ------------------------------------------------------------
    $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        function Write-ZipEntry {
            param([string]$Name, [string]$Content)
            $entry = $zip.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Optimal)
            $stream = $entry.Open()
            $sw = New-Object System.IO.StreamWriter($stream, [System.Text.UTF8Encoding]::new($false))
            $sw.Write($Content)
            $sw.Dispose()
            $stream.Dispose()
        }
        Write-ZipEntry '[Content_Types].xml' $ct
        Write-ZipEntry '_rels/.rels' $rels
        Write-ZipEntry 'xl/workbook.xml' $wb
        Write-ZipEntry 'xl/_rels/workbook.xml.rels' $wrels
        Write-ZipEntry 'xl/styles.xml' $styles
        for ($i = 0; $i -lt $sheetXmls.Count; $i++) {
            Write-ZipEntry ('xl/worksheets/sheet{0}.xml' -f ($i + 1)) $sheetXmls[$i]
        }
    } finally {
        $zip.Dispose()
    }
    Write-AdvLog "Excel report: $Path" 'OK'
}

function Select-AdvReportedFindings {
    param($Findings, [int]$Max = 0, [bool]$ExportAll = $false)
    $sorted = @($Findings | Sort-Object -Property @{Expression = { [int]$_.Risk }; Descending = $true}, @{Expression = { [int]$_.TotalMatches }; Descending = $true})
    if ($ExportAll -or $Max -le 0 -or $sorted.Count -le $Max) { return @($sorted) }
    return @($sorted | Select-Object -First $Max)
}

function Import-AdvRuleFile {
    param([string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($c in @($raw)) {
        if (-not $c.Id) { continue }
        if ($c.AppliesTo -is [string]) {
            $c | Add-Member -NotePropertyName AppliesTo -NotePropertyValue (,([string]$c.AppliesTo)) -Force
        }
        $list.Add($c)
    }
    return ,$list
}

function Export-AdvDefaultRules {
    param([string]$Path)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $json = Get-DefaultRules | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
}

function Export-AdvSarif {
    param([array]$Findings, [string]$Path)
    $byRule = @{}
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($f in @($Findings)) {
        $level = 'note'
        if ($f.Severity -eq 'Critical' -or $f.Severity -eq 'High') { $level = 'error' }
        elseif ($f.Severity -eq 'Medium') { $level = 'warning' }
        $byRule[[string]$f.RuleId] = $f
        $obj = if ($f.Schema) { '{0}.{1}' -f $f.Schema, $f.Object } else { [string]$f.Object }
        if ($f.Database) { $obj = '{0}.{1}' -f $f.Database, $obj }
        $line = [int]$f.Line
        if ($line -lt 1) { $line = 1 }
        $results.Add([ordered]@{
            ruleId  = [string]$f.RuleId
            level   = $level
            message = [ordered]@{ text = ('{0}: {1}' -f $f.Title, $f.Evidence) }
            locations = @([ordered]@{
                physicalLocation = [ordered]@{
                    artifactLocation = [ordered]@{ uri = $obj }
                    region = [ordered]@{ startLine = $line }
                }
            })
        })
    }
    $driverRules = New-Object System.Collections.Generic.List[object]
    foreach ($id in @($byRule.Keys | Sort-Object)) {
        $f = $byRule[$id]
        $driverRules.Add([ordered]@{
            id = [string]$id
            shortDescription = [ordered]@{ text = [string]$f.Title }
            helpUri = [string]$f.DocUrl
            properties = [ordered]@{ category = [string]$f.Category; severity = [string]$f.Severity }
        })
    }
    $doc = New-Object System.Collections.Specialized.OrderedDictionary
    $doc['$schema'] = 'https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json'
    $doc['version'] = '2.1.0'
    $doc['runs'] = @(
        [pscustomobject]@{
            tool = [pscustomobject]@{
                driver = [pscustomobject]@{
                    name = 'SQL Upgrade Advisor'
                    version = [string]$script:AdvToolVersion
                    rules = @($driverRules.ToArray())
                }
            }
            results = @($results.ToArray())
        }
    )
    [System.IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    Write-AdvLog "SARIF report: $Path" 'OK'
}

# --------------------------------------------------------------------------------
# REPORT - JSON (CI friendly)
# --------------------------------------------------------------------------------
function Export-AdvJson {
    param(
        $Engine,
        $InstanceData,
        [array]$DatabaseData,
        [array]$Coverage,
        [string]$Path,
        [string]$TargetVersion,
        [int]$TargetCompat,
        [switch]$IncludeDefinitions,
        [int]$MaxFindings = 0,
        [switch]$ExportAllFindings
    )
    $S = $Engine.Summary
    # refresh coverage snapshot so Summary matches the exported Coverage array
    $S.Coverage = [pscustomobject]@{
        Steps     = @($Coverage).Count
        Collected = @($Coverage | Where-Object { $_.Status -eq 'Collected' }).Count
        Failed    = @($Coverage | Where-Object { $_.Status -ne 'Collected' }).Count
    }
    $server = ''; $srcVer = ''
    if ($InstanceData -and $InstanceData.Instance) {
        $server = [string]$InstanceData.Instance.ServerName
        $srcVer = [string]$InstanceData.Instance.ProductVersion
    }

    $payload = [ordered]@{
        Tool         = 'SQL Upgrade Advisor'
        ToolVersion  = [string]$script:AdvToolVersion
        RunInfo      = [ordered]@{
            Server                   = $server
            SourceVersion            = $srcVer
            TargetVersion            = $TargetVersion
            TargetCompatibilityLevel = $TargetCompat
            GeneratedAt              = [string]$S.GeneratedAt
            ElapsedSec               = [int]$S.ElapsedSec
            DemoMode                 = [bool]$DemoMode
        }
        Summary      = $S
        Backlog      = @($Engine.Backlog)
        Findings     = @(Select-AdvReportedFindings -Findings $Engine.Findings -Max $MaxFindings -ExportAll ([bool]$ExportAllFindings))
        ObjectInventory = @($Engine.Inventory)
        Coverage     = @($Coverage)
        ActiveRules  = @($Engine.ActiveRules)
    }

    if ($IncludeDefinitions) {
        $mods = @()
        foreach ($dbd in $DatabaseData) {
            foreach ($o in @($dbd.Objects | Where-Object { $_ })) {
                if ([string]::IsNullOrWhiteSpace([string]$o.definition)) { continue }
                $mods += [ordered]@{
                    Database   = [string]$dbd.Database
                    Schema     = [string]$o.schema_name
                    Object     = [string]$o.name
                    ObjectType = [string]$o.type_desc
                    Definition = [string]$o.definition
                }
            }
        }
        $payload['ModuleDefinitions'] = $mods
    }

    $json = $payload | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json, [System.Text.UTF8Encoding]::new($false))
    Write-AdvLog "JSON report: $Path" 'OK'
}

# =================================================================================
# MAIN
# =================================================================================
try {
    $rulesRoot = Split-Path -Parent $script:AdvSqlPath
    $defaultRulesFile = Join-Path $rulesRoot 'rules\default-rules.json'
    if ($WriteDefaultRules) {
        Export-AdvDefaultRules -Path $defaultRulesFile
        Write-AdvLog "Wrote default rules to $defaultRulesFile" 'OK'
        return
    }

    if (-not $DemoMode -and [string]::IsNullOrWhiteSpace($ServerInstance)) {
        throw 'ServerInstance is required (or run with -DemoMode to preview the report using the built-in synthetic inventory).'
    }

    $TargetCompat = $TargetCompatibilityLevel
    if ($TargetCompat -le 0) { $TargetCompat = Get-AdvDefaultCompat -TargetVersion $TargetVersion }

    Write-AdvLog ("SQL Upgrade Advisor v{0} - target SQL Server {1} (compatibility level {2})" -f $script:AdvToolVersion, $TargetVersion, $TargetCompat) 'OK'

    # ---- knowledge base ----------------------------------------------------------
    if (Test-Path -LiteralPath $defaultRulesFile) {
        $rules = Import-AdvRuleFile -Path $defaultRulesFile
        Write-AdvLog "Loaded default rules from $defaultRulesFile" 'OK'
    } else {
        $rules = Get-DefaultRules
    }
    if ($RulesPath) { $rules = Import-CustomRules -BaseRules $rules -Path $RulesPath }
    Add-AdvCoverage -Name 'Rules knowledge base' -Ok $true -Detail ("{0} rule(s) loaded{1}" -f @($rules).Count, $(if ($RulesPath) { " (overrides from $RulesPath)" } else { '' }))

    # ---- reviewable T-SQL collection scripts ---------------------------------------
    $sqlCheck = Test-AdvSqlScripts -Names $script:AdvSqlScripts
    if ($sqlCheck.Ok) {
        Add-AdvCoverage -Name 'T-SQL collection scripts' -Ok $true `
            -Detail ("{0} script(s) in {1} (read-only, review before running)" -f @($script:AdvSqlScripts).Count, $sqlCheck.Folder)
        Write-AdvLog ("T-SQL collection sections: {0} validated in {1}" -f @($script:AdvSqlScripts).Count, $sqlCheck.Folder) 'INFO'
    } elseif ($DemoMode) {
        Add-AdvCoverage -Name 'T-SQL collection scripts' -Ok $false `
            -Detail ("not usable ({0}): {1}" -f $sqlCheck.Folder, ((@($sqlCheck.Missing) + @($sqlCheck.ReadOnly)) -join '; '))
        Write-AdvLog ("DemoMode: T-SQL script folder is not usable ({0}) - live runs will fail: {1}" -f `
            $sqlCheck.Folder, ((@($sqlCheck.Missing) + @($sqlCheck.ReadOnly)) -join '; ')) 'WARN'
    } else {
        throw ("T-SQL collection scripts are missing or are not read-only in '{0}'.`r`n" +
               "Missing: {1}`r`nNot SELECT-only: {2}`r`n" +
               "Restore the 'sql' folder next to Invoke-SqlUpgradeAdvisor.ps1, or point -SqlPath at it.") -f `
            $sqlCheck.Folder,
            $(if (@($sqlCheck.Missing).Count) { (@($sqlCheck.Missing) -join ', ') } else { '(none)' }),
            $(if (@($sqlCheck.ReadOnly).Count) { (@($sqlCheck.ReadOnly) -join ' | ') } else { '(none)' })
    }

    # ---- collection ---------------------------------------------------------------
    if ($DemoMode) {
        Write-AdvLog 'DemoMode: skipping live collection, using synthetic SQL Server 2016 inventory' 'WARN'
        $inv = New-AdvDemoInventory
        if ($Databases -and $Databases.Count -gt 0) {
            $dbPatterns = @()
            foreach ($f in @($Databases)) { foreach ($p in ([string]$f).Split(',')) { if (-not [string]::IsNullOrWhiteSpace($p)) { $dbPatterns += $p.Trim() } } }
            $keptAll = [System.Collections.Generic.List[object]]::new()
            foreach ($d in @($inv.DatabaseData)) {
                foreach ($f in $dbPatterns) { if ([string]$d.Database -like $f) { $keptAll.Add($d); break } }
            }
            $total = @($inv.DatabaseData).Count
            $inv.DatabaseData = @($keptAll)
            Write-AdvLog ("DemoMode: -Databases filter applied, kept {0} of {1} database(s)" -f @($keptAll).Count, $total) $(if (@($keptAll).Count -eq 0) { 'WARN' } else { 'INFO' })
        }
    } else {
        Write-AdvLog "Connecting to $ServerInstance ..." 'INFO'
        $conn = $null
        $instanceData = $null
        try {
            $conn = New-AdvConnection -Instance $ServerInstance -Cred $Credential -UseEncrypt ([bool]$Encrypt) -TrustCert ([bool]$TrustServerCertificate) -Database 'master'
            $instanceData = Get-AdvInstanceData -Conn $conn -Timeout $QueryTimeoutSec
        } finally {
            if ($conn) { $conn.Close(); $conn.Dispose() }
        }
        if (-not $instanceData -or -not $instanceData.Instance) {
            throw "Connected to $ServerInstance but instance properties could not be read (insufficient permissions?)."
        }
        $srcMajor = 0
        if ($null -ne $instanceData.Instance.ProductMajorVersion) { $srcMajor = Get-AdvInt $instanceData.Instance.ProductMajorVersion }
        if ($srcMajor -le 0 -and $instanceData.Instance.ProductVersion) {
            $head = ([string]$instanceData.Instance.ProductVersion).Split('.')[0]
            $parsed = 0
            if ([int]::TryParse($head, [ref]$parsed)) { $srcMajor = $parsed }
        }
        $tgtMajor = Get-AdvTargetMajor -TargetVersion $TargetVersion
        if ($srcMajor -gt 0 -and $srcMajor -ge $tgtMajor) {
            Write-AdvLog ("Source engine major {0} is already at or above target SQL Server {1}. Findings describe leftover debt on the current instance, not an upgrade that has not happened." -f $srcMajor, $TargetVersion) 'WARN'
        }

        $selected = Select-AdvDatabases -AllDatabases $instanceData.Databases -Filter $Databases -IncludeMaster ([bool]$IncludeSystemDatabases)
        $selNames = @($selected | ForEach-Object { $_.name })
        Write-AdvLog ("Assessing {0} database(s): {1}" -f $selNames.Count, ($selNames -join ', ')) 'OK'
        if ($selNames.Count -eq 0) { Write-AdvLog 'No user databases matched the -Databases filter.' 'WARN' }

        $dbData = [System.Collections.Generic.List[object]]::new()
        foreach ($d in $selected) {
            Write-AdvLog "Collecting metadata: $($d.name) ..." 'INFO'
            $dbData.Add((Get-AdvDatabaseData -Instance $ServerInstance -Cred $Credential -UseEncrypt ([bool]$Encrypt) -TrustCert ([bool]$TrustServerCertificate) -DbRow $d -Timeout $QueryTimeoutSec -DefinitionsMode $DefinitionsMode))
        }
        $inv = @{ InstanceData = $instanceData; DatabaseData = @($dbData) }
    }

    # ---- rule engine ---------------------------------------------------------------
    $targetMajor = Get-AdvTargetMajor -TargetVersion $TargetVersion
    $engine = Invoke-AdvRuleEngine -InstanceData $inv.InstanceData -DatabaseData $inv.DatabaseData `
        -Rules $rules -TargetMajor $targetMajor -TargetVersion $TargetVersion -TargetCompat $TargetCompat

    # ---- output paths ---------------------------------------------------------------
    $serverLabel = 'Demo'
    if (-not $DemoMode) {
        $serverLabel = [string]$ServerInstance
        if ($inv.InstanceData -and $inv.InstanceData.Instance -and $inv.InstanceData.Instance.ServerName) {
            $serverLabel = [string]$inv.InstanceData.Instance.ServerName
        }
    }
    $safeServer = Get-SafeFileName -Name $serverLabel
    if (-not $OutputPath) {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $OutputPath = Join-Path -Path (Get-Location).Path -ChildPath ("Assessment_{0}_{1}" -f $safeServer, $stamp)
    }
    if (-not (Test-Path -LiteralPath $OutputPath)) {
        New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
    }
    $baseName = 'SqlUpgradeAdvisor_{0}_to_{1}' -f $safeServer, $TargetVersion
    $htmlPath = Join-Path -Path $OutputPath -ChildPath ($baseName + '.html')
    $xlsxPath = Join-Path -Path $OutputPath -ChildPath ($baseName + '.xlsx')
    $jsonPath = Join-Path -Path $OutputPath -ChildPath ($baseName + '.json')
    $sarifPath = Join-Path -Path $OutputPath -ChildPath ($baseName + '.sarif')

    $made = @()
    $also = @($AlsoExport)
    $wantHtml = $Format -in @('HTML', 'All', 'Both')
    $wantExcel = $Format -in @('Excel', 'All', 'Both')
    $wantJson = ($Format -in @('JSON', 'All')) -or ($also -contains 'JSON')
    $wantSarif = ($Format -in @('SARIF', 'All')) -or ($also -contains 'SARIF')
    if ($wantHtml) {
        Export-AdvHtml -Engine $engine -InstanceData $inv.InstanceData -DatabaseData $inv.DatabaseData `
            -Coverage $script:AdvCoverage -Path $htmlPath -TargetVersion $TargetVersion -TargetCompat $TargetCompat `
            -MaxFindings $MaxFindingsInReport
        $made += $htmlPath
        Add-AdvCoverage -Name 'HTML report export' -Ok $true -Detail $htmlPath
    }
    if ($wantExcel) {
        Export-AdvXlsx -Engine $engine -InstanceData $inv.InstanceData -DatabaseData $inv.DatabaseData `
            -Coverage $script:AdvCoverage -Path $xlsxPath -TargetVersion $TargetVersion -TargetCompat $TargetCompat `
            -MaxFindings $MaxFindingsInReport -ExportAllFindings:$ExportAllFindings
        $made += $xlsxPath
        Add-AdvCoverage -Name 'Excel report export' -Ok $true -Detail $xlsxPath
    }
    if ($IncludeDefinitions) {
        Write-AdvLog 'IncludeDefinitions is on: module source text will be written into the JSON export. Review that file before sharing it.' 'WARN'
    }
    if ($wantJson) {
        Export-AdvJson -Engine $engine -InstanceData $inv.InstanceData -DatabaseData $inv.DatabaseData `
            -Coverage $script:AdvCoverage -Path $jsonPath -TargetVersion $TargetVersion -TargetCompat $TargetCompat `
            -IncludeDefinitions:$IncludeDefinitions -MaxFindings $MaxFindingsInReport -ExportAllFindings:$ExportAllFindings
        $made += $jsonPath
        Add-AdvCoverage -Name 'JSON report export' -Ok $true -Detail $jsonPath
    }
    if ($wantSarif) {
        $sarifFindings = Select-AdvReportedFindings -Findings $engine.Findings -Max $MaxFindingsInReport -ExportAll ([bool]$ExportAllFindings)
        Export-AdvSarif -Findings $sarifFindings -Path $sarifPath
        $made += $sarifPath
        Add-AdvCoverage -Name 'SARIF report export' -Ok $true -Detail $sarifPath
    }

    # ---- wrap up --------------------------------------------------------------------
    $S = $engine.Summary
    $elapsed = [int]((Get-Date) - $script:AdvStartTime).TotalSeconds
    Write-AdvLog ('Assessment complete in {0}s: {1} findings | {2} will break | {3} deprecated usage | {4} blind spots | {5}/{6} objects with no static findings' -f `
        $elapsed, $S.TotalFindings, $S.WillBreak, $S.DeprecatedUsage, $S.BlindSpots, $S.ObjectsCompatible, $S.ObjectsAssessed) 'OK'
    foreach ($p in $made) { Write-AdvLog "  -> $p" 'OK' }

    if ($OpenReport) {
        $openTarget = $null
        if ((Test-Path -LiteralPath $htmlPath)) { $openTarget = $htmlPath }
        elseif ($made.Count -gt 0) { $openTarget = $made[0] }
        if ($openTarget) { Start-Process -FilePath $openTarget }
    }

    if ($PassThru) {
        $mods = @()
        if ($IncludeDefinitions) {
            $mods = @(foreach ($dbd in @($inv.DatabaseData)) {
                foreach ($o in @($dbd.Objects)) {
                    if ($o.definition) {
                        [pscustomobject]@{ Database = [string]$dbd.Database; Schema = [string]$o.schema_name; Object = [string]$o.name; ObjectType = [string]$o.type_desc; Definition = [string]$o.definition }
                    }
                }
            })
        }
        return [pscustomobject]@{
            Summary          = $engine.Summary
            Findings         = @($engine.Findings)
            Inventory        = @($engine.Inventory)
            Backlog          = @($engine.Backlog)
            ActiveRules      = @($engine.ActiveRules)
            Coverage         = @($script:AdvCoverage)
            InstanceData     = $inv.InstanceData
            DatabaseData     = @($inv.DatabaseData)
            ModuleDefinitions = $mods
            OutputPath       = $OutputPath
            OutputFiles      = @($made)
        }
    }
} catch {
    Write-AdvLog ("Assessment FAILED: {0}" -f $_.Exception.Message) 'ERROR'
    throw
}

