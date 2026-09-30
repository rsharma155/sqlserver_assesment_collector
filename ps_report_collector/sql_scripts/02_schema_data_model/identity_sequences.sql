/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    'Identity' AS ObjectKind,
    OBJECT_SCHEMA_NAME(c.object_id) AS SchemaName,
    OBJECT_NAME(c.object_id) AS TableOrSequenceName,
    c.name AS ColumnName,
    ty.name AS DataType,
    ic.seed_value AS SeedOrStart,
    ic.increment_value AS Increment,
    ic.last_value AS CurrentValue,
    CAST(NULL AS bit) AS IsCycling,
    CAST(NULL AS bit) AS IsCached
FROM sys.columns c
INNER JOIN sys.tables t ON c.object_id = t.object_id
INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
INNER JOIN sys.identity_columns ic ON c.object_id = ic.object_id AND c.column_id = ic.column_id
WHERE c.is_identity = 1 AND t.is_ms_shipped = 0

UNION ALL

SELECT
    DB_NAME() AS DatabaseName,
    'Sequence' AS ObjectKind,
    OBJECT_SCHEMA_NAME(s.object_id) AS SchemaName,
    s.name AS TableOrSequenceName,
    CAST(NULL AS sysname) AS ColumnName,
    TYPE_NAME(s.user_type_id) AS DataType,
    s.start_value AS SeedOrStart,
    s.increment AS Increment,
    s.current_value AS CurrentValue,
    s.is_cycling AS IsCycling,
    s.is_cached AS IsCached
FROM sys.sequences s

ORDER BY ObjectKind, SchemaName, TableOrSequenceName;
