-- ============================================================================
-- 02 COVERAGE
-- What happened to each person in the universe during GOTV.
-- ============================================================================

-- 2a. Long format first: one row per person per voter-contact channel worked
-- between the GOTV start and the snapshot day. Everyone in the log is kept,
-- not just the universe, so off-universe work can be measured later.
CREATE OR REPLACE TABLE gotv.person_channel AS
SELECT
  person_id,
  channel,
  count(*) FILTER (WHERE counts_as_attempt) AS attempts,
  coalesce(bool_or(counts_as_attempt), false) AS attempted,
  coalesce(bool_or(is_reach), false) AS reached,
  min(contact_day) FILTER (WHERE counts_as_attempt) AS first_attempt_day,
  max(contact_day) FILTER (WHERE counts_as_attempt) AS last_attempt_day
FROM gotv.stg_contacts
WHERE is_voter_contact
  AND contact_day BETWEEN getvariable('gotv_start') AND getvariable('as_of')
GROUP BY person_id, channel;


-- 2b. One row per universe member: channel flags side by side, plus whether
-- they've voted. This is the table the dashboards and the summaries read.
CREATE OR REPLACE TABLE gotv.person_coverage AS
WITH wide AS (
  SELECT
    person_id,
    bool_or(attempted) FILTER (WHERE channel = 'door')  AS door_attempted,
    bool_or(reached)   FILTER (WHERE channel = 'door')  AS door_reached,
    bool_or(attempted) FILTER (WHERE channel = 'phone') AS phone_attempted,
    bool_or(reached)   FILTER (WHERE channel = 'phone') AS phone_reached,
    bool_or(attempted) FILTER (WHERE channel = 'text')  AS text_attempted,
    bool_or(reached)   FILTER (WHERE channel = 'text')  AS text_reached,
    -- Built from the same rows as the channel flags, so "any channel" can
    -- never disagree with the channels themselves.
    bool_or(attempted) AS any_attempted,
    bool_or(reached)   AS any_reached,
    sum(attempts)      AS attempts,
    min(first_attempt_day) AS first_attempt_day,
    max(last_attempt_day)  AS last_attempt_day
  FROM gotv.person_channel
  GROUP BY person_id
),

-- The state's returned-ballot file is the ground truth for who has voted.
ballots AS (
  SELECT
    person_id,
    min(returned_on) AS ballot_returned_on,
    arg_min(ballot_type, returned_on) AS ballot_type
  FROM raw.early_vote_returns
  WHERE returned_on <= getvariable('as_of')
  GROUP BY person_id
),

-- Self-reports fill the gap until the state's file catches up. Once someone
-- says "I already voted," that stands even if a later answer differs.
said_voted AS (
  SELECT DISTINCT person_id
  FROM gotv.stg_responses
  WHERE question_code = 'vote_plan'
    AND answer_code = 'already_voted'
    AND response_day BETWEEN getvariable('gotv_start') AND getvariable('as_of')
),

-- Latest support answer given during GOTV (1 = strong support ... 5 = strong oppose).
-- Kept as information only: the universe stays fixed, so a supporter who
-- turns out to be opposed shows up here for filtering, not as a removal.
gotv_support AS (
  SELECT person_id, arg_max(answer_value, (recorded_at, response_id)) AS support_value
  FROM gotv.stg_responses
  WHERE question_code = getvariable('support_question')
    AND response_day BETWEEN getvariable('gotv_start') AND getvariable('as_of')
  GROUP BY person_id
)

SELECT
  u.person_id,
  u.entry_source,
  u.region,
  u.county,
  u.cd,
  u.sd,
  u.hd,
  u.precinct_id,
  coalesce(w.door_attempted, false)  AS door_attempted,
  coalesce(w.door_reached, false)    AS door_reached,
  coalesce(w.phone_attempted, false) AS phone_attempted,
  coalesce(w.phone_reached, false)   AS phone_reached,
  coalesce(w.text_attempted, false)  AS text_attempted,
  coalesce(w.text_reached, false)    AS text_reached,
  coalesce(w.any_attempted, false)   AS any_attempted,
  coalesce(w.any_reached, false)     AS any_reached,
  coalesce(w.attempts, 0)            AS attempts,
  w.first_attempt_day,
  w.last_attempt_day,
  b.ballot_returned_on,
  b.ballot_type,
  s.person_id IS NOT NULL AS said_already_voted,
  CASE
    WHEN b.person_id IS NOT NULL THEN 'returned'
    WHEN s.person_id IS NOT NULL THEN 'self_reported'
    ELSE 'not_yet'
  END AS vote_status,
  g.support_value AS gotv_support_value
FROM gotv.universe AS u
LEFT JOIN wide AS w USING (person_id)
LEFT JOIN ballots AS b USING (person_id)
LEFT JOIN said_voted AS s USING (person_id)
LEFT JOIN gotv_support AS g USING (person_id);
