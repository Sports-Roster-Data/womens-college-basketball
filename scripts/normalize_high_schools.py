#!/usr/bin/env python3
"""
High School Name Normalization and Matching
This script creates normalized versions of high school names for matching
and builds the foundation for standardization
"""

import pandas as pd
from pathlib import Path
from hs_standardization import (
    normalize_hs_name,
    extract_disambiguator,
    categorize_school_type,
    is_likely_common_name
)

# Configuration
DATA_DIR = Path("data")
DATA_DIR.mkdir(exist_ok=True)


def analyze_high_schools(csv_files):
    """
    Extract and analyze all high schools from roster CSV files.

    Args:
        csv_files: List of paths to roster CSV files

    Returns:
        DataFrame with unique high schools and analysis
    """
    print("Extracting high schools from roster files...")

    all_schools = []

    for csv_file in csv_files:
        print(f"  Reading {csv_file.name}...")
        try:
            df = pd.read_csv(csv_file, low_memory=False)

            # Extract high school data
            if 'high_school' in df.columns:
                schools = df[['high_school', 'homestate', 'country_clean']].copy()
                schools = schools[schools['high_school'].notna()]
                schools['source_file'] = csv_file.name
                all_schools.append(schools)
        except Exception as e:
            print(f"    Error reading {csv_file}: {e}")

    if not all_schools:
        print("No high school data found!")
        return None

    # Combine all schools
    combined = pd.concat(all_schools, ignore_index=True)
    print(f"\nTotal high school entries: {len(combined)}")

    # Create unique schools with metadata
    print("Analyzing unique schools...")

    unique_schools = combined.groupby('high_school').agg({
        'homestate': lambda x: x.mode()[0] if len(x.mode()) > 0 else x.iloc[0],
        'country_clean': lambda x: x.mode()[0] if len(x.mode()) > 0 else x.iloc[0],
        'source_file': 'count'  # Number of occurrences
    }).reset_index()

    unique_schools.columns = ['high_school_original', 'state', 'country', 'player_count']

    # Add normalization
    unique_schools['high_school_normalized'] = unique_schools['high_school_original'].apply(normalize_hs_name)
    unique_schools['disambiguator'] = unique_schools['high_school_original'].apply(extract_disambiguator)
    unique_schools['school_type'] = unique_schools['high_school_original'].apply(categorize_school_type)
    unique_schools['is_common_name'] = unique_schools['high_school_normalized'].apply(is_likely_common_name)

    # Sort by frequency
    unique_schools = unique_schools.sort_values('player_count', ascending=False)

    print(f"Unique high schools: {len(unique_schools)}")

    return unique_schools


def identify_duplicates(schools_df):
    """
    Identify potential duplicates based on normalized names.

    Returns:
        DataFrame of schools that may be duplicates
    """
    print("\nIdentifying potential duplicates...")

    # Group by normalized name and state (US schools only)
    us_schools = schools_df[schools_df['country'] == 'USA'].copy()

    duplicates = us_schools.groupby(['high_school_normalized', 'state']).filter(
        lambda x: len(x) > 1
    )

    if len(duplicates) > 0:
        duplicates = duplicates.sort_values(['high_school_normalized', 'state', 'player_count'],
                                             ascending=[True, True, False])
        print(f"Found {len(duplicates)} entries that may be duplicates")
        print(f"({duplicates['high_school_normalized'].nunique()} unique normalized names)")
    else:
        print("No duplicates found")

    return duplicates


def main():
    """Main execution"""
    print("High School Name Normalization\n")
    print("="*60)

    # Find all roster CSV files
    roster_files = sorted(Path(".").glob("wbb_rosters_*.csv"))

    if not roster_files:
        print("No roster files found! Looking in current directory for wbb_rosters_*.csv")
        return

    print(f"Found {len(roster_files)} roster files:")
    for f in roster_files:
        print(f"  - {f.name}")
    print()

    # Analyze high schools
    schools_df = analyze_high_schools(roster_files)

    if schools_df is None:
        return

    # Save full analysis
    output_file = DATA_DIR / "high_schools_unique.csv"
    schools_df.to_csv(output_file, index=False)
    print(f"\nSaved unique schools: {output_file}")

    # Identify duplicates
    duplicates = identify_duplicates(schools_df)

    if len(duplicates) > 0:
        dup_file = DATA_DIR / "high_schools_potential_duplicates.csv"
        duplicates.to_csv(dup_file, index=False)
        print(f"Saved potential duplicates: {dup_file}")

    # Create summary statistics
    print("\n" + "="*60)
    print("SUMMARY STATISTICS")
    print("="*60)

    print(f"\nTotal unique high schools: {len(schools_df)}")
    print(f"Total normalized names: {schools_df['high_school_normalized'].nunique()}")
    print(f"Potential duplicates: {len(duplicates)}")

    print("\nBy Country:")
    print(schools_df.groupby('country')['high_school_original'].count().sort_values(ascending=False).head(10))

    print("\nBy School Type:")
    print(schools_df['school_type'].value_counts())

    print("\nSchools with common/ambiguous names:")
    print(f"{schools_df['is_common_name'].sum()} schools")

    print("\nTop 20 Most Common High Schools:")
    print(schools_df[['high_school_original', 'state', 'player_count']].head(20).to_string(index=False))

    # Save schools by type for manual curation
    print("\n" + "="*60)
    print("Creating files for manual curation...")
    print("="*60)

    # Prep schools (need manual curation)
    prep_schools = schools_df[schools_df['school_type'] == 'prep']
    prep_file = DATA_DIR / "high_schools_prep_academies.csv"
    prep_schools.to_csv(prep_file, index=False)
    print(f"\nPrep schools ({len(prep_schools)}): {prep_file}")

    # International schools
    intl_schools = schools_df[schools_df['country'] != 'USA']
    intl_file = DATA_DIR / "high_schools_international.csv"
    intl_schools.to_csv(intl_file, index=False)
    print(f"International schools ({len(intl_schools)}): {intl_file}")

    # US public schools (ready for NCES matching)
    us_public = schools_df[(schools_df['country'] == 'USA') &
                           (schools_df['school_type'].isin(['public', 'unknown']))]
    us_file = DATA_DIR / "high_schools_us_for_matching.csv"
    us_public.to_csv(us_file, index=False)
    print(f"US schools for NCES matching ({len(us_public)}): {us_file}")

    print("\n" + "="*60)
    print("Normalization complete!")
    print("="*60)
    print("\nNext steps:")
    print("1. Review potential duplicates in data/high_schools_potential_duplicates.csv")
    print("2. Manually curate prep schools in data/high_schools_prep_academies.csv")
    print("3. Obtain NCES data to match against data/high_schools_us_for_matching.csv")
    print("4. Create final standardization mapping")


if __name__ == "__main__":
    main()
