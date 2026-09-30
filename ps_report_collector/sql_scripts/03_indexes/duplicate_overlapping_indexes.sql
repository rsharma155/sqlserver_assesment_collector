/* SQL_Initial_Assessment */
;WITH index_cols AS (
    SELECT
        i.object_id,
        i.index_id,
        i.name AS IndexName,
        i.type_desc,
        i.is_unique,
        i.has_filter,
        ISNULL(i.filter_definition, '') AS FilterDefinition,
        STUFF((
            SELECT ',' + c.name
            FROM sys.index_columns ic
            INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
            ORDER BY ic.key_ordinal
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 1, '') AS KeyColumns,
        STUFF((
            SELECT ',' + c.name
            FROM sys.index_columns ic
            INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
            WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 1
            ORDER BY ic.index_column_id
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 1, '') AS IncludeColumns
    FROM sys.indexes i
    INNER JOIN sys.tables t ON i.object_id = t.object_id
    WHERE t.is_ms_shipped = 0
      AND i.index_id > 0
      AND i.is_hypothetical = 0
      AND i.is_disabled = 0
)
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(a.object_id) AS SchemaName,
    OBJECT_NAME(a.object_id) AS TableName,
    a.IndexName AS IndexA,
    b.IndexName AS IndexB,
    a.KeyColumns,
    a.IncludeColumns AS IncludeColumnsA,
    b.IncludeColumns AS IncludeColumnsB,
    a.FilterDefinition,
    CASE
        WHEN a.KeyColumns = b.KeyColumns
             AND ISNULL(a.IncludeColumns, '') = ISNULL(b.IncludeColumns, '')
             AND a.FilterDefinition = b.FilterDefinition THEN 'ExactDuplicate'
        WHEN a.KeyColumns = b.KeyColumns THEN 'SameKeyColumns'
        WHEN b.KeyColumns LIKE a.KeyColumns + ',%' THEN 'OverlappingPrefix'
        ELSE 'Related'
    END AS OverlapType
FROM index_cols a
INNER JOIN index_cols b
    ON a.object_id = b.object_id
   AND a.index_id < b.index_id
   AND a.FilterDefinition = b.FilterDefinition
   AND (
        a.KeyColumns = b.KeyColumns
        OR b.KeyColumns LIKE a.KeyColumns + ',%'
        OR a.KeyColumns LIKE b.KeyColumns + ',%'
       )
ORDER BY SchemaName, TableName, OverlapType;
