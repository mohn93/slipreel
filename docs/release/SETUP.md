# Release setup (one-time)

Slipreel is distributed directly (signed + notarized DMG, not the App Store).
This is the one-time credential setup. After this, releasing is a single
command (`scripts/release-macos.sh`) or a tag push (CI).

## 1. Developer ID Application certificate

1. Keychain Access → menu **Keychain Access → Certificate Assistant →
   Request a Certificate From a Certificate Authority**. Enter your email,
   leave CA email blank, choose **Saved to disk**, save `CertificateSigningRequest.certSigningRequest`.
2. https://developer.apple.com/account → **Certificates, IDs & Profiles →
   Certificates → +** → **Developer ID Application** → Continue → upload the
   CSR → Continue → **Download** the `.cer`.
3. Double-click the `.cer` to install it into your **login** keychain.
4. Confirm:
   ```bash
   security find-identity -v -p codesigning
   ```
   You should see `Developer ID Application: <Your Name> (<TEAMID>)`. The
   10-character `<TEAMID>` is your Apple Team ID — it's committed in the Xcode
   signing config (not a secret).

## 2. App Store Connect API key (for notarytool)

1. https://appstoreconnect.apple.com → **Users and Access → Integrations →
   App Store Connect API → +** (Team Keys). Name it "Slipreel Notary",
   Access = **Developer**. Generate.
2. **Download the `.p8` now** — Apple shows it only once. Note the **Key ID**
   (on the row) and the **Issuer ID** (top of the page).
3. Store the `.p8` somewhere safe (e.g. `~/.appstoreconnect/private_keys/`).

## 3. Local notarytool keychain profile (convenience)

Stores the API key in your keychain so the script doesn't need the raw key
each run:
```bash
xcrun notarytool store-credentials "slipreel-notary" \
  --key /path/to/AuthKey_<KEYID>.p8 \
  --key-id <KEYID> \
  --issuer <ISSUER_ID>
```
Then release locally with `NOTARY_PROFILE=slipreel-notary`.

## 4. Releasing

**Locally:**
```bash
NOTARY_PROFILE=slipreel-notary scripts/release-macos.sh 1.0.0
```
Produces `dist/Slipreel-1.0.0.dmg` (signed, notarized, stapled).

If your keychain has more than one **Developer ID Application** certificate
(e.g. a renewal overlap or a second team), the bare `"Developer ID
Application"` identity is ambiguous and `codesign` will fail. Pass the
fully-qualified identity (from `security find-identity -v -p codesigning`)
explicitly:
```bash
SIGN_IDENTITY="Developer ID Application: Becoming Ventures, LLC (UD7WB2694V)" \
  NOTARY_PROFILE=slipreel-notary scripts/release-macos.sh 1.0.0
```

**Via CI:** push a tag `v1.0.0`. The workflow needs these repository
**Secrets** (Settings → Secrets and variables → Actions):

| Secret | Value |
|---|---|
| `MACOS_CERT_P12_BASE64` | `base64 -i DeveloperID.p12` — export the cert+key from Keychain Access as a `.p12`, then base64 it |
| `MACOS_CERT_PASSWORD` | the password you set when exporting the `.p12` |
| `NOTARY_KEY_P8_BASE64` | `base64 -i AuthKey_<KEYID>.p8` |
| `NOTARY_KEY_ID` | `<KEYID>` |
| `NOTARY_ISSUER_ID` | `<ISSUER_ID>` |

(Your Team ID is not a secret — it's committed in the Xcode signing config,
so it doesn't need to be added here.)

To export the `.p12`: Keychain Access → login keychain → find **Developer ID
Application: … (TEAMID)** → expand it, select **both** the certificate and
its private key → right-click → **Export 2 items** → `.p12` → set a password.

## Sparkle auto-update (sub-project B)

Auto-update signs each DMG with an EdDSA (ed25519) key that is separate from
the Apple Developer ID signature. Do this once.

### 1. Generate the EdDSA update keypair

The Sparkle CLI tools (`generate_keys`, `sign_update`) ship inside the
auto_updater plugin's Sparkle CocoaPod — there is no Homebrew package for
them (`brew install sparkle` installs an unrelated, deprecated GUI cask).
They appear after a macOS build or `pod install`, at
`packages/screen_recorder/macos/Pods/Sparkle/bin/`. If that directory
doesn't exist yet, run one build first:

    (cd packages/screen_recorder && fvm flutter build macos --release)

Generate the keypair:

    packages/screen_recorder/macos/Pods/Sparkle/bin/generate_keys

`generate_keys` stores the PRIVATE key in your login keychain and prints the
PUBLIC key (a base64 string). Copy the public key: it goes in
`packages/screen_recorder/macos/Runner/Info.plist` as `SUPublicEDKey`
(committed — the public key is not sensitive).

Export the private key for CI (keep this file secret, do not commit it):

    packages/screen_recorder/macos/Pods/Sparkle/bin/generate_keys -x sparkle_private_key

### 2. Add the CI secret

In GitHub → repo Settings → Secrets and variables → Actions, add:

| Secret name             | Value                                            |
| ----------------------- | ------------------------------------------------ |
| `SPARKLE_ED_PRIVATE_KEY`| The full contents of the `sparkle_private_key` file from step 1 |

(No public key secret — it is committed in Info.plist.)

### 3. Enable GitHub Pages

Repo Settings → Pages → Build and deployment → Source = "Deploy from a branch",
Branch = `gh-pages`, folder = `/ (root)`. The release workflow creates and
pushes to `gh-pages` on the first release; after that Pages serves
`https://mohn93.github.io/slipreel/appcast.xml`.

### Local releases

For a local `scripts/release-macos.sh` run the DMG is signed with the private
key in your login keychain automatically (no env needed). To sign with an
explicit key file instead, set `SPARKLE_ED_KEY_FILE=/path/to/sparkle_private_key`.
The script resolves `sign_update` from the pod bin
(`packages/screen_recorder/macos/Pods/Sparkle/bin/`) itself — it does not
need to be on your PATH.
