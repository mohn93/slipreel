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
   10-character `<TEAMID>` is your Apple Team ID — you'll commit it in the
   Xcode config (Task 2) and add it as the `APPLE_TEAM_ID` secret.

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
