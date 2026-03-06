-- File: 04_Deploy_BlockingMonitor.sql
-- Description: Deploys the SQLLockWatch blocking monitor.
--              Part A: Stored procedure that detects blocking chains and sends HTML email alerts.
--              Part B: SQL Server Agent job that runs the procedure every minute.
-- Safe to re-run.

USE msdb;
GO

PRINT '=== SQLLockWatch: Blocking Monitor Deployment ===';
PRINT '';

-- ============================================================
-- PART A: Stored Procedure — SQLLockWatch_CheckBlocking
-- ============================================================
PRINT 'Part A: Creating stored procedure ''SQLLockWatch_CheckBlocking''...';
GO

CREATE OR ALTER PROCEDURE msdb.dbo.SQLLockWatch_CheckBlocking
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        -- --------------------------------------------------------
        -- Read configuration
        -- --------------------------------------------------------
        DECLARE @MailProfile         VARCHAR(100);
        DECLARE @EmailRecipients     VARCHAR(500);
        DECLARE @CooldownMinutes     INT;
        DECLARE @MonitorEnabled      BIT;
        DECLARE @ThresholdSeconds    INT;

        SELECT
            @MailProfile          = MAX(CASE WHEN ConfigKey = 'MailProfile'              THEN ConfigValue END),
            @EmailRecipients      = MAX(CASE WHEN ConfigKey = 'EmailRecipients'          THEN ConfigValue END),
            @CooldownMinutes      = CAST(MAX(CASE WHEN ConfigKey = 'AlertCooldownMinutes'    THEN ConfigValue END) AS INT),
            @MonitorEnabled       = CAST(MAX(CASE WHEN ConfigKey = 'BlockingMonitorEnabled'  THEN ConfigValue END) AS BIT),
            @ThresholdSeconds     = CAST(MAX(CASE WHEN ConfigKey = 'BlockingThresholdSeconds' THEN ConfigValue END) AS INT)
        FROM msdb.dbo.SQLLockWatch_Config
        WHERE ConfigKey IN (
            'MailProfile', 'EmailRecipients', 'AlertCooldownMinutes',
            'BlockingMonitorEnabled', 'BlockingThresholdSeconds'
        );

        -- Apply defaults for safety
        SET @CooldownMinutes  = ISNULL(@CooldownMinutes,  5);
        SET @ThresholdSeconds = ISNULL(@ThresholdSeconds, 30);

        -- Exit early if monitor is disabled
        IF ISNULL(@MonitorEnabled, 0) = 0
        BEGIN
            RETURN;
        END

        -- --------------------------------------------------------
        -- Cooldown check
        -- --------------------------------------------------------
        DECLARE @CooldownCutoff DATETIME = DATEADD(MINUTE, -@CooldownMinutes, GETDATE());

        IF EXISTS (
            SELECT 1
            FROM msdb.dbo.SQLLockWatch_AlertHistory
            WHERE AlertType = 'BLOCKING'
              AND AlertTime >= @CooldownCutoff
        )
        BEGIN
            RETURN;
        END

        -- --------------------------------------------------------
        -- Find blocking chains exceeding the threshold
        -- --------------------------------------------------------
        CREATE TABLE #BlockingChains (
            BlockerSPID      INT,
            BlockedSPID      INT,
            WaitTimeSeconds  INT,
            WaitType         NVARCHAR(60),
            WaitResource     NVARCHAR(256),
            DatabaseName     NVARCHAR(128),
            BlockedLogin     NVARCHAR(128),
            BlockedHost      NVARCHAR(128),
            BlockedProgram   NVARCHAR(256),
            BlockedQuery     NVARCHAR(MAX),
            BlockerLogin     NVARCHAR(128),
            BlockerHost      NVARCHAR(128),
            BlockerProgram   NVARCHAR(256),
            BlockerQuery     NVARCHAR(MAX),
            IsHeadBlocker    BIT
        );

        INSERT INTO #BlockingChains (
            BlockerSPID, BlockedSPID, WaitTimeSeconds, WaitType, WaitResource,
            DatabaseName, BlockedLogin, BlockedHost, BlockedProgram, BlockedQuery,
            BlockerLogin, BlockerHost, BlockerProgram, BlockerQuery, IsHeadBlocker
        )
        SELECT
            r.blocking_session_id                                                   AS BlockerSPID,
            r.session_id                                                            AS BlockedSPID,
            r.wait_time / 1000                                                      AS WaitTimeSeconds,
            r.wait_type                                                             AS WaitType,
            r.wait_resource                                                         AS WaitResource,
            DB_NAME(r.database_id)                                                  AS DatabaseName,
            blocked_s.login_name                                                    AS BlockedLogin,
            blocked_s.host_name                                                     AS BlockedHost,
            blocked_s.program_name                                                  AS BlockedProgram,
            CAST(blocked_t.text AS NVARCHAR(MAX))                                   AS BlockedQuery,
            blocker_s.login_name                                                    AS BlockerLogin,
            blocker_s.host_name                                                     AS BlockerHost,
            blocker_s.program_name                                                  AS BlockerProgram,
            CAST(blocker_t.text AS NVARCHAR(MAX))                                   AS BlockerQuery,
            -- IsHeadBlocker: blocker that is not itself blocked
            CASE WHEN NOT EXISTS (
                    SELECT 1
                    FROM sys.dm_exec_requests r2
                    WHERE r2.session_id = r.blocking_session_id
                      AND r2.blocking_session_id > 0
                ) THEN 1 ELSE 0 END                                                AS IsHeadBlocker
        FROM sys.dm_exec_requests r
        INNER JOIN sys.dm_exec_sessions blocked_s  ON r.session_id           = blocked_s.session_id
        INNER JOIN sys.dm_exec_sessions blocker_s  ON r.blocking_session_id  = blocker_s.session_id
        OUTER APPLY sys.dm_exec_sql_text(r.sql_handle)                         AS blocked_t
        OUTER APPLY sys.dm_exec_sql_text(blocker_s.most_recent_sql_handle)    AS blocker_t
        WHERE r.blocking_session_id > 0
          AND r.wait_time / 1000 >= @ThresholdSeconds;

        IF NOT EXISTS (SELECT 1 FROM #BlockingChains)
        BEGIN
            DROP TABLE #BlockingChains;
            RETURN;
        END

        -- --------------------------------------------------------
        -- Build HTML email
        -- --------------------------------------------------------
        DECLARE @ServerName    NVARCHAR(128) = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128));
        DECLARE @DetectionTime VARCHAR(23)   = CONVERT(VARCHAR(23), GETDATE(), 120);
        DECLARE @EmailSubject  NVARCHAR(200) = N'[SQLLockWatch] BLOCKING Detected on ' + @ServerName
                                               + N' at ' + @DetectionTime;

        DECLARE @BlockingRows  NVARCHAR(MAX) = N'';
        DECLARE @HeadBlockerRows NVARCHAR(MAX) = N'';
        DECLARE @RowNum        INT = 0;

        DECLARE @BlockerSPID     INT;
        DECLARE @BlockedSPID     INT;
        DECLARE @WaitSec         INT;
        DECLARE @WaitType        NVARCHAR(60);
        DECLARE @WaitResource    NVARCHAR(256);
        DECLARE @DBName          NVARCHAR(128);
        DECLARE @BkdLogin        NVARCHAR(128);
        DECLARE @BkdHost         NVARCHAR(128);
        DECLARE @BkdProg         NVARCHAR(256);
        DECLARE @BkdQuery        NVARCHAR(MAX);
        DECLARE @BkrLogin        NVARCHAR(128);
        DECLARE @BkrHost         NVARCHAR(128);
        DECLARE @BkrProg         NVARCHAR(256);
        DECLARE @BkrQuery        NVARCHAR(MAX);
        DECLARE @IsHead          BIT;

        DECLARE chain_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT BlockerSPID, BlockedSPID, WaitTimeSeconds, WaitType, WaitResource,
                   DatabaseName, BlockedLogin, BlockedHost, BlockedProgram, BlockedQuery,
                   BlockerLogin, BlockerHost, BlockerProgram, BlockerQuery, IsHeadBlocker
            FROM #BlockingChains
            ORDER BY WaitTimeSeconds DESC;

        OPEN chain_cursor;
        FETCH NEXT FROM chain_cursor
            INTO @BlockerSPID, @BlockedSPID, @WaitSec, @WaitType, @WaitResource,
                 @DBName, @BkdLogin, @BkdHost, @BkdProg, @BkdQuery,
                 @BkrLogin, @BkrHost, @BkrProg, @BkrQuery, @IsHead;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            DECLARE @RowBg NVARCHAR(20) = CASE WHEN @RowNum % 2 = 0 THEN N'#fff' ELSE N'#fff8f0' END;
            DECLARE @HeadBadge NVARCHAR(50) = CASE WHEN @IsHead = 1 THEN N' &#9733;' ELSE N'' END;

            SET @BlockingRows = @BlockingRows
                + N'<tr style="background:' + @RowBg + N';">'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + CAST(@BlockerSPID AS NVARCHAR(10)) + @HeadBadge + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + CAST(@BlockedSPID AS NVARCHAR(10)) + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + CAST(@WaitSec AS NVARCHAR(10)) + N's</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@WaitType,     N'') + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@WaitResource, N'') + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@DBName,       N'') + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@BkdLogin,     N'') + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@BkdHost,      N'') + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@BkdProg,      N'') + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;font-family:Consolas,monospace;font-size:11px;">'
                    + ISNULL(REPLACE(REPLACE(@BkdQuery, N'<', N'&lt;'), N'>', N'&gt;'), N'') + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;font-family:Consolas,monospace;font-size:11px;">'
                    + ISNULL(REPLACE(REPLACE(@BkrQuery, N'<', N'&lt;'), N'>', N'&gt;'), N'') + N'</td>'
                + N'</tr>';

            IF @IsHead = 1
            BEGIN
                SET @HeadBlockerRows = @HeadBlockerRows
                    + N'<tr><td style="padding:6px 10px;border:1px solid #ddd;">' + CAST(@BlockerSPID AS NVARCHAR(10)) + N'</td>'
                    + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@BkrLogin, N'') + N'</td>'
                    + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@BkrHost,  N'') + N'</td>'
                    + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@BkrProg,  N'') + N'</td>'
                    + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@DBName,   N'') + N'</td>'
                    + N'<td style="padding:6px 10px;border:1px solid #ddd;font-family:Consolas,monospace;font-size:11px;">'
                        + ISNULL(REPLACE(REPLACE(@BkrQuery, N'<', N'&lt;'), N'>', N'&gt;'), N'') + N'</td>'
                    + N'</tr>';
            END

            SET @RowNum = @RowNum + 1;
            FETCH NEXT FROM chain_cursor
                INTO @BlockerSPID, @BlockedSPID, @WaitSec, @WaitType, @WaitResource,
                     @DBName, @BkdLogin, @BkdHost, @BkdProg, @BkdQuery,
                     @BkrLogin, @BkrHost, @BkrProg, @BkrQuery, @IsHead;
        END

        CLOSE chain_cursor;
        DEALLOCATE chain_cursor;

        -- Compose full email
        DECLARE @EmailBody NVARCHAR(MAX);

        SET @EmailBody = N'<!DOCTYPE html><html><head><meta charset="UTF-8"></head><body style="font-family:Arial,sans-serif;font-size:13px;color:#333;">'
            + N'<div style="background:#e67e22;color:#fff;padding:14px 20px;border-radius:4px 4px 0 0;">'
            + N'<h2 style="margin:0;">&#9888; SQLLockWatch — BLOCKING DETECTED</h2></div>'
            + N'<div style="border:1px solid #e67e22;border-top:none;padding:16px;border-radius:0 0 4px 4px;">'
            + N'<table style="margin-bottom:10px;">'
            + N'<tr><td style="font-weight:bold;padding-right:12px;">Server:</td><td>' + @ServerName + N'</td></tr>'
            + N'<tr><td style="font-weight:bold;padding-right:12px;">Detection Time:</td><td>' + @DetectionTime + N'</td></tr>'
            + N'<tr><td style="font-weight:bold;padding-right:12px;">Threshold Used:</td><td>' + CAST(@ThresholdSeconds AS NVARCHAR(10)) + N' seconds</td></tr>'
            + N'</table>'

            -- Head Blocker Highlight
            + CASE WHEN @HeadBlockerRows <> N'' THEN
                N'<h3 style="color:#e67e22;border-bottom:1px solid #e67e22;padding-bottom:4px;">Head Blocker(s) &#9733;</h3>'
                + N'<table style="border-collapse:collapse;width:100%;margin-bottom:16px;">'
                + N'<thead><tr style="background:#e67e22;color:#fff;">'
                + N'<th style="padding:6px 10px;text-align:left;">SPID</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Login</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Host</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Program</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Database</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Current Query</th>'
                + N'</tr></thead><tbody>'
                + @HeadBlockerRows
                + N'</tbody></table>'
              ELSE N'' END

            -- Blocking Chain Detail
            + N'<h3 style="color:#e67e22;border-bottom:1px solid #e67e22;padding-bottom:4px;">Blocking Chain Detail</h3>'
            + N'<table style="border-collapse:collapse;width:100%;">'
            + N'<thead><tr style="background:#e67e22;color:#fff;">'
            + N'<th style="padding:6px 10px;text-align:left;">Blocker SPID</th>'
            + N'<th style="padding:6px 10px;text-align:left;">Blocked SPID</th>'
            + N'<th style="padding:6px 10px;text-align:left;">Wait Time</th>'
            + N'<th style="padding:6px 10px;text-align:left;">Wait Type</th>'
            + N'<th style="padding:6px 10px;text-align:left;">Wait Resource</th>'
            + N'<th style="padding:6px 10px;text-align:left;">Database</th>'
            + N'<th style="padding:6px 10px;text-align:left;">Blocked Login</th>'
            + N'<th style="padding:6px 10px;text-align:left;">Blocked Host</th>'
            + N'<th style="padding:6px 10px;text-align:left;">Blocked Program</th>'
            + N'<th style="padding:6px 10px;text-align:left;">Blocked Query</th>'
            + N'<th style="padding:6px 10px;text-align:left;">Blocker Query</th>'
            + N'</tr></thead><tbody>'
            + @BlockingRows
            + N'</tbody></table>'
            + N'</div></body></html>';

        EXEC msdb.dbo.sp_send_dbmail
            @profile_name  = @MailProfile,
            @recipients    = @EmailRecipients,
            @subject       = @EmailSubject,
            @body          = @EmailBody,
            @body_format   = 'HTML';

        -- Log to alert history
        DECLARE @BlockedCount INT = (SELECT COUNT(*) FROM #BlockingChains);

        INSERT INTO msdb.dbo.SQLLockWatch_AlertHistory (AlertType, Details)
        VALUES ('BLOCKING', CAST(@BlockedCount AS NVARCHAR(10)) + N' blocked session(s) detected on '
                             + @ServerName + N' at ' + @DetectionTime
                             + N'; threshold=' + CAST(@ThresholdSeconds AS NVARCHAR(10)) + N's');

        DROP TABLE #BlockingChains;

    END TRY
    BEGIN CATCH

        DECLARE @ErrMsg  NVARCHAR(2048) = ERROR_MESSAGE();
        DECLARE @ErrLine INT            = ERROR_LINE();

        INSERT INTO msdb.dbo.SQLLockWatch_AlertHistory (AlertType, Details)
        VALUES ('ERROR', N'SQLLockWatch_CheckBlocking error at line '
                          + CAST(@ErrLine AS NVARCHAR(10)) + N': ' + @ErrMsg);

        IF OBJECT_ID('tempdb..#BlockingChains') IS NOT NULL
            DROP TABLE #BlockingChains;

    END CATCH
END;
GO

PRINT '  Stored procedure ''SQLLockWatch_CheckBlocking'' created/updated.';
PRINT '';

-- ============================================================
-- PART B: SQL Server Agent Job
-- ============================================================
PRINT 'Part B: Creating SQL Server Agent job ''SQLLockWatch - Blocking Monitor''...';
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
    SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLLockWatch - Blocking Monitor'
)
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name               = N'SQLLockWatch - Blocking Monitor',
        @delete_unused_schedule = 1;
    PRINT '  Existing job dropped.';
END
GO

DECLARE @JobID   UNIQUEIDENTIFIER;
DECLARE @SchedID INT;

EXEC msdb.dbo.sp_add_job
    @job_name         = N'SQLLockWatch - Blocking Monitor',
    @enabled          = 1,
    @description      = N'Checks for blocking sessions exceeding the configured threshold and sends email alerts.',
    @category_name    = N'Database Maintenance',
    @owner_login_name = N'sa',
    @job_id           = @JobID OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id            = @JobID,
    @step_name         = N'Check Blocking',
    @step_id           = 1,
    @subsystem         = N'TSQL',
    @command           = N'EXEC msdb.dbo.SQLLockWatch_CheckBlocking;',
    @database_name     = N'msdb',
    @on_success_action = 1,
    @on_fail_action    = 2;

EXEC msdb.dbo.sp_add_schedule
    @schedule_name          = N'SQLLockWatch_Blocking_Every1Min',
    @enabled                = 1,
    @freq_type              = 4,
    @freq_interval          = 1,
    @freq_subday_type       = 4,
    @freq_subday_interval   = 1,
    @freq_relative_interval = 0,
    @freq_recurrence_factor = 0,
    @active_start_date      = 19900101,
    @active_end_date        = 99991231,
    @active_start_time      = 0,
    @active_end_time        = 235959,
    @schedule_id            = @SchedID OUTPUT;

EXEC msdb.dbo.sp_attach_schedule
    @job_id      = @JobID,
    @schedule_id = @SchedID;

EXEC msdb.dbo.sp_add_jobserver
    @job_id      = @JobID,
    @server_name = N'(local)';

PRINT '  Job ''SQLLockWatch - Blocking Monitor'' created and enabled.';
PRINT '';
GO

PRINT '=== Blocking Monitor deployment complete. ===';
GO
