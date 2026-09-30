/* SQL_Initial_Assessment */
SELECT TOP (300)
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName,
    OBJECT_NAME(i.object_id) AS TableName,
    i.name AS IndexName,
    i.type_desc AS IndexType,
    i.is_unique AS IsUnique,
    i.is_primary_key AS IsPrimaryKey,
    i.is_unique_constraint AS IsUniqueConstraint,
    i.fill_factor AS FillFactorPct,
    i.has_filter AS HasFilter,
    i.filter_definition AS FilterDefinition,
    i.is_disabled AS IsDisabled,
    ds.name AS FilegroupOrPartitionScheme,
    p.data_compression_desc AS DataCompression,
    SUM(ps.used_page_count) AS UsedPages,
    CAST(SUM(ps.used_page_count) * 8.0 / 1024 AS decimal(18, 2)) AS UsedMB,
    STUFF((
        SELECT ', ' + c.name
        FROM sys.index_columns ic
        INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
        ORDER BY ic.key_ordinal
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 2, '') AS KeyColumns,
    STUFF((
        SELECT ', ' + c.name
        FROM sys.index_columns ic
        INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
        ORDER BY ic.index_column_id
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 2, '') AS IncludeColumns
FROM sys.indexes i
INNER JOIN sys.tables t ON i.object_id = t.object_id
INNER JOIN sys.dm_db_partition_stats ps ON i.object_id = ps.object_id AND i.index_id = ps.index_id
LEFT JOIN sys.data_spaces ds ON i.data_space_id = ds.data_space_id
LEFT JOIN sys.partitions p ON i.object_id = p.object_id AND i.index_id = p.index_id AND p.partition_number = 1
WHERE t.is_ms_shipped = 0
  AND i.index_id > 0
  AND i.is_hypothetical = 0
GROUP BY
    i.object_id, i.index_id, i.name, i.type_desc, i.is_unique, i.is_primary_key,
    i.is_unique_constraint, i.fill_factor, i.has_filter, i.filter_definition,
    i.is_disabled, ds.name, p.data_compression_desc
ORDER BY
    CAST(SUM(ps.used_page_count) * 8.0 / 1024 AS decimal(18, 2)) DESC,
    OBJECT_SCHEMA_NAME(i.object_id),
    OBJECT_NAME(i.object_id),
    i.name;
