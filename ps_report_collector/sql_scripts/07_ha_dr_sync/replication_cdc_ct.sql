/* SQL_Initial_Assessment */
SELECT
    d.name AS DatabaseName,
    d.is_published AS IsPublished,
    d.is_subscribed AS IsSubscribed,
    d.is_merge_published AS IsMergePublished,
    d.is_distributor AS IsDistributor,
    d.is_cdc_enabled AS CdcEnabled,
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM sys.change_tracking_databases ctd
            WHERE ctd.database_id = d.database_id
        ) THEN 1 ELSE 0
    END AS ChangeTrackingEnabled,
    d.is_broker_enabled AS BrokerEnabled,
    dm.mirroring_state_desc AS MirroringState,
    dm.mirroring_role_desc AS MirroringRole,
    dm.mirroring_safety_level_desc AS MirroringSafetyLevel,
    CASE
        WHEN d.is_cdc_enabled = 1 THEN 'CDC'
        WHEN EXISTS (
            SELECT 1 FROM sys.change_tracking_databases ctd WHERE ctd.database_id = d.database_id
        ) THEN 'Change Tracking'
        WHEN d.is_published = 1 OR d.is_subscribed = 1 OR d.is_merge_published = 1 THEN 'Replication'
        WHEN d.is_broker_enabled = 1 THEN 'Service Broker'
        WHEN dm.mirroring_guid IS NOT NULL THEN 'Database Mirroring'
        ELSE 'None detected'
    END AS SyncFeature
FROM sys.databases d
LEFT JOIN sys.database_mirroring dm ON d.database_id = dm.database_id
WHERE d.database_id > 4
{{DatabaseFilter}}
ORDER BY SyncFeature, d.name;
