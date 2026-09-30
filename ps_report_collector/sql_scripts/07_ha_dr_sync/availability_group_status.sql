/* SQL_Initial_Assessment */
SELECT
    ag.name AS AvailabilityGroupName,
    ar.replica_server_name AS ReplicaServerName,
    ar.availability_mode_desc AS AvailabilityMode,
    ar.failover_mode_desc AS FailoverMode,
    ar.primary_role_allow_connections_desc AS PrimaryConnections,
    ar.secondary_role_allow_connections_desc AS SecondaryConnections,
    ars.role_desc AS CurrentRole,
    ars.operational_state_desc AS OperationalState,
    ars.connected_state_desc AS ConnectedState,
    ars.synchronization_health_desc AS SynchronizationHealth,
    ars.last_connect_error_description AS LastConnectError
FROM sys.availability_groups ag
INNER JOIN sys.availability_replicas ar ON ag.group_id = ar.group_id
INNER JOIN sys.dm_hadr_availability_replica_states ars
    ON ar.replica_id = ars.replica_id AND ar.group_id = ars.group_id
ORDER BY ag.name, ar.replica_server_name;
