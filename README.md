# SQLLockWatch

> **Real-time deadlock & blocking alerts for SQL Server**

SQLLockWatch is a free, open-source SQL Server monitoring utility that automatically detects deadlocks and long-running blocking locks, then delivers rich HTML email alerts to your DBA team — with zero external dependencies.

---

## Features

- 🔴 **Deadlock Detection** — captures deadlock graphs via Extended Events and emails a full report with victim/process details
- 🟠 **Blocking Detection** — polls `sys.dm_exec_requests` every minute and alerts when blocking exceeds a configurable threshold
- 📧 **Rich HTML Emails** — professional, inline-CSS emails with process tables, SQL text, and deadlock XML
- ⏱️ **Alert Cooldown** — prevents alert storms by suppressing duplicate alerts within a configurable window
- 🗃️ **Config-Driven** — all thresholds, recipients, and toggles stored in a single SQL table
- 🧹 **Auto Cleanup** — scheduled job purges alert history after a configurable retention period
- ✅ **Pure T-SQL** — no PowerShell, no .NET, no external tools required

---

## Requirements

| Requirement | Detail |
|---|---|
| SQL Server version | 2016 SP1 or later (2016, 2017, 2019, 2022, 2025) |
| SQL Server Agent | Must be running |
| Database Mail | Configured by script 01 (or pre-existing) |
| Permissions | `sysadmin` role required to install |

---

## Quick Start

Run the scripts **in order** using SSMS or `sqlcmd` connected to each SQL Server instance you want to monitor. Each script is safe to re-run.

```sql
-- Step 1: Set up Database Mail account and profile
-- Edit SMTP settings inside the script first if needed
:r 01_Setup_DatabaseMail.sql

-- Step 2: Create config and logging tables in msdb
:r 02_Setup_Config.sql

-- Step 3: Deploy deadlock monitor (Extended Events + Agent job)
:r 03_Deploy_DeadlockMonitor.sql

-- Step 4: Deploy blocking monitor (DMV-based + Agent job)
:r 04_Deploy_BlockingMonitor.sql

-- Step 5: Deploy history cleanup job
:r 05_Cleanup_Retention.sql
```

After installation, three SQL Server Agent jobs will be active:

| Job Name | Schedule | Purpose |
|---|---|---|
| `SQLLockWatch - Deadlock Monitor` | Every 1 minute | Reads Extended Events, emails deadlock reports |
| `SQLLockWatch - Blocking Monitor` | Every 1 minute | Queries DMVs, emails blocking alerts |
| `SQLLockWatch - History Cleanup` | Daily at 3:00 AM | Purges old alert log rows |

---

## Configuration

All settings live in **`msdb.dbo.SQLLockWatch_Config`**. Edit values directly with a simple `UPDATE`:

```sql
UPDATE msdb.dbo.SQLLockWatch_Config
SET ConfigValue = '30'
WHERE ConfigKey = 'BlockingThresholdSeconds';
```

### Config Keys

| Key | Default | Description |
|---|---|---|
| `BlockingThresholdSeconds` | `60` | Minimum seconds a session must be blocked before an alert is sent |
| `AlertCooldownMinutes` | `5` | Minutes before re-alerting for the same blocker (prevents alert storms) |
| `EmailRecipients` | `ray.wang@novachem.com;itenterprisetcssqladministration@novachem.com` | Semicolon-separated list of alert recipient email addresses |
| `MailProfile` | `SQLLockWatch` | Database Mail profile name used to send alerts |
| `RetentionDays` | `28` | Days of alert history to retain (older rows auto-purged) |
| `DeadlockMonitorEnabled` | `1` | Set to `0` to disable deadlock monitoring without removing the job |
| `BlockingMonitorEnabled` | `1` | Set to `0` to disable blocking monitoring without removing the job |

---

## Email Alert Examples

### 🔴 Deadlock Alert

**Subject:** `🔴 DEADLOCK on SQLSRV01 at 2025-03-06 14:32:17`

The email body includes:
- Red header banner with server name and detection timestamp
- A table listing every process involved in the deadlock: SPID, Login, Hostname, Database, SQL statement, and whether that process was the **victim**
- The full deadlock XML graph in a code block for deep diagnostics
- Footer identifying the sending instance

### 🟠 Blocking Alert

**Subject:** `🟠 BLOCKING on SQLSRV01 — 120s (SPID 55)`

The email body includes:
- Orange header banner with server name and total wait duration
- A highlighted "Head Blocker" details box showing: SPID, login, host, database, program name, connection status, last request time, and the blocking query
- A table of all currently blocked sessions with their wait times and SQL text
- A tip line noting whether the blocker appears to be an idle open transaction
- Footer identifying the sending instance

---

## Alert Log

All sent alerts are recorded in `msdb.dbo.SQLLockWatch_AlertLog`:

```sql
SELECT TOP 50 *
FROM msdb.dbo.SQLLockWatch_AlertLog
ORDER BY AlertTime DESC;
```

---

## Uninstall

To completely remove SQLLockWatch from an instance, run:

```sql
:r 99_Uninstall.sql
```

This will:
- Stop and drop all three Agent jobs
- Drop the Extended Events session
- Drop all three stored procedures
- Drop all three tables from `msdb`
- Remove the Database Mail profile and account named `SQLLockWatch`

---

## License

MIT — see [LICENSE](LICENSE).

---

*SQLLockWatch is designed for DBA teams managing SQL Server on-premises environments. Contributions welcome.*
