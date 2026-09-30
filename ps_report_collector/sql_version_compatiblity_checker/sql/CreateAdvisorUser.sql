/* =====================================================================================
   SQL Upgrade Advisor - least-privilege login for the assessment
   =====================================================================================
   Run this ONCE on the SOURCE instance, before invoking Invoke-SqlUpgradeAdvisor.ps1.

       Invoke-Sqlcmd -ServerInstance SOURCE01 -InputFile .\CreateAdvisorUser.sql
       -- or in SSMS: switch to the SOURCE server, press Ctrl+Shift+M is NOT used here;
       -- the script has no sqlcmd variables: edit the two literals in section 1 only.

   WHAT IT CREATES
     * a SQL login (or you may reuse an AD group - see the note in section 1)
     * the minimum grants required by the advisor's collection queries

   WHAT THE ADVISOR ACTUALLY RUNS (all read-only, one file each - see the other
   .sql files in this folder for the exact text):
     sys.configurations / sys.databases / sys.servers / sys.database_mirroring
     sys.availability_groups / sys.objects / sys.sql_modules / sys.triggers
     sys.assembly_modules / sys.assemblies / sys.certificates / sys.asymmetric_keys
     sys.tables / sys.columns / sys.types / sys.computed_columns / sys.indexes
     sys.synonyms / sys.external_* / sys.fulltext_indexes
     sys.sql_expression_dependencies           -> metadata:  VIEW ANY DEFINITION
     sys.dm_os_performance_counters            -> VIEW SERVER STATE
     sys.dm_exec_procedure_stats / _trigger    -> VIEW SERVER STATE (VIEW SERVER
                                                   PERFORMANCE STATE on 2022+)
     sys.database_query_store_options          -> VIEW DATABASE STATE (VIEW DATABASE
                                                   PERFORMANCE STATE on 2022+)
     msdb.dbo.sysjobs / sysjobsteps /          -> SQLAgentReaderRole + explicit SELECT
       sysnotifications / log_shipping_*
     DBCC TRACESTATUS(-1)                      -> no extra grant (read-only, public)
     IS_SRVROLEMEMBER / HAS_PERMS_BY_NAME      -> public

   IT CREATES NOTHING ON THE SERVER: no database, no job, no trace, no DDL, no DML.
   The advisor itself only issues SELECT and DBCC TRACESTATUS.

   PREREQUISITES
     * the login must be created by a sysadmin (or someone with CONTROL SERVER)
     * section 5 (per-database grants) must be re-run whenever a new database is
       added - or use CONNECT ANY DATABASE (section 2) which covers future ones.
   ===================================================================================== */

SET NOCOUNT ON;
USE master;
GO

/* =====================================================================================
   1) EDIT THESE TWO LITERALS
   =====================================================================================
   Keep the login name short and stable; the advisor's -Credential example uses it as
   the SQL-auth user. Password must satisfy the Windows password policy because
   CHECK_POLICY = ON (required by most estates; leave it on).
   ===================================================================================== */
DECLARE @login  sysname = N'sql_upgrade_advisor';          -- EDIT
DECLARE @pwd    nvarchar(128) = N'';                       -- EDIT: set a strong password; do not commit it
DECLARE @defdb  sysname = N'master';

IF SUSER_ID(@login) IS NULL AND (@pwd = N'' OR @pwd LIKE N'CHANGE_ME%')
BEGIN
    RAISERROR('Set @pwd in section 1 before creating the login. Do not store the password in this file.', 16, 1);
    RETURN;
END

IF SUSER_ID(@login) IS NOT NULL
BEGIN
    PRINT 'Login [' + @login + '] already exists - skipping CREATE LOGIN.';
END
ELSE
BEGIN
    DECLARE @sql nvarchar(max) = N'
        CREATE LOGIN [' + REPLACE(@login, N']', N']]') + N']
        WITH PASSWORD = @pwdIn, DEFAULT_DATABASE = [' + REPLACE(@defdb, N']', N']]') + N'],
               CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;';
    EXEC sp_executesql @sql, N'@pwdIn nvarchar(128)', @pwdIn = @pwd;
    PRINT 'Created login [' + @login + '].';
END

-- Do not let the login own anything; keep it out of sysadmin by construction.
IF IS_SRVROLEMEMBER('sysadmin', @login) = 1
    PRINT 'WARNING: [' + @login + '] is a member of sysadmin - remove it; the advisor needs no sysadmin rights.';
GO

/* =====================================================================================
   2) SERVER-LEVEL PERMISSIONS  (master)
   ===================================================================================== */
DECLARE @login sysname = N'sql_upgrade_advisor';           -- must match section 1
IF SUSER_ID(@login) IS NULL
BEGIN
    RAISERROR('Login not found - fix section 1 first.', 16, 1);
    RETURN;
END

DECLARE @stmt TABLE (sql_text nvarchar(400));
INSERT INTO @stmt (sql_text) VALUES
    (N'GRANT CONNECT SQL TO [' + @login + N'];'),               -- implicit, made explicit
    (N'GRANT VIEW ANY DATABASE TO [' + @login + N'];'),         -- list every database
    (N'GRANT VIEW ANY DEFINITION TO [' + @login + N'];'),       -- sys.sql_modules.definition + all metadata
    (N'GRANT VIEW SERVER STATE TO [' + @login + N'];');         -- DMV + performance counters (2016/2019)

DECLARE @s nvarchar(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT sql_text FROM @stmt;
OPEN c;
FETCH NEXT FROM c INTO @s;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC sp_executesql @s;
        PRINT 'OK   ' + @s;
    END TRY
    BEGIN CATCH
        PRINT 'FAIL ' + @s + ' -> ' + ERROR_MESSAGE();
    END CATCH
    FETCH NEXT FROM c INTO @s;
END
CLOSE c; DEALLOCATE c;

-- 2022 / 2025 split VIEW SERVER STATE into a performance tier. These grants fail
-- harmlessly (PRINT'd above pattern) on older versions, so try/catch them.
DECLARE @late TABLE (sql_text nvarchar(400));
INSERT INTO @late (sql_text) VALUES
    (N'GRANT VIEW SERVER PERFORMANCE STATE TO [' + @login + N'];'),
    (N'GRANT CONNECT ANY DATABASE TO [' + @login + N'];'),
    (N'GRANT VIEW ANY DEFINITION TO [' + @login + N'];');

DECLARE c2 CURSOR LOCAL FAST_FORWARD FOR SELECT sql_text FROM @late;
OPEN c2;
FETCH NEXT FROM c2 INTO @s;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC sp_executesql @s;
        PRINT 'OK   ' + @s;
    END TRY
    BEGIN CATCH
        PRINT 'SKIP ' + @s + ' -> ' + ERROR_MESSAGE();   -- unsupported on this version
    END CATCH
    FETCH NEXT FROM c2 INTO @s;
END
CLOSE c2; DEALLOCATE c2;
GO

/* =====================================================================================
   3) msdb  (SQL Agent job inventory + log shipping inventory)
   =====================================================================================
   SQLAgentReaderRole is the documented read-only role: it can read jobs, steps,
   schedules and history but cannot modify or run them. The advisor also reads
   sysnotifications and the two log_shipping tables, which that role does not cover,
   so grant SELECT on exactly those three.
   ===================================================================================== */
DECLARE @login sysname = N'sql_upgrade_advisor';           -- must match section 1
IF SUSER_ID(@login) IS NULL RETURN;

USE msdb;

IF IS_ROLEMEMBER('SQLAgentReaderRole', @login) = 1
    PRINT 'OK   [' + @login + '] is already a member of msdb.SQLAgentReaderRole.';
ELSE
BEGIN
    BEGIN TRY
        EXEC sp_addrolemember @rolename = N'SQLAgentReaderRole', @membername = @login;
        PRINT 'OK   added [' + @login + '] to msdb.SQLAgentReaderRole.';
    END TRY
    BEGIN CATCH
        PRINT 'FAIL SQLAgentReaderRole -> ' + ERROR_MESSAGE();
    END CATCH
END

-- These three tables exist only when the feature has been configured at least once,
-- so probe first and skip quietly when the feature is absent.
DECLARE @t TABLE (obj sysname);
INSERT INTO @t VALUES (N'sysnotifications'),
                      (N'log_shipping_primary_databases'),
                      (N'log_shipping_secondary_databases');

DECLARE @name sysname, @sql nvarchar(400);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT obj FROM @t;
OPEN c;
FETCH NEXT FROM c INTO @name;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(N'msdb.dbo.' + @name, N'U') IS NOT NULL
       OR OBJECT_ID(N'msdb.dbo.' + @name, N'V') IS NOT NULL
    BEGIN
        SET @sql = N'GRANT SELECT ON msdb.dbo.' + QUOTENAME(@name) + N' TO [' + @login + N'];';
        BEGIN TRY
            EXEC sp_executesql @sql;
            PRINT 'OK   ' + @sql;
        END TRY
        BEGIN CATCH
            PRINT 'FAIL ' + @sql + ' -> ' + ERROR_MESSAGE();
        END CATCH
    END
    ELSE
        PRINT 'SKIP ' + @name + ' (not present - feature never configured)';
    FETCH NEXT FROM c INTO @name;
END
CLOSE c; DEALLOCATE c;
GO

/* =====================================================================================
   4) PER-DATABASE PERMISSIONS  (every online user database)
   =====================================================================================
     CONNECT             - open a connection to the database (skipped when
                           CONNECT ANY DATABASE already granted in section 2)
     VIEW DEFINITION     - sys.objects / sys.sql_modules.definition / sys.indexes /
                           sys.columns / sys.synonyms / sys.assemblies / ...
     VIEW DATABASE STATE - sys.database_query_store_options (plan baseline evidence)

   Re-run section 4 after restoring or creating a new database.
   ===================================================================================== */
DECLARE @login sysname = N'sql_upgrade_advisor';           -- must match section 1
IF SUSER_ID(@login) IS NULL RETURN;

DECLARE @db sysname, @stmt nvarchar(400);
DECLARE dbcur CURSOR LOCAL FAST_FORWARD FOR
    SELECT name FROM sys.databases
    WHERE state_desc = 'ONLINE'
      AND user_access_desc = 'MULTI_USER'
      AND database_id <> 2          -- tempdb: never needed
      AND name NOT IN (N'master', N'msdb');   -- granted separately below
OPEN dbcur;
FETCH NEXT FROM dbcur INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @stmt = N'USE [' + REPLACE(@db, N']', N']]') + N'];
                 IF HAS_PERMS_BY_NAME(DB_NAME(), ''DATABASE'', ''CONNECT'') = 0
                     GRANT CONNECT TO [' + @login + N'];
                 GRANT VIEW DEFINITION TO [' + @login + N'];
                 GRANT VIEW DATABASE STATE TO [' + @login + N'];';
    BEGIN TRY
        EXEC sp_executesql @stmt;
        PRINT 'OK   ' + @db + ' : CONNECT / VIEW DEFINITION / VIEW DATABASE STATE';
    END TRY
    BEGIN CATCH
        PRINT 'FAIL ' + @db + ' -> ' + ERROR_MESSAGE();
    END CATCH
    FETCH NEXT FROM dbcur INTO @db;
END
CLOSE dbcur; DEALLOCATE dbcur;
GO

/* =====================================================================================
   5) MASTER  (the advisor opens its instance-level session against master)
   ===================================================================================== */
DECLARE @login sysname = N'sql_upgrade_advisor';           -- must match section 1
IF SUSER_ID(@login) IS NULL RETURN;
USE master;
BEGIN TRY
    IF HAS_PERMS_BY_NAME(N'master', N'DATABASE', N'CONNECT') = 0
        EXEC (N'GRANT CONNECT TO [' + @login + N'];');
    EXEC (N'GRANT VIEW DEFINITION TO [' + @login + N'];');
    EXEC (N'GRANT VIEW DATABASE STATE TO [' + @login + N'];');
    PRINT 'OK   master : CONNECT / VIEW DEFINITION / VIEW DATABASE STATE';
END TRY
BEGIN CATCH
    PRINT 'FAIL master -> ' + ERROR_MESSAGE();
END CATCH
GO

/* =====================================================================================
   6) VERIFICATION - every line should return 1 (or a granted permission)
   ===================================================================================== */
DECLARE @login sysname = N'sql_upgrade_advisor';           -- must match section 1
SELECT step = N'login exists',                       value = CASE WHEN SUSER_ID(@login) IS NOT NULL THEN 1 ELSE 0 END
UNION ALL SELECT N'not sysadmin',                    value = CASE WHEN IS_SRVROLEMEMBER('sysadmin', @login) = 0 THEN 1 ELSE 0 END
UNION ALL SELECT N'VIEW SERVER STATE',               value = CASE WHEN HAS_PERMS_BY_NAME(@login, 'SERVER', 'VIEW SERVER STATE') = 1 THEN 1 ELSE 0 END
UNION ALL SELECT N'VIEW ANY DEFINITION',             value = CASE WHEN HAS_PERMS_BY_NAME(@login, 'SERVER', 'VIEW ANY DEFINITION') = 1 THEN 1 ELSE 0 END
UNION ALL SELECT N'VIEW ANY DATABASE',               value = CASE WHEN HAS_PERMS_BY_NAME(@login, 'SERVER', 'VIEW ANY DATABASE') = 1 THEN 1 ELSE 0 END
UNION ALL SELECT N'CONNECT ANY DATABASE (2012+)',    value = CASE WHEN HAS_PERMS_BY_NAME(@login, 'SERVER', 'CONNECT ANY DATABASE') = 1 THEN 1 ELSE 0 END;

-- Where the login can see module source (should be every user database, value > 0)
SELECT database_name = d.name,
       can_view_definition = HAS_PERMS_BY_NAME(d.name, 'DATABASE', 'VIEW DEFINITION'),
       can_view_db_state   = HAS_PERMS_BY_NAME(d.name, 'DATABASE', 'VIEW DATABASE STATE')
FROM sys.databases d
WHERE d.state_desc = 'ONLINE' AND d.database_id NOT IN (2, 3, 4)
ORDER BY d.name;

-- msdb coverage
USE msdb;
SELECT job_reader_role = IS_ROLEMEMBER('SQLAgentReaderRole', @login);
GO

/* =====================================================================================
   7) REMOVAL / REVOKE  (run when the assessment is finished)
   ===================================================================================== */
/*
DECLARE @login sysname = N'sql_upgrade_advisor';
USE msdb;
IF IS_ROLEMEMBER('SQLAgentReaderRole', @login) = 1
    EXEC sp_droprolemember @rolename = N'SQLAgentReaderRole', @membername = @login;
EXEC (N'REVOKE SELECT ON msdb.dbo.sysnotifications FROM [' + @login + N'];');
EXEC (N'REVOKE SELECT ON msdb.dbo.log_shipping_primary_databases FROM [' + @login + N'];');
EXEC (N'REVOKE SELECT ON msdb.dbo.log_shipping_secondary_databases FROM [' + @login + N'];');

DECLARE @db sysname;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.databases WHERE database_id <> 2;
OPEN c; FETCH NEXT FROM c INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY
        EXEC (N'USE [' + REPLACE(@db, N']', N']]') + N'];
              REVOKE VIEW DATABASE STATE FROM [' + @login + N'];
              REVOKE VIEW DEFINITION FROM [' + @login + N'];
              REVOKE CONNECT FROM [' + @login + N'];');
    END TRY BEGIN CATCH END CATCH
    FETCH NEXT FROM c INTO @db;
END
CLOSE c; DEALLOCATE c;

USE master;
REVOKE VIEW SERVER STATE FROM [sql_upgrade_advisor];
REVOKE VIEW ANY DEFINITION FROM [sql_upgrade_advisor];
REVOKE VIEW ANY DATABASE FROM [sql_upgrade_advisor];
REVOKE CONNECT ANY DATABASE FROM [sql_upgrade_advisor];
REVOKE CONNECT SQL FROM [sql_upgrade_advisor];
DROP LOGIN [sql_upgrade_advisor];
*/
