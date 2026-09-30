/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    fg.name AS FilegroupName,
    fg.type_desc AS FilegroupType,
    fg.is_default AS IsDefault,
    fg.is_read_only AS IsReadOnly,
    df.name AS LogicalFileName,
    df.type_desc AS FileType,
    CAST(df.size * 8.0 / 1024 AS decimal(18, 2)) AS SizeMB,
    CASE WHEN df.max_size = -1 THEN -1 ELSE CAST(df.max_size * 8.0 / 1024 AS decimal(18, 2)) END AS MaxSizeMB,
    df.growth AS GrowthSetting,
    df.is_percent_growth AS IsPercentGrowth,
    df.physical_name AS PhysicalName,
    (SELECT COUNT(*) FROM sys.partitions p
     INNER JOIN sys.allocation_units au ON p.partition_id = au.container_id
     WHERE au.data_space_id = fg.data_space_id AND p.data_compression > 0) AS CompressedPartitionHint
FROM sys.filegroups fg
INNER JOIN sys.database_files df ON fg.data_space_id = df.data_space_id
ORDER BY fg.name, df.file_id;
