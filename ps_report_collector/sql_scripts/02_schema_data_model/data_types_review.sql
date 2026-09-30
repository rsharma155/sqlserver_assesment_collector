/* SQL_Initial_Assessment */
/*
  Data type modernization inventory — flags upgrade/storage/design risks per column.
*/
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(c.object_id) AS SchemaName,
    OBJECT_NAME(c.object_id) AS TableName,
    c.name AS ColumnName,
    ty.name AS DataType,
    c.max_length AS MaxLength,
    c.precision AS [Precision],
    c.scale AS Scale,
    c.is_nullable AS IsNullable,
    c.is_identity AS IsIdentity,
    c.is_computed AS IsComputed,
    CASE WHEN cc.is_persisted = 1 THEN 1 WHEN c.is_computed = 1 THEN 0 ELSE NULL END AS IsPersistedComputed,
    c.is_filestream AS IsFilestream,
    c.is_sparse AS IsSparse,
    CASE
        WHEN ty.name IN ('varchar', 'nvarchar', 'varbinary') AND c.max_length = -1 THEN 1
        WHEN ty.name IN ('text', 'ntext', 'image') THEN 1
        ELSE 0
    END AS IsLob,
    CASE
        WHEN ty.name IN ('text', 'ntext', 'image') THEN 'Deprecated LOB type'
        WHEN ty.name = 'timestamp' THEN 'Deprecated TIMESTAMP (use ROWVERSION)'
        WHEN ty.name IN ('varchar', 'nvarchar', 'varbinary') AND c.max_length = -1 THEN 'MAX LOB column'
        WHEN ty.name IN ('datetime') THEN 'Legacy DATETIME (prefer DATETIME2)'
        WHEN ty.name = 'smalldatetime' THEN 'Legacy SMALLDATETIME (prefer DATETIME2/DATE/TIME)'
        WHEN ty.name IN ('money', 'smallmoney') THEN 'MONEY type (prefer DECIMAL)'
        WHEN ty.name IN ('float', 'real') THEN 'Approximate numeric (review for financial)'
        WHEN ty.name = 'sql_variant' THEN 'SQL_VARIANT usage'
        WHEN ty.name IN ('char', 'nchar') AND (
                (ty.name = 'char' AND c.max_length > 20) OR
                (ty.name = 'nchar' AND c.max_length > 40)
             ) THEN 'Wide fixed-length string (trailing space risk)'
        WHEN ty.name = 'nvarchar' AND c.max_length > 0 AND c.max_length <= 200
             THEN 'Unicode NVARCHAR (confirm Unicode necessity vs VARCHAR)'
        WHEN ty.name IN ('decimal', 'numeric') AND c.precision >= 28
             THEN 'Over-precised DECIMAL/NUMERIC'
        WHEN ty.name IN ('decimal', 'numeric') AND c.scale >= 8 AND c.precision >= 18
             THEN 'High-scale DECIMAL (confirm business need)'
        ELSE 'Review candidate'
    END AS AssessmentFlag,
    CASE
        WHEN ty.name IN ('text', 'ntext', 'image') THEN 'Upgrade blocker / modernization required'
        WHEN ty.name = 'timestamp' THEN 'Upgrade modernization'
        WHEN ty.name IN ('varchar', 'nvarchar', 'varbinary') AND c.max_length = -1 THEN 'Storage/I-O review'
        WHEN ty.name IN ('datetime', 'smalldatetime') THEN 'Type modernization candidate'
        WHEN ty.name IN ('money', 'smallmoney', 'float', 'real') THEN 'Financial precision risk'
        WHEN ty.name = 'nvarchar' THEN 'Storage optimization candidate'
        WHEN ty.name IN ('decimal', 'numeric') THEN 'Precision optimization candidate'
        WHEN ty.name IN ('char', 'nchar') THEN 'Storage waste candidate'
        ELSE 'Review'
    END AS RiskCategory,
    CASE
        WHEN ty.name = 'text' THEN 'Convert to VARCHAR(MAX)'
        WHEN ty.name = 'ntext' THEN 'Convert to NVARCHAR(MAX)'
        WHEN ty.name = 'image' THEN 'Convert to VARBINARY(MAX)'
        WHEN ty.name = 'timestamp' THEN 'Use ROWVERSION intentionally'
        WHEN ty.name = 'datetime' THEN 'Prefer DATETIME2(precision)'
        WHEN ty.name = 'smalldatetime' THEN 'Prefer DATETIME2/DATE/TIME'
        WHEN ty.name IN ('money', 'smallmoney') THEN 'Replace with DECIMAL(p,s)'
        WHEN ty.name = 'nvarchar' THEN 'Use VARCHAR if Unicode is not required'
        WHEN ty.name IN ('decimal', 'numeric') AND c.precision >= 28 THEN 'Reduce precision/scale to business needs'
        WHEN ty.name IN ('char', 'nchar') THEN 'Prefer VARCHAR/NVARCHAR for variable values'
        WHEN ty.name IN ('varchar', 'nvarchar', 'varbinary') AND c.max_length = -1 THEN 'Confirm MAX necessity; consider finite length or off-row document store'
        ELSE 'Review column design'
    END AS RecommendedAction
FROM sys.columns c
INNER JOIN sys.tables t ON c.object_id = t.object_id
INNER JOIN sys.types ty ON c.user_type_id = ty.user_type_id
LEFT JOIN sys.computed_columns cc ON c.object_id = cc.object_id AND c.column_id = cc.column_id
WHERE t.is_ms_shipped = 0
  AND (
        ty.name IN ('text', 'ntext', 'image', 'timestamp', 'sql_variant', 'money', 'smallmoney', 'float', 'real', 'smalldatetime', 'datetime')
        OR (ty.name IN ('varchar', 'nvarchar', 'varbinary') AND c.max_length = -1)
        OR (ty.name IN ('char', 'nchar') AND c.max_length > 20)
        OR (ty.name = 'nvarchar' AND c.max_length > 0 AND c.max_length <= 200)
        OR (ty.name IN ('decimal', 'numeric') AND (c.precision >= 28 OR (c.scale >= 8 AND c.precision >= 18)))
      )
ORDER BY
    CASE
        WHEN ty.name IN ('text', 'ntext', 'image', 'timestamp') THEN 1
        WHEN ty.name IN ('varchar', 'nvarchar', 'varbinary') AND c.max_length = -1 THEN 2
        WHEN ty.name IN ('datetime', 'smalldatetime', 'money', 'smallmoney') THEN 3
        ELSE 4
    END,
    SchemaName, TableName, ColumnName;
