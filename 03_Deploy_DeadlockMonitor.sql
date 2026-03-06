/*
================================================================================
  SQLLockWatch — 03_Deploy_DeadlockMonitor.sql
  Part A : Extended Events session  (SQLLockWatch_Deadlocks)
  Part B : Stored procedure          (msdb.dbo.SQLLockWatch_CheckDeadlocks)
  Part C : SQL Server Agent job      (SQLLockWatch - Deadlock Monitor)

  Safe to re-run.
================================================================================
*/

USE msdb;
GO

PRINT '======================================================';
PRINT ' SQLLockWatch — Deadlock Monitor Deployment';
PRINT '======================================================';
PRINT '';

-- ============================================================
-- PART A: Extended Events Session
-- ============================================================
PRINT 'Part A: Configuring Extended Events session...';

-- Derive the LOG directory from the ErrorLog file path
DECLARE @LogDir        NVARCHAR(512);
DECLARE @ErrorLogPath  NVARCHAR(512);

SELECT @ErrorLogPath = CAST(SERVERPROPERTY('ErrorLogFileName') AS NVARCHAR(512));

-- Strip the filename to get just the directory
SET @LogDir = LEFT(@ErrorLogPath, LEN(@ErrorLogPath) - CHARINDEX(N'\', REVERSE(@ErrorLogPath)));

DECLARE @XETargetPath NVARCHAR(600) = @LogDir + N'\SQLLockWatch_Deadlocks';

PRINT '  XE target path: ' + @XETargetPath;

-- Drop existing session if it exists
IF EXISTS (
    SELECT 1 FROM sys.server_event_sessions WHERE name = N'SQLLockWatch_Deadlocks'
)
BEGIN
    IF EXISTS (
        SELECT 1 FROM sys.dm_xe_sessions WHERE name = N'SQLLockWatch_Deadlocks'
    )
        ALTER EVENT SESSION [SQLLockWatch_Deadlocks] ON SERVER STATE = STOP;

    DROP EVENT SESSION [SQLLockWatch_Deadlocks] ON SERVER;
    PRINT '  Dropped existing XE session.';
END

-- Build the CREATE statement with the dynamic path
DECLARE @CreateXE NVARCHAR(MAX) = N'
CREATE EVENT SESSION [SQLLockWatch_Deadlocks] ON SERVER
ADD EVENT sqlserver.xml_deadlock_report
ADD TARGET package0.event_file
(
    SET filename         = N''' + @XETargetPath + N''',
        max_file_size    = 10,
        max_rollover_files = 5
)
WITH
(
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    STARTUP_STATE        = ON
);';

EXEC sp_executesql @CreateXE;
PRINT '  XE session created.';

-- Start the session immediately
ALTER EVENT SESSION [SQLLockWatch_Deadlocks] ON SERVER STATE = START;
PRINT '  XE session started.';
PRINT '';

GO

-- ============================================================
-- PART B: Stored Procedure — SQLLockWatch_CheckDeadlocks
-- ============================================================
PRINT 'Part B: Creating stored procedure SQLLockWatch_CheckDeadlocks...';
GO

CREATE OR ALTER PROCEDURE msdb.dbo.SQLLockWatch_CheckDeadlocks
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        -- --------------------------------------------------------
        -- Read config
        -- --------------------------------------------------------
        DECLARE @MailProfile       VARCHAR(500);
        DECLARE @EmailRecipients   VARCHAR(500);
        DECLARE @CooldownMinutes   INT;
        DECLARE @MonitorEnabled    INT;

        SELECT @MailProfile     = MAX(CASE WHEN ConfigKey = 'MailProfile'             THEN ConfigValue END),
               @EmailRecipients = MAX(CASE WHEN ConfigKey = 'EmailRecipients'         THEN ConfigValue END),
               @CooldownMinutes = MAX(CASE WHEN ConfigKey = 'AlertCooldownMinutes'    THEN CAST(ConfigValue AS INT) END),
               @MonitorEnabled  = MAX(CASE WHEN ConfigKey = 'DeadlockMonitorEnabled'  THEN CAST(ConfigValue AS INT) END)
        FROM   msdb.dbo.SQLLockWatch_Config;

        IF ISNULL(@MonitorEnabled, 1) = 0
        BEGIN
            RETURN; -- monitoring disabled
        END

        SET @CooldownMinutes = ISNULL(@CooldownMinutes, 5);

        -- --------------------------------------------------------
        -- Get XE file target path from session metadata
        -- --------------------------------------------------------
        DECLARE @TargetPath NVARCHAR(512);

        SELECT TOP 1
               @TargetPath = CAST(t.target_data AS XML)
                                 .value('(/EventFileTarget/File/@name)[1]', 'NVARCHAR(512)')
        FROM   sys.dm_xe_sessions          s
        JOIN   sys.dm_xe_session_targets   t ON t.event_session_address = s.address
        WHERE  s.name    = N'SQLLockWatch_Deadlocks'
          AND  t.target_name = N'event_file';

        IF @TargetPath IS NULL
            RETURN; -- session not running

        -- Replace the exact filename with a wildcard so fn_xe_file_target_read_file
        -- picks up all rollover files
        SET @TargetPath = LEFT(@TargetPath, LEN(@TargetPath) - CHARINDEX(N'_', REVERSE(@TargetPath)))
                          + N'*.xel';

        -- --------------------------------------------------------
        -- Read deadlock events from XE file
        -- --------------------------------------------------------
        DECLARE @DeadlockEvents TABLE
        (
            DeadlockXML   XML      NOT NULL,
            EventTime     DATETIME NOT NULL
        );

        INSERT INTO @DeadlockEvents (DeadlockXML, EventTime)
        SELECT
            TRY_CAST(xdr.event_data AS XML)                            AS DeadlockXML,
            CAST(xdr.timestamp_utc AS DATETIME)                        AS EventTime
        FROM sys.fn_xe_file_target_read_file(@TargetPath, NULL, NULL, NULL) AS xdr
        WHERE xdr.object_name = N'xml_deadlock_report';

        IF NOT EXISTS (SELECT 1 FROM @DeadlockEvents)
            RETURN;

        -- --------------------------------------------------------
        -- Process each deadlock event
        -- --------------------------------------------------------
        DECLARE @DeadlockXML  XML;
        DECLARE @EventTime    DATETIME;
        DECLARE @CooldownKey  VARCHAR(200);

        DECLARE cur_deadlock CURSOR LOCAL FAST_FORWARD FOR
            SELECT DeadlockXML, EventTime
            FROM   @DeadlockEvents
            ORDER BY EventTime;

        OPEN cur_deadlock;
        FETCH NEXT FROM cur_deadlock INTO @DeadlockXML, @EventTime;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- Cooldown key = the deadlock timestamp string (one alert per unique deadlock event)
            SET @CooldownKey = CONVERT(VARCHAR(30), @EventTime, 121);

            -- Check cooldown
            IF NOT EXISTS (
                SELECT 1
                FROM   msdb.dbo.SQLLockWatch_Cooldown
                WHERE  AlertType    = 'DEADLOCK'
                  AND  CooldownKey  = @CooldownKey
                  AND  LastAlertTime >= DATEADD(MINUTE, -@CooldownMinutes, GETDATE())
            )
            BEGIN
                -- ------------------------------------------------
                -- Parse processes from the deadlock XML
                -- ------------------------------------------------
                DECLARE @ProcessInfo TABLE
                (
                    SPID       INT,
                    LoginName  NVARCHAR(128),
                    HostName   NVARCHAR(128),
                    DBName     NVARCHAR(128),
                    InputBuf   NVARCHAR(MAX),
                    IsVictim   BIT
                );

                -- Victim list (one or more)
                DECLARE @VictimList TABLE (VictimID NVARCHAR(20));

                INSERT INTO @VictimList (VictimID)
                SELECT v.value('@id', 'NVARCHAR(20)')
                FROM   @DeadlockXML.nodes('/TextData/deadlock/victim-list/victimProcess') AS t(v);

                -- All processes
                INSERT INTO @ProcessInfo (SPID, LoginName, HostName, DBName, InputBuf, IsVictim)
                SELECT
                    p.value('@spid',       'INT')            AS SPID,
                    p.value('@loginname',  'NVARCHAR(128)')  AS LoginName,
                    p.value('@hostname',   'NVARCHAR(128)')  AS HostName,
                    DB_NAME(p.value('@currentdb', 'INT'))    AS DBName,
                    LEFT(p.value('(inputbuf)[1]', 'NVARCHAR(MAX)'), 2000) AS InputBuf,
                    CASE
                        WHEN vl.VictimID IS NOT NULL THEN 1
                        ELSE 0
                    END                                       AS IsVictim
                FROM  @DeadlockXML.nodes('/TextData/deadlock/process-list/process') AS t(p)
                LEFT JOIN @VictimList vl
                       ON vl.VictimID = p.value('@id', 'NVARCHAR(20)');

                -- ------------------------------------------------
                -- Build HTML email body
                -- ------------------------------------------------
                DECLARE @HtmlBody  NVARCHAR(MAX);
                DECLARE @Subject   NVARCHAR(500);
                DECLARE @TimeStr   VARCHAR(30) = CONVERT(VARCHAR(30), @EventTime, 121);

                SET @Subject = N'🔴 DEADLOCK on ' + @@SERVERNAME + N' at ' + @TimeStr;

                SET @HtmlBody = N'<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#222;margin:0;padding:0;background:#f5f5f5;">
<table width="100%" cellpadding="0" cellspacing="0" style="max-width:900px;margin:20px auto;background:#fff;border:1px solid #ddd;border-radius:6px;overflow:hidden;">

  <!-- Header -->
  <tr>
    <td style="background:#c0392b;padding:20px 24px;">
      <span style="color:#fff;font-size:22px;font-weight:bold;">🔴 DEADLOCK DETECTED on ' + @@SERVERNAME + N'</span><br>
      <span style="color:#f5b7b1;font-size:13px;">Detected at: ' + @TimeStr + N'</span>
    </td>
  </tr>

  <!-- Processes table -->
  <tr>
    <td style="padding:20px 24px;">
      <h3 style="margin:0 0 12px 0;color:#c0392b;">Processes Involved</h3>
      <table width="100%" cellpadding="8" cellspacing="0" style="border-collapse:collapse;font-size:13px;">
        <thead>
          <tr style="background:#c0392b;color:#fff;">
            <th style="text-align:left;padding:8px 10px;border:1px solid #a93226;">SPID</th>
            <th style="text-align:left;padding:8px 10px;border:1px solid #a93226;">Login</th>
            <th style="text-align:left;padding:8px 10px;border:1px solid #a93226;">Host</th>
            <th style="text-align:left;padding:8px 10px;border:1px solid #a93226;">Database</th>
            <th style="text-align:left;padding:8px 10px;border:1px solid #a93226;">Query</th>
            <th style="text-align:left;padding:8px 10px;border:1px solid #a93226;">Victim</th>
          </tr>
        </thead>
        <tbody>';

                SELECT @HtmlBody = @HtmlBody +
                    N'<tr style="background:' + CASE WHEN IsVictim = 1 THEN N'#fdecea' ELSE N'#fff' END + N';">
            <td style="padding:8px 10px;border:1px solid #eee;">' + CAST(SPID AS NVARCHAR(10)) + N'</td>
            <td style="padding:8px 10px;border:1px solid #eee;">' + ISNULL(LoginName, N'') + N'</td>
            <td style="padding:8px 10px;border:1px solid #eee;">' + ISNULL(HostName,  N'') + N'</td>
            <td style="padding:8px 10px;border:1px solid #eee;">' + ISNULL(DBName,    N'') + N'</td>
            <td style="padding:8px 10px;border:1px solid #eee;font-family:Consolas,monospace;font-size:12px;max-width:300px;word-break:break-all;">'
                + ISNULL(LEFT(InputBuf, 500), N'') + N'</td>
            <td style="padding:8px 10px;border:1px solid #eee;font-weight:bold;color:'
                + CASE WHEN IsVictim = 1 THEN N'#c0392b' ELSE N'#27ae60' END + N';">'
                + CASE WHEN IsVictim = 1 THEN N'Yes' ELSE N'No' END + N'</td>
          </tr>'
                FROM @ProcessInfo;

                SET @HtmlBody = @HtmlBody + N'
        </tbody>
      </table>
    </td>
  </tr>

  <!-- Deadlock XML -->
  <tr>
    <td style="padding:0 24px 20px 24px;">
      <h3 style="margin:0 0 8px 0;color:#555;">Deadlock XML Graph</h3>
      <pre style="background:#f4f4f4;border:1px solid #ddd;border-radius:4px;padding:12px;font-size:11px;font-family:Consolas,monospace;overflow-x:auto;white-space:pre-wrap;word-break:break-all;"><code>'
            + ISNULL(CAST(@DeadlockXML AS NVARCHAR(MAX)), N'')
            + N'</code></pre>
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

                -- ------------------------------------------------
                -- Send email
                -- ------------------------------------------------
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

                -- ------------------------------------------------
                -- Log the alert
                -- ------------------------------------------------
                DECLARE @Details NVARCHAR(MAX) = N'Deadlock at ' + @TimeStr
                    + N'. Processes: ' + CAST((SELECT COUNT(*) FROM @ProcessInfo) AS NVARCHAR(10));

                INSERT INTO msdb.dbo.SQLLockWatch_AlertLog
                    (AlertType, Details, EmailSent)
                VALUES ('DEADLOCK', @Details, @EmailSent);

                -- ------------------------------------------------
                -- Update cooldown (upsert)
                -- ------------------------------------------------
                IF EXISTS (
                    SELECT 1 FROM msdb.dbo.SQLLockWatch_Cooldown
                    WHERE AlertType = 'DEADLOCK' AND CooldownKey = @CooldownKey
                )
                    UPDATE msdb.dbo.SQLLockWatch_Cooldown
                    SET    LastAlertTime = GETDATE()
                    WHERE  AlertType    = 'DEADLOCK'
                      AND  CooldownKey  = @CooldownKey;
                ELSE
                    INSERT INTO msdb.dbo.SQLLockWatch_Cooldown (AlertType, CooldownKey, LastAlertTime)
                    VALUES ('DEADLOCK', @CooldownKey, GETDATE());

                -- Clean up temp tables for next iteration
                DELETE FROM @ProcessInfo;
                DELETE FROM @VictimList;

            END -- cooldown check

            FETCH NEXT FROM cur_deadlock INTO @DeadlockXML, @EventTime;
        END -- while

        CLOSE cur_deadlock;
        DEALLOCATE cur_deadlock;

    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'cur_deadlock') >= 0
        BEGIN
            CLOSE cur_deadlock;
            DEALLOCATE cur_deadlock;
        END

        DECLARE @ErrMsg  NVARCHAR(4000) = ERROR_MESSAGE();
        DECLARE @ErrLine INT            = ERROR_LINE();

        INSERT INTO msdb.dbo.SQLLockWatch_AlertLog (AlertType, Details, EmailSent)
        VALUES ('DEADLOCK', N'ERROR in SQLLockWatch_CheckDeadlocks (line '
                + CAST(@ErrLine AS NVARCHAR(10)) + N'): ' + @ErrMsg, 0);
    END CATCH
END
GO

PRINT '  Stored procedure created.';
PRINT '';

-- ============================================================
-- PART C: SQL Server Agent Job
-- ============================================================
PRINT 'Part C: Creating Agent job ''SQLLockWatch - Deadlock Monitor''...';
GO

-- Create the job category if it doesn't exist
IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.syscategories
    WHERE name = N'Database Maintenance' AND category_class = 1
)
BEGIN
    EXEC msdb.dbo.sp_add_category
        @class    = N'JOB',
        @type     = N'LOCAL',
        @name     = N'Database Maintenance';
END

-- Drop existing job if it exists
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLLockWatch - Deadlock Monitor')
    EXEC msdb.dbo.sp_delete_job
        @job_name = N'SQLLockWatch - Deadlock Monitor',
        @delete_unused_schedule = 1;

-- Create the job
DECLARE @JobID UNIQUEIDENTIFIER;

EXEC msdb.dbo.sp_add_job
    @job_name            = N'SQLLockWatch - Deadlock Monitor',
    @enabled             = 1,
    @description         = N'Reads Extended Events deadlock data and sends HTML email alerts.',
    @category_name       = N'Database Maintenance',
    @owner_login_name    = N'sa',
    @job_id              = @JobID OUTPUT;

-- Add job step
EXEC msdb.dbo.sp_add_jobstep
    @job_id          = @JobID,
    @step_name       = N'Check for Deadlocks',
    @step_id         = 1,
    @subsystem       = N'TSQL',
    @command         = N'EXEC msdb.dbo.SQLLockWatch_CheckDeadlocks;',
    @database_name   = N'msdb',
    @on_success_action = 1,  -- quit with success
    @on_fail_action    = 2;  -- quit with failure

-- Add schedule (every 1 minute, all day)
EXEC msdb.dbo.sp_add_jobschedule
    @job_id               = @JobID,
    @name                 = N'SQLLockWatch - Deadlock Monitor - 1min',
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
PRINT ' Deadlock Monitor deployment complete.';
PRINT '   XE Session  : SQLLockWatch_Deadlocks';
PRINT '   Procedure   : msdb.dbo.SQLLockWatch_CheckDeadlocks';
PRINT '   Agent Job   : SQLLockWatch - Deadlock Monitor';
PRINT '======================================================';
GO
