#!/bin/bash
# sim-guard: stop AI coding agents from melting your Mac with iOS simulators.
# https://github.com/annayal-consumerxai/sim-guard  (MIT)
#
#   sim-guard.sh init [N]        pick N iPhone sims on the newest iOS runtime as the shared pool and slim them (default: SIM_CAP)
#   sim-guard.sh audit           list booted sims: RAM, CPU, slim or not, pool or orphan, plus shutdown commands
#   sim-guard.sh preflight       audit, then exit 1 if at the sim cap or Mac memory is low
#   sim-guard.sh acquire         preflight, then boot a free pool sim (slim) and print its UDID
#   sim-guard.sh release <udid> [--keep-apps]
#                                remove user apps, reset keychain, shut the sim down
#
# Settings (env vars):
#   SIM_CAP           max booted sims machine-wide (default 2)
#   MIN_FREE_PCT      refuse to boot below this % of free memory (default 25)
#   SIMSLIM_EXCEPT    simslim categories to keep on (default "store,web": StoreKit, push, universal links)
#   SIM_GUARD_CONFIG  pool file (default ~/.config/sim-guard/pool)

set -u
CAP="${SIM_CAP:-2}"
MIN_FREE="${MIN_FREE_PCT:-25}"
EXCEPT="${SIMSLIM_EXCEPT:-store,web}"
CONFIG="${SIM_GUARD_CONFIG:-$HOME/.config/sim-guard/pool}"

need() { command -v "$1" >/dev/null || { echo "missing: $1 ($2)"; exit 2; }; }
need xcrun "install Xcode"
need simslim "brew install mobai-app/tap/simslim"
need python3 "xcode-select --install"

POOL=()
if [ -f "$CONFIG" ]; then
  while read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d '[:space:]')"
    [ -n "$line" ] && POOL+=("$line")
  done < "$CONFIG"
fi

free_pct() { memory_pressure 2>/dev/null | awk -F': ' '/free percentage/{gsub("%","",$2); print $2}'; }

booted_udids() {
  xcrun simctl list devices booted --json | python3 -c '
import json,sys
for devs in json.load(sys.stdin)["devices"].values():
    for d in devs:
        if d.get("state")=="Booted": print(d["udid"])'
}

init_pool() {
  local n="${1:-$CAP}"
  mkdir -p "$(dirname "$CONFIG")"
  local picks
  picks="$(xcrun simctl list devices available --json | N="$n" python3 -c '
import json,os,re,sys
devs=json.load(sys.stdin)["devices"]
def ver(k):
    m=re.search(r"iOS-(\d+)-(\d+)",k); return (int(m.group(1)),int(m.group(2))) if m else None
ios=sorted([k for k in devs if ver(k)], key=ver, reverse=True)
if not ios: sys.exit("no iOS runtime installed")
phones=[d for d in devs[ios[0]] if d["name"].startswith("iPhone")]
for d in phones[:int(os.environ["N"])]:
    print(d["udid"], "#", d["name"], ios[0].split(".")[-1])')" || return 1
  [ -z "$picks" ] && { echo "No iPhone simulators found. Create one in Xcode first."; return 1; }
  echo "# sim-guard pool: agents reuse these, never create sims per task" > "$CONFIG"
  echo "$picks" >> "$CONFIG"
  echo "Pool written to $CONFIG:"; echo "$picks"
  local u
  while read -r u _; do
    echo "Slimming $u (keeps: $EXCEPT)..."
    simslim on "$u" --except "$EXCEPT" --preserve-boot-state | tail -1
  done <<< "$picks"
}

audit() {
  local snap; snap="$(simslim top --json 2>/dev/null)"
  local pool_csv; pool_csv="$(IFS=,; echo "${POOL[*]:-}")"
  SNAP="$snap" POOL_CSV="$pool_csv" CAP="$CAP" python3 - <<'PY'
import json, os, subprocess
pool = set(filter(None, os.environ["POOL_CSV"].split(",")))
cap = int(os.environ["CAP"])
try: sims = json.loads(os.environ["SNAP"] or "{}").get("sims", [])
except Exception: sims = []
sims = [s for s in sims if s.get("state") == "Booted"]
total = sum(s.get("memory", {}).get("bytes", 0) for s in sims)
print(f"Booted simulators: {len(sims)} (cap {cap}), total RAM {total/1e9:.2f} GB")
if not pool: print("No pool yet. Run: sim-guard.sh init")
orphans = []
for s in sims:
    mem = s.get("memory", {})
    dis, tot = s.get("managedDisabled", 0), s.get("managedTotal", 0) or 1
    slim = "slim" if dis / tot > 0.5 and mem.get("bytes", 0) < 1.5e9 else "NOT slim"
    owner = "pool" if s["udid"] in pool else "orphan"
    if s["udid"] not in pool: orphans.append(s)
    print(f"  {s['udid']}  {s['name']:<20} {s.get('platform','')} {s.get('osVersion',''):<5} "
          f"{mem.get('bytes',0)/1e9:5.2f} GB  {mem.get('processes',0):>3} procs  cpu {mem.get('cpu',0):.1f}%  {slim}  [{owner}]")
ps = subprocess.run(["ps","-axo","comm="], capture_output=True, text=True).stdout
hints = [n for n in ("mcpbridge","xcodebuild","Simulator","codex","claude","cursor") if n in ps.lower()]
print("Agent/sim tooling running:", ", ".join(hints) or "none")
if orphans:
    print("Orphans (not in the pool). Make sure no live agent is using them, then:")
    for s in orphans: print(f"  simslim shutdown {s['udid']}")
if len(sims) > cap: print(f"OVER CAP by {len(sims)-cap}.")
PY
  echo "Mac memory free: $(free_pct)% (floor ${MIN_FREE}%)"
}

preflight() {
  audit
  local n free; n=$(booted_udids | wc -l | tr -d ' '); free=$(free_pct)
  if [ "$n" -ge "$CAP" ]; then
    echo "BLOCKED: $n sims booted, cap is $CAP. Reuse a pool sim you own, wait, or shut down an orphan."
    return 1
  fi
  if [ -n "$free" ] && [ "$free" -lt "$MIN_FREE" ]; then
    echo "BLOCKED: only ${free}% memory free. Close something before booting a sim."
    return 1
  fi
  echo "OK to boot one more sim."
}

acquire() {
  [ "${#POOL[@]}" -eq 0 ] && { echo "No pool yet. Run: sim-guard.sh init"; return 1; }
  local booted; booted="$(booted_udids)"
  preflight || return 1
  local u
  for u in "${POOL[@]}"; do
    echo "$booted" | grep -q "$u" && continue
    echo "Booting pool sim $u (slim)..."
    simslim boot "$u" >/dev/null || return 1
    if ! simslim verify "$u" --except "$EXCEPT" >/dev/null 2>&1; then
      echo "Slim profile drifted, re-applying..."
      simslim on "$u" --except "$EXCEPT" >/dev/null || return 1
    fi
    simslim measure "$u"
    echo "ACQUIRED $u"
    return 0
  done
  echo "BLOCKED: every pool sim is already booted. Reuse one you own, or wait."
  return 1
}

release() {
  local u="${1:-}"; local keep="${2:-}"
  [ -z "$u" ] && { echo "usage: sim-guard.sh release <udid> [--keep-apps]"; return 2; }
  if [ "$keep" != "--keep-apps" ]; then
    xcrun simctl listapps "$u" 2>/dev/null | plutil -convert json -o - - 2>/dev/null | python3 -c '
import json,sys
try: apps=json.load(sys.stdin)
except Exception: apps={}
for bid,a in apps.items():
    if a.get("ApplicationType")=="User": print(bid)' | while read -r bid; do
      echo "uninstall $bid"; xcrun simctl uninstall "$u" "$bid"
    done
    xcrun simctl keychain "$u" reset && echo "keychain reset"
  fi
  simslim shutdown "$u" && echo "RELEASED $u"
}

case "${1:-audit}" in
  init) shift; init_pool "$@" ;;
  audit) audit ;;
  preflight) preflight ;;
  acquire) acquire ;;
  release) shift; release "$@" ;;
  *) sed -n 2,19p "$0"; exit 2 ;;
esac
