# Lid-closed awake & Tailscale

> Website-ready help. Seed `/docs/remote` (lid-closed section) or a dedicated `/docs/lid-closed` page. Tone: calm, plain language. No internal API names in the body.

---

## Keep your Mac reachable when the lid is closed

Closing a MacBook lid normally puts the Mac to sleep. Wi‑Fi and Tailscale drop, so your iPhone can no longer reach Tether.

**Lid-closed awake** is a one-time setup on the Mac. While you need the Mac online, Tether can keep it awake with the lid shut — then restore normal sleep when you are done.

Tether still encrypts every session with your pairing key. Tailscale only provides the network path.

---

## What you need

1. **Tether Host** on the Mac, **Tether** on the iPhone (already paired).
2. **Tailscale** on both devices, signed into the same tailnet, Connected.
3. Mac **Settings → Other networks** turned on, with a **Tailscale** address (`100.x…:52173`) in the setup code saved on the phone.
4. Mac **Settings → Lid-closed awake** → **Install on this Mac…** (password once in Terminal).

---

## Setup (once per Mac)

1. Open **Tether Host → Settings → Lid-closed awake**.
2. Tap **Install on this Mac…** and enter your Mac login password when Terminal asks.
3. When Terminal says **Done**, return to Tether and tap **Recheck**. Setup should say **Installed**.
4. Turn on **Prevent sleep while active**.
5. Keep **Other networks** on (or stay connected / keep an agent running).
6. Confirm **Right now** says **Holding awake** before you close the lid.

If Setup says **Needs repair**, run **Repair setup…** and enter your password again.

---

## Use it remotely

1. On the iPhone: Wi‑Fi off, cellular on, Tailscale **On**.
2. Connect to the Mac using the **100.x** address (not only a home Wi‑Fi address).
3. On the Mac, confirm **Holding awake**, then close the lid.
4. Keep working — browse files, send, or run a coding agent.

When nothing needs the Mac anymore (no session, no agent, or you turn Prevent sleep off / quit Host), normal sleep returns. If Host crashes, a small recovery helper clears the awake flag within about a minute.

---

## Staying connected over Tailscale

Cellular ↔ Tailscale links can stall for a few seconds without the Mac actually going away. Tether is built for that:

- Heartbeats wait longer and require several missed checks before treating the peer as gone.
- Recent file or terminal traffic counts as “still alive.”
- When you unlock the phone or the network path changes, Tether soft-checks twice before showing **Reconnecting…**.
- If the link really drops, the phone reconnects with backoff and can resume a live agent.

You should not lose a whole session because of one brief blip.

---

## Battery

Keeping a closed MacBook awake uses more power than sleep. That is the tradeoff for Tailscale staying up.

| Choice | Effect |
|---|---|
| Prefer **AC power** | Best for long lid-closed sessions |
| **Hold awake on battery** **On** (default) | Lid-closed hold works while unplugged |
| **Hold awake on battery** **Off** | Lid-closed hold only while plugged in — saves battery on the go |
| macOS **Low Power Mode** | Leave **off** for Tailscale reliability during remote use |
| iPhone Low Power Mode | Fine; it does not replace Tailscale or Tether settings |

On battery, Host also spaces its light network keepalives further apart so radios wake less often.

**Safety:** use a ventilated surface with the lid closed — not a bag or soft case.

---

## Quick checklist

| Check | OK when |
|---|---|
| Tailscale on Mac + iPhone | Both Connected, same tailnet |
| Setup code on phone | Shows `100.x…:52173` |
| Lid-closed setup | **Installed** |
| Prevent sleep | **On** |
| Right now | **Holding awake** before the lid closes |
| Phone test | Wi‑Fi off, cellular + Tailscale, then close the lid |

---

## FAQ

**Do I need a relay if I use Tailscale?**  
No. Leave the relay field empty for the Tailscale-only path.

**Is the setup code a password for my files?**  
No. It carries routing info. Files and terminal still need the paired device key. Treat the code as private.

**Why does same-home Wi‑Fi still work when Tailscale is wrong?**  
Local discovery can hide a bad remote path. Always test with phone Wi‑Fi off.

**What gets installed on the Mac?**  
A narrow privilege rule for sleep settings, a small helper script, and a user LaunchAgent. You can remove them anytime from the same Settings tab.

---

## Related

- Full remote options (Tailscale, relay, port forward): [remote-access.md](./remote-access.md)
- Product overview: [README.md](../../README.md)
