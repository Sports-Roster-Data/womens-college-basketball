#!/usr/bin/env python3
"""Find team-seasons whose roster is a stale copy of another season.

Some raw scrapes in dwillis/wbb-rosters saved a team's current roster page
under an earlier season (IUPUI's 2020-21 rows are 2022-23's, row for row).
The copies break cross-season IDs: class years run backwards, so tier 1
cannot link the real seasons, and players appear on teams they never
played for.

Two seasons of one team are flagged when they share at least MIN_SHARED
roster URLs, the shared URLs cover at least MIN_OVERLAP of the smaller
roster, and every shared URL carries the same name and the same (non-blank)
year_clean in both. Real consecutive rosters never pass: returning players
move up a class year. Within each group of identical seasons one season is
kept as the real one and the others are marked stale. The kept season is the
one whose class years line up with the team's nearest unflagged seasons
before and after (returning players should be one class higher per season
elapsed); ties go to the latest season, since the scraper usually fell back
to the current page.

Writes data/stale_roster_exclusions.csv, merged with the entries already
there, so re-running after the season CSVs are stripped keeps the list:

    season, ncaa_id, team, scope, name, url, copy_of_season, reason

scope is team_season (drop every row of that team-season) or row (drop the
one row matching name + url). Row entries are curated in ROW_EXCLUSIONS.

Run from the repo root (stdlib only):
    python3 scripts/find_stale_rosters.py            # update the list
    python3 scripts/find_stale_rosters.py --check    # report, exit 1 if any
"""

import csv
import glob
import re
import statistics
import sys
from collections import defaultdict

OUT = "data/stale_roster_exclusions.csv"
FIELDS = ["season", "ncaa_id", "team", "scope", "name", "url",
          "copy_of_season", "reason"]
MIN_SHARED = 5
MIN_OVERLAP = 0.9
SEASONS = ["2020-21", "2021-22", "2022-23", "2023-24", "2024-25",
           "2025-26", "2026-27"]
YEAR_RANK = {"Freshman": 1, "Sophomore": 2, "Junior": 3, "Senior": 4,
             "Fifth Year": 5, "Graduate Student": 5, "Sixth Year": 6}

# Flagged pairs where the kept season was checked and is wrong:
# (ncaa_id, season) -> never excluded. Extend as audits find them, and add
# the season that really is the copy to AUDIT_STALE.
AUDIT_KEEP = {
    ("321", "2022-23"),  # John Jay: the re-scrape returns this roster for 2022-23
}

# The real copies behind AUDIT_KEEP entries. Once their rows are stripped the
# detector cannot see them, so they are listed by hand.
AUDIT_STALE = [
    {"season": "2020-21", "ncaa_id": "321", "team": "John Jay",
     "scope": "team_season", "name": "", "url": "", "copy_of_season": "2022-23",
     "reason": "roster is an exact copy of 2022-23 (CUNYAC did not play 2020-21; "
               "no 2020-21 roster on the site)"},
]

# Single duplicate rows the season-level test cannot see.
ROW_EXCLUSIONS = [
    {"season": "2024-25", "ncaa_id": "418", "team": "Michigan", "scope": "row",
     "name": "Brooke Q. Daniels",
     "url": "https://mgoblue.com/sports/womens-basketball/roster/brooke-q-daniels/25586",
     "copy_of_season": "",
     "reason": "duplicate of Brooke Quarles Daniels on the same 2024-25 roster"},
] + [
    # 2024-25 nickname rows scraped twice, once cut to the first name
    # (same url and jersey as the full-name row)
    {"season": "2024-25", "ncaa_id": ncaa_id, "team": team, "scope": "row",
     "name": name, "url": url, "copy_of_season": "",
     "reason": f"truncated duplicate of {full} on the same roster"}
    for ncaa_id, team, name, full, url in [
        ("47", "Ball State", "Maliyah", 'Maliyah "MJ" Johnson',
         "https://www.ballstatesports.com/sports/womens-basketball/roster/maliyah-mj-johnson/12090"),
        ("219", "Evansville", "Tamesha", 'Tamesha "Mae" Dozier',
         "https://www.gopurpleaces.com/sports/womens-basketball/roster/tamesha-mae-dozier/6368"),
        ("514", "Oakland", "Naveyah", 'Naveyah "Naz" Damon',
         "https://www.goldengrizzlies.com/sports/womens-basketball/roster/naveyah-naz-damon/10624"),
        ("572", "Rhode Island", "Harsimran", 'Harsimran "Honey" Kaur',
         "https://www.gorhody.com/sports/womens-basketball/roster/harsimran-honey-kaur/8219"),
    ]
]


def norm_url(url):
    url = re.sub(r"^https?://", "", (url or "").strip().lower())
    return re.sub(r"^www\.", "", url).rstrip("/")


def load_rosters():
    """{ncaa_id: {season: {url: (name, year_clean, team)}}}"""
    rosters = defaultdict(lambda: defaultdict(dict))
    for path in sorted(glob.glob("wbb_rosters_20[0-9][0-9]_[0-9][0-9].csv")):
        with open(path, newline="", encoding="utf-8") as f:
            for r in csv.DictReader(f):
                u = norm_url(r.get("url"))
                if u:
                    rosters[r["ncaa_id"]][r["season"]][u] = (
                        r["name"], r.get("year_clean") or "", r["team"])
    return rosters


def is_copy(a, b):
    shared = set(a) & set(b)
    if len(shared) < MIN_SHARED:
        return False
    if len(shared) / min(len(a), len(b)) < MIN_OVERLAP:
        return False
    return all(a[u][:2] == b[u][:2] and a[u][1] for u in shared)


def season_idx(season):
    return SEASONS.index(season) if season in SEASONS else int(season[:4])


def class_gap_error(roster_c, c, roster_n, n):
    """How far returning players' class change is from the seasons elapsed.

    None when fewer than 3 players overlap with a ranked class year. The
    2020-21 COVID freeze lets a 2020-21 player repeat a class once.
    """
    by_name_c = {v[0].lower(): YEAR_RANK.get(v[1]) for v in roster_c.values()}
    by_name_n = {v[0].lower(): YEAR_RANK.get(v[1]) for v in roster_n.values()}
    deltas = [by_name_n[x] - by_name_c[x] for x in set(by_name_c) & set(by_name_n)
              if by_name_c[x] and by_name_n[x]]
    if len(deltas) < 3:
        return None
    delta = statistics.median(deltas)
    gap = season_idx(n) - season_idx(c)
    errors = [abs(delta - gap)]
    if "2020-21" in (c, n):
        errors.append(abs(abs(delta) - (abs(gap) - 1)))
    return min(errors)


def pick_real_season(seasons, members):
    """The member whose class years best fit the nearest outside seasons."""
    outside = [s for s in sorted(seasons) if s not in members]
    neighbors = [s for s in (
        max((s for s in outside if s < min(members)), default=None),
        min((s for s in outside if s > max(members)), default=None)) if s]

    def score(c):
        errs = [class_gap_error(seasons[c], c, seasons[n], n) for n in neighbors]
        errs = [e for e in errs if e is not None]
        return (sum(errs) / len(errs) if errs else 0, -season_idx(c))

    return min(members, key=score)


def find_stale(rosters):
    stale = []
    for ncaa_id, seasons in rosters.items():
        order = sorted(seasons)
        # union-find over flagged pairs -> groups of identical seasons
        parent = {s: s for s in order}

        def root(s):
            while parent[s] != s:
                s = parent[s]
            return s

        for i, a in enumerate(order):
            for b in order[i + 1:]:
                if is_copy(seasons[a], seasons[b]):
                    parent[root(a)] = root(b)
        groups = defaultdict(list)
        for s in order:
            groups[root(s)].append(s)
        for members in groups.values():
            if len(members) < 2:
                continue
            keep = pick_real_season(seasons, members)
            for s in members:
                if s == keep or (ncaa_id, s) in AUDIT_KEEP:
                    continue
                team = next(iter(seasons[s].values()))[2]
                stale.append({
                    "season": s, "ncaa_id": ncaa_id, "team": team,
                    "scope": "team_season", "name": "", "url": "",
                    "copy_of_season": keep,
                    "reason": f"roster is an exact copy of {keep}",
                })
    return stale


def key(r):
    return (r["season"], r["ncaa_id"], r["scope"], r["name"], r["url"])


def main():
    found = find_stale(load_rosters())
    if "--check" in sys.argv:
        for r in found:
            print(r["season"], r["ncaa_id"], r["team"], "copies", r["copy_of_season"])
        print(f"{len(found)} stale team-seasons")
        sys.exit(1 if found else 0)

    existing = []
    try:
        with open(OUT, newline="", encoding="utf-8") as f:
            existing = list(csv.DictReader(f))
    except FileNotFoundError:
        pass
    merged = {key(r): r for r in existing}
    for r in found + AUDIT_STALE + ROW_EXCLUSIONS:
        merged.setdefault(key(r), r)
    for ncaa_id, season in AUDIT_KEEP:
        merged = {k: r for k, r in merged.items()
                  if not (r["ncaa_id"] == ncaa_id and r["season"] == season
                          and r["scope"] == "team_season")}
    rows = sorted(merged.values(), key=lambda r: (r["season"], int(r["ncaa_id"]), r["name"]))
    with open(OUT, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS, quoting=csv.QUOTE_ALL)
        w.writeheader()
        w.writerows(rows)
    print(f"{len(found)} stale team-seasons found; {len(rows)} entries in {OUT}")


if __name__ == "__main__":
    main()
