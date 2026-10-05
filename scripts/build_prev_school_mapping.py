#!/usr/bin/env python3
"""Build data/previous_school_mapping.csv from the roster CSVs and teams.csv.

One row per distinct previous-school lookup string (the raw `previous_school`
column when present, else `previous_school_clean`), with:

    previous_school  the lookup string exactly as it appears in the roster CSVs
    canonical        canonical name: the teams.csv spelling for roster teams,
                     the curated list's spelling for JuCos, the title-cased
                     value for prep schools, else blank (manual work pending)
    ncaa_id          the matching teams.csv id for roster teams, else blank
    category         roster_team / juco / prep / four_year_other / other
    confidence       high_auto / low_fuzzy / manual

Stages, in order:
  1. high_auto  -- abbreviation-expanded exact match against teams.csv names
                   and the curated JuCo list, plus literal prep-school tokens.
  2. low_fuzzy  -- closest difflib match (ratio >= 0.85) against those targets,
                   auto-applied but flagged for review blanks if wrong.
  3. manual     -- everything else, most-mentioned first so human effort lands
                   where the mentions are.

Only TOKEN-equality rules — never substring search on school names (a loose
"contains CC" guess would misfire on College of Charleston).

Self-contained by design: stdlib only (the HS mapping scripts' missing
`hs_standardization` module is a known landmine -- CLAUDE.md).

Run from the repo root (globs every wbb_rosters_20*.csv, so re-run after any
new season lands):
    python3 scripts/build_prev_school_mapping.py
"""

import csv
import glob
import re
from collections import Counter
from difflib import SequenceMatcher

# Token expansions applied to BOTH sides before comparison. Token equality
# keeps these safe: no school in teams.csv contains a standalone "cc" or "st"
# token that means something else here.
ABBREV = {"st": "state", "u": "university", "univ": "university",
          "cc": "community college", "jc": "junior college"}

# Curated two-year institutions seen in these rosters (canonical display
# spelling). Extend the list as review surfaces more; token rules never
# overrule it.
JUCO_NAMES = [
    "Blinn College", "Casper College", "Chipola College",
    "College of Southern Idaho", "Eastern Florida State College",
    "Florida SouthWestern State College", "Garden City Community College",
    "Grayson College", "Gulf Coast State College", "Harford Community College",
    "Hutchinson Community College", "Iowa Central Community College",
    "Iowa Western Community College", "Jones College", "Kilgore College",
    "McLennan Community College", "Midland College", "Monroe College",
    "Navarro College", "Northwest Florida State College", "Odessa College",
    "Salt Lake Community College", "Shelton State Community College",
    "South Plains College", "Temple College", "Trinity Valley Community College",
    "Tyler Junior College", "Wabash Valley College",
    "Western Nebraska Community College",
]
PREP_WORDS = {"prep", "preparatory"}

# Step-3 audit verdicts (2026-10-04): low_fuzzy matches whose canonical names a
# DIFFERENT real institution. The failure mode is SequenceMatcher ratio inflation
# on generic suffixes ("... community college", "... state") and acceptance of D1/D2
# homographs (Western/Eastern pairs, UNC->UNCW, UAPB->UAB, North Carolina State->
# South Carolina St.). These rows are demoted to manual (blank canonical/ncaa_id/
# category) so tier2a falls back to the string path until a human fills them;
# the list keeps the audit alive across re-runs of this script.
AUDIT_BLANKS = [
    "Western Kentucky", "Dodge City CC", "Morton College", "Miles CC",
    "Bishop State CC", "Augustana", "Barton CC", "North Carolina A&T",
    "Georgia Southwestern", "Hinds CC", "Oakton College", "Allen CC",
    "Charleston", "Barton Community College", "East Central CC",
    "Lane CC", "Mesa CC", "Otero Junior College", "College of Southern Nevada",
    "Eastern Connecticut State", "Hinds Community College", "Iowa Lakes CC",
    "Southern Illinois", "Western Washington", "Barton College",
    "Carver College", "Daytona State CC", "LSUE", "Palm Beach State",
    "Seward CC", "Tarleton", "Temple JC", "East Texas A&M",
    "UL-Lafayette", "Centralia CC", "Concordia (NY)", "Concordia (OR)",
    "Garrett County Community College", "Illinois Central CC",
    "Iowa Lakes Community College", "Jackson State CC", "Mesa Community College",
    "Midland CC", "Montreat College", "Northwest Florida", "Otero JC",
    "Raritan Valley CC", "Rend Lake CC", "Rock Valley CC",
    "Seminole State CC", "Southern Connecticut State", "Southwestern CC",
    "Arizona Western CC", "Central Community College",
    "Dodge City Community College", "Dutchess CC", "East Central C.C.",
    "East Georgia College", "Lawson State CC", "Nicholls",
    "Roane State CC", "Snead State CC", "South Carolina-Aiken",
    "Southwestern Illinois", "St. Josephs (PA)", "Weatherford Community College",
    "West Virginia Tech", "Allen Community College", "Broward CC",
    "Broward College", "Central CC", "Clinton College", "Concordia",
    "Concordia (NE)", "East Central Community College", "Fayetteville Tech",
    "Florham", "Gadsden State CC", "Garrett CC", "Harper College",
    "Johnson CC", "Johnston CC", "Kansas City CC", "Lane Community College",
    "Laney", "Laney CC", "Lawson State Community College",
    "Lynn College", "Midland Community College", "Mile City CC",
    "Mile City Community College", "Miles Community College",
    "Moraine Valley CC", "Moraine Valley Community College",
    "Mt. St. Mary's (MD)", "Napa Valley College", "North Carolina State",
    "NW Florida State", "Oxnard CC", "Queens (ECC)", "Roosevelt HS",
    "SE Missouri St.", "SE Oklahoma St.", "Seward Community College",
    "Skyline JC", "South Carolina Aiken", "South Carolina Upstate",
    "Southwestern", "Southwestern Michigan", "Southwestern State",
    "UTA", "UAPB", "Victor Valley CC", "Vol State CC",
    "Vol State Community College", "West Virginia/Penn State",
    "Western Texas Community College", "WV Wesleyan",
]
assert len(AUDIT_BLANKS) == len(set(AUDIT_BLANKS)), "duplicate audit keys"


def norm(s):
    s = re.sub(r"[.'’`-]", " ", (s or "").lower())
    return re.sub(r"\s+", " ", s).strip()


def expand(s):
    return " ".join(ABBREV.get(t, t) for t in norm(s).split())


def load_teams():
    with open("teams.csv", encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
    by_id = {r["ncaa_id"]: r["team"] for r in rows}
    lookups = {}                      # expanded-normalized key -> ncaa_id
    for r in rows:
        e = expand(r["team"])
        for key in {e, norm(r["team"])}:
            if key:
                lookups.setdefault(key, r["ncaa_id"])
    return by_id, lookups


def lookup_strings():
    """Distinct previous-school strings with their mention counts."""
    seen = Counter()
    for path in sorted(glob.glob("wbb_rosters_20*.csv")):
        with open(path, encoding="utf-8", newline="") as f:
            for r in csv.DictReader(f):
                raw = (r.get("previous_school") or "").strip()
                clean = (r.get("previous_school_clean") or "").strip()
                v = raw if raw else clean
                if v:
                    seen[v] += 1
    return seen


def best_fuzzy(e, targets):
    """(target_key, ratio) of the closest target to the expanded string."""
    best, best_r = None, 0.0
    for key in targets:
        r = SequenceMatcher(None, e, key).ratio()
        if r > best_r:
            best, best_r = key, r
    return best, best_r


def main():
    by_id, team_lookups = load_teams()
    juco_lookups = {expand(n): n for n in JUCO_NAMES}
    juco_alt = {norm(n): n for n in JUCO_NAMES}

    values = lookup_strings()
    counts = Counter()
    out = {}   # lookup string -> (canonical, ncaa_id, category, confidence)
    for v in sorted(values, key=lambda k: (-values[k], k.lower())):
        e = expand(v)
        ncaa_id = team_lookups.get(e)
        if ncaa_id:
            out[v] = (by_id[ncaa_id], ncaa_id, "roster_team", "high_auto")
            counts["high_auto"] += 1
            continue
        juco = juco_lookups.get(e) or juco_alt.get(norm(v))
        if juco:
            out[v] = (juco, "", "juco", "high_auto")
            counts["high_auto"] += 1
            continue
        if PREP_WORDS & set(norm(v).split()):
            out[v] = (v.title(), "", "prep", "high_auto")
            counts["high_auto"] += 1
            continue
        key, r = best_fuzzy(e, team_lookups)
        juco_key, jr = best_fuzzy(e, juco_lookups)
        if jr > r:
            key, r = juco_key, jr
        if r >= 0.85 and key is not None:
            if key in juco_lookups:
                out[v] = (juco_lookups[key], "", "juco", "low_fuzzy")
            else:
                nid = team_lookups[key]
                out[v] = (by_id[nid], nid, "roster_team", "low_fuzzy")
            counts["low_fuzzy"] += 1
        else:
            out[v] = ("", "", "", "manual")
            counts["manual"] += 1
        if v in AUDIT_BLANKS and out[v][3] == "low_fuzzy":
            out[v] = ("", "", "", "manual")
            counts["manual"] += 1
            counts["low_fuzzy"] -= 1

    rows_out = []
    for v in sorted(values, key=lambda k: (-values[k], k.lower())):
        rows_out.append([v, *out[v]])

    # Invariants before declaring success. (ncaa_id present implies canonical
    # non-empty; juco/prep rows carry canonical without an ncaa_id.)
    assert len({r[0] for r in rows_out}) == len(rows_out), "duplicate keys"
    assert all(not r[2] or r[1] for r in rows_out), "ncaa_id implies canonical"
    assert all(r[3] == "roster_team" for r in rows_out if r[2]), \
        "ncaa_id present implies roster_team"

    with open("data/previous_school_mapping.csv", "w",
              encoding="utf-8", newline="") as f:
        w = csv.writer(f)
        w.writerow(["previous_school", "canonical", "ncaa_id", "category",
                    "confidence"])
        w.writerows(rows_out)

    print("Wrote data/previous_school_mapping.csv (%d rows):" % len(rows_out))
    for k in ("high_auto", "low_fuzzy", "manual"):
        print("  %s: %d" % (k, counts[k]))


if __name__ == "__main__":
    main()