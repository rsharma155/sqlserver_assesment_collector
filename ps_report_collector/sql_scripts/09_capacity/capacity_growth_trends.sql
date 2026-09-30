/* SQL_Initial_Assessment */
;WITH backup_sizes AS (
    SELECT
        database_name AS DatabaseName,
        backup_finish_date AS BackupFinishDate,
        backup_size / 1024.0 / 1024 AS BackupSizeMB,
        compressed_backup_size / 1024.0 / 1024 AS CompressedSizeMB
    FROM msdb.dbo.backupset
    WHERE type = 'D'
      AND is_copy_only = 0
      AND backup_finish_date >= DATEADD(DAY, -{{DaysToAnalyze}}, GETDATE())
{{DatabaseFilter}}
),
ranked AS (
    SELECT
        DatabaseName,
        BackupFinishDate,
        BackupSizeMB,
        CompressedSizeMB,
        ROW_NUMBER() OVER (PARTITION BY DatabaseName ORDER BY BackupFinishDate ASC) AS RnAsc,
        ROW_NUMBER() OVER (PARTITION BY DatabaseName ORDER BY BackupFinishDate DESC) AS RnDesc,
        COUNT(*) OVER (PARTITION BY DatabaseName) AS SampleCount
    FROM backup_sizes
)
SELECT
    DatabaseName,
    MIN(BackupFinishDate) AS OldestSample,
    MAX(BackupFinishDate) AS NewestSample,
    MAX(CASE WHEN RnAsc = 1 THEN BackupSizeMB END) AS OldestBackupSizeMB,
    MAX(CASE WHEN RnDesc = 1 THEN BackupSizeMB END) AS NewestBackupSizeMB,
    CAST(
        MAX(CASE WHEN RnDesc = 1 THEN BackupSizeMB END)
        - MAX(CASE WHEN RnAsc = 1 THEN BackupSizeMB END)
        AS decimal(18, 2)
    ) AS GrowthMB,
    MAX(SampleCount) AS SampleCount,
    CAST(
        CASE
            WHEN DATEDIFF(DAY, MIN(BackupFinishDate), MAX(BackupFinishDate)) > 0
            THEN (
                MAX(CASE WHEN RnDesc = 1 THEN BackupSizeMB END)
                - MAX(CASE WHEN RnAsc = 1 THEN BackupSizeMB END)
            ) * 90.0 / DATEDIFF(DAY, MIN(BackupFinishDate), MAX(BackupFinishDate))
            ELSE 0
        END AS decimal(18, 2)
    ) AS Estimated90DayGrowthMB
FROM ranked
GROUP BY DatabaseName
ORDER BY Estimated90DayGrowthMB DESC, DatabaseName;
