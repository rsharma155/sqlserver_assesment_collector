/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    o.type_desc AS ObjectType,
    OBJECT_SCHEMA_NAME(o.object_id) AS SchemaName,
    o.name AS ObjectName,
    CASE
        WHEN o.name LIKE ' %' OR o.name LIKE '% ' THEN 'Leading/trailing space in name'
        WHEN o.name LIKE '% %' THEN 'Space in object name'
        WHEN o.name COLLATE Latin1_General_BIN LIKE '%[a-z][A-Z]%' AND o.name LIKE '%[_]%' THEN 'Mixed naming styles'
        WHEN LEFT(o.name, 1) LIKE '[0-9]' THEN 'Starts with digit'
        WHEN o.name LIKE 'tbl%' OR o.name LIKE 'tbl[_]%' THEN 'Hungarian tbl prefix'
        WHEN o.name LIKE 'sp[_]%' AND o.type = 'P' THEN 'sp_ prefix on user procedure (conflicts with system naming)'
        WHEN o.schema_id = 1 AND o.type IN ('U', 'P', 'V') THEN 'Object in dbo schema (review schema organization)'
        ELSE 'Review naming'
    END AS Finding,
    'MEDIUM' AS Severity
FROM sys.objects o
WHERE o.is_ms_shipped = 0
  AND o.type IN ('U', 'P', 'V', 'FN', 'IF', 'TF', 'TR')
  AND (
        o.name LIKE ' %' OR o.name LIKE '% ' OR o.name LIKE '% %'
        OR LEFT(o.name, 1) LIKE '[0-9]'
        OR o.name LIKE 'tbl%' OR o.name LIKE 'tbl[_]%'
        OR (o.name LIKE 'sp[_]%' AND o.type = 'P')
      )
ORDER BY ObjectType, SchemaName, ObjectName;
