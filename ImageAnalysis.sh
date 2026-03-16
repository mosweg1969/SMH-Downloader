#!/usr/bin/env bash
set -euo pipefail

# ---------------- CONFIG ----------------
RED='\033[1;31m'
RESET='\033[0m'
shopt -s nullglob

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

ocr1() {
    tesseract "$1" stdout --psm 7 -c tessedit_char_whitelist=\ \.\,-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz 2>/dev/null
}

ocr2() {
    tesseract "$1" stdout --psm 7 -c tessedit_char_whitelist=\ \.\,-0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ 2>/dev/null
}

similarity() {
python3 - <<'PY' "$1" "$2"ø

import sys

s1 = sys.argv[1]
s2 = sys.argv[2]

def levenshtein(a,b):
    if len(a) < len(b):
        return levenshtein(b,a)
    if len(b) == 0:
        return len(a)

    previous = range(len(b)+1)
    for i,c1 in enumerate(a):
        current = [i+1]
        for j,c2 in enumerate(b):
            insertions = previous[j+1] + 1
            deletions = current[j] + 1
            substitutions = previous[j] + (c1 != c2)
            current.append(min(insertions,deletions,substitutions))
        previous = current
    return previous[-1]

dist = levenshtein(s1, s2)
max_len = max(len(s1), len(s2))
similarity = (1 - dist / max_len) * 100 if max_len else 100
print(f"{similarity:.0f}")
PY
}

# ---------------- PARSE ARGUMENTS ----------------

if [[ $# -eq 0 || $# -gt 2 ]]; then
    usage
fi

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

# ---------------- DATE SETUP ----------------
if [[ -n "$OVERRIDE_DATE" ]]; then
    TARGET_DATE="$OVERRIDE_DATE"
else
    TARGET_DATE=$(date '+%Y-%m-%d')
fi

PAPER_BASE_DIR="/mnt/storage/Newspapers/The Sydney Morning Herald"
YEAR="${TARGET_DATE:0:4}"
CCYY_MM_DD="${TARGET_DATE:0:4}-${TARGET_DATE:5:2}-${TARGET_DATE:8:2}"

DOW_LONG=$(date -d "$TARGET_DATE" +%A | tr '[:lower:]' '[:upper:]')
MONTH_NAME=$(date -d "$TARGET_DATE" +%B | tr '[:lower:]' '[:upper:]')
DAY_NUM=$(date -d "$TARGET_DATE" +%-d)

JSON_FILE="$PAPER_BASE_DIR/Contents/$YEAR/$CCYY_MM_DD.json"
TEXT_FILE="$PAPER_BASE_DIR/Contents/$YEAR/$CCYY_MM_DD.txt"
ADS_FILE="$PAPER_BASE_DIR/Contents/$YEAR/$CCYY_MM_DD.ads.txt"
IMAGES_BASE_DIR="$PAPER_BASE_DIR/Images/$YEAR/$TARGET_DATE"

# ---------------- LOG HEADER ----------------
logline
log "Run started: $(date)"
log "Target date: $TARGET_DATE"

# ---------------- PERFORM THE ANALYSIS OF EACH PAGE ----------------

ARGS="-auto-level -resize 300% -threshold 75%"

TMP_IMAGE="/tmp/smhtemp.png"

read MAIN_START MAIN_END < <(awk '$1=="MAIN"{print $2+0, $3+0}' "$TEXT_FILE")

if [[ -f "$ADS_FILE" ]]; then
    rm "$ADS_FILE"
fi

RIGHT_HAND=true
PAGE_NUM=1
CONTENTS_FOUND=false

if [[ "$DOW_LONG" == "SUNDAY" ]]; then
    PAPER_NAME1="The Sun-Herald"
    PAPER_NAME2="THE SUN-HERALD"
else
    PAPER_NAME1="The Sydney Morning Herald"
    PAPER_NAME2="THE SYDNEY MORNING HERALD"
fi

for f in "$IMAGES_BASE_DIR/png/"*.png; do
    base=$(basename "$f" .png)

    PAGE_IDENTIFIED=false
    read WIDTH HEIGHT < <(identify -format "%w %h\n" "$f")
    if (( ( WIDTH == 2060 || WIDTH == 2061 ) && HEIGHT == 2820 )); then
        if ! $CONTENTS_FOUND; then
            convert "$f" -crop x220+0+50 $ARGS "$TMP_IMAGE"
            MAST=$(ocr1 "$TMP_IMAGE")
            MAST_SCORE=$(similarity "$MAST" "$PAPER_NAME1")

            if (( MAST_SCORE == 100 )); then
                echo "Page $PAGE_NUM is a masthead"
	    elif (( MAST_SCORE > 90 )); then
	        echo "Page $PAGE_NUM is a masthead - ($MAST_SCORE) -'$MAST'"
	    fi
	    (( MAST_SCORE > 90 )) && PAGE_IDENTIFIED=true || PAGE_IDENTIFIED=false
	fi

	if ! $PAGE_IDENTIFIED; then
            if $RIGHT_HAND; then
                convert "$f" -crop 700x50+1275+40 $ARGS "$TMP_IMAGE"
                EXPECTED="$DOW_LONG, $MONTH_NAME $DAY_NUM, $YEAR $PAPER_NAME2 $PAGE_NUM"
            else
                convert "$f" -crop 700x50+75+40 $ARGS "$TMP_IMAGE"
                EXPECTED="$PAGE_NUM $PAPER_NAME2 $DOW_LONG, $MONTH_NAME $DAY_NUM, $YEAR"
            fi

            TEXT=$(ocr2 "$TMP_IMAGE")
            PAGE_SCORE=$(similarity "$TEXT" "$EXPECTED")

	    echo "Comparing '$TEXT' to '$EXPECTED' - Score $PAGE_SCORE"
	    if (( PAGE_SCORE > 90 )); then
		echo "Page $PAGE_NUM - Normal"
	    elif (( PAGE_SCORE > 80 )); then
		echo "Page $PAGE_NUM - Likely correct ($PAGE_SCORE) found '$TEXT'"
	    fi
            if (( PAGE_SCORE > 80 )); then
		PAGE_IDENTIFIED=true
		CONTENTS_FOUND=true
	    fi
	fi

        if ! $PAGE_IDENTIFIED && (( PAGE_NUM == MAIN_END )); then
            convert "$f" -crop 700x50+1275+60 $ARGS "$TMP_IMAGE"
            EXPECTED="$DOW_LONG, $MONTH_NAME $DAY_NUM, $YEAR $PAPER_NAME2"

            TEXT=$(ocr2 "$TMP_IMAGE")
            PAGE_SCORE=$(similarity "$TEXT" "$EXPECTED")

            echo "Comparing '$TEXT' to '$EXPECTED' - Score $PAGE_SCORE"

            if (( PAGE_SCORE > 90 )); then
                echo "Page $PAGE_NUM - Normal"
            elif (( PAGE_SCORE > 80 )); then
                echo "Page $PAGE_NUM - Likely correct ($PAGE_SCORE) found '$TEXT'"
            fi
            if (( PAGE_SCORE > 80 )); then
                PAGE_IDENTIFIED=true
                CONTENTS_FOUND=true
            fi
	fi

	if ! $PAGE_IDENTIFIED; then
	    echo $PAGE_NUM >> "$ADS_FILE"
	    echo "Page $PAGE_NUM - Advertising"
        fi

	RIGHT_HAND=$(! $RIGHT_HAND && echo true || echo false)
    fi
    ((PAGE_NUM++))

    if (( PAGE_NUM > MAIN_END )); then
	break
    fi
done

log "Run finished: $(date)"
logline

