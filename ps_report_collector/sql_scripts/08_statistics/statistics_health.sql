/* SQL_Initial_Assessment */
SELECT
    DB_NAME() AS DatabaseName,
    OBJECT_SCHEMA_NAME(st.object_id) AS SchemaName,
    OBJECT_NAME(st.object_id) AS TableName,
    st.name AS StatisticsName,
    sp.last_updated AS LastUpdated,
    CASE WHEN sp.last_updated IS NULL THEN NULL ELSE DATEDIFF(DAY, sp.last_updated, GETDATE()) END AS DaysSinceUpdate,
    sp.rows AS [Rows],
    sp.rows_sampled AS RowsSampled,
    CAST(100.0 * sp.rows_sampled / NULLIF(sp.rows, 0) AS decimal(8, 2)) AS SamplePercent,
    sp.modification_counter AS ModificationCounter,
    CAST(100.0 * sp.modification_counter / NULLIF(sp.rows, 0) AS decimal(10, 2)) AS ModificationPercent,
    st.auto_created AS AutoCreated,
    st.user_created AS UserCreated,
    st.no_recompute AS NoRecompute,
    st.has_filter AS HasFilter,
    st.filter_definition AS FilterDefinition,
    CASE
        WHEN sp.modification_counter IS NOT NULL
             AND sp.rows IS NOT NULL
             AND sp.rows > 0
             AND (100.0 * sp.modification_counter / sp.rows) >= 20
            THEN 'Yes'
        WHEN sp.last_updated IS NOT NULL
             AND DATEDIFF(DAY, sp.last_updated, GETDATE()) >= 30
             AND ISNULL(sp.rows, 0) >= 10000
            THEN 'Yes'
        WHEN st.no_recompute = 1
             AND sp.modification_counter IS NOT NULL
             AND sp.rows IS NOT NULL
             AND sp.rows > 0
             AND (100.0 * sp.modification_counter / sp.rows) >= 10
            THEN 'Yes'
        ELSE 'No'
    END AS RequiresUpdate,
    CASE
        WHEN sp.modification_counter IS NOT NULL
             AND sp.rows IS NOT NULL
             AND sp.rows > 0
             AND (100.0 * sp.modification_counter / sp.rows) >= 20
            THEN 'UPDATE REQUIRED - high modification pct'
        WHEN sp.last_updated IS NOT NULL
             AND DATEDIFF(DAY, sp.last_updated, GETDATE()) >= 30
             AND ISNULL(sp.rows, 0) >= 10000
            THEN 'UPDATE REQUIRED - old update on large table'
        WHEN st.no_recompute = 1
             AND sp.modification_counter IS NOT NULL
             AND sp.rows IS NOT NULL
             AND sp.rows > 0
             AND (100.0 * sp.modification_counter / sp.rows) >= 10
            THEN 'UPDATE REQUIRED - NORECOMPUTE with modifications'
        WHEN st.no_recompute = 1 THEN 'Review - NORECOMPUTE set'
        ELSE 'OK / review'
    END AS Assessment
FROM sys.stats st
INNER JOIN sys.tables t ON st.object_id = t.object_id
OUTER APPLY sys.dm_db_stats_properties(st.object_id, st.stats_id) sp
WHERE t.is_ms_shipped = 0
ORDER BY
    CASE
        WHEN sp.modification_counter IS NOT NULL AND sp.rows > 0 AND (100.0 * sp.modification_counter / sp.rows) >= 20 THEN 0
        WHEN sp.last_updated IS NOT NULL AND DATEDIFF(DAY, sp.last_updated, GETDATE()) >= 30 AND ISNULL(sp.rows, 0) >= 10000 THEN 1
        WHEN st.no_recompute = 1 THEN 2
        ELSE 3
    END,
    ModificationPercent DESC,
    SchemaName, TableName, StatisticsName;
