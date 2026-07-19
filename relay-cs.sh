#!/bin/bash
# relay-cs.sh — CS-side relay helper. No secrets inside.
RELAY_HOST=63.250.40.238
CM="$HOME/.relay-cm"
R(){ ssh -q -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath="$CM" -o ControlPersist=900 relay@"$RELAY_HOST" "$@"; }
trap 'ssh -o ControlPath="$CM" -O exit relay@"$RELAY_HOST" >/dev/null 2>&1' EXIT

echo "=== Relay transfer ==="
echo "--- Enter relay password when prompted:"
R list >/dev/null 2>&1 || { echo "auth failed"; exit 1; }

if [ -n "$1" ]; then
  NAME=$1
  echo "--- Resuming job $NAME"
else
  read -p "Backup URL: " URL
  echo "--- Staging on relay..."
  OUT=$(R stage "$URL") || { echo "$OUT"; exit 1; }
  echo "$OUT"
  NAME=$(echo "$OUT" | awk '/^STAGING/{print $2}')
  [ -n "$NAME" ] || { echo "stage failed"; exit 1; }
  echo "--- If this session dies, resume with: bash relay-cs.sh $NAME"
fi

while :; do
  S=$(R status "$NAME")
  case "$S" in
    READY*) echo "$S"; break;;
    FAILED*) echo "$S"; exit 1;;
    *) echo "  $(echo "$S" | tail -1)"; sleep 15;;
  esac
done

WGET=$(R status "$NAME" | grep '^wget')
echo "--- Pulling to $(hostname -s)..."
T0=$(date +%s); eval "$WGET"; RC=$?; T1=$(date +%s)
[ "$RC" -eq 0 ] || { echo "local download failed, file kept on relay"; exit 1; }
SZ=$(stat -c%s "$NAME"); EL=$((T1-T0)); [ "$EL" -lt 1 ] && EL=1
SPD=$((SZ/EL/1024))
case "$NAME" in
  *.gz|*.tgz) gzip -t "$NAME" && CHK="gzip OK" || CHK="CORRUPT";;
  *.zip) unzip -qql "$NAME" >/dev/null 2>&1 && CHK="zip OK" || CHK="CORRUPT";;
  *) CHK="not verified";;
esac
LOSS=$(ping -c 10 -q "$RELAY_HOST" 2>/dev/null | awk -F, '/loss/{gsub(/^ /,"",$3); print $3}')
echo "RESULT: $((SZ/1048576)) MB in ${EL}s = ${SPD} KB/s | $CHK"
echo ""
echo "=== SHEET LINE (paste in column A, split by semicolon) ==="
printf "%s;%s / VPS relay;%s;http;%s MB;%s KB/s;%s KB/s;never;;%s;;relay\n" \
  "$(date -u +'%Y-%m-%d %H:%M')" "$RELAY_HOST" "$(hostname -s)" "$((SZ/1048576))" "$SPD" "$SPD" "${LOSS:-n/a}"
echo ""
[ "$CHK" = "CORRUPT" ] && { echo "!!! Corrupt locally — file KEPT on relay, retry."; exit 1; }
read -p "Delete from relay now? (y/N): " D
[ "$D" = "y" ] && R delete "$NAME"
