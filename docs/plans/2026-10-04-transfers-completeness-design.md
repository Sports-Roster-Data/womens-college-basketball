# Transfers completeness: recover unlinked moves + standardize previous_school

Date: 2026-10-04. Status: approved (user picked approaches A + B; CSV adjudication workflow stays).

## Problem

The Transfers view says it is "a floor, not a ceiling," and the floor is low. Quantified
against `wbb_rosters_combined.csv` + `wbb_player_seasons.csv` (six seasons, 2020-21 … 2025-26):

- The site shows **4,756 matched moves** across five season windows (646 / 831 / 947 / 1,014 / 1,318).
- **~1,524 same-name cross-team player pairs are unlinked** in the same windows, of which
  ~1,200 pass year *and* height consistency screens (B1 = 1,092, B2 = 317) and 115 have a
  previous school that *does* name the departure team but still failed to link (A).
- These exist because Tier 2 requires an evidence gate: previous_school names the prior
  team, **or** hometown+state match, **or** high school match. A same-name cross-team mover
  with a blank previous school and no hometown/HS match falls through every tier and is
  **silently minted as a new player** — no view ever sees the move.
- `previous_school` is sparse: 10–17% of rows filled per season (12,087 mentions total).
  Light normalization matches only **47% of mentions to a roster team**, and the miss list is
  dominated by junior colleges (Trinity Valley CC, Chipola, Blinn, Southern Idaho) — real
  origins outside the roster universe, not parse errors. It also misses roster teams spelled
  differently: teams.csv uses abbreviations ("Utah St.", "Idaho St.") while previous-school
  strings say "Utah State", so the feeder view paints D1 programs gray.
- The feeder view's `is_team` is a bare `tolower() %in% c(teams$team, w$team)`.
- **2025-26 linkage collapsed**: `match_tier="new"` jumped to 7,942 ids vs ~4,500 in every
  other season, tier1 fell 8,165 → 6,376, while 2025-26's class-year data is *cleaner* than
  the seasons that work. This depresses moves, retention, and turnover for the newest window
  and needs a root-cause pass of its own.
- `wbb_id_review_queue.csv` has **3,386 pending rows** (1,895 `transfer_name_variant`,
  1,210 `same_team_name_variant`, 157 `ambiguous_transfer`), decision column effectively
  empty — an adjudication backlog that already exists.

## Design

### 1. Pipeline — stop silently dropping unlinked transfers (A)

In `scripts/player_id_functions.R`, after tier 2, reusing the pipeline's own
`year_progression_ok()` and `attributes_conflict()` screens (one definition of consistency):

- **New queue block `same_name_unconfirmed_transfer`**: cross-team same-name candidates that
  fail the tier-2 evidence gate but pass year progression AND height (≤3″) AND are one-to-one
  on both sides. Routed to the review queue instead of silently minting a new ID.
  **Never auto-merged** — the repo's fuzzy-tier philosophy; `decision` +
  `player_id_overrides.csv` remain the only merge path.
- **New queue block `corroborated_blocked` with a `reason` column**: candidates that passed
  the evidence gate but failed elsewhere (ambiguous / year fail / height conflict /
  duplicate claim). Some reasons are roster-data errors fixable in the editor (a misparsed
  `year_clean`), after which the re-knit links them without an override.
- Queue columns gain `year_ok`, `height_close`, `reason`. Overrides format unchanged.
- Expected volume: ~1,500 new rows on top of the existing 3,386.
- **Inertness guard**: with zero new overrides, pipeline output stays byte-identical to
  today's; the queue only grows.

Prerequisite: **diagnose the 2025-26 tier1 collapse** first — it distorts window 4 and the
recovery machinery should be validated on healthy windows.

### 2. Previous-school standardization (B)

`data/previous_school_mapping.csv` — same pattern as `data/high_school_mapping.csv` — built
by a new **self-contained** `scripts/build_prev_school_mapping.py` (the HS scripts' missing
`hs_standardization` module dependency is a known landmine; this script must not repeat it).
Stages, each writing a `confidence` value:

1. `high_auto` — normalized-exact match against `teams.csv` names plus a small alias table
   (`St.` ↔ `State`, `U.` ↔ `University`) and roster-name spellings.
2. `low_fuzzy` — Jaro-Winkler-close team matches, auto-applied but flagged for review.
3. `manual` — reserved rows for human filling, like the HS mapping.
4. Category column for the remainder: `juco` / `four_year_other` / `prep` /
   `international` / `other` — seeded from a curated JuCo list. Never a naive "contains CC"
   rule (College of Charleston is a roster team).

`cleaning.Rmd` applies the mapping inline (authoritative, like the HS mapping) and ships two
new columns: `previous_school_canonical` and `previous_school_ncaa_id` (blank when the
previous school is not a roster team). Raw `previous_school_clean` stays for compatibility.

Downstream:

- **Tier 2a upgrades** from normalized-string comparison to the canonical/`ncaa_id` join.
- **Feeders**: `is_team` becomes "canonical maps to an `ncaa_id`"; the four-year/JuCo/prep
  split becomes a real `category` column in the JSON and CSVs; "Utah State" turns blue again.

### 3. Success measures

- Adjudication converts most of `same_name_unconfirmed_transfer` into merges: the
  five-window move total rises from 4,756 toward ~6,000+; per-window capture rate
  ~30% → ~45%.
- `is_team` correctness on listed mentions: 47% → ~90%.
- Invariants preserved: overrides-empty output byte-identical; team-season and totals
  `stopifnot` guards untouched.

## Out of scope (may revisit)

- **C — external portal fill** (transfer-portal datasets joined by name for the blank
  non-freshman pool): the only route that names origins for blank-previous-school movers;
  revisit after A's adjudication shows which blanks still matter.
- **D — honest-bounds site labeling** ("transferred in, origin unlisted"): not needed while
  the focus is recovering real identity links.
- An editor review-queue adjudication mode: **deferred — the CSV workflow stays for now**
  (decision column in `wbb_id_review_queue.csv`, resolved rows copied into
  `player_id_overrides.csv`, re-knit so overrides apply).