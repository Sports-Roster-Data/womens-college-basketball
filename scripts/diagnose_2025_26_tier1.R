# scripts/diagnose_2025_26_tier1.R -- classify why 2025-26 same-team, same-name
# candidates failed tier 1.
#
# Grounded symptom (from the committed funnel in wbb_player_seasons.csv):
#   2024-25: tier1 8,165 / tier2 1,111 / new 4,446   (933 schools)
#   2025-26: tier1 6,376 / tier2 1,546 / new 7,942   (1,074 schools)
# while the 2024-25 -> 2025-26 window only linked 6,332 stays against
# 8,107-8,480 in every other window. So the damage is in STAYS.
#
# DIAGNOSIS (from running this script + the vintage checks below):
# The matcher is NOT at fault -- rerunning the same tier-1 join/screens against
# the cumulative player table rebuilt with 2025-26 withheld reproduces the
# committed 6,376 exactly, and the year/height screens reject only 14 rows
# (9 rank_JUMPED, 2 rank_DROPPED, 3 height) plus 77 ambiguous rows. The
# shortfall is in candidate GENERATION: 6,411 of 15,864 season-6 rows have
# >= 1 same-name + same-team table candidate (9,453 = 59.6% have none, vs
# 39.9% in the 2023-24 -> 2024-25 control window); 6,467 is the candidate-
# pair count (rows x their candidates), not a row count.
#
# Root cause: baseline-vintage mismatch at the (name, team) key level.
# `wbb_rosters_2024_25.csv` in this repo was cleaned 2025-10-01 from the
# upstream (github.com/dwillis/wbb-rosters) rosters_2024-25.csv as it stood
# after the Dec 2024 "removed players no longer on rosters" maintenance
# (f97fc88): 13,730 rows / 13,722 distinct (team, name) keys over 933 schools
# -- verbatim, 0 key differences. The December 2025 rebuild of `wbb_rosters_2025_26.csv` was
# cleaned from the upstream's re-scraped 2025-26 rosters (Nov 27 2025
# "updated rosters" 298d3a5 through Dec 14 2025 "updated" b22f2e5): 15,894
# rows over 1,074 schools, with (name, team) keys IDENTICAL across our Nov 29
# and Dec 13 versions (0 nov-only / 0 dec-only), i.e. the December polish did
# not change names/teams. Meanwhile the upstream OVERHauled its 2024-25 file
# too ("fixes" feecac5 2025-11-28, "better 2024-25 rosters" fec3f38
# 2025-12-15): keys 13,793 -> 15,799 over ~1,076 schools. Substituting that
# December-15 2024-25 vintage as the baseline moves exact 2024-25 -> 2025-26
# stay pairs from 6,365 to 8,239 (net +1,874 at the (team, name) key level;
# 1,918 keys are newly covered -- 1,192 at newly covered schools and 726 at
# schools already covered -- less ~45 keys the new vintage drops), matching
# the historical 8,107-8,480 range. The 2025-26 file is a
# faithful clean of its vintage (0 raw-vs-cleaned key differences), so the
# fix is to refresh the 2024-25 (and earlier) baseline rosters from the
# upstream's current raw files -- not changes to tiers/screens/parse tables.
#
# No parsing damage in the December rebuild beyond that: names are comma-free,
# order-stable, and never empty in any season; the raw `year` token
# convention DID shift to abbreviations in 2025-26 ("Fr." 2,750 / "Jr." 2,530
# / "So." 2,398 / "Sr." 2,020 / "Fy." 322 vs full words in 2024-25) but
# year_clean maps all of it (0 year_clean NA in 2025-26).
#
# Secondary, pre-existing issues this run surfaced (small, not the collapse):
# - MCLA's source pages write heights as x'-y" ("5'-11"), which the height
#   parser splits at the hyphen and turns NEGATIVE (5 ft -11 in -> 49 total
#   inches; "5'-2"" -> 58). 10 such 2025-26 rows; 2 of them (Hailey Peabody,
#   Ashlyn Bill) failed the tier-1 height screen against their correct 71-inch
#   priors. The 14 screen failures below are almost all of this kind plus a
#   few schools whose class-year strings contradict their own history
#   (Freshman -> Senior with elapsed=1). cleaning.Rmd's current "58-90 inches
#   -> NA" guard would contain these; consider fixing the ft/in split too.
# - 77 ambiguous rows trace to DUPLICATE same-name same-team wbb_ids minted in
#   seasons 1-5 (e.g. four ids at one Fresno Pacific name whose last
#   appearances there span seasons 2-5; one of them, wbb-001081, minted
#   season 1 at Cal State Bakersfield, arrived at Fresno Pacific in season 3
#   via a successful tier-2 transfer claim -- doubling the name there
#   alongside wbb-012636 and making seasons 4-6 ambiguous); tier1 requires a
#   unique candidate at (name_norm, ncaa_id), so any such name can never
#   re-link once doubled. Small now (<80 rows), but the mechanism compounds.
#
# To reproduce the upstream vintage checks: clone
# github.com/dwillis/wbb-rosters and point WBB_RAW_REPO at it (defaults to
# /tmp/wbb-rosters-raw); the section is skipped if it is not present.
#
# Run with (from the repo root):
#   LC_ALL=en_US.UTF-8 Rscript scripts/diagnose_2025_26_tier1.R
# Pair-level detail goes to /tmp/diag_2025_26_tier1_pairs.csv (not committed).
# Diagnosis ONLY: this reads season CSVs and writes to /tmp; it never
# modifies pipeline files or matcher behavior.

source("scripts/player_id_functions.R")

all_rows <- load_all_seasons()
dedup <- resolve_within_season_dupes(all_rows)
all_rows_d <- dedup$rows

# Tier 1 for 2025-26 runs against the cumulative player table as it stood after
# 2024-25, so rebuild it with the last season withheld.
pt <- build_player_ids(all_rows_d %>% filter(season_order <= 5))$player_table

# The real pipeline feeds only duplicate representatives into tier 1
# (build_player_ids filters is_dup_representative before matching; duplicate
# rows inherit their representative's wbb_id later), so restrict the
# 2025-26 slice the same way to reproduce tier 1's actual universe.
season_rows <- all_rows_d %>% filter(season_order == 6, is_dup_representative)

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
cat("season 6 rows entering tier 1:", nrow(season_rows),
    "of", nrow(all_rows_d %>% filter(season_order == 6)), "loaded\n")

# One failure attribution feeds BOTH outputs (this count funnel and the pairs
# CSV below), so a future run can never print disagreeing buckets: attribute
# off the real screens -- if the year screen would accept the pair, only the
# height screen can have failed; an NA rank always passes the year screen, so
# it too can only fail on height. This run's labels are unchanged:
# 9 rank_JUMPED, 2 rank_DROPPED, 3 height_or_other.
cand <- cand %>%
  mutate(fail_why = case_when(
    year_progression_ok(year_rank.prev, last_season_order, redshirt_num.prev,
                        year_rank, season_order, redshirt_num) ~ "height_or_other",
    year_rank < year_rank.prev ~ "rank_DROPPED",
    year_rank == year_rank.prev ~ "rank_STALLED_or_other",
    TRUE ~ "rank_JUMPED"),
    why = case_when(
      n_cand > 1 ~ "ambiguous_multiple_candidates",
      screen_ok ~ "tier1_should_have_matched",
      fail_why == "height_or_other" ~ "failed_height_or_other",
      TRUE ~ paste0("failed_year:", fail_why)))
cand %>% count(why) %>% print()

# Fidelity check: single-candidate + screen-passing rows are exactly what
# tier 1 matched in the committed run (the duplicate-wbb_id-claim guard in
# build_player_ids demotes only tier-2 claims this season: 1 row in the queue).
repro_tier1 <- cand %>% filter(n_cand == 1, screen_ok)
cat("\ntier1 reproduction: single-candidate screen-passing rows =",
    nrow(repro_tier1), "(committed 2025-26 tier1 = 6,376)\n")
# Hard fidelity guard: this diagnostic must reproduce the committed pipeline's
# 2025-26 tier1 count exactly, or its conclusions are about a different
# universe than the one that produced the funnel. Do not weaken or bypass.
stopifnot("tier1 reproduction mismatch: diagnostic != committed pipeline tier1" =
            nrow(repro_tier1) == 6376L)

fail_pairs <- cand %>% filter(n_cand == 1, !screen_ok) %>%
  transmute(row_id, season, team, name,
            prior_wbb_id = wbb_id, prev_team = last_team,
            prev_year_rank = year_rank.prev, prev_rs = redshirt_num.prev,
            prev_inches = total_inches_num.prev,
            curr_raw_year = year, curr_year = year_clean,
            curr_year_rank = year_rank, curr_rs = redshirt_num,
            curr_inches = total_inches_num,
            elapsed = season_order - last_season_order,
            why_class = fail_why)
# (the cumulative player table carries year_rank, not year_clean, so the
# prior side is shown as its 1-6 rank; arrival side keeps the raw values)
write_csv(fail_pairs, "/tmp/diag_2025_26_tier1_pairs.csv")
cat("\nWrote", nrow(fail_pairs), "failed pairs to /tmp/diag_2025_26_tier1_pairs.csv\n")
set.seed(1)
print(fail_pairs %>% slice_sample(n = 25))

# If ambiguous_multiple_candidates shows up, trace: each candidate is a
# distinct wbb_id carrying the same name_norm + ncaa_id pair. Print the full
# per-row detail (candidate ids @ the season each last played, so the header's
# Fresno Pacific example is reproducible from this run) plus the usual
# multiplicity histogram. (Not dominant here: 77 rows.)
amb <- cand %>% filter(n_cand > 1)
if (nrow(amb) > 0) {
  amb_sum <- amb %>%
    arrange(wbb_id) %>%          # candidate rows per arrival keep id order
    group_by(row_id) %>%
    summarise(team = first(team), name = first(name),
              n_cand = first(n_cand),
              candidates = paste(sprintf("%s@S%d", wbb_id, last_season_order),
                                 collapse = ","),
              last_span = paste(range(last_season_order), collapse = "-"),
              .groups = "drop")
  cat("\nAmbiguous rows: each has multiple same-name same-team table\n",
      "candidates (ids @ last_S; multiple ids at one name+team = cascading\n",
      "duplicates minted earlier). Detail:\n")
  print(amb_sum)
  cat("\nmultiplicity:\n")
  print(amb_sum %>% count(n_cand, name = "n_rows"))
}

# Context: class-year distribution per season. A systematic shift in the
# 2025-26 column points at the source/parse level (December rebuild).
cat("\nyear_clean distribution per season:\n")
print(all_rows_d %>% count(season, year_clean) %>%
  pivot_wider(names_from = season, values_from = n, values_fill = 0))

# Same view on the raw scraped `year` strings for the seasons on either side
# of the collapse -- catches a convention change that year_clean can hide.
cat("\nRAW `year` string distribution, 2024-25 vs 2025-26:\n")
print(all_rows_d %>% filter(season %in% c("2024-25", "2025-26")) %>%
  count(season, year) %>%
  pivot_wider(names_from = season, values_from = n, values_fill = 0) %>%
  arrange(desc(`2025-26`)))

# Class-year tokens of the failed rows themselves, next to the 2024-25 column.
cat("\nyear_clean among failed pairs, vs 2024-25 whole season:\n")
print(bind_rows(
  all_rows_d %>% filter(season_order == 5, is_dup_representative) %>%
    count(source = "2024-25 all", year_clean),
  # rename to a shared column: otherwise bind_rows manufactures an all-NA
  # curr_year column next to a real year_clean column
  fail_pairs %>% count(source = "2025-26 failed", year_clean = curr_year)
) %>%
  pivot_wider(names_from = source, values_from = n, values_fill = 0))

# ---------------------------------------------------------------------------
# Control window: run the identical candidate computation for 2024-25 against
# the table built from seasons 1-4, so the no-candidate rate has a baseline.
control_pt <- build_player_ids(all_rows_d %>% filter(season_order <= 4))$player_table
season5 <- all_rows_d %>% filter(season_order == 5, is_dup_representative)
cand5 <- season5 %>%
  inner_join(control_pt %>% select(name_norm, ncaa_id), by = c("name_norm", "ncaa_id")) %>%
  distinct(row_id)
cat(sprintf("\nCONTROL 2024-25: rows %d, no_cand %d (%.1f%%) | 2025-26: no_cand %.1f%%\n",
            nrow(season5), nrow(season5) - nrow(cand5),
            100 * (nrow(season5) - nrow(cand5)) / nrow(season5),
            100 * nrow(no_cand) / nrow(season_rows)))
nc_ex <- no_cand %>% filter(ncaa_id %in% (all_rows_d %>% filter(season_order == 5) %>%
                                            distinct(ncaa_id) %>% pull(ncaa_id)))
cat("\n2025-26 no_cand rows split by school coverage:\n")
print(no_cand %>%
        mutate(new_school_2025_26 = !ncaa_id %in%
                 (all_rows_d %>% filter(season_order == 5) %>% distinct(ncaa_id) %>% pull(ncaa_id))) %>%
        count(new_school_2025_26))
cat("year_clean among 2025-26 no_cand rows at schools covered in 2024-25:\n")
print(nc_ex %>% count(year_clean, sort = TRUE))

# ---------------------------------------------------------------------------
# File-level same-name same-team stay keys for every window (cleaned CSVs only)
cat("\nexact (name_norm, ncaa_id) stay keys per window:\n")
stay_keys_per_window <- map_dfr(1:5, function(k) {
  a <- all_rows_d %>% filter(season_order == k, is_dup_representative) %>% distinct(ncaa_id, name_norm)
  b <- all_rows_d %>% filter(season_order == k + 1, is_dup_representative) %>% distinct(ncaa_id, name_norm)
  tibble(window = paste0(names(SEASON_FILES)[k], " -> ", names(SEASON_FILES)[k + 1]),
         rows_prev = nrow(a), rows_curr = nrow(b),
         stay_keys = nrow(inner_join(a, b, by = c("ncaa_id", "name_norm"))))
})
print(stay_keys_per_window)

# ---------------------------------------------------------------------------
# Optional upstream-vintage check (skipped without a clone of
# github.com/dwillis/wbb-rosters at $WBB_RAW_REPO): the 2024-25-side key
# universe is replaced with the upstream's own vintage of that season and
# exact 2024-25 -> 2025-26 stays are recounted at (team, name).

# readr records parse problems on the returned tibble and silently drops the
# broken rows unless problems() is consulted. The raw upstream files carry a
# documented quoting landmine (an unescaped 5'10"" that swallows the next
# row -- see DATA_QUALITY_ISSUES.md), so surface them rather than quietly
# biasing these exact-key counts.
report_problems <- function(x, label) {
  pr <- problems(x)
  if (!is.null(pr) && nrow(pr) > 0) {
    cat(sprintf("  !! %s: %d parse problems (first: row %d, col %s, expected %s)\n",
                label, nrow(pr), pr$row[1], pr$col[1], pr$expected[1]))
  }
}

raw_repo <- Sys.getenv("WBB_RAW_REPO", unset = "/tmp/wbb-rosters-raw")
if (dir.exists(raw_repo) && file.exists(file.path(raw_repo, "rosters_2025-26.csv"))) {
  k26_raw <- read_csv(file.path(raw_repo, "rosters_2025-26.csv"), show_col_types = FALSE,
                      col_types = cols(.default = "c"))
  # report_problems() MUST see the raw read_csv() frame: mutate() strips
  # readr's problems attribute, so consulting problems() after any dplyr
  # step reports nothing even when rows were dropped.
  report_problems(k26_raw, "rosters_2025-26.csv [current]")
  k26 <- k26_raw %>% mutate(nn = normalize_name(name))
  ours5k <- all_rows_d %>% filter(season_order == 5, is_dup_representative) %>%
    distinct(ncaa_id, name_norm) %>% rename(team_id = ncaa_id, nn = name_norm)
  vintages <- list(pre_removal_dec2024 = "f778739", removed_dec2024 = "f97fc88",
                   nov28_2025 = "feecac5", dec15_2025 = "fec3f38")
  cat("\nUPSTREAM VINTAGE CHECK (rosters_2025-26.csv [current] vs rosters_2024-25.csv\n",
      "vintages: exact stays at (team, name), with the our-s5 baseline overlap):\n")
  vres <- list()
  for (nm in names(vintages)) {
    f <- sprintf("/tmp/diag_show_%s_2024_25.csv", nm)
    # The `status != 0` check must come BEFORE `!file.exists(f)`: the shell
    # `>` redirect pre-creates the output file even when `git show` fails, so
    # testing file existence alone would treat a failed extraction as a real
    # vintage.
    status <- system(sprintf("cd %s && git show %s:rosters_2024-25.csv > %s",
                             shQuote(raw_repo), vintages[[nm]], f))
    if (status != 0 || !file.exists(f)) next
    d25_raw <- read_csv(f, show_col_types = FALSE, col_types = cols(.default = "c"))
    report_problems(d25_raw, sprintf("%s %s", vintages[[nm]], nm))
    d25 <- d25_raw %>% mutate(nn = normalize_name(name))
    k25 <- if ("team_id" %in% names(d25)) d25 %>% distinct(team_id, nn)
           else d25 %>% distinct(team_id = ncaa_id, nn)
    stay <- inner_join(k25, k26 %>% distinct(team_id, nn), by = c("team_id", "nn"),
                       relationship = "many-to-many")
    ours_in <- nrow(inner_join(ours5k, k25, by = c("team_id", "nn")))
    vres[[nm]] <- list(rows = nrow(d25), keys = nrow(k25),
                       our_only = nrow(ours5k) - ours_in, stays = nrow(stay))
    cat(sprintf("  %-20s rows %d | keys %d | our-s5 keys present %d (our-only %d) | stays %d\n",
                nm, nrow(d25), nrow(k25), ours_in, nrow(ours5k) - ours_in, nrow(stay)))
  }
  base <- vres[["removed_dec2024"]]
  # Only echo the "verbatim" recap when the baseline vintage actually
  # materialized with the shape the header asserts; otherwise fall back to a
  # "verified on" statement so a failed clone/checkout can't silently
  # impersonate a reproduction.
  if (!is.null(base) && base$keys == 13722L && base$our_only == 0L) {
    cat("\n  Our cleaned wbb_rosters_2024_25.csv reproduces the removed_dec2024\n",
        "  vintage verbatim (13,730 rows / 13,722 distinct (team, name) keys,\n",
        "  our-only = 0)")
    if (!is.null(vres[["dec15_2025"]])) {
      cat(sprintf(paste0(", and the dec15 'better 2024-25 rosters' baseline\n",
                         "  restores stays to %d -- back in the historical\n",
                         "  8,107-8,480 range.\n"),
                  vres[["dec15_2025"]]$stays))
    } else {
      cat(".\n")
    }
  } else {
    cat("\n  Could not materialize the removed_dec2024 vintage with the expected\n",
        "  shape -- header numbers were verified on 2026-10-04.\n")
  }
} else {
  cat("\nUPSTREAM VINTAGE CHECK skipped: clone github.com/dwillis/wbb-rosters\n",
      "and run again with WBB_RAW_REPO=/path to reproduce (numbers in this\n",
      "script's header).\n")
}