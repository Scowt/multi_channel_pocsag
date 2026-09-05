#!/usr/bin/env bash
# Set up a private PagerMon instance fed by the POCSAG chain in this repository.
# Run as the pi user (NOT root):  bash setup-pagermon.sh
set -euo pipefail

PM=/home/pi/pagermon
RADIO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRV="$PM/server"

command -v node >/dev/null || { echo "node not installed - run: sudo bash $RADIO/SUDO-PAGERMON.sh" >&2; exit 1; }
[[ -d "$SRV" ]] || { echo "$SRV not found - clone pagermon first" >&2; exit 1; }

echo "==> node $(node --version), npm $(npm --version)"

# ---------------------------------------------------------------- npm install
if [[ ! -d "$SRV/node_modules" ]]; then
  echo "==> Installing server dependencies (this takes several minutes on a Pi)"
  ( cd "$SRV" && npm install --no-audit --no-fund )
else
  echo "==> node_modules already present, skipping npm install"
fi

# ------------------------------------------------------------------- secrets
gen() { openssl rand -hex "$1" 2>/dev/null || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
SESSION_SECRET=$(gen 24)
API_KEY=$(gen 24)
ADMIN_PASS=$(gen 9)

# bcryptjs ships with PagerMon, so hash the password with the same library the
# server verifies against.
ADMIN_HASH=$(cd "$SRV" && node -e "
const b=require('bcryptjs');
process.stdout.write(b.hashSync(process.argv[1], 8));
" "$ADMIN_PASS")

# -------------------------------------------------------------- server config
echo "==> Writing $SRV/config/config.json"
node -e '
const fs=require("fs"), path=require("path");
const dir=process.argv[1];
const c=JSON.parse(fs.readFileSync(path.join(dir,"config/default.json"),"utf8"));
c.global.sessionSecret = process.argv[2];
c.global.monitorName   = "Radio Pi POCSAG";
c.global.loglevel      = "info";
c.auth.registration    = false;               // private: nobody can self-register
c.auth.user            = "admin";
c.auth.encPass         = process.argv[3];
c.auth.keys            = [{ name: "radio-pi", key: process.argv[4], selected: true }];
c.messages.apiSecurity = true;                // require login to read messages
c.messages.duplicateFiltering = true;
c.messages.replaceText = [];                  // drop the shipped demo rules
c.database.file        = "./messages.db";
c.database.type        = "sqlite3";
fs.writeFileSync(path.join(dir,"config/config.json"), JSON.stringify(c,null,2));
' "$SRV" "$SESSION_SECRET" "$ADMIN_HASH" "$API_KEY"

# -------------------------------------------------------------- client config
echo "==> Writing $RADIO/pagermon-client.json"
cat > "$RADIO/pagermon-client.json" <<JSON
{
  "hostname": "http://127.0.0.1:3000",
  "apikey": "$API_KEY",
  "identifier": "radio-pi"
}
JSON
chmod 600 "$RADIO/pagermon-client.json"

# ------------------------------------------------------------- credentials file
cat > "$RADIO/pagermon-credentials.txt" <<TXT
PagerMon credentials - generated $(date -Is)

  Web UI    http://$(hostname -I | awk '{print $1}'):3000
  Username  admin
  Password  $ADMIN_PASS

  API key   $API_KEY   (already written to $RADIO/pagermon-client.json)

Change the password at /admin once you have logged in.
TXT
chmod 600 "$RADIO/pagermon-credentials.txt"

echo
echo "================================================================"
echo " PagerMon configured."
echo
echo "   URL       http://$(hostname -I | awk '{print $1}'):3000"
echo "   Username  admin"
echo "   Password  $ADMIN_PASS"
echo
echo " Saved to $RADIO/pagermon-credentials.txt (mode 600)"
echo "================================================================"
echo
echo "Start the server with:   bash $RADIO/bin/pagermon-server.sh"
