/* SQL_Initial_Assessment */
SELECT
    servicename AS ServiceName,
    startup_type_desc AS StartupType,
    status_desc AS Status,
    last_startup_time AS LastStartupTime,
    service_account AS ServiceAccount,
    filename AS BinaryPath
FROM sys.dm_server_services
ORDER BY servicename;
