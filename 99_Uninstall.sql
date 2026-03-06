/*
================================================================================
  SQLLockWatch — 99_Uninstall.sql
  Completely removes all SQLLockWatch objects from this SQL Server instance.
  Safe to run even if some objects do not exist.

  Objects removed:
    - SQL Server Agent jobs (3)
    - Extended Events session
    - Stored procedures in msdb (3)
    - Tables in msdb (3)
    - Database Mail profile and account (SQLLockWatch)
================================================================================
*/

PRINT '======================================================';
PRINT ' SQLLockWatch — Uninstall';
PRINT '======================================================';
PRINT '';

-- ============================================================
-- Step 1: Drop Agent Jobs
-- ============================================================
PRINT 'Step 1: Removing SQL Server Agent jobs...';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLLockWatch - Deadlock Monitor')
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name = N'SQLLockWatch - Deadlock Monitor',
        @delete_unused_schedule = 1;
    PRINT '  Dropped job: SQLLockWatch - Deadlock Monitor';
END
ELSE
    PRINT '  Job not found (skipping): SQLLockWatch - Deadlock Monitor';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLLockWatch - Blocking Monitor')
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name = N'SQLLockWatch - Blocking Monitor',
        @delete_unused_schedule = 1;
    PRINT '  Dropped job: SQLLockWatch - Blocking Monitor';
END
ELSE
    PRINT '  Job not found (skipping): SQLLockWatch - Blocking Monitor';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLLockWatch - History Cleanup')
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name = N'SQLLockWatch - History Cleanup',
        @delete_unused_schedule = 1;
    PRINT '  Dropped job: SQLLockWatch - History Cleanup';
END
ELSE
    PRINT '  Job not found (skipping): SQLLockWatch - History Cleanup';

PRINT '';

-- ============================================================
-- Step 2: Stop and Drop Extended Events Session
-- ============================================================
PRINT 'Step 2: Removing Extended Events session...';

IF EXISTS (SELECT 1 FROM sys.server_event_sessions WHERE name = N'SQLLockWatch_Deadlocks')
BEGIN
    -- Stop the session if it is running
    IF EXISTS (SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'SQLLockWatch_Deadlocks')
    BEGIN
        ALTER EVENT SESSION [SQLLockWatch_Deadlocks] ON SERVER STATE = STOP;
        PRINT '  Stopped XE session: SQLLockWatch_Deadlocks';
    END

    DROP EVENT SESSION [SQLLockWatch_Deadlocks] ON SERVER;
    PRINT '  Dropped XE session: SQLLockWatch_Deadlocks';
END
ELSE
    PRINT '  XE session not found (skipping): SQLLockWatch_Deadlocks';

PRINT '';

-- ============================================================
-- Step 3: Drop Stored Procedures
-- ============================================================
PRINT 'Step 3: Removing stored procedures...';

IF OBJECT_ID(N'msdb.dbo.SQLLockWatch_CheckDeadlocks', N'P') IS NOT NULL
BEGIN
    DROP PROCEDURE msdb.dbo.SQLLockWatch_CheckDeadlocks;
    PRINT '  Dropped procedure: msdb.dbo.SQLLockWatch_CheckDeadlocks';
END
ELSE
    PRINT '  Procedure not found (skipping): SQLLockWatch_CheckDeadlocks';

IF OBJECT_ID(N'msdb.dbo.SQLLockWatch_CheckBlocking', N'P') IS NOT NULL
BEGIN
    DROP PROCEDURE msdb.dbo.SQLLockWatch_CheckBlocking;
    PRINT '  Dropped procedure: msdb.dbo.SQLLockWatch_CheckBlocking';
END
ELSE
    PRINT '  Procedure not found (skipping): SQLLockWatch_CheckBlocking';

IF OBJECT_ID(N'msdb.dbo.SQLLockWatch_PurgeHistory', N'P') IS NOT NULL
BEGIN
    DROP PROCEDURE msdb.dbo.SQLLockWatch_PurgeHistory;
    PRINT '  Dropped procedure: msdb.dbo.SQLLockWatch_PurgeHistory';
END
ELSE
    PRINT '  Procedure not found (skipping): SQLLockWatch_PurgeHistory';

PRINT '';

-- ============================================================
-- Step 4: Drop Tables
-- ============================================================
PRINT 'Step 4: Removing tables...';

IF OBJECT_ID(N'msdb.dbo.SQLLockWatch_AlertLog', N'U') IS NOT NULL
BEGIN
    DROP TABLE msdb.dbo.SQLLockWatch_AlertLog;
    PRINT '  Dropped table: msdb.dbo.SQLLockWatch_AlertLog';
END
ELSE
    PRINT '  Table not found (skipping): SQLLockWatch_AlertLog';

IF OBJECT_ID(N'msdb.dbo.SQLLockWatch_Cooldown', N'U') IS NOT NULL
BEGIN
    DROP TABLE msdb.dbo.SQLLockWatch_Cooldown;
    PRINT '  Dropped table: msdb.dbo.SQLLockWatch_Cooldown';
END
ELSE
    PRINT '  Table not found (skipping): SQLLockWatch_Cooldown';

IF OBJECT_ID(N'msdb.dbo.SQLLockWatch_Config', N'U') IS NOT NULL
BEGIN
    DROP TABLE msdb.dbo.SQLLockWatch_Config;
    PRINT '  Dropped table: msdb.dbo.SQLLockWatch_Config';
END
ELSE
    PRINT '  Table not found (skipping): SQLLockWatch_Config';

PRINT '';

-- ============================================================
-- Step 5: Remove Database Mail Profile and Account
-- ============================================================
PRINT 'Step 5: Removing Database Mail profile and account...';

-- Remove profile-account association first
IF EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_profileaccount pa
    JOIN msdb.dbo.sysmail_profile        pr ON pa.profile_id = pr.profile_id
    JOIN msdb.dbo.sysmail_account        ac ON pa.account_id = ac.account_id
    WHERE pr.name = N'SQLLockWatch'
      AND ac.name = N'SQLLockWatch'
)
BEGIN
    EXEC msdb.dbo.sysmail_delete_profileaccount_sp
        @profile_name = N'SQLLockWatch',
        @account_name = N'SQLLockWatch';
    PRINT '  Removed profile-account association.';
END

IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = N'SQLLockWatch')
BEGIN
    EXEC msdb.dbo.sysmail_delete_profile_sp
        @profile_name = N'SQLLockWatch';
    PRINT '  Dropped Database Mail profile: SQLLockWatch';
END
ELSE
    PRINT '  Profile not found (skipping): SQLLockWatch';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = N'SQLLockWatch')
BEGIN
    EXEC msdb.dbo.sysmail_delete_account_sp
        @account_name = N'SQLLockWatch';
    PRINT '  Dropped Database Mail account: SQLLockWatch';
END
ELSE
    PRINT '  Account not found (skipping): SQLLockWatch';

PRINT '';

-- ============================================================
PRINT '======================================================';
PRINT ' SQLLockWatch uninstall complete.';
PRINT ' All SQLLockWatch objects have been removed.';
PRINT '======================================================';
