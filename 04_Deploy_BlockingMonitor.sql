/*
================================================================================
  SQLLockWatch — 04_Deploy_BlockingMonitor.sql
  Part A : Stored procedure  (msdb.dbo.SQLLockWatch_CheckBlocking)
  Part B : SQL Server Agent job (SQLLockWatch - Blocking Monitor)

  Safe to re-run.
================================================================================
*/

USE msdb;
GO

PRINT '======================================================';
PRINT ' SQLLockWatch — Blocking Monitor Deployment';
PRINT '======================================================';
PRINT '';

-- ============================================================
-- PART A: Stored Procedure — SQLLockWatch_CheckBlocking
-- ============================================================
PRINT 'Part A: Creating stored procedure SQLLockWatch_CheckBlocking...';
GO

CREATE OR ALTER PROCEDURE dbo.SQLLockWatch_CheckBlocking
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        -- --------------------------------------------------------
        -- Read config
        -- --------------------------------------------------------
        DECLARE @BlockingThresholdSeconds INT;
        DECLARE @CooldownMinutes          INT;
        DECLARE @MailProfile              VARCHAR(500);
        DECLARE @EmailRecipients          VARCHAR(500);
        DECLARE @MonitorEnabled           INT;

        SELECT
            @BlockingThresholdSeconds = MAX(CASE WHEN ConfigKey = 'BlockingThresholdSeconds' THEN CAST(ConfigValue AS INT) END),
            @CooldownMinutes          = MAX(CASE WHEN ConfigKey = 'AlertCooldownMinutes'      THEN CAST(ConfigValue AS INT) END),
            @MailProfile              = MAX(CASE WHEN ConfigKey = 'MailProfile'               THEN ConfigValue END),
            @EmailRecipients          = MAX(CASE WHEN ConfigKey = 'EmailRecipients'           THEN ConfigValue END),
            @MonitorEnabled           = MAX(CASE WHEN ConfigKey = 'BlockingMonitorEnabled'    THEN CAST(ConfigValue AS INT) END)
        FROM msdb.dbo.SQLLockWatch_Config;

        IF ISNULL(@MonitorEnabled, 1) = 0
            RETURN; -- monitoring disabled

        SET @BlockingThresholdSeconds = ISNULL(@BlockingThresholdSeconds, 60);
        SET @CooldownMinutes          = ISNULL(@CooldownMinutes, 5);

        -- --------------------------------------------------------
        -- Find blocking chains that exceed the threshold
        -- --------------------------------------------------------
        -- Blocked sessions
        DECLARE @BlockedSessions TABLE
        (
            BlockedSPID   INT,
            BlockerSPID   INT,
            LoginName     NVARCHAR(128),
            HostName      NVARCHAR(128),
            DBName        NVARCHAR(128),
            WaitSeconds   INT,
            BlockedSQL    NVARCHAR(MAX)
        );

        INSERT INTO @BlockedSessions
            (BlockedSPID, BlockerSPID, LoginName, HostName, DBName, WaitSeconds, BlockedSQL)
        SELECT
            r.session_id                        AS BlockedSPID,
            r.blocking_session_id               AS BlockerSPID,
            s.login_name                        AS LoginName,
            s.host_name                         AS HostName,
            DB_NAME(s.database_id)              AS DBName,
            r.wait_time / 1000                  AS WaitSeconds,
            ISNULL(LEFT(st.text, 2000), N'')    AS BlockedSQL
        FROM sys.dm_exec_requests    r
        JOIN sys.dm_exec_sessions    s  ON s.session_id = r.session_id
        CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) st
        WHERE r.blocking_session_id <> 0
          AND r.wait_time / 1000 >= @BlockingThresholdSeconds;

        IF NOT EXISTS (SELECT 1 FROM @BlockedSessions)
            RETURN; -- no blocking above threshold

        -- --------------------------------------------------------
        -- Identify the head blocker
        -- The head blocker is the SPID that is blocking others
        -- but is not itself blocked.
        -- --------------------------------------------------------
        DECLARE @HeadBlockerSPID INT;

        SELECT TOP 1
            @HeadBlockerSPID = bs.BlockerSPID
        FROM @BlockedSessions bs
        WHERE NOT EXISTS (
            SELECT 1 FROM @BlockedSessions bs2
            WHERE bs2.BlockedSPID = bs.BlockerSPID
        )
        ORDER BY (SELECT COUNT(*) FROM @BlockedSessions bs3 WHERE bs3.BlockerSPID = bs.BlockerSPID) DESC;

        IF @HeadBlockerSPID IS NULL
            RETURN;

        DECLARE @MaxWaitSeconds INT;
        SELECT @MaxWaitSeconds = MAX(WaitSeconds) FROM @BlockedSessions;

        DECLARE @DBName       NVARCHAR(128);
        SELECT TOP 1 @DBName = DBName FROM @BlockedSessions WHERE BlockerSPID = @HeadBlockerSPID;

        -- --------------------------------------------------------
        -- Cooldown check
        -- --------------------------------------------------------
        DECLARE @CooldownKey VARCHAR(200) = 'BLOCKING_' + CAST(@HeadBlockerSPID AS VARCHAR(10))
                                            + '_' + ISNULL(@DBName, 'unknown');

        IF EXISTS (
            SELECT 1
            FROM   msdb.dbo.SQLLockWatch_Cooldown
            WHERE  AlertType    = 'BLOCKING'
              AND  CooldownKey  = @CooldownKey
              AND  LastAlertTime >= DATEADD(MINUTE, -@CooldownMinutes, GETDATE())
        )
            RETURN; -- in cooldown

        -- --------------------------------------------------------
        -- Get head blocker details from DMVs
        -- --------------------------------------------------------
        DECLARE @BlockerLogin    NVARCHAR(128);
        DECLARE @BlockerHost     NVARCHAR(128);
        DECLARE @BlockerDB       NVARCHAR(128);
        DECLARE @BlockerProgram  NVARCHAR(128);
        DECLARE @BlockerStatus   NVARCHAR(30);
        DECLARE @BlockerLastReq  DATETIME;
        DECLARE @BlockerWaitType NVARCHAR(60);
        DECLARE @BlockerSQL      NVARCHAR(MAX);

        SELECT
            @BlockerLogin   = s.login_name,
            @BlockerHost    = s.host_name,
            @BlockerDB      = DB_NAME(s.database_id),
            @BlockerProgram = s.program_name,
            @BlockerStatus  = s.status,
            @BlockerLastReq = s.last_request_start_time,
            @BlockerWaitType= ISNULL((SELECT TOP 1 r2.wait_type FROM sys.dm_exec_requests r2 WHERE r2.session_id = @HeadBlockerSPID), N''),
            @BlockerSQL     = ISNULL(LEFT(st2.text, 2000), N'')
        FROM sys.dm_exec_sessions    s
        LEFT JOIN sys.dm_exec_connections c ON c.session_id = s.session_id
        OUTER APPLY sys.dm_exec_sql_text(c.most_recent_sql_handle) st2
        WHERE s.session_id = @HeadBlockerSPID;

        -- --------------------------------------------------------
        -- Build HTML email
        -- --------------------------------------------------------
        DECLARE @Subject  NVARCHAR(500);
        DECLARE @HtmlBody NVARCHAR(MAX);
        DECLARE @NowStr   VARCHAR(30) = CONVERT(VARCHAR(30), GETDATE(), 121);

        SET @Subject = N'🟠 BLOCKING on ' + @@SERVERNAME
                     + N' — ' + CAST(@MaxWaitSeconds AS NVARCHAR(10))
                     + N's (SPID ' + CAST(@HeadBlockerSPID AS NVARCHAR(10)) + N')';

        SET @HtmlBody = N'<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222;margin:0;padding:0;background:#f5f5f5;">
<table width="100%" cellpadding="0" cellspacing="0" style="max-width:900px;margin:20px auto;background:#fff;border:1px solid #ddd;border-radius:6px;overflow:hidden;">

  <!-- Header -->
  <tr>
    <td style="background:#e67e22;padding:20px 24px;">
      <span style="color:#fff;font-size:22px;font-weight:bold;">🟠 BLOCKING ALERT on ' + @@SERVERNAME + N'</span><br>
      <span style="color:#fef5e7;font-size:13px;">Max wait: ' + CAST(@MaxWaitSeconds AS NVARCHAR(10)) + N' seconds &nbsp;|&nbsp; Detected at: ' + @NowStr + N'</span>
    </td>
  </tr>

  <!-- Head Blocker Box -->
  <tr>
    <td style="padding:20px 24px 10px 24px;">
      <h3 style="margin:0 0 10px 0;color:#e67e22;">Head Blocker — SPID ' + CAST(@HeadBlockerSPID AS NVARCHAR(10)) + N'</h3>
      <table cellpadding="0" cellspacing="0" style="background:#fef9ee;border:1px solid #f0c040;border-radius:4px;padding:14px 18px;width:100%;">
        <tr>
          <td width="160" style="color:#888;font-size:13px;padding:4px 0;">Login</td>
          <td style="font-size:13px;padding:4px 0;font-weight:bold;">' + ISNULL(@BlockerLogin, N'') + N'</td>
        </tr>
        <tr>
          <td style="color:#888;font-size:13px;padding:4px 0;">Host</td>
          <td style="font-size:13px;padding:4px 0;">' + ISNULL(@BlockerHost, N'') + N'</td>
        </tr>
        <tr>
          <td style="color:#888;font-size:13px;padding:4px 0;">Database</td>
          <td style="font-size:13px;padding:4px 0;">' + ISNULL(@BlockerDB, N'') + N'</td>
        </tr>
        <tr>
          <td style="color:#888;font-size:13px;padding:4px 0;">Program</td>
          <td style="font-size:13px;padding:4px 0;">' + ISNULL(@BlockerProgram, N'') + N'</td>
        </tr>
        <tr>
          <td style="color:#888;font-size:13px;padding:4px 0;">Status</td>
          <td style="font-size:13px;padding:4px 0;">' + ISNULL(@BlockerStatus, N'') + N'</td>
        </tr>
        <tr>
          <td style="color:#888;font-size:13px;padding:4px 0;">Last Request</td>
          <td style="font-size:13px;padding:4px 0;">' + ISNULL(CONVERT(VARCHAR(30), @BlockerLastReq, 121), N'') + N'</td>
        </tr>
        <tr>
          <td style="color:#888;font-size:13px;padding:4px 0;vertical-align:top;">Query</td>
          <td style="font-size:12px;padding:4px 0;font-family:Consolas,monospace;word-break:break-all;">' + ISNULL(@BlockerSQL, N'') + N'</td>
        </tr>
      </table>
    </td>
  </tr>

  <!-- Blocked Sessions Table -->
  <tr>
    <td style="padding:10px 24px 20px 24px;">
      <h3 style="margin:0 0 10px 0;color:#555;">Blocked Sessions</h3>
      <table width="100%" cellpadding="8" cellspacing="0" style="border-collapse:collapse;font-size:13px;">
        <thead>
          <tr style="background:#e67e22;color:#fff;">
            <th style="text-align:left;padding:8px 10px;border:1px solid #ca6f1e;">SPID</th>
            <th style="text-align:left;padding:8px 10px;border:1px solid #ca6f1e;">Login</th>
            <th style="text-align:left;padding:8px 10px;border:1px solid #ca6f1e;">Host</th>
            <th style="text-align:left;padding:8px 10px;border:1px solid #ca6f1e;">Database</th>
            <th style="text-align:left;padding:8px 10px;border:1px solid #ca6f1e;">Wait (s)</th>
            <th style="text-align:left;padding:8px 10px;border:1px solid #ca6f1e;">Query</th>
          </tr>
        </thead>
        <tbody>';

        SELECT @HtmlBody = @HtmlBody +
            N'<tr style="background:#fff;">
            <td style="padding:8px 10px;border:1px solid #eee;">' + CAST(BlockedSPID AS NVARCHAR(10)) + N'</td>
            <td style="padding:8px 10px;border:1px solid #eee;">' + ISNULL(LoginName, N'') + N'</td>
            <td style="padding:8px 10px;border:1px solid #eee;">' + ISNULL(HostName,  N'') + N'</td>
            <td style="padding:8px 10px;border:1px solid #eee;">' + ISNULL(DBName,    N'') + N'</td>
            <td style="padding:8px 10px;border:1px solid #eee;">' + CAST(WaitSeconds AS NVARCHAR(10)) + N'</td>
            <td style="padding:8px 10px;border:1px solid #eee;font-family:Consolas,monospace;font-size:12px;word-break:break-all;">'
                + ISNULL(LEFT(BlockedSQL, 500), N'') + N'</td>
          </tr>'
        FROM @BlockedSessions;

        SET @HtmlBody = @HtmlBody + N'
        </tbody>
      </table>
    </td>
  </tr>

  <!-- Tip -->
  <tr>
    <td style="padding:0 24px 16px 24px;">
      <div style="background:#fffde7;border:1px solid #f9ca24;border-radius:4px;padding:10px 14px;font-size:13px;">
        💡 The head blocker (SPID ' + CAST(@HeadBlockerSPID AS NVARCHAR(10)) + N') is in <strong>''' + ISNULL(@BlockerStatus, N'') + N'''</strong> state.
        ' + CASE WHEN LOWER(ISNULL(@BlockerStatus, '')) = 'sleeping'
                 THEN N'This likely indicates an idle open transaction that has not been committed or rolled back.'
                 ELSE N'Check the query above and determine whether it can be killed or optimised.' END + N'
      </div>
    </td>
  </tr>

  <!-- Footer -->
  <tr>
    <td style="background:#f0f0f0;padding:12px 24px;border-top:1px solid #ddd;">
      <span style="color:#888;font-size:12px;">This alert was generated by SQLLockWatch on ' + @@SERVERNAME + N'</span>
    </td>
  </tr>

</table>
</body>
</html>';

        -- --------------------------------------------------------
        -- Send email
        -- --------------------------------------------------------
        DECLARE @EmailSent BIT = 0;

        BEGIN TRY
            EXEC msdb.dbo.sp_send_dbmail
                @profile_name  = @MailProfile,
                @recipients    = @EmailRecipients,
                @subject       = @Subject,
                @body          = @HtmlBody,
                @body_format   = N'HTML';

            SET @EmailSent = 1;
        END TRY
        BEGIN CATCH
            SET @EmailSent = 0;
        END CATCH

        -- --------------------------------------------------------
        -- Log the alert
        -- --------------------------------------------------------
        DECLARE @Details NVARCHAR(MAX) = N'Blocking detected. Head blocker SPID: '
            + CAST(@HeadBlockerSPID AS NVARCHAR(10))
            + N'. Max wait: ' + CAST(@MaxWaitSeconds AS NVARCHAR(10)) + N' seconds.'
            + N' Blocked sessions: ' + CAST((SELECT COUNT(*) FROM @BlockedSessions) AS NVARCHAR(10));

        INSERT INTO msdb.dbo.SQLLockWatch_AlertLog
            (AlertType, Details, BlockerSPID, EmailSent)
        VALUES ('BLOCKING', @Details, @HeadBlockerSPID, @EmailSent);

        -- --------------------------------------------------------
        -- Update cooldown (upsert)
        -- --------------------------------------------------------
        IF EXISTS (
            SELECT 1 FROM msdb.dbo.SQLLockWatch_Cooldown
            WHERE AlertType = 'BLOCKING' AND CooldownKey = @CooldownKey
        )
            UPDATE msdb.dbo.SQLLockWatch_Cooldown
            SET    LastAlertTime = GETDATE()
            WHERE  AlertType   = 'BLOCKING'
              AND  CooldownKey = @CooldownKey;
        ELSE
            INSERT INTO msdb.dbo.SQLLockWatch_Cooldown (AlertType, CooldownKey, LastAlertTime)
            VALUES ('BLOCKING', @CooldownKey, GETDATE());

    END TRY
    BEGIN CATCH
        DECLARE @ErrMsg  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrLine INT            = ERROR_LINE();

        INSERT INTO msdb.dbo.SQLLockWatch_AlertLog (AlertType, Details, EmailSent)
        VALUES ('BLOCKING', N'ERROR in SQLLockWatch_CheckBlocking (line '
                + CAST(@ErrLine AS NVARCHAR(10)) + N'): ' + @ErrMsg, 0);
    END CATCH
END
GO

PRINT '  Stored procedure created.';
PRINT '';

-- ============================================================
-- PART B: SQL Server Agent Job
-- ============================================================
PRINT 'Part B: Creating Agent job ''SQLLockWatch - Blocking Monitor''...';
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
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLLockWatch - Blocking Monitor')
    EXEC msdb.dbo.sp_delete_job
        @job_name = N'SQLLockWatch - Blocking Monitor',
        @delete_unused_schedule = 1;

-- Create the job
DECLARE @JobID UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name            = N'SQLLockWatch - Blocking Monitor',
    @enabled             = 1,
    @description         = N'Queries DMVs for blocking and sends HTML email alerts.',
    @category_name       = N'Database Maintenance',
    @owner_login_name    = N'sa',
    @job_id              = @JobID OUTPUT;

-- Add job step
EXEC msdb.dbo.sp_add_jobstep
    @job_id            = @JobID,
    @step_name         = N'Check for Blocking',
    @step_id           = 1,
    @subsystem         = N'TSQL',
    @command           = N'EXEC msdb.dbo.SQLLockWatch_CheckBlocking;',
    @database_name     = N'msdb',
    @on_success_action = 1,  -- quit with success
    @on_fail_action    = 2;  -- quit with failure

-- Add schedule (every 1 minute, all day)
EXEC msdb.dbo.sp_add_jobschedule
    @job_id               = @JobID,
    @name                 = N'SQLLockWatch - Blocking Monitor - 1min',
    @enabled              = 1,
    @freq_type            = 4,    -- daily
    @freq_interval        = 1,
    @freq_subday_type     = 4,    -- minutes
    @freq_subday_interval = 1,
    @active_start_time    = 0,
    @active_end_time      = 235959;

-- Attach to local server
EXEC msdb.dbo.sp_add_jobserver
    @job_id      = @JobID,
    @server_name = N'(local)';

PRINT '  Agent job created.';
PRINT '';

PRINT '======================================================';
PRINT ' Blocking Monitor deployment complete.';
PRINT '   Procedure : msdb.dbo.SQLLockWatch_CheckBlocking';
PRINT '   Agent Job : SQLLockWatch - Blocking Monitor';
PRINT '======================================================';
GO
