#!/usr/bin/env python3
"""
Build High School Standardization Mapping
This script creates the canonical mapping for high school names
"""

import pandas as pd
import re
from pathlib import Path
from collections import defaultdict

DATA_DIR = Path("data")

def select_canonical_name(group_df):
    """
    Given a group of duplicate high school names, select the canonical one.

    Strategy (in order of preference):
    1. Most common version (highest player_count)
    2. If tie, prefer "High School" over "HS" or "H.S."
    3. If still tie, prefer version without periods
    4. If still tie, take first alphabetically
    """

    # Start with most common
    group_df = group_df.sort_values('player_count', ascending=False)

    max_count = group_df.iloc[0]['player_count']
    top_candidates = group_df[group_df['player_count'] == max_count].copy()

    if len(top_candidates) == 1:
        return top_candidates.iloc[0]

    # Prefer "High School" suffix
    def score_name(name):
        score = 0
        if 'High School' in str(name):
            score += 100
        elif ' HS' in str(name) and 'H.S.' not in str(name):
            score += 50
        # Deduct points for periods
        score -= str(name).count('.') * 10
        return score

    top_candidates['name_score'] = top_candidates['high_school_original'].apply(score_name)
    top_candidates = top_candidates.sort_values(['name_score', 'high_school_original'],
                                                  ascending=[False, True])

    return top_candidates.iloc[0]


def create_duplicate_mapping(duplicates_file):
    """
    Create mapping from duplicate variations to canonical names.
    """
    print("Creating duplicate mapping...")

    df = pd.read_csv(duplicates_file)

    # Group by normalized name and state
    mappings = []

    for (normalized, state), group in df.groupby(['high_school_normalized', 'state']):
        if len(group) == 1:
            continue

        # Select canonical name
        canonical = select_canonical_name(group)

        # Create mappings for all variations
        for _, row in group.iterrows():
            mappings.append({
                'high_school_original': row['high_school_original'],
                'high_school_standardized': canonical['high_school_original'],
                'state': state,
                'confidence': 'high_auto',
                'source': 'duplicate_resolution',
                'nces_id': None,
                'player_count': row['player_count'],
                'canonical_player_count': canonical['player_count']
            })

    mapping_df = pd.DataFrame(mappings)

    print(f"Created {len(mapping_df)} mappings from duplicate resolution")
    print(f"Reduced to {mapping_df['high_school_standardized'].nunique()} canonical names")

    return mapping_df


def create_prep_school_mapping():
    """
    Create manual curated mapping for well-known prep schools and basketball academies.
    These schools won't be in NCES public school database.
    """
    print("\nCreating prep school manual mapping...")

    # Well-known basketball prep schools and academies
    prep_schools = [
        {'original': 'IMG Academy', 'standardized': 'IMG Academy', 'city': 'Bradenton', 'state': 'FL'},
        {'original': 'Montverde Academy', 'standardized': 'Montverde Academy', 'city': 'Montverde', 'state': 'FL'},
        {'original': 'Oak Hill Academy', 'standardized': 'Oak Hill Academy', 'city': 'Mouth of Wilson', 'state': 'VA'},
        {'original': 'Brewster Academy', 'standardized': 'Brewster Academy', 'city': 'Wolfeboro', 'state': 'NH'},
        {'original': 'Prolific Prep', 'standardized': 'Prolific Prep', 'city': 'Napa', 'state': 'CA'},
        {'original': 'Spire Academy', 'standardized': 'Spire Institute', 'city': 'Geneva', 'state': 'OH'},
        {'original': 'Spire Institute', 'standardized': 'Spire Institute', 'city': 'Geneva', 'state': 'OH'},
        {'original': 'Link Academy', 'standardized': 'Link Academy', 'city': 'Branson', 'state': 'MO'},
        {'original': 'La Lumiere School', 'standardized': 'La Lumiere School', 'city': 'La Porte', 'state': 'IN'},
        {'original': 'New Hope Academy', 'standardized': 'New Hope Christian Academy', 'city': 'Landover Hills', 'state': 'MD'},
        {'original': 'New Hope Christian Academy', 'standardized': 'New Hope Christian Academy', 'city': 'Landover Hills', 'state': 'MD'},
        {'original': 'Hamilton Heights Christian Academy', 'standardized': 'Hamilton Heights Christian Academy', 'city': 'Chattanooga', 'state': 'TN'},
        {'original': 'Northfield Mount Hermon', 'standardized': 'Northfield Mount Hermon School', 'city': 'Gill', 'state': 'MA'},
        {'original': 'Northfield Mount Hermon School', 'standardized': 'Northfield Mount Hermon School', 'city': 'Gill', 'state': 'MA'},
        {'original': 'South Kent School', 'standardized': 'South Kent School', 'city': 'South Kent', 'state': 'CT'},
        {'original': 'Wilbraham & Monson Academy', 'standardized': 'Wilbraham & Monson Academy', 'city': 'Wilbraham', 'state': 'MA'},
        {'original': 'Westtown School', 'standardized': 'Westtown School', 'city': 'West Chester', 'state': 'PA'},
        {'original': 'Worcester Academy', 'standardized': 'Worcester Academy', 'city': 'Worcester', 'state': 'MA'},
        {'original': 'The Governor\'s Academy', 'standardized': 'The Governor\'s Academy', 'city': 'Byfield', 'state': 'MA'},
        {'original': 'Governors Academy', 'standardized': 'The Governor\'s Academy', 'city': 'Byfield', 'state': 'MA'},
        {'original': 'Blair Academy', 'standardized': 'Blair Academy', 'city': 'Blairstown', 'state': 'NJ'},
        {'original': 'Putnam Science Academy', 'standardized': 'Putnam Science Academy', 'city': 'Putnam', 'state': 'CT'},
        {'original': 'St. Andrew\'s School', 'standardized': 'St. Andrew\'s School', 'city': 'Barrington', 'state': 'RI'},
        {'original': 'Tabor Academy', 'standardized': 'Tabor Academy', 'city': 'Marion', 'state': 'MA'},
        {'original': 'Choate Rosemary Hall', 'standardized': 'Choate Rosemary Hall', 'city': 'Wallingford', 'state': 'CT'},
    ]

    mapping_records = []
    for school in prep_schools:
        mapping_records.append({
            'high_school_original': school['original'],
            'high_school_standardized': school['standardized'],
            'state': school['state'],
            'confidence': 'high_manual',
            'source': 'prep_school_curated',
            'nces_id': None,
            'city': school.get('city', ''),
            'notes': 'Manually curated prep/basketball academy'
        })

    df = pd.DataFrame(mapping_records)
    print(f"Created {len(df)} manual prep school mappings")

    return df


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

    # Create duplicate mapping
    duplicate_mapping = create_duplicate_mapping(duplicates_file)

    # Create prep school mapping
    prep_mapping = create_prep_school_mapping()

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
