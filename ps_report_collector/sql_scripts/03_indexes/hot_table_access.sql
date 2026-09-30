/* SQL_Initial_Assessment */
SELECT TOP (100)
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName,
    OBJECT_NAME(i.object_id) AS TableName,
    SUM(ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0)) AS TotalReads,
    SUM(ISNULL(ius.user_updates, 0)) AS TotalWrites,
    CAST(
        CASE
            WHEN SUM(ISNULL(ius.user_updates, 0)) = 0 THEN NULL
            ELSE 1.0 * SUM(ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0))
                 / SUM(ISNULL(ius.user_updates, 0))
        END AS decimal(18, 2)
    ) AS ReadWriteRatio,
    CASE
        WHEN SUM(ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0))
             > SUM(ISNULL(ius.user_updates, 0)) * 5 THEN 'Read-heavy'
        WHEN SUM(ISNULL(ius.user_updates, 0))
             > SUM(ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0)) * 5 THEN 'Write-heavy'
        ELSE 'Mixed'
    END AS AccessPattern
FROM sys.indexes i
INNER JOIN sys.tables t ON i.object_id = t.object_id
LEFT JOIN sys.dm_db_index_usage_stats ius
    ON i.object_id = ius.object_id
   AND i.index_id = ius.index_id
   AND ius.database_id = DB_ID()
WHERE t.is_ms_shipped = 0
  AND i.index_id > 0
GROUP BY i.object_id
HAVING SUM(ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0) + ISNULL(ius.user_updates, 0)) > 0
ORDER BY (SUM(ISNULL(ius.user_seeks, 0) + ISNULL(ius.user_scans, 0) + ISNULL(ius.user_lookups, 0) + ISNULL(ius.user_updates, 0))) DESC;
