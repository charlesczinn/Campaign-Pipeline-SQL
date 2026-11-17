-- ============================================================================
-- 03 SUMMARIES
-- Aggregates for dashboards: by geography, by channel, and by day.
-- ============================================================================

-- 3a. Coverage at every reporting level in one pass. GROUPING SETS computes
-- region, congressional, senate, house and statewide totals together, so they
-- always come from the same snapshot and always reconcile.
CREATE OR REPLACE TABLE gotv.coverage_by_geo AS
SELECT
  CASE
    WHEN GROUPING(region) = 0 THEN 'region'
    WHEN GROUPING(cd) = 0     THEN 'congressional'
    WHEN GROUPING(sd) = 0     THEN 'senate'
    WHEN GROUPING(hd) = 0     THEN 'house'
    ELSE 'state'
  END AS geo_level,
  coalesce(region, cd, sd, hd, 'Westmark') AS geo_value,
  count(*)                                               AS universe,
  count(*) FILTER (WHERE any_attempted)                  AS attempted,
  count(*) FILTER (WHERE any_reached)                    AS reached,
  count(*) FILTER (WHERE vote_status <> 'not_yet')       AS voted,
  count(*) FILTER (WHERE vote_status = 'not_yet')        AS still_to_vote,
  -- The work list that matters most on the last weekend: hasn't voted, never tried.
  count(*) FILTER (WHERE vote_status = 'not_yet' AND NOT any_attempted) AS still_to_vote_untouched,
  round(attempted / universe, 4)                         AS attempted_rate,
  round(reached / universe, 4)                           AS reached_rate,
  round(reached / nullif(attempted, 0), 4)               AS contact_rate,
  round(voted / universe, 4)                             AS voted_rate
FROM gotv.person_coverage
GROUP BY GROUPING SETS ((region), (cd), (sd), (hd), ())
ORDER BY
  CASE geo_level WHEN 'state' THEN 0 WHEN 'region' THEN 1 WHEN 'congressional' THEN 2
                 WHEN 'senate' THEN 3 ELSE 4 END,
  geo_value;


-- 3b. Channel performance by region. UNPIVOT turns the paired door/phone/text
-- columns into rows, so the summary needs no per-channel copy-paste.
CREATE OR REPLACE TABLE gotv.channel_summary AS
WITH long AS (
  UNPIVOT (
    SELECT person_id, region,
           door_attempted, door_reached,
           phone_attempted, phone_reached,
           text_attempted, text_reached
    FROM gotv.person_coverage
  )
  ON (door_attempted, door_reached)   AS door,
     (phone_attempted, phone_reached) AS phone,
     (text_attempted, text_reached)   AS text
  INTO NAME channel VALUE was_attempted, was_reached
)
SELECT
  CASE WHEN GROUPING(region) = 0 THEN region ELSE 'All regions' END AS region,
  channel,
  count(*)                              AS universe,
  count(*) FILTER (WHERE was_attempted) AS attempted,
  count(*) FILTER (WHERE was_reached)   AS reached,
  round(attempted / universe, 4)        AS attempted_rate,
  round(reached / nullif(attempted, 0), 4) AS contact_rate
FROM long
GROUP BY GROUPING SETS ((region, channel), (channel))
ORDER BY GROUPING(region), region, channel;


-- 3c. Cumulative progress by day, per region and statewide: who has been
-- attempted at least once, and whose ballot has come back. A full calendar is
-- built first so days with no activity still appear as flat lines rather than gaps.
CREATE OR REPLACE TABLE gotv.daily_progress AS
WITH days AS (
  SELECT CAST(d AS DATE) AS day
  FROM generate_series(
    CAST(getvariable('gotv_start') AS TIMESTAMP),
    CAST(getvariable('as_of') AS TIMESTAMP),
    INTERVAL 1 DAY
  ) AS t(d)
),
areas AS (
  SELECT coalesce(region, 'All regions') AS area, count(*) AS universe
  FROM gotv.person_coverage
  GROUP BY GROUPING SETS ((region), ())
),
-- One event per person per milestone. Ballots that came back before GOTV
-- started are counted on day one.
milestones AS (
  SELECT region, first_attempt_day AS day, 1 AS new_attempted, 0 AS new_voted
  FROM gotv.person_coverage
  WHERE any_attempted
  UNION ALL
  SELECT region, greatest(ballot_returned_on, getvariable('gotv_start')), 0, 1
  FROM gotv.person_coverage
  WHERE ballot_returned_on IS NOT NULL
),
per_day AS (
  SELECT coalesce(region, 'All regions') AS area, day,
         sum(new_attempted) AS new_attempted,
         sum(new_voted) AS new_voted
  FROM milestones
  GROUP BY GROUPING SETS ((region, day), (day))
),
running AS (
  SELECT
    a.area,
    d.day,
    a.universe,
    sum(coalesce(p.new_attempted, 0)) OVER w AS attempted_to_date,
    sum(coalesce(p.new_voted, 0)) OVER w     AS ballots_returned_to_date
  FROM areas AS a
  CROSS JOIN days AS d
  LEFT JOIN per_day AS p ON p.area = a.area AND p.day = d.day
  WINDOW w AS (PARTITION BY a.area ORDER BY d.day ROWS UNBOUNDED PRECEDING)
)
SELECT
  *,
  round(attempted_to_date / universe, 4)        AS attempted_rate,
  round(ballots_returned_to_date / universe, 4) AS ballots_returned_rate
FROM running
ORDER BY area = 'All regions' DESC, area, day;
