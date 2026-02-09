#!/usr/bin/env python3

import json
import sys
from pathlib import Path
from datetime import datetime

KNOWN_SUPPLEMENTS = {
    "The Guide",
    "The Form",
    "Spectrum",
    "Traveller",
    "Sydney Inside Out",
    "Melbourne Inside Out",
    "Domayne",
    "Harvey Norman",
    "Harvey Norman Furniture",
    "Harvey Norman Computers",
    "Good Weekend",
    "Sunday Life",
    "Domain",
    "Drive",
    "International Women's Day",
    "Where to Vote",
    "Good Food",
    "Australian Made",
    "HSC Study Guide",
    "Sunday Traveller",
    "Trading Room",
    "My Career",
}

START_SECTIONS = {"Front Cover", "Front Page"}
END_SECTIONS = {"Back Cover", "Back Page", "Sport Cover"}

POST_MAIN_MAIN_SECTIONS = {"Business", "Money"}
PUZZLE_SECTIONS = {"Puzzles", "puzzles"}

KNOWN_MAIN_SECTIONS = {
    *START_SECTIONS,
    *END_SECTIONS,
    "News",
    "News Review",
    "World",
    "Opinion",
    "Business",
    "Arts",
    "Good Food",
    "Television",
    "Community Voice",
    *PUZZLE_SECTIONS,
    "Weather",
    "Sport",
    "Tributes",
    "Tributes & Celebrations",
    "Trading Room",
    "Extra",
    "Money",
    "Obituaries",
    "Life",
    "Classifieds",
    "Sunday Superquiz",
    "Advertising Feature",
    "Racing",
    "Notices",
    "Letters",
    "Summer in Sydney",
    "Sunday Scene",
    "Sydney Scene",
}

main_section_pages = {}   # section -> count
main_section_order = []   # preserve order

def fatal(msg):
    print(f"ERROR {msg}")
    sys.exit(1)


def pad(n: int) -> str:
    return f"{n:03d}"


def ordinal(n: int) -> str:
    if 11 <= n % 100 <= 13:
        return f"{n}th"
    return f"{n}{['th','st','nd','rd','th'][min(n % 10, 4)]}"


def format_date_from_path(path: Path) -> str:
    try:
        year, month, day = map(int, path.stem.split("-"))
        dt = datetime(year, month, day)
    except Exception:
        fatal("Path must be in /path/to/file/CCYY-MM-DD.json format")

    return f"{dt.strftime('%A')} {ordinal(dt.day)} {dt.strftime('%B %Y')}"


def main():
    if len(sys.argv) != 2:
        fatal("Usage: ConvertJSON.py </path/to/CCYY-MM-DD.json>")

    path = Path(sys.argv[1])
    date_line = format_date_from_path(path)
    the_year = path.stem[:4]

    with path.open("r", encoding="utf-8") as f:
        data = json.load(f)

    sections = [(e["section"], [int(p) for p in e["pages"]]) for e in data]

    supplements = {}
    warnings = []
    main_pages = []
    puzzles = []

    front_seen = False
    main_end_seen = False

    for section, pages in sections:
        # --- BEFORE Front Cover: ad-hoc wraps ---
        if not front_seen:
            if section in START_SECTIONS:
                front_seen = True
            else:
                supplements[section] = pages
                continue

        # --- MAIN edition ---
        if front_seen and not main_end_seen:
            main_pages.extend(pages)

            if section not in main_section_pages:
                main_section_pages[section] = 0
                main_section_order.append(section)

            main_section_pages[section] += len(pages)

            if section not in KNOWN_MAIN_SECTIONS:
                warnings.append(f"Unknown section detected inside MAIN: {section}")

            if section in PUZZLE_SECTIONS:
                puzzles = pages

            if section in END_SECTIONS:
                main_end_seen = True
            continue

        # --- Saturday exception ---
        if (main_end_seen and section in POST_MAIN_MAIN_SECTIONS and pages and min(pages) == max(main_pages) + 1):
            main_pages.extend(pages)

            if section not in main_section_pages:
                main_section_pages[section] = 0
                main_section_order.append(section)

            main_section_pages[section] += len(pages)

            continue

        # --- After MAIN: always supplement ---
        supplements[section] = pages

        if section not in KNOWN_SUPPLEMENTS and not (the_year in section or ' Wrap' in section or ' Liftout' in section or 'Feature' in section or " Guide" in section):
            warnings.append(f"Unknown section outside MAIN: {section}")

    if not front_seen:
        fatal("No 'Front Cover' found")

    if not main_end_seen:
        fatal("No 'Back Cover' or 'Sport Cover' found")

    main_pages = sorted(set(main_pages))

    # ---- stdout output ----
    print(f"DATE {date_line}")

    section_list = ", ".join(f"{name}({main_section_pages[name]})" for name in main_section_order)
    print(f"MAIN {pad(main_pages[0])} {pad(main_pages[-1])} ({section_list})")

    if puzzles:
        print(f"PUZZLES {pad(puzzles[0])} {pad(puzzles[-1])}")

    for name, pages in supplements.items():
        if name == "Melbourne Inside Out":
            name = "Sydney Inside Out"
        pages = sorted(pages)
        print(f'SUPPLEMENT "{name}" {pad(pages[0])} {pad(pages[-1])}')

    for w in warnings:
        print(f"WARNING {w}")


if __name__ == "__main__":
    main()
