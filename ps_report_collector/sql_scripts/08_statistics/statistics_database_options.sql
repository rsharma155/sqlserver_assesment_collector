/* SQL_Initial_Assessment */
-- Database-level auto stats settings (complements per-stat health).
SELECT
    name AS DatabaseName,
    is_auto_create_stats_on AS AutoCreateStats,
    is_auto_update_stats_on AS AutoUpdateStats,
    is_auto_update_stats_async_on AS AutoUpdateStatsAsync,
    CASE
        WHEN is_auto_create_stats_on = 0 OR is_auto_update_stats_on = 0 THEN 'WARNING - auto stats disabled'
        WHEN is_auto_update_stats_async_on = 0 THEN 'INFO - async stats off'
        ELSE 'OK'
    END AS Assessment
FROM sys.databases
WHERE database_id = DB_ID();
