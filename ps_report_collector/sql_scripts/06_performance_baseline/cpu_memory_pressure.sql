/* SQL_Initial_Assessment */
SELECT
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE counter_name = 'Page life expectancy' AND object_name LIKE '%Buffer Manager%') AS PageLifeExpectancy,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE counter_name = 'Lazy writes/sec' AND object_name LIKE '%Buffer Manager%') AS LazyWritesPerSec,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE counter_name = 'Checkpoint pages/sec' AND object_name LIKE '%Buffer Manager%') AS CheckpointPagesPerSec,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE counter_name = 'Memory Grants Pending' AND object_name LIKE '%Memory Manager%') AS MemoryGrantsPending,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE counter_name = 'Memory Grants Outstanding' AND object_name LIKE '%Memory Manager%') AS MemoryGrantsOutstanding,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE counter_name = 'Batch Requests/sec' AND object_name LIKE '%SQL Statistics%') AS BatchRequestsPerSec,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE counter_name = 'SQL Compilations/sec' AND object_name LIKE '%SQL Statistics%') AS SqlCompilationsPerSec,
    (SELECT cntr_value FROM sys.dm_os_performance_counters
     WHERE counter_name = 'SQL Re-Compilations/sec' AND object_name LIKE '%SQL Statistics%') AS SqlRecompilationsPerSec,
    (SELECT physical_memory_kb / 1024 FROM sys.dm_os_sys_info) AS PhysicalMemoryMB,
    (SELECT committed_target_kb / 1024 FROM sys.dm_os_sys_info) AS CommittedTargetMB,
    (SELECT committed_kb / 1024 FROM sys.dm_os_sys_info) AS CommittedMB;
