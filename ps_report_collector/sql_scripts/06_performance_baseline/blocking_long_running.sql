/* SQL_Initial_Assessment */
SELECT
    DB_NAME(er.database_id) AS DatabaseName,
    er.session_id AS SessionId,
    er.blocking_session_id AS BlockingSessionId,
    er.wait_type AS WaitType,
    er.wait_time AS WaitTimeMs,
    er.wait_resource AS WaitResource,
    er.status AS Status,
    er.command AS Command,
    er.cpu_time AS CpuTimeMs,
    er.total_elapsed_time AS ElapsedTimeMs,
    er.reads AS Reads,
    er.writes AS Writes,
    er.logical_reads AS LogicalReads,
    er.transaction_isolation_level AS IsolationLevel,
    es.login_name AS LoginName,
    es.host_name AS HostName,
    es.program_name AS ProgramName,
    SUBSTRING(st.text, 1, 400) AS BatchText
FROM sys.dm_exec_requests er
INNER JOIN sys.dm_exec_sessions es ON er.session_id = es.session_id
OUTER APPLY sys.dm_exec_sql_text(er.sql_handle) st
WHERE er.session_id <> @@SPID
  AND (
        er.blocking_session_id > 0
        OR er.total_elapsed_time > 30000
        OR er.status = 'suspended'
      )
  AND (es.program_name IS NULL OR es.program_name NOT LIKE 'dbatools PowerShell%')
{{DatabaseFilter}}
ORDER BY er.blocking_session_id DESC, er.total_elapsed_time DESC;
