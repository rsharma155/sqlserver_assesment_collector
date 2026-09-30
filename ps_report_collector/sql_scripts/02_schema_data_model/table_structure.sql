/* SQL_Initial_Assessment */
/*
  Table metadata & storage baseline for upgrade/scalability assessment.
*/
;WITH table_stats AS (
    SELECT
        ps.object_id,
        SUM(CASE WHEN ps.index_id < 2 THEN ps.row_count ELSE 0 END) AS RowCnt,
        SUM(ps.reserved_page_count) AS ReservedPages,
        SUM(ps.used_page_count) AS UsedPages,
        SUM(CASE WHEN ps.index_id < 2 THEN ps.used_page_count ELSE 0 END) AS DataPages,
        SUM(CASE WHEN ps.index_id >= 2 THEN ps.used_page_count ELSE 0 END) AS IndexPages
    FROM sys.dm_db_partition_stats ps
    INNER JOIN sys.tables t ON ps.object_id = t.object_id
    WHERE t.is_ms_shipped = 0
    GROUP BY ps.object_id
),
col_counts AS (
    SELECT object_id, COUNT(*) AS ColumnCount
    FROM sys.columns
    GROUP BY object_id
),
index_counts AS (
    SELECT
        object_id,
        COUNT(*) AS IndexCount,
        SUM(CASE WHEN type = 1 THEN 1 ELSE 0 END) AS ClusteredCount,
        SUM(CASE WHEN type = 2 THEN 1 ELSE 0 END) AS NonclusteredCount,
        SUM(CASE WHEN type IN (5, 6) THEN 1 ELSE 0 END) AS ColumnstoreCount,
        SUM(CASE WHEN has_filter = 1 THEN 1 ELSE 0 END) AS FilteredIndexCount
    FROM sys.indexes
    WHERE index_id > 0 AND is_hypothetical = 0
    GROUP BY object_id
),
pk_info AS (
    SELECT
        i.object_id,
        i.name AS PrimaryKeyName,
        CASE WHEN i.type = 1 THEN 1 ELSE 0 END AS PkIsClustered,
        STUFF((
            SELECT ', ' + c.name + '(' + ty.name +
                   CASE
                       WHEN ty.name IN ('varchar','nvarchar','char','nchar','varbinary','binary')
                            THEN '(' + CASE WHEN c.max_length = -1 THEN 'MAX' ELSE CAST(
                                CASE WHEN ty.name LIKE 'n%' THEN c.max_length / 2 ELSE c.max_length END AS varchar(10)) END + ')'
                       WHEN ty.name IN ('decimal','numeric')
                            THEN '(' + CAST(c.precision AS varchar(10)) + ',' + CAST(c.scale AS varchar(10)) + ')'
                       ELSE ''
                   END + ')'
            FROM sys.index_columns ic
            INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
            ORDER BY ic.key_ordinal
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, '') AS PkColumnsWithTypes,
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM sys.index_columns ic
                INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
                INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
                WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
                  AND ty.name IN ('uniqueidentifier')
            ) THEN 1 ELSE 0
        END AS PkContainsGuid
    FROM sys.indexes i
    WHERE i.is_primary_key = 1
),
clustered_info AS (
    SELECT
        i.object_id,
        i.name AS ClusteredIndexName,
        STUFF((
            SELECT ', ' + c.name
            FROM sys.index_columns ic
            INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
            ORDER BY ic.key_ordinal
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, '') AS ClusteredKeyColumns
    FROM sys.indexes i
    WHERE i.type = 1
),
partition_base AS (
    SELECT
        i.object_id,
        i.index_id,
        ps.name AS PartitionScheme,
        pf.name AS PartitionFunction,
        p.partition_number
    FROM sys.indexes i
    INNER JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id
    INNER JOIN sys.partition_schemes ps ON i.data_space_id = ps.data_space_id
    INNER JOIN sys.partition_functions pf ON ps.function_id = pf.function_id
    WHERE i.index_id IN (0, 1)
),
partition_columns AS (
    SELECT DISTINCT
        i.object_id,
        i.index_id,
        STUFF((
            SELECT ', ' + c.name
            FROM sys.index_columns ic
            INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE ic.object_id = i.object_id
              AND ic.index_id = i.index_id
              AND ic.partition_ordinal > 0
            ORDER BY ic.partition_ordinal
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, '') AS PartitionColumns
    FROM sys.indexes i
    WHERE i.index_id IN (0, 1)
      AND EXISTS (
            SELECT 1
            FROM sys.partition_schemes ps
            WHERE ps.data_space_id = i.data_space_id
          )
),
partition_info_one AS (
    SELECT
        pb.object_id,
        COUNT(DISTINCT pb.partition_number) AS PartitionCount,
        MAX(pb.PartitionScheme) AS PartitionScheme,
        MAX(pb.PartitionFunction) AS PartitionFunction,
        MAX(pc.PartitionColumns) AS PartitionColumns
    FROM partition_base pb
    LEFT JOIN partition_columns pc
        ON pb.object_id = pc.object_id
       AND pb.index_id = pc.index_id
    GROUP BY pb.object_id
),
compression_info AS (
    SELECT
        p.object_id,
        MAX(CASE WHEN p.data_compression_desc <> 'NONE' THEN p.data_compression_desc END) AS DataCompression
    FROM sys.partitions p
    WHERE p.index_id IN (0, 1)
    GROUP BY p.object_id
)
SELECT TOP (400)
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(ts.object_id) AS SchemaName,
    OBJECT_NAME(ts.object_id) AS TableName,
    ts.RowCnt AS [RowCount],
    CASE
        WHEN ts.RowCnt >= 100000000 THEN 'Massive'
        WHEN ts.RowCnt >= 10000000 THEN 'Large'
        WHEN ts.RowCnt >= 100000 THEN 'Medium'
        ELSE 'Small'
    END AS SizeTier,
    CAST(ts.DataPages * 8.0 / 1024 AS decimal(18, 2)) AS DataMB,
    CAST(ts.IndexPages * 8.0 / 1024 AS decimal(18, 2)) AS IndexMB,
    CAST(ts.ReservedPages * 8.0 / 1024 AS decimal(18, 2)) AS ReservedMB,
    CAST((ts.ReservedPages - ts.UsedPages) * 8.0 / 1024 AS decimal(18, 2)) AS UnusedMB,
    CAST(CASE WHEN ts.DataPages > 0 THEN ts.IndexPages * 100.0 / ts.DataPages ELSE 0 END AS decimal(18, 1)) AS IndexToDataPct,
    CAST(CASE
        WHEN ts.RowCnt > 0 THEN (ts.DataPages * 8.0 * 1024.0) / ts.RowCnt
        ELSE NULL
    END AS decimal(18, 1)) AS AvgRowBytesEstimate,
    ISNULL(cc.ColumnCount, 0) AS ColumnCount,
    ISNULL(ic.IndexCount, 0) AS IndexCount,
    ISNULL(ic.NonclusteredCount, 0) AS NonclusteredIndexCount,
    ISNULL(ic.FilteredIndexCount, 0) AS FilteredIndexCount,
    ISNULL(ic.ColumnstoreCount, 0) AS ColumnstoreIndexCount,
    CASE WHEN ISNULL(ic.ClusteredCount, 0) = 0 THEN 1 ELSE 0 END AS IsHeap,
    CASE
        WHEN ISNULL(ic.ClusteredCount, 0) = 0 AND ISNULL(ic.NonclusteredCount, 0) > 0 THEN 1
        ELSE 0
    END AS IsHeapWithNonclustered,
    CASE WHEN pk.object_id IS NULL THEN 0 ELSE 1 END AS HasPrimaryKey,
    pk.PrimaryKeyName,
    pk.PkColumnsWithTypes,
    pk.PkIsClustered,
    pk.PkContainsGuid,
    ci.ClusteredIndexName,
    ci.ClusteredKeyColumns,
    CASE WHEN ISNULL(pi.PartitionCount, 1) > 1 THEN 1 ELSE 0 END AS IsPartitioned,
    ISNULL(pi.PartitionCount, 1) AS PartitionCount,
    pi.PartitionScheme,
    pi.PartitionFunction,
    pi.PartitionColumns,
    ISNULL(comp.DataCompression, 'NONE') AS DataCompression,
    CASE WHEN t.is_tracked_by_cdc = 1 THEN 1 ELSE 0 END AS IsCdcTracked,
    CASE WHEN t.temporal_type > 0 THEN 1 ELSE 0 END AS IsTemporal,
    CASE WHEN t.is_memory_optimized = 1 THEN 1 ELSE 0 END AS IsMemoryOptimized,
    t.create_date AS CreateDate,
    t.modify_date AS ModifyDate
FROM table_stats ts
INNER JOIN sys.tables t ON ts.object_id = t.object_id
LEFT JOIN col_counts cc ON ts.object_id = cc.object_id
LEFT JOIN index_counts ic ON ts.object_id = ic.object_id
LEFT JOIN pk_info pk ON ts.object_id = pk.object_id
LEFT JOIN clustered_info ci ON ts.object_id = ci.object_id
LEFT JOIN partition_info_one pi ON ts.object_id = pi.object_id
LEFT JOIN compression_info comp ON ts.object_id = comp.object_id
ORDER BY ts.ReservedPages DESC, ts.RowCnt DESC;
