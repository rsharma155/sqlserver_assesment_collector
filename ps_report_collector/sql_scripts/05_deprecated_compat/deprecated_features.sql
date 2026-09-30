/* SQL_Initial_Assessment */
/*
  Detects deprecated / removed SQL Server features (2012-2022 reference).
  Output includes why the item is flagged and the recommended remediation.
*/
;WITH code_hits AS (
    SELECT
        o.object_id,
        OBJECT_SCHEMA_NAME(o.object_id) AS SchemaName,
        o.name AS ObjectName,
        o.type_desc AS ObjectType,
        sm.definition AS DefinitionText
    FROM sys.objects o
    INNER JOIN sys.sql_modules sm ON o.object_id = sm.object_id
    WHERE o.is_ms_shipped = 0
),
flagged_code AS (
    SELECT
        SchemaName,
        ObjectName,
        ObjectType,
        Feature,
        Severity,
        Category,
        WhyFlagged,
        RecommendedAction,
        VersionNote
    FROM code_hits
    CROSS APPLY (VALUES
        (
            CASE WHEN DefinitionText LIKE '%SET ROWCOUNT%' THEN 'SET ROWCOUNT' END,
            'CRITICAL',
            'Removed T-SQL',
            'SET ROWCOUNT for limiting rows is removed/unsupported for INSERT/UPDATE/DELETE paths and should not be used in modern code.',
            'Replace with TOP (...), OFFSET/FETCH, or set-based filters.',
            'Removed SQL Server 2012+'
        ),
        (
            CASE WHEN DefinitionText LIKE '%@@REMSERVER%' THEN '@@REMSERVER' END,
            'CRITICAL',
            'Removed T-SQL',
            '@@REMSERVER was removed; remote-server identity is no longer available this way.',
            'Use linked servers (sys.servers) and modern remote access patterns.',
            'Removed SQL Server 2012'
        ),
        (
            CASE WHEN DefinitionText LIKE '%DATABASEPROPERTY(%' AND DefinitionText NOT LIKE '%DATABASEPROPERTYEX(%' THEN 'DATABASEPROPERTY()' END,
            'CRITICAL',
            'Removed T-SQL',
            'DATABASEPROPERTY() was removed.',
            'Replace with DATABASEPROPERTYEX().',
            'Removed SQL Server 2012'
        ),
        (
            CASE WHEN DefinitionText LIKE '%sp_dboption%' THEN 'sp_dboption' END,
            'CRITICAL',
            'Removed Procedure',
            'sp_dboption was removed; database options must be set with ALTER DATABASE.',
            'Rewrite to ALTER DATABASE ... SET <option>.',
            'Removed SQL Server 2016'
        ),
        (
            CASE WHEN DefinitionText LIKE '%fn_virtualservernodes%' THEN 'fn_virtualservernodes' END,
            'HIGH',
            'Removed Function',
            'fn_virtualservernodes was removed.',
            'Use sys.dm_os_cluster_nodes.',
            'Removed SQL Server 2016'
        ),
        (
            CASE WHEN DefinitionText LIKE '%fn_servershareddrives%' THEN 'fn_servershareddrives' END,
            'HIGH',
            'Removed Function',
            'fn_servershareddrives was removed.',
            'Use sys.dm_io_cluster_shared_drives.',
            'Removed SQL Server 2016'
        ),
        (
            CASE WHEN DefinitionText LIKE '%sp_addalias%' OR DefinitionText LIKE '%sp_dropalias%' THEN 'sp_addalias / sp_dropalias' END,
            'CRITICAL',
            'Removed Procedure',
            'Alias procedures were removed.',
            'Use database roles and proper user mappings instead of aliases.',
            'Removed SQL Server 2012'
        ),
        (
            CASE WHEN DefinitionText LIKE '%sp_grantdbaccess%' OR DefinitionText LIKE '%sp_revokedbaccess%'
                      OR DefinitionText LIKE '%sp_adduser%' OR DefinitionText LIKE '%sp_dropuser%'
                 THEN 'Legacy user procedures (sp_adduser/sp_dropuser/sp_grantdbaccess)' END,
            'CRITICAL',
            'Removed Procedure',
            'Legacy database-user procedures were removed.',
            'Use CREATE USER / DROP USER.',
            'Removed SQL Server 2012'
        ),
        (
            CASE WHEN DefinitionText LIKE '%sp_changedbowner%' THEN 'sp_changedbowner' END,
            'CRITICAL',
            'Removed Procedure',
            'sp_changedbowner was removed.',
            'Use ALTER AUTHORIZATION ON DATABASE::[db] TO [principal].',
            'Removed SQL Server 2012'
        ),
        (
            CASE WHEN DefinitionText LIKE '%sp_addlogin%' OR DefinitionText LIKE '%sp_droplogin%' THEN 'sp_addlogin / sp_droplogin' END,
            'HIGH',
            'Deprecated Procedure',
            'Login management via sp_addlogin/sp_droplogin is deprecated.',
            'Use CREATE LOGIN / DROP LOGIN.',
            'Deprecated'
        ),
        (
            CASE WHEN DefinitionText LIKE '%sp_addrole%' OR DefinitionText LIKE '%sp_droprole%'
                      OR DefinitionText LIKE '%sp_addrolemember%' OR DefinitionText LIKE '%sp_droprolemember%'
                 THEN 'Legacy role procedures' END,
            'HIGH',
            'Deprecated Procedure',
            'Role membership helpers are deprecated.',
            'Use CREATE ROLE / DROP ROLE / ALTER ROLE ... ADD|DROP MEMBER.',
            'Deprecated'
        ),
        (
            CASE WHEN DefinitionText LIKE '%sp_addserver%' THEN 'sp_addserver' END,
            'HIGH',
            'Deprecated Procedure',
            'sp_addserver is deprecated for registering remote/local servers.',
            'Use sp_addlinkedserver / linked-server management.',
            'Deprecated SQL Server 2012+'
        ),
        (
            CASE WHEN DefinitionText LIKE '%*=%' OR DefinitionText LIKE '%=*%' THEN 'Old-style outer join (*= / =*)' END,
            'HIGH',
            'Deprecated Syntax',
            'Old-style outer-join operators are deprecated and rejected under modern compatibility settings.',
            'Rewrite as LEFT/RIGHT OUTER JOIN ... ON ...',
            'Deprecated since SQL Server 2005'
        ),
        (
            CASE WHEN DefinitionText LIKE '%sysobjects%' OR DefinitionText LIKE '%syscolumns%' OR DefinitionText LIKE '%sysindexes%'
                 THEN 'Legacy system tables (sysobjects/syscolumns/sysindexes)' END,
            'HIGH',
            'Deprecated Catalog',
            'Compatibility views/system tables are legacy and incomplete versus catalog views.',
            'Replace with sys.objects, sys.columns, sys.indexes (or related catalog views).',
            'Deprecated'
        ),
        (
            CASE WHEN DefinitionText LIKE '%sys.sql_dependencies%' THEN 'sys.sql_dependencies' END,
            'HIGH',
            'Removed Catalog',
            'sys.sql_dependencies was removed.',
            'Use sys.sql_expression_dependencies / sys.dm_sql_referenced_entities.',
            'Removed SQL Server 2012'
        ),
        (
            CASE WHEN DefinitionText LIKE '%TEXTPTR(%' OR DefinitionText LIKE '%TEXTVALID(%'
                      OR DefinitionText LIKE '%UPDATETEXT%' OR DefinitionText LIKE '%WRITETEXT%'
                      OR DefinitionText LIKE '%READTEXT%'
                 THEN 'TEXT/IMAGE LOB functions (TEXTPTR/READTEXT/WRITETEXT/UPDATETEXT)' END,
            'HIGH',
            'Deprecated LOB API',
            'TEXT/IMAGE manipulation functions are deprecated with the old LOB types.',
            'Migrate columns to VARCHAR/NVARCHAR/VARBINARY(MAX) and use .WRITE() / standard DML.',
            'Deprecated; removed pathways in modern engines'
        ),
        (
            CASE WHEN DefinitionText LIKE '%SET ANSI_DEFAULTS%OFF%' OR DefinitionText LIKE '%SET ANSI_DEFAULTS OFF%'
                 THEN 'SET ANSI_DEFAULTS OFF' END,
            'MEDIUM',
            'Deprecated Setting',
            'SET ANSI_DEFAULTS OFF is deprecated.',
            'Set required ANSI options individually (ANSI_NULLS, ANSI_PADDING, etc.).',
            'Deprecated SQL Server 2012+'
        ),
        (
            CASE WHEN DefinitionText LIKE '%SET CONTEXT_INFO%' THEN 'SET CONTEXT_INFO' END,
            'MEDIUM',
            'Deprecated Session API',
            'SET CONTEXT_INFO is superseded by SESSION_CONTEXT.',
            'Use sp_set_session_context / SESSION_CONTEXT().',
            'Prefer SESSION_CONTEXT (SQL Server 2016+)'
        ),
        (
            CASE WHEN DefinitionText LIKE '%RAISERROR%' AND DefinitionText NOT LIKE '%THROW%' THEN 'RAISERROR without THROW' END,
            'MEDIUM',
            'Deprecated Pattern',
            'Older RAISERROR-only error handling is discouraged for new development.',
            'Prefer THROW (and TRY/CATCH) for modern error handling.',
            'THROW available SQL Server 2012+'
        ),
        (
            CASE WHEN DefinitionText LIKE '%HASHBYTES%MD2%' OR DefinitionText LIKE '%HASHBYTES%''MD2''%'
                      OR DefinitionText LIKE '%HASHBYTES%MD4%' OR DefinitionText LIKE '%HASHBYTES%''MD4''%'
                      OR DefinitionText LIKE '%HASHBYTES%MD5%' OR DefinitionText LIKE '%HASHBYTES%''MD5''%'
                      OR DefinitionText LIKE '%HASHBYTES%SHA1%' OR DefinitionText LIKE '%HASHBYTES%''SHA1''%'
                      OR DefinitionText LIKE '%HASHBYTES(''SHA''%'
                 THEN 'Weak HASHBYTES algorithm (MD2/MD4/MD5/SHA/SHA1)' END,
            'HIGH',
            'Deprecated Crypto',
            'Weak hash algorithms are deprecated for cryptographic use.',
            'Use HASHBYTES with SHA2_256 or SHA2_512.',
            'Deprecated SQL Server 2014+'
        ),
        (
            CASE WHEN DefinitionText LIKE '%::node()%' OR DefinitionText LIKE '%::text()%' THEN 'Deprecated XQuery ::node()/::text()' END,
            'MEDIUM',
            'Deprecated XQuery',
            'Older XQuery axis helpers are deprecated.',
            'Use ::nodes() and modern XQuery text() patterns.',
            'Deprecated SQL Server 2016+'
        ),
        (
            CASE WHEN DefinitionText LIKE '%SET FMTONLY%ON%' OR DefinitionText LIKE '%SET FMTONLY ON%' THEN 'SET FMTONLY ON' END,
            'MEDIUM',
            'Deprecated Setting',
            'SET FMTONLY ON is deprecated for metadata discovery.',
            'Use sp_describe_first_result_set / modern client metadata APIs.',
            'Deprecated SQL Server 2012+'
        ),
        (
            CASE WHEN DefinitionText LIKE '%sp_attach_db%' OR DefinitionText LIKE '%sp_attach_single_file_db%'
                 THEN 'sp_attach_db / sp_attach_single_file_db' END,
            'MEDIUM',
            'Deprecated Procedure',
            'Attach helpers are deprecated.',
            'Use CREATE DATABASE ... FOR ATTACH / FOR ATTACH_REBUILD_LOG.',
            'Deprecated SQL Server 2017+'
        ),
        (
            CASE WHEN DefinitionText LIKE '%OPTION%FASTFIRSTROW%' OR DefinitionText LIKE '%FASTFIRSTROW%'
                 THEN 'FASTFIRSTROW hint' END,
            'LOW',
            'Deprecated Hint',
            'FASTFIRSTROW query hint is deprecated.',
            'Use OPTION (FAST n) instead.',
            'Deprecated'
        ),
        (
            CASE WHEN DefinitionText LIKE '%BACKUP%PASSWORD%' OR DefinitionText LIKE '%RESTORE%PASSWORD%'
                 THEN 'BACKUP/RESTORE WITH PASSWORD' END,
            'HIGH',
            'Deprecated Backup Option',
            'BACKUP/RESTORE WITH PASSWORD is deprecated and should not be used.',
            'Remove password option; protect backups with OS/storage encryption and access controls.',
            'Deprecated SQL Server 2012+'
        )
    ) AS v(Feature, Severity, Category, WhyFlagged, RecommendedAction, VersionNote)
    WHERE Feature IS NOT NULL
),
data_types AS (
    SELECT
        OBJECT_SCHEMA_NAME(c.object_id) AS SchemaName,
        OBJECT_NAME(c.object_id) AS ObjectName,
        CAST('USER_TABLE' AS nvarchar(60)) AS ObjectType,
        CASE ty.name
            WHEN 'text' THEN 'TEXT data type'
            WHEN 'ntext' THEN 'NTEXT data type'
            WHEN 'image' THEN 'IMAGE data type'
            WHEN 'timestamp' THEN 'TIMESTAMP data type (use ROWVERSION)'
            WHEN 'sql_variant' THEN 'SQL_VARIANT data type'
            WHEN 'money' THEN 'MONEY data type'
            WHEN 'smallmoney' THEN 'SMALLMONEY data type'
        END AS Feature,
        CASE
            WHEN ty.name IN ('text', 'ntext', 'image') THEN 'CRITICAL'
            WHEN ty.name = 'timestamp' THEN 'HIGH'
            ELSE 'MEDIUM'
        END AS Severity,
        CAST('Deprecated Data Type' AS nvarchar(40)) AS Category,
        CASE ty.name
            WHEN 'text' THEN 'TEXT is a legacy LOB type that blocks many modern engine features and maintenance patterns.'
            WHEN 'ntext' THEN 'NTEXT is a legacy Unicode LOB type and should not be used in new or upgraded designs.'
            WHEN 'image' THEN 'IMAGE is a legacy binary LOB type.'
            WHEN 'timestamp' THEN 'TIMESTAMP is a synonym for rowversion and is a misleading/legacy type name.'
            WHEN 'sql_variant' THEN 'SQL_VARIANT complicates typing, indexing, and cross-version migrations.'
            WHEN 'money' THEN 'MONEY has well-known rounding/precision issues for financial systems.'
            WHEN 'smallmoney' THEN 'SMALLMONEY has limited range/precision for financial systems.'
        END AS WhyFlagged,
        CASE ty.name
            WHEN 'text' THEN 'Convert to VARCHAR(MAX); rewrite TEXTPTR/READTEXT/WRITETEXT/UPDATETEXT usage.'
            WHEN 'ntext' THEN 'Convert to NVARCHAR(MAX); rewrite legacy LOB APIs.'
            WHEN 'image' THEN 'Convert to VARBINARY(MAX); rewrite legacy LOB APIs.'
            WHEN 'timestamp' THEN 'Rename/migrate to ROWVERSION intentionally; avoid assuming datetime semantics.'
            WHEN 'sql_variant' THEN 'Replace with explicit typed columns or a normalized design.'
            WHEN 'money' THEN 'Replace with DECIMAL(p,s) matching business precision rules.'
            WHEN 'smallmoney' THEN 'Replace with DECIMAL(p,s) matching business precision rules.'
        END AS RecommendedAction,
        CASE
            WHEN ty.name IN ('text', 'ntext', 'image', 'timestamp') THEN 'Deprecated since SQL Server 2005'
            ELSE 'Assessment risk type (modernization)'
        END AS VersionNote,
        c.name AS Evidence
    FROM sys.columns c
    INNER JOIN sys.tables t ON c.object_id = t.object_id
    INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
    WHERE t.is_ms_shipped = 0
      AND ty.name IN ('text', 'ntext', 'image', 'timestamp', 'sql_variant', 'money', 'smallmoney')
),
mirroring AS (
    SELECT
        CAST(NULL AS sysname) AS SchemaName,
        DB_NAME() AS ObjectName,
        CAST('DATABASE' AS nvarchar(60)) AS ObjectType,
        CAST('Database Mirroring' AS nvarchar(200)) AS Feature,
        CAST('HIGH' AS nvarchar(20)) AS Severity,
        CAST('Deprecated HA Feature' AS nvarchar(40)) AS Category,
        CAST('Database Mirroring is deprecated; new HA designs should not rely on it.' AS nvarchar(400)) AS WhyFlagged,
        CAST('Plan migration to Always On Availability Groups (or another supported HA/DR pattern).' AS nvarchar(400)) AS RecommendedAction,
        CAST('Deprecated; prefer Always On' AS nvarchar(80)) AS VersionNote,
        CAST(mirroring_state_desc AS nvarchar(200)) AS Evidence
    FROM sys.database_mirroring
    WHERE database_id = DB_ID()
      AND mirroring_guid IS NOT NULL
),
compat AS (
    SELECT
        CAST(NULL AS sysname) AS SchemaName,
        DB_NAME() AS ObjectName,
        CAST('DATABASE' AS nvarchar(60)) AS ObjectType,
        CAST('Low compatibility_level' AS nvarchar(200)) AS Feature,
        CAST(CASE WHEN d.compatibility_level < 100 THEN 'HIGH' ELSE 'MEDIUM' END AS nvarchar(20)) AS Severity,
        CAST('Compatibility' AS nvarchar(40)) AS Category,
        CAST('Compatibility level is below the modern baseline expected for current SQL Server engines, limiting optimizer/IQP behavior.' AS nvarchar(400)) AS WhyFlagged,
        CAST('Raise compatibility_level in a staged plan with Query Store baselining and regression testing.' AS nvarchar(400)) AS RecommendedAction,
        CAST('Target current engine max (e.g. 140/150/160)' AS nvarchar(80)) AS VersionNote,
        CAST(('compatibility_level=' + CAST(d.compatibility_level AS varchar(10))) AS nvarchar(200)) AS Evidence
    FROM sys.databases d
    WHERE d.database_id = DB_ID()
      AND d.compatibility_level < 130
),
combined AS (
    SELECT
        SchemaName, ObjectName, ObjectType, Feature, Severity, Category, WhyFlagged, RecommendedAction, VersionNote,
        CAST(ObjectType AS nvarchar(200)) AS Evidence
    FROM flagged_code
    UNION ALL
    SELECT SchemaName, ObjectName, ObjectType, Feature, Severity, Category, WhyFlagged, RecommendedAction, VersionNote, Evidence
    FROM data_types
    UNION ALL
    SELECT SchemaName, ObjectName, ObjectType, Feature, Severity, Category, WhyFlagged, RecommendedAction, VersionNote, Evidence
    FROM mirroring
    UNION ALL
    SELECT SchemaName, ObjectName, ObjectType, Feature, Severity, Category, WhyFlagged, RecommendedAction, VersionNote, Evidence
    FROM compat
)
SELECT
    CAST(DB_NAME() AS nvarchar(128)) COLLATE DATABASE_DEFAULT AS DatabaseName,
    CAST(Severity AS nvarchar(20)) COLLATE DATABASE_DEFAULT AS Severity,
    CAST(Category AS nvarchar(40)) COLLATE DATABASE_DEFAULT AS Category,
    CAST(Feature AS nvarchar(200)) COLLATE DATABASE_DEFAULT AS DeprecatedFeature,
    CAST(SchemaName AS nvarchar(128)) COLLATE DATABASE_DEFAULT AS SchemaName,
    CAST(ObjectName AS nvarchar(256)) COLLATE DATABASE_DEFAULT AS ObjectName,
    CAST(ObjectType AS nvarchar(60)) COLLATE DATABASE_DEFAULT AS ObjectType,
    CAST(WhyFlagged AS nvarchar(400)) COLLATE DATABASE_DEFAULT AS WhyFlagged,
    CAST(RecommendedAction AS nvarchar(400)) COLLATE DATABASE_DEFAULT AS RecommendedAction,
    CAST(VersionNote AS nvarchar(80)) COLLATE DATABASE_DEFAULT AS VersionNote,
    CAST(Evidence AS nvarchar(200)) COLLATE DATABASE_DEFAULT AS Evidence
FROM combined
ORDER BY
    CASE Severity WHEN 'CRITICAL' THEN 1 WHEN 'HIGH' THEN 2 WHEN 'MEDIUM' THEN 3 WHEN 'LOW' THEN 4 ELSE 5 END,
    Category, DeprecatedFeature, SchemaName, ObjectName;
