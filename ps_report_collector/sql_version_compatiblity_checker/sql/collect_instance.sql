-- =====================================================================================
-- SQL Upgrade Advisor — instance collectors
-- Run by : Get-AdvInstanceData, against master (some sections read msdb)
--
-- Each "-- section: <name>" block is executed on its own. Do not combine sections
-- into one batch: the advisor loads one section per call.
-- Collection sections must stay read-only (SELECT or DBCC TRACESTATUS).
-- The login setup script is CreateAdvisorUser.sql and is never executed by the advisor.
-- =====================================================================================

-- section: inst_instance_properties
-- Version, edition, collation, cluster / HADR. ProductMajorVersion exists on 2012+.
SELECT @@SERVERNAME AS ServerName,
       CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion,
       CAST(SERVERPROPERTY('ProductMajorVersion') AS int) AS ProductMajorVersion,
       CAST(SERVERPROPERTY('ProductLevel')  AS nvarchar(128)) AS ProductLevel,
       CAST(SERVERPROPERTY('Edition')       AS nvarchar(128)) AS Edition,
       CAST(SERVERPROPERTY('Collation')     AS nvarchar(128)) AS Collation,
       CAST(SERVERPROPERTY('EngineEdition') AS int) AS EngineEdition,
       CAST(SERVERPROPERTY('IsClustered')   AS int) AS IsClustered,
       CAST(SERVERPROPERTY('IsHadrEnabled') AS int) AS IsHadrEnabled,
       CAST(SERVERPROPERTY('IsFullTextInstalled') AS int) AS IsFullTextInstalled,
       CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS int) AS IsIntegratedSecurityOnly

-- section: inst_config_options
-- value is the configured setting; value_in_use is what is active (may differ until restart).
SELECT name,
       CAST(value AS bigint) AS value,
       CAST(value_in_use AS bigint) AS value_in_use
FROM sys.configurations
WHERE name IN (
    N'clr strict security', N'lightweight pooling', N'external scripts enabled', N'xp_cmdshell',
    N'Ole Automation Procedures', N'Ad Hoc Distributed Queries', N'clr enabled',
    N'max degree of parallelism', N'cost threshold for parallelism',
    N'remote data archive', N'filestream access level', N'contained database authentication'
)

-- section: inst_databases
-- Replication flags catch a publisher whose distribution database is remote or renamed.
SELECT d.database_id, d.name, d.compatibility_level, d.collation_name, d.state_desc,
       d.recovery_model_desc, d.is_trustworthy_on, d.is_read_only, d.user_access_desc,
       d.is_auto_create_stats_on, d.is_auto_update_stats_on,
       CAST(d.is_remote_data_archive_enabled AS bit) AS is_remote_data_archive_enabled,
       d.page_verify_option_desc, CAST(d.is_encrypted AS bit) AS is_encrypted,
       d.is_ansi_nulls_on, d.is_ansi_padding_on, d.is_concat_null_yields_null_on,
       d.is_published, d.is_subscribed, d.is_merge_published, d.is_distributor,
       SUSER_SNAME(d.owner_sid) AS owner_name
FROM sys.databases d
ORDER BY d.database_id

-- section: owner_permissions
-- Parameter {owner} is substituted by the advisor after quote-escaping the login name.
SELECT IS_SRVROLEMEMBER('sysadmin', N'{owner}'),
       COALESCE(HAS_PERMS_BY_NAME(N'{owner}', 'SERVER', 'UNSAFE ASSEMBLY'), 0)

-- section: inst_linked_servers
-- is_linked = 1 excludes the local server row and the repl_distributor registration.
SELECT server_id, name, product, provider, data_source,
       CAST(is_rpc_out_enabled AS int) AS is_rpc_out_enabled,
       CAST(is_data_access_enabled AS int) AS is_data_access_enabled
FROM sys.servers
WHERE is_linked = 1
ORDER BY name

-- section: inst_mirroring
SELECT DB_NAME(database_id) AS database_name, mirroring_state_desc, mirroring_role_desc, mirroring_partner_name
FROM sys.database_mirroring
WHERE mirroring_guid IS NOT NULL

-- section: inst_availability_groups
-- 2012–2016 safe. cluster_type_desc does not exist before SQL Server 2017 and must not
-- be referenced here: the engine compiles the whole batch.
SELECT name,
       CAST(NULL AS nvarchar(60)) AS cluster_type_desc
FROM sys.availability_groups

-- section: inst_availability_groups_cluster
-- SQL Server 2017+ only. The advisor selects this section when ProductMajorVersion >= 14.
SELECT name,
       cluster_type_desc
FROM sys.availability_groups

-- section: inst_has_distribution_db
-- Distribution database name is configurable. is_distributor covers a renamed database.
-- FOR XML PATH keeps the query valid on SQL Server 2016 (STRING_AGG is 2017+).
SELECT CASE WHEN EXISTS (
           SELECT 1 FROM sys.databases WHERE is_distributor = 1
       ) THEN 1 ELSE 0 END AS has_distribution,
       STUFF((
           SELECT N', ' + d.name
           FROM sys.databases AS d
           WHERE d.is_distributor = 1
           ORDER BY d.name
           FOR XML PATH(''), TYPE
       ).value('.', 'nvarchar(max)'), 1, 2, N'') AS distributor_databases

-- section: inst_repl_distributor
-- data_source is the distributor instance. A value other than this server means remote.
SELECT COUNT(*) AS cnt,
       MAX(data_source) AS data_source
FROM sys.servers
WHERE name = N'repl_distributor'

-- section: inst_log_shipping
-- One row per database. monitor_server is set on the primary; a monitor other than
-- this instance is the SQL Server 2025 remote-monitor certificate case.
SELECT N'PRIMARY' AS role,
       p.primary_database AS database_name,
       p.monitor_server
FROM msdb.dbo.log_shipping_primary_databases AS p
UNION ALL
SELECT N'SECONDARY',
       s.secondary_database,
       CAST(NULL AS sysname) AS monitor_server
FROM msdb.dbo.log_shipping_secondary_databases AS s

-- section: inst_agent_jobs
-- T-SQL step text is collected for static rules. Other subsystems are recorded by
-- name only so CmdExec / PowerShell / SSIS commands (often containing secrets) are
-- not copied into the assessment report.
SELECT j.name AS job_name,
       j.enabled AS job_enabled,
       s.step_id,
       s.step_name,
       s.subsystem,
       CASE WHEN s.subsystem = N'TSQL' THEN LEFT(s.command, 8000) ELSE NULL END AS command
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
ORDER BY j.name, s.step_id

-- section: inst_agent_notifications
-- notification_method bits: 1 = email, 2 = pager, 4 = net send. Email is not deprecated.
SELECT COUNT(*) AS cnt
FROM msdb.dbo.sysnotifications
WHERE (notification_method & 2) = 2
   OR (notification_method & 4) = 4

-- section: inst_trace_status
-- DBCC TRACESTATUS is read-only. It often requires ALTER TRACE or sysadmin, which the
-- least-privilege login does not have. A failure is a permission gap, not "no flags".
DBCC TRACESTATUS(-1) WITH NO_INFOMSGS

-- section: inst_deprecated_counters
-- Counters reset when the instance restarts. Zero means "not seen since startup".
SELECT RTRIM(instance_name) AS feature,
       MAX(CAST(cntr_value AS bigint)) AS hits
FROM sys.dm_os_performance_counters
WHERE object_name LIKE N'%Deprecated Features%'
GROUP BY instance_name
ORDER BY MAX(CAST(cntr_value AS bigint)) DESC

-- section: inst_endpoints
-- Non-TSQL endpoints: Service Broker, database mirroring, availability groups, SOAP.
-- SOAP / HTTP endpoints are discontinued. Passwords are not selected.
SELECT name, type_desc, protocol_desc, state_desc
FROM sys.endpoints
WHERE type_desc <> N'TSQL'

-- section: inst_server_triggers
-- Instance DDL triggers. definition may be NULL when the module is encrypted.
SELECT t.name, CAST(t.is_disabled AS int) AS is_disabled, m.definition
FROM sys.server_triggers AS t
LEFT JOIN sys.server_sql_modules AS m ON m.object_id = t.object_id
WHERE t.is_ms_shipped = 0

-- section: inst_trusted_assemblies
-- SQL Server 2017+. The advisor runs this only when the engine major is 14 or higher.
-- The hash is the trust identity. Assembly bytes are not selected.
SELECT CONVERT(varchar(128), hash, 1) AS hash, description
FROM sys.trusted_assemblies

-- section: inst_credentials
-- Names and identities only. The credential secret is not selected.
SELECT name, credential_identity
FROM sys.credentials

-- section: inst_agent_proxies
-- Proxy names only. The underlying credential secret is not selected.
SELECT name, CAST(enabled AS int) AS enabled
FROM msdb.dbo.sysproxies

-- section: inst_linked_logins
-- Mapping shape only. No password column is selected.
SELECT s.name AS server_name,
       CAST(ll.uses_self_credential AS int) AS uses_self_credential,
       ll.remote_name
FROM sys.linked_logins AS ll
JOIN sys.servers AS s ON s.server_id = ll.server_id
WHERE s.is_linked = 1
