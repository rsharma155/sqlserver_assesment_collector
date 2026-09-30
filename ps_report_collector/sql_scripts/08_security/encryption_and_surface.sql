/* SQL_Initial_Assessment */
SELECT
    d.name AS DatabaseName,
    d.is_encrypted AS TdeEnabled,
    d.is_trustworthy_on AS Trustworthy,
    d.is_db_chaining_on AS DbChaining,
    CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS WindowsAuthOnly,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'clr enabled') AS ClrEnabled,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'xp_cmdshell') AS XpCmdshell,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'Ole Automation Procedures') AS OleAutomation,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'cross db ownership chaining') AS CrossDbOwnershipChaining,
    (SELECT CAST(value_in_use AS int) FROM sys.configurations WHERE name = 'Ad Hoc Distributed Queries') AS AdHocDistributedQueries
FROM sys.databases d
WHERE d.database_id > 4 OR d.name IN ('master', 'msdb')
ORDER BY d.name;
