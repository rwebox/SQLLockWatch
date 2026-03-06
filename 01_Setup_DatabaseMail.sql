-- File: 01_Setup_DatabaseMail.sql
-- Description: Configures Database Mail for use by SQLLockWatch.
--              Creates the SQLLockWatch mail profile and account with placeholder
--              SMTP settings. A DBA must update the SMTP server, port, and
--              email address before deploying the monitors.
-- Safe to re-run.

USE msdb;
GO

PRINT '=== SQLLockWatch: Database Mail Setup ===';
PRINT '';

-- ============================================================
-- Step 1: Enable Database Mail if not already enabled
-- ============================================================
PRINT 'Step 1: Checking Database Mail configuration...';

IF (SELECT CAST(value_in_use AS INT)
    FROM sys.configurations
    WHERE name = 'Database Mail XPs') = 0
BEGIN
    PRINT '  Database Mail XPs not enabled. Enabling now...';
    EXEC sp_configure 'show advanced options', 1;
    RECONFIGURE WITH OVERRIDE;
    EXEC sp_configure 'Database Mail XPs', 1;
    RECONFIGURE WITH OVERRIDE;
    PRINT '  Database Mail XPs enabled.';
END
ELSE
BEGIN
    PRINT '  Database Mail XPs already enabled. Skipping.';
END
PRINT '';

-- ============================================================
-- Step 2: Create the Database Mail profile
-- ============================================================
PRINT 'Step 2: Checking Database Mail profile ''SQLLockWatch''...';

IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_profile
    WHERE name = 'SQLLockWatch'
)
BEGIN
    EXEC msdb.dbo.sysmail_add_profile_sp
        @profile_name = 'SQLLockWatch',
        @description  = 'SQLLockWatch alert mail profile';
    PRINT '  Profile ''SQLLockWatch'' created.';
END
ELSE
BEGIN
    PRINT '  Profile ''SQLLockWatch'' already exists. Skipping.';
END
PRINT '';

-- ============================================================
-- Step 3: Create the Database Mail account
-- ============================================================
PRINT 'Step 3: Checking Database Mail account ''SQLLockWatch''...';

IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_account
    WHERE name = 'SQLLockWatch'
)
BEGIN
    EXEC msdb.dbo.sysmail_add_account_sp
        @account_name            = 'SQLLockWatch',
        @description             = 'SQLLockWatch SMTP account',
        @email_address           = 'sqllockwatch@yourcompany.com',  -- *** UPDATE THIS ***
        @display_name            = 'SQLLockWatch Alerts',
        @mailserver_name         = 'smtp.yourcompany.com',           -- *** UPDATE THIS ***
        @port                    = 25,                               -- *** UPDATE THIS ***
        @enable_ssl              = 0;                                -- *** SET TO 1 FOR SSL ***
    PRINT '  Account ''SQLLockWatch'' created.';
    PRINT '  *** ACTION REQUIRED: Update SMTP server, port, and email address in sysmail_account. ***';
END
ELSE
BEGIN
    PRINT '  Account ''SQLLockWatch'' already exists. Skipping.';
END
PRINT '';

-- ============================================================
-- Step 4: Associate the account with the profile
-- ============================================================
PRINT 'Step 4: Checking profile-to-account association...';

DECLARE @ProfileID  INT;
DECLARE @AccountID  INT;

SELECT @ProfileID = profile_id
FROM msdb.dbo.sysmail_profile
WHERE name = 'SQLLockWatch';

SELECT @AccountID = account_id
FROM msdb.dbo.sysmail_account
WHERE name = 'SQLLockWatch';

IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_profileaccount
    WHERE profile_id = @ProfileID
      AND account_id = @AccountID
)
BEGIN
    EXEC msdb.dbo.sysmail_add_profileaccount_sp
        @profile_name  = 'SQLLockWatch',
        @account_name  = 'SQLLockWatch',
        @sequence_number = 1;
    PRINT '  Account associated with profile.';
END
ELSE
BEGIN
    PRINT '  Account already associated with profile. Skipping.';
END
PRINT '';

-- ============================================================
-- Step 5: Grant the profile to the public role
-- ============================================================
PRINT 'Step 5: Granting profile to public role...';

IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_principalprofile
    WHERE profile_id = @ProfileID
      AND principal_sid = 0x00  -- 0x00 = public
)
BEGIN
    EXEC msdb.dbo.sysmail_add_principalprofile_sp
        @profile_name   = 'SQLLockWatch',
        @principal_name = 'public',
        @is_default     = 0;
    PRINT '  Profile granted to public role.';
END
ELSE
BEGIN
    PRINT '  Profile already granted to public role. Skipping.';
END
PRINT '';

PRINT '=== Database Mail setup complete. ===';
PRINT 'NEXT STEP: Edit sysmail_account to set your real SMTP server, port, and sender address.';
GO
