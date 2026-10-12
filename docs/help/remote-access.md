# Remote access: iPhone to Mac from another network

This guide is for product help, FAQ, and website copy. It explains how to open a Mac that sits on home Wi‑Fi from an iPhone on cellular, another Wi‑Fi, or any network that is not the same LAN.

Tether does not create a VPN by itself. Same-Wi‑Fi discovery uses Bonjour. Away from that network, the phone needs a **reachable path** to the Mac: Tailscale (recommended), a public address with a port forward, or a small outbound relay.

---

## Mental model

| Situation | How the phone finds the Mac |
|---|---|
| Same home Wi‑Fi | Bonjour (`_tether._tcp`). Local only. Cellular is not used for this path. |
| Phone on cellular / other Wi‑Fi / far away | Saved **Other networks** setup code: try the Mac’s reachable address, then the relay if one is set. |

A home address such as `192.168.x.x` only exists inside that Wi‑Fi. The internet cannot route to it. Turning on “Allow connections from other networks” and listening on port **52173** is necessary, but not enough if the setup code still points at that private Wi‑Fi address.

```
iPhone (cellular) → Tailscale mesh → Mac (100.x) → Tether port 52173 → encrypted pairing session
```

Tailscale is the tunnel. Tether still encrypts files and terminal traffic with the pairing key. A relay only forwards bytes; it never gets the device key.

Connection order on the phone:

1. If the Mac is visible on the local network, use that.
2. Otherwise try the saved address (prefer Tailscale `100.x` when present).
3. Otherwise open the saved relay.

---

## Prerequisites (all remote options)

1. Pair the iPhone with the Mac **once on the same Wi‑Fi** (QR code or typed pairing code; Allow on the Mac).
2. Keep **Tether Host** running on the Mac, with at least one shared folder if you want to browse files.
3. On the Mac, open **Other networks** and turn **on** **Allow connections from other networks**. The Mac listens on port **52173**.
4. Copy a **fresh** setup code after the reachable address (or relay) is correct, and paste it on the iPhone under **Settings → Other networks → Save**.

The setup code is tied to a Mac you already paired. It carries the Mac id, the address, an optional relay, and a rendezvous token. The token is **not** the file-encryption key. Someone who has only the token still cannot pass the pairing handshake. Do not publish the setup code.

---

## Option A — Tailscale (recommended)

Closest to “access home services from my phone over Tailscale.” No router port forward. Works from another room on cellular, or from hundreds of kilometres away, as long as both devices are online on the same Tailscale network (tailnet).

### A1. Tailscale on the Mac

1. Install [Tailscale for macOS](https://tailscale.com/download/mac) (standalone or Mac App Store).
2. Sign in and leave Tailscale **Connected**.
3. Confirm this Mac’s Tailscale IPv4 address:
   ```bash
   tailscale ip -4
   ```
   You want something like `100.64.1.23` (any address in the Tailscale `100.x` range).
4. Optional: in the Tailscale admin console, note MagicDNS / the machine hostname (`your-mac.tailnet-name.ts.net`) if you prefer a name over the IP.

### A2. Tailscale on the iPhone

1. Install Tailscale from the App Store.
2. Sign in with the **same account / same tailnet** as the Mac.
3. Turn Tailscale **On** and allow the VPN configuration when iOS asks.
4. Confirm the Mac appears as an online peer in Tailscale.

Both devices must stay signed in and connected for remote Tether use.

### A3. Bake Tailscale into Tether on the Mac

1. Open **Tether Host → Settings → Other networks** (⌘, or the sidebar Settings link).
2. Turn **on** **Allow connections from other networks**.
3. Under **Addresses**, confirm a row labeled **Tailscale** with something like `100.x.y.z:52173`.
   - If you only see **This network** (`192.168…` / `10.…`), Tailscale is not up on the Mac yet. Connect Tailscale, then leave Other networks and reopen it (or restart Host) so addresses refresh.
4. Leave **Address the iPhone should use** blank so Tether auto-picks Tailscale (it prefers Tailscale over Wi‑Fi).
   - Or set it explicitly to `100.x.y.z` or `100.x.y.z:52173`, then **Save addresses**.
5. Leave **Relay address** empty for the Tailscale-only path.
6. Under **iPhone setup**, **Copy code** (it starts with `tether://remote?...`).

Status should indicate the Mac is listening. Port is **52173**.

### A4. Save the code on the iPhone

1. Open **Tether → Settings → Other networks**.
2. Paste the code → **Save**.
3. Under the Mac’s name you should see a summary like `Address 100.x.y.z:52173`, **not** only a `192.168…` address.
4. If you still see a Wi‑Fi-only address, remove the old remote route, copy a **fresh** code from the Mac after the Tailscale row appears, and save again.

### A5. Everyday use after setup

1. Mac: home Wi‑Fi, Tailscale connected, Tether Host running, remote listening on.
2. iPhone: Tailscale On. On cellular or any other network, open Tether and tap the Mac.
3. On the same home Wi‑Fi, Tether still prefers local Bonjour when the Mac is visible. The saved Tailscale route is for when that local path is not available.

Useful extras:

- Turn on **Prevent sleep while active** so the Mac does not idle-sleep mid-session.
- For a closed lid: Mac **Settings → Lid-closed awake** → install once, leave Prevent sleep and Other networks on until **Right now** says Holding awake, then close the lid. Prefer AC power; keep Low Power Mode off.
- **Hold awake on battery** (same tab): leave on for lid-closed work away from a charger; turn off to save battery when unplugged (lid-closed hold waits until you plug in).
- Keep Tailscale **Connected** on Mac and iPhone for cellular / other-network use. Brief Tailscale stalls should reconnect quietly without wiping a live session.

---

## Option B — Outbound relay (no Tailscale, no router changes)

Use when you can run a small program on a machine that has a public host:port (VPS, always-on server, etc.). The Mac and the iPhone both connect **out** to the relay, so the home router needs no port forward.

1. On the public machine:
   ```bash
   cd Packages/TetherCore
   swift run tether-relay 52174
   ```
   Leave that process running. Default relay port is **52174**.
2. On the Mac: **Other networks** → turn remote listening on → enter the relay as `example.com:52174` (your host) → **Save addresses**.
3. Copy a fresh setup code → paste on the iPhone → **Save**.
4. Test with the phone on cellular. Both sides dial out to the relay; the relay only forwards bytes after the encrypted handshake headers.

---

## Option C — Public address + port forward

1. On the home router, forward WAN TCP **52173** to the Mac’s LAN address on port **52173**.
2. On the Mac: **Other networks** → turn remote listening on → put the public hostname or IP in **Address the iPhone should use** (for example `home.example.com:52173`) → **Save addresses**.
3. Copy a fresh setup code → paste on the iPhone → **Save**.
4. Prefer Tailscale or the relay when you can; an open port is reachable by anyone who can route to it. They still need a paired device key to read files, but do not publish the setup code.

---

## What each address kind means (Mac → Other networks → Addresses)

| Label | Example | Works from cellular / far away? |
|---|---|---|
| **This network** | `192.168.x.x:52173` | No (unless you also port-forward that machine) |
| **Tailscale** | `100.x.y.z:52173` | Yes, if both devices are on the same tailnet |
| **VPN** | other tunnel IP | Yes, if both sides share that VPN |
| **Public** | public IP / hostname | Yes, if routing and firewall allow it |
| **Relay** field filled | `host:52174` | Yes, both sides dial out |

On the phone, **Settings → Other networks** should show `Address 100.…:52173` and/or a relay — not only `192.168.…` — for real remote use.

---

## Test plan

### Same Wi‑Fi (sanity)

Phone and Mac on home Wi‑Fi → open Tether → connect → browse a folder. Local discovery should work even without Tailscale.

### Cellular + Tailscale (the real remote test)

1. Mac on home Wi‑Fi, Tailscale connected, Tether Host listening with a **Tailscale** address in the setup code.
2. iPhone: **Wi‑Fi off**, cellular on, Tailscale **On**.
3. Open Tether. The Mac row may say **Saved for other networks**.
4. Tap the Mac → connect without standing next to the laptop.
5. List files, open a small preview, run a short terminal command (`pwd`, `ls`).
6. Walk to another room or leave the house. The session should stay up or reconnect over Tailscale, not only when you are 1–2 m from the laptop.

### Distance

If the cellular + Tailscale test works at home, distance does not matter as long as both Tailscale peers stay online. “1000 km away” is the same path as “other room on cellular.”

### Why a walk across the house can still fail without Tailscale

If the phone is on cellular but the saved code still has a `192.168…` address:

1. Near the laptop, the phone may still rediscover the Mac via local Wi‑Fi / Bonjour when radio allows it.
2. Far from the AP on cellular, local discovery dies and the private address is unreachable → offline.

That is expected LAN behavior, not a broken remote feature. Fix it by putting a Tailscale, public, or relay address into a **new** setup code.

---

## Troubleshooting checklist

| Check | What you want |
|---|---|
| Pairing | Phone appears under paired iPhones on the Mac |
| Mac Tailscale | Connected; `tailscale ip -4` shows `100.…` |
| Mac Other networks | **Allow connections…** on; **Tailscale** row visible |
| Phone Tailscale | Connected to the **same** tailnet (VPN icon) |
| Phone saved summary | `Address 100.…:52173` (or a relay), not only `192.168…` |
| Fresh code | Re-copy after Tailscale appears; discard an old Wi‑Fi-only code |
| Host running | Tether Host open; Mac not asleep / offline on Tailscale |
| Firewall | Allow Tether Host / inbound TCP 52173 on the Tailscale interface if macOS asks |
| Relay (if used) | `tether-relay` still running; address matches what you saved |

---

## FAQ (website-ready)

**Can I use Tether from mobile data while my laptop stays on home Wi‑Fi?**  
Yes. Pair once on Wi‑Fi, then use Tailscale (recommended), a relay, or a forwarded public address, and save the Mac’s setup code on the phone.

**Is listening on port 52173 enough?**  
No. The phone must have a setup code whose address (or relay) is actually reachable from the phone’s network. A home `192.168…` address is not reachable over cellular by itself.

**Does Tether replace Tailscale?**  
No. Tailscale (or another tunnel / relay / port forward) provides the network path. Tether provides pairing, encryption, files, terminal, and agents on top of that path.

**Do I need a relay if I use Tailscale?**  
No. Leave the relay field empty for the Tailscale-only path.

**Is the setup code a password for my files?**  
No. It carries routing info and a rendezvous token. File and terminal bytes still require the paired device key. Still treat the code as private.

**Does same-Wi‑Fi use go through Tailscale or the relay?**  
No. When Bonjour sees the Mac on the local network, Tether uses that path first.

**Why did reconnect only work when I stood next to the laptop?**  
You were likely still depending on local Wi‑Fi discovery. Configure Tailscale (or relay / public address) and save a fresh code that shows `100.…` or a relay on the phone.

**Will coding agents work remotely?**  
Yes, over the same encrypted session once the remote path is working. Keep the Mac awake (Prevent sleep while active, and lid-closed privilege if you close the lid) so long agent runs are not cut off.

**What if I close the MacBook lid?**  
Idle-sleep prevention alone is not enough. Install lid-closed privilege so Tether can set `disablesleep` while a session is active. If Host dies, a recovery agent undoes that flag so the Mac is not stuck awake.

**Does lid-closed awake drain the battery?**  
Holding the Mac awake with the lid closed uses more power than sleep — that is the tradeoff for Tailscale staying up. Prefer AC for long sessions. Turn off **Hold awake on battery** if you only want lid-closed hold while plugged in. On battery, Host also spaces network keepalives further apart.

**Why did the phone say Reconnecting after a short Tailscale blip?**  
Older builds treated a short stall as a dead peer. Current builds soft-probe twice and keep the session when traffic is still flowing; a true drop still reconnects with backoff.

---

## Quick comparison

| Setup | Cellular / other network / long distance |
|---|---|
| Listen 52173 + Wi‑Fi IP only | No |
| Tailscale on Mac + iPhone + new code with `100.x` | Yes |
| `tether-relay` + new code | Yes |
| Public IP + port forward + new code | Yes |

---

## Related in this repo

- Short overview: [README.md](../../README.md) → **Other networks**
- Product requirements: [PRD.md](../PRD.md)
- Design notes: [DESIGN.md](../DESIGN.md)

Ports used by Tether for remote access:

| Port | Role |
|---|---|
| **52173** | Direct listen on the Mac when Other networks is enabled |
| **52174** | Default `tether-relay` port |
