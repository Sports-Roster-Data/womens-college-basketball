# Transfers-completeness Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the missed-transfers gap — queue ~1,500 unlinked same-name cross-team pairs for human adjudication instead of silently minting IDs, fix the 2025-26 tier1 collapse, and standardize `previous_school` (canonical name + `ncaa_id` + category) so Tier 2a and the feeder view join exactly.

**Architecture:** A queuing-only change to the tiered matcher (`scripts/player_id_functions.R`) — new review-queue blocks, no assignment changes until overrides exist. A self-contained Python builder writes `data/previous_school_mapping.csv`; the ID pipeline applies it at load time; `build_site_data.R`'s feeder section and `site/js/transfers.js` consume the canonical/category columns.

**Tech Stack:** R (tidyverse, rmarkdown, stringdist) for the ID pipeline; Python stdlib only (`csv`, `re`, `difflib`) for the mapping builder; jsonlite for site data; hand-rolled JS for the site.

**Design doc:** `docs/plans/2026-10-04-transfers-completeness-design.md` (approved: approaches A + B; C portal-fill and D labeling out of scope; CSV adjudication workflow stays — no editor mode this round).

**Plan-level deviations from the design doc (flagged for review):**
- The design says `cleaning.Rmd` applies the previous-school mapping inline. Instead, this plan applies it in `player_id_functions.R` at load time. Why: shipping new columns into the six committed season CSVs would mean re-knitting every season against the live external raw repo (upstream may have drifted since the original scrapes) while unrelated editor-corrections work is uncommitted on this machine. The load layer reaches every downstream output (`players.csv`, `wbb_player_seasons.csv`, `wbb_rosters_combined.csv`) without touching season files; when 2026-27 is onboarded, `cleaning.Rmd` can adopt the mapping natively (that's the separate annual workflow, out of scope here).
- The fuzzy stage uses stdlib `difflib.SequenceMatcher` (ratio ≥ 0.85, flagged `low_fuzzy`) instead of a Jaro-Winkler library, keeping the builder stdlib-only (the HS scripts' missing `hs_standardization` module is a known landmine; this script must not repeat it).

**Grounded baseline numbers (verified 2026-10-04 from committed outputs):**

| season | tier1 | tier2 | new | season rows |
|---|---|---|---|---|
| 2021-22 | 8,450 | 646 | 4,545 | 13,644 |
| 2022-23 | 8,405 | 966 | 4,418 | 13,798 |
| 2023-24 | 8,089 | 1,053 | 4,764 | 13,907 |
| 2024-25 | 8,165 | 1,111 | 4,446 | 13,730 |
| 2025-26 | **6,376** | 1,546 | **7,942** | 15,876 |

Windows (matched pairs / moves / stays, computed from `wbb_player_seasons.csv`):

| window | linked pairs | moves | stays |
|---|---|---|---|
| 2020-21→21-22 … 2023-24→24-25 | 8,959–9,131 | 646–1,014 | 8,117–8,450 |
| 2024-25→2025-26 | **7,650** | 1,318 | **6,332** |

The 2025-26 damage sits in **stays** (same-name, same-team players left unlinked), not in moves — and the season is ~2,100 rows larger than 2024-25, so part of its `new` growth is genuine newcomers.

**Amendment from Task 0 (2026-10-04):** the committed `wbb_id_review_queue.csv` was a stale artifact — a deterministic re-knit of HEAD reproduces the three data CSVs byte-identically but yields 2,609 queue rows vs the stale 3,385 (no `decision` data lost; row ids are load-order-dependent). Task 0's follow-up commit re-syncs it, so the queue baseline for Task 3 is **2,609**, and the parity guard rests on the three CSVs only. Also: knits on this machine need `RSTUDIO_PANDOC=/Applications/RStudio.app/Contents/Resources/app/quarto/bin/tools/aarch64` alongside the UTF-8 locale (no system pandoc). All knit commands below carry it.

---

### Task 0: Baseline checksums

**Files:** none committed. Temporary checksums in `/tmp`.

**Step 1: Record the baseline**

```bash
git status --short
shasum -a 256 players.csv wbb_player_seasons.csv wbb_rosters_combined.csv > /tmp/tr_baseline.sum
cat /tmp/tr_baseline.sum
```

The three CSVs must be clean in `git status` (other files may be dirty from separate
in-flight editor work — leave those alone, don't stage them).

**Step 2: Baseline reproduction run**

```bash
LC_ALL=en_US.UTF-8 RSTUDIO_PANDOC=/Applications/RStudio.app/Contents/Resources/app/quarto/bin/tools/aarch64 \
  Rscript -e "rmarkdown::render('player_ids.Rmd')"
shasum -a 256 -c /tmp/tr_baseline.sum
```

All three must check OK — the committed CSVs are the pipeline's own output. If any
mismatches, STOP and diagnose that before any edit; the task-3 parity guard depends
on this baseline being reproducible.

**Step 3: No commit (nothing changed).**

**Resolution as executed (2026-10-04):** the knit reproduced the three CSVs
byte-identically (checksums OK; funnel and GUID checks clean), but
`git diff` showed `wbb_id_review_queue.csv` drifted: the committed copy is a
stale artifact from an earlier pipeline state (3,385 committed rows → 2,609 on
re-knit; all 30 duplicate-watcher rows identical; zero `decision` cells in
either version). Resolution: committed the freshly regenerated queue plus the
header-only `player_id_overrides.csv` the pipeline expects, as a dedicated
re-sync commit. Queue baseline after the sync: **2,609 rows**.

---

### Task 1: Diagnose the 2025-26 tier1 collapse

**Files:**
- Create: `scripts/diagnose_2025_26_tier1.R` (committed — it records the diagnosis)

**Step 1: Write the diagnostic**

The damage is in stays: same-name, same-team candidates failing tier1, while tier2
rose and 2025-26 class years are clean. Rebuild the exact tier1 universe (cumulative
player table as of the end of 2024-25) and classify every failure.

```r
# scripts/diagnose_2025_26_tier1.R -- classify why 2025-26 same-team, same-name
# candidates failed tier 1. Run with:
#   LC_ALL=en_US.UTF-8 Rscript scripts/diagnose_2025_26_tier1.R
# Pair-level detail goes to /tmp/diag_2025_26_tier1_pairs.csv (not committed).
source("scripts/player_id_functions.R")

all_rows <- load_all_seasons()
dedup <- resolve_within_season_dupes(all_rows)
all_rows_d <- dedup$rows

# Tier 1 for 2025-26 runs against the cumulative player table as it stood after
# 2024-25, so rebuild it with the last season withheld.
pt <- build_player_ids(all_rows_d %>% filter(season_order <= 5))$player_table
season_rows <- all_rows_d %>% filter(season_order == 6)

cand <- season_rows %>%
  inner_join(pt, by = c("name_norm", "ncaa_id"), suffix = c("", ".prev"),
             relationship = "many-to-many") %>%
  group_by(row_id) %>% mutate(n_cand = n()) %>% ungroup()

ok <- pmap_lgl(
  cand %>% select(year_rank, season_order, redshirt_num,
                  year_rank.prev, last_season_order, redshirt_num.prev,
                  total_inches_num, total_inches_num.prev),
  function(year_rank, season_order, redshirt_num, year_rank.prev, last_season_order,
           redshirt_num.prev, total_inches_num, total_inches_num.prev) {
    year_progression_ok(year_rank.prev, last_season_order, redshirt_num.prev,
                        year_rank, season_order, redshirt_num) &&
      !attributes_conflict(total_inches_num.prev, total_inches_num)
  }
)
cand <- cand %>% mutate(screen_ok = unname(ok))

no_cand <- season_rows %>% anti_join(cand, by = "row_id")
cat("\n2025-26 rows with NO same-name same-team table candidate",
    "(arrivals whose prior roster row at that team doesn't exist):",
    nrow(no_cand), "of", nrow(season_rows), "\n")
cat("same-name same-team candidate rows:", nrow(cand), "\n")

cand %>%
  mutate(why = case_when(
    n_cand > 1 ~ "ambiguous_multiple_candidates",
    screen_ok ~ "tier1_should_have_matched",
    !is.na(year_rank.prev) & !is.na(year_rank) & year_rank < year_rank.prev ~
      "failed_year:rank_DROPPED",
    !is.na(year_rank.prev) & !is.na(year_rank) &
      year_rank > year_rank.prev + (season_order - last_season_order) + 1 ~
      "failed_year:rank_JUMPED",
    is.na(year_rank.prev) | is.na(year_rank) ~ "failed_year:rank_NA",
    TRUE ~ "failed_height_or_other"
  )) %>%
  count(why) %>% print()

fail_pairs <- cand %>% filter(n_cand == 1, !screen_ok) %>%
  transmute(team, name, prior_wbb_id = wbb_id, prev_team = last_team,
            prev_year_rank = year_rank.prev, prev_rs = redshirt_num.prev,
            prev_inches = total_inches_num.prev,
            curr_year = year_clean, curr_rs = redshirt_num,
            curr_inches = total_inches_num)
# (the cumulative player table carries year_rank, not year_clean, so the
# prior side is shown as its 1-6 rank; arrival side keeps the raw values)
write_csv(fail_pairs, "/tmp/diag_2025_26_tier1_pairs.csv")
cat("\nWrote", nrow(fail_pairs), "failed pairs to /tmp/diag_2025_26_tier1_pairs.csv\n")
print(fail_pairs %>% slice_sample(n = 25))

# Context: class-year distribution per season. A systematic shift in the
# 2025-26 column points at the source/parse level (December rebuild).
cat("\nyear_clean distribution per season:\n")
print(all_rows_d %>% count(season, year_clean) %>%
  pivot_wider(names_from = season, values_from = n, values_fill = 0))
```

**Step 2: Run it**

```bash
LC_ALL=en_US.UTF-8 Rscript scripts/diagnose_2025_26_tier1.R
```

Read the `why` buckets, the sample pairs, and the distribution table. If failures
cluster as `rank_DROPPED`/`rank_JUMPED` on rows whose raw `year_clean` strings
changed convention (compare the 2025-26 column against 2024-25's), the December
rebuild's parse is at fault. If they cluster as height mismatches or `rank_NA`, it's
the height/year columns instead. If `ambiguous_multiple_candidates` dominates, trace
back: duplicate same-name same-team wbb_ids minted in an EARLIER window.

**Step 3: Record the verdict** (bucket counts + 2–3 example pairs) so Task 2's
commit message carries the evidence. No pipeline code changes in this task.

**Step 4: Commit**

```bash
git add scripts/diagnose_2025_26_tier1.R
git commit -m "Diagnose 2025-26 tier1 collapse (failure buckets + sample pairs)"
```

---

### Task 2: Fix the diagnosed root cause

**RESOLVED BY TASK 1 (2026-10-04, verified at commit 38c5957):** the collapse is a
**baseline-vintage mismatch**, not a parse problem. Our `wbb_rosters_2024_25.csv`
was cleaned 2025-10-01 from upstream's Dec-2024 snapshot (13,730 rows / 13,722
distinct (team,name) keys, 933 schools); upstream has since overhauled that
season's raw file (feecac5 11/28, fec3f38 12/15 "better 2024-25 rosters",
15,799 keys). 9,453/15,864 (59.6%) of 2025-26 rows have no same-name/same-team
candidate because their prior-season row was never covered (39.9% in the
2023-24→2024-25 control). Substituting the Dec-15 vintage lifts exact stay pairs
6,365 → 8,239. Year tokens shifted to abbreviations but map cleanly (0 NA);
screens fail only 14 rows; 77 pair rows across 21 row_ids are pre-existing
ambiguous duplicates (secondary, not the mechanism). So the branch is:

**Branch R — refresh the 2024-25 baseline** (was "not planned"; Task 1's verdict).

**Files:**
- Rebuild: `wbb_rosters_2024_25.csv`, then `wbb_rosters_2025_26.csv` (PREV_FILE
  cascade), then `players.csv`, `wbb_player_seasons.csv`, `wbb_rosters_combined.csv`,
  `wbb_id_review_queue.csv` (full re-knit).
- Do NOT edit `cleaning.Rmd` in place — it carries the user's uncommitted
  in-flight work. Re-knit via a temp copy instead (Step 1).

**Step 1: Re-clean 2024-25 from the current upstream raw**

copy `cleaning.Rmd` (working-tree version, user edits retained) to
`/tmp/cleaning_2024_25.Rmd`, change its `SEASON <- "2026-27"` line to
`SEASON <- "2024-25"`, render it with the repo as knit root so all relative
paths and outputs (incl. `corrections/baseline_2024_25.csv`) land in the repo:

```bash
LC_ALL=en_US.UTF-8 RSTUDIO_PANDOC=/Applications/RStudio.app/Contents/Resources/app/quarto/bin/tools/aarch64 \
  Rscript -e "rmarkdown::render('/tmp/cleaning_2024_25.Rmd', knit_root_dir = getwd())"
```

The knit needs internet (INPUT_URL pulls upstream's current `rosters_2024-25.csv`).
The correction chunk re-applies `corrections/corrections_2024_25.csv` and prints
Applied/Unmatched/Stale counts — **record them** and read the unmatched list:
unmatched = the upstream re-scrape renamed/dropped a row an editor correction
was keyed on. If unmatched > 25 rows, STOP and report to the controller before
committing (data-governance issue: past manual fixes may need re-keying).

**Step 2: Containment-check the rebuilt 2024-25 CSV vs committed**

Key-level comparison `(ncaa_id, team, name, jersey)`:
- Rows grow 13,730 → ~15,7xx (that IS the fix; upstream coverage jump).
- For keys present in BOTH vintages: changed cells should be upstream's own
  fixes (heights, class years, hometowns) plus columns our pipeline derives;
  spot-check a sample. Manual-correction columns on matching keys must still
  hold (corrections re-apply).
- Old-vintage-only keys ≈ 45 upstream dropped — check how many had editor
  corrections attached (they will be lost); report in the commit message.

**Step 3: Cascade — re-clean 2025-26** the same way (`/tmp/cleaning_2025_26.Rmd`,
`SEASON <- "2025-26"`, same render command). Its raw vintage is the Dec-13 file
(already current), so the rebuilt CSV must differ from committed ONLY in
hs-derived columns (`hs_clean`, `backfilled`) for some rows. Any other changed
column or row-count change = STOP and diagnose before proceeding.

**Step 4: Re-knit the ID pipeline**

```bash
LC_ALL=en_US.UTF-8 RSTUDIO_PANDOC=/Applications/RStudio.app/Contents/Resources/app/quarto/bin/tools/aarch64 \
  Rscript -e "rmarkdown::render('player_ids.Rmd')"
```

**Step 5: Verify the funnel recovers**

Expected in the printed validation output (grounded by Task 1):
- 2025-26 `tier1` back to ≈8,000+; `new` falls correspondingly; window 4 linked
  pairs ≈9,000+, stays ≈8,100+; moves ≈1,318 or a bit higher.
- Window 3 (2023-24→2024-25) also grows (the +726 keys at already-covered
  schools + 1,192 at newly covered schools); windows 1–2 byte-identical
  (seasons processed before the refreshed one); GUID precision and recall
  unchanged.
- Re-derive the window table to confirm:

```bash
LC_ALL=en_US.UTF-8 RSTUDIO_PANDOC=/Applications/RStudio.app/Contents/Resources/app/quarto/bin/tools/aarch64 \
  Rscript -e "rmarkdown::render('player_ids.Rmd')"
```

Expected in the printed validation output:
- 2025-26 `tier1` back to ≈8,000+; `new` falls correspondingly; window 4 linked
  pairs ≈9,000+, stays ≈8,100+; moves ≈1,318 or a bit higher; GUID precision and
  recall unchanged.
- Re-derive the window table to confirm (same counts as the grounded baseline):

```bash
python3 - <<'EOF'
import csv, collections
rows = list(csv.DictReader(open('wbb_player_seasons.csv')))
order = ['2020-21','2021-22','2022-23','2023-24','2024-25','2025-26']
oi = {s: i for i, s in enumerate(order)}
per = collections.defaultdict(list)
for r in rows:
    per[r['wbb_id']].append((oi[r['season']], r['ncaa_id']))
for w in range(5):
    pairs = moves = stays = 0
    for k in per.values():
        k.sort()
        for (a, ta), (b, tb) in zip(k, k[1:]):
            if a == w and b == a + 1:
                pairs += 1
                moves += ta != tb
                stays += ta == tb
    print(f"window {w}: pairs={pairs} moves={moves} stays={stays}")
EOF
```

**Step 6: Commit (rebuilt outputs only)**

```bash
git add wbb_rosters_2024_25.csv wbb_rosters_2025_26.csv player_ids.Rmd
git add players.csv wbb_player_seasons.csv wbb_rosters_combined.csv wbb_id_review_queue.csv
git commit -m "Refresh 2024-25 baseline from upstream overhaul; fix 2025-26 tier1 collapse"
```

(Never `git add` the user's in-flight files — README.md, cleaning.Rmd,
wbb_rosters_2026_27.csv, editor/, corrections/, prep.qmd, non_us_*.csv,
.gitignore — or the player_ids.html knit byproduct. `player_ids.Rmd` itself
should only change if the knit writes a `SEASON_FILES`-adjacent edit — otherwise
leave it out and adjust the add list accordingly.)

**Branch C (secondary, 77 pair rows):** the pre-existing ambiguous duplicates
(21 row_ids with 2-4 same-name same-team wbb_ids, e.g. Aaliyah Seuell at Fresno
Pacific: one id minted season 1 at Cal State Bakersfield, linked by a failed
tier-2 claim). Do NOT widen the dedupe. They permanently block tier-1 relinking
for their row_ids; the queue machinery already routes them
(`duplicate_wbb_id_claim`). Record their count in the commit message; fixing
them = editor-corrections work, not this task.

---

### Task 3: Queue unconfirmed transfer candidates (queuing only — byte-parity guard)

**Files:**
- Modify: `scripts/player_id_functions.R` (new function after `mint_ids`, lines
  ~339–351; one wiring block inside `build_player_ids` right after the
  `ambiguous_transfer` review-queue append, line ~383)
- Modify: `player_ids.Rmd` ("How matching works", after the tier-3 paragraph, line ~27)

**Step 1: Append the queuer to `scripts/player_id_functions.R`**

The queuer reads `previous_school_ncaa_id`, which arrives with Task 5. To land this
task before Task 5, pull Task 5's Step-1 additions forward into the same edit (the
four `load_one_season` columns + `ps_map_lookup` + `blank_to_na`) so the file stays
runnable, and note that in the commit message; with no
`data/previous_school_mapping.csv` yet those columns gracefully fall back (NULL map
→ `ncaa_id` NA → string-evidence path only). The parity check below is the gate
either way.

```r
# ---------------------------------------------------------------------------
# Step 3c: queue transfer candidates tier 2 declined (never auto-merged)
# ---------------------------------------------------------------------------

# Same-name candidates on a different team that tier 2 declined, labeled by why:
# consistent year+height but no corroborating evidence at all
# (same_name_unconfirmed_transfer), or corroboration that failed a screen
# (corroborated_blocked -- which screen and what evidence are both columns).
# Queuing only: the candidate keeps its own freshly minted wbb_id; merging
# happens only when a human resolves the review-queue row and copies it into
# player_id_overrides.csv. With an empty overrides file this function changes
# no output except the review queue itself.
queue_transfer_candidates <- function(season_rows, player_table) {
  if (nrow(player_table) == 0 || nrow(season_rows) == 0) return(tibble())

  candidates <- season_rows %>%
    inner_join(player_table, by = "name_norm", suffix = c("", ".prev"),
               relationship = "many-to-many") %>%
    filter(ncaa_id != ncaa_id.prev) %>%
    mutate(
      prev_school_norm = normalize_team(previous_school_clean),
      prev_team_norm = normalize_team(last_team),
      evidence = case_when(
        (!is.na(previous_school_ncaa_id) & !is.na(ncaa_id.prev) &
           previous_school_ncaa_id == ncaa_id.prev) |
          (!is.na(prev_school_norm) & !is.na(prev_team_norm) &
             prev_school_norm == prev_team_norm) ~ "previous_school",
        !is.na(hometown_clean) & !is.na(hometown_clean.prev) &
          hometown_clean == hometown_clean.prev &
          !is.na(state_clean) & !is.na(state_clean.prev) &
          state_clean == state_clean.prev ~ "hometown",
        !is.na(hs_clean) & !is.na(hs_clean.prev) & hs_clean == hs_clean.prev ~ "high_school",
        TRUE ~ "none"
      ),
      height_close = is.na(total_inches_num.prev) | is.na(total_inches_num) |
        abs(total_inches_num - total_inches_num.prev) <= 3
    )
  if (nrow(candidates) == 0) return(tibble())

  ok <- pmap_lgl(
    candidates %>% select(year_rank, season_order, redshirt_num,
                          year_rank.prev, last_season_order, redshirt_num.prev),
    function(year_rank, season_order, redshirt_num, year_rank.prev, last_season_order,
             redshirt_num.prev) {
      year_progression_ok(year_rank.prev, last_season_order, redshirt_num.prev,
                          year_rank, season_order, redshirt_num)
    }
  )
  candidates <- candidates %>% mutate(year_ok = unname(ok))

  queueable <- candidates %>%
    group_by(row_id) %>%
    mutate(n_arrival = n(), n_ok = sum(year_ok & height_close)) %>%   # per pair
    ungroup() %>%
    filter(n_ok == 0) %>%          # rows with a screen-passing candidate are
                                   # tier 2's business (matched or ambiguous)
    group_by(wbb_id) %>% mutate(n_prior = n()) %>% ungroup() %>%
    filter(evidence != "none" |    # corroborated-but-screen-failing always queue
             (year_ok & height_close &   # no-evidence rows: only the consistent,
              n_arrival == 1 & n_prior == 1))  # unambiguous ones are candidates

  queueable %>%
    transmute(
      row_id, season, team, name,
      candidate_wbb_id = wbb_id,
      candidate_name = name_norm.prev,
      candidate_team = last_team,
      block = if_else(evidence == "none",
                      "same_name_unconfirmed_transfer", "corroborated_blocked"),
      reason = case_when(
        evidence == "none" ~ "no_evidence",
        !year_ok ~ "failed_year_progression",
        TRUE ~ "height_conflict"
      ),
      evidence, year_ok, height_close,
      name_dist = NA_real_, hometown_match = NA, hs_match = NA,
      height_match = NA, score = NA_real_
    )
}
```

**Step 2: Wire it into `build_player_ids`** — right after the
`ambiguous_transfer` append and before `matched_this_season` is built:

```r
    step3_queue <- queue_transfer_candidates(step2$remaining, player_table)
    if (nrow(step3_queue) > 0) {
      review_queue[[length(review_queue) + 1]] <- step3_queue
    }
```

**Step 3: Byte-parity check (the inertness guarantee)**

```bash
LC_ALL=en_US.UTF-8 RSTUDIO_PANDOC=/Applications/RStudio.app/Contents/Resources/app/quarto/bin/tools/aarch64 \
  Rscript -e "rmarkdown::render('player_ids.Rmd')"
shasum -a 256 -c /tmp/tr_baseline.sum
```

All three output CSVs must be unchanged. The review-queue file itself is expected
to grow — that's the point. Sanity-check the new queue content:

```python
import csv, collections
q = list(csv.DictReader(open('wbb_id_review_queue.csv')))
c = collections.Counter((r['block'] or '(tier3/dup)') for r in q)
print('queue rows:', len(q))
print(c.most_common())
```

Expected: ≈4,300–4,700 rows total (Task 0's re-sync put the queue baseline at
2,609); `same_name_unconfirmed_transfer` ≈ 1,000–1,500 (the one-to-one share of
the measured B1+B2 pool of 1,409); `corroborated_blocked` smaller (these rows
drop silently in tier 2 today); `decision` blank everywhere.

**Step 4: Update "How matching works" in `player_ids.Rmd`** — insert after the
tier-3 paragraph (line ~27):

> Cross-team same-name pairs with **no** corroborating evidence that still pass the
> same year and height screens are also queued now (`same_name_unconfirmed_transfer`),
> as are corroborated pairs that fail a screen (`corroborated_blocked`, with the
> evidence and the failing screen in their columns). Neither is ever auto-merged.

**Step 5: Commit**

```bash
git add scripts/player_id_functions.R player_ids.Rmd wbb_id_review_queue.csv
git commit -m "Queue unconfirmed cross-team transfer candidates for adjudication"
```

---

### Task 4: Build the previous-school mapping (`data/previous_school_mapping.csv`)

**Files:**
- Create: `scripts/build_prev_school_mapping.py` (self-contained: stdlib only)
- Create: `data/previous_school_mapping.csv` (committed; its `manual` rows are the
  standing surface for human filling, like `data/high_school_mapping.csv`)

**Step 1: Write the builder**

```python
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

    rows_out = []
    for v in sorted(values, key=lambda k: (-values[k], k.lower())):
        rows_out.append([v, *out[v]])

    # Invariants before declaring success.
    assert len({r[0] for r in rows_out}) == len(rows_out), "duplicate keys"
    assert all(r[2] or not r[1] for r in rows_out), "ncaa_id implies canonical"
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
```

(The one intentional deviation from the design doc — `difflib` instead of
Jaro-Winkler — is in the header note above; `ratio ≥ 0.85` ≈ JW distance ≤ 0.1 in
strictness.)

**Step 2: Run and check the stages**

```bash
python3 scripts/build_prev_school_mapping.py
python3 - <<'EOF'
import csv, collections
m = list(csv.DictReader(open('data/previous_school_mapping.csv')))
print('rows:', len(m))
print(collections.Counter(r['confidence'] for r in m))
print(collections.Counter(r['category'] for r in m))
EOF
```

Expected: ~3,000+ rows; `high_auto` covers the roster-team share (the diagnosis's
47%-of-mentions plus abbreviation wins like `Utah State` → `Utah St.`); `low_fuzzy`
small and flagged; `manual` the long tail, most-mentioned first.

**Step 3: Review 10 rows per confidence level before the pipeline touches them**

```bash
python3 - <<'EOF'
import csv
m = list(csv.DictReader(open('data/previous_school_mapping.csv')))
for conf in ('high_auto', 'low_fuzzy', 'manual'):
    print('\n--', conf)
    for r in [r for r in m if r['confidence'] == conf][:10]:
        print(r)
EOF
```

If any `low_fuzzy` row matched unrelated real schools, blank its
`canonical`/`ncaa_id` in `data/previous_school_mapping.csv` and set its
`confidence` to `manual` before continuing (the file is hand-editable — that is
its role).

**Step 4: Commit**

```bash
git add scripts/build_prev_school_mapping.py data/previous_school_mapping.csv
git commit -m "Build previous-school canonical mapping (auto + fuzzy + manual stages)"
```

---

### Task 5: Apply the mapping in the ID layer and upgrade Tier 2a

**Files:**
- Modify: `scripts/player_id_functions.R` — adds `PREV_SCHOOL_MAP_FILE`,
  `load_prev_school_map`, `ps_map_lookup`, `blank_to_na` (after `normalize_team`,
  ~line 68); changes `load_one_season` signature + trailing mutate fields
  (~lines 84–112); changes `load_all_seasons` (~line 115); changes `tier2a` in
  `match_tier2` (~line 254).

**Step 1: Add the loader + helpers after `normalize_team`:**

```r
PREV_SCHOOL_MAP_FILE <- "data/previous_school_mapping.csv"

# Load the previous-school mapping (built by
# scripts/build_prev_school_mapping.py). A missing file is fine: the canonical
# columns still exist downstream and fall back to the cleaned value.
load_prev_school_map <- function() {
  if (!file.exists(PREV_SCHOOL_MAP_FILE)) return(NULL)
  read_csv(PREV_SCHOOL_MAP_FILE, show_col_types = FALSE,
           col_types = cols(.default = "c")) %>%
    arrange(confidence == "manual") %>%   # strongest confidence wins ties
    distinct(previous_school, .keep_all = TRUE)
}

# One field (canonical / ncaa_id / category) of the previous-school mapping
# for a vector of lookup strings; NA where there is no entry.
ps_map_lookup <- function(ps_map, lookup, field) {
  if (is.null(ps_map) || all(is.na(lookup))) {
    return(rep(NA_character_, length(lookup)))
  }
  idx <- match(lookup, str_squish(ps_map$previous_school))
  vals <- str_squish(ps_map[[field]])
  out <- vals[idx]
  out[!is.na(out) & out == ""] <- NA_character_
  out
}

# "" and NA mean the same thing (blank) downstream, but coalesce() doesn't
# treat "" as missing -- normalize keys before joining.
blank_to_na <- function(x) {
  x[is.na(x) | x == ""] <- NA_character_
  x
}
```

**Step 2: Extend `load_one_season`** — signature becomes
`load_one_season <- function(file, season_label, ps_map = NULL) {`; add these four
fields at the end of its existing `mutate` chain (after `total_inches_num`):

```r
      previous_school_lookup =
        coalesce(blank_to_na(previous_school), blank_to_na(previous_school_clean)),
      previous_school_canonical =
        coalesce(ps_map_lookup(ps_map, previous_school_lookup, "canonical"),
                 previous_school_lookup),
      previous_school_ncaa_id =
        ps_map_lookup(ps_map, previous_school_lookup, "ncaa_id"),
      previous_school_category =
        ps_map_lookup(ps_map, previous_school_lookup, "category")
```

(With no mapping file, `canonical` = the lookup string itself and `ncaa_id` /
`category` fall back to NA — the site coalesces those to gray feeders, and Tier 2a
keeps its string path: degraded-but-correct.)

**Step 3: Thread the map through `load_all_seasons`:**

```r
load_all_seasons <- function(season_files = SEASON_FILES,
                             ps_map = load_prev_school_map()) {
  seasons_in_order <- names(season_files)
  all_rows <- imap_dfr(season_files, ~ load_one_season(.x, .y, ps_map = ps_map))
  all_rows %>%
    mutate(
      season_order = match(season, seasons_in_order),
      row_id = paste0("r", row_number())
    )
}
```

**Step 4: Upgrade `tier2a` in `match_tier2`** (exact current lines ~254–255):

```r
      tier2a = (!is.na(previous_school_ncaa_id) & !is.na(ncaa_id.prev) &
                  previous_school_ncaa_id == ncaa_id.prev) |
        (!is.na(prev_school_norm) & !is.na(prev_team_norm) &
           prev_school_norm == prev_team_norm),
```

The string path stays as the fallback for values the mapping hasn't seen.
`player_table` gains no columns (the comparison is arrival-side), so the
`updated_existing`/`new_players` transmutes are untouched.

**Step 5: Re-knit — checksums no longer apply from here on** (widening tier2a
legitimately adds matches). Verify by metrics:

```bash
LC_ALL=en_US.UTF-8 RSTUDIO_PANDOC=/Applications/RStudio.app/Contents/Resources/app/quarto/bin/tools/aarch64 \
  Rscript -e "rmarkdown::render('player_ids.Rmd')"
```

Expected in the printed output:
- GUID precision at its Task-3 value (no new wrong merges); recall may rise.
- Funnel: `tier2` never drops in any season; total moves never decreases; `new`
  falls (the canonical join fires where the string path missed abbreviations).

```bash
head -1 wbb_rosters_combined.csv
```

must show `previous_school_lookup`, `previous_school_canonical`,
`previous_school_ncaa_id`, `previous_school_category` among the columns.

**Step 6: Commit**

```bash
git add scripts/player_id_functions.R players.csv wbb_player_seasons.csv \
        wbb_rosters_combined.csv wbb_id_review_queue.csv
git commit -m "Previous-school canonical columns in the ID layer; tier2a joins on ncaa_id"
```

---

### Task 6: Feeder view on canonical columns

**Files:**
- Modify: `scripts/build_site_data.R` — two spots: the `w` coercion block
  (lines 187–192) and the feeder section (lines 594–609)

**Step 1: Carry the canonical columns into `w`** — NOT via `SHIP_COLS` (they stay
out of the per-season explorer JSON, whose size matters). After the `blank_na()`
for-loop (lines 187–192), add:

```r
# Previous-school canonical columns (applied by player_ids.Rmd): used by the
# feeder section, kept out of SHIP_COLS and the per-season files.
stopifnot("combined lacks the previous-school canonical columns - re-knit player_ids.Rmd" =
            all(c("previous_school_canonical", "previous_school_ncaa_id",
                  "previous_school_category") %in% names(d)))
for (col in c("previous_school_canonical", "previous_school_ncaa_id",
              "previous_school_category")) {
  w[[col]] <- blank_na(d[[col]])
}
```

**Step 2: Replace the feeder section (lines 594–609):**

```r
# Feeders: canonical previous school with >= FEEDER_MIN_PLAYERS distinct
# players. is_team is category-driven: roster_team and four_year_other are
# four-year programs; juco / prep / international / other render gray.
feeder_src <- w[!is.na(w$previous_school_canonical), ]
feeder_f <- factor(feeder_src$previous_school_canonical)
feeder_cat <- tapply(feeder_src$previous_school_category, feeder_f, function(v) {
  tab <- table(v)
  names(tab)[which.max(tab)]
})
feeder_ncaa <- tapply(feeder_src$previous_school_ncaa_id, feeder_f, function(v) {
  u <- unique(na.omit(v))
  if (length(u) > 0) u[[1]] else ""
})
feeders <- data.frame(
  name = levels(feeder_f),
  players = as.integer(tapply(feeder_src$wbb_id, feeder_f,
                              function(v) length(unique(v)))),
  rows = as.integer(table(feeder_f)),
  is_team = unname(feeder_cat) %in% c("roster_team", "four_year_other"),
  category = unname(feeder_cat),
  ncaa_id = unname(feeder_ncaa),
  stringsAsFactors = FALSE
)
stopifnot("four-year feeders must carry an ncaa_id" =
            all(feeders$ncaa_id[feeders$is_team] != ""))
stopifnot("feeder categories are from the known set" =
            all(feeders$category %in% c("roster_team", "four_year_other",
                                        "juco", "prep", "international", "other")))
feeders <- feeders[feeders$players >= FEEDER_MIN_PLAYERS, ]
feeders <- feeders[order(-feeders$players, feeders$name, method = "radix"), ]
rownames(feeders) <- NULL
```

JSON row order is `[name, players, rows, is_team, category, ncaa_id]` — slots 0–3
unchanged for the existing JS; category and ncaa_id are the two new tail slots.

**Step 3: Rebuild and inspect**

```bash
LC_ALL=en_US.UTF-8 Rscript scripts/build_site_data.R
python3 - <<'EOF'
import json, collections
t = json.load(open('site/data/transfers.json'))
f = t['feeders']
print('rows:', len(f))
print(collections.Counter(r[4] for r in f))
print('four-year share:', round(sum(r[3] for r in f) / len(f) * 100), '%')
for r in f[:12]:
    print(r)
EOF
```

Expected: abbreviation victims (`Utah State`, `Idaho State`) appear as one
roster-team canonical entry in teams.csv spelling (blue); real JuCos stay gray;
the four-year share of the listed pool rises sharply from the old string-match
level; `moves_per_pair` unchanged from Task 5's value.

**Step 4: Commit**

```bash
git add scripts/build_site_data.R
git commit -m "Feeder programs resolve canonical previous school, with category"
```

---

### Task 7: Site display for the feeder category

**Files:**
- Modify: `site/js/transfers.js` — feeder card view, tooltip, CSV; find exact
  anchors with
  `grep -n 'feeders\|feederGray\|inconsistently\|is_four_year_program' site/js/transfers.js`

**Step 1: Update the feeder view:**

- Tooltip: the gray-row label currently just says JuCo; show the mapped category
  instead. Find the tooltip's four-year/JuCO wording and use:

```js
  var feedCat = {
    juco: 'Junior college', prep: 'Prep school',
    four_year_other: 'Four-year program (not on our rosters)',
    international: 'International', other: 'Other'
  };
```

  with the tooltip body showing
  `(f[3] ? 'Four-year program' : (feedCat[f[4]] || 'Other'))` where the old code
  chose between the two strings.
- CSV: header gains `category` —
  `['previous_school','distinct_players','roster_mentions','is_four_year_program','category']` —
  and each row appends `f[4] || 'other'`.
- Feeder subtitle (`chartSub`): drop "inconsistently formatted" — the canonical
  mapping now handles that — but KEEP the sparsity warning (about 85% of rows
  don't name a previous school; that's unchanged by this work). Suggested text:

  `The previous schools named most often on these rosters (minimum 5 distinct players), top 25. About 85% of rows simply don't name a previous school at all, so counts are a floor.`

- Header comment item 4 (top of file):
  `4. Feeder programs (top 25; four-year vs JuCo/prep/other via the canonical previous-school mapping)`.

**Step 2: Syntax check**

```bash
node --check site/js/transfers.js
```

**Step 3: Local render check** — serve a copy of `site/` (the harness approach per
repo memory: injected script writes results to `document.title`), open `#/transfers`,
assert the feeder card's legend/tooltip/CSV, and take a screenshot; eyeball that
roster-team feeders render blue and real JuCos stay gray.

**Step 4: Commit and push** (Pages rebuild triggers on push; find the run with
`gh run list --repo Sports-Roster-Data/womens-college-basketball --limit 3` — never
`--commit=`, per repo memory — then `gh run watch --exit-status <run_id>`).

```bash
git add site/js/transfers.js
git commit -m "Transfers: feeder category in tooltip and CSV; sparsity wording"
git push origin main
```

**Step 5: Live check after the run goes green:**

```bash
curl -fsSL https://sports-roster-data.github.io/womens-college-basketball/js/transfers.js | grep -c feedCat
curl -fsSL https://sports-roster-data.github.io/womens-college-basketball/data/transfers.json | python3 -c "
import json, sys
t = json.load(sys.stdin)
print(t['feeders'][:5])"
```

First command prints a count ≥ 1; second shows the new 6-slot rows.

---

### Task 8: Docs + final verification

**Step 1: Update `CLAUDE.md`:** in the directory-notes section
(§3's `data/high_school_mapping.csv` paragraph), document
`data/previous_school_mapping.csv` + `scripts/build_prev_school_mapping.py`
(self-contained; staged high_auto/low_fuzzy/manual; category column) in the same
shape; in the matcher description, list the new review-queue blocks alongside
tier 3.

**Step 2: Full local assertions**

```bash
python3 - <<'EOF'
import json
t = json.load(open('site/data/transfers.json'))
assert all(len(r) == 6 for r in t['feeders']), 'feeder row shape changed'
assert all(t['feeders'][i][1] >= t['feeders'][i + 1][1]
           for i in range(len(t['feeders']) - 1)), 'feeders not sorted'
print('feeders OK:', len(t['feeders']), 'rows; total moves:',
      sum(t['moves_per_pair']))
EOF
```

Also confirm `player_ids.Rmd`'s validation section prints no issues and the GUID
checks' precision/recall.

**Step 3: Commit docs**

```bash
git add CLAUDE.md
git commit -m "Document previous-school mapping and new review-queue blocks"
git push origin main
```

---

### Task 9 (user-driven, after the plan): Adjudicate the queue

Mechanics only — the decisions are yours:

1. Open `wbb_id_review_queue.csv`, filter `block` = `same_name_unconfirmed_transfer`
   (~1,500 rows). `candidate_team` names the prior side's team; the prior side's
   season is the roster season immediately before `season`.
2. For each pair you confirm: append to `player_id_overrides.csv` with the PRIOR
   season's row as side A (`season_a`/`team_a`/`name_a` — the **as-scraped** team
   and name from that season's CSV; `candidate_name` is normalized, so take the
   display name from `wbb_player_seasons.csv` or the season's roster file) and the
   arrival row as side B. `decision` = `same`.
3. Re-knit `player_ids.Rmd` (overrides apply on every knit), re-run
   `scripts/build_site_data.R`, commit rebuilt outputs, push. The five-window move
   total should move from 4,756 toward ~6,000+.
4. `corroborated_blocked` rows: check whether `reason` + `evidence` name a fixable
   data error (a misparsed `year_clean` — fix via the editor/corrections workflow)
   or a genuine mismatch (`decision` = `different`, or leave blank).

---

## As-executed amendments (Tasks 2–7, 2026-10-04)

Task 2's replacement text above (Branch R, the vintage-overlay repair) was
amended inline by the controller at execution time. Later tasks amended
code-vs-plan as follows; each was verified against the data before use, with
fuller detail in the per-task commit messages:

- **Task 3 (queuer):** the plan's transmute referenced `name_norm.prev`, but a
  join keyed on `name_norm` never suffixes the key column — `candidate_name`
  reads plain `name_norm`. And `filter(n_ok == 0)` would have made
  `same_name_unconfirmed_transfer` unreachable (tier 2's pool is
  evidence-only, so no-evidence pass-both pairs are never tier 2's business);
  the executed filter is `n_ok_ev == 0` (evidence-bearing pass-both only).
  Result: 1,200 new queue rows, zero assignment changes.
- **Task 4 (builder):** the asserted invariant is "ncaa_id present implies
  canonical" (`not r[2] or r[1]` — the plan's direction fired on every
  juco/prep row). The Step 3 fuzzy audit blanked 118 wrong ≥0.85 matches
  (difflib inflates on generic suffixes: "... community college",
  "... state"; and accepts D1/D2 homographs), embedded as `AUDIT_BLANKS` so
  re-runs reproduce the audited file.
- **Task 5 (canonical columns in the ID layer + tier2a):** the four
  `previous_school_*` columns land mid-table in `wbb_rosters_combined`
  (after `season_player_id`), not appended at the end — they are union
  extras of some season files under `imap_dfr`. All Step 5 gates passed
  (GUID precision unchanged; tier2 +80, tier1/tier3 unchanged, new down;
  moves +80; players −80; queue 3,944 → 3,842, all decision blank).
- **Task 6 (feeder view):** the plan's `which.max` feeder category assumed
  canonical implies category; the loader coalesces canonical back to the raw
  lookup for unmapped strings, so all-NA groups exist and got category `""`
  (unadjudicated mapping row; the known-set guard accepts `""`).
  `moves_per_pair` was specified "unchanged from Task 5's value": not so —
  4,965 → 5,041 on the site's consecutive-season metric, because Task 5's
  merges connect id chains `is_move` can now see (the feeder edit itself
  cannot affect moves). The four-year share expectation ("rises sharply")
  also over-estimated: the old lowercase-name-match already caught most
  four-year strings, so the share moved 64% → 65%; the actual gains are
  category accuracy and variant consolidation.
- **Task 7 (site display):** executed as written; 11/11 harness assertions
  against independently computed data passed.
- **Re-baselined governance numbers:** Task 9 Step 3's "from 4,756 toward
  ~6,000+" was written before the Task 2 repair round. With the refreshed
  baseline and the +80 merges, the site's consecutive-season move total is
  5,041 with ~1,780 corroborate-able pairs still queued
  (1,972 transfer_name_variant + 1,078 same_name_unconfirmed_transfer);
  adjudication of those pushes it toward the ~6,000+ the plan projected.

## Fix round (review findings, 2026-10-05)

Both review agents returned findings after Tasks 0–8's commits. Each was
verified against actual code/data before acting; every fix root-caused first.
Rebuild numbers below are from the completed re-run chain (repair script →
mapping builder → `player_ids.Rmd` knit → `build_site_data.R`).

- **Repair guards re-scoped to uniquely-matched keys.** First re-run tripped
  "overlaid classes must match the old vintage": the guard joined FULL `O`,
  whose 16 duplicate-keyed rows (8 keys, all Lewis) collide with NEW's
  representation. Diagnosis: three OLD keys self-contradict (e.g. Tara
  Gugliuzza {Junior, Senior}; Lewis scraped two class years for the same
  player); NEW's representation agrees with one copy, the final file
  legitimately carries it, so the guarantee's domain is keys unique in BOTH
  vintages (`O_match`), not `O`. Added a second guard pinning the weaker
  property for duplicate-OLD keys NEW represents: NEW's class must equal at
  least one OLD copy's class.
- **Height trio overlay + global parse invariant.** The first repair
  overlaid only `total_inches`, leaving `height_clean`/`height_ft`/`height_in`
  describing NEW's measurement while inches described OLD's. Now the whole
  trio overlays together, gated on OLD's parsed inches (`o_in` non-NA —
  guarantees the OLD string parses and is self-consistent; an unparseable OLD
  string must not overwrite NEW's: 3 keys, kept NEW by design). New global
  guard: wherever `height_clean` parses, it must agree with `total_inches`
  (0 violations in the rebuilt file; the committed intermediate had 3,050
  affected rows).
- **teams.csv section made a true re-run no-op.** The byte-roundtrip check
  used reader `write_csv` output (LF + trailing newline), but this script's
  own convention is CRLF with no trailing newline — the committed (already
  collapsed) file could never roundtrip. Also the duplicate-key detection now
  precedes the roundtrip check, which runs only on the editing path; a no-op
  run leaves teams.csv untouched and unvalidated-transformed.
- **HOMOGRAPH_BLANKS demotion was dead code — fixed.** First builder re-run
  produced a byte-identical mapping: the demotion checks lived inside the
  assignment loop, but each high_auto branch ends in `continue`, so an exact
  token match (precisely what the FDU homograph is) could never reach them.
  Demotions moved to a post-loop pass; AUDIT_BLANKS keeps its deliberate
  stage gate (fuzzy-only). Result: `Fairleigh Dickinson` keeps its canonical
  string but loses `ncaa_id`/`category` (confidence → manual; ledger now
  716 high_auto / 142 low_fuzzy / 2,986 manual, 3,844 rows), tier2a loses
  canonical-evidence authority for those players
  (combined: exactly 15 rows lose `previous_school_ncaa_id`; `wbb_id` sets
  unchanged), and the feeder row renders gray.
- **Homograph first re-run was byte-identical**: the demotion checks lived
  inside the assignment loop where each high_auto branch `continue`s over
  them — dead code for exactly the rows they target; caught because the file
  diff was empty after the code shipped.
- **Loader squish-before-blank_to_na.** Raw scrapes carry non-breaking-space
  previous_school values (2022-23 La Verne rows whose previous_school is only
  `\xa0`); `str_squish` must precede `blank_to_na` or a junk feeder row
  renders. Loader also now asserts the mapping's squished keys are unique. In
  the rebuilt transfers.json: 0 junk rows.
- **`to_logical` hardening (cleaning.Rmd corrections chunk):** the editor
  serializes checkboxes as "true"/"false"; hand-written "1"/"0" in the log
  would silently become NA under bare `as.logical()`. Accepts both + numeric
  fallback; corrections_2026_27.csv carries zero boolean rows, so prophylactic.
- **check-countries chunk** now prints which teams carry unparsed countries
  (was a bare "N rows" print with no names).
- **Reviewer-accepted-as-documented (no code change):** the queuer's
  evidence-only under-collection (a pair passing tier 1/3 screens with zero
  corroborating evidence is queued, but tier-2-eligible evidence-bearing pairs
  that fail a screen are NOT re-queued — documented); `which.max`/`feeder_ncaa`
  determinism (first-row-wins on ties) — deliberate, single-writer build.
- **Rebuild gate results:** 2024-25 rows 16,168 → 16,170 (+2: Marley Freeman's
  passed-through duplicate and Samantha Campanelli's restored row, each
  gaining a wbb_id; 0 rows removed); `players.csv` count unchanged (40,251);
  per-group `wbb_id` SETS unchanged across all 86,428 (season, team, name)
  groups; review queue 3,842 rows / 3,504 unique pairs, pairs IDENTICAL to
  baseline (only row_id ordering churned); GUID crosswalk precision/recall
  0.9996 / 0.9994; moves total 5,041 unchanged; feeders 504 rows, sort holds
  (moves desc, tie name asc); FDU feeder row now gray.