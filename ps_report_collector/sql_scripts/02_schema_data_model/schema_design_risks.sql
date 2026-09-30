/* SQL_Initial_Assessment */
/*
  Structural/design anomaly heuristics for scalability refactoring.
  Full normalization proof requires domain workshops; these are automated indicators.
*/
-- Tables without primary key
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(t.object_id) AS SchemaName,
    t.name AS TableName,
    'NoPrimaryKey' AS Issue,
    CAST('HIGH' AS nvarchar(20)) AS Severity,
    CAST(NULL AS sysname) AS RelatedObject,
    CAST('Table has no primary key — identity and relationship integrity are unclear.' AS nvarchar(400)) AS WhyFlagged,
    CAST('Add an explicit primary key (prefer ever-increasing BIGINT/INT surrogate where appropriate).' AS nvarchar(400)) AS RecommendedAction
FROM sys.tables t
WHERE t.is_ms_shipped = 0
  AND NOT EXISTS (
        SELECT 1 FROM sys.indexes i
        WHERE i.object_id = t.object_id AND i.is_primary_key = 1
      )

UNION ALL

-- Heaps
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(t.object_id) AS SchemaName,
    t.name AS TableName,
    'HeapTable' AS Issue,
    'HIGH',
    CAST(NULL AS sysname),
    'No clustered index (heap). Can cause forwarded records and unstable IO patterns.',
    'Create a clustered index on an ever-increasing key unless a deliberate heap design is documented.'
FROM sys.tables t
WHERE t.is_ms_shipped = 0
  AND t.is_memory_optimized = 0
  AND NOT EXISTS (
        SELECT 1 FROM sys.indexes i
        WHERE i.object_id = t.object_id AND i.type = 1
      )

UNION ALL

-- Heaps with nonclustered indexes
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(t.object_id) AS SchemaName,
    t.name AS TableName,
    'HeapWithNonclusteredIndexes' AS Issue,
    'HIGH',
    CAST(NULL AS sysname),
    'Heap has nonclustered indexes — forwarded-record / bookmark lookup costs are common.',
    'Convert to a clustered table or justify the heap design with measured workload evidence.'
FROM sys.tables t
WHERE t.is_ms_shipped = 0
  AND t.is_memory_optimized = 0
  AND NOT EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type = 1)
  AND EXISTS (SELECT 1 FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type = 2 AND i.is_hypothetical = 0)

UNION ALL

-- GUID in clustered PK
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(i.object_id) AS SchemaName,
    OBJECT_NAME(i.object_id) AS TableName,
    'GuidClusteredKey' AS Issue,
    'HIGH',
    i.name,
    'Clustered key includes uniqueidentifier (GUID), which often increases fragmentation and page splits.',
    'Prefer BIGINT/INT ever-increasing clustering keys; keep GUID as nonclustered alternate key if needed.'
FROM sys.indexes i
INNER JOIN sys.index_columns ic ON i.object_id = ic.object_id AND i.index_id = ic.index_id AND ic.is_included_column = 0
INNER JOIN sys.columns c ON ic.object_id = c.object_id AND ic.column_id = c.column_id
INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
INNER JOIN sys.tables t ON i.object_id = t.object_id
WHERE t.is_ms_shipped = 0
  AND i.type = 1
  AND ty.name = 'uniqueidentifier'

UNION ALL

-- Wide tables
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(t.object_id) AS SchemaName,
    t.name AS TableName,
    CASE WHEN COUNT(c.column_id) > 100 THEN 'VeryWideTable' ELSE 'WideTable' END AS Issue,
    CASE WHEN COUNT(c.column_id) > 100 THEN 'HIGH' ELSE 'MEDIUM' END,
    CAST(NULL AS sysname),
    CAST(COUNT(c.column_id) AS nvarchar(20)) + ' columns — often indicates weak normalization or overloaded entity design.',
    'Review for vertical partitioning, related child tables, or sparse/JSON document boundaries.'
FROM sys.tables t
INNER JOIN sys.columns c ON t.object_id = c.object_id
WHERE t.is_ms_shipped = 0
GROUP BY t.object_id, t.name
HAVING COUNT(c.column_id) > 50

UNION ALL

-- Untrusted FKs
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(fk.parent_object_id) AS SchemaName,
    OBJECT_NAME(fk.parent_object_id) AS TableName,
    'UntrustedForeignKey' AS Issue,
    'HIGH',
    fk.name,
    'FK is disabled or not trusted — optimizer cannot rely on it and orphans may exist.',
    'Validate data then ALTER TABLE ... WITH CHECK CHECK CONSTRAINT.'
FROM sys.foreign_keys fk
WHERE fk.is_not_trusted = 1 OR fk.is_disabled = 1

UNION ALL

-- Untrusted/disabled checks
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(cc.parent_object_id) AS SchemaName,
    OBJECT_NAME(cc.parent_object_id) AS TableName,
    'UntrustedOrDisabledCheck' AS Issue,
    'MEDIUM',
    cc.name,
    'CHECK constraint is disabled or not trusted.',
    'Re-enable with WITH CHECK after cleansing invalid rows.'
FROM sys.check_constraints cc
WHERE cc.is_not_trusted = 1 OR cc.is_disabled = 1

UNION ALL

-- Repeating group column names (Phone1/Phone2, Email1/Email2, Address1/Address2, etc.)
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(t.object_id) AS SchemaName,
    t.name AS TableName,
    'RepeatingGroupColumns' AS Issue,
    'MEDIUM',
    CAST(NULL AS sysname),
    'Columns appear to encode repeating groups (numbered suffixes), a 1NF violation smell.',
    'Model as a related 1:N table (e.g., ContactMethod) instead of Phone1/Phone2/Email1 columns.'
FROM sys.tables t
WHERE t.is_ms_shipped = 0
  AND (
        SELECT COUNT(*)
        FROM sys.columns c
        WHERE c.object_id = t.object_id
          AND (
                c.name LIKE '%[0-9]'
                AND (
                    c.name LIKE 'Phone%' OR c.name LIKE 'Email%' OR c.name LIKE 'Address%'
                    OR c.name LIKE 'Fax%' OR c.name LIKE 'Mobile%' OR c.name LIKE 'Contact%'
                    OR c.name LIKE 'Line%' OR c.name LIKE 'Item%' OR c.name LIKE 'Child%'
                    OR c.name LIKE 'Col%' OR c.name LIKE 'Value%' OR c.name LIKE 'Field%'
                )
              )
      ) >= 2

UNION ALL

-- EAV-like tables (Attribute/Value style)
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(t.object_id) AS SchemaName,
    t.name AS TableName,
    'PossibleEavPattern' AS Issue,
    'MEDIUM',
    CAST(NULL AS sysname),
    'Table naming/columns suggest Entity-Attribute-Value design, which often harms query performance and typing.',
    'Confirm whether a typed schema or JSON document model is more appropriate for V2.'
FROM sys.tables t
WHERE t.is_ms_shipped = 0
  AND (
        t.name LIKE '%Attribute%' OR t.name LIKE '%Attrib%' OR t.name LIKE '%EAV%'
        OR t.name LIKE '%FlexField%' OR t.name LIKE '%CustomField%' OR t.name LIKE '%ExtendedPropert%'
      )
  AND EXISTS (
        SELECT 1 FROM sys.columns c
        WHERE c.object_id = t.object_id
          AND c.name IN ('AttributeName','AttributeValue','AttrName','AttrValue','PropertyName','PropertyValue','FieldName','FieldValue','KeyName','KeyValue')
      )

UNION ALL

-- Duplicate column names across multiple user tables (redundant data smell)
SELECT
    DB_NAME() AS DatabaseName,
    CAST(NULL AS sysname) AS SchemaName,
    CAST(NULL AS sysname) AS TableName,
    'DuplicateColumnNameAcrossTables' AS Issue,
    'LOW',
    c.name,
    'Column name appears in many tables and may indicate copied attributes instead of normalized references.',
    'Review whether this should be owned by a master table and referenced by key.'
FROM sys.columns c
INNER JOIN sys.tables t ON c.object_id = t.object_id
WHERE t.is_ms_shipped = 0
  AND c.name NOT IN ('Id','ID','CreatedDate','ModifiedDate','CreateDate','UpdateDate','CreatedBy','ModifiedBy','IsActive','IsDeleted','RowVersion','Timestamp')
GROUP BY c.name
HAVING COUNT(DISTINCT c.object_id) >= 8

UNION ALL

-- No compression on large tables
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(t.object_id) AS SchemaName,
    t.name AS TableName,
    'NoCompressionOnLargeTable' AS Issue,
    'MEDIUM',
    CAST(NULL AS sysname),
    'Large table has no ROW/PAGE compression — missed storage and IO quick win.',
    'Evaluate PAGE/ROW compression (and Columnstore for analytical tables) after workload testing.'
FROM sys.tables t
INNER JOIN sys.dm_db_partition_stats ps ON t.object_id = ps.object_id AND ps.index_id IN (0, 1)
INNER JOIN sys.partitions p ON t.object_id = p.object_id AND p.index_id IN (0, 1) AND p.partition_number = 1
WHERE t.is_ms_shipped = 0
  AND t.is_memory_optimized = 0
GROUP BY t.object_id, t.name, p.data_compression_desc
HAVING SUM(ps.used_page_count) >= 12800  -- >= 100 MB
   AND ISNULL(MAX(p.data_compression_desc), 'NONE') = 'NONE'

ORDER BY Severity, Issue, SchemaName, TableName;
