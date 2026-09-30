/* SQL_Initial_Assessment */
SELECT DISTINCT
    vs.volume_mount_point AS VolumeMountPoint,
    vs.logical_volume_name AS LogicalVolumeName,
    vs.file_system_type AS FileSystemType,
    CAST(vs.total_bytes / 1024.0 / 1024 / 1024 AS decimal(18, 2)) AS TotalSizeGB,
    CAST(vs.available_bytes / 1024.0 / 1024 / 1024 AS decimal(18, 2)) AS FreeSpaceGB,
    CAST(100.0 * vs.available_bytes / NULLIF(vs.total_bytes, 0) AS decimal(5, 2)) AS FreePct
FROM sys.master_files AS mf
CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) AS vs
ORDER BY vs.volume_mount_point;
