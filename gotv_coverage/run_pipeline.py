#!/usr/bin/env python3
"""
Build the Westmark GOTV coverage tables in DuckDB, run the data checks, and
export the summary tables to CSV.

Usage (from the repo root):
    python synthetic/generate.py              # once, to create data/raw/
    python gotv_coverage/run_pipeline.py      # build, check, export
    python gotv_coverage/run_pipeline.py --as-of 2026-10-27   # a mid-GOTV snapshot
"""
from __future__ import annotations

import argparse
import re
import sys
import time
import tomllib
from datetime import date
from pathlib import Path

import duckdb

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SQL_DIR = HERE / "sql"

RAW_PARQUET = [
    "precincts", "people", "partner_lists", "contact_log",
    "survey_responses", "early_vote_returns",
]
SEED_CSV = {
    "outcome_codes": (REPO / "synthetic/seeds/outcome_codes.csv", {
        "channel": "VARCHAR", "outcome": "VARCHAR", "label": "VARCHAR",
        "is_attempt": "BOOLEAN", "is_response": "BOOLEAN",
        "is_reach": "BOOLEAN", "is_exclusion": "BOOLEAN",
    }),
    "survey_answers": (REPO / "synthetic/seeds/survey_answers.csv", {
        "question_code": "VARCHAR", "answer_code": "VARCHAR",
        "answer_label": "VARCHAR", "answer_value": "INTEGER",
    }),
    "dashboard_access": (HERE / "seeds/dashboard_access.csv", {
        "email": "VARCHAR", "scope_type": "VARCHAR", "scope_value": "VARCHAR",
    }),
}
EXPORTS = [
    "universe_funnel", "coverage_by_geo", "channel_summary",
    "daily_progress", "script_summary",
]


def sql_literal(value) -> str:
    """Render a config value as a DuckDB literal."""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, date):
        return f"DATE '{value.isoformat()}'"
    if isinstance(value, str):
        return "'" + value.replace("'", "''") + "'"
    if isinstance(value, list):
        return "[" + ", ".join(sql_literal(v) for v in value) + "]"
    raise TypeError(f"Unsupported config value: {value!r}")


def load_config(path: Path, as_of: date | None) -> dict:
    cfg = tomllib.loads(path.read_text())
    if as_of:
        cfg["gotv"]["as_of"] = as_of
    g, s = cfg["gotv"], cfg["script"]
    problems = []
    if g["text_attempt_rule"] not in {"sent", "responded"}:
        problems.append("gotv.text_attempt_rule must be 'sent' or 'responded'")
    if g["as_of"] < g["start"]:
        problems.append("gotv.as_of is before gotv.start")
    if not set(s["scored"]) <= set(s["questions"]):
        problems.append("script.scored lists a question that isn't in script.questions")
    if s["support_question"] not in s["questions"]:
        problems.append("script.support_question isn't in script.questions")
    if problems:
        sys.exit("Config problems:\n  - " + "\n  - ".join(problems))
    return cfg


def variables(cfg: dict) -> dict:
    """The values the SQL reads with getvariable()."""
    g, u, s = cfg["gotv"], cfg["universe"], cfg["script"]
    return {
        "timezone": cfg["run"]["timezone"],
        "gotv_start": g["start"],
        "as_of": g["as_of"],
        "text_attempt_rule": g["text_attempt_rule"],
        "model_support_min": u["model_support_min"],
        "model_turnout_min": u["model_turnout_min"],
        "model_turnout_max": u["model_turnout_max"],
        "self_id_max_value": u["self_id_max_value"],
        "opposed_min_value": u["opposed_min_value"],
        "support_question": s["support_question"],
        "script_questions": s["questions"],
        "scored_questions": s["scored"],
    }


def load_raw(con: duckdb.DuckDBPyConnection, raw_dir: Path) -> None:
    """Copy inputs into the database so the .duckdb file stands on its own."""
    missing = [n for n in RAW_PARQUET if not (raw_dir / f"{n}.parquet").exists()]
    if missing:
        sys.exit(f"Missing {', '.join(missing)} in {raw_dir}. Run synthetic/generate.py first.")
    con.execute("CREATE SCHEMA IF NOT EXISTS raw; CREATE SCHEMA IF NOT EXISTS gotv;")
    for name in RAW_PARQUET:
        con.execute(f"CREATE OR REPLACE TABLE raw.{name} AS "
                    f"SELECT * FROM read_parquet({sql_literal(str(raw_dir / f'{name}.parquet'))})")
    for name, (path, columns) in SEED_CSV.items():
        cols = "{" + ", ".join(f"'{c}': '{t}'" for c, t in columns.items()) + "}"
        con.execute(f"CREATE OR REPLACE TABLE raw.{name} AS "
                    f"SELECT * FROM read_csv({sql_literal(str(path))}, header = true, columns = {cols})")


def parse_checks(text: str) -> list[tuple[str, str]]:
    parts = re.split(r"^-- check:\s*(\S+)\s*$", text, flags=re.MULTILINE)
    return [(parts[i], parts[i + 1].strip()) for i in range(1, len(parts), 2)]


def run_checks(con: duckdb.DuckDBPyConnection) -> bool:
    checks = parse_checks((SQL_DIR / "checks.sql").read_text())
    failed = 0
    for name, query in checks:
        bad = con.sql(query.rstrip(";")).fetchall()
        status = "ok  " if not bad else "FAIL"
        print(f"  {status} {name}" + (f"  ({len(bad)} rows, e.g. {bad[0]})" if bad else ""))
        failed += bool(bad)
    print(f"  {len(checks) - failed}/{len(checks)} checks passed")
    return failed == 0


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", type=Path, default=HERE / "config.toml")
    ap.add_argument("--as-of", type=date.fromisoformat, help="snapshot day, overrides config")
    ap.add_argument("--no-export", action="store_true", help="skip writing CSVs")
    args = ap.parse_args()

    cfg = load_config(args.config, args.as_of)
    db_path = REPO / cfg["run"]["database"]
    db_path.parent.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect(str(db_path))

    t0 = time.perf_counter()
    load_raw(con, REPO / cfg["run"]["raw_dir"])
    for name, value in variables(cfg).items():
        con.execute(f"SET VARIABLE {name} = {sql_literal(value)}")

    print(f"Building GOTV coverage as of {cfg['gotv']['as_of']} "
          f"(GOTV started {cfg['gotv']['start']}, texts count when {cfg['gotv']['text_attempt_rule']})")
    for step in sorted(SQL_DIR.glob("[0-9][0-9]_*.sql")):
        con.execute(step.read_text())
        print(f"  ran {step.name}")

    print("\nChecks")
    passed = run_checks(con)

    print("\nUniverse funnel")
    con.sql("FROM gotv.universe_funnel").show()
    print("Coverage by region")
    con.sql("""
        SELECT geo_value AS region, universe, attempted_rate, reached_rate, contact_rate,
               voted_rate, still_to_vote_untouched
        FROM gotv.coverage_by_geo WHERE geo_level IN ('state', 'region')
    """).show()

    if not args.no_export:
        out = REPO / cfg["run"]["output_dir"]
        out.mkdir(parents=True, exist_ok=True)
        for table in EXPORTS:
            con.execute(f"COPY gotv.{table} TO {sql_literal(str(out / f'{table}.csv'))} (HEADER)")
        print(f"Exported {len(EXPORTS)} summary tables to {out.relative_to(REPO)}/")

    print(f"Done in {time.perf_counter() - t0:.1f}s. Database: {db_path.relative_to(REPO)}")
    con.close()
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
