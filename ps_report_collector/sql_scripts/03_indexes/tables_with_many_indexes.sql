/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(t.object_id) AS SchemaName,
    t.name AS TableName,
    COUNT(*) AS IndexCount,
    SUM(CASE WHEN i.type = 1 THEN 1 ELSE 0 END) AS ClusteredCount,
    SUM(CASE WHEN i.type = 2 THEN 1 ELSE 0 END) AS NonclusteredCount,
    SUM(CASE WHEN i.type IN (5, 6) THEN 1 ELSE 0 END) AS ColumnstoreCount,
    SUM(CASE WHEN i.type = 3 THEN 1 ELSE 0 END) AS XmlIndexCount,
    SUM(CASE WHEN i.type = 4 THEN 1 ELSE 0 END) AS SpatialIndexCount,
    CASE
        WHEN COUNT(*) > 20 THEN 'Critical review'
        WHEN COUNT(*) > 10 THEN 'Review necessity'
        ELSE 'OK'
    END AS Assessment
FROM sys.tables t
INNER JOIN sys.indexes i ON t.object_id = i.object_id
WHERE t.is_ms_shipped = 0
  AND i.index_id > 0
  AND i.is_hypothetical = 0
GROUP BY t.object_id, t.name
HAVING COUNT(*) > 5
ORDER BY IndexCount DESC, SchemaName, TableName;
