# Releasing Yap

Publishing a GitHub release (tag `vX.Y.Z`) runs `.github/workflows/build.yml`, which builds Yap and attaches
`Yap-vX.Y.Z-macOS-arm64.zip` to the release. Three optional upgrades switch on when their secrets exist. Without
them, the release is the same ad-hoc signed build as before.

| Upgrade | Needs | What users get |
|---|---|---|
| Developer ID signing | `MACOS_CERTIFICATE`, `MACOS_CERTIFICATE_PASSWORD` | A signed app |
| Notarization | the above + `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` | No "Apple could not verify" warning |
| In-app updates (Sparkle) | secret `SPARKLE_PRIVATE_KEY` + variable `SPARKLE_PUBLIC_KEY` | Yap → Check for Updates…, and automatic update checks |

Add them in GitHub: **Settings → Secrets and variables → Actions**.

## 1. Developer ID and notarization (Apple Developer Program, $99/year)

1. In Xcode → Settings → Accounts (or developer.apple.com → Certificates), create a **Developer ID Application**
   certificate.
2. In Keychain Access, export it with its private key as a `.p12` file and set a password.
3. Add the secrets:
   - `MACOS_CERTIFICATE`: the output of `base64 -i DeveloperID.p12 | pbcopy`
   - `MACOS_CERTIFICATE_PASSWORD`: the `.p12` password
   - `APPLE_ID`: your Apple Account email
   - `APPLE_TEAM_ID`: the 10-character team ID shown at developer.apple.com → Membership
   - `APPLE_APP_PASSWORD`: an app-specific password from account.apple.com → Sign-In and Security
4. Delete the local `.p12` file.

Developer ID builds use the default code requirement (bundle ID + team), so macOS permissions survive updates.

## 2. In-app updates (free)

Sparkle verifies every update with an EdDSA signature. You make the key pair once:

```bash
curl -fsSLO https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz
mkdir sparkle && tar -xf Sparkle-2.9.6.tar.xz -C sparkle
./sparkle/bin/generate_keys            # saves the private key in your login Keychain, prints the public key
./sparkle/bin/generate_keys -x sparkle-private.txt
```

- Add the printed public key as the repository **variable** `SPARKLE_PUBLIC_KEY`.
- Paste the contents of `sparkle-private.txt` into the **secret** `SPARKLE_PRIVATE_KEY`, then delete the file.
  The copy in your Keychain is your backup. If you lose the private key, existing installs can't verify new
  updates.

Each release then also attaches `appcast.xml`. Yap reads it from
`https://github.com/max-pantom/yap/releases/latest/download/appcast.xml`, so only mark full releases as
"latest" (pre-releases are skipped). Builds without `SPARKLE_PUBLIC_KEY`, such as local `./build.sh` builds,
never check for updates.

Copies installed before Sparkle was added (v1.0) can't update themselves. Those users download once more.

## Version numbers

The tag sets the version (`v1.2.0` → 1.2.0). The workflow run number becomes the build number, which Sparkle
compares, so it always goes up.
