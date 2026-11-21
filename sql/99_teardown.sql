-- =====================================================================
-- 99_teardown.sql — remove everything this demo created. Run as ACCOUNTADMIN.
-- It drops these objects BY NAME. If your account already has a database,
-- warehouse, resource monitor or role with one of these names that is not part
-- of this demo, do not run this script.
-- =====================================================================
DROP DATABASE IF EXISTS GENAI_INTENT_DETECTION;
DROP WAREHOUSE IF EXISTS GENAI_INTENT_DEMO_WH;
DROP RESOURCE MONITOR IF EXISTS GENAI_INTENT_DEMO_RM;
DROP ROLE IF EXISTS INTENT_CLASSIFIER_ROLE;
DROP ROLE IF EXISTS CUSTOMER_CARE_VULNERABILITY;
DROP ROLE IF EXISTS CONTACT_CENTRE_ANALYST;
