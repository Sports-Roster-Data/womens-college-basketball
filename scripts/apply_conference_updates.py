#!/usr/bin/env python3
"""Apply season-aware conference overrides to committed roster CSVs.

teams.csv's conference column is static (reflects each team's current
affiliation), so season CSVs knit before a realignment carry stale values.
This script rewrites ONLY the conference field of rows whose season-aware
conference (per data/teams_conference.csv — the same rule the
`conf_overrides` chunk of cleaning.Rmd applies) differs from what is stored.
Everything else is byte-identical via the corrections.py reader/writer, which
reproduces R's write_csv(quote = "all", na = "") exactly.

Run after any change to data/teams_conference.csv (new realignment, new
season) to bring already-committed files in line with what a fresh knit would
produce, without re-pulling the raw scrapes. scripts/audit_conferences.py is
the fast "is anything stale?" check; this rewrites the files.

Rows for teams absent from teams.csv (e.g. MacMurray, Talladega) are left
untouched and reported.
"""

import csv
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                os.pardir, "editor"))
import corrections  # noqa: E402

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir)
TEAMS_CSV = os.path.join(ROOT, "teams.csv")
HISTORY_CSV = os.path.join(ROOT, "data", "teams_conference.csv")
SEASON_FILES = ["wbb_rosters_%d_%02d.csv" % (y, (y + 1) % 100) for y in range(2020, 2027)]


def read_plain(path):
    with open(path, encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def load_static():
    """ncaa_id (str) -> teams.csv conference."""
    return {r["ncaa_id"]: r["conference"] for r in read_plain(TEAMS_CSV)}


def overrides_for(season, history):
    """Map ncaa_id -> conference for spans that cover `season`."""
    binds = [h for h in history
             if season >= h["first_season"]
             and (not h["last_season"] or season <= h["last_season"])]
    ncaas = [h["ncaa_id"] for h in binds]
    assert len(ncaas) == len(set(ncaas)), \
        "spans in team_conference.csv overlap for season %s: %s" % (season, ncaas)
    return {h["ncaa_id"]: h["conference"] for h in binds}


def expected(row, c_idx, n_idx, ov, static):
    """Season-aware conference for a row; None when the team is unknown."""
    ncaa = row[n_idx]
    if ncaa in ov:
        return ov[ncaa]
    return static.get(ncaa)


def process(path, row_season, history, static, label):
    """Patch one CSV. row_season(row, season_col_idx) -> season string."""
    with open(path, encoding="utf-8", newline="") as f:
        raw = f.read()
    table = corrections.read_table(path)
    # The writer must reproduce the untouched file exactly before we change
    # anything, otherwise "byte-identical apart from conference" is a lie.
    roundtrip = corrections.format_table(table)
    assert roundtrip == raw, \
        "%s: corrections.py round-trip is not byte-stable; aborting" % label
    c, n, s = table.index["conference"], table.index["ncaa_id"], table.index["season"]
    changed = skip = 0
    cache = {}
    for r in table.rows:
        season = row_season(r, s)
        if season not in cache:
            cache[season] = overrides_for(season, history)
        exp = expected(r, c, n, cache[season], static)
        if exp is None:
            skip += 1
            continue
        if (r[c] or "") != exp:
            r[c] = exp
            changed += 1
    if changed:
        corrections.write_atomic(path, corrections.format_table(table))
    print("%-26s %5d conference cell(s) updated, %3d row(s) skipped (team unknown)"
          % (label, changed, skip))

    # verify by re-reading the written file
    table = corrections.read_table(path)
    c, n, s = table.index["conference"], table.index["ncaa_id"], table.index["season"]
    bad = []
    cache = {}
    for r in table.rows:
        season = row_season(r, s)
        if season not in cache:
            cache[season] = overrides_for(season, history)
        exp = expected(r, c, n, cache[season], static)
        if exp is not None and (r[c] or "") != exp:
            bad.append((r[table.index["team"]], season, r[c], exp))
    assert not bad, "%s: %d rows still wrong after write: %s" % (label, len(bad), bad[:5])
    return changed


def file_season(fname):
    tag = fname[len("wbb_rosters_"):-len(".csv")]
    return "%s-%s" % (tag[:4], tag[5:])


def main():
    static = load_static()
    history = read_plain(HISTORY_CSV)
    total = 0
    for fname in SEASON_FILES:
        total += process(os.path.join(ROOT, fname),
                         lambda r, s: file_season(fname),
                         history, static, file_season(fname))
    # combined: each row carries its own season
    total += process(os.path.join(ROOT, "wbb_rosters_combined.csv"),
                     lambda r, s: r[s], history, static, "combined")
    print("\nTotal: %d conference cell(s) updated" % total)


if __name__ == "__main__":
    main()
