/* SQL_Initial_Assessment */
-- Primary keys
SELECT
    DB_NAME() AS DatabaseName,
    'PrimaryKey' AS ConstraintType,
    OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName,
    OBJECT_NAME(i.object_id) AS TableName,
    i.name AS ConstraintName,
    i.type_desc AS IndexType,
    i.is_unique AS IsUnique,
    i.is_primary_key AS IsPrimaryKey,
    CASE WHEN i.type = 1 THEN 1 ELSE 0 END AS IsClustered,
    CAST(NULL AS nvarchar(20)) AS DeleteAction,
    CAST(NULL AS nvarchar(20)) AS UpdateAction,
    CAST(NULL AS bit) AS IsDisabled,
    CAST(NULL AS bit) AS IsNotTrusted,
    CAST(NULL AS nvarchar(256)) AS ReferencedTable,
    STUFF((
        SELECT ', ' + c.name + ' (' + ty.name + ')'
        FROM sys.index_columns ic
        INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
        ORDER BY ic.key_ordinal
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 2, '') AS KeyColumns
FROM sys.indexes i
INNER JOIN sys.tables t ON i.object_id = t.object_id
WHERE i.is_primary_key = 1 AND t.is_ms_shipped = 0

UNION ALL

-- Foreign keys
SELECT
    DB_NAME() AS DatabaseName,
    'ForeignKey' AS ConstraintType,
    OBJECT_SCHEMA_NAME(fk.parent_object_id) AS SchemaName,
    OBJECT_NAME(fk.parent_object_id) AS TableName,
    fk.name AS ConstraintName,
    CAST(NULL AS nvarchar(60)) AS IndexType,
    CAST(NULL AS bit) AS IsUnique,
    CAST(NULL AS bit) AS IsPrimaryKey,
    CAST(NULL AS int) AS IsClustered,
    fk.delete_referential_action_desc AS DeleteAction,
    fk.update_referential_action_desc AS UpdateAction,
    fk.is_disabled AS IsDisabled,
    fk.is_not_trusted AS IsNotTrusted,
    OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id) AS ReferencedTable,
    STUFF((
        SELECT ', ' + COL_NAME(fkc.parent_object_id, fkc.parent_column_id)
             + ' -> ' + COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id)
        FROM sys.foreign_key_columns fkc
        WHERE fkc.constraint_object_id = fk.object_id
        ORDER BY fkc.constraint_column_id
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 2, '') AS KeyColumns
FROM sys.foreign_keys fk
INNER JOIN sys.tables t ON fk.parent_object_id = t.object_id
WHERE t.is_ms_shipped = 0

UNION ALL

-- Unique constraints
SELECT
    DB_NAME() AS DatabaseName,
    'UniqueConstraint' AS ConstraintType,
    OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName,
    OBJECT_NAME(i.object_id) AS TableName,
    i.name AS ConstraintName,
    i.type_desc AS IndexType,
    i.is_unique AS IsUnique,
    i.is_primary_key AS IsPrimaryKey,
    CASE WHEN i.type = 1 THEN 1 ELSE 0 END AS IsClustered,
    CAST(NULL AS nvarchar(20)) AS DeleteAction,
    CAST(NULL AS nvarchar(20)) AS UpdateAction,
    CAST(NULL AS bit) AS IsDisabled,
    CAST(NULL AS bit) AS IsNotTrusted,
    CAST(NULL AS nvarchar(256)) AS ReferencedTable,
    STUFF((
        SELECT ', ' + c.name
        FROM sys.index_columns ic
        INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
        WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id AND ic.is_included_column = 0
        ORDER BY ic.key_ordinal
        FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 2, '') AS KeyColumns
FROM sys.indexes i
INNER JOIN sys.tables t ON i.object_id = t.object_id
WHERE i.is_unique_constraint = 1 AND t.is_ms_shipped = 0

UNION ALL

-- Check constraints
SELECT
    DB_NAME() AS DatabaseName,
    'CheckConstraint' AS ConstraintType,
    OBJECT_SCHEMA_NAME(cc.parent_object_id) AS SchemaName,
    OBJECT_NAME(cc.parent_object_id) AS TableName,
    cc.name AS ConstraintName,
    CAST(NULL AS nvarchar(60)) AS IndexType,
    CAST(NULL AS bit) AS IsUnique,
    CAST(NULL AS bit) AS IsPrimaryKey,
    CAST(NULL AS int) AS IsClustered,
    CAST(NULL AS nvarchar(20)) AS DeleteAction,
    CAST(NULL AS nvarchar(20)) AS UpdateAction,
    cc.is_disabled AS IsDisabled,
    cc.is_not_trusted AS IsNotTrusted,
    CAST(NULL AS nvarchar(256)) AS ReferencedTable,
    LEFT(cc.definition, 400) AS KeyColumns
FROM sys.check_constraints cc
INNER JOIN sys.tables t ON cc.parent_object_id = t.object_id
WHERE t.is_ms_shipped = 0

UNION ALL

-- Default constraints
SELECT
    DB_NAME() AS DatabaseName,
    'DefaultConstraint' AS ConstraintType,
    OBJECT_SCHEMA_NAME(dc.parent_object_id) AS SchemaName,
    OBJECT_NAME(dc.parent_object_id) AS TableName,
    dc.name AS ConstraintName,
    CAST(NULL AS nvarchar(60)) AS IndexType,
    CAST(NULL AS bit) AS IsUnique,
    CAST(NULL AS bit) AS IsPrimaryKey,
    CAST(NULL AS int) AS IsClustered,
    CAST(NULL AS nvarchar(20)) AS DeleteAction,
    CAST(NULL AS nvarchar(20)) AS UpdateAction,
    CAST(NULL AS bit) AS IsDisabled,
    CAST(NULL AS bit) AS IsNotTrusted,
    COL_NAME(dc.parent_object_id, dc.parent_column_id) AS ReferencedTable,
    LEFT(dc.definition, 400) AS KeyColumns
FROM sys.default_constraints dc
INNER JOIN sys.tables t ON dc.parent_object_id = t.object_id
WHERE t.is_ms_shipped = 0

ORDER BY ConstraintType, SchemaName, TableName, ConstraintName;
