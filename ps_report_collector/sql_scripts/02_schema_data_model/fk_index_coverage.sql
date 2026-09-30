/* SQL_Initial_Assessment */
/*
  FK index coverage — every FK should typically have a supporting index
  to reduce locks/deadlocks on joins and cascading actions.
*/
;WITH fk_cols AS (
    SELECT
        fk.object_id AS FkObjectId,
        fk.name AS ForeignKeyName,
        fk.parent_object_id,
        fk.referenced_object_id,
        fk.delete_referential_action_desc AS DeleteAction,
        fk.update_referential_action_desc AS UpdateAction,
        fk.is_disabled,
        fk.is_not_trusted,
        fkc.constraint_column_id,
        fkc.parent_column_id,
        COL_NAME(fkc.parent_object_id, fkc.parent_column_id) AS ParentColumn,
        COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id) AS ReferencedColumn
    FROM sys.foreign_keys fk
    INNER JOIN sys.foreign_key_columns fkc ON fk.object_id = fkc.constraint_object_id
),
fk_key AS (
    SELECT
        FkObjectId,
        ForeignKeyName,
        parent_object_id,
        referenced_object_id,
        DeleteAction,
        UpdateAction,
        is_disabled,
        is_not_trusted,
        STUFF((
            SELECT ', ' + ParentColumn
            FROM fk_cols x
            WHERE x.FkObjectId = f.FkObjectId
            ORDER BY constraint_column_id
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 2, '') AS FkColumns,
        STUFF((
            SELECT ',' + CAST(parent_column_id AS varchar(12))
            FROM fk_cols x
            WHERE x.FkObjectId = f.FkObjectId
            ORDER BY constraint_column_id
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 1, '') AS FkColumnIdList
    FROM fk_cols f
    GROUP BY
        FkObjectId, ForeignKeyName, parent_object_id, referenced_object_id,
        DeleteAction, UpdateAction, is_disabled, is_not_trusted
),
index_keys AS (
    SELECT
        i.object_id,
        i.index_id,
        i.name AS IndexName,
        STUFF((
            SELECT ',' + CAST(ic.column_id AS varchar(12))
            FROM sys.index_columns ic
            WHERE ic.object_id = i.object_id
              AND ic.index_id = i.index_id
              AND ic.is_included_column = 0
            ORDER BY ic.key_ordinal
            FOR XML PATH(''), TYPE
        ).value('.', 'nvarchar(max)'), 1, 1, '') AS IndexKeyColumnIdList
    FROM sys.indexes i
    WHERE i.is_hypothetical = 0
      AND i.is_disabled = 0
      AND i.index_id > 0
)
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(fk.parent_object_id) AS SchemaName,
    OBJECT_NAME(fk.parent_object_id) AS TableName,
    fk.ForeignKeyName,
    fk.FkColumns,
    OBJECT_SCHEMA_NAME(fk.referenced_object_id) + '.' + OBJECT_NAME(fk.referenced_object_id) AS ReferencedTable,
    fk.DeleteAction,
    fk.UpdateAction,
    fk.is_disabled AS IsDisabled,
    fk.is_not_trusted AS IsNotTrusted,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM index_keys ik
            WHERE ik.object_id = fk.parent_object_id
              AND (
                    ik.IndexKeyColumnIdList = fk.FkColumnIdList
                    OR ik.IndexKeyColumnIdList LIKE fk.FkColumnIdList + ',%'
                  )
        ) THEN 1 ELSE 0
    END AS HasSupportingIndex,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM index_keys ik
            WHERE ik.object_id = fk.parent_object_id
              AND (
                    ik.IndexKeyColumnIdList = fk.FkColumnIdList
                    OR ik.IndexKeyColumnIdList LIKE fk.FkColumnIdList + ',%'
                  )
        ) THEN 'OK'
        ELSE 'Missing FK index - add nonclustered index on FK columns'
    END AS Assessment,
    CASE
        WHEN fk.DeleteAction LIKE '%CASCADE%' OR fk.UpdateAction LIKE '%CASCADE%' THEN 1
        ELSE 0
    END AS HasCascadeAction
FROM fk_key fk
ORDER BY
    HasSupportingIndex ASC,
    HasCascadeAction DESC,
    SchemaName, TableName, ForeignKeyName;
