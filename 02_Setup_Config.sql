-- File: 02_Setup_Config.sql
-- Description: Creates the SQLLockWatch configuration and alert history tables
--              in msdb and inserts default configuration values.
-- Safe to re-run.

USE msdb;
GO

PRINT '=== SQLLockWatch: Configuration Setup ===';
PRINT '';

-- ============================================================
-- Step 1: Create SQLLockWatch_Config table
-- ============================================================
PRINT 'Step 1: Checking SQLLockWatch_Config table...';

IF NOT EXISTS (
    SELECT 1
    FROM sys.tables t
    INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE s.name = 'dbo'
      AND t.name = 'SQLLockWatch_Config'
)
BEGIN
    CREATE TABLE msdb.dbo.SQLLockWatch_Config (
        ConfigKey     VARCHAR(100) NOT NULL CONSTRAINT PK_SQLLockWatch_Config PRIMARY KEY,
        ConfigValue   VARCHAR(500) NOT NULL,
        ModifiedDate  DATETIME     NOT NULL CONSTRAINT DF_SQLLockWatch_Config_ModifiedDate DEFAULT (GETDATE())
    );
    PRINT '  Table SQLLockWatch_Config created.';
END
ELSE
BEGIN
    PRINT '  Table SQLLockWatch_Config already exists. Skipping.';
END
PRINT '';

-- ============================================================
-- Step 2: Create SQLLockWatch_AlertHistory table
-- ============================================================
PRINT 'Step 2: Checking SQLLockWatch_AlertHistory table...';

IF NOT EXISTS (
    SELECT 1
    FROM sys.tables t
    INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
    WHERE s.name = 'dbo'
      AND t.name = 'SQLLockWatch_AlertHistory'
)
BEGIN
    CREATE TABLE msdb.dbo.SQLLockWatch_AlertHistory (
        AlertID    INT           NOT NULL IDENTITY(1,1) CONSTRAINT PK_SQLLockWatch_AlertHistory PRIMARY KEY,
        AlertType  VARCHAR(50)   NOT NULL,
        AlertTime  DATETIME      NOT NULL CONSTRAINT DF_SQLLockWatch_AlertHistory_AlertTime DEFAULT (GETDATE()),
        Details    NVARCHAR(MAX) NULL
    );
    PRINT '  Table SQLLockWatch_AlertHistory created.';
END
ELSE
BEGIN
    PRINT '  Table SQLLockWatch_AlertHistory already exists. Skipping.';
END
PRINT '';

-- ============================================================
-- Step 3: Insert / update default configuration values
-- ============================================================
PRINT 'Step 3: Inserting default configuration values...';

MERGE msdb.dbo.SQLLockWatch_Config AS target
USING (
    VALUES
        ('MailProfile',               'SQLLockWatch'),
        ('EmailRecipients',           'dba-team@yourcompany.com'),  -- *** UPDATE THIS ***
        ('AlertCooldownMinutes',      '5'),
        ('DeadlockMonitorEnabled',    '1'),
        ('BlockingMonitorEnabled',    '1'),
        ('BlockingThresholdSeconds',  '30'),
        ('RetentionDays',             '30')
) AS source (ConfigKey, ConfigValue)
ON target.ConfigKey = source.ConfigKey
WHEN NOT MATCHED THEN
    INSERT (ConfigKey, ConfigValue)
    VALUES (source.ConfigKey, source.ConfigValue);

PRINT '  Default configuration values inserted (existing values were not overwritten).';
PRINT '';

PRINT '=== Configuration setup complete. ===';
PRINT 'NEXT STEP: Update EmailRecipients in SQLLockWatch_Config with your real DBA email address.';
GO
