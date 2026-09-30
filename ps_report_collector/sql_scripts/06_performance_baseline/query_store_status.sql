/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    qs.actual_state_desc AS ActualState,
    qs.desired_state_desc AS DesiredState,
    qs.readonly_reason AS ReadonlyReason,
    qs.current_storage_size_mb AS CurrentStorageSizeMB,
    qs.max_storage_size_mb AS MaxStorageSizeMB,
    qs.flush_interval_seconds AS FlushIntervalSeconds,
    qs.interval_length_minutes AS IntervalLengthMinutes,
    qs.size_based_cleanup_mode_desc AS SizeBasedCleanupMode,
    qs.query_capture_mode_desc AS QueryCaptureMode,
    qs.stale_query_threshold_days AS StaleQueryThresholdDays,
    qs.max_plans_per_query AS MaxPlansPerQuery
FROM sys.database_query_store_options qs;
