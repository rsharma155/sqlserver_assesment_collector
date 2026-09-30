/* SQL_Initial_Assessment */
SELECT TOP (100)
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(t.object_id) AS SchemaName,
    t.name AS TableName,
    CAST(SUM(ps.used_page_count) * 8.0 / 1024 AS decimal(18, 2)) AS UsedMB,
    MAX(p.data_compression_desc) AS CurrentCompression,
    CASE
        WHEN SUM(ps.used_page_count) >= 12800 AND ISNULL(MAX(p.data_compression_desc), 'NONE') = 'NONE'
            THEN 'Candidate for ROW/PAGE compression'
        WHEN SUM(ps.row_count) >= 1000000
             AND NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type IN (5, 6))
            THEN 'Candidate for Columnstore (analytical tables)'
        ELSE 'Review'
    END AS Opportunity
FROM sys.tables t
INNER JOIN sys.dm_db_partition_stats ps ON t.object_id = ps.object_id AND ps.index_id IN (0, 1)
INNER JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0, 1) AND p.partition_number = 1
WHERE t.is_ms_shipped = 0
  AND t.is_memory_optimized = 0
GROUP BY t.object_id, t.name
HAVING SUM(ps.used_page_count) >= 6400  -- >= 50 MB
ORDER BY UsedMB DESC;
