-- ============================================================================
-- DATA CHECKS
-- Each check returns the rows that break a rule. Zero rows means it passes.
-- run_pipeline.py runs them all after every build and fails loudly if any
-- return rows. Blocks are separated by "-- check:" headers.
-- ============================================================================

-- check: every_contact_outcome_is_coded
-- An outcome missing from outcome_codes would silently drop out of staging.
SELECT c.channel, c.outcome, count(*) AS n
FROM raw.contact_log AS c
LEFT JOIN raw.outcome_codes AS o USING (channel, outcome)
WHERE o.outcome IS NULL
GROUP BY ALL;

-- check: every_survey_answer_is_coded
SELECT r.question_code, r.answer_code, count(*) AS n
FROM raw.survey_responses AS r
LEFT JOIN raw.survey_answers AS a USING (question_code, answer_code)
WHERE a.answer_code IS NULL
GROUP BY ALL;

-- check: universe_one_row_per_person
SELECT person_id, count(*) AS n
FROM gotv.universe
GROUP BY person_id
HAVING count(*) > 1;

-- check: no_excluded_person_in_universe
SELECT u.person_id
FROM gotv.universe AS u
JOIN gotv.universe_exclusions AS x USING (person_id);

-- check: contact_exclusions_predate_gotv
-- The frozen-universe rule: no contact result logged on or after the start date removes anyone.
SELECT person_id, reason, evidence_day
FROM gotv.universe_exclusions
WHERE reason LIKE 'contact:%'
  AND evidence_day >= getvariable('gotv_start');

-- check: funnel_matches_universe
SELECT f.in_universe, (SELECT count(*) FROM gotv.universe) AS universe_rows
FROM gotv.universe_funnel AS f
WHERE f.entry_source = 'total'
  AND f.in_universe <> (SELECT count(*) FROM gotv.universe);

-- check: funnel_columns_add_up
SELECT *
FROM gotv.universe_funnel
WHERE candidates <> removed_registration + removed_opposed + removed_contact_result + in_universe;

-- check: coverage_has_whole_universe
SELECT (SELECT count(*) FROM gotv.universe) AS universe_rows,
       (SELECT count(*) FROM gotv.person_coverage) AS coverage_rows
WHERE (SELECT count(*) FROM gotv.universe) <> (SELECT count(*) FROM gotv.person_coverage);

-- check: every_counted_channel_has_columns
-- Guards the staging allowlist: a channel there without door/phone/text-style columns in 02 would be lost.
SELECT DISTINCT channel
FROM gotv.person_channel
WHERE channel NOT IN ('door', 'phone', 'text');

-- check: reached_implies_attempted
SELECT person_id
FROM gotv.person_coverage
WHERE (door_reached AND NOT door_attempted)
   OR (phone_reached AND NOT phone_attempted)
   OR (text_reached AND NOT text_attempted)
   OR (any_reached AND NOT any_attempted);

-- check: any_channel_agrees_with_channels
SELECT person_id
FROM gotv.person_coverage
WHERE any_attempted <> (door_attempted OR phone_attempted OR text_attempted)
   OR any_reached   <> (door_reached OR phone_reached OR text_reached);

-- check: attempts_fall_inside_gotv_window
SELECT person_id, first_attempt_day, last_attempt_day
FROM gotv.person_coverage
WHERE first_attempt_day < getvariable('gotv_start')
   OR last_attempt_day > getvariable('as_of');

-- check: state_row_matches_person_table
SELECT g.*
FROM gotv.coverage_by_geo AS g
WHERE g.geo_level = 'state'
  AND (g.universe  <> (SELECT count(*) FROM gotv.person_coverage)
    OR g.attempted <> (SELECT count(*) FROM gotv.person_coverage WHERE any_attempted)
    OR g.reached   <> (SELECT count(*) FROM gotv.person_coverage WHERE any_reached));

-- check: regions_sum_to_state
SELECT sum(universe) FILTER (WHERE geo_level = 'region') AS region_total,
       max(universe) FILTER (WHERE geo_level = 'state')  AS state_total
FROM gotv.coverage_by_geo
HAVING region_total <> state_total;

-- check: channel_summary_matches_person_table
SELECT s.channel, s.attempted, p.attempted AS expected
FROM gotv.channel_summary AS s
JOIN (
  SELECT 'door' AS channel, count(*) FILTER (WHERE door_attempted) AS attempted FROM gotv.person_coverage
  UNION ALL SELECT 'phone', count(*) FILTER (WHERE phone_attempted) FROM gotv.person_coverage
  UNION ALL SELECT 'text',  count(*) FILTER (WHERE text_attempted)  FROM gotv.person_coverage
) AS p USING (channel)
WHERE s.region = 'All regions' AND s.attempted <> p.attempted;

-- check: daily_progress_never_decreases
SELECT area, day
FROM (
  SELECT area, day, attempted_to_date, ballots_returned_to_date,
         lag(attempted_to_date) OVER (PARTITION BY area ORDER BY day) AS prev_attempted,
         lag(ballots_returned_to_date) OVER (PARTITION BY area ORDER BY day) AS prev_returned
  FROM gotv.daily_progress
)
WHERE attempted_to_date < prev_attempted OR ballots_returned_to_date < prev_returned;

-- check: daily_progress_ends_at_totals
SELECT d.area, d.attempted_to_date, g.attempted
FROM gotv.daily_progress AS d
JOIN gotv.coverage_by_geo AS g
  ON g.geo_value = CASE WHEN d.area = 'All regions' THEN 'Westmark' ELSE d.area END
 AND g.geo_level IN ('state', 'region')
WHERE d.day = getvariable('as_of')
  AND d.attempted_to_date <> g.attempted;

-- check: script_has_every_slot
SELECT person_id, count(*) AS slots
FROM gotv.script_answers
GROUP BY person_id
HAVING count(*) <> len(getvariable('script_questions'));

-- check: only_scored_questions_carry_scores
SELECT person_id, question_code, score_value
FROM gotv.script_answers
WHERE score_value IS NOT NULL AND NOT is_scored;

-- check: region_viewer_sees_only_their_region
SELECT person_id, region
FROM gotv.coverage_for('harbor.lead@example.org')
WHERE region <> 'Harbor';

-- check: state_viewer_sees_everyone
SELECT (SELECT count(*) FROM gotv.coverage_for('data.team@example.org')) AS visible,
       (SELECT count(*) FROM gotv.person_coverage) AS total
WHERE (SELECT count(*) FROM gotv.coverage_for('data.team@example.org'))
   <> (SELECT count(*) FROM gotv.person_coverage);

-- check: unknown_viewer_sees_nothing
SELECT person_id
FROM gotv.coverage_for('someone.else@example.org');

-- check: overlapping_scopes_do_not_duplicate_rows
-- two.hats holds the Lakes region AND WM-03, which overlap in Juniper County.
SELECT viewer_email, person_id, count(*) AS copies
FROM gotv.person_coverage_by_viewer
GROUP BY ALL
HAVING count(*) > 1;

-- check: emails_match_case_insensitively
SELECT 'case-sensitive match' AS problem
WHERE (SELECT count(*) FROM gotv.coverage_for('Harbor.Lead@Example.org'))
   <> (SELECT count(*) FROM gotv.coverage_for('harbor.lead@example.org'));
