# Functions for building stable cross-season player IDs (wbb_id) that
# identify the same person across the women's college basketball roster
# seasons regardless of team or year. See player_ids.Rmd for the build
# script that calls these functions and writes the output files.

suppressPackageStartupMessages({
  library(dplyr)
  library(tidyr)
  library(readr)
  library(stringr)
  library(stringi)
  library(purrr)
  library(stringdist)
})

SEASON_FILES <- c(
  "2020-21" = "wbb_rosters_2020_21.csv",
  "2021-22" = "wbb_rosters_2021_22.csv",
  "2022-23" = "wbb_rosters_2022_23.csv",
  "2023-24" = "wbb_rosters_2023_24.csv",
  "2024-25" = "wbb_rosters_2024_25.csv",
  "2025-26" = "wbb_rosters_2025_26.csv",
  "2026-27" = "wbb_rosters_2026_27.csv"
)

# Grad students are treated at the same tier as fifth-year players since
# both commonly repeat a season of eligibility.
YEAR_RANK <- c(
  "Freshman" = 1,
  "Sophomore" = 2,
  "Junior" = 3,
  "Senior" = 4,
  "Fifth Year" = 5,
  "Graduate Student" = 5,
  "Sixth Year" = 6
)

# ---------------------------------------------------------------------------
# Step 1: normalization helpers
# ---------------------------------------------------------------------------

normalize_name <- function(x) {
  x %>%
    stri_trans_general("Latin-ASCII") %>%
    str_to_lower() %>%
    str_replace_all("[‘’“”'\"`.()-]", " ") %>%
    str_replace_all("\\b(jr|sr|ii|iii|iv|v)\\b", " ") %>%
    str_squish()
}

last_token <- function(x) {
  map_chr(str_split(x, " "), ~ if (length(.x) == 0) NA_character_ else tail(.x, 1))
}

normalize_url <- function(x) {
  x %>%
    str_to_lower() %>%
    str_replace("^https?://", "") %>%
    str_replace("^www\\.", "") %>%
    str_remove("/$")
}

normalize_team <- function(x) {
  x %>%
    str_to_lower() %>%
    str_replace_all("[.'-]", " ") %>%
    str_squish()
}

PREV_SCHOOL_MAP_FILE <- "data/previous_school_mapping.csv"

# Load the previous-school mapping (built by
# scripts/build_prev_school_mapping.py). A missing file is fine: the canonical
# columns still exist downstream and fall back to the cleaned value.
load_prev_school_map <- function() {
  if (!file.exists(PREV_SCHOOL_MAP_FILE)) return(NULL)
  out <- read_csv(PREV_SCHOOL_MAP_FILE, show_col_types = FALSE,
                  col_types = cols(.default = "c"))
  # The builder squishes keys and writes each lookup string once, so no
  # duplicate keys can survive; assert that rather than silently resolving it.
  stopifnot("previous-school mapping keys must be unique" =
              !any(duplicated(str_squish(out$previous_school))))
  out
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

# ---------------------------------------------------------------------------
# Step 0: load and standardize all six season files
# ---------------------------------------------------------------------------

derive_height_from_clean <- function(height_clean) {
  cleaned <- height_clean %>%
    str_replace_all("'", "-") %>%
    str_replace_all("''", "") %>%
    str_replace_all('"', "")
  parts <- str_split_fixed(cleaned, "-", 2)
  ft <- suppressWarnings(as.numeric(parts[, 1]))
  inch <- suppressWarnings(as.numeric(parts[, 2]))
  list(height_ft = ft, height_in = inch, total_inches = ft * 12 + inch)
}

load_one_season <- function(file, season_label, ps_map = NULL) {
  df <- read_csv(file, show_col_types = FALSE, col_types = cols(.default = "c"))

  if (!"player_id" %in% names(df)) df$player_id <- NA_character_
  if (!"previous_school" %in% names(df)) df$previous_school <- NA_character_
  if (!"previous_school_clean" %in% names(df)) df$previous_school_clean <- NA_character_

  # 2021-22 lacks parsed height columns; derive them from height_clean the
  # same way cleaning.Rmd does for every other season.
  if (!all(c("height_ft", "height_in", "total_inches") %in% names(df))) {
    derived <- derive_height_from_clean(df$height_clean)
    df$height_ft <- as.character(derived$height_ft)
    df$height_in <- as.character(derived$height_in)
    df$total_inches <- as.character(derived$total_inches)
  }

  df %>%
    mutate(
      season = season_label,
      # 2025-26 has no player_id column; recover the roster number from url.
      season_player_id = if_else(is.na(player_id) | player_id == "",
                                  str_extract(url, "\\d+$"), player_id),
      url_norm = normalize_url(url),
      name_norm = normalize_name(name),
      last_name_norm = last_token(name_norm),
      year_rank = unname(YEAR_RANK[year_clean]),
      redshirt_num = replace_na(suppressWarnings(as.numeric(redshirt)), 0),
      total_inches_num = suppressWarnings(as.numeric(total_inches)),
      previous_school_lookup =
        # Squish first: raw scrapes carry non-breaking spaces and padding
        # (e.g. 2022-23 La Verne rows whose previous_school is only a nbsp),
        # which would otherwise survive as a junk lookup string.
        coalesce(blank_to_na(str_squish(previous_school)),
                 blank_to_na(str_squish(previous_school_clean))),
      previous_school_canonical =
        coalesce(ps_map_lookup(ps_map, previous_school_lookup, "canonical"),
                 previous_school_lookup),
      previous_school_ncaa_id =
        ps_map_lookup(ps_map, previous_school_lookup, "ncaa_id"),
      previous_school_category =
        ps_map_lookup(ps_map, previous_school_lookup, "category")
    )
}

STALE_EXCLUSIONS_FILE <- "data/stale_roster_exclusions.csv"

# Drop the rows scripts/find_stale_rosters.py listed: team-seasons whose
# roster is a stale copy of another season (scope team_season) and single
# duplicate rows (scope row: season + ncaa_id + name + url). The published
# season CSVs are stripped too (scripts/strip_stale_rows.py); this keeps the
# ID build correct if a stale row ever comes back.
drop_stale_rows <- function(df, exclusions_file = STALE_EXCLUSIONS_FILE) {
  if (!file.exists(exclusions_file)) return(df)
  ex <- read_csv(exclusions_file, show_col_types = FALSE,
                 col_types = cols(.default = "c"))
  team_seasons <- ex %>% filter(scope == "team_season") %>% distinct(season, ncaa_id)
  rows <- ex %>%
    filter(scope == "row") %>%
    transmute(season, ncaa_id, name, url_norm = normalize_url(url))
  df %>%
    anti_join(team_seasons, by = c("season", "ncaa_id")) %>%
    anti_join(rows, by = c("season", "ncaa_id", "name", "url_norm"))
}

load_all_seasons <- function(season_files = SEASON_FILES,
                             ps_map = load_prev_school_map()) {
  seasons_in_order <- names(season_files)
  all_rows <- imap_dfr(season_files, ~ load_one_season(.x, .y, ps_map = ps_map))
  n_loaded <- nrow(all_rows)
  all_rows <- drop_stale_rows(all_rows)
  message("Dropped ", n_loaded - nrow(all_rows), " stale roster rows (",
          STALE_EXCLUSIONS_FILE, ")")
  all_rows %>%
    mutate(
      season_order = match(season, seasons_in_order),
      row_id = paste0("r", row_number())
    )
}

# ---------------------------------------------------------------------------
# Step 2: within-season duplicate resolution
# ---------------------------------------------------------------------------

resolve_within_season_dupes <- function(all_rows) {
  dup_keys <- all_rows %>%
    count(season, ncaa_id, name_norm) %>%
    filter(n > 1)

  if (nrow(dup_keys) == 0) {
    return(list(
      rows = all_rows %>% mutate(dup_of = NA_character_, is_dup_representative = TRUE),
      review = tibble()
    ))
  }

  flagged <- all_rows %>%
    semi_join(dup_keys, by = c("season", "ncaa_id", "name_norm")) %>%
    arrange(season, ncaa_id, name_norm, row_id) %>%
    group_by(season, ncaa_id, name_norm) %>%
    mutate(
      same_hometown = n_distinct(coalesce(hometown_clean, "NA_PLACEHOLDER")) == 1,
      same_height = n_distinct(coalesce(as.character(total_inches_num), "NA_PLACEHOLDER")) == 1,
      likely_same_person = same_hometown & same_height,
      dup_of = if_else(likely_same_person, first(row_id), NA_character_),
      is_dup_representative = row_id == first(row_id) | !likely_same_person
    ) %>%
    ungroup()

  review_rows <- flagged %>%
    filter(!likely_same_person) %>%
    transmute(
      queue_type = "within_season_duplicate_name",
      season, ncaa_id, team, name, hometown_clean, total_inches_num, jersey,
      note = "Same name + team, different hometown/height -- verify distinct players"
    )

  merged <- all_rows %>%
    left_join(flagged %>% select(row_id, dup_of, is_dup_representative), by = "row_id") %>%
    mutate(is_dup_representative = coalesce(is_dup_representative, TRUE))

  list(rows = merged, review = review_rows)
}

# ---------------------------------------------------------------------------
# Guards shared by tier 1 and tier 2
# ---------------------------------------------------------------------------

year_progression_ok <- function(prev_rank, prev_order, prev_redshirt,
                                 curr_rank, curr_order, curr_redshirt) {
  if (is.na(prev_rank) || is.na(curr_rank)) return(TRUE)
  elapsed <- curr_order - prev_order
  if (elapsed <= 0) return(FALSE)
  # COVID eligibility freeze: 2020-21 -> 2021-22 allows a repeated rank
  # beyond the normal redshirt allowance.
  covid_slack <- if (prev_order == 1 && curr_order == 2) 1 else 0
  redshirt_slack <- if (curr_redshirt == 1 || prev_redshirt == 1) 1 else 0
  min_allowed <- prev_rank - redshirt_slack - covid_slack
  max_allowed <- prev_rank + elapsed + 1 + redshirt_slack + covid_slack
  curr_rank >= min_allowed && curr_rank <= max_allowed
}

attributes_conflict <- function(prev_inches, curr_inches) {
  !is.na(prev_inches) && !is.na(curr_inches) && abs(prev_inches - curr_inches) > 3
}

# ---------------------------------------------------------------------------
# Step 3: tiered matching against the cumulative player table
# ---------------------------------------------------------------------------

new_player_table <- function() {
  tibble(
    wbb_id = character(), name_norm = character(), last_name_norm = character(),
    ncaa_id = character(), last_team = character(), last_season_order = integer(),
    year_rank = numeric(), redshirt_num = numeric(), total_inches_num = numeric(),
    hometown_clean = character(), state_clean = character(), hs_clean = character(),
    country_clean = character(), previous_school_clean = character(),
    n_seasons = integer(), first_season_order = integer()
  )
}

empty_matched <- function(season_rows) {
  season_rows %>% filter(FALSE) %>% mutate(wbb_id = character(), match_tier = character())
}

match_tier1 <- function(season_rows, player_table) {
  if (nrow(player_table) == 0 || nrow(season_rows) == 0) {
    return(list(matched = empty_matched(season_rows), remaining = season_rows))
  }

  candidates <- season_rows %>%
    inner_join(player_table, by = c("name_norm", "ncaa_id"), suffix = c("", ".prev"),
               relationship = "many-to-many") %>%
    group_by(row_id) %>%
    filter(n() == 1) %>%
    ungroup()

  if (nrow(candidates) == 0) return(list(matched = empty_matched(season_rows), remaining = season_rows))

  ok <- pmap_lgl(
    candidates %>% select(year_rank, season_order, redshirt_num,
                           year_rank.prev, last_season_order, redshirt_num.prev,
                           total_inches_num, total_inches_num.prev),
    function(year_rank, season_order, redshirt_num, year_rank.prev, last_season_order,
             redshirt_num.prev, total_inches_num, total_inches_num.prev) {
      year_progression_ok(year_rank.prev, last_season_order, redshirt_num.prev,
                           year_rank, season_order, redshirt_num) &&
        !attributes_conflict(total_inches_num.prev, total_inches_num)
    }
  )

  matched <- candidates %>% filter(ok) %>% mutate(match_tier = "tier1")
  remaining <- season_rows %>% anti_join(matched, by = "row_id")
  list(matched = matched, remaining = remaining)
}

match_tier2 <- function(season_rows, player_table) {
  if (nrow(player_table) == 0 || nrow(season_rows) == 0) {
    return(list(matched = empty_matched(season_rows), remaining = season_rows,
                ambiguous = empty_matched(season_rows)))
  }

  candidates <- season_rows %>%
    inner_join(player_table, by = "name_norm", suffix = c("", ".prev"),
               relationship = "many-to-many") %>%
    filter(ncaa_id != ncaa_id.prev) %>%
    mutate(
      prev_school_norm = normalize_team(previous_school_clean),
      prev_team_norm = normalize_team(last_team),
      # Canonical previous-school path first (resolves abbreviations the string
      # path can't, e.g. "Utah State" vs team "Utah St."); string path stays as
      # the fallback for values the mapping hasn't seen.
      tier2a = (!is.na(previous_school_ncaa_id) & !is.na(ncaa_id.prev) &
                  previous_school_ncaa_id == ncaa_id.prev) |
        (!is.na(prev_school_norm) & !is.na(prev_team_norm) &
           prev_school_norm == prev_team_norm),
      tier2b_hometown = !is.na(hometown_clean) & !is.na(hometown_clean.prev) &
        hometown_clean == hometown_clean.prev &
        !is.na(state_clean) & !is.na(state_clean.prev) & state_clean == state_clean.prev,
      tier2b_hs = !is.na(hs_clean) & !is.na(hs_clean.prev) & hs_clean == hs_clean.prev,
      tier2_evidence = tier2a | tier2b_hometown | tier2b_hs
    ) %>%
    filter(tier2_evidence)

  if (nrow(candidates) == 0) {
    return(list(matched = empty_matched(season_rows), remaining = season_rows,
                ambiguous = empty_matched(season_rows)))
  }

  ok <- pmap_lgl(
    candidates %>% select(year_rank, season_order, redshirt_num,
                           year_rank.prev, last_season_order, redshirt_num.prev,
                           total_inches_num, total_inches_num.prev),
    function(year_rank, season_order, redshirt_num, year_rank.prev, last_season_order,
             redshirt_num.prev, total_inches_num, total_inches_num.prev) {
      year_progression_ok(year_rank.prev, last_season_order, redshirt_num.prev,
                           year_rank, season_order, redshirt_num) &&
        !attributes_conflict(total_inches_num.prev, total_inches_num)
    }
  )

  candidates <- candidates %>% filter(ok)
  if (nrow(candidates) == 0) {
    return(list(matched = empty_matched(season_rows), remaining = season_rows,
                ambiguous = empty_matched(season_rows)))
  }
  n_candidates <- candidates %>% count(row_id)
  unambiguous_ids <- n_candidates %>% filter(n == 1) %>% pull(row_id)

  matched <- candidates %>% filter(row_id %in% unambiguous_ids) %>% mutate(match_tier = "tier2")
  ambiguous <- candidates %>% filter(!row_id %in% unambiguous_ids)
  remaining <- season_rows %>% anti_join(matched, by = "row_id")

  list(matched = matched, remaining = remaining, ambiguous = ambiguous)
}

match_tier3 <- function(season_rows, player_table, max_dist = 0.12) {
  if (nrow(player_table) == 0 || nrow(season_rows) == 0) return(tibble())

  block_a <- season_rows %>%
    inner_join(player_table, by = "ncaa_id", suffix = c("", ".prev"),
               relationship = "many-to-many") %>%
    mutate(name_dist = stringdist(name_norm, name_norm.prev, method = "jw", p = 0.1)) %>%
    filter(name_dist > 0, name_dist <= max_dist) %>%
    mutate(block = "same_team_name_variant")

  block_b <- season_rows %>%
    inner_join(player_table, by = "last_name_norm", suffix = c("", ".prev"),
               relationship = "many-to-many") %>%
    filter(
      ncaa_id != ncaa_id.prev,
      (!is.na(hometown_clean) & !is.na(hometown_clean.prev) & hometown_clean == hometown_clean.prev) |
        (!is.na(hs_clean) & !is.na(hs_clean.prev) & hs_clean == hs_clean.prev)
    ) %>%
    mutate(
      name_dist = stringdist(name_norm, name_norm.prev, method = "jw", p = 0.1),
      block = "transfer_name_variant"
    )

  candidates <- bind_rows(block_a, block_b) %>% distinct(row_id, wbb_id, .keep_all = TRUE)
  if (nrow(candidates) == 0) return(tibble())

  candidates %>%
    mutate(
      name_dist = round(name_dist, 6),
      hometown_match = !is.na(hometown_clean) & !is.na(hometown_clean.prev) & hometown_clean == hometown_clean.prev,
      hs_match = !is.na(hs_clean) & !is.na(hs_clean.prev) & hs_clean == hs_clean.prev,
      height_match = !is.na(total_inches_num) & !is.na(total_inches_num.prev) &
        abs(total_inches_num - total_inches_num.prev) <= 1,
      score = round((1 - name_dist) * 0.5 + hometown_match * 0.2 + hs_match * 0.2 + height_match * 0.1, 3)
    ) %>%
    transmute(
      row_id, season, team, name,
      candidate_wbb_id = wbb_id, candidate_name = name_norm.prev,
      block, name_dist, hometown_match, hs_match, height_match, score
    ) %>%
    arrange(desc(score))
}

mint_ids <- function(rows, next_id) {
  if (nrow(rows) == 0) {
    return(list(
      assignments = tibble(row_id = character(), wbb_id = character(), match_tier = character()),
      next_id = next_id
    ))
  }
  ids <- sprintf("wbb-%06d", next_id + seq_len(nrow(rows)) - 1)
  list(
    assignments = tibble(row_id = rows$row_id, wbb_id = ids, match_tier = "new"),
    next_id = next_id + nrow(rows)
  )
}

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
    mutate(n_arrival = n(),          # n_ok_ev counts only evidence-bearing
           n_ok_ev = sum(year_ok & height_close & evidence != "none")) %>%
    ungroup() %>%
    filter(n_ok_ev == 0) %>%         # rows with an evidence-bearing screen-passing
                                     # candidate are tier 2's business (matched or
                                     # ambiguous); rows tier 2 declined stay queued
    group_by(wbb_id) %>% mutate(n_prior = n()) %>% ungroup() %>%
    filter(evidence != "none" |      # corroborated-but-screen-failing always queue
             (year_ok & height_close &   # no-evidence rows: only the consistent,
              n_arrival == 1 & n_prior == 1))  # unambiguous ones are candidates

  queueable %>%
    transmute(
      row_id, season, team, name,
      candidate_wbb_id = wbb_id,
      candidate_name = name_norm,      # join key: prior row's name_norm is identical
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

# ---------------------------------------------------------------------------
# Orchestration: process seasons in order against a cumulative player table
# ---------------------------------------------------------------------------

build_player_ids <- function(all_rows_with_dupes) {
  seasons <- sort(unique(all_rows_with_dupes$season_order))
  player_table <- new_player_table()
  assignments <- tibble(row_id = character(), wbb_id = character(), match_tier = character())
  review_queue <- list()
  next_id <- 1

  representatives <- all_rows_with_dupes %>% filter(is_dup_representative)

  for (s in seasons) {
    season_rows <- representatives %>% filter(season_order == s)

    step1 <- match_tier1(season_rows, player_table)
    step2 <- match_tier2(step1$remaining, player_table)
    tier3_candidates <- match_tier3(step2$remaining, player_table)

    if (nrow(tier3_candidates) > 0) {
      review_queue[[length(review_queue) + 1]] <- tier3_candidates
    }
    if (nrow(step2$ambiguous) > 0) {
      review_queue[[length(review_queue) + 1]] <- step2$ambiguous %>%
        transmute(row_id, season, team, name,
                  candidate_wbb_id = wbb_id, candidate_name = name_norm,
                  block = "ambiguous_transfer", name_dist = NA_real_,
                  hometown_match = tier2b_hometown, hs_match = tier2b_hs,
                  height_match = NA, score = NA_real_)
    }

    step3_queue <- queue_transfer_candidates(step2$remaining, player_table)
    if (nrow(step3_queue) > 0) {
      review_queue[[length(review_queue) + 1]] <- step3_queue
    }

    matched_this_season <- bind_rows(
      step1$matched %>% select(row_id, wbb_id, match_tier),
      step2$matched %>% select(row_id, wbb_id, match_tier)
    ) %>%
      arrange(match_tier, row_id)

    # Guard: two different rows in the same season can independently match
    # the same historical player (e.g. a coincidental shared hometown with
    # an unrelated same-name transfer). Keep only the first claim on a given
    # wbb_id per season; demote the rest back into the matching pool so
    # tier 3 / minting handles them instead of silently double-assigning.
    dupe_claims <- matched_this_season %>% count(wbb_id) %>% filter(n > 1) %>% pull(wbb_id)
    if (length(dupe_claims) > 0) {
      demoted <- matched_this_season %>%
        filter(wbb_id %in% dupe_claims) %>%
        group_by(wbb_id) %>%
        slice(-1) %>%
        ungroup()
      review_queue[[length(review_queue) + 1]] <- demoted %>%
        left_join(season_rows %>% select(row_id, team, name), by = "row_id") %>%
        transmute(row_id, season = season_rows$season[1], team, name,
                  candidate_wbb_id = wbb_id, candidate_name = NA_character_,
                  block = "duplicate_wbb_id_claim", name_dist = NA_real_,
                  hometown_match = NA, hs_match = NA, height_match = NA, score = NA_real_)
      matched_this_season <- matched_this_season %>% anti_join(demoted, by = "row_id")
    }

    still_unmatched <- season_rows %>% anti_join(matched_this_season, by = "row_id")
    minted <- mint_ids(still_unmatched, next_id)
    next_id <- minted$next_id

    season_assignments <- bind_rows(matched_this_season, minted$assignments)
    assignments <- bind_rows(assignments, season_assignments)

    season_detail <- season_rows %>% inner_join(season_assignments, by = "row_id")

    updated_existing <- season_detail %>%
      filter(match_tier != "new") %>%
      left_join(
        player_table %>%
          select(wbb_id, old_total_inches = total_inches_num, old_hometown_clean = hometown_clean,
                 old_state_clean = state_clean, old_hs_clean = hs_clean,
                 old_country_clean = country_clean, n_seasons, first_season_order),
        by = "wbb_id"
      ) %>%
      transmute(
        wbb_id, name_norm, last_name_norm, ncaa_id, last_team = team,
        last_season_order = season_order, year_rank, redshirt_num = redshirt_num,
        total_inches_num = coalesce(total_inches_num, old_total_inches),
        hometown_clean = coalesce(hometown_clean, old_hometown_clean),
        state_clean = coalesce(state_clean, old_state_clean),
        hs_clean = coalesce(hs_clean, old_hs_clean),
        country_clean = coalesce(country_clean, old_country_clean),
        previous_school_clean,
        n_seasons = n_seasons + 1L,
        first_season_order
      )

    new_players <- season_detail %>%
      filter(match_tier == "new") %>%
      transmute(
        wbb_id, name_norm, last_name_norm, ncaa_id, last_team = team,
        last_season_order = season_order, year_rank, redshirt_num,
        total_inches_num, hometown_clean, state_clean, hs_clean, country_clean,
        previous_school_clean, n_seasons = 1L, first_season_order = season_order
      )

    if (nrow(updated_existing) > 0) {
      player_table <- rows_update(player_table, updated_existing, by = "wbb_id")
    }
    if (nrow(new_players) > 0) {
      player_table <- bind_rows(player_table, new_players)
    }
  }

  list(
    assignments = assignments,
    player_table = player_table,
    review_queue = if (length(review_queue) > 0) bind_rows(review_queue) else tibble()
  )
}

propagate_dup_assignments <- function(all_rows_with_dupes, assignments) {
  dup_rows <- all_rows_with_dupes %>%
    filter(!is_dup_representative) %>%
    select(row_id, dup_of)

  if (nrow(dup_rows) == 0) return(assignments)

  dup_assignments <- dup_rows %>%
    inner_join(assignments %>% select(dup_of = row_id, wbb_id, match_tier), by = "dup_of") %>%
    mutate(match_tier = paste0(match_tier, "_dup")) %>%
    select(row_id, wbb_id, match_tier)

  bind_rows(assignments, dup_assignments)
}

# ---------------------------------------------------------------------------
# Step 4 (post-process): hand-adjudicated overrides
# ---------------------------------------------------------------------------

apply_overrides <- function(assignments, all_rows, overrides_file = "player_id_overrides.csv") {
  if (!file.exists(overrides_file)) return(assignments)

  overrides <- read_csv(overrides_file, show_col_types = FALSE)
  if (nrow(overrides) == 0) return(assignments)

  lookup <- all_rows %>% select(row_id, season, team, name)

  resolve_side <- function(season_col, team_col, name_col) {
    tibble(season = overrides[[season_col]], team = overrides[[team_col]], name = overrides[[name_col]]) %>%
      left_join(lookup, by = c("season", "team", "name")) %>%
      left_join(assignments %>% select(row_id, wbb_id), by = "row_id")
  }

  side_a <- resolve_side("season_a", "team_a", "name_a")
  side_b <- resolve_side("season_b", "team_b", "name_b")

  pairs <- tibble(
    decision = overrides$decision,
    row_id_b = side_b$row_id,
    wbb_id_a = side_a$wbb_id,
    wbb_id_b = side_b$wbb_id
  ) %>% filter(!is.na(wbb_id_a), !is.na(wbb_id_b))

  splits <- pairs %>% filter(decision == "different", wbb_id_a == wbb_id_b)
  if (nrow(splits) > 0) {
    max_num <- max(suppressWarnings(as.numeric(str_extract(assignments$wbb_id, "\\d+"))), na.rm = TRUE)
    for (i in seq_len(nrow(splits))) {
      max_num <- max_num + 1
      new_id <- sprintf("wbb-%06d", max_num)
      assignments$wbb_id[assignments$row_id == splits$row_id_b[i]] <- new_id
    }
  }

  merges <- pairs %>% filter(decision == "same", wbb_id_a != wbb_id_b)
  for (i in seq_len(nrow(merges))) {
    assignments$wbb_id[assignments$wbb_id == merges$wbb_id_b[i]] <- merges$wbb_id_a[i]
  }

  assignments
}

# ---------------------------------------------------------------------------
# Step 4b (post-process): keep published wbb_ids stable across re-knits
# ---------------------------------------------------------------------------
#
# The matcher mints IDs from 1 on every run, so any change to the input
# (a dropped stale roster, a new override) would renumber everyone. This
# step maps the run's temporary IDs back onto the IDs already published in
# wbb_player_seasons.csv, matching rows on season + ncaa_id + name + url:
#
#   - Old IDs are handed out lowest first. Each goes to the cluster holding
#     most of its rows, unless that cluster already has an (older) ID.
#   - When every cluster holding an old ID already has one, the old ID is
#     retired into the cluster's ID (a merge). Old IDs whose rows are all gone
#     retire with no successor. Retirements are appended to wbb_id_retired.csv,
#     so downstream users can follow them.
#   - Clusters with no old ID get new IDs above the highest ever issued,
#     retired ones included, so an ID is never reused.

RETIRED_IDS_FILE <- "wbb_id_retired.csv"

id_num <- function(x) suppressWarnings(as.numeric(str_extract(x, "\\d+")))

persist_ids <- function(assignments, all_rows, prior_file = "wbb_player_seasons.csv",
                        registry_file = RETIRED_IDS_FILE,
                        retired_on = as.character(Sys.Date())) {
  registry <- if (file.exists(registry_file)) {
    read_csv(registry_file, show_col_types = FALSE, col_types = cols(.default = "c"))
  } else {
    tibble(old_wbb_id = character(), new_wbb_id = character(),
           retired_on = character(), reason = character())
  }
  prior <- if (file.exists(prior_file)) {
    read_csv(prior_file, show_col_types = FALSE, col_types = cols(.default = "c")) %>%
      transmute(old_id = wbb_id, season, ncaa_id, name, url_norm = normalize_url(url)) %>%
      distinct()
  } else {
    tibble(old_id = character(), season = character(), ncaa_id = character(),
           name = character(), url_norm = character())
  }

  rows <- assignments %>%
    left_join(all_rows %>% select(row_id, season, ncaa_id, name, url_norm, season_order),
              by = "row_id")
  clusters <- rows %>%
    group_by(temp_id = wbb_id) %>%
    summarise(first_order = min(season_order),
              first_row = min(as.numeric(str_remove(row_id, "^r"))), .groups = "drop") %>%
    arrange(first_order, first_row)
  carried <- rows %>%
    inner_join(prior, by = c("season", "ncaa_id", "name", "url_norm"),
               relationship = "many-to-many") %>%
    count(temp_id = wbb_id, old_id, name = "support") %>%
    left_join(clusters %>% mutate(cluster_rank = row_number()) %>%
                select(temp_id, cluster_rank), by = "temp_id") %>%
    arrange(old_id, desc(support), cluster_rank)

  final <- setNames(rep(NA_character_, nrow(clusters)), clusters$temp_id)
  retired <- list()
  by_old <- split(carried$temp_id, carried$old_id)
  for (old in names(by_old)) {
    cands <- by_old[[old]]
    free <- cands[is.na(final[cands])]
    if (length(free) > 0) {
      final[free[1]] <- old
    } else {
      retired[[length(retired) + 1]] <- tibble(old_wbb_id = old, temp_id = cands[1],
                                               reason = "merged")
    }
  }

  max_num <- max(c(0, id_num(prior$old_id), id_num(registry$old_wbb_id),
                   id_num(registry$new_wbb_id)), na.rm = TRUE)
  unassigned <- names(final)[is.na(final)]
  final[unassigned] <- sprintf("wbb-%06d", max_num + seq_along(unassigned))

  id_map <- tibble(temp_id = names(final), wbb_id = unname(final))
  gone <- setdiff(unique(prior$old_id), carried$old_id)
  new_registry <- bind_rows(
    bind_rows(retired, tibble(old_wbb_id = character(), temp_id = character(),
                              reason = character())) %>%
      left_join(id_map, by = "temp_id") %>%
      transmute(old_wbb_id, new_wbb_id = wbb_id, retired_on, reason),
    tibble(old_wbb_id = gone, new_wbb_id = NA_character_, retired_on = retired_on,
           reason = rep("rows removed", length(gone)))
  ) %>% arrange(old_wbb_id)

  out <- assignments %>%
    rename(temp_id = wbb_id) %>%
    left_join(id_map, by = "temp_id") %>%
    select(row_id, wbb_id, everything(), -temp_id)

  all_retired <- c(registry$old_wbb_id, new_registry$old_wbb_id)
  stopifnot(
    "persist_ids: every row keeps exactly one wbb_id" =
      nrow(out) == nrow(assignments) && !any(is.na(out$wbb_id)),
    "persist_ids: one temporary ID maps to one final ID" =
      !any(duplicated(id_map$wbb_id)),
    "persist_ids: a retired wbb_id is live again" =
      !any(out$wbb_id %in% all_retired),
    "persist_ids: a published wbb_id vanished without a retirement record" =
      all(unique(prior$old_id) %in% c(out$wbb_id, all_retired))
  )

  list(assignments = out, id_map = id_map,
       registry = bind_rows(registry, new_registry), new_retirements = new_registry)
}

# ---------------------------------------------------------------------------
# Step 4: GUID crosswalk as validation / enrichment (2022-23 only)
# ---------------------------------------------------------------------------

check_against_guids <- function(all_rows, assignments, crosswalk_file = "wbb_rosters23_crosswalk.csv") {
  crosswalk <- read_csv(crosswalk_file, show_col_types = FALSE) %>%
    mutate(url_norm = normalize_url(url))

  season_2223 <- all_rows %>%
    filter(season == "2022-23") %>%
    left_join(assignments, by = "row_id") %>%
    left_join(crosswalk %>% select(url_norm, hhs_person_id_text), by = "url_norm",
              relationship = "many-to-many")

  precision_check <- season_2223 %>%
    filter(!is.na(hhs_person_id_text)) %>%
    group_by(wbb_id) %>%
    summarise(n_guids = n_distinct(hhs_person_id_text), .groups = "drop")

  recall_check <- season_2223 %>%
    filter(!is.na(hhs_person_id_text)) %>%
    group_by(hhs_person_id_text) %>%
    summarise(n_wbb_ids = n_distinct(wbb_id), .groups = "drop")

  list(
    precision = mean(precision_check$n_guids == 1),
    recall = mean(recall_check$n_wbb_ids == 1),
    precision_violations = precision_check %>% filter(n_guids > 1),
    recall_violations = recall_check %>% filter(n_wbb_ids > 1),
    joined = season_2223
  )
}

# ---------------------------------------------------------------------------
# Step 5: validation checks
# ---------------------------------------------------------------------------

validate_ids <- function(all_rows, assignments) {
  joined <- all_rows %>% left_join(assignments, by = "row_id")

  issues <- list()

  two_teams_same_season <- joined %>%
    distinct(wbb_id, season, ncaa_id) %>%
    count(wbb_id, season) %>%
    filter(n > 1)
  if (nrow(two_teams_same_season) > 0) issues$two_teams_same_season <- two_teams_same_season

  span <- joined %>%
    group_by(wbb_id) %>%
    summarise(span = max(season_order) - min(season_order) + 1, .groups = "drop") %>%
    filter(span > 7)
  if (nrow(span) > 0) issues$impossible_span <- span

  funnel <- joined %>%
    count(season, match_tier) %>%
    pivot_wider(names_from = match_tier, values_from = n, values_fill = 0)

  list(issues = issues, funnel = funnel)
}
