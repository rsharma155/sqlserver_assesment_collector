/* SQL_Initial_Assessment */
SELECT
    CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) AS ServerName,
    CAST(SERVERPROPERTY('InstanceName') AS nvarchar(128)) AS InstanceName,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS Edition,
    CAST(SERVERPROPERTY('EngineEdition') AS int) AS EngineEdition,
    CAST(SERVERPROPERTY('IsClustered') AS int) AS IsClustered,
    CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS IsHadrEnabled,
    sqlserver_start_time AS LastRestart,
    DATEDIFF(MINUTE, sqlserver_start_time, GETDATE()) AS UptimeMinutes,
    cpu_count AS LogicalCpuCount,
    hyperthread_ratio AS HyperthreadRatio,
    physical_memory_kb / 1024 AS PhysicalMemoryMB,
    committed_kb / 1024 AS CommittedMemoryMB,
    committed_target_kb / 1024 AS CommittedTargetMB,
    sql_memory_model_desc AS SqlMemoryModel,
    softnuma_configuration_desc AS SoftNumaConfiguration,
    socket_count AS SocketCount,
    cores_per_socket AS CoresPerSocket,
    numa_node_count AS NumaNodeCount
FROM sys.dm_os_sys_info;
