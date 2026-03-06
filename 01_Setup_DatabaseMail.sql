/*
================================================================================
  SQLLockWatch — 01_Setup_DatabaseMail.sql
  Configures Database Mail for use by SQLLockWatch alert emails.

  Safe to re-run. Checks for existing profile/account before creating.
  Run this script with sysadmin privileges.
================================================================================
*/

PRINT '======================================================';
PRINT ' SQLLockWatch — Database Mail Setup';
PRINT '======================================================';
PRINT '';

-- ============================================================
-- Step 1: Enable Database Mail XPs
-- ============================================================
PRINT 'Step 1: Enabling Database Mail XPs...';

EXEC sp_configure 'show advanced options', 1;
RECONFIGURE WITH OVERRIDE;

EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE WITH OVERRIDE;

PRINT '  Database Mail XPs enabled.';
PRINT '';

-- ============================================================
-- Step 2: Build the dynamic "From" email address
--         ServerName@novachem.com  (backslash -> underscore
--         for named instances)
-- ============================================================
DECLARE @ServerName  NVARCHAR(256) = REPLACE(CAST(@@SERVERNAME AS NVARCHAR(256)), N'\', N'_');
DECLARE @FromAddress NVARCHAR(256) = @ServerName + N'@novachem.com';
DECLARE @DisplayName NVARCHAR(256) = N'SQLLockWatch on ' + @ServerName;

PRINT 'Step 2: Derived From address: ' + @FromAddress;
PRINT '';

-- ============================================================
-- Step 3: Create Database Mail Account (if not already exists)
-- ============================================================
PRINT 'Step 3: Creating Database Mail account ''SQLLockWatch''...';

IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = N'SQLLockWatch'
)
BEGIN
    EXEC msdb.dbo.sysmail_add_account_sp
        @account_name        = N'SQLLockWatch',
        @description         = N'SQLLockWatch monitoring alert account',
        @email_address       = @FromAddress,
        @display_name        = @DisplayName,
        @mailserver_name     = N'mail.novachem.com',
        @port                = 25,
        @enable_ssl          = 0,
        @use_default_credentials = 0;

    PRINT '  Account created.';
END
ELSE
BEGIN
    -- Update the email address in case the server was renamed
    EXEC msdb.dbo.sysmail_update_account_sp
        @account_name    = N'SQLLockWatch',
        @email_address   = @FromAddress,
        @display_name    = @DisplayName,
        @mailserver_name = N'mail.novachem.com',
        @port            = 25,
        @enable_ssl      = 0,
        @use_default_credentials = 0;

    PRINT '  Account already exists — updated email/display name.';
END

PRINT '';

-- ============================================================
-- Step 4: Create Database Mail Profile (if not already exists)
-- ============================================================
PRINT 'Step 4: Creating Database Mail profile ''SQLLockWatch''...';

IF NOT EXISTS (
    SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = N'SQLLockWatch'
)
BEGIN
    EXEC msdb.dbo.sysmail_add_profile_sp
        @profile_name = N'SQLLockWatch',
        @description  = N'SQLLockWatch monitoring alert profile';

    PRINT '  Profile created.';
END
ELSE
BEGIN
    PRINT '  Profile already exists — skipping creation.';
END

PRINT '';

-- ============================================================
-- Step 5: Associate account with profile (if not already linked)
-- ============================================================
PRINT 'Step 5: Associating account with profile...';

IF NOT EXISTS (
    SELECT 1
    FROM msdb.dbo.sysmail_profileaccount pa
    JOIN msdb.dbo.sysmail_profile        pr ON pa.profile_id  = pr.profile_id
    JOIN msdb.dbo.sysmail_account        ac ON pa.account_id  = ac.account_id
    WHERE pr.name = N'SQLLockWatch'
      AND ac.name = N'SQLLockWatch'
)
BEGIN
    EXEC msdb.dbo.sysmail_add_profileaccount_sp
        @profile_name  = N'SQLLockWatch',
        @account_name  = N'SQLLockWatch',
        @sequence_number = 1;

    PRINT '  Account associated with profile.';
END
ELSE
BEGIN
    PRINT '  Association already exists — skipping.';
END

PRINT '';

-- ============================================================
-- Step 6: Send test email
-- ============================================================
PRINT 'Step 6: Sending test email to ray.wang@novachem.com...';

DECLARE @Subject NVARCHAR(255) = N'SQLLockWatch Database Mail configured successfully on ' + @ServerName;
DECLARE @Body    NVARCHAR(MAX) = N'SQLLockWatch Database Mail configured successfully on ' + @ServerName
    + N'. This is a confirmation that Database Mail is set up and working correctly for the SQLLockWatch monitoring utility.';

EXEC msdb.dbo.sp_send_dbmail
    @profile_name  = N'SQLLockWatch',
    @recipients    = N'ray.wang@novachem.com',
    @subject       = @Subject,
    @body          = @Body,
    @body_format   = N'TEXT';

PRINT '  Test email queued successfully.';
PRINT '';

-- ============================================================
PRINT '======================================================';
PRINT ' Database Mail setup complete.';
PRINT ' From address : ' + @FromAddress;
PRINT ' Profile      : SQLLockWatch';
PRINT ' Account      : SQLLockWatch';
PRINT ' SMTP Server  : mail.novachem.com:25';
PRINT '======================================================';
