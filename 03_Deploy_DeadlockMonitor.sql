-- File: 03_Deploy_DeadlockMonitor.sql
-- Description: Deploys the SQLLockWatch deadlock monitor.
--              Part A: Extended Events session capturing xml_deadlock_report.
--              Part B: Stored procedure that reads XE events and sends HTML email alerts.
--              Part C: SQL Server Agent job that runs the procedure every minute.
-- Safe to re-run.

USE msdb;
GO

PRINT '=== SQLLockWatch: Deadlock Monitor Deployment ===';
PRINT '';

-- ============================================================
-- PART A: Extended Events Session
-- ============================================================
PRINT 'Part A: Configuring Extended Events session ''SQLLockWatch_Deadlocks''...';

DECLARE @LogDir    NVARCHAR(512);
DECLARE @XEFile    NVARCHAR(512);
DECLARE @CreateSQL NVARCHAR(MAX);
DECLARE @ErrorLog  NVARCHAR(512);

-- Derive the SQL Server LOG directory from the error log path
SET @ErrorLog = CAST(SERVERPROPERTY('ErrorLogFileName') AS NVARCHAR(512));
SET @LogDir   = LEFT(@ErrorLog, LEN(@ErrorLog) - CHARINDEX('\', REVERSE(@ErrorLog)));
SET @XEFile   = @LogDir + N'\SQLLockWatch_Deadlocks';

PRINT '  XE target path: ' + @XEFile;

-- Stop and drop existing session if present
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
        PRINT '  Stopped existing XE session.';
    END
    DROP EVENT SESSION [SQLLockWatch_Deadlocks] ON SERVER;
    PRINT '  Dropped existing XE session.';
END

-- Build CREATE EVENT SESSION statement dynamically (target path requires a variable)
SET @CreateSQL = N'
CREATE EVENT SESSION [SQLLockWatch_Deadlocks] ON SERVER
ADD EVENT sqlserver.xml_deadlock_report
ADD TARGET package0.event_file (
    SET filename            = N''' + @XEFile + N''',
        max_file_size       = 10,
        max_rollover_files  = 5
)
WITH (
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    STARTUP_STATE        = ON
);';

EXEC sp_executesql @CreateSQL;
PRINT '  XE session ''SQLLockWatch_Deadlocks'' created.';

-- Start the session immediately
ALTER EVENT SESSION [SQLLockWatch_Deadlocks] ON SERVER STATE = START;
PRINT '  XE session started.';
PRINT '';
GO

-- ============================================================
-- PART B: Stored Procedure — SQLLockWatch_CheckDeadlocks
-- ============================================================
PRINT 'Part B: Creating stored procedure ''SQLLockWatch_CheckDeadlocks''...';
GO

CREATE OR ALTER PROCEDURE msdb.dbo.SQLLockWatch_CheckDeadlocks
AS
BEGIN
    SET NOCOUNT ON;

    BEGIN TRY

        -- --------------------------------------------------------
        -- Read configuration
        -- --------------------------------------------------------
        DECLARE @MailProfile          VARCHAR(100);
        DECLARE @EmailRecipients      VARCHAR(500);
        DECLARE @CooldownMinutes      INT;
        DECLARE @MonitorEnabled       BIT;

        SELECT @MailProfile     = MAX(CASE WHEN ConfigKey = 'MailProfile'            THEN ConfigValue END),
               @EmailRecipients = MAX(CASE WHEN ConfigKey = 'EmailRecipients'        THEN ConfigValue END),
               @CooldownMinutes = CAST(MAX(CASE WHEN ConfigKey = 'AlertCooldownMinutes'  THEN ConfigValue END) AS INT),
               @MonitorEnabled  = CAST(MAX(CASE WHEN ConfigKey = 'DeadlockMonitorEnabled' THEN ConfigValue END) AS BIT)
        FROM msdb.dbo.SQLLockWatch_Config
        WHERE ConfigKey IN ('MailProfile', 'EmailRecipients', 'AlertCooldownMinutes', 'DeadlockMonitorEnabled');

        -- Exit early if monitor is disabled
        IF ISNULL(@MonitorEnabled, 0) = 0
        BEGIN
            RETURN;
        END

        -- --------------------------------------------------------
        -- Determine cooldown window
        -- --------------------------------------------------------
        DECLARE @CooldownCutoff DATETIME = DATEADD(MINUTE, -ISNULL(@CooldownMinutes, 5), GETDATE());

        IF EXISTS (
            SELECT 1
            FROM msdb.dbo.SQLLockWatch_AlertHistory
            WHERE AlertType = 'DEADLOCK'
              AND AlertTime >= @CooldownCutoff
        )
        BEGIN
            -- Still within cooldown period; skip
            RETURN;
        END

        -- --------------------------------------------------------
        -- Locate the XE file target path
        -- --------------------------------------------------------
        DECLARE @TargetFile NVARCHAR(512);

        SELECT TOP 1
            @TargetFile = CAST(xst.target_data AS XML)
                              .value('(EventFileTarget/File/@name)[1]', 'NVARCHAR(512)')
        FROM sys.dm_xe_sessions          xss
        JOIN sys.dm_xe_session_targets   xst  ON xss.address = xst.event_session_address
        WHERE xss.name   = 'SQLLockWatch_Deadlocks'
          AND xst.name   = 'event_file';

        IF @TargetFile IS NULL
        BEGIN
            -- Session not running; nothing to read
            RETURN;
        END

        -- Use wildcard so fn_xe_file_target_read_file reads all rollover files
        DECLARE @FileWildcard NVARCHAR(512) =
            LEFT(@TargetFile, LEN(@TargetFile) - CHARINDEX('_', REVERSE(@TargetFile)))
            + N'*.xel';

        -- --------------------------------------------------------
        -- Read deadlock events from XE file
        -- --------------------------------------------------------
        DECLARE @LastAlertTime DATETIME;

        SELECT @LastAlertTime = MAX(AlertTime)
        FROM msdb.dbo.SQLLockWatch_AlertHistory
        WHERE AlertType = 'DEADLOCK';

        -- Default to last 5 minutes if no prior alert
        IF @LastAlertTime IS NULL
            SET @LastAlertTime = DATEADD(MINUTE, -5, GETDATE());

        -- Temporary table to hold new deadlock events
        CREATE TABLE #DeadlockEvents (
            EventTime   DATETIME2,
            DeadlockXML XML
        );

        INSERT INTO #DeadlockEvents (EventTime, DeadlockXML)
        SELECT
            CAST(n.value('(@timestamp)[1]', 'VARCHAR(30)') AS DATETIME2)                       AS EventTime,
            n.query('(data[@name="xml_report"]/value/deadlock)[1]')                            AS DeadlockXML
        FROM (
            SELECT CAST(event_data AS XML) AS event_data_xml
            FROM sys.fn_xe_file_target_read_file(@FileWildcard, NULL, NULL, NULL)
            WHERE object_name = 'xml_deadlock_report'
        ) AS xedata
        CROSS APPLY event_data_xml.nodes('event') AS t(n)
        WHERE CAST(n.value('(@timestamp)[1]', 'VARCHAR(30)') AS DATETIME2)
              > CAST(@LastAlertTime AS DATETIME2);

        IF NOT EXISTS (SELECT 1 FROM #DeadlockEvents)
        BEGIN
            DROP TABLE #DeadlockEvents;
            RETURN;
        END

        -- --------------------------------------------------------
        -- Build and send an HTML email for each new deadlock
        -- --------------------------------------------------------
        DECLARE @EventTime   DATETIME2;
        DECLARE @DlXML       XML;
        DECLARE @EmailBody   NVARCHAR(MAX);
        DECLARE @EmailSubject NVARCHAR(200);
        DECLARE @ServerName  NVARCHAR(128) = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128));

        DECLARE dead_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT EventTime, DeadlockXML
            FROM #DeadlockEvents
            ORDER BY EventTime;

        OPEN dead_cursor;
        FETCH NEXT FROM dead_cursor INTO @EventTime, @DlXML;

        WHILE @@FETCH_STATUS = 0
        BEGIN
            -- Extract victim process
            DECLARE @VictimID     VARCHAR(20);
            DECLARE @VictimSpid   VARCHAR(20);
            DECLARE @VictimDB     NVARCHAR(128);
            DECLARE @VictimLogin  NVARCHAR(128);
            DECLARE @VictimHost   NVARCHAR(128);
            DECLARE @VictimApp    NVARCHAR(256);
            DECLARE @VictimClient NVARCHAR(50);
            DECLARE @VictimQuery  NVARCHAR(MAX);

            SELECT
                @VictimID     = @DlXML.value('(deadlock/victim-list/victimProcess/@id)[1]', 'VARCHAR(20)');

            SELECT
                @VictimSpid   = @DlXML.value('(deadlock/process-list/process[@id=sql:variable("@VictimID")]/@spid)[1]',         'VARCHAR(20)'),
                @VictimDB     = @DlXML.value('(deadlock/process-list/process[@id=sql:variable("@VictimID")]/@currentdb)[1]',    'NVARCHAR(128)'),
                @VictimLogin  = @DlXML.value('(deadlock/process-list/process[@id=sql:variable("@VictimID")]/@loginname)[1]',   'NVARCHAR(128)'),
                @VictimHost   = @DlXML.value('(deadlock/process-list/process[@id=sql:variable("@VictimID")]/@hostname)[1]',    'NVARCHAR(128)'),
                @VictimApp    = @DlXML.value('(deadlock/process-list/process[@id=sql:variable("@VictimID")]/@clientapp)[1]',   'NVARCHAR(256)'),
                @VictimClient = @DlXML.value('(deadlock/process-list/process[@id=sql:variable("@VictimID")]/@clientoption1)[1]','NVARCHAR(50)'),
                @VictimQuery  = @DlXML.value('(deadlock/process-list/process[@id=sql:variable("@VictimID")]/inputbuf)[1]',     'NVARCHAR(MAX)');

            -- Build HTML body
            SET @EmailSubject = N'[SQLLockWatch] DEADLOCK Detected on ' + @ServerName
                                 + N' at ' + CONVERT(VARCHAR(23), @EventTime, 120);

            SET @EmailBody = N'<!DOCTYPE html><html><head><meta charset="UTF-8"></head><body style="font-family:Arial,sans-serif;font-size:13px;color:#333;">'
                + N'<div style="background:#c0392b;color:#fff;padding:14px 20px;border-radius:4px 4px 0 0;">'
                + N'<h2 style="margin:0;">&#9888; SQLLockWatch — DEADLOCK DETECTED</h2></div>'
                + N'<div style="border:1px solid #c0392b;border-top:none;padding:16px;border-radius:0 0 4px 4px;">'
                + N'<table style="margin-bottom:10px;">'
                + N'<tr><td style="font-weight:bold;padding-right:12px;">Server:</td><td>' + @ServerName + N'</td></tr>'
                + N'<tr><td style="font-weight:bold;padding-right:12px;">Deadlock Time:</td><td>' + CONVERT(VARCHAR(23), @EventTime, 120) + N'</td></tr>'
                + N'</table>'

                -- Victim details
                + N'<h3 style="color:#c0392b;border-bottom:1px solid #c0392b;padding-bottom:4px;">Victim Process</h3>'
                + N'<table style="border-collapse:collapse;width:100%;">'
                + N'<thead><tr style="background:#c0392b;color:#fff;">'
                + N'<th style="padding:6px 10px;text-align:left;">SPID</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Database</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Login</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Host</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Application</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Query</th>'
                + N'</tr></thead>'
                + N'<tbody>'
                + N'<tr style="background:#fdf2f2;">'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@VictimSpid,   N'') + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@VictimDB,     N'') + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@VictimLogin,  N'') + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@VictimHost,   N'') + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@VictimApp,    N'') + N'</td>'
                + N'<td style="padding:6px 10px;border:1px solid #ddd;font-family:Consolas,monospace;font-size:11px;">' + ISNULL(REPLACE(REPLACE(@VictimQuery, N'<', N'&lt;'), N'>', N'&gt;'), N'') + N'</td>'
                + N'</tr>'
                + N'</tbody></table>';

            -- All processes in deadlock
            DECLARE @ProcessRows NVARCHAR(MAX) = N'';
            DECLARE @ProcID      VARCHAR(20);
            DECLARE @ProcSpid    VARCHAR(20);
            DECLARE @ProcDB      NVARCHAR(128);
            DECLARE @ProcLogin   NVARCHAR(128);
            DECLARE @ProcHost    NVARCHAR(128);
            DECLARE @ProcApp     NVARCHAR(256);
            DECLARE @ProcWait    NVARCHAR(256);
            DECLARE @ProcQuery   NVARCHAR(MAX);
            DECLARE @RowNum      INT = 0;

            DECLARE proc_cursor CURSOR LOCAL FAST_FORWARD FOR
                SELECT
                    t.c.value('@id',          'VARCHAR(20)'),
                    t.c.value('@spid',         'VARCHAR(20)'),
                    t.c.value('@currentdb',   'NVARCHAR(128)'),
                    t.c.value('@loginname',   'NVARCHAR(128)'),
                    t.c.value('@hostname',    'NVARCHAR(128)'),
                    t.c.value('@clientapp',   'NVARCHAR(256)'),
                    t.c.value('@waitresource','NVARCHAR(256)'),
                    t.c.value('inputbuf[1]',  'NVARCHAR(MAX)')
                FROM @DlXML.nodes('deadlock/process-list/process') AS t(c);

            OPEN proc_cursor;
            FETCH NEXT FROM proc_cursor
                INTO @ProcID, @ProcSpid, @ProcDB, @ProcLogin, @ProcHost, @ProcApp, @ProcWait, @ProcQuery;

            WHILE @@FETCH_STATUS = 0
            BEGIN
                DECLARE @RowStyle NVARCHAR(50) = CASE WHEN @RowNum % 2 = 0 THEN N'background:#fff;' ELSE N'background:#fdf2f2;' END;
                DECLARE @IsVictim NVARCHAR(10) = CASE WHEN @ProcID = @VictimID THEN N' &#9888;' ELSE N'' END;

                SET @ProcessRows = @ProcessRows
                    + N'<tr style="' + @RowStyle + N'">'
                    + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@ProcSpid,  N'') + @IsVictim + N'</td>'
                    + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@ProcDB,    N'') + N'</td>'
                    + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@ProcLogin, N'') + N'</td>'
                    + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@ProcHost,  N'') + N'</td>'
                    + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@ProcApp,   N'') + N'</td>'
                    + N'<td style="padding:6px 10px;border:1px solid #ddd;">' + ISNULL(@ProcWait,  N'') + N'</td>'
                    + N'<td style="padding:6px 10px;border:1px solid #ddd;font-family:Consolas,monospace;font-size:11px;">'
                        + ISNULL(REPLACE(REPLACE(@ProcQuery, N'<', N'&lt;'), N'>', N'&gt;'), N'') + N'</td>'
                    + N'</tr>';

                SET @RowNum = @RowNum + 1;
                FETCH NEXT FROM proc_cursor
                    INTO @ProcID, @ProcSpid, @ProcDB, @ProcLogin, @ProcHost, @ProcApp, @ProcWait, @ProcQuery;
            END

            CLOSE proc_cursor;
            DEALLOCATE proc_cursor;

            SET @EmailBody = @EmailBody
                + N'<h3 style="color:#c0392b;border-bottom:1px solid #c0392b;padding-bottom:4px;margin-top:20px;">All Processes Involved</h3>'
                + N'<table style="border-collapse:collapse;width:100%;">'
                + N'<thead><tr style="background:#c0392b;color:#fff;">'
                + N'<th style="padding:6px 10px;text-align:left;">SPID</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Database</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Login</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Host</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Application</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Wait Resource</th>'
                + N'<th style="padding:6px 10px;text-align:left;">Query</th>'
                + N'</tr></thead><tbody>'
                + @ProcessRows
                + N'</tbody></table>'
                -- Raw XML
                + N'<h3 style="color:#c0392b;border-bottom:1px solid #c0392b;padding-bottom:4px;margin-top:20px;">Raw Deadlock Graph XML</h3>'
                + N'<pre style="background:#f8f8f8;border:1px solid #ddd;padding:12px;overflow:auto;font-size:11px;">'
                + REPLACE(REPLACE(CAST(@DlXML AS NVARCHAR(MAX)), N'<', N'&lt;'), N'>', N'&gt;')
                + N'</pre>'
                + N'</div></body></html>';

            EXEC msdb.dbo.sp_send_dbmail
                @profile_name  = @MailProfile,
                @recipients    = @EmailRecipients,
                @subject       = @EmailSubject,
                @body          = @EmailBody,
                @body_format   = 'HTML';

            -- Log to alert history
            INSERT INTO msdb.dbo.SQLLockWatch_AlertHistory (AlertType, Details)
            VALUES ('DEADLOCK', N'Deadlock at ' + CONVERT(VARCHAR(23), @EventTime, 120)
                                + N'; Victim SPID ' + ISNULL(@VictimSpid, N'?')
                                + N' on ' + @ServerName);

            FETCH NEXT FROM dead_cursor INTO @EventTime, @DlXML;
        END

        CLOSE dead_cursor;
        DEALLOCATE dead_cursor;

        DROP TABLE #DeadlockEvents;

    END TRY
    BEGIN CATCH

        DECLARE @ErrMsg  NVARCHAR(2048) = ERROR_MESSAGE();
        DECLARE @ErrLine INT            = ERROR_LINE();

        INSERT INTO msdb.dbo.SQLLockWatch_AlertHistory (AlertType, Details)
        VALUES ('ERROR', N'SQLLockWatch_CheckDeadlocks error at line '
                          + CAST(@ErrLine AS NVARCHAR(10)) + N': ' + @ErrMsg);

        IF OBJECT_ID('tempdb..#DeadlockEvents') IS NOT NULL
            DROP TABLE #DeadlockEvents;

    END CATCH
END;
GO

PRINT '  Stored procedure ''SQLLockWatch_CheckDeadlocks'' created/updated.';
PRINT '';

-- ============================================================
-- PART C: SQL Server Agent Job
-- ============================================================
PRINT 'Part C: Creating SQL Server Agent job ''SQLLockWatch - Deadlock Monitor''...';
GO

-- Create job category if needed
IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.syscategories
    WHERE name = N'Database Maintenance' AND category_class = 1
)
BEGIN
    EXEC msdb.dbo.sp_add_category
        @class    = N'JOB',
        @type     = N'LOCAL',
        @name     = N'Database Maintenance';
    PRINT '  Job category ''Database Maintenance'' created.';
END
GO

-- Drop existing job if present
IF EXISTS (
    SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SQLLockWatch - Deadlock Monitor'
)
BEGIN
    EXEC msdb.dbo.sp_delete_job
        @job_name             = N'SQLLockWatch - Deadlock Monitor',
        @delete_unused_schedule = 1;
    PRINT '  Existing job dropped.';
END
GO

DECLARE @JobID   UNIQUEIDENTIFIER;
DECLARE @SchedID INT;

EXEC msdb.dbo.sp_add_job
    @job_name             = N'SQLLockWatch - Deadlock Monitor',
    @enabled              = 1,
    @description          = N'Checks for new deadlock events and sends email alerts.',
    @category_name        = N'Database Maintenance',
    @owner_login_name     = N'sa',
    @job_id               = @JobID OUTPUT;

EXEC msdb.dbo.sp_add_jobstep
    @job_id          = @JobID,
    @step_name       = N'Check Deadlocks',
    @step_id         = 1,
    @subsystem       = N'TSQL',
    @command         = N'EXEC msdb.dbo.SQLLockWatch_CheckDeadlocks;',
    @database_name   = N'msdb',
    @on_success_action = 1,  -- Quit with success
    @on_fail_action    = 2;  -- Quit with failure

EXEC msdb.dbo.sp_add_schedule
    @schedule_name           = N'SQLLockWatch_Deadlock_Every1Min',
    @enabled                 = 1,
    @freq_type               = 4,    -- Daily
    @freq_interval           = 1,
    @freq_subday_type        = 4,    -- Minutes
    @freq_subday_interval    = 1,
    @freq_relative_interval  = 0,
    @freq_recurrence_factor  = 0,
    @active_start_date       = 19900101,
    @active_end_date         = 99991231,
    @active_start_time       = 0,
    @active_end_time         = 235959,
    @schedule_id             = @SchedID OUTPUT;

EXEC msdb.dbo.sp_attach_schedule
    @job_id      = @JobID,
    @schedule_id = @SchedID;

EXEC msdb.dbo.sp_add_jobserver
    @job_id      = @JobID,
    @server_name = N'(local)';

PRINT '  Job ''SQLLockWatch - Deadlock Monitor'' created and enabled.';
PRINT '';
GO

PRINT '=== Deadlock Monitor deployment complete. ===';
GO
