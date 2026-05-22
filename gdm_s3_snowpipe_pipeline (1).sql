------------------------------------------- Phase 1 ----------------------------------------------------

CREATE DATABASE GLOBAL_DATA_MART;  -- poore project ka main database
USE DATABASE GLOBAL_DATA_MART;

CREATE SCHEMA SALES; -- sales related ingestion aur processing ke liye schema
USE SCHEMA SALES;

use warehouse compute_wh;  -- queries aur loading execution ke liye compute warehouse

USE ROLE ACCOUNTADMIN;  -- storage integration aur external stages create karne ke liye

CREATE  STORAGE INTEGRATION s3_int     -- Snowflake ko securely S3 access dene ke liye
TYPE = EXTERNAL_STAGE                  -- IAM role based authentication use kiya gaya
STORAGE_PROVIDER = 'S3'
ENABLED = TRUE
STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::034917377686:role/global-data-mart'
STORAGE_ALLOWED_LOCATIONS = ('s3://global-data-mart-bucket/');

DESC STORAGE INTEGRATION s3_int;  -- integration details verify karne ke liye

--------------- JSON FILE FORMAT ----------------------
CREATE OR REPLACE FILE FORMAT json_format  -- NDJSON structure support ke liye
TYPE = JSON                                -- har line independent JSON object hai
STRIP_OUTER_ARRAY = FALSE;

--------------- CSV FILE FORMAT -----------------------
CREATE OR REPLACE FILE FORMAT csv_format  -- header ignore karne aur quoted values handle karne ke liye
TYPE = CSV
SKIP_HEADER = 1
FIELD_OPTIONALLY_ENCLOSED_BY = '"';

---------------- PARQUET FILE FORMAT --------------------
CREATE OR REPLACE FILE FORMAT parquet_format  -- parquet files ke liye native format
TYPE = PARQUET;

----------------- JSON TABLE ----------------------
CREATE OR REPLACE TABLE json_data (      -- semi-structured dynamic JSON data ke liye VARIANT datatype use kiya
    raw_data VARIANT
);

------------------ CSV TABLE ----------------------
CREATE OR REPLACE TABLE pos_transactions (        -- fixed schema transactional data
    transaction_id STRING,
    store_id STRING,
    store_name STRING,
    store_city STRING,
    store_region STRING,
    cashier_id STRING,
    customer_id STRING,
    
    transaction_date DATE,
    transaction_time STRING,
    
    product_sku STRING,
    product_name STRING,
    category STRING,
    subcategory STRING,
    quantity INT,
    
    unit_price FLOAT,
    discount_pct INT,
    total_amount FLOAT,
    payment_method STRING,
    loyalty_points INT
);

-------------------- ERP ORDERS TABLE ------------------
CREATE OR REPLACE TABLE erp_orders (           -- structured parquet order data
    order_id STRING,
    order_date DATE,
    
    store_id STRING,
    store_city STRING,
    
    supplier_id STRING,
    supplier_name STRING,
    supplier_city STRING,
    
    product_sku STRING,
    category STRING,
    quantity_ordered INT,
    quantity_received INT,
    
    unit_cost FLOAT,
    total_cost FLOAT,
    
    order_status STRING,
    expected_delivery DATE,
    actual_delivery DATE,
    warehouse_id STRING,
    lead_time_days INT,
    is_late BOOLEAN
);

----------------- ERP INVENTORY TABLE ---------------
CREATE OR REPLACE TABLE erp_inventory (              -- inventory related parquet data
    snapshot_date DATE,
    
    store_id STRING,
    warehouse_id STRING,
    
    product_sku STRING,
    category STRING,
    
    quantity_on_hand INT,
    reorder_level INT,
    max_stock_level INT,
    last_received_date DATE
);

----------------------- JSON STAGE --------------------
CREATE OR REPLACE STAGE json_stage          -- S3 json folder connect karne ke liye
URL='s3://global-data-mart-bucket/json/'
STORAGE_INTEGRATION = s3_int
FILE_FORMAT = json_format;

---------------------- CSV STAGE --------------------- 
CREATE OR REPLACE STAGE csv_stage          -- S3 csv folder connect karne ke liye
URL='s3://global-data-mart-bucket/ftp/csv/'
STORAGE_INTEGRATION = s3_int
FILE_FORMAT = csv_format;

--------------------------- PARQUET STAGE -----------------
CREATE OR REPLACE STAGE parquet_stage         -- S3 parquet folder connect karne ke liye
URL='s3://global-data-mart-bucket/ftp/parquet/'
STORAGE_INTEGRATION = s3_int
FILE_FORMAT = parquet_format;

------------------- stage files verify karne ke liye ---------------------
LIST @json_stage;
LIST @csv_stage;
LIST @parquet_stage;

--------------------------------------------------- Phase 2 ---------------------------------------------------------------

------------------- JSON SNOWPIPE ------------------------------
CREATE OR REPLACE PIPE json_pipe            -- realtime json ingestion ke liye
AUTO_INGEST = TRUE
AS
COPY INTO json_data
FROM @json_stage
FILE_FORMAT = (FORMAT_NAME = json_format);

------------------ CSV SNOWPIPE -----------------------
CREATE OR REPLACE PIPE csv_pipe           -- realtime csv ingestion ke liye
AUTO_INGEST = TRUE
AS
COPY INTO pos_transactions
FROM @csv_stage
FILE_FORMAT = (FORMAT_NAME = csv_format);

---------------- ERP ORDERS PIPE ---------------
CREATE OR REPLACE PIPE orders_pipe      -- sirf orders parquet files load karne ke liye
AUTO_INGEST = TRUE                       -- pattern filtering use ki gayi
AS
COPY INTO erp_orders
FROM @parquet_stage
FILE_FORMAT = (FORMAT_NAME = parquet_format)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
PATTERN='.*orders.*[.]parquet';

-------------- ERP INVENTORY PIPE ---------------
CREATE OR REPLACE PIPE inventory_pipe       -- sirf inventory parquet files load karne ke liye
AUTO_INGEST = TRUE
AS
COPY INTO erp_inventory
FROM @parquet_stage
FILE_FORMAT = (FORMAT_NAME = parquet_format)
MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE
PATTERN='.*inventory.*[.]parquet';

SHOW PIPES;    -- snowpipes verify karne ke liye

------------------------ existing S3 files manually ingest karne ke liye ---------------
ALTER PIPE csv_pipe REFRESH;
ALTER PIPE json_pipe REFRESH;
ALTER PIPE orders_pipe REFRESH;
ALTER PIPE inventory_pipe REFRESH;

----- Veriy Data --------------
SELECT * FROM pos_transactions;
SELECT * FROM erp_orders;
SELECT * FROM erp_inventory;

-- nested JSON arrays ko rows me convert karne ke liye LATERAL FLATTEN use kiya gaya kyuki JSON data nested structure me tha normal SELECT se poora nested array ek hi row me aa raha tha FLATTEN har JSON object ko separate row me tod deta hai analytics aur querying easy ho jati hai
SELECT value FROM json_data, LATERAL FLATTEN(input => raw_data);    

------------------------------------------------ Phase 3 -----------------------------------------------------

---------------------------------------- TRANSIENT TABLE ----------------------------------
Create or Replace Transient Table daily_sales_buffer AS  -- Phase 3 me TRANSIENT table feature implement karne ke liye use ki gayi
select * from pos_transactions;                          -- ye buffering/intermediate processing use-case ko represent karti hai
select * from daily_sales_buffer;                        -- fail-safe storage avoid karne aur storage cost optimize karne ke liye use hoti hai

----------------------------------------- TEMPORARY TABLE ---------------------------------------------
Create or Replace Temporary Table temp_iot_dedup AS  -- Phase 3 me TEMPORARY table feature demonstrate karne ke liye ek sample table create ki gayi
select * from json_data;                             -- ye temporary staging aur session-based processing use-case ko represent karti hai
-- saari tables ko temporary nahi banaya kyuki session end hote hi TEMP tables automatically delete ho jati hain
SELECT value FROM temp_iot_dedup, LATERAL FLATTEN(input => raw_data); 

----------------------------------------- TIME TRAVEL USING OFFSET ------------------------------- 
-- Phase 3 me Time Travel feature implement karne ke liye use kiya gaya
-- accidental data changes ko recover aur historical snapshot access karne ke liye helpful hai

UPDATE pos_transactions   -- temporary update perform kiya gaya taaki Time Travel restore test kiya ja sake
SET discount_pct = 99
WHERE discount_pct < 10;

SELECT DISTINCT discount_pct FROM pos_transactions;  -- current updated values verify karne ke liye


SELECT DISTINCT discount_pct                      -- OFFSET use karke 5 minute purana snapshot access kiya gaya
FROM pos_transactions AT(OFFSET => -300);         -- isse update se pehle ka original data visible hota hai

CREATE OR REPLACE TABLE pos_transactions AS        -- Time Travel snapshot use karke original table restore ki gayi
SELECT * FROM pos_transactions AT(OFFSET => -300);

SELECT DISTINCT discount_pct FROM pos_transactions;  -- restored original values verify karne ke liye


------------------------------------ Time Travel Using TIMESTAMP ----------------------------
-- Phase 3 me Time Travel TIMESTAMP feature implement karne ke liye use kiya gaya
-- TIMESTAMP exact historical date aur time ka snapshot access karne ke liye use hota hai
-- historical data verification aur recovery scenarios me helpful hai

SELECT CURRENT_TIMESTAMP;  -- current quantity values verify karne ke liye

SELECT DISTINCT quantity_ordered FROM erp_orders LIMIT 10;

UPDATE erp_orders            -- temporary update perform kiya gaya taaki Time Travel restore test kiya ja sake
SET quantity_ordered = 1546
WHERE order_id = 'ORD_000001';

SELECT quantity_ordered FROM erp_orders    -- exact historical TIMESTAMP snapshot access karke old value verify ki gayi
AT(TIMESTAMP => '2026-05-21 22:47:49.667 -0700') WHERE order_id = 'ORD_000001';

UPDATE erp_orders   -- BEFORE(STATEMENT) use karke update query execute hone se pehle ka data restore kiya gaya
SET quantity_ordered = (   -- ye query-based recovery aur accidental update rollback ke liye helpful hai
    SELECT quantity_ordered FROM erp_orders BEFORE(STATEMENT => '01c48833-3202-b787-0016-ff76000deb06')
    WHERE order_id = 'ORD_000001'
)
WHERE order_id = 'ORD_000001';

SELECT order_id, quantity_ordered FROM erp_orders
WHERE order_id = 'ORD_000001'; -- restored original value verify karne ke liye

-- OFFSET vs TIMESTAMP DIFFERENCE

-- OFFSET relative past time access karta hai
-- example: 5 minute pehle ka snapshot

-- TIMESTAMP exact historical date aur time ka snapshot access karta hai
-- example: specific timestamp par table kaisi thi

-- OFFSET quick recovery aur recent rollback scenarios me useful hai
-- TIMESTAMP audit, historical verification aur exact point-in-time recovery me better hai

-- production scenarios me TIMESTAMP zyada reliable aur preferred approach hoti hai

------------------------------------ UNDROP TABLE FEATURE -------------------------------
-- Phase 3 me accidental table deletion recovery demonstrate karne ke liye use kiya gaya
-- Snowflake deleted tables ko Time Travel ke through restore karne ki capability provide karta hai

SELECT COUNT(*) FROM erp_inventory;  -- current table data verify karne ke liye
DROP TABLE erp_inventory;   -- table intentionally drop ki gayi taaki recovery test ki ja sake

-- dropped table access verify karne ke liye
SELECT * FROM erp_inventory;   -- yaha error aayega kyuki table delete ho chuki hai

UNDROP TABLE erp_inventory;  -- deleted table ko restore karne ke liye UNDROP use kiya gaya

SELECT COUNT(*) FROM erp_inventory;   -- restored table aur data verify karne ke liye

--------------------------------------- FAIL-SAFE ANALYSIS ----------------------------------

-- Phase 3 me permanent aur transient tables ke storage behavior analyze karne ke liye use kiya gaya
-- fail-safe eligibility aur storage optimization concepts verify karne me helpful hai
SELECT * FROM INFORMATION_SCHEMA.TABLE_STORAGE_METRICS;

-------------------------------------- APPEND_ONLY STREAM -----------------------------------

-- insert-only change tracking aur CDC monitoring ke liye use kiya gaya
CREATE OR REPLACE STREAM inventory_stream ON TABLE erp_inventory APPEND_ONLY = TRUE;

SELECT * FROM inventory_stream;   -- stream data verify karne ke liye

INSERT INTO erp_inventory
SELECT * FROM erp_inventory LIMIT 1;  -- new insert perform kiya gaya taaki stream tracking test ki ja sake

SELECT * FROM inventory_stream;  -- newly captured inserted row verify karne ke liye

------------------------------------ STANDARD STREAM -------------------------------
-- STREAMS + TASKS IMPLEMENTATION
-- Phase 3 me CDC automation aur incremental processing implement karne ke liye use kiya gaya
-- Streams table changes capture karti hain Tasks automatically stream data process karti hain

-- POS transactions ke insert changes track karne ke liye
CREATE OR REPLACE STREAM pos_stream ON TABLE pos_transactions APPEND_ONLY = TRUE;

-- ERP orders ke insert, update aur delete changes track karne ke liye
CREATE OR REPLACE STREAM orders_stream ON TABLE erp_orders;

-- ERP inventory ke insert changes track karne ke liye
CREATE OR REPLACE STREAM inventory_stream ON TABLE erp_inventory APPEND_ONLY = TRUE;

-- JSON raw ingestion changes track karne ke liye
CREATE OR REPLACE STREAM json_stream ON TABLE json_data APPEND_ONLY = TRUE;

SHOW STREAMS;   -- STREAM VERIFICATION

------------ TASKS CREATION --------
CREATE OR REPLACE TASK pos_task  -- POS stream automation task
WAREHOUSE = compute_wh
SCHEDULE = '1 MINUTE'
AS SELECT * FROM pos_stream;

CREATE OR REPLACE TASK orders_task  -- ERP orders CDC automation task
WAREHOUSE = compute_wh
SCHEDULE = '1 MINUTE'
AS SELECT * FROM orders_stream;

CREATE OR REPLACE TASK inventory_task  -- ERP inventory stream automation task
WAREHOUSE = compute_wh
SCHEDULE = '1 MINUTE'
AS SELECT * FROM inventory_stream;

CREATE OR REPLACE TASK json_task  -- JSON ingestion stream automation task
WAREHOUSE = compute_wh
SCHEDULE = '1 MINUTE'
AS SELECT * FROM json_stream;

SHOW TASKS;   -- TASKS VERIFY

-- TASKS START
ALTER TASK pos_task RESUME;
ALTER TASK orders_task RESUME;
ALTER TASK inventory_task RESUME;
ALTER TASK json_task RESUME;

-- TASK HISTORY CHECK
SELECT * FROM TABLE( INFORMATION_SCHEMA.TASK_HISTORY() );

--------------------------------------------------- Phase 4 ----------------------------------------------

