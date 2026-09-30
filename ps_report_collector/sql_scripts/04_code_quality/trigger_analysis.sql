/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(t.parent_id) AS SchemaName,
    OBJECT_NAME(t.parent_id) AS TableName,
    t.name AS TriggerName,
    CASE WHEN t.is_instead_of_trigger = 1 THEN 'INSTEAD OF' ELSE 'AFTER' END AS TriggerTiming,
    CASE WHEN OBJECTPROPERTY(t.object_id, 'ExecIsInsertTrigger') = 1 THEN 1 ELSE 0 END AS IsInsert,
    CASE WHEN OBJECTPROPERTY(t.object_id, 'ExecIsUpdateTrigger') = 1 THEN 1 ELSE 0 END AS IsUpdate,
    CASE WHEN OBJECTPROPERTY(t.object_id, 'ExecIsDeleteTrigger') = 1 THEN 1 ELSE 0 END AS IsDelete,
    t.is_disabled AS IsDisabled,
    t.create_date AS CreateDate,
    t.modify_date AS ModifyDate,
    CASE WHEN sm.definition IS NOT NULL AND sm.definition NOT LIKE '%SET NOCOUNT ON%' THEN 1 ELSE 0 END AS MissingSetNocount,
    CASE WHEN sm.definition IS NOT NULL AND (
        sm.definition LIKE '%CURSOR %' OR sm.definition LIKE '%WHILE %'
    ) THEN 1 ELSE 0 END AS RowByRowPattern,
    LEN(sm.definition) AS DefinitionLength
FROM sys.triggers t
INNER JOIN sys.tables tbl ON t.parent_id = tbl.object_id
LEFT JOIN sys.sql_modules sm ON t.object_id = sm.object_id
WHERE t.parent_class = 1
  AND tbl.is_ms_shipped = 0
ORDER BY SchemaName, TableName, TriggerName;
