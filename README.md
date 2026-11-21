# GenAI-powered intent detection — Part 1: the Snowflake pipeline

Companion code for the Medium article .

It shows **only** the silver → gold step: a stored procedure that reads redacted
transcripts and classifies them with Snowflake Cortex `AI_COMPLETE`, driven by taxonomy
and config tables, next to a deliberately simple keyword bot for comparison.

Bronze ingest (S3 → bronze) and silver curation (bronze → silver, including redaction)
are out of scope. The silver table is seeded with 10 synthetic transcripts that are
already redacted; nothing here performs or tests redaction.

Everything is synthetic. Bexley & Rowe is a fictional UK fashion retailer.

## Objects

| Schema | Object | Purpose |
|---|---|---|
| — | `GENAI_INTENT_DEMO_WH` | XS warehouse, 60s auto-suspend |
| — | `GENAI_INTENT_DEMO_RM` | Suspends that warehouse at 5 credits a month. A threshold, not a precise limit, and it does **not** cover AI token spend |
| BRONZE | *(empty)* | Raw landing zone; ingest is out of scope for Part 1 |
| SILVER | `CONTACT_TRANSCRIPTS` | Curated, redacted transcripts (10 seeded rows) |
| GOLD | `INTENT_FAMILY` | Reporting families and owning teams |
| GOLD | `INTENT_CATALOGUE` | Versioned labels, definitions, boundaries, routing, target hours |
| GOLD | `INTENT_BOUNDARY_GROUP` | Reference data: confusable label groups and the fact that decides each. Not read by the classifier |
| GOLD | `CLASSIFIER_CONFIG` | Model, temperature, versions, review threshold |
| GOLD | `KEYWORD_BOT_RULES` / `V_KEYWORD_BOT` | The keyword baseline. The view exposes raw first utterances; do not grant it widely |
| GOLD | `SP_CLASSIFY_SILVER_TO_GOLD` | The classifier |
| GOLD | `CONTACT_INTENT` / `CLASSIFICATION_RUN_LOG` | Output and run log |
| GOLD | `V_CONTACT_INTENT_CURRENT` | Gold rows for the prompt version that is live in config |
| GOLD | `V_BOT_VS_GENAI`, `V_SCORECARD`, `V_TRIAGE_QUEUE`, `V_VULNERABLE_CUSTOMERS`, `V_INTENT_BY_FAMILY` | Comparison and business views |
| GOLD | `DEMO_EXPECTED_LABELS` | Demo-only answer key |
| GOVERNANCE | `DATA_SENSITIVITY` tag | PII / PII_REDACTED / DERIVED_SENSITIVE / REFERENCE per layer |
| GOVERNANCE | `MASK_VULNERABILITY_TEXT`, `MASK_RAW_RESPONSE` | Vulnerability reason and rationale masked, raw model response hidden, for everyone except `CUSTOMER_CARE_VULNERABILITY` |
| GOLD | DMF `ACCEPTED_VALUES` on `CONTACT_INTENT.DATA_QUALITY_REASON` | Counts rows that carry a data-quality reason. Runs on change, on serverless compute |
| — | `INTENT_CLASSIFIER_ROLE` | Runs the procedure: reads silver and config, writes gold, no bronze. Granted to `SYSADMIN` |
| — | `CONTACT_CENTRE_ANALYST` | Reads `V_TRIAGE_QUEUE`, `V_VULNERABLE_CUSTOMERS` and `V_INTENT_BY_FAMILY`; sees the vulnerability flag, not the reason. Granted to `SYSADMIN` |
| — | `CUSTOMER_CARE_VULNERABILITY` | Reads the same three views plus `CONTACT_INTENT`, unmasked. Granted only to the user who runs `50_governance.sql`, deliberately not to an admin role |

## Run it

Run from the project root. Each file sets its own warehouse and database.

```bash
snow sql -c <connection> --role ACCOUNTADMIN -f sql/00_setup.sql
snow sql -c <connection> --role ACCOUNTADMIN -f sql/10_silver_transcripts.sql
snow sql -c <connection> --role ACCOUNTADMIN -f sql/20_gold_config.sql
snow sql -c <connection> --role ACCOUNTADMIN -f sql/30_gold_classify.sql
snow sql -c <connection> --role ACCOUNTADMIN -f sql/40_gold_views.sql
snow sql -c <connection> --role ACCOUNTADMIN -f sql/50_governance.sql   

snow sql -c <connection> --role INTENT_CLASSIFIER_ROLE --warehouse GENAI_INTENT_DEMO_WH \
  -q "USE SECONDARY ROLES NONE; CALL GENAI_INTENT_DETECTION.GOLD.SP_CLASSIFY_SILVER_TO_GOLD(50)"

snow sql -c <connection> --role ACCOUNTADMIN --warehouse GENAI_INTENT_DEMO_WH \
  -q "SELECT * FROM GENAI_INTENT_DETECTION.GOLD.V_SCORECARD"
```

Requirements: a Cortex-enabled account where `claude-haiku-4-5` is reachable under your
`CORTEX_ENABLED_CROSS_REGION` setting. This was built on AWS eu-west-1 (Ireland) with
`AWS_EU`. The scripts only read that setting; they do not set or check it.

To use another model, change the `MODEL` row in `GOLD.CLASSIFIER_CONFIG` **and** bump
`PROMPT_VERSION`. The model must be one the calling role is allowed to use, and it must
accept the response schema; test it before relying on it.

## Things to know before you rely on it

- **The procedure runs as whoever calls it** (`EXECUTE AS CALLER`). It does not switch to
  `INTENT_CLASSIFIER_ROLE`. Call it under that role, with secondary roles off, if you want
  that role's grants to be the limit.
- **Secondary roles change what a test proves.** `50_governance.sql` grants
  `CUSTOMER_CARE_VULNERABILITY` to the deploying user. If that user has
  `DEFAULT_SECONDARY_ROLES = ('ALL')`, every session carries all of their roles, so they see
  unmasked text whatever their primary role. Run `USE SECONDARY ROLES NONE` before testing
  what a role can and cannot do.
- **Only the deploying user gets the vulnerability role.** If you deploy with one user
  (a service user over the CLI, say) and open Snowsight as another, `USE ROLE
  CUSTOMER_CARE_VULNERABILITY` fails with "not assigned to the executing user". Grant it
  yourself: `GRANT ROLE CUSTOMER_CARE_VULNERABILITY TO USER <your_user>;`
- **Model access is not locked down.** On a default account every role can call every
  Cortex model. The per-model grant in `50_governance.sql` restricts nothing until the
  broad grants that `PUBLIC` inherits are removed account-wide. See the comments in that file.
- **Run one at a time.** The procedure is safe to re-run but not to run concurrently: two
  overlapping sessions can classify the same contacts twice. Snowflake does not enforce the
  declared primary keys.
- **`PROMPT_VERSION` is the release key.** Contacts already classified under the current
  `PROMPT_VERSION` are skipped. Changing the model or taxonomy alone reclassifies nothing.
  Changing `PROMPT_VERSION` empties the business views until the new version has been run.
- **Check the returned status.** If the model returns nothing for some rows the run comes
  back as `PARTIAL`, and for every row as `FAILED`. Neither raises an error, so whatever
  calls the procedure has to read the status. Config errors and statement failures are
  logged as `ERROR` and re-raised.
- **`10_silver_transcripts.sql` and `20_gold_config.sql` are reset scripts.** They drop and
  recreate their tables (the transcripts, the answer key and the config tables), but not
  the classifier's output in `CONTACT_INTENT` and `CLASSIFICATION_RUN_LOG`. Recreating a
  table also drops its grants and tags, so re-run `50_governance.sql` afterwards or the
  classifier role can no longer read silver or config. Contacts that already have a gold
  row are not reclassified. For a clean, consistent state run `99_teardown.sql` and then
  everything in order. `30`, `40` and `50` are safe to re-run.
- **Teardown drops by name.** `99_teardown.sql` drops the database, warehouse, resource
  monitor and three roles named above. Do not run it if those names are used for anything else.

## What to expect

The run in the article scored 9/10 on exact intent against `GOLD.DEMO_EXPECTED_LABELS`,
found all three vulnerable customers and raised no false alarms; the keyword bot scored
2/10. The miss is C08, and it is deliberate: the refund is still inside its 14-day window,
but only the contact date shows that, and the model is not given the contact date. It
returns `Refund_Not_Received` with high confidence, so the contact is not sent for review.

The model's wording changes between runs even at temperature 0, so your rationales will
differ, and C05's secondary intent has varied between runs.

## Cost

The run reported in the article (18 November 2026) used 20,148 input and 3,405 output
tokens, billed at 0.0223 credits, taken from
`SNOWFLAKE.ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` joined to the run log on
`INFERENCE_QUERY_ID`. The run took 11 seconds; warehouse billing is separate and has a
60-second minimum each time the warehouse resumes. The data metric function uses
serverless compute, billed separately. Nothing in these scripts caps AI token spend.

The exported results and usage rows are in [evidence/](evidence/).


