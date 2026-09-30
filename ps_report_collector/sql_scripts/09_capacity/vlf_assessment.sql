/* SQL_Initial_Assessment */
-- Prefer DMV when available (SQL 2016 SP2 / 2017+).
SELECT
    DB_NAME() AS DatabaseName,
    file_id AS FileId,
    COUNT(*) AS VlfCount,
    CAST(SUM(vlf_size_mb) AS decimal(18, 2)) AS TotalVlfSizeMB,
    CAST(AVG(vlf_size_mb) AS decimal(18, 2)) AS AvgVlfSizeMB,
    SUM(CASE WHEN vlf_active = 1 THEN 1 ELSE 0 END) AS ActiveVlfCount,
    CASE
        WHEN COUNT(*) >= 500 THEN 'CRITICAL - excessive VLFs'
        WHEN COUNT(*) >= 100 THEN 'HIGH - VLF count elevated'
        WHEN COUNT(*) >= 50 THEN 'MEDIUM - monitor / consider shrink-regrow plan'
        ELSE 'OK'
    END AS Assessment
FROM sys.dm_db_log_info(DB_ID())
GROUP BY file_id
ORDER BY VlfCount DESC;
