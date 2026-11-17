#!/usr/bin/env python3
"""Draw docs/daily_progress.png from the pipeline's daily_progress table."""
from __future__ import annotations

from pathlib import Path

import duckdb
import matplotlib

matplotlib.use("Agg")
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter, PercentFormatter

HERE = Path(__file__).resolve().parent
DB = HERE.parent / "data" / "westmark.duckdb"
OUT = HERE / "docs" / "daily_progress.png"

SURFACE, TEXT, TEXT_2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e6e5e1"
# Fixed categorical order, assigned by entity (largest universe first), never by rank.
REGION_COLORS = {"Harbor": "#2a78d6", "Capital": "#eb6834", "Lakes": "#1baf7a", "Ridge": "#eda100"}


def main() -> None:
    con = duckdb.connect(str(DB), read_only=True)
    df = con.sql("SELECT area, day, attempted_rate FROM gotv.daily_progress ORDER BY area, day").df()
    universes = dict(con.sql(
        "SELECT geo_value, universe FROM gotv.coverage_by_geo WHERE geo_level IN ('region', 'state')"
    ).fetchall())
    con.close()

    plt.rcParams.update({"font.size": 10, "axes.edgecolor": GRID, "text.color": TEXT})
    fig, ax = plt.subplots(figsize=(8.6, 4.6), dpi=200)
    fig.patch.set_facecolor(SURFACE)
    ax.set_facecolor(SURFACE)

    def end_label(series, text, color):
        last = series.iloc[-1]
        ax.plot(last["day"], last["attempted_rate"], "o", ms=5, color=color, mec=SURFACE, mew=1.5, zorder=4)
        ax.annotate(f"{text}  {last['attempted_rate']:.0%}", (last["day"], last["attempted_rate"]),
                    xytext=(8, 0), textcoords="offset points", va="center", fontsize=9, color=TEXT)

    state_final = df[df["area"] == "All regions"]["attempted_rate"].iloc[-1]

    for region, color in REGION_COLORS.items():
        s = df[df["area"] == region]
        ax.plot(s["day"], s["attempted_rate"], color=color, lw=2, solid_capstyle="round",
                label=f"{region} ({universes[region]:,} people)", zorder=3)
        end_label(s, region, color)

    ax.set_ylim(0, 1)
    ax.yaxis.set_major_formatter(PercentFormatter(1.0, decimals=0))
    ax.grid(axis="y", color=GRID, lw=0.8)
    ax.tick_params(colors=TEXT_2, length=0)
    for side in ("top", "right", "left"):
        ax.spines[side].set_visible(False)
    ax.margins(x=0.01)
    ax.xaxis.set_major_locator(mdates.WeekdayLocator(byweekday=mdates.TU))
    # "Oct 6", not "Oct 06", on every platform
    ax.xaxis.set_major_formatter(FuncFormatter(lambda x, _: (d := mdates.num2date(x)).strftime("%b ") + str(d.day)))

    fig.text(0.06, 0.95, "Share of the GOTV universe attempted at least once",
             fontsize=12.5, weight="bold", color=TEXT)
    fig.text(0.06, 0.905, f"By field region, Oct 13 to Election Day. Statewide: {state_final:.0%} of "
             f"{universes['Westmark']:,} people. Synthetic data.", fontsize=9.5, color=TEXT_2)
    ax.legend(loc="upper left", frameon=False, fontsize=9, labelcolor=TEXT, ncol=2,
              handlelength=1.6, borderaxespad=0.2)
    fig.subplots_adjust(left=0.06, right=0.86, top=0.85, bottom=0.08)

    OUT.parent.mkdir(exist_ok=True)
    fig.savefig(OUT, facecolor=SURFACE)
    print(f"Wrote {OUT.relative_to(HERE.parent)}")


if __name__ == "__main__":
    main()
