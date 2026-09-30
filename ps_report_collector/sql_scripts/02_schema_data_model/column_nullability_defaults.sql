/* SQL_Initial_Assessment */
/*
  Nullable columns and missing database defaults — data quality / design signals.
  Exact NULL percentages require sampling; this captures structure + default coverage.
*/
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(c.object_id) AS SchemaName,
    OBJECT_NAME(c.object_id) AS TableName,
    c.name AS ColumnName,
    ty.name AS DataType,
    c.is_nullable AS IsNullable,
    CASE WHEN dc.object_id IS NULL THEN 0 ELSE 1 END AS HasDefaultConstraint,
    LEFT(dc.definition, 200) AS DefaultDefinition,
    c.is_identity AS IsIdentity,
    c.is_computed AS IsComputed,
    CASE
        WHEN c.is_nullable = 1 AND dc.object_id IS NULL AND c.is_computed = 0 AND c.is_identity = 0
            THEN 'Nullable without DB default - defaults may live only in application code'
        WHEN c.is_nullable = 1 AND dc.object_id IS NOT NULL
            THEN 'Nullable with DB default'
        WHEN c.is_nullable = 0 AND dc.object_id IS NULL AND c.is_identity = 0 AND c.is_computed = 0
            THEN 'NOT NULL without default - insert path must always supply value'
        ELSE 'OK / not applicable'
    END AS Assessment
FROM sys.columns c
INNER JOIN sys.tables t ON c.object_id = t.object_id
INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
LEFT JOIN sys.default_constraints dc
    ON c.object_id = dc.parent_object_id
   AND c.column_id = dc.parent_column_id
WHERE t.is_ms_shipped = 0
  AND (
        c.is_nullable = 1
        OR (c.is_nullable = 0 AND dc.object_id IS NULL AND c.is_identity = 0 AND c.is_computed = 0
            AND ty.name NOT IN ('timestamp', 'rowversion'))
      )
ORDER BY
    CASE WHEN c.is_nullable = 1 AND dc.object_id IS NULL THEN 0 ELSE 1 END,
    SchemaName, TableName, ColumnName;
