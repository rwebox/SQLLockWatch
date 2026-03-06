/*
================================================================================
  SQLLockWatch — 02_Setup_Config.sql
  Creates configuration, alert log, and cooldown tables in msdb.
  Inserts default configuration values (does NOT overwrite existing values).

  Safe to re-run.
================================================================================
*/

USE msdb;
GO

PRINT '======================================================';
PRINT ' SQLLockWatch — Config & Logging Setup';
PRINT '======================================================';
PRINT '';

-- ============================================================
-- Table: SQLLockWatch_Config
-- ============================================================
PRINT 'Creating table SQLLockWatch_Config (if not exists)...';

IF OBJECT_ID(N'msdb.dbo.SQLLockWatch_Config', N'U') IS NULL
BEGIN
    CREATE TABLE msdb.dbo.SQLLockWatch_Config
    (
        ConfigKey     VARCHAR(100)  NOT NULL
            CONSTRAINT PK_SQLLockWatch_Config PRIMARY KEY CLUSTERED,
        ConfigValue   VARCHAR(500)  NOT NULL,
        Description   VARCHAR(500)  NULL,
        LastModified  DATETIME      NOT NULL
            CONSTRAINT DF_SQLLockWatch_Config_LastModified DEFAULT (GETDATE())
    );

    PRINT '  Table created.';
END
ELSE
BEGIN
    PRINT '  Table already exists — skipping creation.';
END

PRINT '';

-- ============================================================
-- Default config values
-- Only INSERT if the key does not already exist so that
-- user customisations are preserved on re-run.
-- ============================================================
PRINT 'Inserting default config values (skipping any that already exist)...';

-- BlockingThresholdSeconds
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.SQLLockWatch_Config WHERE ConfigKey = 'BlockingThresholdSeconds')
    INSERT INTO msdb.dbo.SQLLockWatch_Config (ConfigKey, ConfigValue, Description)
    VALUES ('BlockingThresholdSeconds', '60',
            'Minimum blocking duration in seconds before alerting');

-- AlertCooldownMinutes
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.SQLLockWatch_Config WHERE ConfigKey = 'AlertCooldownMinutes')
    INSERT INTO msdb.dbo.SQLLockWatch_Config (ConfigKey, ConfigValue, Description)
    VALUES ('AlertCooldownMinutes', '5',
            'Don''t re-alert for same blocker within this many minutes');

-- EmailRecipients
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.SQLLockWatch_Config WHERE ConfigKey = 'EmailRecipients')
    INSERT INTO msdb.dbo.SQLLockWatch_Config (ConfigKey, ConfigValue, Description)
    VALUES ('EmailRecipients',
            'ray.wang@novachem.com;itenterprisetcssqladministration@novachem.com',
            'Semicolon-separated list of email recipients for alerts');

-- MailProfile
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.SQLLockWatch_Config WHERE ConfigKey = 'MailProfile')
    INSERT INTO msdb.dbo.SQLLockWatch_Config (ConfigKey, ConfigValue, Description)
    VALUES ('MailProfile', 'SQLLockWatch',
            'Database Mail profile name to use for sending alerts');

-- RetentionDays
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.SQLLockWatch_Config WHERE ConfigKey = 'RetentionDays')
    INSERT INTO msdb.dbo.SQLLockWatch_Config (ConfigKey, ConfigValue, Description)
    VALUES ('RetentionDays', '28',
            'How long to keep alert history in days (4 weeks)');

-- DeadlockMonitorEnabled
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.SQLLockWatch_Config WHERE ConfigKey = 'DeadlockMonitorEnabled')
    INSERT INTO msdb.dbo.SQLLockWatch_Config (ConfigKey, ConfigValue, Description)
    VALUES ('DeadlockMonitorEnabled', '1',
            'Enable/disable deadlock monitoring (1=on, 0=off)');

-- BlockingMonitorEnabled
IF NOT EXISTS (SELECT 1 FROM msdb.dbo.SQLLockWatch_Config WHERE ConfigKey = 'BlockingMonitorEnabled')
    INSERT INTO msdb.dbo.SQLLockWatch_Config (ConfigKey, ConfigValue, Description)
    VALUES ('BlockingMonitorEnabled', '1',
            'Enable/disable blocking monitoring (1=on, 0=off)');

PRINT '  Default config values inserted (existing values unchanged).';
PRINT '';

-- ============================================================
-- Table: SQLLockWatch_AlertLog
-- ============================================================
PRINT 'Creating table SQLLockWatch_AlertLog (if not exists)...';

IF OBJECT_ID(N'msdb.dbo.SQLLockWatch_AlertLog', N'U') IS NULL
BEGIN
    CREATE TABLE msdb.dbo.SQLLockWatch_AlertLog
    (
        AlertID    INT           NOT NULL IDENTITY(1,1)
            CONSTRAINT PK_SQLLockWatch_AlertLog PRIMARY KEY CLUSTERED,
        AlertType  VARCHAR(20)   NOT NULL,   -- 'DEADLOCK' or 'BLOCKING'
        AlertTime  DATETIME      NOT NULL
            CONSTRAINT DF_SQLLockWatch_AlertLog_AlertTime DEFAULT (GETDATE()),
        Details    NVARCHAR(MAX) NULL,
        BlockerSPID INT          NULL,       -- head blocker SPID for BLOCKING alerts
        EmailSent  BIT           NOT NULL
            CONSTRAINT DF_SQLLockWatch_AlertLog_EmailSent DEFAULT (0)
    );

    PRINT '  Table created.';
END
ELSE
BEGIN
    PRINT '  Table already exists — skipping creation.';
END

PRINT '';

-- ============================================================
-- Table: SQLLockWatch_Cooldown
-- ============================================================
PRINT 'Creating table SQLLockWatch_Cooldown (if not exists)...';

IF OBJECT_ID(N'msdb.dbo.SQLLockWatch_Cooldown', N'U') IS NULL
BEGIN
    CREATE TABLE msdb.dbo.SQLLockWatch_Cooldown
    (
        CooldownID    INT          NOT NULL IDENTITY(1,1)
            CONSTRAINT PK_SQLLockWatch_Cooldown PRIMARY KEY CLUSTERED,
        AlertType     VARCHAR(20)  NOT NULL,   -- 'DEADLOCK' or 'BLOCKING'
        CooldownKey   VARCHAR(200) NOT NULL,   -- identifier to prevent duplicate alerts
        LastAlertTime DATETIME     NOT NULL
    );

    -- Index to speed up cooldown lookups
    CREATE NONCLUSTERED INDEX IX_SQLLockWatch_Cooldown_Key
        ON msdb.dbo.SQLLockWatch_Cooldown (AlertType, CooldownKey);

    PRINT '  Table created.';
END
ELSE
BEGIN
    PRINT '  Table already exists — skipping creation.';
END

PRINT '';

-- ============================================================
PRINT '======================================================';
PRINT ' Config & Logging setup complete.';
PRINT ' Tables in msdb.dbo:';
PRINT '   SQLLockWatch_Config';
PRINT '   SQLLockWatch_AlertLog';
PRINT '   SQLLockWatch_Cooldown';
PRINT '======================================================';
