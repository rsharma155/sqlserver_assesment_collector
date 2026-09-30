/* SQL_Initial_Assessment */
SELECT
    'Profile' AS ObjectType,
    p.name AS Name,
    CAST(NULL AS bit) AS IsEnabled,
    p.description AS Details
FROM msdb.dbo.sysmail_profile p

UNION ALL

SELECT
    'Account' AS ObjectType,
    a.name AS Name,
    CAST(NULL AS bit) AS IsEnabled,
    a.email_address AS Details
FROM msdb.dbo.sysmail_account a

UNION ALL

SELECT
    'Config' AS ObjectType,
    paramname AS Name,
    CAST(NULL AS bit) AS IsEnabled,
    CAST(paramvalue AS nvarchar(256)) AS Details
FROM msdb.dbo.sysmail_configuration

UNION ALL

SELECT
    'XpCmdshellOrMailXps' AS ObjectType,
    c.name AS Name,
    CASE WHEN c.value_in_use = 1 THEN CAST(1 AS bit) ELSE CAST(0 AS bit) END AS IsEnabled,
    CAST(c.value_in_use AS nvarchar(20)) AS Details
FROM sys.configurations c
WHERE c.name IN ('Database Mail XPs', 'Agent XPs')

ORDER BY ObjectType, Name;
