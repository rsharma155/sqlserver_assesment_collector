/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    o.type_desc AS ObjectType,
    OBJECT_SCHEMA_NAME(o.object_id) AS SchemaName,
    o.name AS ObjectName,
    o.create_date AS CreateDate,
    o.modify_date AS ModifyDate,
    CASE WHEN sm.definition IS NULL THEN NULL ELSE LEN(sm.definition) END AS DefinitionLength,
    CASE WHEN sm.definition IS NULL THEN NULL ELSE (LEN(sm.definition) - LEN(REPLACE(sm.definition, CHAR(10), ''))) + 1 END AS ApproxLineCount,
    CASE
        WHEN o.type = 'P' AND sm.definition IS NOT NULL AND sm.definition NOT LIKE '%SET NOCOUNT ON%' THEN 1
        ELSE 0
    END AS MissingSetNocount,
    CASE
        WHEN sm.definition IS NOT NULL AND (
            sm.definition LIKE '%CURSOR %' OR sm.definition LIKE '%DECLARE % CURSOR%'
        ) THEN 1 ELSE 0
    END AS UsesCursor,
    CASE
        WHEN sm.definition IS NOT NULL AND (
            sm.definition LIKE '%EXEC(%' OR sm.definition LIKE '%EXECUTE(%'
            OR sm.definition LIKE '%sp_executesql%'
        ) THEN 1 ELSE 0
    END AS UsesDynamicSql,
    CASE
        WHEN sm.definition IS NOT NULL AND sm.definition LIKE '%SELECT *%' THEN 1
        ELSE 0
    END AS UsesSelectStar,
    CASE
        WHEN sm.definition IS NOT NULL AND (
            sm.definition LIKE '%WITH (NOLOCK)%' OR sm.definition LIKE '%WITH(NOLOCK)%'
        ) THEN 1 ELSE 0
    END AS UsesNolock,
    CASE
        WHEN sm.definition IS NOT NULL AND sm.definition LIKE '%BEGIN TRAN%' THEN 1
        ELSE 0
    END AS UsesExplicitTransaction,
    CASE
        WHEN sm.definition IS NOT NULL AND sm.definition LIKE '%TRY%' AND sm.definition LIKE '%CATCH%' THEN 1
        ELSE 0
    END AS HasTryCatch,
    CASE WHEN sm.is_schema_bound = 1 THEN 1 ELSE 0 END AS IsSchemaBound,
    ISNULL((
        SELECT COUNT(*) FROM sys.parameters p WHERE p.object_id = o.object_id AND p.parameter_id > 0
    ), 0) AS ParameterCount
FROM sys.objects o
LEFT JOIN sys.sql_modules sm ON o.object_id = sm.object_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('P', 'FN', 'IF', 'TF', 'V', 'TR')
ORDER BY
    CASE o.type WHEN 'P' THEN 1 WHEN 'FN' THEN 2 WHEN 'TF' THEN 3 WHEN 'IF' THEN 4 WHEN 'V' THEN 5 ELSE 6 END,
    ApproxLineCount DESC,
    SchemaName, ObjectName;
