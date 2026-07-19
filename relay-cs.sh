#!/bin/bash
# relay-cs.sh — CS-side relay helper. Contains no secrets.
CONF="$HOME/.relay/config"; KEY="$HOME/.relay/key"
[ -f "$CONF" ] && [ -f "$KEY" ] || { echo "Missing $CONF or $KEY — request relay access internally."; exit 1; }
. "$CONF"; chmod 600 "$KEY" 2>/dev/null
[ -n "$RELAY_HOST" ] || { echo "RELAY_HOST not set in config"; exit 1; }

eval "$(ssh-agent -s)" >/dev/null
trap 'ssh-agent -k >/dev/null 2>&1' EXIT
echo "--- Unlocking relay key (passphrase):"
ssh-add "$KEY" || exit 1
R(){ ssh -q -o StrictHostKeyChecking=accept-new relay@"$RELAY_HOST" "$@"; }

read -p "Backup URL: " URL
echo "--- Asking relay to stage..."
OUT=$(R stage "$URL") || { echo "$OUT"; exit 1; }
echo "$OUT"
NAME=$(echo "$OUT" | awk '/^STAGING/{print $2}')
[ -n "$NAME" ] || { echo "stage failed"; exit 1; }

echo "--- Downloading to relay (safe to wait, runs detached on relay side)"
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
echo "--- Verifying locally..."
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
[ "$CHK" = "CORRUPT" ] && { echo "!!! Corrupt locally — file KEPT on relay, retry the pull."; exit 1; }
read -p "Delete from relay now? (y/N): " D
[ "$D" = "y" ] && R delete "$NAME"
