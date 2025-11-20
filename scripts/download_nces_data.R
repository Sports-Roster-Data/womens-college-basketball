# Download NCES Common Core of Data for High School Standardization
# This script downloads public school directory data from the Urban Institute Education Data API
# and NCES CCD for use in standardizing high school names

library(tidyverse)
library(httr)
library(jsonlite)

# Create data directory if it doesn't exist
dir.create("data/nces", recursive = TRUE, showWarnings = FALSE)

cat("Starting NCES data download...\n\n")

# ============================================================================
# METHOD 1: Urban Institute Education Data API
# ============================================================================
# This API provides easy access to CCD data with filtering capabilities
# Documentation: https://educationdata.urban.org/documentation/

download_urban_api <- function() {
  cat("Method 1: Attempting download via Urban Institute API...\n")

  # We'll download data for recent years to capture school information
  # School level codes: 1=Primary, 2=Middle, 3=High, 4=Other
  # We want high schools (3) and combined schools that include high school grades

  years <- c(2023, 2022, 2021)  # Most recent available years
  all_schools <- tibble()

  for (year in years) {
    cat(sprintf("  Downloading %d data...\n", year))

    # API endpoint for CCD school directory
    base_url <- sprintf("https://educationdata.urban.org/api/v1/schools/ccd/directory/%d/", year)

    # We'll need to paginate through results
    page <- 0
    year_schools <- tibble()

    repeat {
      # Build URL with pagination
      url <- paste0(base_url, "?page=", page)

      tryCatch({
        response <- GET(url)

        if (status_code(response) != 200) {
          cat(sprintf("    Error: HTTP %d\n", status_code(response)))
          break
        }

        data <- content(response, as = "text") %>% fromJSON()

        # Check if we got results
        if (is.null(data$results) || length(data$results) == 0) {
          break
        }

        # Append to year data
        page_data <- as_tibble(data$results)
        year_schools <- bind_rows(year_schools, page_data)

        cat(sprintf("    Page %d: %d schools (total: %d)\n",
                    page, nrow(page_data), nrow(year_schools)))

        # Check if there's a next page
        if (is.null(data$`next`) || data$`next` == "") {
          break
        }

        page <- page + 1

        # Rate limiting - be nice to the API
        Sys.sleep(0.5)

      }, error = function(e) {
        cat(sprintf("    Error on page %d: %s\n", page, e$message))
        break
      })
    }

    if (nrow(year_schools) > 0) {
      year_schools$data_year <- year
      all_schools <- bind_rows(all_schools, year_schools)
      cat(sprintf("  Year %d complete: %d schools\n", year, nrow(year_schools)))
    }
  }

  if (nrow(all_schools) > 0) {
    # Save raw data
    write_csv(all_schools, "data/nces/urban_api_raw.csv")
    cat(sprintf("\nDownloaded %d school records from Urban Institute API\n", nrow(all_schools)))
    return(all_schools)
  } else {
    cat("\nFailed to download from Urban Institute API\n")
    return(NULL)
  }
}

# ============================================================================
# METHOD 2: Direct NCES Download (manual backup)
# ============================================================================
# If API fails, provide instructions for manual download

print_manual_instructions <- function() {
  cat("\n============================================================\n")
  cat("MANUAL DOWNLOAD INSTRUCTIONS\n")
  cat("============================================================\n\n")
  cat("If automatic download fails, please manually download:\n\n")
  cat("1. Go to: https://nces.ed.gov/ccd/files.asp\n")
  cat("2. Find '2023-24 Public Elementary/Secondary School Universe Survey'\n")
  cat("3. Download the CSV file (usually named ccd_sch_*.csv)\n")
  cat("4. Save it to: data/nces/nces_schools_manual.csv\n\n")
  cat("Alternative:\n")
  cat("1. Go to: https://nces.ed.gov/ccd/pubschuniv.asp\n")
  cat("2. Download the most recent school universe survey data\n")
  cat("3. Extract and save the school-level CSV to data/nces/\n\n")
  cat("============================================================\n\n")
}

# ============================================================================
# Filter for High Schools
# ============================================================================

filter_high_schools <- function(schools_data) {
  cat("\nFiltering for high schools...\n")

  # Identify columns that might indicate school level
  # Different data sources use different column names
  level_cols <- c("school_level", "level", "lowest_grade", "highest_grade")
  grade_cols <- c("lowest_grade", "highest_grade", "lowest_grade_offered",
                  "highest_grade_offered")

  # Filter criteria:
  # - School level = 3 (High) or 4 (Other - might include alternative high schools)
  # - OR highest grade >= 9 (includes high school grades)
  # - School status = Open/Operating (not closed)

  hs_data <- schools_data %>%
    filter(
      # Filter for open schools
      if("school_status" %in% names(.)) school_status == 1 else TRUE,
      # Filter for schools with high school grades
      if("school_level" %in% names(.)) {
        school_level %in% c(3, 4) | is.na(school_level)
      } else {
        TRUE
      },
      if("highest_grade" %in% names(.)) {
        highest_grade >= 9 | is.na(highest_grade)
      } else if("highest_grade_offered" %in% names(.)) {
        highest_grade_offered >= 9 | is.na(highest_grade_offered)
      } else {
        TRUE
      }
    )

  cat(sprintf("Filtered to %d high schools from %d total schools\n",
              nrow(hs_data), nrow(schools_data)))

  return(hs_data)
}

# ============================================================================
# Standardize Column Names
# ============================================================================

standardize_columns <- function(schools_data) {
  cat("\nStandardizing column names...\n")

  # Map common column name variations to standard names
  column_mapping <- c(
    "ncessch" = "nces_school_id",
    "ncessch_num" = "nces_school_id",
    "school_name" = "school_name",
    "schnam" = "school_name",
    "sch_name" = "school_name",
    "lea_name" = "district_name",
    "leanm" = "district_name",
    "leaid" = "nces_district_id",
    "state_location" = "state",
    "state_leaid" = "state",
    "lstate" = "state",
    "lcity" = "city",
    "city_location" = "city",
    "lstree" = "street",
    "location_address" = "street",
    "lzip" = "zip",
    "phone" = "phone",
    "school_level" = "school_level",
    "lowest_grade" = "lowest_grade",
    "highest_grade" = "highest_grade"
  )

  # Rename columns that exist
  for (old_name in names(column_mapping)) {
    new_name <- column_mapping[[old_name]]
    if (old_name %in% names(schools_data) && !new_name %in% names(schools_data)) {
      schools_data <- schools_data %>%
        rename(!!new_name := !!old_name)
    }
  }

  cat("Column standardization complete\n")

  return(schools_data)
}

# ============================================================================
# Main Execution
# ============================================================================

# Try Urban Institute API first
schools_data <- download_urban_api()

# If API download worked, process the data
if (!is.null(schools_data) && nrow(schools_data) > 0) {

  # Standardize column names
  schools_data <- standardize_columns(schools_data)

  # Filter for high schools
  hs_data <- filter_high_schools(schools_data)

  # Save processed high school data
  write_csv(hs_data, "data/nces/high_schools_all_years.csv")

  # Also create a deduplicated version (most recent data per school)
  hs_dedup <- hs_data %>%
    arrange(nces_school_id, desc(data_year)) %>%
    distinct(nces_school_id, .keep_all = TRUE)

  write_csv(hs_dedup, "data/nces/high_schools_current.csv")

  # Print summary statistics
  cat("\n============================================================\n")
  cat("DOWNLOAD COMPLETE\n")
  cat("============================================================\n\n")
  cat(sprintf("Total high schools: %d\n", nrow(hs_dedup)))
  cat(sprintf("States covered: %d\n", n_distinct(hs_dedup$state)))
  cat("\nFiles created:\n")
  cat("  - data/nces/urban_api_raw.csv (raw API data)\n")
  cat("  - data/nces/high_schools_all_years.csv (all years)\n")
  cat("  - data/nces/high_schools_current.csv (deduplicated)\n\n")

  # Show sample of data
  cat("Sample of downloaded data:\n")
  hs_dedup %>%
    select(any_of(c("nces_school_id", "school_name", "city", "state"))) %>%
    head(10) %>%
    print()

} else {
  # API failed, show manual instructions
  print_manual_instructions()
  cat("\nScript will continue with next steps once data is available.\n")
}

cat("\nNECS data download script complete.\n")
