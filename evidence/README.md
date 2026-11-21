# Evidence for the figures in the article

Exported on 18 November 2026 from the single classification run the article reports
(`run_id 87472e16-f3e4-4f86-aca4-82c06dcd874d`), on a Snowflake Enterprise account in
AWS eu-west-1 with `CORTEX_ENABLED_CROSS_REGION = AWS_EU`. All contact data is synthetic.

| File | What it is | Exported as |
|---|---|---|
| `contact_intent_unmasked.json` | Every gold row from the run, including the model's raw response | `CUSTOMER_CARE_VULNERABILITY`, secondary roles off |
| `triage_queue_as_analyst.json` | `V_TRIAGE_QUEUE` as an analyst sees it (vulnerability text masked) | `CONTACT_CENTRE_ANALYST`, secondary roles off |
| `run_log.json` | `CLASSIFICATION_RUN_LOG`: the run and the no-op re-run after it | `ACCOUNTADMIN` |
| `scorecard.json`, `bot_vs_genai.json` | The comparison views | `ACCOUNTADMIN` |
| `model_usage.json` | Rows from `ACCOUNT_USAGE.CORTEX_AI_FUNCTIONS_USAGE_HISTORY` joined to the run on `INFERENCE_QUERY_ID` | `ACCOUNTADMIN` |

The model's wording varies slightly between runs even at temperature 0, so a fresh run
will not reproduce the rationale text word for word. Across the runs made while building
this, the primary intents and the three vulnerability flags did not change for a given
transcript; the secondary intent on C05 did (`Cancel_Order` in some runs,
`Change_Delivery_Details` in others, including this one).

C08 is a deliberate miss. The refund is still inside its 14-day window, which only the
contact date shows, and the model is not given the contact date. It returned
`Refund_Not_Received` at 0.92 confidence in both runs made with this transcript.

Not included: the larger 2,000-contact evaluation the article cites. That lives in the
separate Big Data LDN repository.
