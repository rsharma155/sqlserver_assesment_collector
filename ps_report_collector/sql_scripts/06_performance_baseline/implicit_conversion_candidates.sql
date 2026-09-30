/* SQL_Initial_Assessment */
SELECT TOP (100)
    DB_NAME(CONVERT(int, epa.value)) AS DatabaseName,
    qs.execution_count AS ExecutionCount,
    qs.total_worker_time / 1000 AS TotalCpuMs,
    CAST(qs.total_worker_time / 1000.0 / NULLIF(qs.execution_count, 0) AS decimal(18, 2)) AS AvgCpuMs,
    qs.last_execution_time AS LastExecutionTime,
    CASE
        WHEN st.text LIKE '%CONVERT(%' OR st.text LIKE '%CAST(%' THEN 'CAST/CONVERT present'
        WHEN st.text LIKE '%COLLATE%' THEN 'COLLATE present'
        ELSE 'Type coercion pattern'
    END AS Pattern,
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
  AND (
        st.text LIKE '%CONVERT(%'
        OR st.text LIKE '%CAST(%'
        OR st.text LIKE '%COLLATE%'
      )
{{DatabaseFilter}}
ORDER BY qs.total_worker_time DESC;
