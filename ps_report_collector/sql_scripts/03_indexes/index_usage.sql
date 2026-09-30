/* SQL_Initial_Assessment */
SELECT TOP (300)
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName,
    OBJECT_NAME(i.object_id) AS TableName,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    ISNULL(ius.user_seeks, 0) AS UserSeeks,
    ISNULL(ius.user_scans, 0) AS UserScans,
    ISNULL(ius.user_lookups, 0) AS UserLookups,
    ISNULL(ius.user_updates, 0) AS UserUpdates,
    ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0) AS TotalReads,
    CASE
        WHEN ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0) = 0
             AND ISNULL(ius.user_updates, 0) > 0 THEN 'UnusedWriteOnly'
        WHEN ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0) = 0
             THEN 'Unused'
        WHEN ISNULL(ius.user_updates, 0) > (ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0)) * 10
             THEN 'WriteHeavy'
        ELSE 'Active'
    END AS UsageAssessment,
    ius.last_user_seek AS LastUserSeek,
    ius.last_user_scan AS LastUserScan,
    ius.last_user_lookup AS LastUserLookup,
    ius.last_user_update AS LastUserUpdate
FROM sys.indexes i
INNER JOIN sys.tables t ON i.object_id = t.object_id
LEFT JOIN sys.dm_db_index_usage_stats ius
    ON i.object_id = ius.object_id
   AND i.index_id = ius.index_id
   AND ius.database_id = DB_ID()
WHERE t.is_ms_shipped = 0
  AND i.index_id > 0
  AND i.is_hypothetical = 0
  AND i.is_primary_key = 0
ORDER BY
    CASE
        WHEN ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0) = 0 THEN 0
        ELSE 1
    END,
    UserUpdates DESC,
    TotalReads ASC;
