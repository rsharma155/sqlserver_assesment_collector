/* SQL_Initial_Assessment */
SELECT TOP (200)
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(o.object_id) AS SchemaName,
    o.name AS ObjectName,
    o.type_desc AS ObjectType,
    CASE
        WHEN sm.definition LIKE '%*=%' OR sm.definition LIKE '%=*%' THEN 'Old-style outer join'
        WHEN sm.definition LIKE '%= NULL%' OR sm.definition LIKE '%<> NULL%' THEN 'Equality compare to NULL'
        WHEN sm.definition LIKE '%TEXTIMAGE_ON%' THEN 'TEXTIMAGE_ON usage'
        WHEN sm.definition LIKE '%::fn_%' THEN 'Deprecated system function pattern'
        WHEN sm.definition LIKE '%sysobjects%' OR sm.definition LIKE '%syscolumns%' OR sm.definition LIKE '%sysindexes%' THEN 'Deprecated system table'
        WHEN sm.definition LIKE '%SET ROWCOUNT%' THEN 'SET ROWCOUNT'
        WHEN sm.definition LIKE '%RAISERROR%' AND sm.definition NOT LIKE '%THROW%' THEN 'RAISERROR without THROW'
        WHEN sm.definition LIKE '%GOTO %' THEN 'GOTO usage'
        ELSE 'Other smell'
    END AS SmellType,
    CASE WHEN LEN(sm.definition) > 300 THEN 1 ELSE 0 END AS LargeDefinition,
    ISNULL((SELECT COUNT(*) FROM sys.parameters p WHERE p.object_id = o.object_id AND p.parameter_id > 0), 0) AS ParameterCount
FROM sys.objects o
INNER JOIN sys.sql_modules sm ON o.object_id = sm.object_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('P', 'FN', 'IF', 'TF', 'V', 'TR')
  AND (
        sm.definition LIKE '%*=%' OR sm.definition LIKE '%=*%'
        OR sm.definition LIKE '%= NULL%' OR sm.definition LIKE '%<> NULL%'
        OR sm.definition LIKE '%sysobjects%' OR sm.definition LIKE '%syscolumns%' OR sm.definition LIKE '%sysindexes%'
        OR sm.definition LIKE '%SET ROWCOUNT%'
        OR sm.definition LIKE '%GOTO %'
        OR (sm.definition LIKE '%RAISERROR%' AND sm.definition NOT LIKE '%THROW%')
      )
ORDER BY SmellType, SchemaName, ObjectName;
