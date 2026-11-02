#!/usr/bin/env python3
"""Re-scrape the team-seasons listed as stale copies, and check the results.

data/stale_roster_exclusions.csv lists team-seasons whose raw roster was a
copy of another season (see find_stale_rosters.py). This script runs the
roster scraper in the dwillis/wbb repo (`uv run wbb scrape`) for each of
those team-seasons, then compares every result to the raw roster of the
season it had copied (from a local dwillis/wbb-rosters checkout), using
the same test as find_stale_rosters.py: at least MIN_SHARED shared roster
URLs, covering MIN_OVERLAP of the smaller roster, with identical name and
class year on every shared URL.

Each team-season gets one of these statuses:
  ok          rows came back and do not copy the other season
  still_copy  the scrape returned the copied season again
  no_compare  rows came back, but the copied season is not in wbb-rosters
  zero_rows   the scraper found no players (or failed the season check)

Nothing in this repo or in wbb-rosters is modified. Output goes to
--out-dir (default data/rescrape/, gitignored):
  rosters_<season>.csv   the scraper's raw-format rows (all statuses)
  ok_<season>.csv        only the rows that passed (status ok)
  rescrape_report.csv    one row per team-season with its status

Splice the ok_<season>.csv rows into wbb-rosters (replacing that team's
rows), re-knit cleaning.Rmd for the affected seasons, then delete their
team_season entries from data/stale_roster_exclusions.csv.

Run from the repo root (stdlib only; the scraper needs uv):
    python3 scripts/rescrape_stale_rosters.py --dry-run
    python3 scripts/rescrape_stale_rosters.py --season 2020-21 --teams 2699 352
    python3 scripts/rescrape_stale_rosters.py              # everything
"""

import argparse
import csv
import os
import subprocess
import sys
from collections import defaultdict

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from find_stale_rosters import MIN_OVERLAP, MIN_SHARED, OUT as EXCLUSIONS, norm_url  # noqa: E402

REPORT_FIELDS = ["season", "ncaa_id", "team", "copy_of_season", "status",
                 "n_rows", "shared_urls", "overlap"]


def load_targets(season=None, teams=None):
    """{season: [exclusion rows]} for the team_season entries to re-scrape."""
    targets = defaultdict(list)
    with open(EXCLUSIONS, newline="", encoding="utf-8") as f:
        for r in csv.DictReader(f):
            if r["scope"] != "team_season":
                continue
            if season and r["season"] != season:
                continue
            if teams and r["ncaa_id"] not in teams:
                continue
            targets[r["season"]].append(r)
    return targets


def read_raw(path):
    """{team_id: [rows]} from a raw-format roster CSV, or {} if missing."""
    by_team = defaultdict(list)
    if os.path.exists(path):
        with open(path, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                by_team[str(r["team_id"])].append(r)
    return by_team


def roster_key(rows):
    """{normalized url: (name, class year)} for one team's raw rows."""
    return {norm_url(r["url"]): (r["name"].strip(), r["academic_year"].strip().lower())
            for r in rows if norm_url(r.get("url"))}


def compare(new_rows, old_rows):
    """(is_copy, shared url count, overlap share), as in find_stale_rosters."""
    a, b = roster_key(new_rows), roster_key(old_rows)
    shared = set(a) & set(b)
    overlap = len(shared) / min(len(a), len(b)) if a and b else 0.0
    is_copy = (len(shared) >= MIN_SHARED and overlap >= MIN_OVERLAP
               and all(a[u] == b[u] and a[u][1] for u in shared))
    return is_copy, len(shared), overlap


def scrape(season, team_ids, wbb_dir, season_dir):
    """Run the wbb scraper for one season; return {team_id: [rows]}."""
    os.makedirs(season_dir, exist_ok=True)
    # a one-team run writes rosters_<season>_team_<id>.csv instead
    out_files = [os.path.join(season_dir, f"rosters_{season}.csv")] + [
        os.path.join(season_dir, f"rosters_{season}_team_{t}.csv") for t in team_ids]
    for path in out_files:
        if os.path.exists(path):
            os.remove(path)  # never read a previous run's rows
    cmd = ["uv", "run", "wbb", "scrape", "-s", season, "-entity", "player",
           "-teams", *team_ids, "--out-dir", os.path.abspath(season_dir)]
    print(f"{season}: scraping {len(team_ids)} teams", file=sys.stderr)
    # exit 1 means zero rows overall; that is a result, not a failure here
    result = subprocess.run(cmd, cwd=wbb_dir)
    if result.returncode not in (0, 1):
        sys.exit(f"scraper failed for {season} (exit {result.returncode})")
    rows = {}
    for path in out_files:
        rows.update(read_raw(path))
    return rows


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--season", help="only this season, e.g. 2020-21")
    p.add_argument("--teams", nargs="*", help="only these ncaa_ids")
    p.add_argument("--wbb-dir", default="../wbb", help="dwillis/wbb checkout")
    p.add_argument("--rosters-dir", default="../wbb-rosters",
                   help="dwillis/wbb-rosters checkout (raw season CSVs)")
    p.add_argument("--out-dir", default="data/rescrape")
    p.add_argument("--dry-run", action="store_true",
                   help="list the team-seasons and exit")
    args = p.parse_args()

    targets = load_targets(args.season, set(args.teams or []))
    if not targets:
        sys.exit("no matching team_season entries in " + EXCLUSIONS)
    if args.dry_run:
        for season in sorted(targets):
            print(season, " ".join(f"{r['ncaa_id']}:{r['team']}" for r in targets[season]))
        print(sum(map(len, targets.values())), "team-seasons")
        return
    if not os.path.exists(os.path.join(args.wbb_dir, "wbb", "cli.py")):
        sys.exit(f"--wbb-dir {args.wbb_dir} is not a dwillis/wbb checkout")

    raw_cache = {}
    report = []
    for season in sorted(targets):
        entries = targets[season]
        season_dir = os.path.join(args.out_dir, season)
        scraped = scrape(season, [r["ncaa_id"] for r in entries], args.wbb_dir, season_dir)
        ok_rows, all_rows = [], []
        for e in entries:
            new = scraped.get(e["ncaa_id"], [])
            all_rows += new
            copy_season = e["copy_of_season"]
            if copy_season not in raw_cache:
                raw_cache[copy_season] = read_raw(
                    os.path.join(args.rosters_dir, f"rosters_{copy_season}.csv"))
            old = raw_cache[copy_season].get(e["ncaa_id"], [])
            is_copy, n_shared, overlap = compare(new, old) if new and old else (False, 0, 0.0)
            if not new:
                status = "zero_rows"
            elif not old:
                status = "no_compare"
            else:
                status = "still_copy" if is_copy else "ok"
            if status == "ok":
                ok_rows += new
            report.append({"season": season, "ncaa_id": e["ncaa_id"], "team": e["team"],
                           "copy_of_season": copy_season, "status": status,
                           "n_rows": len(new), "shared_urls": n_shared,
                           "overlap": f"{overlap:.2f}"})
        rerun = {e["ncaa_id"] for e in entries}
        for name, rows in ((f"rosters_{season}.csv", all_rows), (f"ok_{season}.csv", ok_rows)):
            path = os.path.join(args.out_dir, name)
            # keep earlier runs' rows for teams not re-scraped this time
            kept = [r for t, rs in read_raw(path).items() if t not in rerun for r in rs]
            rows = kept + rows
            if not rows:
                continue
            with open(path, "w", newline="", encoding="utf-8") as f:
                w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
                w.writeheader()
                w.writerows(rows)

    report_path = os.path.join(args.out_dir, "rescrape_report.csv")
    if args.season or args.teams:
        # partial run: keep earlier results for team-seasons not re-run here
        done = {(r["season"], r["ncaa_id"]) for r in report}
        if os.path.exists(report_path):
            with open(report_path, newline="", encoding="utf-8") as f:
                report = [r for r in csv.DictReader(f)
                          if (r["season"], r["ncaa_id"]) not in done] + report
    report.sort(key=lambda r: (r["season"], int(r["ncaa_id"])))
    with open(report_path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=REPORT_FIELDS)
        w.writeheader()
        w.writerows(report)

    counts = defaultdict(int)
    for r in report:
        counts[r["status"]] += 1
    print(", ".join(f"{k}: {v}" for k, v in sorted(counts.items())), "->", report_path)


if __name__ == "__main__":
    main()
