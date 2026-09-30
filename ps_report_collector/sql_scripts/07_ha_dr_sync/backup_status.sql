/* SQL_Initial_Assessment */
SELECT
    d.name AS DatabaseName,
    d.recovery_model_desc AS RecoveryModel,
    MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END) AS LastFullBackup,
    MAX(CASE WHEN b.type = 'I' THEN b.backup_finish_date END) AS LastDiffBackup,
    MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END) AS LastLogBackup,
    DATEDIFF(HOUR, MAX(CASE WHEN b.type = 'D' THEN b.backup_finish_date END), GETDATE()) AS FullAgeHours,
    DATEDIFF(MINUTE, MAX(CASE WHEN b.type = 'L' THEN b.backup_finish_date END), GETDATE()) AS LogAgeMinutes,
    MAX(CASE WHEN b.type = 'D' THEN b.backup_size END) / 1024.0 / 1024 AS LastFullBackupSizeMB,
    MAX(CASE WHEN b.type = 'D' THEN b.compressed_backup_size END) / 1024.0 / 1024 AS LastFullCompressedSizeMB
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset b
    ON d.name = b.database_name
   AND b.is_copy_only = 0
WHERE d.name NOT IN ('tempdb')
  AND d.state = 0
{{DatabaseFilter}}
GROUP BY d.name, d.recovery_model_desc
ORDER BY d.name;
