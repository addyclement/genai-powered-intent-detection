-- =====================================================================
-- 20_gold_config.sql — the taxonomy and classifier settings, as DATA
-- =====================================================================
-- Intent families, labels, definitions, routing and the model choice are rows
-- in tables, so changing them is an INSERT/UPDATE rather than a redeploy.
-- Not everything is data yet: the flag definitions, the review rule and the
-- triage ordering still live in SQL (30_gold_classify.sql, 40_gold_views.sql).
--
-- THIS IS A RESET SCRIPT. It drops and recreates every table below, which
-- puts the config back to its defaults and removes any taxonomy versions you
-- have added. Snowflake does not enforce the primary and foreign keys declared
-- here on standard tables; the procedure checks what it relies on before it
-- spends anything on inference.
-- =====================================================================
USE WAREHOUSE GENAI_INTENT_DEMO_WH;
USE DATABASE GENAI_INTENT_DETECTION;
USE SCHEMA GOLD;

-- ---------------------------------------------------------------------
-- 1. Intent families: the reporting roll-up and the team that owns it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE GOLD.INTENT_FAMILY (
    FAMILY_CODE   VARCHAR(30)  NOT NULL,
    FAMILY_NAME   VARCHAR(60)  NOT NULL,
    OWNING_TEAM   VARCHAR(60)  NOT NULL,
    DESCRIPTION   VARCHAR(300),
    CONSTRAINT PK_INTENT_FAMILY PRIMARY KEY (FAMILY_CODE)
)
COMMENT = 'Reporting families that intents roll up to, with the accountable team.';

INSERT INTO GOLD.INTENT_FAMILY VALUES
('ORDERS',   'Orders & Delivery',  'Fulfilment Ops',      'Where is it, when is it coming, what arrived.'),
('RETURNS',  'Returns & Refunds',  'Returns Ops',         'Sending things back and getting money back.'),
('PAYMENTS', 'Payments & Billing', 'Payments & Credit',   'Charges, declines and instalment plans.'),
('ACCOUNT',  'Account & Digital',  'Digital & Security',  'Access, profile, closure and compromise.'),
('SERVICE',  'Service & General',  'Customer Care',       'Complaints, human requests and general questions.'),
('RESERVED', 'Reserved',           'Data Engineering',    'Not a business intent. Used only when no goal is recoverable.');

-- ---------------------------------------------------------------------
-- 2. Intent catalogue: one row per label per taxonomy version.
--    DEFINITION and BOUNDARY are sent to the model. ROUTE and SLA are not:
--    they drive what happens AFTER classification.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE GOLD.INTENT_CATALOGUE (
    TAXONOMY_VERSION     VARCHAR(20)  NOT NULL,
    INTENT               VARCHAR(60)  NOT NULL,
    FAMILY_CODE          VARCHAR(30)  NOT NULL,
    DEFINITION           VARCHAR(300) NOT NULL,
    BOUNDARY             VARCHAR(300),
    IS_HIGH_CONSEQUENCE  BOOLEAN      NOT NULL DEFAULT FALSE,
    DEFAULT_ROUTE        VARCHAR(60)  NOT NULL,
    TARGET_SLA_HOURS     NUMBER       NOT NULL,
    IS_ACTIVE            BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT PK_INTENT_CATALOGUE PRIMARY KEY (TAXONOMY_VERSION, INTENT),
    CONSTRAINT FK_CATALOGUE_FAMILY FOREIGN KEY (FAMILY_CODE) REFERENCES GOLD.INTENT_FAMILY (FAMILY_CODE)
)
COMMENT = 'Versioned label set. A taxonomy change is a new TAXONOMY_VERSION, never an in-place edit.';

INSERT INTO GOLD.INTENT_CATALOGUE
    (TAXONOMY_VERSION, INTENT, FAMILY_CODE, DEFINITION, BOUNDARY, IS_HIGH_CONSEQUENCE, DEFAULT_ROUTE, TARGET_SLA_HOURS)
VALUES
('tx-2026.11','Order_Status',             'ORDERS',  'Customer asks where an order is, with no failure alleged.',                         'Becomes Delivery_Delay once the customer says it is late.',                         FALSE,'Self-service: tracking',      72),
('tx-2026.11','Delivery_Delay',           'ORDERS',  'The customer says an order is late or overdue.',                                     'If no lateness is alleged, it is Order_Status.',                                    FALSE,'Fulfilment',                  24),
('tx-2026.11','Change_Delivery_Details',  'ORDERS',  'Change the address, slot or safe place on an order in flight.',                      'An amendment, not a cancellation.',                                                 FALSE,'Fulfilment',                  4),
('tx-2026.11','Cancel_Order',             'ORDERS',  'Stop an order before it is dispatched.',                                             'Becomes Return_Request once the order has shipped.',                                FALSE,'Fulfilment',                  4),
('tx-2026.11','Wrong_Item_Received',      'ORDERS',  'Parcel arrived with the wrong product, colour or size.',                             'Retailer erred. If the customer simply wants another size, Exchange_Or_Size_Swap.', FALSE,'Returns',                     48),
('tx-2026.11','Damaged_Or_Faulty_Item',   'ORDERS',  'Item arrived damaged or failed on first wear.',                                      'A fault, not a change of mind (Return_Request).',                                   FALSE,'Returns',                     48),
('tx-2026.11','Return_Request',           'RETURNS', 'Send an item back for a refund: change of mind or fit.',                             'If they want a different size instead of money, Exchange_Or_Size_Swap.',            FALSE,'Self-service: returns portal',72),
('tx-2026.11','Exchange_Or_Size_Swap',    'RETURNS', 'Wants a different size, colour or product rather than a refund.',                    'Goal is the replacement, not the money.',                                           FALSE,'Returns',                     48),
('tx-2026.11','Refund_Status',            'RETURNS', 'Chasing a refund that is still inside the stated SLA.',                              'Becomes Refund_Not_Received once the stated SLA has passed.',                       FALSE,'Self-service: refund tracker',72),
('tx-2026.11','Refund_Not_Received',      'RETURNS', 'Refund SLA has passed and the money has not arrived.',                               'Past SLA. Inside SLA is Refund_Status.',                                            FALSE,'Returns escalations',         24),
('tx-2026.11','Duplicate_Charge',         'PAYMENTS','Charged more than once for a single order.',                                         'One unknown charge is Unrecognised_Charge.',                                        FALSE,'Payments',                    24),
('tx-2026.11','Unrecognised_Charge',      'PAYMENTS','Does not recognise a charge but has not alleged fraud.',                             'Becomes Fraud_Or_Account_Takeover once compromise is alleged.',                     FALSE,'Payments',                    24),
('tx-2026.11','Buy_Now_Pay_Later_Query',  'PAYMENTS','Question or problem with an instalment plan, including affordability or arrears.',   'Third-party credit plan, not a card payment.',                                      TRUE, 'Payments & Credit',           24),
('tx-2026.11','Account_Login_Issue',      'ACCOUNT', 'Cannot sign in, reset a password or pass verification.',                             'Once signed in, changing details is a profile update.',                             FALSE,'Self-service: password reset',72),
('tx-2026.11','Account_Closure',          'ACCOUNT', 'Wants an account closed or deleted, including on behalf of someone else.',           'Wins over any order or refund the closure happens to involve.',                     TRUE, 'Customer Care',               24),
('tx-2026.11','Fraud_Or_Account_Takeover','ACCOUNT', 'Account or card used without authorisation, or an order placed by someone else.',    'Compromise alleged. Mere unfamiliarity is Unrecognised_Charge.',                    TRUE, 'Fraud',                       1),
('tx-2026.11','App_Or_Website_Issue',     'ACCOUNT', 'The app or site is broken: crash, error page, checkout will not progress.',          'A digital defect. Never FAQ.',                                                      FALSE,'Digital support',             24),
('tx-2026.11','Complaint',                'SERVICE', 'The grievance itself is the ask, not a task to be done.',                            'If a task is recoverable, label the task and set complaint_flag.',                  FALSE,'Complaints',                  24),
('tx-2026.11','Agent_Request',            'SERVICE', 'Asks for a human and no underlying reason is recoverable.',                          'If the reason is recoverable, label the reason and set agent_requested_flag.',      FALSE,'Customer Care',               4),
('tx-2026.11','FAQ',                      'SERVICE', 'General information question with no specific servicing issue.',                     'Residual. Never for a broken checkout or failed payment.',                          FALSE,'Self-service: help centre',   72),
('tx-2026.11','Unclassified',             'RESERVED','No customer goal is recoverable (silence, abandoned, garbled).',                     'Reserved. Must carry a data-quality reason.',                                       FALSE,'Data quality review',         72);

-- ---------------------------------------------------------------------
-- 3. Intent boundary groups: the labels that genuinely get confused, and the
--    fact that settles each case. This table is REFERENCE DATA: the classifier
--    does not read it. It is there for evaluation sampling and for recording
--    which errors no prompt can fix (the deciding fact isn't in the text).
--    FACT_IN_TRANSCRIPT says where the fact is normally found, not that it is
--    present in any particular contact.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE GOLD.INTENT_BOUNDARY_GROUP (
    GROUP_CODE        VARCHAR(30)  NOT NULL,
    INTENTS           ARRAY        NOT NULL,
    DECIDED_BY        VARCHAR(200) NOT NULL,
    FACT_IN_TRANSCRIPT BOOLEAN     NOT NULL,
    CONSTRAINT PK_INTENT_BOUNDARY_GROUP PRIMARY KEY (GROUP_CODE)
)
COMMENT = 'Contested label boundaries. If FACT_IN_TRANSCRIPT is FALSE, the fix is a join, not a prompt.';

INSERT INTO GOLD.INTENT_BOUNDARY_GROUP
SELECT column1, PARSE_JSON(column2), column3, column4 FROM VALUES
('DELIVERY_STAGE', '["Order_Status","Delivery_Delay"]',                           'whether the customer says it is late',              TRUE),
('CANCEL_VS_RETURN','["Cancel_Order","Return_Request"]',                          'whether the order had been dispatched',             FALSE),
('REFUND_SLA',     '["Refund_Status","Refund_Not_Received"]',                     'whether the stated refund SLA has passed',          TRUE),
('MONEY_OR_ITEM',  '["Return_Request","Exchange_Or_Size_Swap"]',                  'whether the customer wants the money or the item',  TRUE),
('CHARGE_TRUST',   '["Unrecognised_Charge","Duplicate_Charge","Fraud_Or_Account_Takeover"]','whether compromise is alleged, and whether there is one charge or two', TRUE),
('GOAL_VS_MECHANISM','["Account_Closure","Cancel_Order","Refund_Status"]',        'which is the goal and which is the mechanism',      TRUE),
('HUMAN_OR_REASON','["Agent_Request","Complaint"]',                               'whether an underlying reason is recoverable',       TRUE);

-- ---------------------------------------------------------------------
-- 4. Classifier config: model, versions and thresholds. Key/value on purpose:
--    adding a setting never needs a schema change.
--    UPDATED_BY / UPDATED_AT are filled on INSERT only. They are not a change
--    history; if you need one, log changes explicitly.
--    PROMPT_VERSION is the release key: the procedure skips a contact that
--    already has a row for the current PROMPT_VERSION. Changing MODEL or
--    TAXONOMY_VERSION on its own does NOT reclassify anything. Bump
--    PROMPT_VERSION whenever you change the model, the taxonomy or the prompt.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE GOLD.CLASSIFIER_CONFIG (
    CONFIG_KEY    VARCHAR(60)  NOT NULL,
    CONFIG_VALUE  VARCHAR(200) NOT NULL,
    NOTES         VARCHAR(500),
    UPDATED_BY    VARCHAR(100) DEFAULT CURRENT_USER(),
    UPDATED_AT    TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
    CONSTRAINT PK_CLASSIFIER_CONFIG PRIMARY KEY (CONFIG_KEY)
)
COMMENT = 'Single source of truth for the gold classifier settings.';

INSERT INTO GOLD.CLASSIFIER_CONFIG (CONFIG_KEY, CONFIG_VALUE, NOTES) VALUES
('MODEL',                       'claude-haiku-4-5', 'Pinned. Available under AWS_EU.'),
('TEMPERATURE',                 '0',                'Classification, not creativity.'),
('TAXONOMY_VERSION',            'tx-2026.11',       'Which catalogue version is live.'),
('PROMPT_VERSION',              'p1.0',             'Release key. Bump for any model, taxonomy or prompt change.'),
('REVIEW_CONFIDENCE_THRESHOLD', '0.75',             'Below this, a human reviews it.'),
('MAX_TRANSCRIPT_CHARS',        '12000',            'Cost and latency guard.');

-- ---------------------------------------------------------------------
-- 5. The incumbent: a keyword bot. First match wins, first customer
--    utterance only. This is what most contact centres already have.
-- ---------------------------------------------------------------------
CREATE OR REPLACE TABLE GOLD.KEYWORD_BOT_RULES (
    PRIORITY        NUMBER       NOT NULL,
    PATTERN         VARCHAR(200) NOT NULL,     -- case-insensitive regex
    BOT_LABEL       VARCHAR(60)  NOT NULL,
    MAPS_TO_INTENT  VARCHAR(60),               -- NULL = umbrella label, no single intent
    COVERS_INTENTS  ARRAY,                     -- intents this label is a fair coarse route for
    CONSTRAINT PK_KEYWORD_BOT_RULES PRIMARY KEY (PRIORITY)
)
COMMENT = 'Deliberately simple first-utterance keyword router, used as the baseline.';

INSERT INTO GOLD.KEYWORD_BOT_RULES
SELECT column1, column2, column3, column4, PARSE_JSON(column5) FROM VALUES
(10, 'cancel',                                        'cancel_order',        'Cancel_Order',              '["Cancel_Order"]'),
(20, 'refund|money back|return|send (it|this) back',  'returns_and_refunds', NULL,                        '["Return_Request","Exchange_Or_Size_Swap","Refund_Status","Refund_Not_Received"]'),
(30, 'charge|payment|instalment|pay later|pay in',    'payment_issue',       NULL,                        '["Duplicate_Charge","Unrecognised_Charge","Buy_Now_Pay_Later_Query"]'),
(40, 'log ?in|password|sign ?in|locked out',          'account_help',        'Account_Login_Issue',       '["Account_Login_Issue"]'),
(50, 'damaged|faulty|broken|ripped',                  'damaged_item',        'Damaged_Or_Faulty_Item',    '["Damaged_Or_Faulty_Item"]'),
(60, 'fraud|hacked',                                  'fraud_query',         'Fraud_Or_Account_Takeover', '["Fraud_Or_Account_Takeover"]'),
(70, 'complain',                                      'complaint',           'Complaint',                 '["Complaint"]'),
(80, 'agent|real person|human',                       'agent_request',       'Agent_Request',             '["Agent_Request"]'),
(90, 'order|parcel|delivery',                         'order_status',        'Order_Status',              '["Order_Status","Delivery_Delay"]');
