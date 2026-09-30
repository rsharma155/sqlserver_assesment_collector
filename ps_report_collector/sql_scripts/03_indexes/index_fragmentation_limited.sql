/* SQL_Initial_Assessment */
/*
  LIMITED fragmentation sample for materially sized indexes.
  Keep scoped to avoid heavy production impact.
*/
SELECT TOP (150)
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName,
    OBJECT_NAME(i.object_id) AS TableName,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    ips.partition_number AS PartitionNumber,
    ips.index_level AS IndexLevel,
    ips.page_count AS PageCount,
    CAST(ips.avg_fragmentation_in_percent AS decimal(5, 2)) AS AvgFragmentationPct,
    CAST(ips.avg_page_space_used_in_percent AS decimal(5, 2)) AS AvgPageSpaceUsedPct,
    CASE
        WHEN ips.avg_fragmentation_in_percent >= 30 AND ips.page_count >= 1000 THEN 'Rebuild candidate'
        WHEN ips.avg_fragmentation_in_percent >= 10 AND ips.page_count >= 1000 THEN 'Reorganize candidate'
        ELSE 'Monitor'
    END AS Assessment
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
INNER JOIN sys.indexes i
    ON ips.object_id = i.object_id
   AND ips.index_id = i.index_id
INNER JOIN sys.tables t ON i.object_id = t.object_id
WHERE t.is_ms_shipped = 0
  AND i.is_hypothetical = 0
  AND ips.page_count >= 1000
  AND ips.avg_fragmentation_in_percent >= 10
ORDER BY ips.avg_fragmentation_in_percent DESC, ips.page_count DESC;
