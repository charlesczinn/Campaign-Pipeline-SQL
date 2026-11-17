-- ============================================================================
-- 01 UNIVERSE
-- Who GOTV is trying to turn out.
--
-- The universe is decided as of the GOTV start date and then held fixed. Every
-- coverage rate downstream divides by it, so if people could fall out mid-GOTV
-- (say, because they refused at the door last Tuesday), the rates would rise
-- for reasons that have nothing to do with the work. A fixed denominator means
-- rates only move when doors get knocked and phones get answered.
-- ============================================================================

-- 1a. Every way a person can qualify: one row per person per source.
CREATE OR REPLACE TABLE gotv.universe_sources AS

-- Modeled supporters whose turnout is uncertain. People who almost never vote
-- are left out because a GOTV contact rarely moves them, and reliable voters
-- because they don't need one.
SELECT person_id, 'model' AS source, 3 AS priority
FROM raw.people
WHERE support_score >= getvariable('model_support_min')
  AND turnout_score BETWEEN getvariable('model_turnout_min')
                        AND getvariable('model_turnout_max')

UNION ALL

-- Coalition partner lists, taken as supplied. Someone on both lists shows up
-- twice here and is collapsed in 1b.
SELECT DISTINCT person_id, 'partner:' || partner_code, 2
FROM raw.partner_lists

UNION ALL

-- People who told the campaign directly, before GOTV, that they support the candidate.
SELECT person_id, 'self_id', 1
FROM gotv.pre_gotv_support
WHERE support_value <= getvariable('self_id_max_value');


-- 1b. One row per person. The highest-priority source becomes the entry source
-- for reporting, and the full list is kept for auditing. The struct breaks
-- ties between equal-priority sources alphabetically, so reruns are stable.
CREATE OR REPLACE TABLE gotv.universe_candidates AS
SELECT
  person_id,
  arg_min(source, {'priority': priority, 'source': source}) AS entry_source,
  list_sort(list(source)) AS sources
FROM gotv.universe_sources
GROUP BY person_id;


-- 1c. Reasons to leave someone out: one row per person per reason.
CREATE OR REPLACE TABLE gotv.universe_exclusions AS

-- Registration problems: no longer at this address, or no longer living.
SELECT person_id, 'registration:' || registration_status AS reason, NULL::DATE AS evidence_day
FROM raw.people
WHERE registration_status IN ('moved', 'deceased')

UNION ALL

-- Refusals, wrong numbers, opt-outs and the like, but ONLY when logged before
-- GOTV started. One during GOTV is a worked attempt and stays in the universe.
SELECT person_id, 'contact:' || channel || '/' || outcome, max(contact_day)
FROM gotv.stg_contacts
WHERE is_exclusion
  AND contact_day < getvariable('gotv_start')
GROUP BY ALL

UNION ALL

-- Their latest pre-GOTV answer was opposition.
SELECT person_id, 'self_id:opposed', answered_on
FROM gotv.pre_gotv_support
WHERE support_value >= getvariable('opposed_min_value');


-- 1d. The universe, with geography attached once so no later step re-derives it.
CREATE OR REPLACE TABLE gotv.universe AS
SELECT
  c.person_id,
  c.entry_source,
  c.sources,
  g.region,
  g.county,
  g.cd,
  g.sd,
  g.hd,
  g.precinct_id,
  p.age,
  p.support_score,
  p.turnout_score
FROM gotv.universe_candidates AS c
JOIN raw.people AS p USING (person_id)
JOIN raw.precincts AS g USING (precinct_id)
-- NOT EXISTS rather than NOT IN: a single NULL in the subquery would make
-- NOT IN return no rows at all.
WHERE NOT EXISTS (
  SELECT 1 FROM gotv.universe_exclusions AS x WHERE x.person_id = c.person_id
);


-- 1e. The funnel: what each source brought in, and what took people back out.
-- A person can have several exclusion reasons. Each removal is credited to one
-- reason, in a fixed order (registration, then opposition, then contact
-- result), so the columns add up to the candidate count.
CREATE OR REPLACE TABLE gotv.universe_funnel AS
WITH removal AS (
  SELECT
    person_id,
    arg_min(reason, {
      'rank': CASE split_part(reason, ':', 1)
                WHEN 'registration' THEN 1
                WHEN 'self_id' THEN 2
                ELSE 3
              END,
      'reason': reason
    }) AS reason
  FROM gotv.universe_exclusions
  GROUP BY person_id
)
SELECT
  coalesce(c.entry_source, 'total') AS entry_source,
  count(*) AS candidates,
  count(*) FILTER (WHERE r.reason LIKE 'registration:%') AS removed_registration,
  count(*) FILTER (WHERE r.reason LIKE 'self_id:%') AS removed_opposed,
  count(*) FILTER (WHERE r.reason LIKE 'contact:%') AS removed_contact_result,
  count(*) FILTER (WHERE r.reason IS NULL) AS in_universe
FROM gotv.universe_candidates AS c
LEFT JOIN removal AS r USING (person_id)
GROUP BY ROLLUP (c.entry_source)
ORDER BY GROUPING(c.entry_source), candidates DESC;
