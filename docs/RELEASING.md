# Releasing CleanZip

CleanZip's release workflow always builds universal `arm64` and `x86_64` app, service, package, and ZIP artifacts. It supports two trust modes:

- **Developer ID:** signs with the Hardened Runtime, submits the app bundles and installer to Apple's notary service, staples tickets, and verifies them with `codesign`, `stapler`, and `spctl`.
- **Ad-hoc fallback:** keeps source builds installable when credentials are unavailable, but Gatekeeper requires the manual approval steps documented in the README.

## GitHub Secrets

Add these Actions secrets in **Settings -> Secrets and variables -> Actions**:

| Secret | Value |
| --- | --- |
| `APPLE_DEVELOPER_ID_APPLICATION_P12_BASE64` | Base64-encoded Developer ID Application certificate and private key (`.p12`). |
| `APPLE_DEVELOPER_ID_APPLICATION_P12_PASSWORD` | Password used when exporting that `.p12`. |
| `APPLE_DEVELOPER_ID_APPLICATION_IDENTITY` | Full certificate name, such as `Developer ID Application: Example (TEAMID)`. |
| `APPLE_DEVELOPER_ID_INSTALLER_P12_BASE64` | Base64-encoded Developer ID Installer certificate and private key (`.p12`). |
| `APPLE_DEVELOPER_ID_INSTALLER_P12_PASSWORD` | Password used when exporting that `.p12`. |
| `APPLE_DEVELOPER_ID_INSTALLER_IDENTITY` | Full certificate name, such as `Developer ID Installer: Example (TEAMID)`. |
| `APPLE_NOTARY_KEY_P8_BASE64` | Base64-encoded App Store Connect API private key (`AuthKey_XXXXXXXXXX.p8`). |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID. |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API issuer ID. |

Encode certificate and API key files without line wrapping:

```sh
base64 -i DeveloperIDApplication.p12 | pbcopy
base64 -i DeveloperIDInstaller.p12 | pbcopy
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy
```

The workflow imports certificates into an ephemeral runner keychain. It never writes certificate passwords or private-key contents to logs or release artifacts.

## Publish

Create the tag and release first, then dispatch the workflow so its artifacts replace the release assets:

```sh
gh workflow run cleanzip-liquid-glass-icon.yml \
  --repo lyc280705/CleanZip \
  --ref main \
  -f release_tag=v2.6.35 \
  -f upload_release=true
```

Check the workflow summary before announcing the release. A public build should only be described as notarized when the summary reports `developer-id` and `1` for the signing and notarization fields.
