-- ============================================================================
-- 05 ACCESS
-- Row-level security: each staffer sees only their own turf.
--
-- raw.dashboard_access grants scopes to viewers. A scope is the whole state,
-- a region, a congressional district or a house district, and one viewer can
-- hold several. The scope rules live in access_grants alone, and both ways of
-- serving the data below read from it.
-- ============================================================================

-- One row per (viewer, person) the viewer may see. DISTINCT matters: a viewer
-- whose scopes overlap (a region plus a district inside it) would otherwise
-- see those people twice, and every count on their dashboard would be inflated.
CREATE OR REPLACE VIEW gotv.access_grants AS
SELECT DISTINCT
  lower(a.email) AS viewer_email,
  pc.person_id
FROM raw.dashboard_access AS a
JOIN gotv.person_coverage AS pc
  ON  a.scope_type = 'state'
  OR (a.scope_type = 'region'        AND a.scope_value = pc.region)
  OR (a.scope_type = 'congressional' AND a.scope_value = pc.cd)
  OR (a.scope_type = 'house'         AND a.scope_value = pc.hd);


-- Option 1, for tools that can pass the viewer in as a parameter:
--   SELECT region, count(*) FROM gotv.coverage_for('harbor.lead@example.org') GROUP BY region;
CREATE OR REPLACE MACRO gotv.coverage_for(viewer) AS TABLE
SELECT pc.*
FROM gotv.person_coverage AS pc
WHERE pc.person_id IN (
  SELECT person_id FROM gotv.access_grants WHERE viewer_email = lower(viewer)
);


-- Option 2, for BI tools (Looker Studio, Tableau, etc.) that filter rows on the
-- logged-in user's email: every row carries the email of a viewer allowed to
-- see it, and the tool's own filter narrows to the current viewer.
CREATE OR REPLACE VIEW gotv.person_coverage_by_viewer AS
SELECT g.viewer_email, pc.*
FROM gotv.access_grants AS g
JOIN gotv.person_coverage AS pc USING (person_id);
