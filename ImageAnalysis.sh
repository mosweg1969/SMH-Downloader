#!/usr/bin/env bash
# set -euo pipefail

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
    tesseract "$1" stdout --psm 7 -c tessedit_char_whitelist=\ \.\,0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz   
}

ocr2() {
    tesseract "$1" stdout --psm 7 -c tessedit_char_whitelist=\ \.\,0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ   
}

similarity() {
python3 - <<'PY' "$1" "$2"
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
print(f"'{s1}' '{s2}' {similarity:.2f}")
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

PAPER_BASE_DIR="."
YEAR="${TARGET_DATE:0:4}"
CCYY_MM_DD="${TARGET_DATE:0:4}-${TARGET_DATE:5:2}-${TARGET_DATE:8:2}"

#DOW_LONG=$(date -d "$TARGET_DATE" +%A | tr '[:lower:]' '[:upper:]')
#MONTH_NAME=$(date -d "$TARGET_DATE" +%B | tr '[:lower:]' '[:upper:]')

DOW_LONG=$(date -j -f "%Y-%m-%d" "$TARGET_DATE" +%A | tr '[:lower:]' '[:upper:]')
MONTH_NAME=$(date -j -f "%Y-%m-%d" "$TARGET_DATE" +%B | tr '[:lower:]' '[:upper:]')
DAY_NUM=$(date -j -f "%Y-%m-%d" "$TARGET_DATE" +%-d)

JSON_FILE="$PAPER_BASE_DIR/Contents/$YEAR/$CCYY_MM_DD.json"
TEXT_FILE="$PAPER_BASE_DIR/Contents/$YEAR/$CCYY_MM_DD.txt"
IMAGES_BASE_DIR="$PAPER_BASE_DIR/Images/$YEAR/$TARGET_DATE"

echo "1 THE SYDNEY MORNING HERALD $DOW_LONG, $MONTH_NAME $DAY_NUM, $YEAR"
exit 0

# ---------------- LOG HEADER ----------------
logline
log "Run started: $(date)"
log "Target date: $TARGET_DATE"

# ---------------- PERFORM THE ANALYSIS OF EACH PAGE ----------------

ARGS1="-channel B -separate -auto-level -resize 300% -threshold 45% -negate"
ARGS2="-channel B -separate -auto-level -threshold 45%"

mkdir -p "$IMAGES_BASE_DIR/top"

RIGHT=1
PAGE=1
PAGE_FOUND=0

for f in "$IMAGES_BASE_DIR/png/"*.png; do
    base=$(basename "$f" .png)
    
    MAST=""
    read WIDTH HEIGHT < <(identify -format "%w %h\n" "$f")
    if (( ( WIDTH == 2060 || WIDTH == 2061 ) && HEIGHT == 2820 )); then
        if [[ $PAGE_FOUND -eq 0 ]]; then
            magick "$f" -crop x220+0+50 $ARGS1 "$IMAGES_BASE_DIR/top/$base.mast.png"
            MAST=$(ocr1 "$IMAGES_BASE_DIR/top/$base.1.png")            
            MAST_SCORE=$(similarity "$MAST" "The Sydney Morning Herald")
        fi
        
similarity "THE SYDNEY MORNING HERALD THURSDAY, MARCH 5, 2026" "4 THE SYDNEY MORNING HERALD THURSDAY, MARCH 5, 2026"
similarity "4 THE SYDNEY MORNING HERALD THURSDAY, MARCH 5, 2026" "4 THESYDNEY MORNING HERALD THURSDAY, MARCH 5, 2026"
        
        if [[ $RIGHT -eq 1 ]]; then
            magick "$f" -crop 700x50+1275+40 $ARGS2 "$IMAGES_BASE_DIR/top/$base.date.png"
            RIGHT=0
        else
            magick "$f" -crop 700x50+75+40 $ARGS2 "$IMAGES_BASE_DIR/top/$base.date.png"
            RIGHT=1
        fi
        
        TEXT=$(ocr2 "$IMAGES_BASE_DIR/top/$base.date.png")
        if [[ "$TEXT" == *"THE SYDNEY MORNING HERALD"* ]]; then
            echo "Page $PAGE - $TEXT"
            PAGE_FOUND=1
        else
            echo "Page $PAGE - $MAST - ($TEXT)"
        fi
        # ocr2 "$IMAGES_BASE_DIR/top/$base.2.png"
    fi
    ((PAGE++))
done

log "Run finished: $(date)"
logline
