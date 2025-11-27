#!/usr/bin/env python3
"""
Build High School Standardization Mapping
This script creates the canonical mapping for high school names
"""

import pandas as pd
from pathlib import Path
from hs_standardization import (
    create_duplicate_mapping,
    create_prep_school_mapping
)

DATA_DIR = Path("data")


def analyze_mapping_coverage(mapping_df, unique_schools_file):
    """
    Analyze what percentage of schools are covered by the mapping.
    """
    print("\nAnalyzing mapping coverage...")

    unique_schools = pd.read_csv(unique_schools_file)

    # US schools only
    us_schools = unique_schools[unique_schools['country'] == 'USA']

    # How many schools are mapped?
    mapped = us_schools['high_school_original'].isin(mapping_df['high_school_original'])

    print(f"\nCoverage statistics:")
    print(f"  Total US schools: {len(us_schools)}")
    print(f"  Mapped schools: {mapped.sum()}")
    print(f"  Coverage: {mapped.sum() / len(us_schools) * 100:.1f}%")

    # How many players are covered?
    total_players = us_schools['player_count'].sum()
    mapped_players = us_schools[mapped]['player_count'].sum()

    print(f"\n  Total US player-seasons: {total_players}")
    print(f"  Mapped player-seasons: {mapped_players}")
    print(f"  Player coverage: {mapped_players / total_players * 100:.1f}%")

    # What's unmapped?
    unmapped = us_schools[~mapped].sort_values('player_count', ascending=False)

    print(f"\n  Unmapped schools: {len(unmapped)}")
    print(f"\nTop 20 unmapped schools (by player count):")
    print(unmapped[['high_school_original', 'state', 'player_count', 'school_type']].head(20).to_string(index=False))

    return unmapped


def main():
    """Main execution"""
    print("Building High School Standardization Mapping\n")
    print("="*60)

    # Load duplicate data
    duplicates_file = DATA_DIR / "high_schools_potential_duplicates.csv"
    if not duplicates_file.exists():
        print(f"Error: {duplicates_file} not found")
        print("Run normalize_high_schools.py first")
        return

    print("Creating duplicate mapping...")
    duplicates_df = pd.read_csv(duplicates_file)

    # Create duplicate mapping using utilities function
    duplicate_mapping = create_duplicate_mapping(duplicates_df, group_by_state=True)

    # Add extra columns for compatibility with existing workflow
    if 'nces_id' not in duplicate_mapping.columns:
        duplicate_mapping['nces_id'] = None

    print(f"Created {len(duplicate_mapping)} mappings from duplicate resolution")
    print(f"Reduced to {duplicate_mapping['high_school_standardized'].nunique()} canonical names")

    # Create prep school mapping
    print("\nCreating prep school manual mapping...")
    prep_mapping = create_prep_school_mapping()
    print(f"Created {len(prep_mapping)} manual prep school mappings")

    # Add extra columns for compatibility with existing workflow
    if 'nces_id' not in prep_mapping.columns:
        prep_mapping['nces_id'] = None

    # Combine mappings
    all_mappings = pd.concat([duplicate_mapping, prep_mapping], ignore_index=True)

    # Remove exact duplicates (where original == standardized)
    # Actually, keep them for completeness
    # all_mappings = all_mappings[
    #     all_mappings['high_school_original'] != all_mappings['high_school_standardized']
    # ]

    # Save mapping
    mapping_file = DATA_DIR / "high_school_mapping.csv"
    all_mappings.to_csv(mapping_file, index=False)

    print(f"\n" + "="*60)
    print("MAPPING CREATED")
    print("="*60)
    print(f"\nTotal mappings: {len(all_mappings)}")
    print(f"Canonical schools: {all_mappings['high_school_standardized'].nunique()}")
    print(f"\nSaved to: {mapping_file}")

    # Analyze coverage
    unique_schools_file = DATA_DIR / "high_schools_unique.csv"
    if unique_schools_file.exists():
        unmapped = analyze_mapping_coverage(all_mappings, unique_schools_file)

        # Save unmapped schools for future work
        unmapped_file = DATA_DIR / "high_schools_unmapped.csv"
        unmapped.to_csv(unmapped_file, index=False)
        print(f"\nSaved unmapped schools to: {unmapped_file}")

    print("\n" + "="*60)
    print("Next steps:")
    print("="*60)
    print("1. Review mapping in data/high_school_mapping.csv")
    print("2. Obtain NCES data to map remaining US public schools")
    print("3. Manually curate top unmapped schools")
    print("4. Integrate mapping into cleaning pipeline")


if __name__ == "__main__":
    main()
