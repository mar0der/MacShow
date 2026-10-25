# Releasing MacShow

`scripts/make-dmg.sh` builds `build/MacShow.dmg`. Without the steps below it's
signed ad-hoc: it runs on the Mac that built it, but other Macs will warn that
it can't be checked for malicious software. Making it open cleanly everywhere
needs a paid Apple Developer account.

## 1. Developer ID signing

1. In the Apple Developer portal, create a **Developer ID Application** certificate
   and install it in your keychain.
2. Find its name: `security find-identity -v -p codesigning`
3. Build. With a real identity, `scripts/build-app.sh` signs with the hardened
   runtime and a secure timestamp, which notarization needs:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/make-dmg.sh
```

## 2. Notarization

Create an app-specific password at appleid.apple.com and store it once
(it asks for the password):

```bash
xcrun notarytool store-credentials MacShow --apple-id you@example.com --team-id TEAMID
```

Then `NOTARY_PROFILE` makes `make-dmg.sh` submit the DMG, wait for Apple, and staple it:

```bash
NOTARY_PROFILE=MacShow SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/make-dmg.sh
```

If notarization reports problems with the bundled libraries, `xcrun notarytool log <id>`
lists them. mpv is set not to load any Lua scripts (user scripts, config, and its
built-in ones like the stats overlay and console), so LuaJIT should never start and
the `allow-jit` entitlement isn't needed: music and video play in the hardened
build with no code-signing errors in Console.

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
