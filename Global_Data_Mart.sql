------------------------------------------- Phase 1 ----------------------------------------------------
CREATE DATABASE GLOBAL_DATA_MART;  -- poore project ka main database
USE DATABASE GLOBAL_DATA_MART;

CREATE SCHEMA SALES; -- sales related ingestion aur processing ke liye schema
USE SCHEMA SALES;

USE WAREHOUSE compute_wh;  -- queries aur loading execution ke liye compute warehouse

USE ROLE ACCOUNTADMIN;  -- storage integration aur external stages create karne ke liye

CREATE STORAGE INTEGRATION s3_int     -- Snowflake ko securely S3 access dene ke liye
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
CREATE OR REPLACE TABLE json_data   -- semi-structured dynamic JSON data ke liye VARIANT datatype use kiya
(
    raw_data VARIANT
);

------------------ CSV TABLE ----------------------
CREATE OR REPLACE TABLE pos_transactions (        -- fixed schema transactional data
    transaction_id   STRING,
    store_id         STRING,
    store_name       STRING,
    store_city       STRING,
    store_region     STRING,
    cashier_id       STRING,
    customer_id      STRING,

    transaction_date DATE,
    transaction_time STRING,

    product_sku      STRING,
    product_name     STRING,
    category         STRING,
    subcategory      STRING,
    quantity         INT,

    unit_price       FLOAT,
    discount_pct     INT,
    total_amount     FLOAT,
    payment_method   STRING,
    loyalty_points   INT
);

-------------------- ERP ORDERS TABLE ------------------
CREATE OR REPLACE TABLE erp_orders (           -- structured parquet order data
    order_id            STRING,
    order_date          DATE,

    store_id            STRING,
    store_city          STRING,

    supplier_id         STRING,
    supplier_name       STRING,
    supplier_city       STRING,

    product_sku         STRING,
    category            STRING,
    quantity_ordered    INT,
    quantity_received   INT,

    unit_cost           FLOAT,
    total_cost          FLOAT,

    order_status        STRING,
    expected_delivery   DATE,
    actual_delivery     DATE,
    warehouse_id        STRING,
    lead_time_days      INT,
    is_late             BOOLEAN
);

----------------- ERP INVENTORY TABLE ---------------
CREATE OR REPLACE TABLE erp_inventory (              -- inventory related parquet data
    snapshot_date      DATE,

    store_id           STRING,
    warehouse_id       STRING,

    product_sku        STRING,
    category           STRING,

    quantity_on_hand   INT,
    reorder_level      INT,
    max_stock_level    INT,
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

----- Verify Data --------------
SELECT * FROM pos_transactions;
SELECT * FROM erp_orders;
SELECT * FROM erp_inventory;

-- nested JSON arrays ko rows me convert karne ke liye LATERAL FLATTEN use kiya gaya
SELECT value FROM json_data, LATERAL FLATTEN(input => raw_data);

------------------------------------------------ Phase 3 -----------------------------------------------------

---------------------------------------- TRANSIENT TABLE ----------------------------------
CREATE OR REPLACE TRANSIENT TABLE daily_sales_buffer AS
SELECT * FROM pos_transactions;

SELECT * FROM daily_sales_buffer;

----------------------------------------- TEMPORARY TABLE ---------------------------------------------
CREATE OR REPLACE TEMPORARY TABLE temp_iot_dedup AS
SELECT * FROM json_data;

SELECT value FROM temp_iot_dedup, LATERAL FLATTEN(input => raw_data);

----------------------------------------- TIME TRAVEL USING OFFSET -------------------------------
-- UPDATE pos_transactions
-- SET discount_pct = 99
-- WHERE discount_pct < 10;

-- SELECT DISTINCT discount_pct FROM pos_transactions;

-- SELECT DISTINCT discount_pct
-- FROM pos_transactions AT(OFFSET => -300);

-- CREATE OR REPLACE TABLE pos_transactions AS
-- SELECT * FROM pos_transactions AT(OFFSET => -300);

-- SELECT DISTINCT discount_pct FROM pos_transactions;

------------------------------------ Time Travel Using TIMESTAMP ----------------------------
-- SELECT CURRENT_TIMESTAMP;

-- SELECT DISTINCT quantity_ordered FROM erp_orders LIMIT 10;

-- UPDATE erp_orders
-- SET quantity_ordered = 1546
-- WHERE order_id = 'ORD_000001';

-- SELECT quantity_ordered FROM erp_orders
-- AT(TIMESTAMP => '2026-05-21 22:47:49.667 -0700') WHERE order_id = 'ORD_000001';

-- UPDATE erp_orders
-- SET quantity_ordered = (
--     SELECT quantity_ordered FROM erp_orders BEFORE(STATEMENT => '01c48833-3202-b787-0016-ff76000deb06')
--     WHERE order_id = 'ORD_000001'
-- )
-- WHERE order_id = 'ORD_000001';

-- SELECT order_id, quantity_ordered FROM erp_orders
-- WHERE order_id = 'ORD_000001';

------------------------------------ UNDROP TABLE FEATURE -------------------------------
-- SELECT COUNT(*) FROM erp_inventory;
-- DROP TABLE erp_inventory;
-- SELECT * FROM erp_inventory;   -- error aayega
-- UNDROP TABLE erp_inventory;
-- SELECT COUNT(*) FROM erp_inventory;

--------------------------------------- FAIL-SAFE ANALYSIS ----------------------------------
-- SELECT * FROM INFORMATION_SCHEMA.TABLE_STORAGE_METRICS;

------------------------------------ STANDARD STREAM -------------------------------
CREATE OR REPLACE STREAM pos_stream       ON TABLE pos_transactions APPEND_ONLY = TRUE;
CREATE OR REPLACE STREAM orders_stream    ON TABLE erp_orders;
CREATE OR REPLACE STREAM inventory_stream ON TABLE erp_inventory   APPEND_ONLY = TRUE;
CREATE OR REPLACE STREAM json_stream      ON TABLE json_data        APPEND_ONLY = TRUE;

SHOW STREAMS;

--------------------------------------------------- Phase 4 ----------------------------------------------
-- CSV PIPELINE 
CREATE OR REPLACE SCHEMA staging;

-- RAW CSV TABLE (staging schema me) 
CREATE OR REPLACE TABLE staging.stg_csv_transaction (
    transaction_id   STRING,
    store_id         STRING,
    store_name       STRING,
    store_city       STRING,      
    store_region     STRING,      
    cashier_id       STRING,      
    customer_id      STRING,      
    product_sku      STRING,
    product_name     STRING,      
    category         STRING,      
    subcategory      STRING,      
    quantity         INT,
    unit_price       FLOAT,
    discount_pct     FLOAT,
    total_amount     FLOAT,       
    payment_method   STRING,      
    loyalty_points   INT,         
    transaction_ts   TIMESTAMP,
    source_file      STRING,
    loaded_time      TIMESTAMP
);

----------------------------------------------------------------------------------------------
-- CSV STREAM ← TABLE ke baad, PIPE se PEHLE
CREATE OR REPLACE STREAM staging.csv_stream_v2
ON TABLE staging.stg_csv_transaction
APPEND_ONLY = TRUE;

-----------------------------------------------------------------------------------------------
-- CSV STAGING SNOWPIPE
USE SCHEMA SALES;

CREATE OR REPLACE PIPE staging.csv_staging_pipe
AUTO_INGEST = TRUE
AS
COPY INTO staging.stg_csv_transaction (
    transaction_id,
    store_id,
    store_name,
    store_city,
    store_region,
    cashier_id,
    customer_id,
    product_sku,
    product_name,
    category,
    subcategory,
    quantity,
    unit_price,
    discount_pct,
    total_amount,
    payment_method,
    loyalty_points,
    transaction_ts,
    source_file,
    loaded_time
)
FROM (
    SELECT
        $1,                            -- transaction_id
        $2,                            -- store_id
        $3,                            -- store_name
        $4,                            -- store_city
        $5,                            -- store_region
        $6,                            -- cashier_id
        $7,                            -- customer_id
        $10,                           -- product_sku
        $11,                           -- product_name
        $12,                           -- category
        $13,                           -- subcategory
        $14::INT,                      -- quantity
        $15::FLOAT,                    -- unit_price
        $16::FLOAT,                    -- discount_pct
        $17::FLOAT,                    -- total_amount
        $18,                           -- payment_method
        $19::INT,                      -- loyalty_points
        ($8 || ' ' || $9)::TIMESTAMP,  -- transaction_date + time
        METADATA$FILENAME,             -- source_file
        CURRENT_TIMESTAMP()            -- loaded_time
    FROM @sales.csv_stage
)
FILE_FORMAT = (FORMAT_NAME = sales.csv_format);

ALTER PIPE staging.csv_staging_pipe REFRESH;

---------------------------------------------------------------------------------------------
-- SILVER CSV TABLE (sales schema me) 
USE SCHEMA SALES;

CREATE OR REPLACE TABLE sales.silver_csv_transaction (
    transaction_id   STRING,
    transaction_date DATE,
    transaction_time TIME,
    timezone         STRING,
    store_id         STRING,
    store_name       STRING,
    store_city       STRING,     
    store_region     STRING,      
    cashier_id       STRING,      
    customer_id      STRING,      
    product_sku      STRING,
    product_name     STRING,      
    category         STRING,     
    subcategory      STRING,    
    quantity         INT,
    unit_price       FLOAT,
    discount_pct     FLOAT,
    total_amount     FLOAT,      
    total_orderline  FLOAT,
    payment_method   STRING,      
    loyalty_points   INT,         
    source_file      STRING,      
    loaded_time      TIMESTAMP,   
    process_time     TIMESTAMP
);

------------------------------------------------------------------------------------------------------
-- TASK CSV → SILVER
CREATE OR REPLACE TASK sales.task_csv_to_silver
    WAREHOUSE = COMPUTE_WH
    SCHEDULE  = '1 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('GLOBAL_DATA_MART.STAGING.csv_stream_v2')
AS
INSERT INTO sales.silver_csv_transaction (
    transaction_id,
    transaction_date,
    transaction_time,
    timezone,
    store_id,
    store_name,
    store_city,
    store_region,
    cashier_id,
    customer_id,
    product_sku,
    product_name,
    category,
    subcategory,
    quantity,
    unit_price,
    discount_pct,
    total_amount,
    total_orderline,
    payment_method,
    loyalty_points,
    source_file,
    loaded_time,
    process_time
)
SELECT
    transaction_id,
    CAST(transaction_ts AS DATE),
    CAST(transaction_ts AS TIME),
    TO_VARCHAR(CURRENT_TIMESTAMP(), 'TZHTZM'),
    store_id,
    store_name,
    store_city,
    store_region,
    cashier_id,
    customer_id,
    product_sku,
    product_name,
    category,
    subcategory,
    CASE WHEN quantity     < 0 THEN 0 ELSE quantity     END,
    CASE WHEN unit_price   < 0 THEN 0 ELSE unit_price   END,
    CASE WHEN discount_pct < 0 THEN 0 ELSE discount_pct END,
    total_amount,
    (CASE WHEN quantity    < 0 THEN 0 ELSE quantity    END
     * CASE WHEN unit_price < 0 THEN 0 ELSE unit_price END)
    * (1 - (CASE WHEN discount_pct < 0 THEN 0 ELSE discount_pct END / 100)),
    payment_method,
    loyalty_points,
    source_file,
    loaded_time,
    CURRENT_TIMESTAMP()
FROM GLOBAL_DATA_MART.STAGING.csv_stream_v2;

ALTER TASK sales.task_csv_to_silver RESUME;
---------------------------------------------------------------------------------------------------------

-- RAW JSON TABLE  (staging schema me)
create or replace table staging.stg_json_iot (
    raw_payload  variant,
    source_file  string,
    loaded_time  timestamp
);

-------------------------------------------------------------------------------------------------
-- JSON STREAM  ← TABLE ke baad, PIPE se PEHLE
create or replace stream staging.json_stream1
on table staging.stg_json_iot
append_only = true;

---------------------------------------------------------------------------------------------------
-- JSON STAGING SNOWPIPE — S3 se staging table me data bhejne ke liye
USE SCHEMA SALES;

create or replace pipe staging.json_staging_pipe
auto_ingest = true
as
copy into staging.stg_json_iot (
    raw_payload,
    source_file,
    loaded_time
)
from (
    select
        $1,
        metadata$filename,
        current_timestamp()
    from @sales.json_stage
)
file_format = (format_name = sales.json_format);

ALTER PIPE staging.json_staging_pipe REFRESH;  -- existing S3 files manually load karne ke liye

--------------------------------------------------------------------------------------------
-- SILVER JSON TABLE  (sales schema me)
USE SCHEMA SALES;

create or replace table sales.silver_iot_events (
    event_id            string,
    event_type          string,
    store_id            string,
    store_name          string,
    event_ts            timestamp,
    device_id           string,
    firmware            string,
    battery_pct         int,
    store_floor         int,
    sensor_value        float,
    sensor_unit         string,
    source_file         string,
    loaded_time         timestamp,
    processed_timestamp timestamp,
    alert_type          string,   
    alert_severity      string    
);

-------------------------------------------------------------------------------------------------------
-- TASK JSON → SILVER  — full 3-part stream path use kiya
CREATE OR REPLACE TASK sales.task_json_to_silver
    WAREHOUSE = COMPUTE_WH
    SCHEDULE  = '1 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('GLOBAL_DATA_MART.STAGING.json_stream1')
AS
INSERT INTO sales.silver_iot_events (
    event_id, event_type, store_id, store_name, event_ts,
    device_id, firmware, battery_pct, store_floor,
    sensor_value, sensor_unit,
    alert_type, alert_severity,
    source_file, loaded_time, processed_timestamp
)
SELECT
    evt.value:event_id::STRING,
    evt.value:event_type::STRING,
    evt.value:store_id::STRING,
    evt.value:store_name::STRING,
    TO_TIMESTAMP(evt.value:timestamp::STRING),
    evt.value:device_id::STRING,
    evt.value:metadata.firmware::STRING,
    evt.value:metadata.battery_pct::INT,
    evt.value:metadata.store_floor::INT,
    rdg.value:value::FLOAT,
    rdg.value:unit::STRING,
    evt.value:alerts[0]:alert_type::STRING,
    evt.value:alerts[0]:severity::STRING,
    source_file,
    loaded_time,
    CURRENT_TIMESTAMP()
FROM global_data_mart.staging.json_stream1,
LATERAL FLATTEN(INPUT => raw_payload) evt,
LATERAL FLATTEN(INPUT => evt.value:readings) rdg;

ALTER TASK sales.task_json_to_silver RESUME;

--- VALIDATION — sab check karo ----
SHOW PIPES;
SHOW STREAMS;
SHOW TASKS;
----------------------------------------------------------------------------
-- Staging tables me data aaya?
SELECT COUNT(*) FROM staging.stg_csv_transaction;
SELECT COUNT(*) FROM staging.stg_json_iot;

-- Streams me data hai?
SELECT SYSTEM$STREAM_HAS_DATA('GLOBAL_DATA_MART.STAGING.csv_stream_v2');
SELECT SYSTEM$STREAM_HAS_DATA('GLOBAL_DATA_MART.STAGING.json_stream1');

-- Silver tables me data gaya?
SELECT * FROM sales.silver_csv_transaction limit 1;
SELECT * FROM sales.silver_iot_events;

-- Task history check karo
SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY()) ORDER BY SCHEDULED_TIME DESC LIMIT 10;

-----------------------------------------------------------------------------------------
-- BRONZE TABLE — erp_orders
create or replace table staging.iot_raw_bronze (
    order_id            STRING,
    order_date          DATE,
    store_id            STRING,
    store_city          STRING,
    supplier_id         STRING,
    supplier_name       STRING,
    supplier_city       STRING,
    product_sku         STRING,
    category            STRING,
    quantity_ordered    INT,
    quantity_received   INT,
    unit_cost           FLOAT,
    total_cost          FLOAT,
    order_status        STRING,
    expected_delivery   DATE,
    actual_delivery     DATE,
    warehouse_id        STRING,
    lead_time_days      INT,
    is_late             BOOLEAN,
    loaded_time         TIMESTAMP,
    source_file         STRING
);

--------------------------------------------------------------------------------------------------
-- STREAM ON BRONZE — pipe se pehle banana zaroori hai
CREATE OR REPLACE STREAM staging.orders_bronze_stream
ON TABLE staging.iot_raw_bronze
APPEND_ONLY = TRUE;

---------------------------------------------------------------------------------------------------
-- PIPE — S3 se bronze table me data bhejne ke liye
USE SCHEMA SALES;

create or replace pipe staging.orders_bronze_pipe
AUTO_INGEST = TRUE
AS
COPY INTO staging.iot_raw_bronze (
    order_id,
    order_date,
    store_id,
    store_city,
    supplier_id,
    supplier_name,
    supplier_city,
    product_sku,
    category,
    quantity_ordered,
    quantity_received,
    unit_cost,
    total_cost,
    order_status,
    expected_delivery,
    actual_delivery,
    warehouse_id,
    lead_time_days,
    is_late,
    loaded_time,
    source_file
)
FROM (
    SELECT
        $1:order_id::STRING,
        $1:order_date::DATE,
        $1:store_id::STRING,
        $1:store_city::STRING,
        $1:supplier_id::STRING,
        $1:supplier_name::STRING,
        $1:supplier_city::STRING,
        $1:product_sku::STRING,
        $1:category::STRING,
        $1:quantity_ordered::INT,
        $1:quantity_received::INT,
        $1:unit_cost::FLOAT,
        $1:total_cost::FLOAT,
        $1:order_status::STRING,
        $1:expected_delivery::DATE,
        $1:actual_delivery::DATE,
        $1:warehouse_id::STRING,
        $1:lead_time_days::INT,
        $1:is_late::BOOLEAN,
        CURRENT_TIMESTAMP(),
        METADATA$FILENAME
    from @sales.parquet_stage
)
FILE_FORMAT = (FORMAT_NAME = sales.parquet_format)
PATTERN = '.*orders.*[.]parquet';

alter pipe staging.orders_bronze_pipe refresh;

---------------------------------------------------------------------------------------------
-- SILVER TABLE — erp_orders silver
USE SCHEMA SALES;

create or replace table sales.silver_erp_orders (
    order_id            STRING,
    order_date          DATE,
    store_id            STRING,
    store_city          STRING,
    supplier_id         STRING,
    supplier_name       STRING,
    supplier_city       STRING,
    product_sku         STRING,
    category            STRING,
    quantity_ordered    INT,
    quantity_received   INT,
    unit_cost           FLOAT,
    total_cost          FLOAT,
    order_status        STRING,
    expected_delivery   DATE,
    actual_delivery     DATE,
    warehouse_id        STRING,
    lead_time_days      INT,
    is_late             BOOLEAN,
    loaded_time         TIMESTAMP,
    source_file         STRING,
    process_time        TIMESTAMP   
);

-------------------------------------------------------------------------------------------------------
-- TASK — Bronze se Silver me MERGE
create or replace task sales.task_orders_to_silver
    warehouse = COMPUTE_WH
    schedule  = '1 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('STAGING.orders_bronze_stream')
AS
merge into sales.silver_erp_orders AS tgt
USING (
    SELECT
        order_id,
        order_date,
        store_id,
        store_city,
        supplier_id,
        supplier_name,
        supplier_city,
        product_sku,
        category,
        quantity_ordered,
        quantity_received,
        unit_cost,
        total_cost,
        order_status,
        expected_delivery,
        actual_delivery,
        warehouse_id,
        lead_time_days,
        is_late,
        loaded_time,
        source_file
    FROM staging.orders_bronze_stream
) AS src
ON tgt.order_id = src.order_id

WHEN MATCHED THEN UPDATE SET
    tgt.order_date        = src.order_date,
    tgt.store_id          = src.store_id,
    tgt.store_city        = src.store_city,
    tgt.supplier_id       = src.supplier_id,
    tgt.supplier_name     = src.supplier_name,
    tgt.supplier_city     = src.supplier_city,
    tgt.product_sku       = src.product_sku,
    tgt.category          = src.category,
    tgt.quantity_ordered  = src.quantity_ordered,
    tgt.quantity_received = src.quantity_received,
    tgt.unit_cost         = src.unit_cost,
    tgt.total_cost        = src.total_cost,
    tgt.order_status      = src.order_status,
    tgt.expected_delivery = src.expected_delivery,
    tgt.actual_delivery   = src.actual_delivery,
    tgt.warehouse_id      = src.warehouse_id,
    tgt.lead_time_days    = src.lead_time_days,
    tgt.is_late           = src.is_late,
    tgt.loaded_time       = src.loaded_time,
    tgt.source_file       = src.source_file,
    tgt.process_time      = CURRENT_TIMESTAMP()

WHEN NOT MATCHED THEN INSERT (
    order_id, order_date, store_id, store_city,
    supplier_id, supplier_name, supplier_city,
    product_sku, category,
    quantity_ordered, quantity_received,
    unit_cost, total_cost,
    order_status, expected_delivery, actual_delivery,
    warehouse_id, lead_time_days, is_late,
    loaded_time, source_file, process_time
)
VALUES (
    src.order_id, src.order_date, src.store_id, src.store_city,
    src.supplier_id, src.supplier_name, src.supplier_city,
    src.product_sku, src.category,
    src.quantity_ordered, src.quantity_received,
    src.unit_cost, src.total_cost,
    src.order_status, src.expected_delivery, src.actual_delivery,
    src.warehouse_id, src.lead_time_days, src.is_late,
    src.loaded_time, src.source_file, CURRENT_TIMESTAMP()
);

ALTER TASK sales.task_orders_to_silver RESUME;

-- VALIDATION
SHOW PIPES;
SHOW STREAMS;
SHOW TASKS;

SELECT COUNT(*) FROM staging.iot_raw_bronze;
SELECT SYSTEM$STREAM_HAS_DATA('STAGING.orders_bronze_stream');
SELECT * FROM sales.silver_erp_orders;

SELECT * FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY())
ORDER BY SCHEDULED_TIME DESC LIMIT 10;

--------------------------------- Phase 5 -----------------------------
-- 1. GOLD SCHEMA + fact_decisions TABLE
--    source: silver_csv_transaction
create or replace schema global_data_mart.gold_mart;
use schema global_data_mart.gold_mart;

create or replace table global_data_mart.gold_mart.fact_decisions as
select store_id, store_name, store_city, store_region, category,

    cast(transaction_date as date)        as report_date,
    sum(total_orderline)                  as total_revenue,
    sum(quantity)                         as total_number_of_unit,
    count(distinct transaction_id)        as total_transaction,
    count(distinct customer_id)           as unique_customers,
    avg(total_orderline)                  as avg_cart,
    current_timestamp()                   as load_timestamp
    
from global_data_mart.sales.silver_csv_transaction
group by
    store_id,
    store_name,
    store_city,
    store_region,
    category,
    cast(transaction_date as date);

---------------------------------------------------------------------------------------------------------
-- KPI SUMMARY VIEW
CREATE OR REPLACE VIEW global_data_mart.gold_mart.fact_kpi_summary AS
SELECT
    COUNT(DISTINCT transaction_id)  AS total_transactions,
    COUNT(DISTINCT customer_id)     AS total_unique_customers,
    SUM(total_orderline)            AS total_revenue,
    AVG(discount_pct)               AS avg_discount,
    SUM(quantity)                   AS total_units
FROM global_data_mart.sales.silver_csv_transaction;

select * from global_data_mart.gold_mart.fact_kpi_summary;
----------------------------------------------------------------------------------------------------------
-- VIEW: store_revenue    last 30 days rolling revenue per store
CREATE OR REPLACE VIEW global_data_mart.gold_mart.store_revenue AS
SELECT 
    store_id, 
    store_name, 
    store_city, 
    store_region,
    SUM(total_revenue)       AS rolling_revenue,
    SUM(total_number_of_unit) AS rolling_units,
    SUM(total_transaction)   AS rolling_transactions,
    SUM(unique_customers)    AS rolling_customers,
    MIN(report_date)         AS from_date,
    MAX(report_date)         AS to_date
FROM global_data_mart.gold_mart.fact_decisions
WHERE report_date >= DATEADD(day, -30, (SELECT MAX(report_date) FROM global_data_mart.gold_mart.fact_decisions))
GROUP BY store_id, store_name, store_city, store_region;

SELECT * FROM global_data_mart.gold_mart.store_revenue;

-------------------------------------------------------------------------------------------------------
-- MATERIALIZED VIEW: matelized_view_category_by_region
CREATE OR REPLACE MATERIALIZED VIEW global_data_mart.gold_mart.matelized_view_category_by_region AS
SELECT category, store_region,

    SUM(total_revenue)        AS total_revenue,
    SUM(total_number_of_unit) AS total_units,
    COUNT(store_id)           AS total_unique_stores
    
FROM global_data_mart.gold_mart.fact_decisions
GROUP BY category, store_region;

select * from global_data_mart.gold_mart.matelized_view_category_by_region;
-------------------------------------------------------------------------------------------------
-- DAILY REVENUE — View On transaction level (bina payment ke)
CREATE OR REPLACE VIEW global_data_mart.gold_mart.fact_daily_revenue AS
SELECT
    CAST(transaction_date AS DATE)     AS transaction_date,
    SUM(total_orderline)               AS daily_revenue,
    COUNT(transaction_id)              AS number_of_transactions,
    COUNT(DISTINCT transaction_id)     AS unique_transactions,
    COUNT(DISTINCT customer_id)        AS unique_customers,
    AVG(total_orderline)               AS avg_cart_size
FROM global_data_mart.sales.silver_csv_transaction
GROUP BY CAST(transaction_date AS DATE)
ORDER BY transaction_date DESC;

select * from global_data_mart.gold_mart.fact_daily_revenue;
--------------------------------------------------------------------------------------------------
-- DAILY REVENUE — payment_method ke saath bhi same columns
select
    cast(transaction_date as date)     as transaction_date,
    payment_method,
    
    sum(total_orderline)               as daily_revenue,
    count(transaction_id)              as number_of_transactions,
    count(distinct transaction_id)     as unique_transactions,
    count(distinct customer_id)        as unique_customers,
    avg(total_orderline)               as avg_cart_size,
    max(total_orderline)               as max_cart
    
from global_data_mart.sales.silver_csv_transaction
group by cast(transaction_date as date), payment_method
order by transaction_date desc, payment_method;


----------------------------------------------------------------------------------------------------
-- SENSOR INFO
select store_name,

    sensor_unit              as sensor_name,
    avg(sensor_value)        as avg_sensor_value,
    min(sensor_value)        as min_sensor_value,
    max(sensor_value)        as max_sensor_value
    
from global_data_mart.sales.silver_iot_events
group by store_name, sensor_unit
order by store_name, sensor_unit;

-- STORE + EVENT_TYPE SENSOR SUMMARY
select store_name, event_type, 

    avg(sensor_value)    as avg_sensor_value,
    min(sensor_value)    as min_sensor_value,
    count(*)             as total_event_count
    
from global_data_mart.sales.silver_iot_events
group by store_name, event_type
order by store_name, event_type;

---------------------------------------------------------------------------------------------------------
-- JOIN TRANSACTIONS + SENSOR
-- store_id, store_name, sale_date,
select t.store_id, t.store_name,

    cast(t.transaction_date as date)    as sale_date,
    sum(t.total_orderline)              as total_revenue,
    count(distinct t.transaction_id)    as unique_transactions,
    avg(s.sensor_value)                 as avg_self_value
    
from global_data_mart.sales.silver_csv_transaction t
join global_data_mart.sales.silver_iot_events s
    on  t.store_id = s.store_id
    and cast(t.transaction_date as date) = cast(s.event_ts as date)
    
where lower(s.sensor_unit) like '%kg%'

group by t.store_id, t.store_name, cast(t.transaction_date as date)
order by sale_date desc, t.store_name;

---------------------------------------------------------------------------------------------------------------
-- setup
use schema gold_mart;
--  fact_gross_margin
--  join: silver_csv_transaction (pos) + silver_erp_orders (erp)
--  on: store_id + category
CREATE OR REPLACE TABLE global_data_mart.gold_mart.fact_gross_margin AS
WITH pos_agg AS (
    SELECT 
        store_id, store_name, store_city, category,
        ROUND(SUM(total_orderline), 2) AS total_revenue,
        SUM(quantity) AS total_units_sold
    FROM global_data_mart.sales.silver_csv_transaction
    GROUP BY store_id, store_name, store_city, category
),
erp_agg AS (
    SELECT 
        store_id, category,
        ROUND(AVG(unit_cost), 2) AS total_cost,
        COUNT(DISTINCT order_id) AS total_orders
    FROM global_data_mart.sales.silver_erp_orders
    GROUP BY store_id, category
)
SELECT 
    p.store_id, p.store_name, p.store_city, p.category,
    p.total_revenue,
    ROUND(p.total_units_sold * e.total_cost, 2) AS total_cost,
    ROUND(p.total_revenue - (p.total_units_sold * e.total_cost), 2) AS total_gross_profit,
    ROUND((p.total_revenue - (p.total_units_sold * e.total_cost)) / NULLIF(p.total_revenue, 0) * 100, 2) AS gross_profit_margin,
    p.total_units_sold,
    e.total_orders
FROM pos_agg p
JOIN erp_agg e
    ON p.store_id = e.store_id
    AND p.category = e.category;

select * from global_data_mart.gold_mart.fact_gross_margin limit 5;
select count(*) from global_data_mart.gold_mart.fact_gross_margin;

-------------------------------------------------------------------------------------------------------
--  fact_iot_store_daily  (pivot table)
--  source: silver_iot_events
create or replace table global_data_mart.gold_mart.fact_iot_store_daily as
select cast(event_ts as date) as event_date, store_id, store_name,

    -- pivot: har sensor ka avg alag column me
    round(avg(case when sensor_unit = 'kg' then sensor_value end), 2)  as avg_weight,
    round(avg(case when sensor_unit = 'celsius' then sensor_value end), 2)  as avg_temperature,
    round(avg(case when sensor_unit = 'percent' and event_type  = 'entrance_gate' then sensor_value end), 2) as avg_occupancy,
    round(avg(case when sensor_unit = 'count' and event_type  = 'entrance_gate' then sensor_value end), 2) as avg_footfall,
    round(avg(case when sensor_unit = 'percent' and event_type  = 'cold_storage' then sensor_value end), 2) as avg_humidity,
    round(avg(case when sensor_unit = 'count' and event_type  = 'energy_meter' then sensor_value end), 2) as avg_power,

   -- ✅ SAHI — silver mein has_alert column ke baad
    COUNT(DISTINCT CASE WHEN alert_type IS NOT NULL THEN event_id END) AS total_number_of_alerts

from global_data_mart.sales.silver_iot_events
group by cast(event_ts as date), store_id, store_name;

select * from global_data_mart.gold_mart.fact_iot_store_daily;
select count(*) from global_data_mart.gold_mart.fact_iot_store_daily;

------------------------------------------------------------------------------------------------------------
-- sensor value by sensor name using case when
-- weight_kg  → average_value, occupancy_pct  → occupancy_percentage, humidity_pct   → humidity_percentage

select store_id, store_name, cast(event_ts as date) as event_date,

    round(avg(case when sensor_unit = 'kg' then sensor_value end), 2) as average_value,

    round(avg(case when sensor_unit = 'percent' and event_type  = 'entrance_gate' then sensor_value end), 2) as occupancy_percentage,

    round(avg(case when sensor_unit = 'percent' and event_type  = 'cold_storage' then sensor_value end), 2) as humidity_percentage

from global_data_mart.sales.silver_iot_events
group by store_id, store_name, cast(event_ts as date)
order by event_date, store_name;

---------------------------------------------------------------------------------------------------------------
--  fact_sales_verses_iot
--  join: fact_decisions + fact_iot_store_daily
--  on: store_id + report_date = event_date
create or replace table global_data_mart.gold_mart.fact_sales_verses_iot as
select
    f.report_date,
    f.store_id,
    f.store_name,
    f.category,
    f.total_transaction,
    round(f.total_revenue, 2)    as total_revenue,
    round(f.avg_cart, 2)         as avg_basket_size,
    round(i.avg_temperature, 2)  as avg_temperature,
    round(i.avg_power, 2)      as avg_power,
    round(i.avg_footfall, 2)   as avg_footfall,
    i.total_number_of_alerts   as avg_alerts,
    round(i.avg_occupancy, 2)  as avg_occupancy
    
from global_data_mart.gold_mart.fact_decisions f
join global_data_mart.gold_mart.fact_iot_store_daily i
    on  f.store_id    = i.store_id
    and f.report_date = i.event_date;

select * from global_data_mart.gold_mart.fact_sales_verses_iot;
select count(*) from global_data_mart.gold_mart.fact_sales_verses_iot;

