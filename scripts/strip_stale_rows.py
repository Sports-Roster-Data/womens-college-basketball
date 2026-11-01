#!/usr/bin/env python3
"""Remove the rows listed in data/stale_roster_exclusions.csv from the
published season CSVs (wbb_rosters_YYYY_YY.csv), leaving every other byte as
it was.

Uses the editor's CSV reader/writer (editor/corrections.py), which
round-trips R's quote = "all" output exactly, so old seasons do not need a
re-knit. Matching follows player_id_functions.R's drop_stale_rows():
team_season entries drop every row with that season + ncaa_id; row entries
drop the row with that season + ncaa_id + name + url (url normalized).

Run from the repo root after scripts/find_stale_rosters.py:
    python3 scripts/strip_stale_rows.py
Idempotent: a second run removes nothing.
"""

import csv
import glob
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "editor"))
from corrections import format_table, read_table, write_atomic  # noqa: E402

sys.path.insert(0, os.path.dirname(__file__))
from find_stale_rosters import OUT, norm_url  # noqa: E402


def main():
    with open(OUT, newline="", encoding="utf-8") as f:
        exclusions = list(csv.DictReader(f))
    team_seasons = {(e["season"], e["ncaa_id"]) for e in exclusions
                    if e["scope"] == "team_season"}
    rows = {(e["season"], e["ncaa_id"], e["name"], norm_url(e["url"]))
            for e in exclusions if e["scope"] == "row"}

    total = 0
    for path in sorted(glob.glob("wbb_rosters_20[0-9][0-9]_[0-9][0-9].csv")):
        table = read_table(path)
        ix = table.index

        def stale(r):
            key = (r[ix["season"]], r[ix["ncaa_id"]])
            return key in team_seasons or \
                (*key, r[ix["name"]], norm_url(r[ix["url"]])) in rows

        kept = [r for r in table.rows if not stale(r)]
        dropped = len(table.rows) - len(kept)
        if dropped:
            table.rows = kept
            write_atomic(path, format_table(table))
        total += dropped
        print(f"{path}: dropped {dropped} rows")
    print(f"total dropped: {total}")


if __name__ == "__main__":
    main()
