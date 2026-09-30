/* SQL_Initial_Assessment */
SELECT
    name AS FileName,
    type_desc AS FileType,
    state_desc AS State,
    CAST(size * 8.0 / 1024 AS decimal(18, 2)) AS SizeMB,
    CAST(FILEPROPERTY(name, 'SpaceUsed') * 8.0 / 1024 AS decimal(18, 2)) AS UsedMB,
    CASE WHEN max_size = -1 THEN -1 ELSE CAST(max_size * 8.0 / 1024 AS decimal(18, 2)) END AS MaxSizeMB,
    growth AS GrowthSetting,
    is_percent_growth AS IsPercentGrowth,
    physical_name AS PhysicalName
FROM tempdb.sys.database_files
ORDER BY type, file_id;

-- Also return version store / space summary as second result set is not supported
-- by simple Invoke-DbaQuery collection easily; keep single result set focused on files.
