<div align="center">

# Drive-to-S3 & FTP-to-Snowflake Data Pipeline

Automated multi-source pipeline: monitors Google Drive + FTP server, syncs files to Amazon S3 by file type, tracks uploads in DynamoDB, and loads data continuously into Snowflake — running 24/7 on EC2.

[![Python](https://img.shields.io/badge/Python-3.10+-3776AB?style=flat-square&logo=python&logoColor=white)](https://python.org)
[![AWS S3](https://img.shields.io/badge/AWS-S3-FF9900?style=flat-square&logo=amazons3&logoColor=white)](https://aws.amazon.com/s3/)
[![DynamoDB](https://img.shields.io/badge/AWS-DynamoDB-4053D6?style=flat-square&logo=amazondynamodb&logoColor=white)](https://aws.amazon.com/dynamodb/)
[![EC2](https://img.shields.io/badge/AWS-EC2-FF9900?style=flat-square&logo=amazonec2&logoColor=white)](https://aws.amazon.com/ec2/)
[![Google Drive](https://img.shields.io/badge/Google-Drive%20API-34A853?style=flat-square&logo=googledrive&logoColor=white)](https://developers.google.com/drive)
[![Snowflake](https://img.shields.io/badge/Snowflake-29B5E8?style=flat-square&logo=snowflake&logoColor=white)](https://www.snowflake.com/)

**Created by [Krish Kumawat](https://github.com/krishkumawat)**

</div>

---

## Table of Contents

- [Project Overview](#project-overview)
- [Phase 1 — Google Drive to S3](#phase-1--google-drive-to-s3)
  - [How It Works](#how-it-works)
  - [File Type Handling](#file-type-handling)
  - [Screenshots — Phase 1](#screenshots--phase-1)
  - [DynamoDB Status Schema](#dynamodb-status-schema)
  - [Setup and Installation](#setup-and-installation)
  - [Environment Variables](#environment-variables)
  - [EC2 Deployment Guide](#ec2-deployment-guide)
  - [Cron Job Setup](#cron-job-setup)
- [Phase 2 — FTP Server to S3 + Snowflake](#phase-2--ftp-server-to-s3--snowflake)
  - [FTP Architecture](#ftp-architecture)
  - [How the FTP Pipeline Works](#how-the-ftp-pipeline-works)
  - [Snowflake Integration](#snowflake-integration)
  - [Screenshots — Phase 2](#screenshots--phase-2)
  - [Challenges and Fixes](#challenges-and-fixes)
- [Project Structure](#project-structure)
- [Security Best Practices](#security-best-practices)

---

## Project Overview

This project has two phases built on the same EC2 instance and DynamoDB tracking layer:

**Phase 1 (Day 1):** Drop a `.json` file into a Google Drive folder — the system picks it up, uploads it to S3, and logs the result in DynamoDB. Other file types were detected but skipped; the Drive pipeline was scoped only for JSON at this stage.

**Phase 2 (Day 2):** Set up an FTP server, uploaded `.csv` and `.parquet` files to it, and wrote a Python automation that runs on EC2 every 5 minutes — extracts files from FTP, uploads them to a dedicated S3 folder structure based on timestamp and file type, updates DynamoDB, then Snowflake continuously ingests data from S3 using Snowpipe.

---

## Phase 1 — Google Drive to S3

### How It Works

**Step 1 — Cron triggers the script every 5 minutes** on the EC2 instance.

**Step 2 — Fetch files from Drive.** The script lists all files in the configured `Retail_Incoming_Data` folder using the Google Drive API with OAuth2.

**Step 3 — Check DynamoDB for each file.** Before downloading anything, the script queries DynamoDB using the file's unique `file_id`. If a record already exists with status `UPLOADED` or `ALREADY_EXISTS`, the file is skipped.

**Step 4 — Detect file type.** For new files, the script reads the file extension and MIME type. In Phase 1, only `.json` files were processed — all other types were logged and skipped.

**Step 5 — Download and upload to S3.** The `.json` file is downloaded from Drive to a temporary path, then uploaded to `s3://global-data-mart-bucket/json/filename`.

**Step 6 — Write status to DynamoDB.** After a successful upload, a record is written with `file_id`, `file_name`, `s3_path`, `status`, and `updated_at`.

> **Note:** In Phase 1, the EC2 instance was set up manually on Ubuntu without an IAM role. AWS credentials (`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`) were stored in the `.env` file on the server. IAM role attachment was not configured at this stage.

---

### File Type Handling

The pipeline detects all file types but in Phase 1 only JSON was uploaded:

| Extension | S3 Folder | Phase 1 Status |
|---|---|---|
| `.json` | `s3://bucket/json/` | ✅ Uploaded |
| `.csv` | `s3://bucket/csv/` | ⏭️ Skipped (Phase 2) |
| `.xlsx` | `s3://bucket/xlsx/` | ⏭️ Skipped |
| `.pdf` | `s3://bucket/pdf/` | ⏭️ Skipped |
| `.png`, `.jpg` | `s3://bucket/images/` | ⏭️ Skipped |
| `.parquet` | `s3://bucket/parquet/` | ⏭️ Skipped (Phase 2) |
| others | `s3://bucket/other/` | ⏭️ Skipped |

---

### Screenshots — Phase 1

#### Google Drive — Monitored Folder

The script watches the `Retail_Incoming_Data` folder. Any new `.json` file dropped here is automatically picked up on the next 5-minute cycle.

![Google Drive - Retail_Incoming_Data folder](images/drive-folder.png)

---

#### Amazon S3 — JSON Date Folder

Files are uploaded to `global-data-mart-bucket` under `json/YYYY-MM-DD/` date subfolders. The `2026-05-21/` folder contains 5 IoT event batch files (`iot_events_batch_01.json` through `_05.json`), each around 5.1 MB, auto-generated and uploaded on today's run.

![Amazon S3 - json/2026-05-21/ folder with iot_events batch files](images/s3-json-date-folder.png)

---

#### DynamoDB — File Upload Status Table

The `file_upload_status` table tracks every file processed. Each record shows the `file_id`, `file_name`, `s3_path`, `status`, and `updated_at` timestamp.

![DynamoDB - file_upload_status table](images/dynamodb-table.png)

---

#### EC2 Instance — Running 24/7

The automation runs on a `t3.micro` EC2 instance named `drive-automation` in the `ap-south-1` (Mumbai) region. Ubuntu Server 22.04 LTS. Instance state is `Running` with 3/3 status checks passed. Instance ID: `i-0e84981da80a8395d`.

![EC2 - drive-automation instance running in ap-south-1](images/ec2-instance.png)

---

#### Cron Job — 5-Minute Schedule on EC2

The crontab entry on the EC2 instance runs `automation.py` every 5 minutes and appends all output to `automation.log`.

![Cron job configured on EC2 via crontab](images/cron-job.png)

---

### DynamoDB Status Schema

**Table name:** `file_upload_status`  
**Primary key:** `file_id` (String)

| Attribute | Type | Description |
|---|---|---|
| `file_id` (PK) | String | Unique Google Drive file ID or FTP file path hash |
| `file_name` | String | Original file name |
| `original_file_id` | String | Source file ID (used for dedup check) |
| `s3_path` | String | Full S3 destination path |
| `status` | String | Current upload status |
| `updated_at` | String | ISO 8601 timestamp |

**Status values:**

| Status | Meaning |
|---|---|
| `UPLOADED` | Successfully uploaded to S3 |
| `ALREADY_EXISTS` | File found in a previous run — skipped |
| `UPLOADING` | Upload in progress |
| `DOWNLOADING` | Being downloaded from source |
| `DELETED` | File was removed from source or S3 |

---

### Setup and Installation

#### Prerequisites

- Python 3.10 or higher
- AWS account with S3, DynamoDB, and EC2 access
- Google Cloud project with Drive API enabled
- OAuth2 credentials (`credentials.json`) downloaded from Google Cloud Console

#### 1. Clone the repository

```bash
git clone https://github.com/krishkumawat/drive-to-s3-sync.git
cd drive-to-s3-sync
```

#### 2. Install dependencies

```bash
pip install -r requirements.txt
```

```
google-api-python-client
google-auth-httplib2
google-auth-oauthlib
boto3
python-dotenv
pysftp
pandas
pyarrow
fastparquet
```

#### 3. Set up Google Drive API

1. Go to [Google Cloud Console](https://console.cloud.google.com/) and create a project
2. Enable the **Google Drive API**
3. Create **OAuth 2.0 credentials** and download as `credentials.json`
4. Place `credentials.json` in the project root
5. Run the script once locally to complete the OAuth flow — this creates `token.json`

```bash
python3 automation.py
```

#### 4. Create AWS resources

```bash
# S3 bucket
aws s3 mb s3://global-data-mart-bucket --region ap-south-1

# DynamoDB table
aws dynamodb create-table \
  --table-name file_upload_status \
  --attribute-definitions AttributeName=file_id,AttributeType=S \
  --key-schema AttributeName=file_id,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region ap-south-1
```

---

### Environment Variables

```env
# Google Drive
DRIVE_FOLDER_ID=your_google_drive_folder_id

# AWS
AWS_ACCESS_KEY_ID=your_aws_access_key
AWS_SECRET_ACCESS_KEY=your_aws_secret_key
AWS_REGION=ap-south-1

# S3
S3_BUCKET_NAME=global-data-mart-bucket

# DynamoDB
DYNAMODB_TABLE_NAME=file_upload_status

# FTP (Phase 2)
FTP_HOST=your_ftp_host
FTP_USER=your_ftp_username
FTP_PASSWORD=your_ftp_password
FTP_REMOTE_DIR=/upload

# Snowflake (Phase 2)
SNOWFLAKE_ACCOUNT=your_account
SNOWFLAKE_USER=your_user
SNOWFLAKE_PASSWORD=your_password
SNOWFLAKE_DATABASE=your_database
SNOWFLAKE_SCHEMA=your_schema
SNOWFLAKE_WAREHOUSE=your_warehouse

# Optional
TEMP_DOWNLOAD_DIR=/tmp/drive_sync
LOG_LEVEL=INFO
```

> Never commit `.env`, `credentials.json`, or `token.json` to Git. All are listed in `.gitignore`.

---

### EC2 Deployment Guide

#### 1. Launch the instance

- **AMI:** Ubuntu Server 22.04 LTS
- **Instance type:** `t3.micro`
- **Region:** `ap-south-1` (Mumbai)
- **Security group:** Allow SSH (port 22) from your IP only

#### 2. Set up the environment on EC2

```bash
# SSH into EC2
ssh -i your-key.pem ubuntu@your-ec2-public-ip

# Install dependencies
sudo apt update && sudo apt install python3 python3-pip git -y

# Clone the repo
git clone https://github.com/krishkumawat/drive-to-s3-sync.git
cd drive-to-s3-sync
pip3 install -r requirements.txt
```

#### 3. Upload credentials from your local machine

```bash
scp -i your-key.pem credentials.json ubuntu@your-ec2-ip:~/drive-to-s3-sync/
scp -i your-key.pem token.json ubuntu@your-ec2-ip:~/drive-to-s3-sync/
scp -i your-key.pem .env ubuntu@your-ec2-ip:~/drive-to-s3-sync/
```

#### 4. Test manually

```bash
python3 automation.py
```

---

### Cron Job Setup

```bash
# Open crontab editor
crontab -e

# Add these lines (Phase 1 + Phase 2)
*/5 * * * * cd /home/ubuntu/drive_automation && /usr/bin/python3 automation.py >> automation.log 2>&1
*/5 * * * * cd /home/ubuntu/drive_automation && /usr/bin/python3 ftp_to_s3.py >> ftp.log 2>&1
```

Both scripts run every 5 minutes on the same EC2 instance — `automation.py` handles the Google Drive → S3 pipeline and `ftp_to_s3.py` handles the FTP → S3 → Snowflake pipeline.

Verify it is active:

```bash
crontab -l
tail -f /home/ubuntu/drive_automation/automation.log
tail -f /home/ubuntu/drive_automation/ftp.log
```

#### Cron Job — EC2 Screenshot

The crontab as it runs on the EC2 instance, showing both automation scripts scheduled every 5 minutes with separate log files.

![Cron job configured on EC2 with both automation.py and ftp_to_s3.py](images/cron-job.png)

---

## Phase 2 — FTP Server to S3 + Snowflake

### FTP Architecture

In Phase 2, an FTP server was set up as a new data source. The FTP server receives `.csv` and `.parquet` files, which are extracted by Python running on the same EC2 instance and uploaded to S3 under a folder structure based on file type and ingestion timestamp. From S3, Snowflake continuously loads the data using Snowpipe.

```
FTP Server (upload/)
    │
    │  pysftp / ftplib (EC2 Python script)
    ▼
Amazon S3 (global-data-mart-bucket)
    ├── ftp/csv/YYYY-MM-DD/filename.csv
    └── ftp/parquet/YYYY-MM-DD/filename.parquet
    │
    │  Snowpipe (auto-ingest via SQS)
    ▼
Snowflake Table
```

---

### How the FTP Pipeline Works

**Step 1 — Cron triggers `ftp_sync.py` every 5 minutes** on the EC2 instance (same cron schedule as the Drive pipeline).

**Step 2 — Connect to FTP server.** The script connects using credentials from `.env` and lists all files in the configured remote directory (`/upload`).

**Step 3 — Check DynamoDB for each file.** The script generates a unique key from `ftp_host + remote_path + filename` and queries DynamoDB. Files with status `UPLOADED` or `ALREADY_EXISTS` are skipped — no re-uploads.

**Step 4 — Detect file type.** The file extension (`.csv` or `.parquet`) determines the S3 destination subfolder.

**Step 5 — Download and upload to S3.** The file is downloaded to `/tmp/ftp_sync/`, then uploaded to:
- CSV: `s3://global-data-mart-bucket/ftp/csv/YYYY-MM-DD/filename.csv`
- Parquet: `s3://global-data-mart-bucket/ftp/parquet/YYYY-MM-DD/filename.parquet`

**Step 6 — Write status to DynamoDB.** Same schema as Phase 1 — `file_id`, `file_name`, `s3_path`, `status`, `updated_at`.

**Step 7 — Snowpipe auto-ingests.** Snowflake's Snowpipe listens for S3 PUT events via an SQS notification. As soon as a file lands in S3, Snowpipe queues it for loading into the target Snowflake table.

---

### Snowflake Integration

#### Storage Integration

A Storage Integration was created in Snowflake to allow secure, credential-free access to the S3 bucket. This avoids storing AWS keys inside Snowflake directly.

```sql
CREATE OR REPLACE STORAGE INTEGRATION s3_ftp_integration
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::YOUR_ACCOUNT_ID:role/snowflake-s3-role'
  STORAGE_ALLOWED_LOCATIONS = ('s3://global-data-mart-bucket/ftp/');

DESC INTEGRATION s3_ftp_integration;
-- Copy STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID
-- Add these as a trust relationship in the IAM role
```

#### External Stage

An External Stage points Snowflake to the S3 path where FTP-synced files land.

```sql
CREATE OR REPLACE STAGE ftp_data_stage
  STORAGE_INTEGRATION = s3_ftp_integration
  URL = 's3://global-data-mart-bucket/ftp/'
  FILE_FORMAT = (TYPE = 'CSV' FIELD_OPTIONALLY_ENCLOSED_BY = '"' SKIP_HEADER = 1);
```

#### Snowpipe

Snowpipe was configured with `AUTO_INGEST = TRUE` so that each new file arriving in S3 triggers automatic loading — no manual `COPY INTO` needed.

```sql
CREATE OR REPLACE PIPE ftp_csv_pipe
  AUTO_INGEST = TRUE
AS
  COPY INTO retail_data_table
  FROM @ftp_data_stage/csv/
  FILE_FORMAT = (TYPE = 'CSV' FIELD_OPTIONALLY_ENCLOSED_BY = '"' SKIP_HEADER = 1);

-- Get the SQS ARN from the pipe and configure it as an S3 event notification
SHOW PIPES;
```

After creating the pipe, the SQS ARN from `SHOW PIPES` was added to the S3 bucket's event notifications (PUT events on `ftp/csv/*` prefix) so Snowpipe receives a trigger for every new file.

---

### Screenshots — Phase 2

#### FileZilla — FTP Server Files

FileZilla connected to the FTP server at `sftp://3.109.139.36`. The remote `/home/ubuntu/ftp_files` directory contains 4 files: `sample_data.xlsx`, `pos_batch_sep_dec.xlsx`, `erp_orders.parquet`, and `erp_inventory.parquet` — these are the source files picked up by the EC2 automation script.

![FileZilla FTP client showing remote ftp_files directory with csv and parquet files](images/filezilla-ftp.png)

---

#### Amazon S3 — FTP Subfolder Structure

Files land in `global-data-mart-bucket` under `ftp/` with two subfolders — `csv/` and `parquet/` — created automatically based on file type during the first upload run.

![S3 bucket showing ftp/csv and ftp/parquet folders](images/s3-ftp-folders.png)

---

#### DynamoDB — Updated Table with FTP Records

The same `file_upload_status` table now contains records from both the Drive pipeline and the FTP pipeline. Records include statuses like `ALREADY_EXISTS`, `UPLOADING`, `DELETED`, and `ALREADY_E...` (already exists). FTP records use a composite key derived from `ftp_host + filepath`.

![DynamoDB table with Drive and FTP records](images/dynamodb-ftp-records.png)

---

#### Snowflake — Storage Integration

The `s3_int` storage integration links Snowflake to `s3://global-data-mart-bucket/` via IAM role `arn:aws:iam::034917377686:role/global-data-mart` — no hardcoded AWS credentials inside Snowflake. The `DESC STORAGE INTEGRATION` result confirms the IAM user ARN, role ARN, and external ID needed for the trust policy.

![Snowflake storage integration DESC output showing IAM ARN and external ID](images/snowflake-storage-integration.png)

---

#### Snowflake — Snowpipes (SHOW PIPES)

`SHOW PIPES` confirms 4 active pipes in the `GLOBAL_DATA_MART.SALES` schema: `CSV_PIPE`, `INVENTORY_PIPE`, `JSON_PIPE`, and `ORDERS_PIPE`. Each pipes data from its respective S3 stage (`@csv_stage`, `@parquet_stage`, `@json_stage`) into the target Snowflake tables using `COPY INTO`. The `ALTER PIPE ... REFRESH` commands were run to manually ingest existing S3 files, and verified with `SELECT * FROM pos_transactions`, `erp_orders`, and `erp_inventory`.

![Snowflake SHOW PIPES result with 4 pipes - CSV, INVENTORY, JSON, ORDERS](images/snowflake-snowpipe.png)

---

### Challenges and Fixes

#### 1. FTP Connection — `pysftp` vs `ftplib`

**Problem:** Initially tried `pysftp` (SFTP) but the server was plain FTP, not SFTP. The connection kept timing out with a `paramiko` host key error.

**Fix:** Switched to Python's built-in `ftplib.FTP` with passive mode enabled (`ftp.set_pasv(True)`), which resolved both the protocol mismatch and firewall issues with active FTP.

---

#### 2. Parquet Files — Schema Mismatch in Snowflake

**Problem:** Parquet files uploaded from the FTP server had different column orderings and data types across batches. Snowflake's `COPY INTO` was failing with schema mismatch errors when trying to load them directly.

**Fix:** Added a normalization step in the EC2 script using `pandas` + `pyarrow` — all parquet files are read, column names are lowercased and stripped of spaces, and the file is re-written before upload to S3. This ensured consistent schema for Snowpipe ingestion.

---

#### 3. Snowpipe SQS Notification — Delay and Missing Triggers

**Problem:** After setting up Snowpipe with `AUTO_INGEST = TRUE`, some files were not being ingested automatically. The SQS queue was receiving events but Snowpipe wasn't always picking them up in time.

**Fix:** Verified the SQS ARN from `SHOW PIPES` was correctly added to S3 event notifications with the right prefix filter (`ftp/csv/*`). Also ran `SELECT SYSTEM$PIPE_STATUS('ftp_csv_pipe')` to check the queue and found a few stuck messages — cleared them by manually calling `ALTER PIPE ftp_csv_pipe REFRESH`.

---

#### 4. DynamoDB Dedup for FTP Files

**Problem:** FTP files don't have a unique ID like Google Drive's `file_id`. On reruns, the same file was being re-downloaded and re-uploaded.

**Fix:** Generated a deterministic `file_id` by hashing `ftp_host + remote_file_path` using `hashlib.md5`. This produces a consistent key for the same file across script runs, enabling the same DynamoDB dedup logic used in Phase 1.

---

#### 5. EC2 Credentials — No IAM Role in Phase 1

**Problem:** In Phase 1, AWS credentials were stored directly in `.env` on the EC2 instance. This works but is a security risk — if the instance is compromised, the keys are exposed.

**Fix (Phase 2 improvement):** Attached an IAM role to the EC2 instance with scoped S3 and DynamoDB permissions. Removed `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` from `.env`. `boto3` automatically picks up credentials from the instance metadata service — no keys needed on disk.

---

## Project Structure

```
drive-to-s3-sync/
│
├── automation.py          # Phase 1: Drive → S3 main script
├── ftp_sync.py            # Phase 2: FTP → S3 main script
├── drive_client.py        # Google Drive API wrapper
├── ftp_client.py          # FTP connection and file listing
├── s3_client.py           # S3 upload logic
├── dynamo_client.py       # DynamoDB read/write
├── file_type_detector.py  # Extension and MIME type detection
├── parquet_normalizer.py  # Parquet schema normalization (Phase 2)
│
├── snowflake/
│   ├── create_integration.sql
│   ├── create_stage.sql
│   └── create_pipe.sql
│
├── credentials.json       # Google OAuth2 credentials  [not committed]
├── token.json             # Google OAuth2 token        [not committed]
├── .env                   # Environment variables      [not committed]
├── automation.log         # Runtime log output         [not committed]
│
├── requirements.txt
├── .gitignore
└── README.md
```

---

## Security Best Practices

- Use an **IAM role on EC2** instead of storing AWS keys in `.env` on the server (implemented in Phase 2)
- Never commit `credentials.json`, `token.json`, or `.env` — all are in `.gitignore`
- Restrict the EC2 security group to allow SSH only from your IP address
- Use a **Snowflake Storage Integration** with an IAM role — never store AWS keys inside Snowflake
- Enable **S3 bucket versioning** to protect against accidental overwrites
- Enable **DynamoDB Point-in-Time Recovery** for the `file_upload_status` table
- Rotate FTP credentials periodically and restrict FTP server access by IP if possible

---

<div align="center">
<sub>Built by Krish Kumawat &nbsp;·&nbsp; Phase 1: Google Drive → S3 &nbsp;·&nbsp; Phase 2: FTP → S3 → Snowflake &nbsp;·&nbsp; Runs 24/7 on AWS EC2 (ap-south-1)</sub>
</div>
