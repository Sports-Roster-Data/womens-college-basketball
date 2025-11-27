# Apply High School Standardization
# This script applies the high school mapping to roster data
# To be integrated into cleaning.Rmd

library(tidyverse)

# Load high school mapping
apply_hs_standardization <- function(roster_df) {
  cat("Applying high school standardization...\n")

  # Load mapping table
  mapping_file <- "data/high_school_mapping.csv"

  if (!file.exists(mapping_file)) {
    cat("Warning: High school mapping file not found:", mapping_file, "\n")
    cat("Run scripts/build_hs_mapping.py to create it\n")
    roster_df$high_school_standardized <- roster_df$high_school
    roster_df$hs_confidence <- "none"
    return(roster_df)
  }

  hs_mapping <- read_csv(mapping_file, show_col_types = FALSE) %>%
    select(high_school_original, high_school_standardized, confidence, source)

  cat(sprintf("  Loaded %d high school mappings\n", nrow(hs_mapping)))

  # Apply mapping
  roster_df <- roster_df %>%
    left_join(
      hs_mapping,
      by = c("high_school" = "high_school_original")
    ) %>%
    mutate(
      # Use standardized name if available, otherwise keep original
      high_school_standardized = coalesce(high_school_standardized, high_school),
      # Set confidence level
      hs_confidence = case_when(
        !is.na(confidence) ~ confidence,
        country_clean != "USA" ~ "international",
        is.na(high_school) ~ "missing",
        TRUE ~ "unstandardized"
      ),
      # Track if standardization was applied
      hs_was_standardized = high_school != high_school_standardized &
                           !is.na(high_school_standardized)
    ) %>%
    select(-confidence, -source)

  # Report statistics
  total_hs <- sum(!is.na(roster_df$high_school))
  standardized <- sum(roster_df$hs_was_standardized, na.rm = TRUE)

  cat(sprintf("  Total records with high schools: %d\n", total_hs))
  cat(sprintf("  Standardized: %d (%.1f%%)\n",
              standardized,
              standardized / total_hs * 100))

  cat("\n  Confidence breakdown:\n")
  print(table(roster_df$hs_confidence))

  # Report on unique schools
  unique_original <- n_distinct(roster_df$high_school[!is.na(roster_df$high_school)])
  unique_standardized <- n_distinct(roster_df$high_school_standardized[!is.na(roster_df$high_school_standardized)])

  cat(sprintf("\n  Unique schools (original): %d\n", unique_original))
  cat(sprintf("  Unique schools (standardized): %d\n", unique_standardized))
  cat(sprintf("  Deduplication: %.1f%%\n",
              (unique_original - unique_standardized) / unique_original * 100))

  return(roster_df)
}

# Example usage (for testing this script standalone):
# wbb_rosters <- read_csv("wbb_rosters_2024_25.csv")
# wbb_rosters <- apply_hs_standardization(wbb_rosters)
# write_csv(wbb_rosters, "wbb_rosters_2024_25_standardized.csv")

cat("High school standardization functions loaded\n")
cat("Use: roster_data <- apply_hs_standardization(roster_data)\n")
