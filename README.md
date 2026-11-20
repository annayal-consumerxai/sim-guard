# sim-guard

Run Claude Code, Codex or Cursor agents on iOS apps without cooking your Mac.

Every agent that builds an iOS app wants its own simulator. A stock one idles at about 3.5 GB of RAM and 130+ processes. Run a few agents in parallel and your laptop turns into a space heater.

sim-guard is an agent skill plus one bash script. It caps how many sims can be booted, makes agents share a small pool of slimmed sims instead of creating new ones, and cleans each sim up after a run.

On my M5 Pro, a pool sim boots at 382 MB and 57 processes. The stock sim next to it was using 3.5 GB.

## What it does

- Caps booted sims at 2 machine-wide and refuses to boot when Mac memory free drops under 25%
- Keeps a fixed pool of sims, slimmed with [simslim](https://github.com/MobAI-App/simslim), so agents never create a sim per task
- Wipes user apps and the keychain, then shuts the sim down after every run
- Audits what's booted: RAM, CPU, slim or not, and which sims are orphans no agent owns

## Install

```bash
brew install mobai-app/tap/simslim
git clone https://github.com/fire-eclairs/sim-guard ~/.claude/skills/sim-guard
~/.claude/skills/sim-guard/sim-guard.sh init
```

`init` picks 2 iPhone sims on your newest iOS runtime and slims them. StoreKit, push and universal links stay on, so paywalls and deep links still work.

For Codex, clone it anywhere and add a line to `AGENTS.md` telling agents to read `sim-guard/SKILL.md` before touching a simulator.

## Commands

```
sim-guard.sh init [N]          pick N pool sims and slim them
sim-guard.sh audit             what's booted, how heavy, who owns it
sim-guard.sh preflight         exit 1 if at the cap or memory is low
sim-guard.sh acquire           boot a free pool sim, print its UDID
sim-guard.sh release <udid>    wipe apps + keychain, shut down
```

Settings are env vars: `SIM_CAP` (default 2), `MIN_FREE_PCT` (default 25), `SIMSLIM_EXCEPT` (default `store,web`), `SIM_GUARD_CONFIG` (default `~/.config/sim-guard/pool`).

## Heads up

`release` uninstalls every user app on that sim. That's the point, but don't point it at a sim you use by hand.

## Credit

The heavy lifting is [simslim](https://github.com/MobAI-App/simslim) by MobAI, which turns off the simulator daemons you don't need. sim-guard is the set of rules for agents on top of it. The rules came out of an X thread on parallel agents melting Mac Studios.

MIT. Built by [An Nayal](https://annayal.com) ([@consumerxai](https://x.com/consumerxai)).
