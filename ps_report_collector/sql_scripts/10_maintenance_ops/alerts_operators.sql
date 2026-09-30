/* SQL_Initial_Assessment */
SELECT
    'Alert' AS ObjectType,
    a.name AS Name,
    a.enabled AS IsEnabled,
    a.has_notification AS HasNotification,
    a.severity AS Severity,
    a.message_id AS MessageId,
    a.performance_condition AS PerformanceCondition,
    CAST(NULL AS nvarchar(128)) AS EmailAddress
FROM msdb.dbo.sysalerts a

UNION ALL

SELECT
    'Operator' AS ObjectType,
    o.name AS Name,
    o.enabled AS IsEnabled,
    CASE WHEN o.email_address IS NOT NULL AND o.email_address <> '' THEN 1 ELSE 0 END AS HasNotification,
    CAST(NULL AS int) AS Severity,
    CAST(NULL AS int) AS MessageId,
    CAST(NULL AS nvarchar(512)) AS PerformanceCondition,
    o.email_address AS EmailAddress
FROM msdb.dbo.sysoperators o

ORDER BY ObjectType, Name;
