# SQLLockWatch

Real-time **deadlock** and **blocking lock** email alerts for SQL Server — delivered straight to your DBA inbox.

SQLLockWatch continuously monitors your SQL Server instance using Extended Events (deadlocks) and DMV polling (blocking), and sends richly formatted HTML emails the moment a problem is detected.

---

## Features

- 🔴 **Deadlock alerts** — captures `xml_deadlock_report` via Extended Events; parses victim process, all involved processes, and raw XML graph
- 🟠 **Blocking alerts** — polls `sys.dm_exec_requests` every minute; identifies head-blockers and full blocking chains
- 📧 **Professional HTML emails** — inline CSS, color-coded banners (red for deadlocks, orange for blocking), alternating row colors, query text
- ⚙️ **Configurable** — alert cooldown, blocking threshold, enable/disable each monitor, retention period
- 🧹 **Automatic history cleanup** — daily purge job keeps `SQLLockWatch_AlertHistory` lean
- ♻️ **Idempotent scripts** — all six scripts are safe to re-run without side-effects

---

## Prerequisites

| Requirement | Notes |
|---|---|
| SQL Server 2016 or later | `CREATE OR ALTER PROCEDURE` requires SQL Server 2016+ |
| Database Mail configured | SMTP relay must be reachable from the SQL Server host |
| SQL Server Agent running | Required for the three scheduled jobs |
| `sysadmin` or equivalent | Scripts create objects in `msdb`; XE session requires server-level permission |

---

## Quick-Start Installation

Run the scripts **in order** on the target SQL Server instance using SSMS or `sqlcmd`:

### 1. Configure Database Mail

```sql
-- Opens in SSMS: File > Open > 01_Setup_DatabaseMail.sql
```

Edit the placeholder values in `01_Setup_DatabaseMail.sql` before running:

| Placeholder | Replace with |
|---|---|
| `smtp.yourcompany.com` | Your SMTP relay hostname |
| `25` | SMTP port (587 for STARTTLS, 465 for SSL) |
| `sqllockwatch@yourcompany.com` | Sender email address |
| `0` (enable_ssl) | `1` if your relay requires SSL/TLS |

Then run the script:

```
sqlcmd -S <server> -E -i 01_Setup_DatabaseMail.sql
```

### 2. Create Config and History Tables

```
sqlcmd -S <server> -E -i 02_Setup_Config.sql
```

After running, update the recipient address:

```sql
UPDATE msdb.dbo.SQLLockWatch_Config
SET    ConfigValue = 'your-dba@yourcompany.com'
WHERE  ConfigKey   = 'EmailRecipients';
```

### 3. Deploy Deadlock Monitor

```
sqlcmd -S <server> -E -i 03_Deploy_DeadlockMonitor.sql
```

This creates the `SQLLockWatch_Deadlocks` Extended Events session and the
`SQLLockWatch - Deadlock Monitor` Agent job (runs every minute).

### 4. Deploy Blocking Monitor

```
sqlcmd -S <server> -E -i 04_Deploy_BlockingMonitor.sql
```

Creates the `SQLLockWatch - Blocking Monitor` Agent job (runs every minute).

### 5. Deploy Cleanup Job

```
sqlcmd -S <server> -E -i 05_Cleanup_Retention.sql
```

Creates the `SQLLockWatch - Cleanup` Agent job (runs daily at 3:00 AM).

---

## Configuration Reference

All settings live in `msdb.dbo.SQLLockWatch_Config`.  
Update with a simple `UPDATE` statement; changes take effect on the next job run.

| ConfigKey | Default | Description |
|---|---|---|
| `MailProfile` | `SQLLockWatch` | Database Mail profile name used to send alerts |
| `EmailRecipients` | `dba-team@yourcompany.com` | Semicolon-separated list of alert recipients |
| `AlertCooldownMinutes` | `5` | Minimum minutes between alerts of the same type (prevents alert storms) |
| `DeadlockMonitorEnabled` | `1` | Set to `0` to disable the deadlock monitor without removing the job |
| `BlockingMonitorEnabled` | `1` | Set to `0` to disable the blocking monitor without removing the job |
| `BlockingThresholdSeconds` | `30` | A session must be blocked for at least this many seconds to trigger an alert |
| `RetentionDays` | `30` | Alert history rows older than this many days are purged by the cleanup job |

### Example: tighten blocking threshold to 10 seconds

```sql
UPDATE msdb.dbo.SQLLockWatch_Config
SET    ConfigValue = '10'
WHERE  ConfigKey   = 'BlockingThresholdSeconds';
```

---

## How Alerts Look

### Deadlock email

- **Red** header banner: `⚠ SQLLockWatch — DEADLOCK DETECTED`
- Summary row: server name, deadlock timestamp
- **Victim Process** table — SPID, database, login, host, application, query text
- **All Processes Involved** table — same columns plus wait resource; victim row highlighted with ⚠
- **Raw Deadlock Graph XML** in a scrollable `<pre>` block (useful for SSMS deadlock graph viewer)

### Blocking email

- **Orange** header banner: `⚠ SQLLockWatch — BLOCKING DETECTED`
- Summary row: server name, detection time, threshold used
- **Head Blocker(s) ★** highlight section — the SPID(s) at the root of the blocking chain
- **Blocking Chain Detail** table — blocker SPID, blocked SPID, wait time/type/resource, database, logins, hosts, programs, query text for both sides

---

## Viewing Alert History

```sql
-- Last 50 alerts
SELECT TOP 50 *
FROM   msdb.dbo.SQLLockWatch_AlertHistory
ORDER  BY AlertTime DESC;

-- Only deadlocks in the last 24 hours
SELECT *
FROM   msdb.dbo.SQLLockWatch_AlertHistory
WHERE  AlertType = 'DEADLOCK'
  AND  AlertTime >= DATEADD(HOUR, -24, GETDATE())
ORDER  BY AlertTime DESC;
```

---

## Uninstall

To remove **all** SQLLockWatch objects:

```
sqlcmd -S <server> -E -i 99_Uninstall.sql
```

This script removes Agent jobs, the Extended Events session, stored procedures, and both tables.  
Database Mail profile and account removal is commented out by default — uncomment those lines in `99_Uninstall.sql` if the profile is exclusively used by SQLLockWatch.

---

## File Reference

| Script | Purpose |
|---|---|
| `01_Setup_DatabaseMail.sql` | Enable Database Mail; create profile and account |
| `02_Setup_Config.sql` | Create config and alert history tables; seed defaults |
| `03_Deploy_DeadlockMonitor.sql` | XE session + deadlock check procedure + Agent job |
| `04_Deploy_BlockingMonitor.sql` | Blocking check procedure + Agent job |
| `05_Cleanup_Retention.sql` | History purge procedure + daily Agent job |
| `99_Uninstall.sql` | Full removal of all SQLLockWatch objects |

---

## License

MIT — see [LICENSE](LICENSE) for details.
