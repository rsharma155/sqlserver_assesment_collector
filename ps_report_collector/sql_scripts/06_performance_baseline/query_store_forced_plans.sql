/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    q.query_id AS QueryId,
    p.plan_id AS PlanId,
    p.is_forced_plan AS IsForcedPlan,
    p.force_failure_count AS ForceFailureCount,
    p.last_force_failure_reason_desc AS LastForceFailureReason,
    p.compatibility_level AS PlanCompatibilityLevel,
    LEFT(qt.query_sql_text, 400) AS QueryTextPreview
FROM sys.query_store_plan p
INNER JOIN sys.query_store_query q ON p.query_id = q.query_id
INNER JOIN sys.query_store_query_text qt ON q.query_text_id = qt.query_text_id
WHERE p.is_forced_plan = 1
ORDER BY p.force_failure_count DESC, p.plan_id;
