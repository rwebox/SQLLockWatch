-- File: 99_Uninstall.sql
-- Description: Complete removal of all SQLLockWatch objects.
--              Drops Agent jobs, Extended Events session, stored procedures, and tables.
--              Database Mail profile and account removal is commented out by default
--              because they may be shared with other solutions.
-- Safe to re-run.

USE msdb;
GO

PRINT '=== SQLLockWatch: Uninstall ===';
PRINT '';

-- ============================================================
-- Step 1: Drop SQL Server Agent jobs
-- ============================================================
PRINT 'Step 1: Removing SQL Server Agent jobs...';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLLockWatch - Deadlock Monitor')
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name               = N'SQLLockWatch - Deadlock Monitor',
        @delete_unused_schedule = 1;
    PRINT '  Job ''SQLLockWatch - Deadlock Monitor'' dropped.';
END
ELSE
    PRINT '  Job ''SQLLockWatch - Deadlock Monitor'' not found. Skipping.';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLLockWatch - Blocking Monitor')
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name               = N'SQLLockWatch - Blocking Monitor',
        @delete_unused_schedule = 1;
    PRINT '  Job ''SQLLockWatch - Blocking Monitor'' dropped.';
END
ELSE
    PRINT '  Job ''SQLLockWatch - Blocking Monitor'' not found. Skipping.';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLLockWatch - Cleanup')
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name               = N'SQLLockWatch - Cleanup',
        @delete_unused_schedule = 1;
    PRINT '  Job ''SQLLockWatch - Cleanup'' dropped.';
END
ELSE
    PRINT '  Job ''SQLLockWatch - Cleanup'' not found. Skipping.';

PRINT '';

-- ============================================================
-- Step 2: Stop and drop the Extended Events session
-- ============================================================
PRINT 'Step 2: Removing Extended Events session ''SQLLockWatch_Deadlocks''...';

IF EXISTS (
    SELECT 1
    FROM sys.server_event_sessions
    WHERE name = 'SQLLockWatch_Deadlocks'
)
BEGIN
    IF EXISTS (
        SELECT 1
        FROM sys.dm_xe_sessions
        WHERE name = 'SQLLockWatch_Deadlocks'
    )
    BEGIN
        ALTER EVENT SESSION [SQLLockWatch_Deadlocks] ON SERVER STATE = STOP;
        PRINT '  XE session stopped.';
    END

    DROP EVENT SESSION [SQLLockWatch_Deadlocks] ON SERVER;
    PRINT '  XE session ''SQLLockWatch_Deadlocks'' dropped.';
END
ELSE
    PRINT '  XE session ''SQLLockWatch_Deadlocks'' not found. Skipping.';

PRINT '';

-- ============================================================
-- Step 3: Drop stored procedures
-- ============================================================
PRINT 'Step 3: Dropping stored procedures...';

IF OBJECT_ID('msdb.dbo.SQLLockWatch_CheckDeadlocks', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE msdb.dbo.SQLLockWatch_CheckDeadlocks;
    PRINT '  Procedure ''SQLLockWatch_CheckDeadlocks'' dropped.';
END
ELSE
    PRINT '  Procedure ''SQLLockWatch_CheckDeadlocks'' not found. Skipping.';

IF OBJECT_ID('msdb.dbo.SQLLockWatch_CheckBlocking', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE msdb.dbo.SQLLockWatch_CheckBlocking;
    PRINT '  Procedure ''SQLLockWatch_CheckBlocking'' dropped.';
END
ELSE
    PRINT '  Procedure ''SQLLockWatch_CheckBlocking'' not found. Skipping.';

IF OBJECT_ID('msdb.dbo.SQLLockWatch_PurgeHistory', 'P') IS NOT NULL
BEGIN
    DROP PROCEDURE msdb.dbo.SQLLockWatch_PurgeHistory;
    PRINT '  Procedure ''SQLLockWatch_PurgeHistory'' dropped.';
END
ELSE
    PRINT '  Procedure ''SQLLockWatch_PurgeHistory'' not found. Skipping.';

PRINT '';

-- ============================================================
-- Step 4: Drop tables
-- ============================================================
PRINT 'Step 4: Dropping tables...';

IF OBJECT_ID('msdb.dbo.SQLLockWatch_AlertHistory', 'U') IS NOT NULL
BEGIN
    DROP TABLE msdb.dbo.SQLLockWatch_AlertHistory;
    PRINT '  Table ''SQLLockWatch_AlertHistory'' dropped.';
END
ELSE
    PRINT '  Table ''SQLLockWatch_AlertHistory'' not found. Skipping.';

IF OBJECT_ID('msdb.dbo.SQLLockWatch_Config', 'U') IS NOT NULL
BEGIN
    DROP TABLE msdb.dbo.SQLLockWatch_Config;
    PRINT '  Table ''SQLLockWatch_Config'' dropped.';
END
ELSE
    PRINT '  Table ''SQLLockWatch_Config'' not found. Skipping.';

PRINT '';

-- ============================================================
-- Step 5: Database Mail cleanup (OPTIONAL — commented out by default)
--         Uncomment if the SQLLockWatch profile/account are not shared
--         with other solutions.
-- ============================================================
PRINT 'Step 5: Database Mail cleanup (skipped — uncomment in script to enable).';

/*
-- Remove account from profile
IF EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_profileaccount pa
    INNER JOIN msdb.dbo.sysmail_profile  p ON pa.profile_id = p.profile_id
    INNER JOIN msdb.dbo.sysmail_account  a ON pa.account_id = a.account_id
    WHERE p.name = 'SQLLockWatch'
      AND a.name = 'SQLLockWatch'
)
BEGIN
    EXEC msdb.dbo.sysmail_delete_profileaccount_sp
        @profile_name = 'SQLLockWatch',
        @account_name = 'SQLLockWatch';
    PRINT '  Account removed from profile.';
END

-- Drop profile
IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = 'SQLLockWatch')
BEGIN
    EXEC msdb.dbo.sysmail_delete_profile_sp
        @profile_name = 'SQLLockWatch';
    PRINT '  Profile ''SQLLockWatch'' dropped.';
END

-- Drop account
IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = 'SQLLockWatch')
BEGIN
    EXEC msdb.dbo.sysmail_delete_account_sp
        @account_name = 'SQLLockWatch';
    PRINT '  Account ''SQLLockWatch'' dropped.';
END
*/

PRINT '';
PRINT '=== SQLLockWatch uninstall complete. ===';
GO
