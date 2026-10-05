#!/bin/bash
# Rookie Impact Tracker: pull the four nflverse-derived JSON files published by the
# box to GitHub and install them into the live site's data/ folder.
# Runs from Hostinger cron. All-or-nothing: if any file fails to download or
# validate, nothing in data/ is changed. Never replaces data with an older sync.
set -u
umask 022

REPO="${RIT_REPO:-Stellar7070/rookie-impact-tracker-data}"
BRANCH="${RIT_BRANCH:-main}"
DEST="${RIT_DEST:-$HOME/domains/rookieimpacttracker.com/public_html/data}"
WORK="${RIT_WORK:-$HOME/rit-sync}"
FILES="rookies.json sync-status.json weekly-brief.json weekly-stock.json"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { echo "[$(ts)] $*"; }
fail() { log "FAIL: $*"; rm -rf "$STAGE"; exit 1; }

mkdir -p "$WORK" || { log "FAIL: cannot create $WORK"; exit 1; }
STAGE="$(mktemp -d "$WORK/stage.XXXXXX")" || { log "FAIL: mktemp"; exit 1; }
[ -d "$DEST" ] || fail "destination $DEST missing"

# Resolve the branch head to a commit SHA so the raw CDN cannot serve a stale copy.
SHA="$(curl -fsS --max-time 30 -H 'Accept: application/vnd.github.sha' \
  "https://api.github.com/repos/$REPO/commits/$BRANCH" 2>/dev/null | tr -cd '0-9a-f')"
if [ "${#SHA}" -ne 40 ]; then
  log "WARN: could not resolve commit SHA, falling back to branch $BRANCH"
  SHA="$BRANCH"
fi
log "source https://github.com/$REPO @ $SHA"

for f in $FILES; do
  url="https://raw.githubusercontent.com/$REPO/$SHA/data/$f"
  curl -fsS --retry 3 --retry-delay 5 --max-time 60 -o "$STAGE/$f" "$url" || fail "download $f"
  [ -s "$STAGE/$f" ] || fail "$f is empty"
  php -r '$d = json_decode(file_get_contents($argv[1]), true); exit(is_array($d) ? 0 : 1);' "$STAGE/$f" \
    || fail "$f is not valid JSON"
done

# Content checks: sync-status must say live with a lastSyncedAt; rookies must have players.
php -r '
$s = json_decode(file_get_contents($argv[1]), true);
if (!isset($s["status"]) || empty($s["lastSyncedAt"])) { fwrite(STDERR, "sync-status missing status/lastSyncedAt\n"); exit(1); }
if ($s["status"] !== "live") { fwrite(STDERR, "sync-status status is not live: ".$s["status"]."\n"); exit(1); }
$old = @json_decode(@file_get_contents($argv[2]), true);
if (is_array($old) && !empty($old["lastSyncedAt"]) && strcmp($s["lastSyncedAt"], $old["lastSyncedAt"]) < 0) {
  fwrite(STDERR, "new lastSyncedAt ".$s["lastSyncedAt"]." is older than live ".$old["lastSyncedAt"]."\n"); exit(1);
}
echo "new lastSyncedAt=".$s["lastSyncedAt"]." live lastSyncedAt=".(is_array($old) ? ($old["lastSyncedAt"] ?? "none") : "none")."\n";
' "$STAGE/sync-status.json" "$DEST/sync-status.json" || fail "sync-status check"

php -r '$d = json_decode(file_get_contents($argv[1]), true); exit(is_array($d) && count($d) > 0 ? 0 : 1);' "$STAGE/rookies.json" \
  || fail "rookies.json has no content"

# All four validated: move into place (sync-status last so it never claims data that is not there).
for f in $FILES; do
  cp "$STAGE/$f" "$DEST/.$f.new" && chmod 644 "$DEST/.$f.new" || { rm -f "$DEST"/.*.json.new; fail "copy $f"; }
done
for f in rookies.json weekly-brief.json weekly-stock.json sync-status.json; do
  mv -f "$DEST/.$f.new" "$DEST/$f" || fail "install $f"
done

for f in $FILES; do
  log "installed $f $(wc -c < "$DEST/$f") bytes sha256=$(sha256sum "$DEST/$f" | cut -c1-16)"
done
rm -rf "$STAGE"
date -u +%Y-%m-%dT%H:%M:%SZ > "$WORK/last-success"
NEWSTAMP="$(php -r '$s=json_decode(file_get_contents($argv[1]),true); echo $s["lastSyncedAt"];' "$DEST/sync-status.json")"
log "OK installed 4 files from ${SHA:0:12} lastSyncedAt=$NEWSTAMP"
