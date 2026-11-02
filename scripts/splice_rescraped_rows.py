#!/usr/bin/env python3
"""Splice re-scraped rosters (scripts/rescrape_stale_rosters.py) back in.

For each season, oldest first (each season backfills high schools from the
one before):

1. Remove that season's team_season entries for the re-scraped teams from
   data/stale_roster_exclusions.csv (otherwise cleaning.Rmd and
   load_all_seasons() drop the new rows too).
2. Clean only the re-scraped rows: knit cleaning.Rmd in staging mode
   (WBB_STAGING_* env vars) on data/rescrape/ok_<season>.csv, writing
   data/rescrape/clean_<season>.csv. The season file is not re-knit, so its
   other rows, its hand fixes and its column layout stay as they are.
3. Insert the cleaned rows into wbb_rosters_<season>.csv, mapped onto that
   file's own columns (columns it lacks are dropped, columns the new output
   lacks are left blank), each team's block placed in ncaa_id order. Every
   other byte is unchanged (editor/corrections.py's CSV reader/writer).

Only team-seasons with status ok in data/rescrape/rescrape_report.csv are
used. Teams that already have rows in the season file are skipped, so the
script can be re-run.

With --raw DIR it instead replaces those team-seasons' rows in the raw
dwillis/wbb-rosters files (DIR/rosters_<season>.csv) with the re-scraped
rows, so the raw source matches. Commit that repo separately.

Run from the repo root, then re-knit player_ids.Rmd:
    python3 scripts/splice_rescraped_rows.py [--season 2020-21]
    python3 scripts/splice_rescraped_rows.py --raw ../wbb-rosters
"""

import argparse
import csv
import io
import os
import subprocess
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "editor"))
sys.path.insert(0, HERE)
from corrections import format_table, read_table, write_atomic  # noqa: E402
from find_stale_rosters import FIELDS, OUT as EXCLUSIONS  # noqa: E402

RESCRAPE = "data/rescrape"
REPORT = os.path.join(RESCRAPE, "rescrape_report.csv")
PANDOC = "/Applications/RStudio.app/Contents/Resources/app/quarto/bin/tools/x86_64"


def ok_teams():
    """{season: set(ncaa_id)} with status ok in the rescrape report."""
    out = defaultdict(set)
    with open(REPORT, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["status"] == "ok":
                out[r["season"]].add(r["ncaa_id"])
    return out


def drop_exclusions(season, ids):
    with open(EXCLUSIONS, newline="", encoding="utf-8") as f:
        rows = list(csv.DictReader(f))
    kept = [r for r in rows if not (r["season"] == season and r["ncaa_id"] in ids
                                    and r["scope"] == "team_season")]
    with open(EXCLUSIONS, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS, quoting=csv.QUOTE_ALL)
        w.writeheader()
        w.writerows(kept)
    return len(rows) - len(kept)


def subset_raw(season, ids, path):
    """Write the ok rows for ids to path; return the row count."""
    with open(os.path.join(RESCRAPE, f"ok_{season}.csv"), newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = [r for r in reader if r["team_id"] in ids]
        fields = reader.fieldnames
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=fields)
        w.writeheader()
        w.writerows(rows)
    return len(rows)


def knit_staging(season, raw_path, out_path):
    env = dict(os.environ, LANG="en_US.UTF-8",
               WBB_STAGING_SEASON=season,
               WBB_STAGING_INPUT=os.path.abspath(raw_path),
               WBB_STAGING_OUTPUT=os.path.abspath(out_path))
    env.setdefault("RSTUDIO_PANDOC", PANDOC)
    expr = (f"rmarkdown::render('cleaning.Rmd', output_dir='{RESCRAPE}', "
            f"output_file='cleaning_{season}.html', knit_root_dir=getwd(), quiet=TRUE)")
    log = os.path.join(RESCRAPE, f"cleaning_{season}.log")
    with open(log, "w") as f:
        result = subprocess.run(["Rscript", "-e", expr], env=env, stdout=f, stderr=subprocess.STDOUT)
    if result.returncode != 0:
        sys.exit(f"cleaning.Rmd failed for {season}; see {log}")


def splice_season_file(season, clean_path):
    path = f"wbb_rosters_{season.replace('-', '_')}.csv"
    table = read_table(path)
    new = read_table(clean_path)
    ix, nix = table.index, new.index
    present = {r[ix["ncaa_id"]] for r in table.rows}
    blocks = defaultdict(list)
    for r in new.rows:
        if r[nix["ncaa_id"]] in present:
            continue
        blocks[r[nix["ncaa_id"]]].append(
            [r[nix[c]] if c in nix else None for c in table.header])
    rows = list(table.rows)
    for ncaa_id in sorted(blocks, key=int):
        # before the first row of a higher ncaa_id (files are sorted by it)
        at = next((i for i, r in enumerate(rows) if int(r[ix["ncaa_id"]]) > int(ncaa_id)),
                  len(rows))
        rows[at:at] = blocks[ncaa_id]
    added = len(rows) - len(table.rows)
    table.rows = rows
    write_atomic(path, format_table(table))
    dropped_cols = [c for c in new.header if c not in ix]
    blank_cols = [c for c in table.header if c not in nix]
    return path, added, len(blocks), dropped_cols, blank_cols


def splice_raw(raw_dir, teams):
    for season in sorted(teams):
        path = os.path.join(raw_dir, f"rosters_{season}.csv")
        with open(path, newline="", encoding="utf-8") as f:
            text = f.read()
        eol = "\r\n" if "\r\n" in text[:4096] else "\n"
        rows = list(csv.reader(io.StringIO(text)))
        header, body = rows[0], rows[1:]
        tid = header.index("team_id")
        with open(os.path.join(RESCRAPE, f"ok_{season}.csv"), newline="", encoding="utf-8") as f:
            reader = csv.DictReader(f)
            new = [[r[c] for c in header] for r in reader if r["team_id"] in teams[season]]
        by_team = defaultdict(list)
        for r in new:
            by_team[r[tid]].append(r)
        # each team's new block goes where its old rows were, else at the end
        out_rows, removed = [], 0
        for r in body:
            if r[tid] in teams[season]:
                removed += 1
                out_rows += by_team.pop(r[tid], [])
            else:
                out_rows.append(r)
        for t in sorted(by_team, key=int):
            out_rows += by_team[t]
        out = io.StringIO()
        csv.writer(out, lineterminator=eol).writerows([header] + out_rows)
        write_atomic(path, out.getvalue())
        print(f"{path}: replaced {removed} rows with {len(new)} for {len(teams[season])} teams")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--season", help="only this season")
    p.add_argument("--raw", metavar="DIR", help="splice into dwillis/wbb-rosters raw files instead")
    args = p.parse_args()

    teams = ok_teams()
    if args.season:
        teams = {args.season: teams.get(args.season, set())}
    if args.raw:
        splice_raw(args.raw, teams)
        return

    for season in sorted(teams):
        path = f"wbb_rosters_{season.replace('-', '_')}.csv"
        table = read_table(path)
        present = {r[table.index["ncaa_id"]] for r in table.rows}
        ids = teams[season] - present
        if not ids:
            print(f"{season}: nothing to splice")
            continue
        n_ex = drop_exclusions(season, ids)
        raw_path = os.path.join(RESCRAPE, f"splice_raw_{season}.csv")
        clean_path = os.path.join(RESCRAPE, f"clean_{season}.csv")
        n_raw = subset_raw(season, ids, raw_path)
        print(f"{season}: cleaning {n_raw} rows for {len(ids)} teams "
              f"({n_ex} exclusion entries removed)", file=sys.stderr)
        knit_staging(season, raw_path, clean_path)
        path, added, n_teams, dropped, blank = splice_season_file(season, clean_path)
        print(f"{path}: added {added} rows for {n_teams} teams"
              f"{'; not in this file: ' + ', '.join(dropped) if dropped else ''}"
              f"{'; left blank: ' + ', '.join(blank) if blank else ''}")


if __name__ == "__main__":
    main()
