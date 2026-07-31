# Build and sign the IPA

This fork includes `.github/workflows/build-unsigned-ipa.yml`.

## Build an unsigned IPA on GitHub

1. Open **Actions → Build Unsigned IPA** in this repository.
2. Select **Run workflow**.
3. Enter the Bundle ID expected by your provisioning profile (for example, `com.yourname.freetube`).
4. Wait for the build to finish.
5. Download the `FreeTube-unsigned-*` artifact from the workflow run.
6. Unzip that artifact to obtain the unsigned `.ipa` and its SHA-256 checksum.

The workflow deliberately does not need or store an Apple certificate, private key, provisioning profile, or password. It builds a device `.app` with Xcode code signing disabled and packages it as `Payload/FreeTube.app` inside the IPA.

## Sign it

You can sign the IPA with a sideloading/signing tool that accepts unsigned IPAs, or re-sign it using your own Apple certificate and matching provisioning profile. The final Bundle ID, entitlements, certificate, and profile must agree.

Typical options include:

- AltStore / SideStore
- Sideloadly
- TrollStore, where supported
- A local macOS signing workflow using your own Apple Development or Distribution certificate

Never commit `.p12` files, provisioning profiles, certificate passwords, Apple account passwords, app-specific passwords, or session tokens to this repository.

## Notes

- GitHub-hosted macOS runners and available Xcode versions can change. If a future build fails after a runner update, inspect the workflow log and pin/select a compatible Xcode version.
- The repository states that the app is for personal use, sideloading, or TestFlight, not public App Store submission.
- You are responsible for complying with YouTube's terms and applicable copyright law.
