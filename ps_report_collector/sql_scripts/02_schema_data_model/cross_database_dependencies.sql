/* SQL_Initial_Assessment */
SELECT DISTINCT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(d.referencing_id) AS ReferencingSchema,
    OBJECT_NAME(d.referencing_id) AS ReferencingObject,
    o.type_desc AS ReferencingType,
    d.referenced_server_name AS ReferencedServer,
    d.referenced_database_name AS ReferencedDatabase,
    d.referenced_schema_name AS ReferencedSchema,
    d.referenced_entity_name AS ReferencedEntity,
    CASE
        WHEN d.referenced_database_name IS NOT NULL
             AND d.referenced_database_name <> DB_NAME() THEN 'Cross-database'
        WHEN d.referenced_server_name IS NOT NULL THEN 'Linked/four-part'
        ELSE 'Other'
    END AS DependencyKind
FROM sys.sql_expression_dependencies d
LEFT JOIN sys.objects o ON d.referencing_id = o.object_id
WHERE (
        d.referenced_database_name IS NOT NULL
        AND d.referenced_database_name <> DB_NAME()
      )
   OR d.referenced_server_name IS NOT NULL
ORDER BY DependencyKind, ReferencingSchema, ReferencingObject;
