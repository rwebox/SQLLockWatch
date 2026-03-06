-- File: 05_Cleanup_Retention.sql
-- Description: Deploys the SQLLockWatch history retention (purge) mechanism.
--              Part A: Stored procedure that deletes old alert history rows.
--              Part B: SQL Server Agent job that runs the purge once daily at 3:00 AM.
-- Safe to re-run.

USE msdb;
GO

PRINT '=== SQLLockWatch: Cleanup / Retention Setup ===';
PRINT '';

-- ============================================================
-- PART A: Stored Procedure — SQLLockWatch_PurgeHistory
-- ============================================================
PRINT 'Part A: Creating stored procedure ''SQLLockWatch_PurgeHistory''...';
GO

CREATE OR ALTER PROCEDURE msdb.dbo.SQLLockWatch_PurgeHistory
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        -- Read retention period from config (default 30 days)
        DECLARE @RetentionDays INT;

        SELECT @RetentionDays = CAST(ConfigValue AS INT)
        FROM msdb.dbo.SQLLockWatch_Config
        WHERE ConfigKey = 'RetentionDays';

        SET @RetentionDays = ISNULL(@RetentionDays, 30);

        DECLARE @CutoffDate  DATETIME = DATEADD(DAY, -@RetentionDays, GETDATE());
        DECLARE @DeletedRows INT;

        DELETE FROM msdb.dbo.SQLLockWatch_AlertHistory
        WHERE AlertTime < @CutoffDate;

        SET @DeletedRows = @@ROWCOUNT;

        PRINT 'SQLLockWatch_PurgeHistory: deleted ' + CAST(@DeletedRows AS VARCHAR(10))
              + ' row(s) older than ' + CAST(@RetentionDays AS VARCHAR(10)) + ' day(s).';

        INSERT INTO msdb.dbo.SQLLockWatch_AlertHistory (AlertType, Details)
        VALUES ('CLEANUP', N'Purged ' + CAST(@DeletedRows AS NVARCHAR(10))
                            + N' row(s) older than ' + CAST(@RetentionDays AS NVARCHAR(10)) + N' day(s).');

    END TRY
    BEGIN CATCH

        DECLARE @ErrMsg  NVARCHAR(2048) = ERROR_MESSAGE();
        DECLARE @ErrLine INT            = ERROR_LINE();

        INSERT INTO msdb.dbo.SQLLockWatch_AlertHistory (AlertType, Details)
        VALUES ('ERROR', N'SQLLockWatch_PurgeHistory error at line '
                          + CAST(@ErrLine AS NVARCHAR(10)) + N': ' + @ErrMsg);

    END CATCH
END;
GO

PRINT '  Stored procedure ''SQLLockWatch_PurgeHistory'' created/updated.';
PRINT '';

-- ============================================================
-- PART B: SQL Server Agent Job
-- ============================================================
PRINT 'Part B: Creating SQL Server Agent job ''SQLLockWatch - Cleanup''...';
GO

-- Create job category if needed
IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.syscategories
    WHERE name = N'Database Maintenance' AND category_class = 1
)
BEGIN
    EXEC msdb.dbo.sp_add_category
        @class = N'JOB',
        @type  = N'LOCAL',
        @name  = N'Database Maintenance';
    PRINT '  Job category ''Database Maintenance'' created.';
END
GO

-- Drop existing job if present
IF EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLLockWatch - Cleanup'
)
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name               = N'SQLLockWatch - Cleanup',
        @delete_unused_schedule = 1;
    PRINT '  Existing job dropped.';
END
GO

DECLARE @JobID   UNIQUEIDENTIFIER;
DECLARE @SchedID INT;

EXEC msdb.dbo.sp_add_job
    @job_name         = N'SQLLockWatch - Cleanup',
    @enabled          = 1,
    @description      = N'Purges SQLLockWatch alert history older than the configured retention period.',
    @category_name    = N'Database Maintenance',
    @owner_login_name = N'sa',
    @job_id           = @JobID OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id            = @JobID,
    @step_name         = N'Purge History',
    @step_id           = 1,
    @subsystem         = N'TSQL',
    @command           = N'EXEC msdb.dbo.SQLLockWatch_PurgeHistory;',
    @database_name     = N'msdb',
    @on_success_action = 1,
    @on_fail_action    = 2;

-- Schedule: once daily at 3:00 AM
EXEC msdb.dbo.sp_add_schedule
    @schedule_name          = N'SQLLockWatch_Cleanup_Daily3AM',
    @enabled                = 1,
    @freq_type              = 4,      -- Daily
    @freq_interval          = 1,
    @freq_subday_type       = 1,      -- Once
    @freq_subday_interval   = 0,
    @freq_relative_interval = 0,
    @freq_recurrence_factor = 0,
    @active_start_date      = 19900101,
    @active_end_date        = 99991231,
    @active_start_time      = 30000,  -- 03:00:00
    @active_end_time        = 235959,
    @schedule_id            = @SchedID OUTPUT;

EXEC msdb.dbo.sp_attach_schedule
    @job_id      = @JobID,
    @schedule_id = @SchedID;

EXEC msdb.dbo.sp_add_jobserver
    @job_id      = @JobID,
    @server_name = N'(local)';

PRINT '  Job ''SQLLockWatch - Cleanup'' created and enabled (runs daily at 3:00 AM).';
PRINT '';
GO

PRINT '=== Cleanup / Retention setup complete. ===';
GO
