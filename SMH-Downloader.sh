#!/usr/bin/env bash
set -euo pipefail

# ---------------- CONFIG ----------------
BASE_DIR="/var/lib/smh-downloader"
VENV="$BASE_DIR/.venv"
PY_CONTENTS_SCRIPT="$BASE_DIR/SMH-Contents-Retrieve.py"
PY_DOWNLOAD_SCRIPT="$BASE_DIR/SMH-Page-Downloader.py"
PY_JSON_PARSER="$BASE_DIR/ConvertJSON.py"
RED='\033[1;31m'
RESET='\033[0m'

# ---------------- LOGGING ----------------
LOG_DIR="/mnt/storage/logs/smh-downloader"
TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
RUN_LOG="$LOG_DIR/$TIMESTAMP.log"

# ---------------- DEFAULTS ----------------
OVERRIDE_DATE=""
CROSSWORDS_ONLY=0
CONTENTS_ONLY=0
RECIPIENT_FILE=""
TODAY=0
LOG_CREATED=0

# ---------------- HELP ----------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -date YYYY-MM-DD           Override today\'s date
  --today                    Run by cron, and will not repeat when it's already been successful
  --crosswords-only          Only download crossword pages
  --contents-only            Only download the contents JSON file
  -mail-to recipient_file    Mail downloaded content to recepients specified in recipient_file
  --help                     Show this help

Examples:
  $0 --contents-only                        # Downloads contents for current day edition only
  $0 -date 2026-01-27                       # Downloads the edition for 27th Jan 26 and saves all editions
  $0 -date 2026-01-27 --crosswords-only     # Downloasd the puzzle pages for 27th Jan 26 edition only
  $0 -mail-to user@email.address            # Download and mail current edition to user
EOF
    exit 0
}

create_log() {
    if [[ $LOG_CREATED -eq 0 ]]; then
        mkdir -p "$LOG_DIR"
        touch "$RUN_LOG"
        ln -sf "$RUN_LOG" "$LOG_DIR/latest.log"
        LOG_CREATED=1
    fi
}

fail() {
    create_log
    echo -e "${RED}ERROR${RESET}: $1" | tee -a "$RUN_LOG"
    exit 1
}

log() {
    create_log
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$RUN_LOG"
}

logline() {
    log "---------------------------------------------------"
}

# ---------------- CHECK USER ----------------
if [[ "$(id -un)" != "smh" ]]; then
    fail "This script must be run as the 'smh' user"
fi

# ---------------- PARSE ARGUMENTS ----------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --today)
            TODAY=1
            shift
            ;;
        -date)
            if [[ -z "${2:-}" ]]; then
                fail "❌ ERROR: --date requires YYYY-MM-DD" 
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
                fail "❌ ERROR: -mail-to requires a recipient file"
            fi
            RECIPIENT_FILE="$2"
            shift 2
	    ;;
        --help|-h)
            usage
            ;;
        *)
	    usage
            fail "❌ Unknown option: $1"
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
CCYY_MM_DD="${TARGET_DATE:0:4}-${TARGET_DATE:5:2}-${TARGET_DATE:8:2}"

PAPER_BASE_DIR="/mnt/storage/Newspapers/The Sydney Morning Herald"
JSON_FILE="$PAPER_BASE_DIR/Contents/$YEAR/$CCYY_MM_DD.json"
TEXT_FILE="$PAPER_BASE_DIR/Contents/$YEAR/$CCYY_MM_DD.txt"
EDITION_BASE_DIR="$PAPER_BASE_DIR/Editions/$YEAR/$TARGET_DATE"
IMAGES_BASE_DIR="$PAPER_BASE_DIR/Images/$YEAR/$TARGET_DATE"
COMPLETION_FLAG="$PAPER_BASE_DIR/.latest"

# ---------------- CHECK WHETHER ALREADY RUN SUCCESSFULLY TODAY ----------------
if [[ $TODAY -eq 1 && -f "$COMPLETION_FLAG" ]]; then
    COMPLETION_DATE=$(stat -c %y "$COMPLETION_FLAG" | cut -d' ' -f1)
    if [[ "$COMPLETION_DATE" = "$TARGET_DATE" ]]; then
	echo "Everything is complete for today!"
        exit 0
    fi
fi

# ---------------- ENVIRONMENT ----------------
export PATH="/usr/bin:/bin"
export TZ="Australia/Sydney"

# ---------------- LOG HEADER ----------------
logline
log "Run started: $(date)"
log "Target date: $TARGET_DATE"

# ---------------- SKIP IF EXISTS ----------------
if [[ $CONTENTS_ONLY -eq 1 && -f "$JSON_FILE" ]]; then
    log "🟡 JSON already exists: $JSON_FILE — exiting"
    exit 0
fi

# ---------------- ACTIVATE VENV ----------------

# from this point onwards, we're going to be running some Python scripts regardless of settings
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
        log "JSON contents file downloaded."
    else
        fail "❌ JSON contents file was NOT downloaded."
    fi

    if [[ $CONTENTS_ONLY -eq 1 ]]; then
        log "Run finished: $(date)"
        exit 0
    fi
else
    log "Contents JSON has already been downloaded."
fi

# ---------------- CREATE CUT_DOWN CONTENTS FILE ---------------

if [[ ! -f "$TEXT_FILE" ]]; then
    log "Creating contents text file"
    python3 "$PY_JSON_PARSER" "$JSON_FILE" > "$TEXT_FILE"
else
    log "Contents text file has already been created."
fi

# ---------------- CROSSWORDS ONLY? ----------------

if [[ $CROSSWORDS_ONLY -eq 1 ]]; then
    fail "This has not been implemented yet!"
fi

# ---------------- DOWNLOAD THE EDITION IMAGES ----------------

# ensure that the target directory exists
mkdir -p "$IMAGES_BASE_DIR/png"

EXPECTED_PAGE_CNT=$(jq '[.[].pages[] | tonumber] | max' "$JSON_FILE")
ACTUAL_FILE_CNT=$(find "$IMAGES_BASE_DIR/png/" -maxdepth 1 -name '*.png' -type f | wc -l)

if [[ ! $EXPECTED_PAGE_CNT -eq $ACTUAL_FILE_CNT ]]; then

    if [[ $ACTUAL_FILE_CNT -gt 0 ]]; then
	fail "There are $ACTUAL_FILE_CNT image files in the 'png' directory, expecting $EXPECTED_PAGE_CNT"
    fi

    PY_ARGS=(-date "$TARGET_DATE")
    PY_ARGS+=(-pages "$EXPECTED_PAGE_CNT")

    log "🚀 Running Python Script: $PY_DOWNLOAD_SCRIPT ${PY_ARGS[*]}"

    xvfb-run -a python3 "$PY_DOWNLOAD_SCRIPT" "${PY_ARGS[@]}" >> "$RUN_LOG" 2>&1

    # ensure the the correct number of images have been downloaded
    ACTUAL_FILE_CNT=$(find "$IMAGES_BASE_DIR/png/" -maxdepth 1 -name '*.png' -type f | wc -l)
    if [[ ! $EXPECTED_PAGE_CNT -eq $ACTUAL_FILE_CNT ]]; then
        fail "❌ There is the wrong number of images that have been downloaded, expected $EXPECTED_PAGE_CNT, found $ACTUAL_FILE_CNT."
    fi
else
    log "There are already $ACTUAL_FILE_CNT .png image files downloaded."
fi

# ---------------- CREATE THE SMALLER VERSIONS OF IMAGES ----------------

mkdir -p "$IMAGES_BASE_DIR/jpg"
ACTUAL_FILE_CNT=$(find "$IMAGES_BASE_DIR/jpg/" -maxdepth 1 -name '*.jpg' -type f | wc -l)

if [[ ! $EXPECTED_PAGE_CNT -eq $ACTUAL_FILE_CNT ]]; then

    if [[ $ACTUAL_FILE_CNT -gt 0 ]]; then
        fail "There are $ACTUAL_FILE_CNT image files in the 'jpg' directory, expecting $EXPECTED_PAGE_CNT"
    fi

    log "Converting png images to smaller 60% sized jpg images."

    for f in "$IMAGES_BASE_DIR/png/"*.png; do
        base=$(basename "$f" .png)
        convert "$f" -resize 60% -quality 85 "$IMAGES_BASE_DIR/jpg/$base.jpg" >> "$RUN_LOG" 2>&1
    done

    # ensure the the correct number of images have been converted
    ACTUAL_FILE_CNT=$(find "$IMAGES_BASE_DIR/jpg/" -maxdepth 1 -name '*.jpg' -type f | wc -l)

    if [[ ! $EXPECTED_PAGE_CNT -eq $ACTUAL_FILE_CNT ]]; then
        fail "❌ There is the wrong number of images that have been downloaded, expected $EXPECTED_PAGE_CNT, found $ACTUAL_FILE_CNT."
    fi
else
    log "The $ACTUAL_FILE_CNT smaller .jpg images have already been created."
fi


MAX_SIZE=$((26 * 1024 * 1024))

# ---------------- MAKE THE MAIN Edition PDF ----------------

mkdir -p "$EDITION_BASE_DIR"

PDF="$EDITION_BASE_DIR/Main.pdf"
if [[ ! -f "$PDF" ]]; then

    read MAIN_START MAIN_END < <(awk '$1=="MAIN"{print $2, $3}' "$TEXT_FILE")
    log "Creating large format PDF Main Edition between pages $MAIN_START and $MAIN_END"

    PAGE_LIST=()

    for p in $(seq -f "%03g" "$MAIN_START" "$MAIN_END"); do
        PAGE_LIST+=("$IMAGES_BASE_DIR/png/SMH_${TARGET_DATE}_p${p}.png")
    done

    img2pdf --output "$PDF" "${PAGE_LIST[@]}"

    PDF_SIZE=$(stat -c %s "$PDF")

    if (( PDF_SIZE > MAX_SIZE )); then
        log "Creating small format PDF Main Edition between pages $MAIN_START and $MAIN_END"

	mkdir -p "$EDITION_BASE_DIR/small"
        PDF="$EDITION_BASE_DIR/small/Main.pdf"

        PAGE_LIST=()

        for p in $(seq -f "%03g" "$MAIN_START" "$MAIN_END"); do
            PAGE_LIST+=("$IMAGES_BASE_DIR/jpg/SMH_${TARGET_DATE}_p${p}.jpg")
        done

        img2pdf --output "$PDF" "${PAGE_LIST[@]}"

        PDF_SIZE=$(stat -c %s "$PDF")

        if (( PDF_SIZE > MAX_SIZE )); then
	    log "**WARNING - Main edition small size is over maximum size!"
       fi
    fi
else
    log "Main PDF file has already been created!"
fi

# ---------------- MAKE THE Supplement PDFs ----------------

while IFS=$'\t' read -r NAME SUPP_START SUPP_END; do
    SAFE_NAME=$(echo "$NAME" | tr ' /' '__')
    PDF="$EDITION_BASE_DIR/$SAFE_NAME.pdf"
    if [[ ! -f "$PDF" ]]; then
        log "Creating supplement '$NAME' PDF between pages $SUPP_START and $SUPP_END"

        PAGE_LIST=()

        for p in $(seq -f "%03g" "$SUPP_START" "$SUPP_END"); do
            PAGE_LIST+=("$IMAGES_BASE_DIR/png/SMH_${TARGET_DATE}_p${p}.png")
        done

        img2pdf --output "$PDF" "${PAGE_LIST[@]}"

        PDF_SIZE=$(stat -c %s "$PDF")

        if (( PDF_SIZE > MAX_SIZE )); then
            log "Creating small format PDF Supplement '$NAME'Main Edition between pages $SUPP_START and $SUPP_END"

            PDF="$EDITION_BASE_DIR/small/$SAFE_NAME.pdf"

            PAGE_LIST=()

            for p in $(seq -f "%03g" "$SUPP_START" "$SUPP_END"); do
                PAGE_LIST+=("$EDITION_BASE_DIR/jpg/SMH_${TARGET_DATE}_p${p}.jpg")
            done

            img2pdf --output "$PDF" "${PAGE_LIST[@]}"

            PDF_SIZE=$(stat -c %s "$PDF")

            if (( PDF_SIZE > MAX_SIZE )); then
                log "**WARNING - Supplement '$NAME' small size is over maximum size!"
            fi
        fi
    else
        log "Supplement '$NAME' PDF file has already been created."
    fi
done < <(
    awk '
    $1 == "SUPPLEMENT" {
        match($0, /"([^"]+)"/, name)
        printf "%s\t%s\t%s\n", name[1], $(NF-1), $NF
    }' "$TEXT_FILE"
)

log "Run finished: $(date)"
logline
