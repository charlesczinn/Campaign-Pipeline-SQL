-- ============================================================================
-- 00 STAGING
-- Cleaned, typed copies of the raw inputs. Every later step reads these rather
-- than raw.*, so timezone handling and outcome rules live in one place.
-- ============================================================================

-- Contact and survey times are stored in UTC. Field staff think in local
-- calendar days, and a 9pm phone call must land on the day it was made.
CREATE OR REPLACE TEMP MACRO local_day(ts) AS
  CAST(timezone(getvariable('timezone'), ts) AS DATE);


-- Contact attempts with their outcome rules attached.
CREATE OR REPLACE TABLE gotv.stg_contacts AS
SELECT
  c.attempt_id,
  c.person_id,
  c.channel,
  c.outcome,
  c.attempted_at,
  local_day(c.attempted_at) AS contact_day,

  -- The three channels the program reports on. The log also holds things like
  -- volunteer-event check-ins, which are not voter contact. Adding a channel
  -- here means adding its two columns in 02_coverage.sql; a check enforces it.
  c.channel IN ('door', 'phone', 'text') AS is_voter_contact,

  -- Texts are cheap to send in bulk, so by default only a reply counts as an
  -- attempt. text_attempt_rule = 'sent' counts every delivered text instead.
  CASE
    WHEN c.channel = 'text' AND getvariable('text_attempt_rule') = 'responded'
      THEN o.is_response
    ELSE o.is_attempt
  END AS counts_as_attempt,

  o.is_reach,
  o.is_exclusion
FROM raw.contact_log AS c
JOIN raw.outcome_codes AS o USING (channel, outcome);


-- Survey answers with labels and numeric values attached.
CREATE OR REPLACE TABLE gotv.stg_responses AS
SELECT
  r.response_id,
  r.person_id,
  r.question_code,
  r.answer_code,
  a.answer_label,
  a.answer_value,
  r.recorded_at,
  local_day(r.recorded_at) AS response_day
FROM raw.survey_responses AS r
JOIN raw.survey_answers AS a USING (question_code, answer_code);


-- Each person's latest support answer from before GOTV began. Feeds both the
-- universe (self-identified supporters) and its exclusions (self-identified
-- opponents), so the two can never disagree about what someone said.
CREATE OR REPLACE TABLE gotv.pre_gotv_support AS
SELECT
  person_id,
  arg_max(answer_value, (recorded_at, response_id)) AS support_value,
  max(response_day) AS answered_on
FROM gotv.stg_responses
WHERE question_code = getvariable('support_question')
  AND response_day < getvariable('gotv_start')
GROUP BY person_id;
