/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(o.object_id) AS SchemaName,
    o.name AS FunctionName,
    o.type_desc AS FunctionType,
    o.create_date AS CreateDate,
    o.modify_date AS ModifyDate,
    CASE WHEN sm.is_schema_bound = 1 THEN 1 ELSE 0 END AS IsSchemaBound,
    CASE WHEN sm.uses_ansi_nulls = 1 THEN 1 ELSE 0 END AS UsesAnsiNulls,
    CASE WHEN sm.uses_quoted_identifier = 1 THEN 1 ELSE 0 END AS UsesQuotedIdentifier,
    CASE
        WHEN o.type = 'FN' THEN 'Scalar UDF - high performance risk'
        WHEN o.type = 'TF' THEN 'Multi-statement TVF - cardinality risk'
        WHEN o.type = 'IF' THEN 'Inline TVF - preferred pattern'
        ELSE o.type_desc
    END AS RiskNote,
    LEFT(sm.definition, 500) AS DefinitionPreview
FROM sys.objects o
INNER JOIN sys.sql_modules sm ON o.object_id = sm.object_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('FN', 'IF', 'TF')
ORDER BY
    CASE o.type WHEN 'FN' THEN 1 WHEN 'TF' THEN 2 ELSE 3 END,
    SchemaName, FunctionName;
