# Releasing MacShow

`scripts/make-dmg.sh` builds `build/MacShow.dmg`. Without the steps below it's
signed ad-hoc: it runs on the Mac that built it, but other Macs will warn that
it can't be checked for malicious software. Making it open cleanly everywhere
needs a paid Apple Developer account.

## 1. Developer ID signing

1. In the Apple Developer portal, create a **Developer ID Application** certificate
   and install it in your keychain.
2. Find its name: `security find-identity -v -p codesigning`
3. Add the hardened runtime to the signing step in `scripts/build-app.sh`
   (`codesign --options runtime …`), then build:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/make-dmg.sh
```

## 2. Notarization

Store an app-specific password once, then submit and staple each release:

```bash
xcrun notarytool store-credentials MacShow --apple-id you@example.com --team-id TEAMID
xcrun notarytool submit build/MacShow.dmg --keychain-profile MacShow --wait
xcrun stapler staple build/MacShow.dmg
```

If notarization reports problems with the bundled libraries, `xcrun notarytool log <id>`
lists them. mpv is set not to load any Lua scripts (user scripts, config, and its
built-in ones like the stats overlay and console), so LuaJIT should never start and
the `allow-jit` entitlement shouldn't be needed. Check this on the first hardened
build by playing a file and watching Console for code-signing errors.

## Licenses

`scripts/build-app.sh` copies `Resources/Licenses/` (copyright notices and full
license texts of every bundled library) into the app; Settings › About links to
them. When MPVKit or GRDB is updated, refresh those files and the list in
`Sources/MacShow/Views/AboutView.swift`.

## 3. Auto-update (Sparkle) — not set up yet

1. Add Sparkle (`https://github.com/sparkle-project/Sparkle`) to `Package.swift`.
2. Generate an EdDSA key pair with Sparkle's `generate_keys`, and put the public key in
   `Resources/Info.plist` as `SUPublicEDKey`.
3. Host an appcast (e.g. on GitHub Pages) and set `SUFeedURL`.
4. For each release, sign the DMG with `sign_update` and add it to the appcast.

Sparkle is for the direct download only; App Store builds update through the store.

## 4. Homebrew cask — after the first notarized release

Submit a cask to `homebrew/homebrew-cask` pointing at the DMG on a GitHub release.
