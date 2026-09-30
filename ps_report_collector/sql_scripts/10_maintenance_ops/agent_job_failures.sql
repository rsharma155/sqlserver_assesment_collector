/* SQL_Initial_Assessment */
SELECT TOP (100)
    j.name AS JobName,
    h.step_id AS StepId,
    h.step_name AS StepName,
    h.run_date AS RunDate,
    h.run_time AS RunTime,
    h.run_duration AS RunDuration,
    h.sql_severity AS SqlSeverity,
    h.message AS Message
FROM msdb.dbo.sysjobhistory h
INNER JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
WHERE h.run_status = 0
  AND h.run_date >= CONVERT(int, CONVERT(varchar(8), DATEADD(DAY, -{{DaysToAnalyze}}, GETDATE()), 112))
ORDER BY h.run_date DESC, h.run_time DESC;
