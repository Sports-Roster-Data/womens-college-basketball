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
  "2025-26" = "wbb_rosters_2025_26.csv"
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

load_one_season <- function(file, season_label) {
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
      total_inches_num = suppressWarnings(as.numeric(total_inches))
    )
}

load_all_seasons <- function(season_files = SEASON_FILES) {
  seasons_in_order <- names(season_files)
  all_rows <- imap_dfr(season_files, ~ load_one_season(.x, .y))
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
      tier2a = !is.na(prev_school_norm) & !is.na(prev_team_norm) &
        prev_school_norm == prev_team_norm,
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
    filter(span > 6)
  if (nrow(span) > 0) issues$impossible_span <- span

  funnel <- joined %>%
    count(season, match_tier) %>%
    pivot_wider(names_from = match_tier, values_from = n, values_fill = 0)

  list(issues = issues, funnel = funnel)
}
