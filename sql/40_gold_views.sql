-- =====================================================================
-- 40_gold_views.sql — what the business reads
-- =====================================================================
-- These are VIEWS over classified contacts. They rank and summarise; they do
-- not route anything, open a case or track whether work was done. A real
-- triage queue needs state (owner, status, due time) in a workflow system.
-- =====================================================================
USE WAREHOUSE GENAI_INTENT_DEMO_WH;
USE DATABASE GENAI_INTENT_DETECTION;
USE SCHEMA GOLD;

-- Gold keeps one row per contact per prompt version (history is never
-- overwritten). Everything below reads through this view, which returns only
-- the rows for the prompt version that is live in config.
--
-- This is a strict filter. The moment PROMPT_VERSION is changed in config, the
-- view is empty until the new version has been classified. For a live service,
-- classify the new version first and switch the config row afterwards.
CREATE OR REPLACE VIEW GOLD.V_CONTACT_INTENT_CURRENT COPY GRANTS AS
SELECT g.*
FROM GOLD.CONTACT_INTENT g
WHERE g.PROMPT_VERSION = (SELECT MAX(CONFIG_VALUE) FROM GOLD.CLASSIFIER_CONFIG
                          WHERE CONFIG_KEY = 'PROMPT_VERSION');

-- Side by side: keyword bot vs foundation model vs the answer key.
-- The two are NOT given the same job. The bot reads the first customer
-- utterance and has umbrella labels; the model reads the whole transcript
-- (agent turns included) and has the full label set. So the bot is scored two
-- ways: an exact intent match, and whether its label is at least a fair coarse
-- route for the contact.
CREATE OR REPLACE VIEW GOLD.V_BOT_VS_GENAI COPY GRANTS AS
SELECT
    e.CONTACT_ID,
    e.SCENARIO,
    e.EXPECTED_INTENT,
    b.BOT_INTENT,
    g.PRIMARY_INTENT                                              AS GENAI_INTENT,
    g.SECONDARY_INTENT                                            AS GENAI_SECONDARY,
    ROUND(g.CONFIDENCE, 2)                                        AS CONFIDENCE,
    COALESCE(b.BOT_CANONICAL_INTENT = e.EXPECTED_INTENT, FALSE)   AS BOT_EXACT,
    COALESCE(ARRAY_CONTAINS(e.EXPECTED_INTENT::VARIANT, b.BOT_COVERS_INTENTS), FALSE) AS BOT_FAIR_ROUTE,
    g.CONTACT_ID IS NOT NULL                                      AS GENAI_CLASSIFIED,
    COALESCE(g.PRIMARY_INTENT = e.EXPECTED_INTENT, FALSE)         AS GENAI_EXACT,
    e.EXPECTED_VULNERABLE,
    COALESCE(g.CUSTOMER_VULNERABILITY_FLAG, FALSE)                AS GENAI_VULNERABLE,
    e.WHY_IT_IS_HARD
FROM GOLD.DEMO_EXPECTED_LABELS e
LEFT JOIN GOLD.V_KEYWORD_BOT  b ON b.CONTACT_ID = e.CONTACT_ID
LEFT JOIN GOLD.V_CONTACT_INTENT_CURRENT g ON g.CONTACT_ID = e.CONTACT_ID;

-- The headline numbers, with coverage shown separately from correctness.
CREATE OR REPLACE VIEW GOLD.V_SCORECARD COPY GRANTS AS
SELECT
    SCENARIO,
    COUNT(*)                                                            AS CONTACTS,
    COALESCE(COUNT_IF(BOT_EXACT), 0)                                    AS BOT_EXACT,
    COALESCE(COUNT_IF(BOT_FAIR_ROUTE), 0)                               AS BOT_FAIR_ROUTE,
    COALESCE(COUNT_IF(BOT_INTENT = 'FallbackIntent'), 0)                AS BOT_FALLTHROUGH,
    COALESCE(COUNT_IF(GENAI_CLASSIFIED), 0)                             AS GENAI_CLASSIFIED,
    COALESCE(COUNT_IF(GENAI_EXACT), 0)                                  AS GENAI_EXACT,
    COALESCE(COUNT_IF(GENAI_INTENT = 'Unclassified'), 0)                AS GENAI_UNCLASSIFIED,
    COALESCE(COUNT_IF(EXPECTED_VULNERABLE), 0)                          AS VULNERABLE_EXPECTED,
    COALESCE(COUNT_IF(EXPECTED_VULNERABLE AND GENAI_VULNERABLE), 0)     AS VULNERABLE_FOUND_BY_GENAI,
    COALESCE(COUNT_IF(NOT EXPECTED_VULNERABLE AND GENAI_VULNERABLE), 0) AS VULNERABLE_FALSE_ALARMS,
    0                                                                   AS VULNERABLE_FOUND_BY_BOT   -- by design: the bot has no vulnerability label
FROM GOLD.V_BOT_VS_GENAI
GROUP BY ROLLUP (SCENARIO)
ORDER BY SCENARIO NULLS LAST;

-- Suggested triage order: who a human should look at first, and which team
-- owns it. The specialist team keeps the contact; a vulnerable customer adds
-- the vulnerability team and tightens the target to four hours. The targets
-- and the priority bands are illustrative, and they are business choices that
-- live in this view, not in config.
CREATE OR REPLACE VIEW GOLD.V_TRIAGE_QUEUE COPY GRANTS AS
SELECT
    g.CONTACT_ID,
    g.CHANNEL,
    g.STARTED_AT,
    g.PRIMARY_INTENT,
    f.FAMILY_NAME,
    c.DEFAULT_ROUTE                                    AS ROUTE_TO,
    IFF(g.CUSTOMER_VULNERABILITY_FLAG, 'Customer Care - Vulnerability', NULL) AS ALSO_NOTIFY,
    LEAST(c.TARGET_SLA_HOURS, IFF(g.CUSTOMER_VULNERABILITY_FLAG, 4, 999)) AS TARGET_HOURS,
    CASE
        WHEN g.CUSTOMER_VULNERABILITY_FLAG                        THEN 1
        WHEN c.IS_HIGH_CONSEQUENCE                                THEN 2
        WHEN g.REPEAT_CONTACT_FLAG AND g.COMPLAINT_FLAG           THEN 3
        WHEN g.RESOLUTION_STATUS IN ('UNRESOLVED','ESCALATED')    THEN 4
        ELSE 5
    END                                                AS PRIORITY,
    g.RESOLUTION_STATUS,
    g.NEEDS_HUMAN_REVIEW,
    g.REVIEW_REASON,
    g.VULNERABILITY_REASON,
    g.COMPLAINT_FLAG, g.CHURN_RISK_FLAG, g.REPEAT_CONTACT_FLAG, g.AGENT_REQUESTED_FLAG
FROM GOLD.V_CONTACT_INTENT_CURRENT g
JOIN GOLD.INTENT_CATALOGUE c
  ON c.TAXONOMY_VERSION = g.TAXONOMY_VERSION AND c.INTENT = g.PRIMARY_INTENT
JOIN GOLD.INTENT_FAMILY f
  ON f.FAMILY_CODE = c.FAMILY_CODE
ORDER BY TARGET_HOURS, PRIORITY, g.STARTED_AT;

-- Contacts flagged as vulnerable, available as soon as the classifier has run.
CREATE OR REPLACE VIEW GOLD.V_VULNERABLE_CUSTOMERS COPY GRANTS AS
SELECT
    g.CONTACT_ID, g.CHANNEL, g.STARTED_AT, g.PRIMARY_INTENT,
    g.VULNERABILITY_REASON, g.RESOLUTION_STATUS, g.CLASSIFIED_AT,
    -- Time from the redacted transcript landing in silver to the flag existing.
    -- This is NOT contact-to-flag time: it leaves out transcription, redaction
    -- and ingest, which all happen before silver.
    DATEDIFF('second', s.SILVER_LOADED_AT, g.CLASSIFIED_AT) AS SECONDS_SILVER_TO_FLAG
FROM GOLD.V_CONTACT_INTENT_CURRENT g
JOIN SILVER.CONTACT_TRANSCRIPTS s ON s.CONTACT_ID = g.CONTACT_ID
WHERE g.CUSTOMER_VULNERABILITY_FLAG;

-- Volume and signals by intent family: the management view.
CREATE OR REPLACE VIEW GOLD.V_INTENT_BY_FAMILY COPY GRANTS AS
SELECT
    f.FAMILY_NAME,
    f.OWNING_TEAM,
    COUNT(*)                                                  AS CONTACTS,
    COALESCE(COUNT_IF(g.CUSTOMER_VULNERABILITY_FLAG), 0)      AS VULNERABLE,
    COALESCE(COUNT_IF(g.COMPLAINT_FLAG), 0)                   AS COMPLAINTS,
    COALESCE(COUNT_IF(g.REPEAT_CONTACT_FLAG), 0)              AS REPEAT_CONTACTS,
    COALESCE(COUNT_IF(g.RESOLUTION_STATUS = 'ESCALATED'), 0)  AS ESCALATED,
    ROUND(AVG(g.CONFIDENCE), 2)                               AS AVG_CONFIDENCE
FROM GOLD.V_CONTACT_INTENT_CURRENT g
LEFT JOIN GOLD.INTENT_FAMILY f ON f.FAMILY_CODE = g.INTENT_FAMILY
GROUP BY ALL
ORDER BY CONTACTS DESC;
