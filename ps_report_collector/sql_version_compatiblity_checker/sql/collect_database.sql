-- =====================================================================================
-- SQL Upgrade Advisor — per-database collectors
-- Run by : Get-AdvDatabaseData, in the context of each assessed user database
--
-- Each "-- section: <name>" block is executed on its own.
-- Collection sections must stay read-only (SELECT only).
-- =====================================================================================

-- section: db_query_store_state
-- actual_state is what is running. desired_state and readonly_reason explain OFF vs READ_ONLY vs ERROR.
SELECT TOP (1)
       actual_state_desc,
       desired_state_desc,
       readonly_reason
FROM sys.database_query_store_options

-- section: db_objects
-- definition is NULL for encrypted modules and for CLR objects (FS/FT/TA/AF have no T-SQL body).
SELECT o.object_id, o.parent_object_id, SCHEMA_NAME(o.schema_id) AS schema_name, o.name, o.type, o.type_desc,
       o.create_date, o.modify_date, m.definition
FROM sys.objects o
LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('U','V','P','PC','FN','IF','TF','TR','X','D','R','SO','TT','SN','FS','FT','TA','AF')

-- section: db_ddl_triggers
SELECT t.object_id, SCHEMA_NAME(t.schema_id) AS schema_name, t.name, 'TR' AS type,
       'SQL_DDL_TRIGGER' AS type_desc, t.create_date, t.modify_date, m.definition
FROM sys.triggers t
LEFT JOIN sys.sql_modules m ON m.object_id = t.object_id
WHERE t.parent_id = 0 AND t.is_ms_shipped = 0

-- section: db_clr_modules
SELECT am.object_id, SCHEMA_NAME(o.schema_id) AS schema_name, o.name, o.type, o.type_desc,
       o.create_date, o.modify_date,
       a.name AS assembly_name, am.assembly_class AS assembly_class, a.permission_set_desc AS permission_set
FROM sys.assembly_modules am
JOIN sys.objects o ON o.object_id = am.object_id
JOIN sys.assemblies a ON a.assembly_id = am.assembly_id
WHERE o.is_ms_shipped = 0

-- section: db_columns
-- data_type is the user/alias type name. system_data_type is the underlying built-in type,
-- so a UDT named MyNotes that aliases text is still visible to the LOB deprecation rule.
SELECT t.object_id, SCHEMA_NAME(t.schema_id) AS schema_name, t.name AS table_name,
       c.column_id, c.name AS column_name,
       ty.name AS data_type,
       sty.name AS system_data_type,
       c.max_length, c.precision, c.scale,
       c.is_nullable, c.is_computed, c.is_identity, c.is_rowguidcol, c.is_sparse,
       cc.definition AS computed_definition
FROM sys.tables t
JOIN sys.columns c ON c.object_id = t.object_id
JOIN sys.types ty ON ty.user_type_id = c.user_type_id
JOIN sys.types sty ON sty.user_type_id = c.system_type_id
LEFT JOIN sys.computed_columns cc ON cc.object_id = c.object_id AND cc.column_id = c.column_id
WHERE t.is_ms_shipped = 0
ORDER BY t.object_id, c.column_id

-- section: db_indexes
-- type_desc values are CLUSTERED COLUMNSTORE and NONCLUSTERED COLUMNSTORE.
-- COLUMNSTORE_ARCHIVE is a partition compression, not an index type.
SELECT OBJECT_SCHEMA_NAME(i.object_id) AS schema_name, OBJECT_NAME(i.object_id) AS table_name,
       i.name AS index_name, i.type_desc, i.is_disabled, i.has_filter, i.filter_definition
FROM sys.indexes i
WHERE i.object_id > 0 AND i.type > 0
  AND (
        i.has_filter = 1 OR i.is_disabled = 1
        OR i.type_desc IN (N'XML', N'SPATIAL', N'CLUSTERED COLUMNSTORE', N'NONCLUSTERED COLUMNSTORE')
        OR EXISTS (
            SELECT 1
            FROM sys.partitions p
            WHERE p.object_id = i.object_id
              AND p.index_id = i.index_id
              AND p.data_compression_desc = N'COLUMNSTORE_ARCHIVE'
        )
      )

-- section: db_synonyms
SELECT SCHEMA_NAME(schema_id) AS schema_name, name, base_object_name
FROM sys.synonyms

-- section: db_assemblies
SELECT assembly_id, name, permission_set_desc, is_loaded, is_visible, is_signed
FROM sys.assemblies
WHERE is_user_defined = 1

-- section: db_crypto
SELECT N'CERTIFICATE' AS kind, name, expiry_date
FROM sys.certificates
UNION ALL
SELECT N'ASYMMETRIC KEY', name, CAST(NULL AS datetime) AS expiry_date
FROM sys.asymmetric_keys

-- section: db_external_sources
SELECT name, type_desc, location
FROM sys.external_data_sources

-- section: db_external_tables
SELECT SCHEMA_NAME(et.schema_id) AS schema_name, et.name AS table_name,
       ds.name AS data_source_name, ds.type_desc AS data_source_type, ds.location AS data_source_location
FROM sys.external_tables et
JOIN sys.external_data_sources ds ON ds.data_source_id = et.data_source_id

-- section: db_fulltext
SELECT OBJECT_SCHEMA_NAME(fi.object_id) AS schema_name,
       OBJECT_NAME(fi.object_id) AS table_name,
       fc.name AS catalog_name,
       fi.change_tracking_state_desc
FROM sys.fulltext_indexes AS fi
LEFT JOIN sys.fulltext_catalogs AS fc ON fc.fulltext_catalog_id = fi.fulltext_catalog_id
WHERE fi.object_id > 0

-- section: db_dependencies
-- referencing_schema_name / referencing_entity_name are not columns of
-- sys.sql_expression_dependencies; they are resolved from referencing_id.
-- Column-level rows (referenced_minor_id <> 0) are excluded so fan-in stays at object grain.
SELECT rs.name AS referencing_schema_name,
       ro.name AS referencing_entity_name,
       d.referenced_schema_name,
       d.referenced_entity_name,
       d.referenced_database_name,
       d.referenced_server_name,
       d.referencing_id,
       d.referenced_id,
       d.is_caller_dependent
FROM sys.sql_expression_dependencies AS d
INNER JOIN sys.objects AS ro ON ro.object_id = d.referencing_id
INNER JOIN sys.schemas AS rs ON rs.schema_id = ro.schema_id
WHERE ro.is_ms_shipped = 0
  AND d.referenced_minor_id = 0

-- section: db_procedure_stats
-- Plan cache only. A missing row means the procedure is not cached, not that it is unused.
SELECT object_id, SUM(CAST(execution_count AS bigint)) AS exec_count,
       SUM(CAST(total_logical_reads AS bigint)) AS total_reads,
       SUM(CAST(total_worker_time AS bigint)) AS total_cpu
FROM sys.dm_exec_procedure_stats
WHERE database_id = DB_ID()
GROUP BY object_id

-- section: db_trigger_stats
SELECT object_id, SUM(CAST(execution_count AS bigint)) AS exec_count,
       SUM(CAST(total_logical_reads AS bigint)) AS total_reads,
       SUM(CAST(total_worker_time AS bigint)) AS total_cpu
FROM sys.dm_exec_trigger_stats
WHERE database_id = DB_ID()
GROUP BY object_id

-- section: db_objects_hash
-- Same inventory as db_objects, without module text. Used when -DefinitionsMode HashOnly
-- so large estates are not copied into the report. has_definition = 0 means encrypted or missing.
SELECT o.object_id, o.parent_object_id, SCHEMA_NAME(o.schema_id) AS schema_name, o.name, o.type, o.type_desc,
       o.create_date, o.modify_date,
       CASE WHEN m.definition IS NULL THEN 0 ELSE 1 END AS has_definition,
       CAST(NULL AS nvarchar(max)) AS definition
FROM sys.objects o
LEFT JOIN sys.sql_modules m ON m.object_id = o.object_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('U','V','P','PC','FN','IF','TF','TR','X','D','R','SO','TT','SN','FS','FT','TA','AF')

-- section: db_sku_features
-- Edition-sensitive features that can block a restore onto a lower edition or a different SKU.
SELECT feature_name, feature_id
FROM sys.dm_db_persisted_sku_features

-- section: db_feature_surface
-- One row: CDC, change tracking, In-Memory OLTP, FileTable, FILESTREAM, Service Broker,
-- partitioning, XML schemas, database master key, and Always Encrypted keys.
SELECT
    CAST(d.is_cdc_enabled AS int) AS is_cdc_enabled,
    CAST(d.is_broker_enabled AS int) AS is_broker_enabled,
    (SELECT COUNT(*) FROM sys.tables AS t WHERE t.is_memory_optimized = 1 AND t.is_ms_shipped = 0) AS memory_optimized_tables,
    (SELECT COUNT(*) FROM sys.tables AS t WHERE t.is_filetable = 1 AND t.is_ms_shipped = 0) AS filetables,
    (SELECT COUNT(*) FROM sys.tables AS t WHERE t.is_tracked_by_cdc = 1) AS cdc_tables,
    (SELECT COUNT(*) FROM sys.change_tracking_tables) AS change_tracking_tables,
    (SELECT COUNT(*) FROM sys.service_queues AS q WHERE q.is_ms_shipped = 0) AS broker_queues,
    (SELECT COUNT(*) FROM sys.filegroups AS fg WHERE fg.type = 'FX') AS filestream_filegroups,
    (SELECT COUNT(*) FROM sys.partition_functions) AS partition_functions,
    (SELECT COUNT(*) FROM sys.xml_schema_collections AS x WHERE x.xml_collection_id > 1) AS xml_schema_collections,
    CASE WHEN EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##') THEN 1 ELSE 0 END AS has_database_master_key,
    (SELECT COUNT(*) FROM sys.symmetric_keys WHERE name NOT LIKE N'##MS[_]%') AS user_symmetric_keys,
    (SELECT COUNT(*) FROM sys.column_master_keys) AS column_master_keys,
    (SELECT COUNT(*) FROM sys.column_encryption_keys) AS column_encryption_keys
FROM sys.databases AS d
WHERE d.database_id = DB_ID()

-- section: db_query_store_baseline
-- Counts only. Plan XML is not collected. Forced plans must be re-validated after a compatibility change.
SELECT
    (SELECT COUNT(*) FROM sys.query_store_query) AS query_count,
    (SELECT COUNT(*) FROM sys.query_store_plan WHERE is_forced_plan = 1) AS forced_plans
