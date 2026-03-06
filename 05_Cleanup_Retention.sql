/*
================================================================================
  SQLLockWatch — 05_Cleanup_Retention.sql
  Stored procedure : msdb.dbo.SQLLockWatch_PurgeHistory
  SQL Server Agent job : SQLLockWatch - History Cleanup  (daily at 03:00)

  Safe to re-run.
================================================================================
*/

USE msdb;
GO

PRINT '======================================================';
PRINT ' SQLLockWatch — History Cleanup Deployment';
PRINT '======================================================';
PRINT '';

-- ============================================================
-- Stored Procedure: SQLLockWatch_PurgeHistory
-- ============================================================
PRINT 'Creating stored procedure SQLLockWatch_PurgeHistory...';
GO

CREATE OR ALTER PROCEDURE msdb.dbo.SQLLockWatch_PurgeHistory
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        -- Read retention setting
        DECLARE @RetentionDays INT;

        SELECT @RetentionDays = CAST(ConfigValue AS INT)
        FROM   msdb.dbo.SQLLockWatch_Config
        WHERE  ConfigKey = 'RetentionDays';

        SET @RetentionDays = ISNULL(@RetentionDays, 28);

        -- --------------------------------------------------------
        -- Purge old alert log rows
        -- --------------------------------------------------------
        DECLARE @AlertLogCutoff DATETIME = DATEADD(DAY, -@RetentionDays, GETDATE());

        DELETE FROM msdb.dbo.SQLLockWatch_AlertLog
        WHERE  AlertTime < @AlertLogCutoff;

        DECLARE @AlertLogDeleted INT = @@ROWCOUNT;

        PRINT 'SQLLockWatch_PurgeHistory: Deleted ' + CAST(@AlertLogDeleted AS VARCHAR(10))
            + ' row(s) from SQLLockWatch_AlertLog (retention: '
            + CAST(@RetentionDays AS VARCHAR(10)) + ' days).';

        -- --------------------------------------------------------
        -- Purge old cooldown rows (always keep last 1 day)
        -- --------------------------------------------------------
        DECLARE @CooldownCutoff DATETIME = DATEADD(DAY, -1, GETDATE());

        DELETE FROM msdb.dbo.SQLLockWatch_Cooldown
        WHERE  LastAlertTime < @CooldownCutoff;

        DECLARE @CooldownDeleted INT = @@ROWCOUNT;

        PRINT 'SQLLockWatch_PurgeHistory: Deleted ' + CAST(@CooldownDeleted AS VARCHAR(10))
            + ' row(s) from SQLLockWatch_Cooldown.';

    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrLine INT            = ERROR_LINE();

        PRINT 'ERROR in SQLLockWatch_PurgeHistory (line '
            + CAST(@ErrLine AS VARCHAR(10)) + '): ' + @ErrMsg;

        -- Log the error in the alert log if possible
        INSERT INTO msdb.dbo.SQLLockWatch_AlertLog (AlertType, Details, EmailSent)
        VALUES ('CLEANUP', N'ERROR in SQLLockWatch_PurgeHistory (line '
                + CAST(@ErrLine AS NVARCHAR(10)) + N'): ' + @ErrMsg, 0);
    END CATCH
END
GO

PRINT '  Stored procedure created.';
PRINT '';

-- ============================================================
-- SQL Server Agent Job
-- ============================================================
PRINT 'Creating Agent job ''SQLLockWatch - History Cleanup''...';
GO

-- Create the job category if it doesn't exist
IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.syscategories
    WHERE name = N'Database Maintenance' AND category_class = 1
)
BEGIN
    EXEC msdb.dbo.sp_add_category
        @class = N'JOB',
        @type  = N'LOCAL',
        @name  = N'Database Maintenance';
END

-- Drop existing job if it exists
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLLockWatch - History Cleanup')
    EXEC msdb.dbo.sp_delete_job
        @job_name = N'SQLLockWatch - History Cleanup',
        @delete_unused_schedule = 1;

-- Create the job
DECLARE @JobID UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name            = N'SQLLockWatch - History Cleanup',
    @enabled             = 1,
    @description         = N'Purges old alert history from SQLLockWatch tables in msdb.',
    @category_name       = N'Database Maintenance',
    @owner_login_name    = N'sa',
    @job_id              = @JobID OUTPUT;

-- Add job step
EXEC msdb.dbo.sp_add_jobstep
    @job_id            = @JobID,
    @step_name         = N'Purge History',
    @step_id           = 1,
    @subsystem         = N'TSQL',
    @command           = N'EXEC msdb.dbo.SQLLockWatch_PurgeHistory;',
    @database_name     = N'msdb',
    @on_success_action = 1,  -- quit with success
    @on_fail_action    = 2;  -- quit with failure

-- Add schedule (daily at 03:00 AM)
EXEC msdb.dbo.sp_add_jobschedule
    @job_id               = @JobID,
    @name                 = N'SQLLockWatch - History Cleanup - Daily 3AM',
    @enabled              = 1,
    @freq_type            = 4,     -- daily
    @freq_interval        = 1,
    @freq_subday_type     = 1,     -- once per day
    @freq_subday_interval = 0,
    @active_start_time    = 030000; -- 03:00:00

-- Attach to local server
EXEC msdb.dbo.sp_add_jobserver
    @job_id      = @JobID,
    @server_name = N'(local)';

PRINT '  Agent job created (daily at 03:00 AM).';
PRINT '';

PRINT '======================================================';
PRINT ' History Cleanup deployment complete.';
PRINT '   Procedure : msdb.dbo.SQLLockWatch_PurgeHistory';
PRINT '   Agent Job : SQLLockWatch - History Cleanup';
PRINT '   Schedule  : Daily at 03:00 AM';
PRINT '======================================================';
GO
