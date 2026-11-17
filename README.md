# Westmark Campaign Data

Campaign data engineering and analytics projects built around **Westmark**, a fictional state with a fictional 2026 governor's race. Each project tackles a problem campaign data teams face, using a shared synthetic voter file, so everything runs on a laptop in seconds and nothing depends on real voter data.

These are original projects, inspired by my experience doing data work on a 2026 statewide coordinated campaign. The code, data, geography, thresholds, and targeting rules are all new and invented for this repo.

## Projects

| Project | What it shows | Status |
|---|---|---|
| [**GOTV Coverage Pipeline**](gotv_coverage/) | A multi-step SQL pipeline that measures GOTV universe coverage by geography, channel, and day, tracks script completion, and applies row-level security, with 24 automated data checks | ✅ Ready |
| Contact Universe Builder | Combining scored, list-based, and survey-based sources into one deduplicated contact universe with auditable exclusions | Planned |
| Volunteer Propensity Model | Gradient-boosted ranking of likely volunteers with cross-validated feature selection, calibration, and SHAP explanations | Planned |
| Field Packet Automation | Python automation that turns a tracking sheet into refreshed, printed, and filed canvass packets | Planned |

## Run it

Python 3.11+:

```bash
pip install -r requirements.txt
python synthetic/generate.py            # build the shared synthetic dataset
python gotv_coverage/run_pipeline.py    # run a project
```

## Layout

```
synthetic/          shared synthetic data generator and reference tables
gotv_coverage/      GOTV coverage pipeline (SQL + runner + checks)
data/               generated data and DuckDB database (gitignored)
```

## Tools

SQL (DuckDB, BigQuery-portable) · Python · pandas · NumPy · matplotlib
