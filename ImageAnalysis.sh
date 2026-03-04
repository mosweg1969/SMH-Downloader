#!/usr/bin/env bash
# set -euo pipefail

# ---------------- CONFIG ----------------
RED='\033[1;31m'
RESET='\033[0m'

# ---------------- DEFAULTS ----------------
OVERRIDE_DATE=""

# ---------------- HELP ----------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  -date YYYY-MM-DD           Override today\'s date

Examples:
  $0 -date 2026-01-27                       # Analyses 27th Jan 2026 images

EOF
    exit 0
}

fail() {
    create_log
    echo -e "${RED}ERROR${RESET}: $1"
    exit 1
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

logline() {
    log "---------------------------------------------------"
}

# ---------------- CHECK USER ----------------
if [[ "$(id -un)" != "smh" ]]; then
    fail "This script must be run as the 'smh' user"
fi

# ---------------- PARSE ARGUMENTS ----------------

if [[ $# -eq 0 || $# -gt 2 ]]; do
    usage
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        -date)
            if [[ -z "${2:-}" ]]; then
                fail "❌ ERROR: --date requires YYYY-MM-DD" 
            fi
            OVERRIDE_DATE="$2"
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

PAPER_BASE_DIR="/mnt/storage/Newspapers/The Sydney Morning Herald"
JSON_FILE="$PAPER_BASE_DIR/Contents/$YEAR/$CCYY_MM_DD.json"
TEXT_FILE="$PAPER_BASE_DIR/Contents/$YEAR/$CCYY_MM_DD.txt"
IMAGES_BASE_DIR="$PAPER_BASE_DIR/Images/$YEAR/$TARGET_DATE"

# ---------------- LOG HEADER ----------------
logline
log "Run started: $(date)"
log "Target date: $TARGET_DATE"

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

# ---------------- MAKE THE Puzzle PDF ----------------

mkdir -p "$PUZZLE_BASE_DIR"

PDF="$PUZZLE_BASE_DIR/$TARGET_DATE Puzzles.pdf"
if [[ ! -f "$PDF" ]]; then

    read PUZZLE_START PUZZLE_END < <(awk '$1=="PUZZLES"{print $2, $3}' "$TEXT_FILE")
    if [[ -n $PUZZLE_START ]]; then
        log "Creating puzzles PDF between pages $PUZZLE_START and $PUZZLE_END"

        PAGE_LIST=()

        for p in $(seq -f "%03g" "$PUZZLE_START" "$PUZZLE_END"); do
            PAGE_LIST+=("$IMAGES_BASE_DIR/png/SMH_${TARGET_DATE}_p${p}.png")
        done

        img2pdf --output "$PDF" "${PAGE_LIST[@]}"
    fi
else
    log "Puzzles PDF file has already been created!"
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
                PAGE_LIST+=("$IMAGES_BASE_DIR/jpg/SMH_${TARGET_DATE}_p${p}.jpg")
            done

            img2pdf --output "$PDF" "${PAGE_LIST[@]}"

            PDF_SIZE=$(stat -c %s "$PDF")

            if (( PDF_SIZE > MAX_SIZE )); then
                log "**WARNING - Supplement '$NAME' small size is over maximum size!"
            fi

            if (( PDF_SIZE = 0 )); then
                log "Supplement '$NAME' was created with zero size!!"
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

# ------------------- MAIL THESE OUT -------------

if [[ -n "${RECIPIENT_FILE:-}" ]]; then
    LONG_DATE=$(long_date)

    EMAIL="Bcc: ronlee3@gmail.com, mosweg1969@gmail.com, me.g7t8vsf@goodnotes.email"

    log "Sending puzzles for $LONG_DATE to $EMAIL"
    : | mail -s: | mail -s "The Sydney Morning Herald Puzzles, $LONG_DATE" -A "$PUZZLE_BASE_DIR/$TARGET_DATE Puzzles.pdf" -a "$EMAIL" mosweg1969@gmail.com

    EMAIL="Bcc: wayne.moss@westpac.com.au, mosweg1969@gmail.com, auddster@gmail.com, ronlee3@gmail.com"

    log "Sending main edition for $LONG_DATE to $EMAIL"
    : | mail -s: | mail -s "The Sydney Morning Herald, $LONG_DATE" -A "$EDITION_BASE_DIR/small/Main.pdf" -a "$EMAIL" mosweg1969@gmail.com

fi

date > "$COMPLETION_FLAG"

log "Run finished: $(date) 
logline
