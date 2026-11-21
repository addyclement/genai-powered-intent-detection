-- =====================================================================
-- 50_governance.sql — tags, masking, roles and a data-quality check
-- Run as ACCOUNTADMIN. Tags, masking policies and data metric functions
-- require Snowflake Enterprise Edition or higher. Safe to re-run.
-- =====================================================================
USE WAREHOUSE GENAI_INTENT_DEMO_WH;
USE DATABASE GENAI_INTENT_DETECTION;
CREATE SCHEMA IF NOT EXISTS GENAI_INTENT_DETECTION.GOVERNANCE
    COMMENT = 'Tags and policies for the intent pipeline.';
USE SCHEMA GOVERNANCE;

-- ---------------------------------------------------------------------
-- 1. Classification tag: what kind of personal data each layer holds.
--    Tags DOCUMENT a position and make it queryable. They enforce nothing;
--    grants do that. PII_REDACTED means "direct identifiers have been
--    replaced". It is a label for what the redaction stage is meant to have
--    done, not proof that it worked, and redacted text is still personal data.
-- ---------------------------------------------------------------------
CREATE TAG IF NOT EXISTS GOVERNANCE.DATA_SENSITIVITY
    ALLOWED_VALUES 'PII', 'PII_REDACTED', 'DERIVED_SENSITIVE', 'REFERENCE'
    COMMENT = 'PII = raw identifiers; PII_REDACTED = direct identifiers replaced; DERIVED_SENSITIVE = inferences about a person (e.g. vulnerability).';

ALTER SCHEMA GENAI_INTENT_DETECTION.BRONZE        SET TAG GOVERNANCE.DATA_SENSITIVITY = 'PII';
ALTER TABLE  GENAI_INTENT_DETECTION.SILVER.CONTACT_TRANSCRIPTS SET TAG GOVERNANCE.DATA_SENSITIVITY = 'PII_REDACTED';
-- Gold holds no raw identifiers, but an inference that a customer is
-- vulnerable is still sensitive once it is joined back to the account.
ALTER TABLE  GENAI_INTENT_DETECTION.GOLD.CONTACT_INTENT        SET TAG GOVERNANCE.DATA_SENSITIVITY = 'DERIVED_SENSITIVE';
ALTER TABLE  GENAI_INTENT_DETECTION.GOLD.INTENT_CATALOGUE      SET TAG GOVERNANCE.DATA_SENSITIVITY = 'REFERENCE';

-- ---------------------------------------------------------------------
-- 2. Masking: only the vulnerability team reads WHY a customer was flagged.
--    The disclosure can appear in three places: the reason, the rationale and
--    the model's raw response. The raw response is hidden completely from
--    everyone else, because it is unvalidated: a model that put a sentence
--    where a label should be would otherwise leak it.
--
--    The role is granted to named users only. It is deliberately NOT granted
--    to SYSADMIN: IS_ROLE_IN_SESSION follows the role hierarchy, so any role
--    that inherits it would see the unmasked text.
--
--    CREATE ... IF NOT EXISTS followed by ALTER ... SET BODY makes this
--    re-runnable AND lets a changed policy definition take effect.
-- ---------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS CUSTOMER_CARE_VULNERABILITY;

CREATE MASKING POLICY IF NOT EXISTS GOVERNANCE.MASK_VULNERABILITY_TEXT
    AS (val STRING) RETURNS STRING -> val;
ALTER MASKING POLICY GOVERNANCE.MASK_VULNERABILITY_TEXT SET BODY ->
    CASE WHEN IS_ROLE_IN_SESSION('CUSTOMER_CARE_VULNERABILITY') THEN val
         WHEN val IS NULL THEN NULL
         ELSE '*** restricted: vulnerability team only ***' END;

CREATE MASKING POLICY IF NOT EXISTS GOVERNANCE.MASK_RAW_RESPONSE
    AS (val VARIANT) RETURNS VARIANT -> val;
ALTER MASKING POLICY GOVERNANCE.MASK_RAW_RESPONSE SET BODY ->
    CASE WHEN IS_ROLE_IN_SESSION('CUSTOMER_CARE_VULNERABILITY') THEN val
         ELSE NULL END;

ALTER TABLE GENAI_INTENT_DETECTION.GOLD.CONTACT_INTENT MODIFY
    COLUMN VULNERABILITY_REASON SET MASKING POLICY GOVERNANCE.MASK_VULNERABILITY_TEXT FORCE,
    COLUMN RATIONALE            SET MASKING POLICY GOVERNANCE.MASK_VULNERABILITY_TEXT FORCE,
    COLUMN RAW_RESPONSE         SET MASKING POLICY GOVERNANCE.MASK_RAW_RESPONSE FORCE;

-- ---------------------------------------------------------------------
-- 3. Roles. Three of them, each with only what it needs.
--
--    INTENT_CLASSIFIER_ROLE       runs the procedure: reads silver and the
--                                 config, writes gold. No grant on bronze.
--    CONTACT_CENTRE_ANALYST       reads the business views. Sees the
--                                 vulnerability flag, not the reason.
--    CUSTOMER_CARE_VULNERABILITY  reads the same views and the gold table,
--                                 unmasked.
--
--    The procedure is EXECUTE AS CALLER: it runs with the role that calls it.
--    These grants are the limit only if you call it under
--    INTENT_CLASSIFIER_ROLE with secondary roles switched off.
--    No CREATE TABLE grant is needed: the procedure's batch table is
--    temporary, and creating a temporary table needs only USAGE on the schema.
-- ---------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS INTENT_CLASSIFIER_ROLE;
GRANT USAGE  ON WAREHOUSE GENAI_INTENT_DEMO_WH                                TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT USAGE  ON DATABASE  GENAI_INTENT_DETECTION                              TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT USAGE  ON SCHEMA    GENAI_INTENT_DETECTION.SILVER                       TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT USAGE  ON SCHEMA    GENAI_INTENT_DETECTION.GOLD                         TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT SELECT ON TABLE GENAI_INTENT_DETECTION.SILVER.CONTACT_TRANSCRIPTS       TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT SELECT ON TABLE GENAI_INTENT_DETECTION.GOLD.CLASSIFIER_CONFIG           TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT SELECT ON TABLE GENAI_INTENT_DETECTION.GOLD.INTENT_CATALOGUE            TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT SELECT ON TABLE GENAI_INTENT_DETECTION.GOLD.INTENT_FAMILY               TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT SELECT ON VIEW  GENAI_INTENT_DETECTION.GOLD.V_KEYWORD_BOT               TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT SELECT, INSERT ON TABLE GENAI_INTENT_DETECTION.GOLD.CONTACT_INTENT      TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT INSERT ON TABLE GENAI_INTENT_DETECTION.GOLD.CLASSIFICATION_RUN_LOG      TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT USAGE  ON PROCEDURE GENAI_INTENT_DETECTION.GOLD.SP_CLASSIFY_SILVER_TO_GOLD(NUMBER) TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER                                     TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT APPLICATION ROLE SNOWFLAKE."CORTEX-MODEL-ROLE-CLAUDE-HAIKU-4-5"         TO ROLE INTENT_CLASSIFIER_ROLE;
GRANT ROLE INTENT_CLASSIFIER_ROLE TO ROLE SYSADMIN;

CREATE ROLE IF NOT EXISTS CONTACT_CENTRE_ANALYST;
GRANT USAGE  ON WAREHOUSE GENAI_INTENT_DEMO_WH                                TO ROLE CONTACT_CENTRE_ANALYST;
GRANT USAGE  ON DATABASE  GENAI_INTENT_DETECTION                              TO ROLE CONTACT_CENTRE_ANALYST;
GRANT USAGE  ON SCHEMA    GENAI_INTENT_DETECTION.GOLD                         TO ROLE CONTACT_CENTRE_ANALYST;
GRANT SELECT ON VIEW GENAI_INTENT_DETECTION.GOLD.V_TRIAGE_QUEUE               TO ROLE CONTACT_CENTRE_ANALYST;
GRANT SELECT ON VIEW GENAI_INTENT_DETECTION.GOLD.V_VULNERABLE_CUSTOMERS       TO ROLE CONTACT_CENTRE_ANALYST;
GRANT SELECT ON VIEW GENAI_INTENT_DETECTION.GOLD.V_INTENT_BY_FAMILY           TO ROLE CONTACT_CENTRE_ANALYST;
GRANT ROLE CONTACT_CENTRE_ANALYST TO ROLE SYSADMIN;

GRANT USAGE  ON WAREHOUSE GENAI_INTENT_DEMO_WH                                TO ROLE CUSTOMER_CARE_VULNERABILITY;
GRANT USAGE  ON DATABASE  GENAI_INTENT_DETECTION                              TO ROLE CUSTOMER_CARE_VULNERABILITY;
GRANT USAGE  ON SCHEMA    GENAI_INTENT_DETECTION.GOLD                         TO ROLE CUSTOMER_CARE_VULNERABILITY;
GRANT SELECT ON TABLE GENAI_INTENT_DETECTION.GOLD.CONTACT_INTENT              TO ROLE CUSTOMER_CARE_VULNERABILITY;
GRANT SELECT ON VIEW GENAI_INTENT_DETECTION.GOLD.V_TRIAGE_QUEUE               TO ROLE CUSTOMER_CARE_VULNERABILITY;
GRANT SELECT ON VIEW GENAI_INTENT_DETECTION.GOLD.V_VULNERABLE_CUSTOMERS       TO ROLE CUSTOMER_CARE_VULNERABILITY;
GRANT SELECT ON VIEW GENAI_INTENT_DETECTION.GOLD.V_INTENT_BY_FAMILY           TO ROLE CUSTOMER_CARE_VULNERABILITY;
SET DEPLOYING_USER = CURRENT_USER();
GRANT ROLE CUSTOMER_CARE_VULNERABILITY TO USER IDENTIFIER($DEPLOYING_USER);

-- ---------------------------------------------------------------------
-- 4. What these scripts do NOT lock down: access to models.
--
--    The grant of CORTEX-MODEL-ROLE-CLAUDE-HAIKU-4-5 above says the classifier
--    role MAY call that model. On a default account it restricts nothing,
--    because every role can already call every model:
--      * USE AI FUNCTIONS and SNOWFLAKE.CORTEX_USER are granted to PUBLIC
--        (this script relies on that for USE AI FUNCTIONS; an account that
--        has revoked it must grant it to INTENT_CLASSIFIER_ROLE);
--      * CORTEX-MODEL-ROLE-ALL reaches every role through the
--        SNOWFLAKE.PUBLIC application role;
--      * CORTEX_MODELS_ALLOWLIST defaults to 'ALL' (and is being retired:
--        under behaviour change bundle 2026_07 it is no longer consulted).
--    Restricting a role to one model is therefore an ACCOUNT-WIDE exercise:
--    remove the broad grants, check what PUBLIC still inherits, then grant
--    per-model roles to the roles that need them. It affects every user of
--    Cortex in the account, so it is deliberately left out of a demo script.
--    See "Privileges and model access for Cortex AI Functions" in the docs.
--    The statements below only show you where the account stands.
-- ---------------------------------------------------------------------
SHOW PARAMETERS LIKE 'CORTEX_MODELS_ALLOWLIST' IN ACCOUNT;

-- ---------------------------------------------------------------------
-- 5. Data quality: count gold rows that carry a data-quality reason.
--    The procedure never stores a label that is outside the taxonomy as if it
--    were valid; it records a reason instead. This metric counts those rows.
--    It is a narrow, cumulative check: it says nothing about whether valid
--    labels are CORRECT, and it never sees contacts the model returned
--    nothing for (those are in CLASSIFICATION_RUN_LOG.ROWS_FAILED).
--    ACCEPTED_VALUES returns the number of rows that do NOT satisfy the
--    expression. TRIGGER_ON_CHANGES measures when the table's data changes.
--    Data metric functions run on serverless compute, billed separately.
--    Results: SNOWFLAKE.LOCAL.DATA_QUALITY_MONITORING_RESULTS.
-- ---------------------------------------------------------------------
ALTER TABLE GENAI_INTENT_DETECTION.GOLD.CONTACT_INTENT
    SET DATA_METRIC_SCHEDULE = 'TRIGGER_ON_CHANGES';

-- Attach the metric only if it is not attached already. Any other failure
-- (missing privilege, unsupported edition) is NOT swallowed.
EXECUTE IMMEDIATE $$
DECLARE
    already_attached NUMBER;
BEGIN
    SELECT COUNT(*) INTO :already_attached
    FROM TABLE(GENAI_INTENT_DETECTION.INFORMATION_SCHEMA.DATA_METRIC_FUNCTION_REFERENCES(
            REF_ENTITY_NAME   => 'GENAI_INTENT_DETECTION.GOLD.CONTACT_INTENT',
            REF_ENTITY_DOMAIN => 'TABLE'))
    WHERE METRIC_NAME = 'ACCEPTED_VALUES';

    IF (already_attached = 0) THEN
        ALTER TABLE GENAI_INTENT_DETECTION.GOLD.CONTACT_INTENT
            ADD DATA METRIC FUNCTION SNOWFLAKE.CORE.ACCEPTED_VALUES
            ON (DATA_QUALITY_REASON, DATA_QUALITY_REASON -> DATA_QUALITY_REASON IS NULL);
        RETURN 'Data metric function attached.';
    END IF;
    RETURN 'Data metric function was already attached.';
END;
$$;
