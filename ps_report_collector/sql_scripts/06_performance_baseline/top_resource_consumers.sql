/* SQL_Initial_Assessment */
SELECT TOP (50)
    DB_NAME(CONVERT(int, epa.value)) AS DatabaseName,
    qs.execution_count AS ExecutionCount,
    qs.total_worker_time / 1000 AS TotalCpuMs,
    qs.total_elapsed_time / 1000 AS TotalElapsedMs,
    qs.total_logical_reads AS TotalLogicalReads,
    qs.total_logical_writes AS TotalLogicalWrites,
    qs.total_physical_reads AS TotalPhysicalReads,
    CAST(qs.total_worker_time / 1000.0 / NULLIF(qs.execution_count, 0) AS decimal(18, 2)) AS AvgCpuMs,
    CAST(qs.total_elapsed_time / 1000.0 / NULLIF(qs.execution_count, 0) AS decimal(18, 2)) AS AvgElapsedMs,
    CAST(qs.total_logical_reads * 1.0 / NULLIF(qs.execution_count, 0) AS decimal(18, 2)) AS AvgLogicalReads,
    qs.creation_time AS PlanCreationTime,
    qs.last_execution_time AS LastExecutionTime,
    SUBSTRING(st.text,
        (qs.statement_start_offset / 2) + 1,
        ((CASE qs.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE qs.statement_end_offset END
            - qs.statement_start_offset) / 2) + 1
    ) AS StatementText
FROM sys.dm_exec_query_stats qs
CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) st
OUTER APPLY sys.dm_exec_plan_attributes(qs.plan_handle) epa
WHERE epa.attribute = 'dbid'
  AND CONVERT(int, epa.value) > 4
  AND st.text NOT LIKE '%SQL_Initial_Assessment%'
{{DatabaseFilter}}
ORDER BY qs.total_worker_time DESC;
