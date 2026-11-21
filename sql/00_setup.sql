-- =====================================================================
-- 00_setup.sql — warehouse, cost guardrail, database and medallion schemas
-- Run as ACCOUNTADMIN (resource monitors need it).
-- =====================================================================

-- Cost guardrail 1: a dedicated, tiny warehouse that suspends after 60s idle.
CREATE WAREHOUSE IF NOT EXISTS GENAI_INTENT_DEMO_WH
    WAREHOUSE_SIZE      = 'XSMALL'
    AUTO_SUSPEND        = 60
    AUTO_RESUME         = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'GenAI intent detection article demo. XS, 60s auto-suspend.';

-- Cost guardrail 2: suspend the warehouse once it has used 5 credits in a month.
-- This is a threshold, not a precise limit: a warehouse can use a little more
-- before the suspension takes effect.
-- NOTE: a resource monitor covers WAREHOUSE compute only. Cortex AI function
-- tokens are billed separately and are NOT stopped by it, and nothing in these
-- scripts caps them. Track them in ACCOUNT_USAGE and add your own alert or
-- budget. For the ten transcripts here the token spend is about 0.02 credits.
CREATE RESOURCE MONITOR IF NOT EXISTS GENAI_INTENT_DEMO_RM
    WITH CREDIT_QUOTA = 5
         FREQUENCY = MONTHLY
         START_TIMESTAMP = IMMEDIATELY
    TRIGGERS ON 80  PERCENT DO NOTIFY
             ON 100 PERCENT DO SUSPEND_IMMEDIATE;

ALTER WAREHOUSE GENAI_INTENT_DEMO_WH SET RESOURCE_MONITOR = GENAI_INTENT_DEMO_RM;

USE WAREHOUSE GENAI_INTENT_DEMO_WH;

CREATE DATABASE IF NOT EXISTS GENAI_INTENT_DETECTION
    COMMENT = 'Part 1 of the GenAI intent detection series: the Snowflake pipeline.';

CREATE SCHEMA IF NOT EXISTS GENAI_INTENT_DETECTION.BRONZE
    COMMENT = 'Raw contact-centre exports as landed from S3. Ingest is out of scope for Part 1.';
CREATE SCHEMA IF NOT EXISTS GENAI_INTENT_DETECTION.SILVER
    COMMENT = 'Curated, PII-redacted transcripts. The ONLY text a model is allowed to read.';
CREATE SCHEMA IF NOT EXISTS GENAI_INTENT_DETECTION.GOLD
    COMMENT = 'Taxonomy/config tables, AI intent classifications and business views.';

-- Where inference is allowed to run is an ACCOUNT decision. This script only
-- READS the setting; it does not change it and does not refuse to continue if
-- it is not what you expect. The article was built with AWS_EU on an account
-- in AWS eu-west-1 (Ireland).
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
