/* SQL_Initial_Assessment */
/*
  Instance-scope deprecated feature checks (configuration + Agent jobs).
*/
SELECT
    CAST(@@SERVERNAME AS nvarchar(128)) COLLATE DATABASE_DEFAULT AS DatabaseName,
    CAST(Severity AS nvarchar(20)) COLLATE DATABASE_DEFAULT AS Severity,
    CAST(Category AS nvarchar(40)) COLLATE DATABASE_DEFAULT AS Category,
    CAST(DeprecatedFeature AS nvarchar(200)) COLLATE DATABASE_DEFAULT AS DeprecatedFeature,
    CAST(NULL AS nvarchar(128)) COLLATE DATABASE_DEFAULT AS SchemaName,
    CAST(ObjectName AS nvarchar(256)) COLLATE DATABASE_DEFAULT AS ObjectName,
    CAST(ObjectType AS nvarchar(60)) COLLATE DATABASE_DEFAULT AS ObjectType,
    CAST(WhyFlagged AS nvarchar(400)) COLLATE DATABASE_DEFAULT AS WhyFlagged,
    CAST(RecommendedAction AS nvarchar(400)) COLLATE DATABASE_DEFAULT AS RecommendedAction,
    CAST(VersionNote AS nvarchar(80)) COLLATE DATABASE_DEFAULT AS VersionNote,
    CAST(Evidence AS nvarchar(200)) COLLATE DATABASE_DEFAULT AS Evidence
FROM (
    SELECT
        CASE WHEN c.value_in_use <> 0 THEN 'HIGH' ELSE 'INFO' END AS Severity,
        'Deprecated Config' AS Category,
        c.name AS DeprecatedFeature,
        'sys.configurations' AS ObjectName,
        'CONFIGURATION' AS ObjectType,
        'This sp_configure option is deprecated/removed in modern SQL Server releases and should not be relied on.' AS WhyFlagged,
        'Confirm value_in_use=0 and remove any automation that sets this option.' AS RecommendedAction,
        'Deprecated/removed around SQL Server 2012' AS VersionNote,
        ('value_in_use=' + CAST(c.value_in_use AS varchar(20))) AS Evidence
    FROM sys.configurations c
    WHERE c.name IN (
        'allow updates',
        'locks',
        'open objects',
        'priority boost',
        'remote proc trans',
        'set working set size',
        'disallow results from triggers'
    )

    UNION ALL

    SELECT
        'HIGH' AS Severity,
        'Deprecated Job Command' AS Category,
        CASE
            WHEN s.command LIKE '%BACKUP%PASSWORD%' OR s.command LIKE '%RESTORE%PASSWORD%' THEN 'BACKUP/RESTORE WITH PASSWORD'
            WHEN s.command LIKE '%sp_dboption%' THEN 'sp_dboption'
            WHEN s.command LIKE '%sp_adduser%' OR s.command LIKE '%sp_dropuser%' THEN 'sp_adduser / sp_dropuser'
            WHEN s.command LIKE '%sp_addlogin%' OR s.command LIKE '%sp_droplogin%' THEN 'sp_addlogin / sp_droplogin'
            WHEN s.command LIKE '%SET ROWCOUNT%' THEN 'SET ROWCOUNT'
            WHEN s.command LIKE '%TRUNCATE_ONLY%' OR s.command LIKE '%WITH NO_LOG%' THEN 'BACKUP LOG TRUNCATE_ONLY/NO_LOG'
            ELSE 'Deprecated command in Agent job'
        END AS DeprecatedFeature,
        j.name AS ObjectName,
        'SQL_AGENT_JOB' AS ObjectType,
        'SQL Agent job step contains removed or deprecated syntax that can break after upgrade.' AS WhyFlagged,
        'Update the job step to modern T-SQL / backup practices before or during upgrade.' AS RecommendedAction,
        'SQL Server 2012-2022 deprecation list' AS VersionNote,
        LEFT(REPLACE(REPLACE(s.command, CHAR(13), ' '), CHAR(10), ' '), 200) AS Evidence
    FROM msdb.dbo.sysjobs j
    INNER JOIN msdb.dbo.sysjobsteps s ON j.job_id = s.job_id
    WHERE s.command LIKE '%BACKUP%PASSWORD%'
       OR s.command LIKE '%RESTORE%PASSWORD%'
       OR s.command LIKE '%sp_dboption%'
       OR s.command LIKE '%sp_adduser%'
       OR s.command LIKE '%sp_dropuser%'
       OR s.command LIKE '%sp_addlogin%'
       OR s.command LIKE '%sp_droplogin%'
       OR s.command LIKE '%SET ROWCOUNT%'
       OR s.command LIKE '%TRUNCATE_ONLY%'
       OR s.command LIKE '%WITH NO_LOG%'
) AS x
ORDER BY
    CASE Severity WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 4 ELSE 5 END,
    Category, DeprecatedFeature, ObjectName;
