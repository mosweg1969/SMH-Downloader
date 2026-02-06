#!/usr/bin/env bash
set -euo pipefail

# --- CONFIG ---
BASE_DIR="/var/lib/smh-downloader"
VENV="$BASE_DIR/.venv"
PY_CONTENTS_SCRIPT="$BASE_DIR/SMH-Contents-Retrieve.py"
PY_DOWNLOAD_SCRIPT="$BASE_DIR/SMH-Page-Downloader.py"

#!/usr/bin/env bash
set -euo pipefail

# ---------------- CONFIG ----------------
BASE_DIR="/var/lib/smh-downloader"
VENV="$BASE_DIR/.venv"
PY_SCRIPT="$BASE_DIR/SMH-Downloader.py"

LOG_DIR="/mnt/storage/logs/smh-downloader"

# ---------------- DEFAULTS ----------------
OVERRIDE_DATE=""
CROSSWORDS_ONLY=0
CONTENTS_ONLY=0
RECIPIENT_FILE=""

# ---------------- HELP ----------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -date YYYY-MM-DD           Override today\'s date
  --crosswords-only          Only download crossword pages
  --contents-only            Only download the contents JSON file
  -mail-to recipient_file    Mail downloaded content to recepients specified in recipient_file
  --help                     Show this help

Examples:
  $0 --contents-only                        # Downloads contents for current day edition only
  $0 -date 2026-01-27                       # Downloads the edition for 27th Jan 26 and saves the whole edition 
  $0 -date 2026-01-27 --crosswords-only     # Downloasd the puzzle pages for 27th Jan 26 edition only
  $0 -mail-to user@email.address            # Download and mail current edition to user
EOF
    exit 0
}

# ---------------- PARSE ARGUMENTS ----------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -date)
            if [[ -z "${2:-}" ]]; then
                echo "❌ ERROR: --date requires YYYY-MM-DD" >&2
                exit 1
            fi
            OVERRIDE_DATE="$2"
            shift 2
            ;;
        --crosswords-only)
            CROSSWORDS_ONLY=1
            shift
            ;;
        --contents-only)
            CONTENTS_ONLY=1
            shift
            ;;
        -mail-to)
            if [[ -z "${2:-}" ]]; then
                echo "❌ ERROR: -mail-to requires a recipient file" >&2
                exit 1
            fi
            RECIPIENT_FILE="$2"
            shift 2
	    ;;
        --help|-h)
            usage
            ;;
        *)
            echo "❌ Unknown option: $1" >&2
            usage
            ;;
    esac
done

# ---------------- DATE SETUP ----------------
if [[ -n "$OVERRIDE_DATE" ]]; then
    TARGET_DATE="$OVERRIDE_DATE"
else
    TARGET_DATE=$(date '+%Y-%m-%d')
fi

YEAR="${TARGET_DATE:0:4}"
MM_DD="${TARGET_DATE:5:2}-${TARGET_DATE:8:2}"

PAPER_BASE_DIR="/mnt/storage/Newspapers/The Sydney Morning Herald"
JSON_FILE="$PAPER_BASE_DIR/Contents/$YEAR/$MM_DD.json"

TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
RUN_LOG="$LOG_DIR/$TIMESTAMP.log"

mkdir -p "$LOG_DIR"
touch "$RUN_LOG"
ln -sf "$RUN_LOG" "$LOG_DIR/latest.log"

# ---------------- ENVIRONMENT ----------------
export PATH="/usr/bin:/bin"
export TZ="Australia/Sydney"

# ---------------- LOG HEADER ----------------
{
    echo "=============================="
    echo "Run started: $(date)"
    echo "Target date: $TARGET_DATE"
} >> "$RUN_LOG"

# ---------------- SKIP IF EXISTS ----------------
if [[ $CONTENTS_ONLY -eq 1 && -f "$JSON_FILE" ]]; then
    echo "🟡 JSON already exists: $JSON_FILE — exiting" >> "$RUN_LOG"
    exit 0
fi

# ---------------- ACTIVATE VENV ----------------
# from this point onwards, we're going to be running some Python scripts regardless of settins
source "$VENV/bin/activate"

if [[ ! -f "$JSON_FILE" ]]; then
    # ---------------- BUILD PYTHON ARGS ----------------
    PY_ARGS=(--date "$TARGET_DATE")

    # ---------------- RUN ----------------
    echo "🚀 Running Python Script: $PY_CONTENTS_SCRIPT ${PY_ARGS[*]}" >> "$RUN_LOG"

    # Check the the target directory for the JSON file exists
    if [[ ! -d "$PAPER_BASE_DIR/Contents/$YEAR" ]]; then
        mkdir -p "$PAPER_BASE_DIR/Contents/$YEAR"
    fi

    xvfb-run -a python3 "$PY_CONTENTS_SCRIPT" "${PY_ARGS[@]}" >> "$RUN_LOG" 2>&1

    if [[ -f "$JSON_FILE" ]]; then
        echo "JSON contents file downloaded." >> "$RUN_LOG"
    else
        echo "❌ JSON contents file was NOT downloaded." >> "$RUN_LOG"
        exit 1
    fi

    if [[ $CONTENTS_ONLY -eq 1 ]]; then
        echo "Run finished: $(date)" >> "$RUN_LOG"
        exit 0
    fi
else
    echo "Contents JSON has already been downloaded." >> "$RUN_LOG"
fi

# ---------------- DOWNLOAD THE EDITION PAGES ----------------

# ensure that the target directory exists
mkdir -p "$PAPER_BASE_DIR/Editions/$YEAR/$TARGET_DATE/Pages"
rm -rf "$PAPER_BASE_DIR/Editions/$YEAR/$TARGET_DATE/Pages/*"

PAGE_CNT=$(jq '[.[].pages[] | tonumber] | max' "$JSON_FILE")

PY_ARGS=(-date "$TARGET_DATE")
PY_ARGS+=(-pages "$PAGE_CNT")

echo "🚀 Running Python Script: $PY_DOWNLOAD_SCRIPT ${PY_ARGS[*]}" >> "$RUN_LOG"

xvfb-run -a python3 "$PY_DOWNLOAD_SCRIPT" "${PY_ARGS[@]}" >> "$RUN_LOG" 2>&1

# ensure the the correct number of images have been downloaded
FILE_CNT=$(ls "$PAPER_BASE_DIR/Editions/$YEAR/$TARGET_DATE/Pages/"*.png | wc -l)

if [[ ! $PAGE_CNT -eq $FILE_CNT ]]; then
    echo "❌ There is the wrong number of images that have been downloaded, expected $PAGE_CNT, found $FILE_CNT." >> "$RUN_LOG"
    exit 1
fi

echo "Run finished: $(date)" >> "$RUN_LOG"
