# ☁ CloudTask Pro

**AWS-Integrated Terminal Task Manager — Built for Production**

> *Build it like you're handing it to a colleague.*

![Bash](https://img.shields.io/badge/Bash-4.0%2B-4EAA25?style=flat-square&logo=gnubash&logoColor=white)
![AWS S3](https://img.shields.io/badge/AWS-S3-FF9900?style=flat-square&logo=amazons3&logoColor=white)
![AWS SNS](https://img.shields.io/badge/AWS-SNS-FF9900?style=flat-square&logo=amazonaws&logoColor=white)
![CloudWatch](https://img.shields.io/badge/AWS-CloudWatch-FF9900?style=flat-square&logo=amazonaws&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Ubuntu%2022.04-E95420?style=flat-square&logo=ubuntu&logoColor=white)

---

`cloudtask.sh` is a production-grade command-line task manager for DevOps engineers. It persists tasks to a local CSV, automatically backs up to S3 after every write, fires SNS alerts for HIGH priority tasks, and ships every action to CloudWatch — all without leaving the terminal.

---

## Table of Contents

1. [Quick Start](#1-quick-start)
2. [AWS Setup](#2-aws-setup)
3. [IAM Permissions](#3-iam-permissions)
4. [Environment Variables](#4-environment-variables)
5. [Usage](#5-usage)
6. [Data & File Reference](#6-data--file-reference)
7. [AWS Integration Behaviour](#7-aws-integration-behaviour)
8. [Task Lifecycle](#8-task-lifecycle)
9. [Concurrency & Safety](#9-concurrency--safety)
10. [Troubleshooting](#10-troubleshooting)
11. [Post-Submission Cleanup](#11-post-submission-cleanup)
12. [Project Structure](#12-project-structure)

---

## 1. Quick Start

### Prerequisites

| Requirement | Minimum Version | Check Command |
|---|---|---|
| Ubuntu / WSL2 | 22.04 LTS | `lsb_release -a` |
| Bash | 4.0 | `bash --version` |
| AWS CLI | v2.x | `aws --version` |
| AWS Account | Active + Free Tier | `aws sts get-caller-identity` |
| curl / jq | any recent | `curl --version && jq --version` |

### Clone & Install

```bash
# 1. Clone the repository
git clone https://github.com/helix-digital/cloudtask-pro.git
cd cloudtask-pro

# 2. Make the script executable
chmod +x cloudtask.sh

# 3. Set required environment variables (add to ~/.bashrc for persistence)
export AWS_REGION="eu-west-1"
export S3_BUCKET="helix-cloudtask-backup"
export SNS_TOPIC_ARN="arn:aws:sns:eu-west-1:123456789012:cloudtask-alerts"
export CW_LOG_GROUP="/cloudtask/prod"

# 4. Run the script
./cloudtask.sh
```

> **Tip:** Add the `export` lines to `~/.bashrc` or `~/.bash_profile` so environment variables survive terminal restarts. Run `source ~/.bashrc` to reload without logging out.

---

## 2. AWS Setup

All three AWS resources must exist before the script can perform cloud operations. The script degrades gracefully if they are missing — tasks are still saved locally — but AWS integrations will not fire. Provision in the order shown below.

### 2.1 S3 Bucket (Task Backups)

The bucket stores a timestamped snapshot of `tasks.csv` after every write operation.

```bash
# Replace ACCOUNT_ID with your 12-digit AWS account number
export S3_BUCKET="helix-cloudtask-backup-${AWS_ACCOUNT_ID}"

# Create the bucket (eu-west-1 example; change to your preferred region)
aws s3 mb s3://${S3_BUCKET} --region ${AWS_REGION}

# Enable versioning for extra safety
aws s3api put-bucket-versioning \
  --bucket ${S3_BUCKET} \
  --versioning-configuration Status=Enabled

# Block all public access
aws s3api put-public-access-block \
  --bucket ${S3_BUCKET} \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Verify
aws s3 ls s3://${S3_BUCKET}
```

### 2.2 SNS Topic (HIGH Priority Alerts)

An SNS alert fires whenever a task is created with `Priority=HIGH`. Subscribe at least one endpoint so alerts reach your on-call channel.

```bash
# Create the topic
aws sns create-topic \
  --name "cloudtask-alerts" \
  --region ${AWS_REGION}

# Capture the ARN returned above and export it
export SNS_TOPIC_ARN="arn:aws:sns:${AWS_REGION}:ACCOUNT_ID:cloudtask-alerts"

# Subscribe your email address
aws sns subscribe \
  --topic-arn ${SNS_TOPIC_ARN} \
  --protocol "email" \
  --notification-endpoint "oncall@helixdigital.io"

# Optional: subscribe a Slack webhook via HTTPS
aws sns subscribe \
  --topic-arn ${SNS_TOPIC_ARN} \
  --protocol "https" \
  --notification-endpoint "https://hooks.slack.com/services/XXX/YYY/ZZZ"

# Verify
aws sns list-subscriptions-by-topic --topic-arn ${SNS_TOPIC_ARN}
```

> **Important:** SNS email subscriptions must be confirmed by clicking the link in the AWS confirmation email before alerts will be delivered. Unconfirmed subscriptions are silently ignored.

### 2.3 CloudWatch Log Group (Audit Trail)

Every action — including reads — is shipped to CloudWatch. The compliance team uses this log for auditing.

```bash
# Create the log group
aws logs create-log-group \
  --log-group-name "/cloudtask/prod" \
  --region ${AWS_REGION}

# Set a 90-day retention policy
aws logs put-retention-policy \
  --log-group-name "/cloudtask/prod" \
  --retention-in-days 90

# The script auto-creates the log stream on first run
# Verify the group exists
aws logs describe-log-groups --log-group-name-prefix "/cloudtask"
```

---

## 3. IAM Permissions

Your AWS caller (IAM user or EC2 instance role) must have the following minimum permissions. The IAM roles are pre-configured for this project — refer to your `~/.aws/credentials` or instance metadata if you are unsure which identity is active.

| Service | Actions Required | Why |
|---|---|---|
| S3 | `s3:PutObject`, `s3:GetObject`, `s3:ListBucket` | Upload backup, verify upload, list bucket |
| SNS | `sns:Publish` | Fire HIGH priority alert |
| CloudWatch Logs | `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogGroups` | Create resources if missing; ship log entries |

```bash
# Verify your current identity
aws sts get-caller-identity

# Quick permission smoke-test
aws s3 ls s3://${S3_BUCKET}                           # S3 read
aws sns list-topics                                    # SNS
aws logs describe-log-groups \
  --log-group-name-prefix "/cloudtask"                 # CloudWatch
```

---

## 4. Environment Variables

All variables use safe defaults via Bash parameter expansion (`${VAR:-default}`) so the script never crashes on a missing value. Setting them explicitly is still strongly recommended.

| Variable | Required | Default | Description |
|---|---|---|---|
| `AWS_REGION` | Yes | `us-east-1` | AWS region for all service calls |
| `S3_BUCKET` | Yes | *(none)* | Bucket name for task backups |
| `SNS_TOPIC_ARN` | Yes | *(none)* | Full ARN of the cloudtask-alerts topic |
| `CW_LOG_GROUP` | Yes | `/cloudtask/prod` | CloudWatch log group name |
| `CLOUDTASK_DIR` | No | `~/.cloudtask` | Local data directory override |

```bash
# Recommended: add to ~/.bashrc
export AWS_REGION="eu-west-1"
export S3_BUCKET="helix-cloudtask-backup-123456789012"
export SNS_TOPIC_ARN="arn:aws:sns:eu-west-1:123456789012:cloudtask-alerts"
export CW_LOG_GROUP="/cloudtask/prod"
```

---

## 5. Usage

### 5.1 Interactive Menu

```bash
./cloudtask.sh
```

Launches the numbered main menu. Navigate by entering the option number. Invalid input redisplays the menu without exiting.

| Option | Action |
|---|---|
| `1` | Add a new task |
| `2` | List all tasks (paginated, colour-coded) |
| `3` | Update an existing task |
| `4` | Mark a task as complete |
| `5` | Delete a task (requires typing `DELETE`) |
| `6` | Search tasks by keyword |
| `7` | Filter tasks (category / priority / status / overdue) |
| `8` | View statistics dashboard |
| `9` | Export tasks to CSV |
| `10` | View local audit log |
| `0` | Exit |

### 5.2 CLI Flags

Use CLI flags to call the script from other scripts, cron jobs, or CI pipelines without the interactive menu.

| Command | Behaviour |
|---|---|
| `./cloudtask.sh` | Launch interactive menu (default) |
| `./cloudtask.sh --help` | Print usage guide, env vars, and data paths — then exit |
| `./cloudtask.sh add` | Jump directly to Add Task prompt — then exit |
| `./cloudtask.sh list` | Print all tasks as a formatted table — no menu, then exit |

### 5.3 Adding a Task — Field Reference

Every field is validated before the record is written.

| Field | Type | Valid Values / Format | Notes |
|---|---|---|---|
| Name | String | Any text; no commas — use semicolons | Required; commas break the CSV parser |
| Description | String | Any text; no commas — use semicolons | Required; commas break the CSV parser |
| Category | Enum | `ops` / `dev` / `security` / `infra` / `other` | Case-insensitive |
| Priority | Enum | `LOW` / `MEDIUM` / `HIGH` | `HIGH` fires an SNS alert immediately |
| Due Date | Date | `YYYY-MM-DD` (e.g. `2025-03-15`) | Must be a real calendar date |

---

## 6. Data & File Reference

### 6.1 Directory Layout

```
cloudtask-pro/
├── cloudtask.sh          ← main script (chmod +x)
├── README.md             ← this file
├── .gitignore
└── ~/.cloudtask/         ← auto-created on first run
    ├── tasks.csv         ← task database (single source of truth)
    ├── cloudtask.log     ← append-only structured audit log
    ├── backups/          ← local timestamped snapshots
    └── cloudtask.lock    ← PID-based concurrency guard
```

### 6.2 tasks.csv Schema

The script enforces this schema on every read and write. The header row is always present. **Never edit the file by hand while the script is running.**

| Field | Type | Set By | Notes |
|---|---|---|---|
| `ID` | String (3-digit) | Auto on add | Zero-padded (`001`, `002`, …); never reused |
| `Name` | String | User on add | Semicolons only — no commas |
| `Description` | String | User on add | Semicolons only — no commas |
| `Category` | Enum | User on add | `ops` / `dev` / `security` / `infra` / `other` |
| `Priority` | Enum | User on add / update | `LOW` / `MEDIUM` / `HIGH` |
| `Status` | Enum | System | `PENDING` on create; `COMPLETED` on mark-complete |
| `DueDate` | `YYYY-MM-DD` | User on add / update | `OVERDUE` is derived at display time — never stored |
| `CreatedAt` | ISO 8601 | Auto on add | Set once; never updated |
| `UpdatedAt` | ISO 8601 | Auto on all writes | Stamped on every modification |
| `CompletedAt` | ISO 8601 or blank | Auto on complete | Blank until task transitions to `COMPLETED` |

```
# Header row (always present)
ID,Name,Description,Category,Priority,Status,DueDate,CreatedAt,UpdatedAt,CompletedAt

# Example record
001,Deployment,Deploy staging environment,ops,HIGH,PENDING,2025-03-15,2025-03-01T09:00:00,2025-03-01T09:00:00,
```

### 6.3 cloudtask.log Format

Every line in the log follows this structure. The log is append-only and survives script restarts.

```
[2025-03-01T09:15:42] [INFO]  [add_task]    Task 001 created — Deploy staging environment (HIGH)
[2025-03-01T09:16:05] [INFO]  [s3_backup]   Backup uploaded → s3://helix-cloudtask-backup/backups/tasks_20250301_091605.csv
[2025-03-01T09:16:05] [INFO]  [sns_alert]   HIGH priority alert published for Task 001
[2025-03-01T09:16:06] [INFO]  [cw_log]      Log entry shipped to /cloudtask/prod
[2025-03-01T09:20:11] [WARN]  [s3_backup]   S3 backup failed — check credentials and bucket name
```

---

## 7. AWS Integration Behaviour

All three AWS calls run as background jobs (`&`). The user never waits for a network round-trip. If an AWS call fails, a `WARN` line is written to the local log and execution continues — local task data is never at risk.

| AWS Service | Trigger | Condition |
|---|---|---|
| S3 Backup | `add`, `update`, `delete`, `mark-complete` | Always — fires after every write |
| SNS Alert | `add_task()` only | Only when `Priority = HIGH` |
| CloudWatch | Every action including reads | Always — the `log()` function is the trigger |

> **Design Principle:** `tasks.csv` is always written and fsynced before any AWS call fires. A network failure can never corrupt local task data.

---

## 8. Task Lifecycle

```
         add_task()
            │
            ▼
        ┌─────────┐
        │ PENDING │ ◄─────────────────────────────┐
        └────┬────┘                               │
             │                                    │
    DueDate < today?                              │
             │                                    │
             ▼                                    │
        ┌─────────┐   mark_complete()   ┌─────────────┐
        │ OVERDUE │ ──────────────────► │  COMPLETED  │
        └────┬────┘                     └─────────────┘
             │                                    ▲
             │         mark_complete()            │
             └────────────────────────────────────┘
```

| State | Description |
|---|---|
| `PENDING` | Default state on creation. Task is outstanding. |
| `OVERDUE` | Derived display state only — not stored in CSV. Shown when `Status=PENDING` and `DueDate < today`. |
| `COMPLETED` | Set by Mark Complete (option 4). `CompletedAt` is stamped at this moment. |
| *(deleted)* | Record removed from `tasks.csv` after explicit `DELETE` confirmation. A local snapshot is taken first. |

**State rules:**
- A task is always born in `PENDING` — it cannot be created directly as `COMPLETED`
- `OVERDUE` is never written to `tasks.csv`; it is calculated at render time
- An overdue task can still be marked `COMPLETE` — the transition is always available
- Both `PENDING` and `COMPLETED` tasks can be deleted

---

## 9. Concurrency & Safety

The script uses a PID lock file (`~/.cloudtask/cloudtask.lock`) to prevent two instances from writing simultaneously. On startup, if the lock file exists and the PID inside it corresponds to a running process, the script exits with an error. The lock is always released via `trap release_lock EXIT`.

**Stale lock recovery:**

If the machine rebooted while the script was running, a stale lock file may be left behind. Remove it manually and rerun:

```bash
rm ~/.cloudtask/cloudtask.lock
./cloudtask.sh
```

Only do this if you are certain no other instance of `cloudtask.sh` is running.

---

## 10. Troubleshooting

| Symptom | Resolution |
|---|---|
| `Another instance is running` on startup | `rm ~/.cloudtask/cloudtask.lock` — only if no other instance is active |
| S3 backup `WARN` in log | Verify `AWS_REGION` and `S3_BUCKET` are exported and the bucket exists: `aws s3 ls s3://${S3_BUCKET}` |
| SNS alert not received | Check the SNS subscription is confirmed (email link). Verify `SNS_TOPIC_ARN` is correct. |
| CloudWatch entries missing | Confirm log group exists: `aws logs describe-log-groups --log-group-name-prefix '/cloudtask'` |
| `Permission denied` on `./cloudtask.sh` | `chmod +x cloudtask.sh` |
| Invalid date error on add | Dates must be `YYYY-MM-DD` and must be real calendar dates (e.g. `2025-02-30` is rejected) |
| `tasks.csv` shows only a header row | No tasks have been added yet — use option `1` from the menu |

---

## 11. Post-Submission Cleanup

> **Warning:** All resources fall within the AWS Free Tier. Delete them after submission to avoid unexpected charges.

```bash
# 1. Delete all objects in the S3 bucket, then delete the bucket
aws s3 rm s3://${S3_BUCKET} --recursive
aws s3 rb s3://${S3_BUCKET} --force

# 2. Delete the SNS topic (removes all subscriptions)
aws sns delete-topic --topic-arn ${SNS_TOPIC_ARN}

# 3. Delete the CloudWatch log group (removes all log streams too)
aws logs delete-log-group --log-group-name "/cloudtask/prod"

# 4. Remove local script data
rm -rf ~/.cloudtask
```

---

## 12. Project Structure

```
cloudtask-pro/
├── cloudtask.sh          ← fully commented Bash script (chmod +x)
├── README.md             ← this document
├── .gitignore            ← excludes *.lock, *.log, backups/
├── cloudtask.log         ← log from full test run (submitted evidence)
└── evidence.txt          ← proof of AWS integration firing
```

### .gitignore

```gitignore
# AWS credentials — never commit
.env
*.env

# Runtime data
*.lock
*.log

# Local backups
backups/
.cloudtask/

# macOS
.DS_Store
```


