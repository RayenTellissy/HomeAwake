# HomeAwake

HomeAwake keeps a MacBook awake while it is at home on AC power, so remote sessions you start from your phone can
reach it. With the one-time lid-closed setup, it stays awake with the lid shut too. On battery, on any other network,
or when paused, the Mac sleeps normally. When the Mac has no network, for example while the router restarts,
HomeAwake changes nothing until the network is back, so a Mac that was awake at home stays awake.

HomeAwake knows it is home by the MAC address of the Wi-Fi router (the default gateway). macOS lets any app read that
address without Location permission, unlike the network name.

## Install

1. Build the app.

	```sh
	scripts/build-app.sh
	```

2. Copy `build/HomeAwake.app` to `/Applications`.
3. Open HomeAwake. It installs its background agent and shows the current status. The line under the status names
   this network's router and says whether lid-closed mode is available.
4. At home, click **Use this network as home**. HomeAwake saves the router named in that line.
5. Click **Done**. The window closes, and the agent keeps running.

Open HomeAwake again whenever you want to see the status, pause, or change the home network. If you move the app,
open it once from the new place so the agent follows.

## Keep the Mac awake with the lid closed

Without this setup, HomeAwake keeps the Mac awake only while the lid is open. macOS lets an ordinary app's sleep
assertion block idle sleep, but only Apple-signed software can block lid-close sleep. The one switch left is
`pmset disablesleep`, and it needs root.

Lid-closed mode needs a sudoers rule that lets your user run these two commands without a password:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

HomeAwake reads `sudo -n -l` to find out whether any rule grants both. If another tool already installed such a rule,
lid-closed mode is available right away, and there is nothing to set up. Otherwise, click **Set up lid-closed mode…**
and enter your password once. HomeAwake installs `/etc/sudoers.d/homeawake` with exactly those two commands. `visudo`
checks the rule before it goes live.

### HomeAwake turns off only what it turned on

`disablesleep` is one switch for the whole Mac, and other tools can set it too. HomeAwake follows these rules:

- At home on AC power, if `disablesleep` is off, the agent turns it on and records in `status.json` that HomeAwake
  owns it.
- If `disablesleep` is already on when HomeAwake needs it, HomeAwake leaves it alone and does not take ownership.
  That switch belongs to the tool that set it.
- Away from home, on battery, or when paused, the agent turns `disablesleep` off only if HomeAwake owns it. It never
  turns off another tool's switch.
- If you unplug the Mac with the lid closed while HomeAwake owns the switch, the agent turns `disablesleep` off and
  asks macOS to sleep right away, so the Mac does not stay awake in a bag. It makes that request itself, without
  sudo.

The agent reads ownership back from `status.json` when it starts, so a crash or restart does not lose track of it.

## What runs, and what it costs

HomeAwake has two programs in one app bundle.

- `HomeAwake` is the window you open. It quits when you click **Done**.
- `homeawake-agent` runs all the time as a LaunchAgent (`~/Library/LaunchAgents/dev.homeawake.agent.plist`) with
  `ProcessType` set to `Background`. It links Foundation, IOKit, and SystemConfiguration, but not AppKit.

The agent has no timer. It wakes only when the power source switches between AC and battery, when the network
changes, when the Mac wakes from sleep, or when you change a setting. Right after a network change, it can retry the
router lookup up to four times over 30 seconds.

Measured on a MacBook Pro with Apple M5 and macOS 26.6:

- Memory (`phys_footprint` 10 seconds after launch) ranged from 2048 to 2656 KB over two sets of five runs, with
  medians of 2048 KB and 2608 KB. A bare run loop with the same event
  sources and no work measures about 1.8 MB, so HomeAwake's own code adds 0.25 to 0.8 MB. RSS was about 8 MB, most of
  it system libraries that other processes share.
- Idle wakeups over 60 seconds were 0 in every run.
- CPU time over 70 seconds was `00:00.01` in `top` in every run, which is its smallest step of 10 ms.

The window app uses no memory once you click **Done**, because it quits.

Keeping a Mac awake uses more wall power than letting it sleep. That cost comes from the awake Mac, not from the
agent, and HomeAwake pays it only at home on AC power.

## What HomeAwake cannot do

- It cannot wake a Mac that is already asleep. Wake-on-LAN to a MacBook on Wi-Fi is not dependable. If the Mac sleeps
  at home, for example because you closed the lid before lid-closed mode was set up, open the lid to wake it.
- It does not turn off a `disablesleep` that another tool turned on. While that tool keeps it on, the Mac stays awake
  everywhere, with the lid open or closed.
- It recognizes home by the router. A full-tunnel VPN that replaces the default route can hide the router. HomeAwake
  then sees no network and keeps the Mac as it was, so a VPN turned on at home keeps the Mac awake, and an agent that
  starts with the VPN already on lets the Mac sleep normally.

## Files

- `~/Library/Application Support/HomeAwake/prefs.json` holds your home networks and the pause switch. Only the app
  writes it.
- `~/Library/Application Support/HomeAwake/status.json` holds what the agent last saw and whether HomeAwake owns
  `disablesleep`. The agent writes it, and only when that changes. **Remove HomeAwake** also writes it when the agent
  was not running to turn the switch off itself.

## Remove HomeAwake

Open HomeAwake and click **Remove HomeAwake**. It stops the agent, deletes the LaunchAgent, and turns
`disablesleep` off if HomeAwake owns it. Your settings stay in `~/Library/Application Support/HomeAwake`. The
lid-closed rule stays too. If HomeAwake installed it, you can delete it with this command:

```sh
sudo rm /etc/sudoers.d/homeawake
```

## Develop

```sh
swift build -c release
swift test
scripts/build-app.sh
scripts/check-agent.sh     # holds a sleep assertion for a few seconds under a scratch CFFIXED_USER_HOME
scripts/measure-agent.sh   # five 70 s runs: footprint, idle wakeups, and CPU, with the median and range
```

Both scripts run the agent through `scripts/sandboxed.sh`, which blocks it from running `sudo` or `pmset`, so a test
run cannot change `disablesleep` even on a Mac where a sudoers rule allows it.
