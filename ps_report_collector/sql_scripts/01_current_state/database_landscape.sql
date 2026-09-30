/* SQL_Initial_Assessment */
;WITH sizes AS (
    SELECT
        database_id,
        SUM(CASE WHEN type = 0 THEN size ELSE 0 END) * 8.0 / 1024 AS DataSizeMB,
        SUM(CASE WHEN type = 1 THEN size ELSE 0 END) * 8.0 / 1024 AS LogSizeMB,
        COUNT(CASE WHEN type = 0 THEN 1 END) AS DataFileCount,
        COUNT(CASE WHEN type = 1 THEN 1 END) AS LogFileCount
    FROM sys.master_files
    GROUP BY database_id
)
SELECT
    d.name AS DatabaseName,
    d.database_id AS DatabaseId,
    d.state_desc AS Status,
    d.user_access_desc AS UserAccess,
    d.recovery_model_desc AS RecoveryModel,
    d.compatibility_level AS CompatibilityLevel,
    d.collation_name AS Collation,
    SUSER_SNAME(d.owner_sid) AS Owner,
    d.page_verify_option_desc AS PageVerify,
    d.is_auto_close_on AS AutoClose,
    d.is_auto_shrink_on AS AutoShrink,
    d.is_auto_create_stats_on AS AutoCreateStats,
    d.is_auto_update_stats_on AS AutoUpdateStats,
    d.is_auto_update_stats_async_on AS AutoUpdateStatsAsync,
    d.is_read_only AS IsReadOnly,
    d.is_encrypted AS IsEncrypted,
    d.is_query_store_on AS QueryStoreEnabled,
    d.is_broker_enabled AS BrokerEnabled,
    d.is_cdc_enabled AS CdcEnabled,
    d.is_published AS IsPublished,
    d.is_subscribed AS IsSubscribed,
    d.is_merge_published AS IsMergePublished,
    d.is_distributor AS IsDistributor,
    d.is_trustworthy_on AS Trustworthy,
    d.is_db_chaining_on AS DbChaining,
    d.containment_desc AS Containment,
    d.snapshot_isolation_state_desc AS SnapshotIsolation,
    d.is_read_committed_snapshot_on AS RcsiEnabled,
    d.delayed_durability_desc AS DelayedDurability,
    d.source_database_id AS SourceDatabaseId,
    HAS_DBACCESS(d.name) AS HasDbAccess,
    CAST(ISNULL(s.DataSizeMB, 0) AS decimal(18, 1)) AS DataSizeMB,
    CAST(ISNULL(s.LogSizeMB, 0) AS decimal(18, 1)) AS LogSizeMB,
    CAST(ISNULL(s.DataSizeMB, 0) + ISNULL(s.LogSizeMB, 0) AS decimal(18, 1)) AS TotalSizeMB,
    s.DataFileCount,
    s.LogFileCount,
    d.create_date AS CreateDate
FROM sys.databases d
LEFT JOIN sizes s ON d.database_id = s.database_id
ORDER BY d.database_id;
