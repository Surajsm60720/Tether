# Tether

Tether lets an iPhone browse, preview, download, and upload files on a Mac over the local network. There is no cloud account and no password. The Mac app is a menu-bar host. The iPhone app is the client.

## Open the project

Open `Tether.xcodeproj` in Xcode 16 or later.

## Run on your Mac

1. Select the **TetherHost** scheme and **My Mac**.
2. Press Run.
3. Tether appears in the menu bar (it does not show a Dock icon).
4. Choose **Add folder…** and pick a folder to share. Nothing else on the Mac is visible.
5. Folders start as **Read only**. In Settings → Folders, turn on **Can upload** for any folder the iPhone should be allowed to add files to.
6. Choose **Pair new iPhone…**. A QR code and a 16-character code stay valid for two minutes.

## Run on your iPhone

The iPhone build has to be signed with your Apple ID. Simulator builds are already configured; a physical iPhone is not.

1. Connect the iPhone with a cable, or choose it as a wireless device.
2. Select the **TetherClient** scheme and your iPhone.
3. Open the target’s **Signing & Capabilities** tab. Set **Team** to your Apple ID and leave the bundle id as `app.tether.client` (change it only if Xcode says it is already taken).
4. Press Run. On the phone, trust the developer certificate if iOS asks (Settings → General → VPN & Device Management).
5. Keep the Mac and iPhone on the same Wi-Fi. A phone hotspot works when a guest network blocks device-to-device traffic.
6. On the iPhone, tap **Continue** for Local Network access, then **Allow** on the system prompt.
7. Tap **Pair**, scan the code on the Mac, then tap **Allow** on the Mac.
8. Browse folders, tap a file to preview it, and use the Terminal tab for `ls`, `cat`, `open`, and `get`.

To try the interface with no second device, open Settings on the iPhone and turn on **Demo**. Sample files appear under Demo Mac.

## Tests

```bash
swift test --package-path Packages/TetherCore
```
