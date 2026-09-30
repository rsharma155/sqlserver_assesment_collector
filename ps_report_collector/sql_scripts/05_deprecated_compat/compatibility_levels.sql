/* SQL_Initial_Assessment */
SELECT
    d.name AS DatabaseName,
    d.compatibility_level AS CompatibilityLevel,
    CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS ProductMajorVersion,
    CASE
        WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16 THEN 160
        WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS int) = 15 THEN 150
        WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS int) = 14 THEN 140
        WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS int) = 13 THEN 130
        ELSE d.compatibility_level
    END AS MaxSupportedCompatLevel,
    CASE
        WHEN d.compatibility_level <
            CASE
                WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS int) >= 16 THEN 160
                WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS int) = 15 THEN 150
                WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS int) = 14 THEN 140
                WHEN CAST(SERVERPROPERTY('ProductMajorVersion') AS int) = 13 THEN 130
                ELSE d.compatibility_level
            END
        THEN 'Below engine max - IQP/CE features may be limited'
        ELSE 'At or near engine max'
    END AS Assessment,
    d.collation_name AS Collation,
    d.is_query_store_on AS QueryStoreEnabled,
    d.is_auto_update_stats_async_on AS AutoUpdateStatsAsync,
    d.is_encrypted AS IsEncrypted,
    d.state_desc AS Status
FROM sys.databases d
WHERE d.database_id > 4
{{DatabaseFilter}}
ORDER BY d.compatibility_level, d.name;
