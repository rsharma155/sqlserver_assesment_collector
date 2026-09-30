/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(t.object_id) AS SchemaName,
    t.name AS TableName,
    CASE
        WHEN t.temporal_type = 1 THEN 'History table'
        WHEN t.temporal_type = 2 THEN 'System-versioned temporal'
        WHEN t.is_memory_optimized = 1 THEN 'Memory-optimized'
        WHEN t.is_filetable = 1 THEN 'FileTable'
        WHEN t.is_tracked_by_cdc = 1 THEN 'CDC tracked'
        WHEN EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.is_filestream = 1) THEN 'FILESTREAM columns'
        WHEN EXISTS (SELECT 1 FROM sys.partitions p WHERE p.object_id = t.object_id AND p.partition_number > 1) THEN 'Partitioned'
        WHEN EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type IN (5, 6)) THEN 'Columnstore index present'
        WHEN EXISTS (SELECT 1 FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0,1) AND p.data_compression > 0) THEN 'Compressed storage'
        WHEN EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.is_computed = 1) THEN 'Has computed columns'
        WHEN EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.is_sparse = 1) THEN 'Has sparse columns'
        ELSE 'Other modern feature'
    END AS Feature,
    t.temporal_type_desc AS TemporalType,
    OBJECT_SCHEMA_NAME(t.history_table_id) + '.' + OBJECT_NAME(t.history_table_id) AS HistoryTable,
    t.durability_desc AS Durability,
    CASE WHEN t.is_tracked_by_cdc = 1 THEN 1 ELSE 0 END AS IsCdcTracked,
    (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id AND c.is_computed = 1) AS ComputedColumnCount,
    (SELECT COUNT(*) FROM sys.computed_columns cc WHERE cc.object_id = t.object_id AND cc.is_persisted = 1) AS PersistedComputedCount,
    (SELECT COUNT(*) FROM sys.computed_columns cc WHERE cc.object_id = t.object_id AND cc.is_persisted = 0) AS NonPersistedComputedCount,
    (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id AND c.is_sparse = 1) AS SparseColumnCount,
    (SELECT COUNT(*) FROM sys.columns c WHERE c.object_id = t.object_id AND c.system_type_id = 241) AS XmlColumnCount,
    (SELECT COUNT(*) FROM sys.columns c INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id WHERE c.object_id = t.object_id AND ty.name IN ('geography','geometry','hierarchyid')) AS SpatialHierarchyColumnCount,
    (SELECT COUNT(*) FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type IN (5, 6)) AS ColumnstoreIndexCount,
    (SELECT MAX(p.data_compression_desc) FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0, 1)) AS DataCompression
FROM sys.tables t
WHERE t.is_ms_shipped = 0
  AND (
        t.temporal_type > 0
        OR t.is_memory_optimized = 1
        OR t.is_filetable = 1
        OR t.is_tracked_by_cdc = 1
        OR EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND c.is_filestream = 1)
        OR EXISTS (SELECT 1 FROM sys.partitions p WHERE p.object_id = t.object_id AND p.partition_number > 1)
        OR EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type IN (5, 6))
        OR EXISTS (SELECT 1 FROM sys.partitions p WHERE p.object_id = t.object_id AND p.index_id IN (0,1) AND p.data_compression > 0)
        OR EXISTS (SELECT 1 FROM sys.columns c WHERE c.object_id = t.object_id AND (c.is_computed = 1 OR c.is_sparse = 1 OR c.system_type_id = 241))
        OR EXISTS (SELECT 1 FROM sys.columns c INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id WHERE c.object_id = t.object_id AND ty.name IN ('geography','geometry','hierarchyid'))
      )
ORDER BY Feature, SchemaName, TableName;
