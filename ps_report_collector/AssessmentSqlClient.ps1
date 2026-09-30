# Dot-source this file from the assessment collectors.
# Built-in ADO.NET replacement for Connect-DbaInstance / Invoke-DbaQuery.
# Do not set strict mode or error-action preference here; the caller owns that.

function Connect-AssessmentSqlInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ServerInstance,
        [Parameter(Mandatory)][pscredential]$Credential,
        [string]$Database = 'master',
        [int]$ConnectTimeoutSec = 15
    )

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder['Data Source'] = $ServerInstance
    $builder['Initial Catalog'] = $Database
    $builder['Connect Timeout'] = $ConnectTimeoutSec
    $builder['Application Name'] = 'SQL Assessment Collector'
    # Match the previous dbatools call: Connect-DbaInstance -TrustServerCertificate.
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $true
    $builder['Integrated Security'] = $false
    $builder['Pooling'] = $false
    $builder['User ID'] = $Credential.UserName
    $network = New-Object System.Net.NetworkCredential('', $Credential.Password)
    $builder['Password'] = $network.Password

    $connection = New-Object System.Data.SqlClient.SqlConnection $builder.ConnectionString
    $connection.Open()
    return $connection
}

function Close-AssessmentSqlConnection {
    [CmdletBinding()]
    param([AllowNull()]$Connection)

    if ($null -eq $Connection) { return }
    try {
        try {
            if ($Connection -is [System.Data.SqlClient.SqlConnection] -and
                $Connection.State -ne [System.Data.ConnectionState]::Closed) {
                $Connection.Close()
            }
        }
        finally {
            if ($Connection -is [System.IDisposable]) {
                $Connection.Dispose()
            }
        }
    }
    catch { }
}

function ConvertFrom-AssessmentDataTable {
    [CmdletBinding()]
    param([AllowNull()][System.Data.DataTable]$Table)

    $list = New-Object System.Collections.Generic.List[object]
    if ($null -eq $Table) { return @() }
    foreach ($row in $Table.Rows) {
        $ordered = [ordered]@{}
        foreach ($col in $Table.Columns) {
            $value = $row[$col]
            if ($value -is [System.DBNull]) { $value = $null }
            $ordered[$col.ColumnName] = $value
        }
        $list.Add([pscustomobject]$ordered)
    }
    return @($list.ToArray())
}

function Invoke-AssessmentSqlQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Query,
        [string]$Database = 'master',
        [int]$QueryTimeout = 180
    )

    if ($Connection.State -ne [System.Data.ConnectionState]::Open) {
        $Connection.Open()
    }
    if ($Connection.Database -ne $Database) {
        $Connection.ChangeDatabase($Database)
    }

    $command = $Connection.CreateCommand()
    $command.CommandText = $Query
    $command.CommandTimeout = $QueryTimeout
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command
    $table = New-Object System.Data.DataTable
    try {
        [void]$adapter.Fill($table)
    }
    finally {
        $command.Dispose()
        $adapter.Dispose()
    }

    $converted = @(ConvertFrom-AssessmentDataTable -Table $table)
    return $converted
}
