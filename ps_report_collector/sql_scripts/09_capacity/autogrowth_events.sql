/* SQL_Initial_Assessment */
DECLARE @path nvarchar(260);
SELECT @path = path FROM sys.traces WHERE is_default = 1;

IF @path IS NOT NULL
BEGIN
    SELECT TOP (200)
        DatabaseName,
        FileName,
        StartTime,
        Duration / 1000.0 AS DurationMs,
        IntegerData * 8.0 / 1024 AS GrowthMB,
        CASE EventClass
            WHEN 92 THEN 'Data File Auto Grow'
            WHEN 93 THEN 'Log File Auto Grow'
            WHEN 94 THEN 'Data File Auto Shrink'
            WHEN 95 THEN 'Log File Auto Shrink'
        END AS EventName
    FROM fn_trace_gettable(@path, DEFAULT)
    WHERE EventClass IN (92, 93, 94, 95)
      AND StartTime >= DATEADD(DAY, -{{DaysToAnalyze}}, GETDATE())
{{DatabaseFilter}}
    ORDER BY StartTime DESC;
END
ELSE
BEGIN
    SELECT
        CAST(NULL AS nvarchar(128)) AS DatabaseName,
        CAST(NULL AS nvarchar(260)) AS FileName,
        CAST(NULL AS datetime) AS StartTime,
        CAST(NULL AS float) AS DurationMs,
        CAST(NULL AS float) AS GrowthMB,
        CAST('Default trace not available' AS nvarchar(60)) AS EventName
    WHERE 1 = 0;
END
