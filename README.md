# HomeAwake

HomeAwake keeps a MacBook awake while it is at home on AC power, so remote sessions you start from your phone can
reach it. With the one-time lid-closed setup, it stays awake with the lid shut too. On battery, on any other network,
or when paused, the Mac sleeps normally.

HomeAwake knows it is home by the MAC address of the Wi-Fi router (the default gateway). macOS lets any app read that
address without Location permission, unlike the network name.

## Install

1. Build the app.

	```sh
	scripts/build-app.sh
	```

2. Copy `build/HomeAwake.app` to `/Applications`.
3. Open HomeAwake. It installs its background agent and shows the current status.
4. At home, click **Use this network as home**.
5. Click **Done**. The window closes, and the agent keeps running.

Open HomeAwake again whenever you want to see the status, pause, or change the home network. If you move the app,
open it once from the new place so the agent follows.

## Keep the Mac awake with the lid closed

Without this setup, HomeAwake keeps the Mac awake only while the lid is open. macOS lets an ordinary app's sleep
assertion block idle sleep, but only Apple-signed software can block lid-close sleep. The one switch left is
`pmset disablesleep`, and it needs root.

To set it up, click **Set up lid-closed mode…** and enter your password once. HomeAwake installs
`/etc/sudoers.d/homeawake`, which lets your user run exactly these three commands without a password:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
/usr/bin/pmset sleepnow
```

`visudo` checks the rule before it is installed. After that, the agent turns `disablesleep` on at home and off
everywhere else. If you unplug the Mac with the lid closed, the agent turns `disablesleep` off and puts the Mac to
sleep right away.

## What runs, and what it costs

HomeAwake has two programs in one app bundle.

- `HomeAwake` is the window you open. It quits when you click **Done**.
- `homeawake-agent` runs all the time as a LaunchAgent (`~/Library/LaunchAgents/dev.homeawake.agent.plist`) with
  `ProcessType` set to `Background`. It links Foundation, IOKit, and SystemConfiguration, but not AppKit.

The agent has no timer. It wakes only when the power source switches between AC and battery, when the network
changes, when the Mac wakes from sleep, or when you change a setting. Right after a network change, it can retry the
router lookup up to four times over 30 seconds.

Measured on a MacBook Pro with Apple M5 and macOS 26.6, over five runs of `scripts/measure-agent.sh`:

- Memory (`phys_footprint` 10 seconds after launch) was 2080 to 2128 KB, with a median of 2096 KB. RSS was about
  7 MB, most of it system libraries that other processes share.
- Idle wakeups over 60 seconds were 0 in every run.
- CPU time over 70 seconds was under 10 ms in every run. `top` shows `00:00.00`.

The window app uses no memory once you click **Done**, because it quits.

Keeping a Mac awake uses more wall power than letting it sleep. That cost comes from the awake Mac, not from the
agent, and HomeAwake pays it only at home on AC power.

## What HomeAwake cannot do

- It cannot wake a Mac that is already asleep. Wake-on-LAN to a MacBook on Wi-Fi is not dependable. If the Mac sleeps
  at home, for example because you closed the lid before lid-closed mode was set up, open the lid to wake it.
- It recognizes home by the router. A full-tunnel VPN that replaces the default route can hide the router, and then
  HomeAwake treats the Mac as away.

## Files

- `~/Library/Application Support/HomeAwake/prefs.json` holds your home networks and the pause switch. Only the app
  writes it.
- `~/Library/Application Support/HomeAwake/status.json` holds what the agent last saw. The agent rewrites it only
  when that changes.

## Remove HomeAwake

Open HomeAwake and click **Remove HomeAwake**. It stops the agent, deletes the LaunchAgent, and turns
`disablesleep` off. Your settings stay in `~/Library/Application Support/HomeAwake`. The lid-closed rule stays too.
To delete it, run:

```sh
sudo rm /etc/sudoers.d/homeawake
```

## Develop

```sh
swift build -c release
swift test
scripts/build-app.sh
scripts/check-agent.sh     # holds a sleep assertion for a few seconds under a scratch HOME
scripts/measure-agent.sh   # 70 s run: footprint, idle wakeups, and CPU
```
