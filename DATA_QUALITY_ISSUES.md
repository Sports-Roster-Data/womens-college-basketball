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
`scripts/repair_2024_25_vintage.R`) found, over 12,434 comparable shared
same-player stay rows:

- 3,449 class cells changed from the pre-refresh vintage, with **zero +1
  deltas** -- only +2/+3 jumps (a same-season progression is impossible).
- 1,251 real 2024-25 rows (mostly schools that have closed) were dropped.
- 891 NEW-only rows strong-mirrored a player's 2025-26 record backward
  (same school, identical class/height/hometown), e.g. a 2024-25 "Virginia"
  row for a player who was actually at NC State that season.

`scripts/repair_2024_25_vintage.R` applied the owner-approved repair: the
pre-refresh vintage (`f1a5ba0`) is historical truth wherever it has a value;
strong-mirror fabrications were deleted; dropped rows were restored.
Post-repair, the shared-stay class==2025-26 rate fell from 46.8% to 6.9%
(honest-era control ~6.5%).

**Rule: season files older than the live season must only ever be re-knit
against an archived/raw source frozen at that season's vintage.** Re-knitting
a historical season against upstream's current raw will silently import
whichever season the live pages now serve.
