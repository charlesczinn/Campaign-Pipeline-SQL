#!/usr/bin/env python3
"""
Generate the synthetic inputs shared by every project in this repo.

Westmark is a fictional state with a fictional 2026 governor's race. Every
person, place, score, list and contact here is random, drawn from a fixed
seed so runs are reproducible. Nothing comes from a real voter file.

Usage:
    python synthetic/generate.py                 # 60,000 people, seed 2026
    python synthetic/generate.py --people 5000   # quick small run
"""
from __future__ import annotations

import argparse
from datetime import date, timedelta
from pathlib import Path

import duckdb
import numpy as np
import pandas as pd

REPO = Path(__file__).resolve().parent.parent
SEEDS = Path(__file__).resolve().parent / "seeds"
TIMEZONE = "America/Chicago"

# Campaign calendar for the simulated field program
ELECTION_DAY = date(2026, 11, 3)
PERSUASION_START = date(2026, 8, 17)
GOTV_START = date(2026, 10, 13)
MAIL_VOTING_START = date(2026, 10, 5)
EARLY_VOTING = (date(2026, 10, 24), date(2026, 11, 1))

# name, code, field region, density, share of voters, congressional district, partisan lean
COUNTIES = [
    ("Alder",       "ALD", "Harbor",  "urban",    0.18, "WM-01",  12),
    ("Fairhaven",   "FHV", "Harbor",  "urban",    0.12, "WM-01",   8),
    ("Cedar",       "CED", "Capital", "urban",    0.10, "WM-02",   6),
    ("Birch Falls", "BRF", "Capital", "suburban", 0.11, "WM-02",   3),
    ("Dunmore",     "DUN", "Capital", "suburban", 0.08, "WM-02",  -2),
    ("Harlow",      "HAR", "Lakes",   "suburban", 0.10, "WM-04",   0),
    ("Juniper",     "JUN", "Lakes",   "suburban", 0.10, "WM-03",  -1),
    ("Ironwood",    "IRN", "Lakes",   "rural",    0.08, "WM-04",  -8),
    ("Elk Ridge",   "ELK", "Ridge",   "rural",    0.07, "WM-03", -10),
    ("Greystone",   "GRY", "Ridge",   "rural",    0.06, "WM-03",  -6),
]
N_PRECINCTS = 320
N_HOUSE_DISTRICTS = 36
HOUSE_PER_SENATE = 3

# How hard the field program worked each region during GOTV (share of targets touched)
REGION_REACH = {"Harbor": 0.80, "Capital": 0.70, "Lakes": 0.60, "Ridge": 0.45}

# Channel mix by density: door, phone, text
CHANNEL_MIX = {
    "urban":    [0.50, 0.20, 0.30],
    "suburban": [0.35, 0.30, 0.35],
    "rural":    [0.15, 0.45, 0.40],
}

# Outcome probabilities per channel (must match synthetic/seeds/outcome_codes.csv)
OUTCOMES = {
    "door":  {"canvassed": 0.28, "not_home": 0.60, "inaccessible": 0.05, "refused": 0.05, "moved": 0.02},
    "phone": {"talked": 0.14, "no_answer": 0.55, "left_message": 0.18, "wrong_number": 0.07,
              "refused": 0.04, "do_not_call": 0.02},
    "text":  {"sent": 0.86, "replied": 0.09, "opted_out": 0.03, "undeliverable": 0.02},
}
REACH_OUTCOMES = {"canvassed", "talked", "replied"}
LOCAL_HOURS = {"door": (10, 19), "phone": (16, 21), "text": (11, 20), "event": (18, 20)}


# ---------------------------------------------------------------------------
# Geography and people
# ---------------------------------------------------------------------------
def build_geography() -> tuple[pd.DataFrame, pd.DataFrame]:
    counties = pd.DataFrame(
        COUNTIES, columns=["county", "code", "region", "density", "share", "cd", "lean"]
    )
    per_county = np.maximum(8, np.round(counties["share"] * N_PRECINCTS)).astype(int)
    rows = [
        (f"{c.code}-{i:03d}", c.county, c.region, c.density, c.cd)
        for c, n in zip(counties.itertuples(), per_county)
        for i in range(1, n + 1)
    ]
    precincts = pd.DataFrame(rows, columns=["precinct_id", "county", "region", "density", "cd"])

    # House districts are contiguous runs of precincts, so most sit inside one
    # county and a few straddle a county line. Senate districts are 3 House districts.
    hd_num = np.arange(len(precincts)) * N_HOUSE_DISTRICTS // len(precincts) + 1
    precincts["hd"] = [f"HD-{n:02d}" for n in hd_num]
    precincts["sd"] = [f"SD-{(n - 1) // HOUSE_PER_SENATE + 1:02d}" for n in hd_num]
    return counties, precincts


def build_people(rng: np.random.Generator, n: int, counties: pd.DataFrame,
                 precincts: pd.DataFrame) -> pd.DataFrame:
    county_idx = rng.choice(len(counties), size=n, p=counties["share"] / counties["share"].sum())
    precinct_lists = precincts.groupby("county")["precinct_id"].apply(np.array)
    precinct = np.empty(n, dtype=object)
    for i, name in enumerate(counties["county"]):
        mask = county_idx == i
        precinct[mask] = rng.choice(precinct_lists[name], size=mask.sum())

    age = np.clip(np.round(18 + rng.gamma(2.6, 13.0, size=n)), 18, 98).astype(int)

    # Support: polarized (U-shaped) beta whose center shifts with county lean
    center = np.clip((50 + 2 * counties["lean"].to_numpy()[county_idx]) / 100, 0.15, 0.85)
    k = 1.8
    support = np.round(100 * rng.beta(center * k, (1 - center) * k), 1)

    # Turnout: rises with age, plus individual noise
    logit = -1.2 + 0.035 * (age - 18) + rng.normal(0, 0.9, size=n)
    turnout = np.round(100 / (1 + np.exp(-logit)), 1)

    status = rng.choice(["active", "inactive", "moved", "deceased"], size=n,
                        p=[0.95, 0.03, 0.015, 0.005])

    return pd.DataFrame({
        "person_id": np.arange(100001, 100001 + n),
        "precinct_id": precinct,
        "age": age,
        "registration_status": status,
        "support_score": support,
        "turnout_score": turnout,
    })


def build_partner_lists(rng: np.random.Generator, people: pd.DataFrame) -> pd.DataFrame:
    """Two coalition partners share lists. They lean toward supporters but aren't screened."""
    partners = [
        ("educators", "Westmark Educators Union member list", 0.025, date(2026, 9, 1)),
        ("rivers", "Clean Rivers Alliance supporter list", 0.020, date(2026, 9, 15)),
    ]
    weight = (people["support_score"].to_numpy() + 10) ** 2
    frames = []
    for code, name, rate, added_on in partners:
        idx = rng.choice(len(people), size=int(rate * len(people)), replace=False,
                         p=weight / weight.sum())
        frames.append(pd.DataFrame({
            "person_id": people["person_id"].to_numpy()[idx],
            "partner_code": code,
            "list_name": name,
            "added_on": added_on,
        }))
    return pd.concat(frames, ignore_index=True)


# ---------------------------------------------------------------------------
# Field program
# ---------------------------------------------------------------------------
def ramped_days(rng: np.random.Generator, start: date, end: date, k: int) -> list[date]:
    """k sorted days in [start, end], weighted toward the end like a real field program."""
    span = (end - start).days + 1
    w = (1 + 2 * np.arange(span) / span) ** 2
    picks = np.sort(rng.choice(span, size=k, p=w / w.sum()))
    return [start + timedelta(days=int(d)) for d in picks]


def local_timestamps(rng: np.random.Generator, days: list[date], channel: str) -> list[pd.Timestamp]:
    lo, hi = LOCAL_HOURS[channel]
    minutes = rng.integers(lo * 60, hi * 60, size=len(days))
    return [pd.Timestamp(d) + pd.Timedelta(minutes=int(m)) for d, m in zip(days, minutes)]


def simulate_contacts(rng, people, person_idx, start, end, mean_attempts, stop_after_reach):
    """One row per attempt. People get 1+ attempts across channels until reached (usually)."""
    rows = []
    density = people["density"].to_numpy()
    pid = people["person_id"].to_numpy()
    channels = np.array(["door", "phone", "text"])
    for i in person_idx:
        n = 1 + rng.poisson(mean_attempts - 1)
        days = ramped_days(rng, start, end, n)
        for day in days:
            channel = rng.choice(channels, p=CHANNEL_MIX[density[i]])
            probs = OUTCOMES[channel]
            outcome = rng.choice(list(probs), p=list(probs.values()))
            ts = local_timestamps(rng, [day], channel)[0]
            rows.append((pid[i], channel, outcome, ts))
            if outcome in REACH_OUTCOMES and rng.random() < stop_after_reach:
                break
    return pd.DataFrame(rows, columns=["person_id", "channel", "outcome", "local_ts"])


def support_answer(rng, support_score, shift=0.0, noise=15.0):
    latent = support_score + shift + rng.normal(0, noise, size=len(support_score))
    return np.select([latent > 80, latent > 60, latent > 40, latent > 20], ["1", "2", "3", "4"], "5")


def build_early_vote_returns(rng, people) -> pd.DataFrame:
    """The state's daily file of returned mail and early in-person ballots."""
    p_vote = people["turnout_score"].to_numpy() / 100 * 0.5
    p_vote[people["registration_status"].isin(["moved", "deceased"]).to_numpy()] = 0
    voted = rng.random(len(people)) < p_vote
    voters = people.loc[voted, "person_id"].to_numpy()
    is_mail = rng.random(len(voters)) < 0.55
    returned = np.empty(len(voters), dtype=object)
    mail_days = ramped_days(rng, MAIL_VOTING_START, ELECTION_DAY - timedelta(days=1), int(is_mail.sum()))
    early_days = ramped_days(rng, *EARLY_VOTING, int((~is_mail).sum()))
    returned[is_mail] = rng.permutation(np.array(mail_days, dtype=object))
    returned[~is_mail] = rng.permutation(np.array(early_days, dtype=object))
    return pd.DataFrame({
        "person_id": voters,
        "ballot_type": np.where(is_mail, "mail", "early_in_person"),
        "returned_on": returned,
    })


def gotv_responses(rng, reached, people, returns) -> pd.DataFrame:
    """Script answers from GOTV conversations. Not every question gets asked every time."""
    returned_on = returns.set_index("person_id")["returned_on"]
    support = people.set_index("person_id")["support_score"]
    rows = []
    sup = support.reindex(reached["person_id"]).to_numpy()
    sup_ans = support_answer(rng, sup, shift=8, noise=10)
    plans = np.array(["mail", "early_in_person", "election_day", "unsure", "already_voted"])
    for j, r in enumerate(reached.itertuples()):
        day = r.local_ts.date()
        if rng.random() < 0.90:
            rows.append((r.attempt_id, r.person_id, "support_check", sup_ans[j], r.local_ts))
        if rng.random() < 0.85:
            voted_before = r.person_id in returned_on.index and returned_on[r.person_id] < day
            if voted_before and rng.random() < 0.85:
                plan = "already_voted"
            else:
                plan = rng.choice(plans, p=[0.15, 0.25, 0.45, 0.12, 0.03])
            rows.append((r.attempt_id, r.person_id, "vote_plan", plan, r.local_ts))
        if rng.random() < 0.60:
            rows.append((r.attempt_id, r.person_id, "ride_needed",
                         "yes" if rng.random() < 0.07 else "no", r.local_ts))
    return pd.DataFrame(rows, columns=["attempt_id", "person_id", "question_code", "answer_code", "local_ts"])


def to_utc(local: pd.Series) -> pd.Series:
    return local.dt.tz_localize(TIMEZONE).dt.tz_convert("UTC")


# ---------------------------------------------------------------------------
def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--people", type=int, default=60_000)
    ap.add_argument("--seed", type=int, default=2026)
    ap.add_argument("--out", type=Path, default=REPO / "data" / "raw")
    args = ap.parse_args()

    rng = np.random.default_rng(args.seed)
    counties, precincts = build_geography()
    people = build_people(rng, args.people, counties, precincts)
    people_geo = people.merge(precincts[["precinct_id", "region", "density"]], on="precinct_id")
    partners = build_partner_lists(rng, people)

    # Persuasion phase (before GOTV): persuadable voters plus some noise.
    sup = people_geo["support_score"].to_numpy()
    persuadable = (sup >= 35) & (sup <= 75)
    p_target = np.where(persuadable, 0.25, 0.05)
    persuasion_idx = np.flatnonzero(rng.random(len(people_geo)) < p_target)
    persuasion = simulate_contacts(rng, people_geo, persuasion_idx, PERSUASION_START,
                                   GOTV_START - timedelta(days=1), mean_attempts=1.6, stop_after_reach=0.9)

    # GOTV phase: the field program works likely supporters (a wider net than any
    # one universe definition), at a pace that differs by region, plus stray contacts.
    turn = people_geo["turnout_score"].to_numpy()
    targetish = (sup >= 60) & (turn >= 15) & (turn <= 85)
    targetish |= people_geo["person_id"].isin(partners["person_id"]).to_numpy()
    region_rate = people_geo["region"].map(REGION_REACH).to_numpy()
    p_gotv = np.where(targetish, region_rate, 0.03)
    gotv_idx = np.flatnonzero(rng.random(len(people_geo)) < p_gotv)
    gotv = simulate_contacts(rng, people_geo, gotv_idx, GOTV_START, ELECTION_DAY,
                             mean_attempts=2.6, stop_after_reach=0.7)

    # A few volunteer-event check-ins land in the same contact log. They are
    # not voter contact and the pipeline must not count them.
    ev_idx = rng.choice(len(people_geo), size=int(0.01 * len(people_geo)), replace=False)
    ev_days = ramped_days(rng, GOTV_START, ELECTION_DAY, len(ev_idx))
    events = pd.DataFrame({
        "person_id": people_geo["person_id"].to_numpy()[ev_idx],
        "channel": "event",
        "outcome": "attended",
        "local_ts": local_timestamps(rng, ev_days, "event"),
    })

    contacts = pd.concat([persuasion, gotv, events], ignore_index=True)
    contacts = contacts.sort_values(["local_ts", "person_id"]).reset_index(drop=True)
    contacts.insert(0, "attempt_id", np.arange(1, len(contacts) + 1))

    returns = build_early_vote_returns(rng, people)

    # Survey answers: persuasion-phase IDs, then the GOTV script.
    reached = contacts[contacts["outcome"].isin(REACH_OUTCOMES)]
    pre = reached[reached["local_ts"] < pd.Timestamp(GOTV_START)]
    pre_sup = people.set_index("person_id")["support_score"].reindex(pre["person_id"]).to_numpy()
    pre_resp = pd.DataFrame({
        "attempt_id": pre["attempt_id"].to_numpy(),
        "person_id": pre["person_id"].to_numpy(),
        "question_code": "support_check",
        "answer_code": support_answer(rng, pre_sup),
        "local_ts": pre["local_ts"].to_numpy(),
    })
    post_resp = gotv_responses(rng, reached[reached["local_ts"] >= pd.Timestamp(GOTV_START)], people, returns)
    responses = pd.concat([pre_resp, post_resp], ignore_index=True)
    responses.insert(0, "response_id", np.arange(1, len(responses) + 1))

    # Store event times the way most systems do: UTC.
    contacts["attempted_at"] = to_utc(contacts.pop("local_ts"))
    responses["recorded_at"] = to_utc(responses.pop("local_ts"))

    tables = {
        "precincts": precincts,
        "people": people,
        "partner_lists": partners,
        "contact_log": contacts,
        "survey_responses": responses,
        "early_vote_returns": returns,
    }
    args.out.mkdir(parents=True, exist_ok=True)
    con = duckdb.connect()
    for name, df in tables.items():
        con.register("df", df)
        con.execute(f"COPY (SELECT * FROM df) TO '{args.out / name}.parquet' (FORMAT parquet)")
        con.unregister("df")
        print(f"  {name:<20} {len(df):>8,} rows")
    print(f"Wrote synthetic Westmark data to {args.out}")


if __name__ == "__main__":
    main()
