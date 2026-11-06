#!/usr/bin/env python3
"""Audit conference labels in the committed roster CSVs.

Recomputes every row's expected conference (season-aware: the team's span in
data/teams_conference.csv when one covers the row's season, else the static
teams.csv value) and reports rows that disagree. Exit 1 on any mismatch, so it
can guard a pipeline run or CI.

Run after landing a new season CSV, re-knitting, or editing
teams.csv / data/teams_conference.csv. scripts/apply_conference_updates.py
rewrites stale files in place; this one never writes anything.

Known-data-gap exception: rows for teams with no ncaa_id in teams.csv (e.g.
MacMurray, Talladega) have NA conferences; they are counted and reported as a
warning, not a failure.
"""

import csv
import glob
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir)
TEAMS_CSV = os.path.join(ROOT, "teams.csv")
HISTORY_CSV = os.path.join(ROOT, "data", "teams_conference.csv")


def read_plain(path):
    with open(path, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def overrides_for(season, history):
    spans = [h for h in history if season >= h["first_season"]
             and (not h["last_season"] or season <= h["last_season"])]
    return {h["ncaa_id"]: h["conference"] for h in spans}


def audit(path, row_season):
    """Yield (kind, row_desc, detail) for rows whose conference is wrong."""
    static = {r["ncaa_id"]: r["conference"] for r in read_plain(TEAMS_CSV)}
    history = read_plain(HISTORY_CSV)
    cache, n_rows = {}, 0
    na_teams, wrong = {}, []
    with open(path, encoding="utf-8", newline="") as f:
        for r in csv.reader(f):
            if n_rows == 0:
                idx = {c: i for i, c in enumerate(r)}
                n_rows += 1
                continue
            n_rows += 1
            season = row_season(r, idx)
            if not season:
                continue
            if season not in cache:
                cache[season] = overrides_for(season, history)
            ov = cache[season]
            ncaa = r[idx["ncaa_id"]]
            if ncaa in ov:
                exp = ov[ncaa]
            elif ncaa in static:
                exp = static[ncaa]
            else:
                na_teams[r[idx["team"]]] = na_teams.get(r[idx["team"]], 0) + 1
                continue
            if r[idx["conference"]] != exp:
                wrong.append((r[idx["team"]], season, ncaa,
                              r[idx["conference"]], exp))
    return n_rows - 1, na_teams, wrong


def main():
    targets = sorted(glob.glob(os.path.join(ROOT, "wbb_rosters_2*.csv")))
    files = [p for p in targets if "_" in os.path.basename(p)
             and "combined" not in os.path.basename(p)]
    files.append(os.path.join(ROOT, "wbb_rosters_combined.csv"))
    failed = False
    for path in files:
        name = os.path.basename(path)
        if name == "wbb_rosters_combined.csv":
            season_of = lambda r, idx: r[idx["season"]]  # noqa: E731
        else:
            tag = name[len("wbb_rosters_"):-len(".csv")]
            season_of = lambda r, idx, s="%s-%s" % (tag[:4], tag[5:]): s  # noqa: E731,F841
        rows, na_teams, wrong = audit(path, season_of)
        status = "OK" if not wrong else "STALE"
        print("%-26s %7d rows  %-6s  %d wrong-conference row(s)"
              % (name, rows, status, len(wrong)))
        if na_teams:
            print("    warning: %d row(s) for teams missing from teams.csv"
                  " (conference left NA): %s"
                  % (sum(na_teams.values()),
                     ", ".join("%s x%d" % (t, n) for t, n in sorted(na_teams.items()))))
        for team, season, ncaa, got, exp in wrong[:8]:
            print("    %s %s (ncaa_id %s): stored %r, season-aware %r"
                  % (team, season, ncaa, got, exp))
        if len(wrong) > 8:
            print("    ... and %d more" % (len(wrong) - 8))
        if wrong:
            failed = True
            print("    run scripts/apply_conference_updates.py to fix")
    if failed:
        print("\nAUDIT FAILED")
        sys.exit(1)
    print("\nAll conference labels are season-correct.")


if __name__ == "__main__":
    main()
