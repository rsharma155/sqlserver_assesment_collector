/* SQL_Initial_Assessment */
SELECT
    j.name AS JobName,
    j.enabled AS IsEnabled,
    j.category_id AS CategoryId,
    c.name AS CategoryName,
    SUSER_SNAME(j.owner_sid) AS OwnerName,
    j.date_created AS DateCreated,
    j.date_modified AS DateModified,
    CASE
        WHEN j.name LIKE '%backup%' OR j.name LIKE '%index%' OR j.name LIKE '%stat%'
             OR j.name LIKE '%checkdb%' OR j.name LIKE '%maint%' OR c.name LIKE '%Database Maintenance%'
            THEN 1 ELSE 0
    END AS LooksLikeMaintenance,
    (
        SELECT TOP (1) h.run_date
        FROM msdb.dbo.sysjobhistory h
        WHERE h.job_id = j.job_id AND h.step_id = 0
        ORDER BY h.instance_id DESC
    ) AS LastRunDate,
    (
        SELECT TOP (1) h.run_status
        FROM msdb.dbo.sysjobhistory h
        WHERE h.job_id = j.job_id AND h.step_id = 0
        ORDER BY h.instance_id DESC
    ) AS LastRunStatus
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON j.category_id = c.category_id
ORDER BY LooksLikeMaintenance DESC, j.name;
