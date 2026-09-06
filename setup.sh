#!/usr/bin/env bash
# Everything that does NOT need root, in one place.
#
#   bash setup.sh
#
# Creates the Python venv, clones and configures a private PagerMon instance in
# ~/opt/pagermon, and generates its secrets. Run sudo-setup.sh first - this
# needs the Node.js and packages it installs. Safe to re-run, though it
# regenerates the password and API key each time.
set -euo pipefail

[[ $EUID -ne 0 ]] || { echo "Do NOT run this as root - run: bash $0" >&2; exit 1; }

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PM="${PAGERMON_HOME:-$HOME/opt/pagermon}"
SRV="$PM/server"
PAGERMON_REPO="https://github.com/pagermon/pagermon.git"

command -v node >/dev/null || { echo "node not installed - run: sudo bash $REPO/sudo-setup.sh" >&2; exit 1; }
command -v git  >/dev/null || { echo "git not installed - run: sudo bash $REPO/sudo-setup.sh" >&2; exit 1; }
command -v npm  >/dev/null || { echo "npm not installed - run: sudo bash $REPO/sudo-setup.sh" >&2; exit 1; }

echo "==> node $(node --version), npm $(npm --version)"
mkdir -p "$REPO/logs"
echo "==> repo $REPO"
echo "==> pagermon $PM"

# ------------------------------------------------------------------ python venv
# GNU Radio ships as a Debian package with compiled bindings and cannot be
# pip-installed, so the venv is pointed at the system dist-packages instead of
# being isolated. That keeps one interpreter for the whole project.
if [[ ! -x "$REPO/.venv/bin/python" ]]; then
  echo "==> Creating $REPO/.venv"
  python3 -m venv "$REPO/.venv"
else
  echo "==> .venv already present"
fi
SITE="$("$REPO/.venv/bin/python" -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"
echo "/usr/lib/python3/dist-packages" > "$SITE/system-dist-packages.pth"
"$REPO/.venv/bin/python" -c 'import gnuradio' 2>/dev/null \
  && echo "==> gnuradio importable from the venv" \
  || echo "!!  gnuradio NOT importable - is gnuradio installed? re-run sudo-setup.sh" >&2

# ---------------------------------------------------------------------- clone
if [[ -d "$PM/.git" ]]; then
  echo "==> PagerMon already cloned at $PM"
elif [[ -e "$PM" ]]; then
  # A half-finished clone leaves the directory in place; git clone would abort
  # on it with a bare "destination path already exists".
  echo "$PM exists but is not a git checkout - move or remove it, then re-run" >&2; exit 1
else
  echo "==> Cloning PagerMon into $PM"
  mkdir -p "$(dirname "$PM")"
  git clone --depth 1 "$PAGERMON_REPO" "$PM"
fi
[[ -d "$SRV" ]] || { echo "$SRV missing after clone - aborting" >&2; exit 1; }

# ---------------------------------------------------------------- npm install
# Gate on a package that must exist, not just the directory: an interrupted
# install leaves node_modules present but unusable.
if [[ ! -d "$SRV/node_modules/bcryptjs" ]]; then
  echo "==> Installing server dependencies (this takes several minutes on a Pi)"
  ( cd "$SRV" && npm install --no-audit --no-fund )
else
  echo "==> node_modules already present, skipping npm install"
fi

# -------------------------------------------------------------------- secrets
# Re-running must not lock you out. Regenerating the API key would orphan the
# running receiver mid-flight, and regenerating the password would print one
# credential while the file recorded another, so existing secrets are reused
# unless --regenerate is passed explicitly.
gen() { openssl rand -hex "$1" 2>/dev/null || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

REGENERATE=0
[[ "${1:-}" == "--regenerate" ]] && REGENERATE=1

REUSED=0
if [[ -f "$SRV/config/config.json" && $REGENERATE -eq 0 ]]; then
  read -r SESSION_SECRET API_KEY ADMIN_HASH < <(node -e '
    const c=require(process.argv[1]);
    const k=(c.auth&&c.auth.keys&&c.auth.keys[0]&&c.auth.keys[0].key)||"";
    process.stdout.write([
      (c.global&&c.global.sessionSecret)||"",
      k,
      (c.auth&&c.auth.encPass)||"",
    ].join(" "));
  ' "$SRV/config/config.json") || true
  if [[ -n "${SESSION_SECRET:-}" && -n "${API_KEY:-}" && -n "${ADMIN_HASH:-}" ]]; then
    REUSED=1
    echo "==> Reusing existing secrets from $SRV/config/config.json"
    echo "    (pass --regenerate for a fresh password and API key)"
  else
    echo "!!  existing config.json is missing secrets - generating new ones" >&2
  fi
fi

if [[ $REUSED -eq 0 ]]; then
  SESSION_SECRET=$(gen 24)
  API_KEY=$(gen 24)
  ADMIN_PASS=$(gen 9)
  # bcryptjs ships with PagerMon, so hash the password with the same library the
  # server verifies against.
  ADMIN_HASH=$(cd "$SRV" && node -e "
const b=require('bcryptjs');
process.stdout.write(b.hashSync(process.argv[1], 8));
" "$ADMIN_PASS")
fi

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
echo "==> Writing $REPO/pagermon-client.json"
cat > "$REPO/pagermon-client.json" <<JSON
{
  "hostname": "http://127.0.0.1:3000",
  "apikey": "$API_KEY",
  "identifier": "radio-pi"
}
JSON
chmod 600 "$REPO/pagermon-client.json"

# ----------------------------------------------------------- credentials file
IP="$(hostname -I | awk '{print $1}')"
if [[ $REUSED -eq 1 ]]; then
  echo "==> Keeping existing $REPO/pagermon-credentials.txt (password unchanged)"
else
cat > "$REPO/pagermon-credentials.txt" <<TXT
PagerMon credentials - generated $(date -Is)

  Web UI    http://$IP:3000
  Username  admin
  Password  $ADMIN_PASS

  API key   $API_KEY   (already written to $REPO/pagermon-client.json)

Change the password at /admin once you have logged in.
TXT
chmod 600 "$REPO/pagermon-credentials.txt"
fi

echo
echo "================================================================"
echo " PagerMon configured at $PM"
echo
echo "   URL       http://$IP:3000"
echo "   Username  admin"
if [[ $REUSED -eq 1 ]]; then
  echo "   Password  unchanged - see $REPO/pagermon-credentials.txt"
else
  echo "   Password  $ADMIN_PASS"
  echo
  echo " Saved to $REPO/pagermon-credentials.txt (mode 600)"
fi
echo "================================================================"
echo
echo "Now start everything with:  sudo bash $REPO/sudo-setup.sh"
