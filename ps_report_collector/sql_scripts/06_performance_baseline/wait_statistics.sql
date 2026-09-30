/* SQL_Initial_Assessment */
/*
  Top non-idle wait statistics (cumulative since last restart).
  Logic aligned with Wait_stats/top_server_waits.sql — exclusions, metrics, ranking, recommendations.
*/
SET NOCOUNT ON;

;WITH Waits AS
(
    SELECT
        wait_type,
        waiting_tasks_count,
        wait_time_ms,
        signal_wait_time_ms,
        resource_wait_ms = wait_time_ms - signal_wait_time_ms,
        avg_wait_ms =
            CASE
                WHEN waiting_tasks_count = 0 THEN 0
                ELSE wait_time_ms * 1.0 / waiting_tasks_count
            END
    FROM sys.dm_os_wait_stats
    WHERE wait_type NOT IN
    (
        'BROKER_EVENTHANDLER',
        'BROKER_RECEIVE_WAITFOR',
        'SOS_WORK_DISPATCHER',
        'BROKER_TASK_STOP',
        'BROKER_TO_FLUSH',
        'BROKER_TRANSMITTER',
        'CHECKPOINT_QUEUE',
        'CHKPT',
        'CLR_AUTO_EVENT',
        'CLR_MANUAL_EVENT',
        'CLR_SEMAPHORE',
        'DBMIRROR_DBM_EVENT',
        'DBMIRROR_EVENTS_QUEUE',
        'DBMIRROR_WORKER_QUEUE',
        'DBMIRRORING_CMD',
        'DIRTY_PAGE_POLL',
        'DISPATCHER_QUEUE_SEMAPHORE',
        'EXECSYNC',
        'FSAGENT',
        'FT_IFTS_SCHEDULER_IDLE_WAIT',
        'FT_IFTSHC_MUTEX',
        'HADR_CLUSAPI_CALL',
        'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
        'HADR_LOGCAPTURE_WAIT',
        'HADR_NOTIFICATION_DEQUEUE',
        'HADR_TIMER_TASK',
        'HADR_WORK_QUEUE',
        'KSOURCE_WAKEUP',
        'LAZYWRITER_SLEEP',
        'LOGMGR_QUEUE',
        'MEMORY_ALLOCATION_EXT',
        'ONDEMAND_TASK_QUEUE',
        'PARALLEL_REDO_DRAIN_WORKER',
        'PARALLEL_REDO_LOG_CACHE',
        'PARALLEL_REDO_TRAN_LIST',
        'PARALLEL_REDO_WORKER_SYNC',
        'PARALLEL_REDO_WORKER_WAIT_WORK',
        'PREEMPTIVE_OS_FLUSHFILEBUFFERS',
        'PREEMPTIVE_XE_GETTARGETSTATE',
        'PWAIT_ALL_COMPONENTS_INITIALIZED',
        'PWAIT_DIRECTLOGCONSUMER_GETNEXT',
        'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
        'QDS_ASYNC_QUEUE',
        'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
        'QDS_SHUTDOWN_QUEUE',
        'REDO_THREAD_PENDING_WORK',
        'REQUEST_FOR_DEADLOCK_SEARCH',
        'RESOURCE_QUEUE',
        'SERVER_IDLE_CHECK',
        'SLEEP_BPOOL_FLUSH',
        'SLEEP_DBSTARTUP',
        'SLEEP_DCOMSTARTUP',
        'SLEEP_MASTERDBREADY',
        'SLEEP_MASTERMDREADY',
        'SLEEP_MASTERUPGRADED',
        'SLEEP_MSDBSTARTUP',
        'SLEEP_SYSTEMTASK',
        'SLEEP_TASK',
        'SLEEP_TEMPDBSTARTUP',
        'SNI_HTTP_ACCEPT',
        'SP_SERVER_DIAGNOSTICS_SLEEP',
        'SQLTRACE_BUFFER_FLUSH',
        'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
        'SQLTRACE_WAIT_ENTRIES',
        'WAIT_FOR_RESULTS',
        'WAITFOR',
        'WAITFOR_TASKSHUTDOWN',
        'WAIT_XTP_RECOVERY',
        'XE_DISPATCHER_JOIN',
        'XE_DISPATCHER_WAIT',
        'XE_TIMER_EVENT'
    )
),
Totals AS
(
    SELECT SUM(wait_time_ms) AS total_wait_ms
    FROM Waits
)
SELECT TOP (25)
    w.wait_type AS WaitType,
    w.waiting_tasks_count AS WaitingTasks,
    CAST(w.wait_time_ms / 1000.0 AS decimal(18, 2)) AS TotalWaitSeconds,
    CAST(w.resource_wait_ms / 1000.0 AS decimal(18, 2)) AS ResourceWaitSeconds,
    CAST(w.signal_wait_time_ms / 1000.0 AS decimal(18, 2)) AS SignalWaitSeconds,
    CAST(w.avg_wait_ms AS decimal(18, 2)) AS AvgWaitMs,
    CAST((100.0 * w.wait_time_ms) / NULLIF(t.total_wait_ms, 0) AS decimal(6, 2)) AS WaitPercent,
    CASE
        WHEN w.wait_type LIKE 'PAGEIOLATCH%' THEN
            'Storage latency. Check disk latency, memory pressure, missing indexes.'
        WHEN w.wait_type LIKE 'PAGELATCH%' THEN
            'TempDB or allocation contention.'
        WHEN w.wait_type = 'CXPACKET' THEN
            'Review parallelism (MAXDOP & Cost Threshold).'
        WHEN w.wait_type = 'CXCONSUMER' THEN
            'Usually benign unless accompanied by CXPACKET.'
        WHEN w.wait_type LIKE 'LCK_M_%' THEN
            'Blocking. Investigate long-running transactions.'
        WHEN w.wait_type = 'WRITELOG' THEN
            'Transaction log bottleneck.'
        WHEN w.wait_type LIKE 'ASYNC_NETWORK_IO' THEN
            'Client consuming results slowly.'
        WHEN w.wait_type = 'SOS_SCHEDULER_YIELD' THEN
            'CPU pressure or inefficient queries.'
        WHEN w.wait_type = 'RESOURCE_SEMAPHORE' THEN
            'Memory grant pressure.'
        WHEN w.wait_type = 'THREADPOOL' THEN
            'Worker thread exhaustion.'
        WHEN w.wait_type = 'PREEMPTIVE_XE_DISPATCHER' THEN
            'Extended Events writing to OS. Usually benign unless XE sessions or storage are slow.'
        WHEN w.wait_type = 'PREEMPTIVE_OS_CRYPTOPS' THEN
            'Windows Crypto API. Check TDE, TLS, backup encryption, Always Encrypted, EKM, certificate validation.'
        WHEN w.wait_type = 'SOS_WORK_DISPATCHER' THEN
            'Background worker dispatcher. Normally expected and can usually be ignored.'
        WHEN w.wait_type = 'XE_DISPATCHER_WAIT' THEN
            'Extended Events dispatcher idle wait. Normally benign.'
        WHEN w.wait_type = 'XE_TIMER_EVENT' THEN
            'Extended Events timer wait. Normally benign.'
        WHEN w.wait_type = 'HADR_SYNC_COMMIT' THEN
            'Always On synchronous replica latency.'
        WHEN w.wait_type = 'LOG_RATE_GOVERNOR' THEN
            'Transaction log throughput throttling (commonly Azure SQL Managed Instance or cloud environments).'
        WHEN w.wait_type = 'RESERVED_MEMORY_ALLOCATION_EXT' THEN
            'Memory allocation pressure. Investigate if sustained with RESOURCE_SEMAPHORE.'
        WHEN w.wait_type = 'SESSION_WAIT_STATS_CHILDREN' THEN
            'Internal wait for per-session wait statistics aggregation. Normally benign and can be ignored.'
        WHEN w.wait_type = 'CMEMTHREAD' THEN
            'Memory object contention caused by concurrent access to shared SQL Server memory structures. Common causes include excessive compilations, ad hoc plan cache bloat, high concurrency, and plan cache contention. Review compilation rate, Optimize for Ad Hoc Workloads, parameterization, and MAXDOP.'
        ELSE
            'Investigate based on workload.'
    END AS Recommendation
FROM Waits w
CROSS JOIN Totals t
WHERE w.wait_time_ms > 0
ORDER BY WaitPercent DESC;
