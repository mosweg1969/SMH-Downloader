start="$1"
end="$2"

d=$(date -d "$start" +%s)
end_s=$(date -d "$end" +%s)

while [ "$d" -le "$end_s" ]; do
    dt=$(date -d "@$d" +%Y-%m-%d)
    echo " ./SMH-Downloader.sh --contents-only -date $dt"
    ./SMH-Downloader.sh --contents-only -date "$dt"
    d=$(( d + 86400 ))
done

