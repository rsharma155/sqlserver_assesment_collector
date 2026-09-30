-- =====================================================================================
-- OPTIONAL. The advisor does not execute this file.
-- Run it yourself, on the source instance, when you want runtime proof of deprecated
-- feature use (including dynamic SQL) over a business cycle.
--
-- It creates an Extended Events session. That is not a read-only assessment step.
-- Stop and drop the session when the capture window ends. Review the .xel file offline.
-- Requires ALTER ANY EVENT SESSION.
-- =====================================================================================
/*
IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'SqlUpgradeAdvisor_Deprecated')
    DROP EVENT SESSION [SqlUpgradeAdvisor_Deprecated] ON SERVER;
GO

CREATE EVENT SESSION [SqlUpgradeAdvisor_Deprecated] ON SERVER
ADD EVENT sqlserver.deprecation_announcement,
ADD EVENT sqlserver.deprecation_final_support
ADD TARGET package0.event_file
    (SET filename = N'SqlUpgradeAdvisor_Deprecated.xel', max_file_size = 50, max_rollover_files = 4)
WITH (STARTUP_STATE = OFF);
GO

ALTER EVENT SESSION [SqlUpgradeAdvisor_Deprecated] ON SERVER STATE = START;
GO

-- After the capture window:
-- ALTER EVENT SESSION [SqlUpgradeAdvisor_Deprecated] ON SERVER STATE = STOP;
-- DROP EVENT SESSION [SqlUpgradeAdvisor_Deprecated] ON SERVER;
*/
