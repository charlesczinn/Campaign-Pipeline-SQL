-- ============================================================================
-- 04 SCRIPT COMPLETION
-- Of the people we actually talked to, how much of the GOTV script got asked?
-- A conversation that skips the vote-plan question is a weaker GOTV contact,
-- even though it counts as "reached".
-- ============================================================================

-- 4a. One row per reached person per script question, answered or not.
-- Building every (person, question) slot first and then LEFT JOINing answers
-- is what makes unanswered questions visible. Starting from the answers would
-- hide them.
CREATE OR REPLACE TABLE gotv.script_answers AS
WITH reached AS (
  SELECT person_id, region, cd, sd, hd
  FROM gotv.person_coverage
  WHERE any_reached
),
script AS (
  SELECT unnest(getvariable('script_questions')) AS question_code
),
latest_answer AS (
  SELECT person_id, question_code, answer_code, answer_label, answer_value
  FROM gotv.stg_responses
  WHERE response_day BETWEEN getvariable('gotv_start') AND getvariable('as_of')
    AND list_contains(getvariable('script_questions'), question_code)
  QUALIFY row_number() OVER (
    PARTITION BY person_id, question_code
    ORDER BY recorded_at DESC, response_id DESC
  ) = 1
)
SELECT
  r.person_id,
  r.region,
  r.cd,
  r.sd,
  r.hd,
  s.question_code,
  list_contains(getvariable('scored_questions'), s.question_code) AS is_scored,
  a.person_id IS NOT NULL AS answered,
  a.answer_code,
  a.answer_label,
  -- Only ordinal questions carry a number, so AVG() over this column can't
  -- accidentally mix in a yes/no question.
  CASE WHEN list_contains(getvariable('scored_questions'), s.question_code)
       THEN a.answer_value END AS score_value
FROM reached AS r
CROSS JOIN script AS s
LEFT JOIN latest_answer AS a USING (person_id, question_code);


-- 4b. One row per reached person.
CREATE OR REPLACE TABLE gotv.script_person AS
SELECT
  person_id,
  region,
  count(*) AS questions_in_script,
  count(*) FILTER (WHERE answered) AS questions_answered,
  round(questions_answered / questions_in_script, 3) AS completion,
  questions_answered = questions_in_script AS full_script
FROM gotv.script_answers
GROUP BY person_id, region;


-- 4c. Answer rates by question and region, with statewide rows.
CREATE OR REPLACE TABLE gotv.script_summary AS
SELECT
  CASE WHEN GROUPING(region) = 0 THEN region ELSE 'All regions' END AS region,
  question_code,
  count(*) AS people_reached,
  count(*) FILTER (WHERE answered) AS answered_count,
  round(answered_count / people_reached, 4) AS answer_rate,
  -- 1 = strong support ... 5 = strong oppose, so lower is better.
  round(avg(score_value), 2) AS avg_score
FROM gotv.script_answers
GROUP BY GROUPING SETS ((region, question_code), (question_code))
ORDER BY GROUPING(region), region, question_code;
