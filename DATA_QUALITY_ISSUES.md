# Known Corrupted Rows in the Season Roster Files

While building stable cross-season player IDs (see [player_ids.Rmd](player_ids.Rmd)),
a systematic scan of all six `wbb_rosters_*.csv` files turned up a small number
of rows with genuine source corruption -- roughly two dozen out of 84,038 rows
(0.03%). These are pre-existing issues in the scraped source data, not
something introduced by the player-ID pipeline. This document lists them so
they can be fixed at the source.

## Structural corruption (fields actually shifted or lost) -- 5 rows

| File : Line | Player | Team (ncaa_id) | What broke |
|---|---|---|---|
| `wbb_rosters_2020_21.csv:9690` | Kelsey Winfrey | Drury (1057) | `high_school` field is missing entirely, shifting every column from `url` onward one slot left. Her `url`, `season`, `team_state`, `conference`, `year_clean`, etc. all now hold the wrong values. |
| `wbb_rosters_2021_22.csv:12177-12178` | **Kendra Stanford / Jenna Wagoner** | Salem (WV) (19117) | The worst one. Stanford's height field is malformed -- `"5'10""` instead of a properly escaped `"5'10"""` -- which breaks CSV quoting and swallows the *entire next physical line* (Jenna Wagoner's row) into Stanford's record as garbage text. **Jenna Wagoner's row effectively doesn't exist as a separate record** in the parsed data. |
| `wbb_rosters_2021_22.csv:8700` | Maya Dunson | Valparaiso (735) | `player_id` field is empty/missing, shifting `height_clean`, `position`, `jersey`, `url`, etc. one column left. |
| `wbb_rosters_2023_24.csv:7549` | Kassidy Dixon | Sam Houston State (624) | Same pattern as Winfrey -- url/season fields fused, jersey number (`10`) leaked into the `url` column. |
| `wbb_rosters_2025_26.csv:788` | Kayana Armbrister | Bentley (56) | Minor version of the same bug -- a stray leading comma in front of the `url` value, one field short upstream. |

## Cosmetic-only (season label wrong, but no field shift) -- 18 rows

| File : Lines | Rows | Issue |
|---|---|---|
| `wbb_rosters_2021_22.csv:8371-8386` (16 rows) | UT-San Antonio (706) | `season` field literally reads `"2021-2022"` instead of `"2021-22"` -- a typo, but every other field is intact. |
| `wbb_rosters_2023_24.csv:5435` | Teal Howle, Mount Holyoke (449) | `season` field reads `"2023-24,"` -- trailing comma, otherwise fine. |

## Impact on the player-ID pipeline

The [player_ids.Rmd](player_ids.Rmd) loader overrides the `season` column with
the season each file actually represents, so the cosmetic-only rows above
caused no issues. The structural rows still each received a `wbb_id`, just
without reliable matching evidence (name/hometown/height are corrupted for
those specific records). Jenna Wagoner's true 2021-22 season entry is simply
absent from the file -- that's a data gap the player-ID matcher can't recover,
since the row was never parsed as a distinct record.

## Suggested fix

- Patch the 5 structurally corrupted rows by hand in the source CSVs (repair
  the missing/malformed field and re-derive the shifted columns).
- Fix the 18 cosmetic season-label typos with a find-and-replace.
- Look at whatever scraper step produces the `5'10""`-style height string --
  that's the root cause of the worst corruption (the Stanford/Wagoner merge)
  and could resurface in future seasons if not addressed.

## Vintage contamination: never re-knit an old season against current raw

In December 2025 the upstream scrape repo (`dwillis/wbb-rosters`) overhauled
`rosters_2024-25.csv` by re-scraping **live** roster pages instead of the
archived ones it had originally used. The refreshed file is a mixed-vintage
hybrid: about a third of the teams still served archived pages (their files
were honest), but for the rest each "2024-25" row actually carries a later
season's content. The 2026-10-04 quantification (see
`scripts/repair_2024_25_vintage.R`) found, over 12,463 comparable shared
same-player stay rows (12,438 same-label, 25 school label-drift):

- 3,449 class cells changed from the pre-refresh vintage, with **zero +1
  deltas** -- only +2/+3 jumps (a same-season progression is impossible).
- 1,252 real 2024-25 rows (mostly schools that have closed) were dropped.
- 892 NEW-only rows strong-mirrored a player's 2025-26 record backward
  (same school, identical class/height/hometown), e.g. a 2024-25 "Virginia"
  row for a player who was actually at NC State that season.

`scripts/repair_2024_25_vintage.R` applied the owner-approved repair: the
pre-refresh vintage (`f1a5ba0`) is historical truth wherever it has a value;
strong-mirror fabrications were deleted (892); dropped rows were restored
(1,252, including one duplicate pair collapsed to its single distinct copy);
the repaired `wbb_rosters_2024_25.csv` carries 16,170 rows, with `height_clean`
agreeing with `total_inches` on every parseable row. Post-repair, the
shared-stay class==2025-26 rate fell from 46.8% to 6.9% (honest-era control
~6.5%).

**Rule: season files older than the live season must only ever be re-knit
against an archived/raw source frozen at that season's vintage.** Re-knitting
a historical season against upstream's current raw will silently import
whichever season the live pages now serve.

Bounds (within-file duplicate-key rows, unattributable one-to-one and never
cross-matched by the repair):

- NEW's own duplicate-keyed rows pass through on NEW's values. One such row
  (Marley Freeman, 2024-25 LeMoyne-Owen, no jersey) matches neither its own
  2025-26 twin (jersey 11, 5'8") nor the refreshed row (5'8") and was left
  standing; its twin-matching neighbor was deleted as a mirror.
- OLD's duplicate-keyed rows restore when NEW does not represent the key
  (Samantha Campanelli, Lewis: two identical rows restored to one).
- Three OLD duplicate keys self-contradict (Lewis scraped two class years for
  the same player -- e.g. Tara Gugliuzza {Junior, Senior}); where NEW carries
  the key, NEW's representation survives. A guard pins that NEW's class always
  agreed with at least one OLD copy in these cases.

Cascade note: 2025-26's final knit (`b2a69d2`) ran before the 2024-25 repair
existed, so its high-school backfill (which reads the previous season's
output) could see only the pre-repair 2024-25 vintage. About 3 of its 1,371
missing-high-school rows would backfill from the restored rows. It is **not**
re-knitted here -- a re-knit would also bake the working tree's uncommitted
corrections and the current live upstream into the commit. If you choose to
re-knit: set `SEASON` to 2025-26 in `cleaning.Rmd`, re-knit it, then re-knit
`player_ids.Rmd` and commit both.

## Stale-copy team-seasons: a past season scraped from the current page

Found 2026-11-01 while checking a duplicate-ID report from Her Hoop Stats.
For 170 team-seasons (115 teams, mostly D-II/D-III, 13 D-I) the raw scrape
saved a different season's roster under the season label: the same roster
URLs, names and class years, row for row. Sidearm's season-specific roster
URLs (`/roster/2020-21`) now serve the current roster, which is the likely
cause. Example: IUPUI's 2020-21 rows are its 2022-23 roster, and its 2021-22
rows are its 2023-24 roster. Katie Davidson appears there in 2021-22 even
though she was at Miami (OH) that season.

The copies broke cross-season IDs: class years ran backwards, so tier 1 could
not link the real seasons. They also placed players on teams they never
played for. 2020-21 and 2021-22 copying 2022-23 account for most of them.

`scripts/find_stale_rosters.py` flags them. Two seasons of one team are
flagged when at least 5 URLs are shared, they cover 90% or more of the
smaller roster, and every shared row has the same name and class year. The
season kept is the one whose class years line up with the team's nearest
unflagged seasons. The others are written to
`data/stale_roster_exclusions.csv` (scope `team_season`, plus curated
single-row duplicates, scope `row`).

`scripts/strip_stale_rows.py` removed those 2,482 rows from the published
season CSVs (byte-identical otherwise). `load_all_seasons()` and
`cleaning.Rmd` also drop them, and `cleaning.Rmd`'s `check-stale-roster`
chunk flags a new season that copies `PREV_FILE`.

Not caught: sites that reuse the same URLs and edit the class years in place
(Hunter 2022-23 vs 2023-24). The real rosters for the dropped team-seasons
still need a re-scrape upstream. When one lands, remove its exclusion rows.
