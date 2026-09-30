/* SQL_Initial_Assessment */
SELECT
    CAST('LinkedServer' AS nvarchar(40)) COLLATE DATABASE_DEFAULT AS IntegrationType,
    CAST(s.name AS nvarchar(128)) COLLATE DATABASE_DEFAULT AS Name,
    CAST(s.product AS nvarchar(128)) COLLATE DATABASE_DEFAULT AS Product,
    CAST(s.provider AS nvarchar(128)) COLLATE DATABASE_DEFAULT AS Provider,
    CAST(s.data_source AS nvarchar(4000)) COLLATE DATABASE_DEFAULT AS DataSource,
    CAST(s.catalog AS nvarchar(128)) COLLATE DATABASE_DEFAULT AS CatalogName,
    s.is_linked AS IsLinked,
    s.is_remote_login_enabled AS IsRemoteLoginEnabled,
    s.is_rpc_out_enabled AS IsRpcOutEnabled,
    s.is_data_access_enabled AS IsDataAccessEnabled,
    CAST(NULL AS nvarchar(60)) COLLATE DATABASE_DEFAULT AS EndpointState
FROM sys.servers s
WHERE s.is_linked = 1

UNION ALL

SELECT
    CAST('ServiceBrokerEndpoint' AS nvarchar(40)) COLLATE DATABASE_DEFAULT AS IntegrationType,
    CAST(e.name AS nvarchar(128)) COLLATE DATABASE_DEFAULT AS Name,
    CAST(e.protocol_desc AS nvarchar(128)) COLLATE DATABASE_DEFAULT AS Product,
    CAST(e.type_desc AS nvarchar(128)) COLLATE DATABASE_DEFAULT AS Provider,
    CAST(CAST(t.port AS nvarchar(128)) AS nvarchar(4000)) COLLATE DATABASE_DEFAULT AS DataSource,
    CAST(NULL AS nvarchar(128)) COLLATE DATABASE_DEFAULT AS CatalogName,
    CAST(NULL AS bit) AS IsLinked,
    CAST(NULL AS bit) AS IsRemoteLoginEnabled,
    CAST(NULL AS bit) AS IsRpcOutEnabled,
    CAST(NULL AS bit) AS IsDataAccessEnabled,
    CAST(e.state_desc AS nvarchar(60)) COLLATE DATABASE_DEFAULT AS EndpointState
FROM sys.service_broker_endpoints e
LEFT JOIN sys.tcp_endpoints t ON e.endpoint_id = t.endpoint_id

ORDER BY IntegrationType, Name;
