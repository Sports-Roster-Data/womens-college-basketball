#!/usr/bin/env Rscript
# Build the public site's JSON data from the committed CSVs.
#
# Inputs (repo root): wbb_rosters_combined.csv, players.csv, teams.csv
# Outputs (site/data/): meta.json, teams.json, players.json, team_seasons.json,
#   geography.json, transfers.json, trends.json, seasons/<season>.json,
#   cards/wbb-XXX.json
#
# Run:  LC_ALL=en_US.UTF-8 Rscript scripts/build_site_data.R
# Requires: jsonlite (plus base R). The stopifnot() guards below name the
# invariant that broke; don't weaken them to make a run pass.
#
# Conventions:
# - Seasons are derived from wbb_rosters_combined.csv, never hardcoded, so a
#   future re-knit of player_ids.Rmd that adds a season needs no change here.
# - Teams are compared by ncaa_id everywhere (names change; ids don't).
# - state_clean: "USVI" is normalized to "VI" here only, never in the CSVs.
# - Heights outside [58, 90] inches are treated as parse errors (the same rule
#   cleaning.Rmd applies) and excluded from aggregates, but shipped raw in the
#   per-season files.
# - Generated JSON is gitignored; the CSVs stay the single source of truth.

suppressWarnings(library(jsonlite))

## ---------------------------------------------------------------- constants

SHIP_COLS <- c(
  "wbb_id", "ncaa_id", "team", "name", "jersey", "year_clean", "redshirt",
  "position_clean", "primary_position", "total_inches", "hometown_clean",
  "state_clean", "country_clean", "hs_clean", "previous_school_clean",
  "conference", "division", "url"
)

YEAR_ORDER <- c("Freshman", "Sophomore", "Junior", "Senior", "Graduate Student",
                "Fifth Year", "Sixth Year", "Unknown")
POS_ORDER <- c("GUARD", "FORWARD", "CENTER", "WING", "Unknown")

HEIGHT_MIN <- 58
HEIGHT_MAX <- 90
CITY_MIN_PLAYERS <- 10      # hometown cities need >= this many distinct players
FEEDER_MIN_PLAYERS <- 5      # previous schools need >= this many distinct players

# 2020 Census resident population (public domain). AE has no resident
# population, so it is excluded from per-capita views.
STATE_INFO <- list(
  "AL" = list(name = "Alabama", pop = 5024279),
  "AK" = list(name = "Alaska", pop = 733391),
  "AZ" = list(name = "Arizona", pop = 7151502),
  "AR" = list(name = "Arkansas", pop = 3011524),
  "CA" = list(name = "California", pop = 39538223),
  "CO" = list(name = "Colorado", pop = 5773714),
  "CT" = list(name = "Connecticut", pop = 3605944),
  "DE" = list(name = "Delaware", pop = 989948),
  "DC" = list(name = "District of Columbia", pop = 689545),
  "FL" = list(name = "Florida", pop = 21538187),
  "GA" = list(name = "Georgia", pop = 10711908),
  "HI" = list(name = "Hawaii", pop = 1455271),
  "ID" = list(name = "Idaho", pop = 1839106),
  "IL" = list(name = "Illinois", pop = 12812508),
  "IN" = list(name = "Indiana", pop = 6785528),
  "IA" = list(name = "Iowa", pop = 3190369),
  "KS" = list(name = "Kansas", pop = 2937880),
  "KY" = list(name = "Kentucky", pop = 4505836),
  "LA" = list(name = "Louisiana", pop = 4657757),
  "ME" = list(name = "Maine", pop = 1362359),
  "MD" = list(name = "Maryland", pop = 6177224),
  "MA" = list(name = "Massachusetts", pop = 7029917),
  "MI" = list(name = "Michigan", pop = 10077331),
  "MN" = list(name = "Minnesota", pop = 5706494),
  "MS" = list(name = "Mississippi", pop = 2961279),
  "MO" = list(name = "Missouri", pop = 6154913),
  "MT" = list(name = "Montana", pop = 1084225),
  "NE" = list(name = "Nebraska", pop = 1961504),
  "NV" = list(name = "Nevada", pop = 3104614),
  "NH" = list(name = "New Hampshire", pop = 1377529),
  "NJ" = list(name = "New Jersey", pop = 9288994),
  "NM" = list(name = "New Mexico", pop = 2117522),
  "NY" = list(name = "New York", pop = 20201249),
  "NC" = list(name = "North Carolina", pop = 10439388),
  "ND" = list(name = "North Dakota", pop = 779094),
  "OH" = list(name = "Ohio", pop = 11799448),
  "OK" = list(name = "Oklahoma", pop = 3959353),
  "OR" = list(name = "Oregon", pop = 4237256),
  "PA" = list(name = "Pennsylvania", pop = 13002700),
  "RI" = list(name = "Rhode Island", pop = 1097379),
  "SC" = list(name = "South Carolina", pop = 5118425),
  "SD" = list(name = "South Dakota", pop = 886667),
  "TN" = list(name = "Tennessee", pop = 6910840),
  "TX" = list(name = "Texas", pop = 29145505),
  "UT" = list(name = "Utah", pop = 3271616),
  "VT" = list(name = "Vermont", pop = 643077),
  "VA" = list(name = "Virginia", pop = 8631393),
  "WA" = list(name = "Washington", pop = 7705281),
  "WV" = list(name = "West Virginia", pop = 1793716),
  "WI" = list(name = "Wisconsin", pop = 5893718),
  "WY" = list(name = "Wyoming", pop = 576851),
  "PR" = list(name = "Puerto Rico", pop = 3285874),
  "VI" = list(name = "U.S. Virgin Islands", pop = 87146),
  "GU" = list(name = "Guam", pop = 153836),
  "AE" = list(name = "U.S. Armed Forces (Europe)")
)

# Tokens stripped from comma-less hometowns ("GREENSBORO NC" -> "GREENSBORO"):
# postal codes plus the old-style state abbreviations and full state names the
# source data mixes in.
NO_COMMA_STATE_TOKENS <- c(
  names(STATE_INFO),
  "ALASKA", "ARIZONA", "ARKANSA", "CALIF", "CALIFORNIA", "COLO", "COLORADO",
  "CONN", "CONNECTICUT", "DELAWARE", "FLA", "FLORIDA", "GEORGIA", "HAWAII",
  "ILL", "ILLINOIS", "IND", "INDIANA", "IOWA", "KAN", "KANSAS", "KENT",
  "KENTUCKY", "LOUISIANA", "MARYLAND", "MASS", "MASSACHUSETTS", "MICH",
  "MICHIGAN", "MINN", "MINNESOTA", "MISS", "MISSISSIPPI", "MISSOURI",
  "MONT", "MONTANA", "NEB", "NEBRASKA", "NEVADA", "OKLA", "OREG", "PENNA",
  "TENN", "TENNESSEE", "TEXAS", "VIRGINIA", "WASH", "WASHINGTON", "WISC",
  "WISCONSIN", "WYO"
)

## ---------------------------------------------------------------- helpers

# Read a committed CSV as all-character ("" stays "", nothing becomes NA here).
read_chr <- function(path) {
  read.csv(path, colClasses = "character", na.strings = character(0),
           check.names = FALSE, fileEncoding = "UTF-8")
}

# jsonlite wrapper: compact arrays for data.frames (array-of-arrays), NA -> null.
wj <- function(x, path) {
  jsonlite::write_json(x, path, auto_unbox = TRUE, digits = NA, na = "null",
                       dataframe = "values", pretty = FALSE)
}

# Empty string -> NA for a character vector ("" and NA are indistinguishable in
# the source anyway).
blank_na <- function(x) { x[x == ""] <- NA_character_; x }

# City from hometown_clean (US rows). Best-effort, documented on the site:
# strip trailing commas, then the city is everything before the last
# comma-segment ("ST, PETERS, MO" -> "ST, PETERS"); comma-less hometowns lose a
# trailing state token if one is present ("GREENSBORO NC" -> "GREENSBORO").
city_from <- function(hometown) {
  h <- trimws(hometown)
  h <- trimws(sub(",+$", "", h))
  comma <- regexpr(",", h, fixed = TRUE)[1]
  if (comma > 0) {
    last <- max(gregexpr(",", h, fixed = TRUE)[[1]])
    return(trimws(substr(h, 1, last - 1)))
  }
  parts <- strsplit(h, " ", fixed = TRUE)[[1]]
  if (length(parts) > 1 && parts[length(parts)] %in% NO_COMMA_STATE_TOKENS) {
    return(paste(head(parts, -1), collapse = " "))
  }
  h
}

## ---------------------------------------------------------------- read inputs

cat("Reading inputs...\n")
d <- read_chr("wbb_rosters_combined.csv")
players <- read_chr("players.csv")
teams <- read_chr("teams.csv")

stopifnot("wbb_rosters_combined.csv is missing shipped columns" =
            all(SHIP_COLS %in% names(d)))

## ---------------------------------------------------------------- normalize

d$state_clean[d$state_clean == "USVI"] <- "VI"

seasons <- sort(unique(d$season))
season_years <- as.integer(substr(seasons, 1, 4))
stopifnot("season values don't look like YYYY-YY" =
            all(grepl("^20\\d{2}-\\d{2}$", seasons)))
stopifnot("combined has fewer than 5 seasons - something is wrong" =
            length(seasons) >= 5)
seasons <- seasons[order(season_years)]
season_years <- season_years[order(season_years)]
stopifnot("seasons are not consecutive years" =
            all(diff(season_years) == 1))
n_season <- length(seasons)
d$season_idx <- match(d$season, seasons) - 1  # 0-based, JS-friendly

# Working frame: only the shipped columns, with types coerced.
w <- d[, SHIP_COLS]
w$season_idx <- d$season_idx  # kept alongside, not shipped in the JSON
w$redshirt <- suppressWarnings(as.integer(ifelse(w$redshirt == "", NA, w$redshirt)))
w$total_inches <- suppressWarnings(as.numeric(ifelse(w$total_inches == "", NA, w$total_inches)))
for (col in c("ncaa_id", "wbb_id", "team", "name", "jersey", "year_clean",
              "position_clean", "primary_position", "hometown_clean",
              "state_clean", "country_clean", "hs_clean", "previous_school_clean",
              "conference", "division", "url")) {
  w[[col]] <- blank_na(w[[col]])
}
# Previous-school canonical columns (applied by player_ids.Rmd): used by the
# feeder section, kept out of SHIP_COLS and the per-season files.
stopifnot("combined lacks the previous-school canonical columns - re-knit player_ids.Rmd" =
            all(c("previous_school_canonical", "previous_school_ncaa_id",
                  "previous_school_category") %in% names(d)))
for (col in c("previous_school_canonical", "previous_school_ncaa_id",
              "previous_school_category")) {
  w[[col]] <- blank_na(d[[col]])
}
# Heights used for aggregates (plausible range only, same rule as cleaning.Rmd).
w$height_ok <- !is.na(w$total_inches) &
               w$total_inches >= HEIGHT_MIN & w$total_inches <= HEIGHT_MAX

stopifnot("all US state codes must be in the STATE_INFO list - extend it" =
            all(na.omit(w$state_clean) %in% names(STATE_INFO)))

## ---------------------------------------------------------------- dedupe

# One row per (wbb_id, season). The known duplicates are near-identical rows;
# keep the most complete one (fewest NAs over the shipped columns), then lowest
# url as a deterministic tie-break.
na_count <- rowSums(is.na(w[, SHIP_COLS]))
keep_order <- order(w$wbb_id, w$season_idx, na_count, w$url, method = "radix")
w <- w[keep_order, ]
dupes <- duplicated(w[, c("wbb_id", "season_idx")])
cat(sprintf("Dropping %d duplicate wbb_id+season rows\n", sum(dupes)))
w <- w[!dupes, ]
rownames(w) <- NULL

stopifnot("duplicate wbb_id+season survived dedupe" =
            !any(duplicated(w[, c("wbb_id", "season_idx")])))
stopifnot("combined and players.csv are out of sync - re-knit player_ids.Rmd" =
            length(unique(w$wbb_id)) == nrow(players))
stopifnot("players.csv has ids the combined file lacks" =
            all(players$wbb_id %in% w$wbb_id))

n_rows <- nrow(w)
season_rows <- as.integer(table(factor(w$season_idx, levels = 0:(n_season - 1))))
cat(sprintf("%d player-seasons, %d players, %d seasons\n",
            n_rows, length(unique(w$wbb_id)), n_season))

## ---------------------------------------------------------------- per-season files

cat("Writing per-season files...\n")
dir.create("site/data/seasons", recursive = TRUE, showWarnings = FALSE)
for (i in seq_len(n_season)) {
  wi <- w[w$season_idx == i - 1, SHIP_COLS]
  wj(list(cols = SHIP_COLS, rows = wi),
     file.path("site/data/seasons", paste0(seasons[i], ".json")))
}

## ---------------------------------------------------------------- players index + card shards

cat("Writing player index and card shards...\n")
stopifnot("players.csv season labels don't match combined seasons" =
            all(c(players$first_season, players$last_season) %in% seasons))
players$first_idx <- match(players$first_season, seasons) - 1
players$last_idx <- match(players$last_season, seasons) - 1

players_out <- data.frame(
  wbb_id = players$wbb_id,
  name = players$canonical_name,
  first = players$first_idx,
  last = players$last_idx,
  n_seasons = as.integer(players$n_seasons),
  position = blank_na(players$position_mode),
  state = blank_na(players$state_clean),
  country = blank_na(players$country_clean),
  height = suppressWarnings(as.numeric(ifelse(players$height_total_inches_mode == "",
                                              NA, players$height_total_inches_mode))),
  hometown = blank_na(players$hometown_clean),
  stringsAsFactors = FALSE
)

# Per-player season rows from the deduped combined frame (already ordered by
# season within each wbb_id because of the dedupe sort; re-sort to be safe).
wo <- w[order(w$wbb_id, w$season_idx, method = "radix"), ]
wo_split <- split(wo, wo$wbb_id)
stopifnot("player split lost rows" =
            sum(vapply(wo_split, nrow, 1L)) == n_rows)

card_seasons <- lapply(wo_split, function(px) {
  data.frame(
    idx = px$season_idx,
    team_id = px$ncaa_id,
    team = px$team,
    year = ifelse(is.na(px$year_clean), "Unknown", px$year_clean),
    rs = px$redshirt,
    url = px$url,
    stringsAsFactors = FALSE
  )
})

shard_key <- substr(players$wbb_id, 1, 7)  # "wbb-001155" -> "wbb-001"
stopifnot("card shard count looks wrong (> 64 shards)" = length(unique(shard_key)) <= 64)

dir.create("site/data/cards", recursive = TRUE, showWarnings = FALSE)
players_ht <- suppressWarnings(as.numeric(ifelse(
  players$height_total_inches_mode == "", NA, players$height_total_inches_mode)))
shard_ids <- list()
for (key in sort(unique(shard_key))) {
  ids <- players$wbb_id[shard_key == key]
  shard_ids[[key]] <- ids
  pos <- match(ids, players$wbb_id)
  cards <- lapply(seq_along(ids), function(j) {
    i <- pos[j]
    list(
      name = players$canonical_name[i],
      home = blank_na(players$hometown_clean[i]),
      st = blank_na(players$state_clean[i]),
      co = blank_na(players$country_clean[i]),
      hs = blank_na(players$hs_clean[i]),
      ht = players_ht[i],
      pos = blank_na(players$position_mode[i]),
      conf = blank_na(players$match_confidence[i]),
      seasons = card_seasons[[ids[j]]]
    )
  })
  names(cards) <- ids
  wj(cards, file.path("site/data/cards", paste0(key, ".json")))
}
stopifnot("card shards must partition all players exactly once" =
            sum(lengths(shard_ids)) == nrow(players) &&
            length(unique(unlist(shard_ids))) == nrow(players))

## ---------------------------------------------------------------- teams

# Dedupe by ncaa_id keeping the LAST row: teams.csv carries renames as extra
# rows, and the last row is the current name/conference.
teams <- teams[!duplicated(teams$ncaa_id, fromLast = TRUE), ]
stopifnot("teams.csv dedupe left duplicate ncaa_ids" = !any(duplicated(teams$ncaa_id)))
teams_out <- data.frame(
  id = teams$ncaa_id,
  team = blank_na(teams$team),
  state = blank_na(teams$team_state),
  conference = blank_na(teams$conference),
  division = blank_na(teams$division),
  url = blank_na(teams$url),
  twitter = blank_na(teams$twitter),
  stringsAsFactors = FALSE
)
orphan_ids <- setdiff(unique(w$ncaa_id), teams_out$id)
if (length(orphan_ids) > 0) {
  cat(sprintf("NOTE: %d team ids in combined are missing from teams.csv: %s\n",
              length(orphan_ids), paste(head(orphan_ids, 10), collapse = ", ")))
}
team_state_of <- setNames(blank_na(teams$team_state), teams$ncaa_id)

wj(list(cols = names(teams_out), rows = teams_out), "site/data/teams.json")

## ---------------------------------------------------------------- team-seasons

cat("Building team-season summaries...\n")

# has_next: the next row in the sorted frame is the same player in the next
# season. has_prev: mirror. (Frame is sorted by wbb_id, season_idx.)
n <- nrow(wo)
same_next <- c(wo$wbb_id[-1], NA) == wo$wbb_id & c(wo$season_idx[-1], NA) == wo$season_idx + 1
same_next[is.na(same_next)] <- FALSE
same_prev <- c(NA, wo$wbb_id[-n]) == wo$wbb_id & c(NA, wo$season_idx[-n]) == wo$season_idx - 1
same_prev[is.na(same_prev)] <- FALSE

next_team <- ifelse(same_next, c(wo$ncaa_id[-1], NA), NA)
prev_team <- ifelse(same_prev, c(NA, wo$ncaa_id[-n]), NA)

# moves: rows where the player's next season is a different team (ncaa_id).
is_move <- same_next & !is.na(next_team) & next_team != wo$ncaa_id
stopifnot("transfer moves must be to a different team" =
            all(next_team[is_move] != wo$ncaa_id[is_move]))

us_row <- !is.na(wo$country_clean) & wo$country_clean == "USA"
# Canonical team_state comes from teams.csv (via the deduped map), since the
# shipped columns don't include team_state.
wo_team_state <- team_state_of[wo$ncaa_id]
in_state_row <- !is.na(wo$state_clean) & !is.na(wo_team_state) &
                wo$state_clean == wo_team_state

key <- paste(wo$ncaa_id, wo$season_idx, sep = "\r")
sum_by_key <- function(value) {
  tapply(value, factor(key), function(v) {
    v <- v[!is.na(v)]
    if (length(v) == 0) NA_integer_ else sum(v)
  })
}

# Per team-season counts (all computed from the row-level frame).
ts_players <- as.integer(table(key))
ts_us <- sum_by_key(as.integer(us_row))
ts_in_state <- sum_by_key(as.integer(in_state_row))

# retained_next / transfers_out need the *next* season for each row, so they are
# row attributes first, then summed per team-season.
row_retained_next <- ifelse(same_next, as.integer(next_team == wo$ncaa_id), NA_integer_)
row_retained_next[same_next & is.na(next_team)] <- 0L
row_retained_next[is.na(same_next) | wo$season_idx == n_season - 1] <- NA_integer_
row_transfers_out <- ifelse(same_next, as.integer(is_move), NA_integer_)
row_transfers_in <- ifelse(same_prev & !is.na(prev_team) & prev_team != wo$ncaa_id,
                           1L, ifelse(same_prev, 0L, NA_integer_))

ts_retained <- sum_by_key(row_retained_next)
ts_out <- sum_by_key(row_transfers_out)
ts_in <- sum_by_key(row_transfers_in)

# mean height over plausible heights only
row_height <- ifelse(wo$height_ok, wo$total_inches, NA_real_)
ts_mean_h <- tapply(row_height, factor(key), function(v) {
  v <- v[!is.na(v)]
  if (length(v) == 0) NA_real_ else round(mean(v), 1)
})

key_levels <- levels(factor(key))
ts_ncaa <- sub("\r.*", "", key_levels)
ts_idx <- as.integer(sub(".*\r", "", key_levels))

team_seasons_out <- data.frame(
  ncaa_id = ts_ncaa,
  season_idx = ts_idx,
  players = ts_players,
  us_players = ts_us,
  in_state = ts_in_state,
  retained_next = ts_retained,
  transfers_in = ts_in,
  transfers_out = ts_out,
  mean_height = ts_mean_h,
  stringsAsFactors = FALSE
)
team_seasons_out <- team_seasons_out[order(team_seasons_out$ncaa_id,
                                           team_seasons_out$season_idx,
                                           method = "radix"), ]
rownames(team_seasons_out) <- NULL

stopifnot("team-season player counts don't reconcile with total rows" =
            sum(team_seasons_out$players) == n_rows)
stopifnot("retained_next exceeds players somewhere" =
            all(team_seasons_out$retained_next <= team_seasons_out$players, na.rm = TRUE))
stopifnot("transfers_in exceeds players somewhere" =
            all(team_seasons_out$transfers_in <= team_seasons_out$players, na.rm = TRUE))
stopifnot("transfers_out exceeds players somewhere" =
            all(team_seasons_out$transfers_out <= team_seasons_out$players, na.rm = TRUE))
stopifnot("transfers_out must be null for the latest season" =
            all(is.na(team_seasons_out$transfers_out[team_seasons_out$season_idx == n_season - 1])))
stopifnot("transfers_in must be null for the first season" =
            all(is.na(team_seasons_out$transfers_in[team_seasons_out$season_idx == 0])))

wj(list(cols = names(team_seasons_out), rows = team_seasons_out),
   "site/data/team_seasons.json")

## ---------------------------------------------------------------- geography

cat("Building geography aggregates...\n")

us_w <- !is.na(w$country_clean) & w$country_clean == "USA"
us_state_rows <- w[us_w & !is.na(w$state_clean), ]
state_levels <- sort(names(STATE_INFO))
state_season <- lapply(state_levels, function(st) {
  as.integer(table(factor(us_state_rows$season_idx[us_state_rows$state_clean == st],
                          levels = 0:(n_season - 1))))
})
names(state_season) <- state_levels
stopifnot("state matrix doesn't reconcile with US rows that have a state" =
            sum(unlist(state_season)) == sum(us_w & !is.na(w$state_clean)))

# Per-division state matrix, bucketed by the row's own division (blank ->
# "Unknown"; "NAIA" passes through but is not offered in the UI). The overall
# state_season above stays the "all divisions" source, so overall figures
# never shift.
division_of <- ifelse(is.na(us_state_rows$division) | us_state_rows$division == "",
                      "Unknown", us_state_rows$division)
div_levels <- sort(unique(division_of))
state_season_division <- lapply(div_levels, function(dv) {
  keep <- division_of == dv
  # setNames() gives the inner list state-code keys for the client (lapply
  # over a bare character vector yields an unnamed list, and unnamed elements
  # serialize as a plain array).
  setNames(lapply(state_levels, function(st) {
    as.integer(table(factor(us_state_rows$season_idx[us_state_rows$state_clean == st & keep],
                            levels = 0:(n_season - 1))))
  }), state_levels)
})
names(state_season_division) <- div_levels
stopifnot("division state matrices don't reconcile with overall state rows" =
            sum(unlist(state_season_division)) == nrow(us_state_rows))

country_of <- ifelse(is.na(w$country_clean) | w$country_clean == "", "Unknown", w$country_clean)
country_levels <- sort(unique(country_of))
country_season <- lapply(country_levels, function(co) {
  as.integer(table(factor(w$season_idx[country_of == co], levels = 0:(n_season - 1))))
})
names(country_season) <- country_levels
stopifnot("country matrix doesn't reconcile with total rows" =
            sum(unlist(country_season)) == n_rows)

# Per-division country matrix over ALL countries; the client derives per-
# division leaders from it.
division_of_all <- ifelse(is.na(w$division) | w$division == "", "Unknown", w$division)
div_levels_all <- sort(unique(division_of_all))
country_season_division <- lapply(div_levels_all, function(dv) {
  keep <- division_of_all == dv
  # setNames() as above: keeps country-code keys intact in JSON.
  setNames(lapply(country_levels, function(co) {
    as.integer(table(factor(w$season_idx[country_of == co & keep],
                            levels = 0:(n_season - 1))))
  }), country_levels)
})
names(country_season_division) <- div_levels_all
stopifnot("division country matrices don't reconcile with total rows" =
            sum(unlist(country_season_division)) == n_rows)

# Hometown cities: US rows with a parsed state; keyed by (city, state).
us_h <- w[us_w & !is.na(w$state_clean) & !is.na(w$hometown_clean), ]
city <- vapply(us_h$hometown_clean, city_from, "", USE.NAMES = FALSE)
city_key <- paste(city, us_h$state_clean, sep = "\r")
city_f <- factor(city_key)
city_keys <- strsplit(levels(city_f), "\r", fixed = TRUE)
cities <- data.frame(
  city = vapply(city_keys, `[[`, "", 1),
  state = vapply(city_keys, `[[`, "", 2),
  players = as.integer(tapply(us_h$wbb_id, city_f, function(v) length(unique(v)))),
  rows = as.integer(table(city_f)),
  stringsAsFactors = FALSE
)
cities <- cities[cities$players >= CITY_MIN_PLAYERS, ]
cities <- cities[order(-cities$players, cities$city, method = "radix"), ]
rownames(cities) <- NULL
cat(sprintf("Cities: %d with >= %d distinct players (from %d distinct city+state combos)\n",
            nrow(cities), CITY_MIN_PLAYERS, length(levels(city_f))))

# Per-division city lists: threshold applied within each division, so a city
# that passes overall but not within one division drops from that division's
# view. Same [city, state, players, rows] shape as `cities`.
us_h_div <- ifelse(is.na(us_h$division) | us_h$division == "", "Unknown", us_h$division)
cities_division <- lapply(sort(unique(us_h_div)), function(dv) {
  hd <- us_h[us_h_div == dv, ]
  city_d <- vapply(hd$hometown_clean, city_from, "", USE.NAMES = FALSE)
  key_d <- paste(city_d, hd$state_clean, sep = "\r")
  f_d <- factor(key_d)
  out <- data.frame(
    city = vapply(strsplit(levels(f_d), "\r", fixed = TRUE), `[[`, "", 1),
    state = vapply(strsplit(levels(f_d), "\r", fixed = TRUE), `[[`, "", 2),
    players = as.integer(tapply(hd$wbb_id, f_d, function(v) length(unique(v)))),
    rows = as.integer(table(f_d)),
    stringsAsFactors = FALSE
  )
  out <- out[out$players >= CITY_MIN_PLAYERS, ]
  out <- out[order(-out$players, out$city, method = "radix"), ]
  rownames(out) <- NULL
  out
})
names(cities_division) <- sort(unique(us_h_div))

wj(list(
  state_season = state_season,
  country_season = country_season,
  season_totals = season_rows,
  cities = cities,
  state_season_division = state_season_division,
  country_season_division = country_season_division,
  cities_division = cities_division
), "site/data/geography.json")

## ---------------------------------------------------------------- transfers

cat("Building transfer aggregates...\n")

pairs <- paste0(seasons[-n_season], " → ", seasons[-1])
move_i <- which(is_move)
moves_per_pair <- as.integer(table(factor(wo$season_idx[move_i],
                                           levels = 0:(n_season - 2))))

team_edges <- aggregate(list(count = move_i),
                        by = list(pair = wo$season_idx[move_i],
                                   from = wo$ncaa_id[move_i],
                                   to = next_team[move_i]),
                        FUN = length)
team_edges <- team_edges[order(team_edges$pair, -team_edges$count,
                                team_edges$from, method = "radix"), ]
stopifnot("team edge counts don't reconcile with moves" =
            sum(team_edges$count) == length(move_i))

# Conference edges use each roster row's own conference for that season; moves
# with a blank conference on either side are skipped (counted and reported).
conf_next <- ifelse(same_next, c(wo$conference[-1], NA), NA)
conf_ok <- !is.na(wo$conference[move_i]) & !is.na(conf_next[move_i])
ci <- move_i[conf_ok]
conf_edges <- aggregate(list(count = ci),
                        by = list(pair = wo$season_idx[ci],
                                   from = wo$conference[ci],
                                   to = conf_next[ci]),
                        FUN = length)
conf_edges <- conf_edges[order(conf_edges$pair, -conf_edges$count,
                               conf_edges$from, method = "radix"), ]
cat(sprintf("Conference edges: %d moves skipped for blank conference\n",
            length(move_i) - sum(conf_edges$count)))

# Most traveled: players on 3+ distinct teams.
teams_per_player <- tapply(wo$ncaa_id, wo$wbb_id, function(v) length(unique(v)))
mt_ids <- names(teams_per_player)[teams_per_player >= 3]
most_traveled <- lapply(mt_ids, function(id) {
  px <- wo_split[[id]]
  list(
    id = id,
    name = players$canonical_name[players$wbb_id == id],
    n_teams = as.integer(teams_per_player[[id]]),
    stops = data.frame(idx = px$season_idx, team_id = px$ncaa_id,
                       team = px$team, stringsAsFactors = FALSE)
  )
})
most_traveled <- most_traveled[order(-vapply(most_traveled, function(m) m$n_teams, 1L),
                                     vapply(most_traveled, function(m) m$name, ""))]

# Feeders: canonical previous school with >= FEEDER_MIN_PLAYERS distinct
# players. Tier2a canonicalizes abbreviations on the ID layer, so "Utah
# State" and "Utah St." feeders now aggregate. is_team is category-driven:
# roster_team and four_year_other are four-year programs; juco / prep /
# international / other render gray. Category is blank ("") when the mapping
# row is still manual (canonical falls back to the raw lookup string there),
# so one all-blank group is a real state, not an all-NA error.
feeder_src <- w[!is.na(w$previous_school_canonical), ]
feeder_f <- factor(feeder_src$previous_school_canonical)
feeder_cat <- tapply(feeder_src$previous_school_category, feeder_f, function(v) {
  v <- v[!is.na(v)]
  if (length(v) == 0) return("")
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
            all(feeders$category %in% c("", "roster_team", "four_year_other",
                                        "juco", "prep", "international", "other")))
feeders <- feeders[feeders$players >= FEEDER_MIN_PLAYERS, ]
feeders <- feeders[order(-feeders$players, feeders$name, method = "radix"), ]
rownames(feeders) <- NULL

wj(list(
  pairs = pairs,
  moves_per_pair = moves_per_pair,
  team_edges = team_edges,
  conf_edges = conf_edges,
  most_traveled = most_traveled,
  feeders = feeders
), "site/data/transfers.json")

## ---------------------------------------------------------------- trends

cat("Building trend aggregates...\n")

class_of <- ifelse(is.na(w$year_clean) | w$year_clean == "", "Unknown", w$year_clean)
class_season <- lapply(YEAR_ORDER, function(cl) {
  as.integer(table(factor(w$season_idx[class_of == cl], levels = 0:(n_season - 1))))
})
names(class_season) <- YEAR_ORDER
stopifnot("class matrix doesn't reconcile with total rows" =
            sum(unlist(class_season)) == n_rows)

pos_of <- ifelse(is.na(w$primary_position) | w$primary_position == "", "Unknown", w$primary_position)
position_season <- lapply(POS_ORDER, function(p) {
  as.integer(table(factor(w$season_idx[pos_of == p], levels = 0:(n_season - 1))))
})
names(position_season) <- POS_ORDER
stopifnot("position matrix doesn't reconcile with total rows" =
            sum(unlist(position_season)) == n_rows)

height_quantiles <- lapply(0:(n_season - 1), function(i) {
  v <- w$total_inches[w$season_idx == i & w$height_ok]
  q <- round(quantile(v, c(0, 0.1, 0.25, 0.5, 0.75, 0.9, 1)), 1)
  list(n = length(v), min = q[1], p10 = q[2], p25 = q[3], p50 = q[4],
       p75 = q[5], p90 = q[6], max = q[7])
})
names(height_quantiles) <- seasons

# 2-inch bins over the plausible range; every season ships the full label set so
# the series align.
bin_labels <- c(paste0(seq(HEIGHT_MIN, HEIGHT_MAX - 2, by = 2), "-",
                       seq(HEIGHT_MIN + 1, HEIGHT_MAX - 1, by = 2)), "90+")
height_bins <- lapply(0:(n_season - 1), function(i) {
  v <- w$total_inches[w$season_idx == i & w$height_ok]
  cut_v <- cut(v, breaks = c(seq(HEIGHT_MIN, HEIGHT_MAX, by = 2), Inf),
               labels = bin_labels, right = FALSE, include.lowest = TRUE)
  data.frame(bin = bin_labels, n = as.integer(table(cut_v)),
             stringsAsFactors = FALSE)
})
names(height_bins) <- seasons

scale <- lapply(0:(n_season - 1), function(i) {
  sw <- w[w$season_idx == i, ]
  c(i, length(unique(sw$ncaa_id)), nrow(sw),
    round(nrow(sw) / length(unique(sw$ncaa_id)), 1),
    round(median(sw$total_inches[sw$height_ok]), 1))
})
scale <- do.call(rbind, scale)

wj(list(
  class_season = class_season,
  position_season = position_season,
  height_quantiles = height_quantiles,
  height_bins = height_bins,
  scale = scale,
  season_totals = season_rows
), "site/data/trends.json")

## ---------------------------------------------------------------- meta + players index

cat("Writing meta.json and players.json...\n")

sort_unique <- function(x) sort(unique(na.omit(blank_na(x))))
with_unknown <- function(x) c(sort_unique(x), "Unknown")

## Featured players for the home page: real multi-team careers that show
## what the cross-season wbb_id does. Deterministic: 2-3 distinct teams, at
## least 4 seasons, most recent season in Division I; ordered by seasons
## played, then teams, then name. Each entry carries its season/team path so
## the home page can draw a timeline without fetching a card shard.
ft_split <- split(wo[, c("season_idx", "ncaa_id", "team", "division")], wo$wbb_id)
ft_teams <- vapply(ft_split, function(px) length(unique(px$ncaa_id)), 1L)
ft_seas <- vapply(ft_split, nrow, 1L)
ft_lastdiv <- vapply(ft_split, function(px) {
  d <- px$division[nrow(px)]; if (is.na(d)) "" else d
}, "")
ft_ids <- names(ft_split)[ft_teams >= 2 & ft_teams <= 3 & ft_seas >= 4 & ft_lastdiv == "I"]
ft_names <- players$canonical_name[match(ft_ids, players$wbb_id)]
ft_ord <- order(-ft_seas[ft_ids], -ft_teams[ft_ids], ft_names, method = "radix")
ft_ids <- head(ft_ids[ft_ord], 5)
# The home page timeline is pinned to a chosen example (Duke -> Maryland).
FEATURED_PIN <- "wbb-022771"  # Oluchi Okananwa
stopifnot("pinned featured player missing from combined data" = FEATURED_PIN %in% names(ft_split))
ft_ids <- c(FEATURED_PIN, setdiff(ft_ids, FEATURED_PIN))
stopifnot("no featured players found for the home page" = length(ft_ids) >= 1)
featured <- lapply(ft_ids, function(id) {
  px <- ft_split[[id]]
  list(
    wbb_id = id,
    name = players$canonical_name[match(id, players$wbb_id)],
    seasons = data.frame(idx = px$season_idx, team = px$team, stringsAsFactors = FALSE)
  )
})

meta <- list(
  built = format(Sys.Date()),
  seasons = seasons,
  season_rows = season_rows,
  players = nrow(players),
  player_seasons = n_rows,
  teams = nrow(teams_out),
  countries = length(sort_unique(w$country_clean)),
  featured_players = featured,
  states = STATE_INFO,
  filter_options = list(
    year = YEAR_ORDER,
    position = with_unknown(w$position_clean),
    division = with_unknown(w$division),
    conference = with_unknown(w$conference),
    country = with_unknown(w$country_clean),
    state = with_unknown(w$state_clean)
  )
)
wj(meta, "site/data/meta.json")
wj(list(cols = names(players_out), rows = players_out), "site/data/players.json")

## ---------------------------------------------------------------- size report

cat("\nGenerated files:\n")
files <- list.files("site/data", recursive = TRUE, full.names = TRUE)
raw_sizes <- file.info(files)$size
gz_sizes <- vapply(files, function(f) {
  length(memCompress(readBin(f, "raw", file.info(f)$size), "gzip"))
}, 1L)
report <- data.frame(
  file = sub("^site/data/", "", files),
  raw_kb = round(raw_sizes / 1024),
  gzip_kb = round(gz_sizes / 1024),
  stringsAsFactors = FALSE
)
print(report, row.names = FALSE)
cat(sprintf("\nTotals: %.1f MB raw, %.1f MB gzip\n",
            sum(raw_sizes) / 1024^2, sum(gz_sizes) / 1024^2))

cat("\nDone.\n")