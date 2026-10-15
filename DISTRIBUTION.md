# Distributing Hush

Hush ships as a **notarized DMG on GitHub Releases**, outside the Mac App Store: anyone can
download it, drag it to Applications and open it with no Gatekeeper warnings.

There are two ways to make a release, and both produce the same file:

| | How | When |
|---|---|---|
| **GitHub Actions** (recommended) | Push a tag: `git tag v1.3.0 && git push origin v1.3.0` | Normal releases — builds, notarizes and publishes the GitHub Release for you |
| **Locally** | `./release.sh 1.3.0` → `dist/Hush-1.3.0.dmg` | Testing the pipeline, or releasing without CI |

---

## One-time setup

### 1. Apple Developer Program

Already done if you ship iOS apps — the same membership covers Mac apps outside the App Store.

### 2. A *Developer ID Application* certificate

This is a separate certificate from the *Apple Development* / *Apple Distribution* ones used for
iOS. Only the account holder can create it.

1. Xcode → **Settings → Accounts** → select your team → **Manage Certificates…**
2. **+** → **Developer ID Application**

Check it's in your keychain:

```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 3. Notarization credentials

1. Create an app-specific password: <https://account.apple.com> → **Sign-In and Security →
   App-Specific Passwords** → name it `hush-notary`.
2. Find your **Team ID**: <https://developer.apple.com/account> → **Membership details**.

For **local** releases, store them in your keychain once:

```bash
xcrun notarytool store-credentials hush-notary \
  --apple-id "YOUR_APPLE_ID_EMAIL" \
  --team-id  "YOUR_TEAM_ID" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

### 4. GitHub Actions secrets (for tag-triggered releases)

Export the certificate with its private key:

1. **Keychain Access** → **login** → **My Certificates** → right-click
   **Developer ID Application: …** → **Export…** → save as `DeveloperID.p12` with a password.

Then add five repository secrets (you'll be prompted for each value; nothing is echoed):

```bash
cd Hush
base64 -i ~/Desktop/DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64
gh secret set DEVELOPER_ID_P12_PASSWORD   # the .p12 export password
gh secret set APPLE_ID                    # your Apple ID email
gh secret set APPLE_APP_PASSWORD          # the app-specific password from step 3
gh secret set APPLE_TEAM_ID               # your Team ID
rm ~/Desktop/DeveloperID.p12
```

(Or add them on GitHub: repo → **Settings → Secrets and variables → Actions**.)

The release workflow checks for all five before it starts and names any that are missing.

---

## Making a release

1. Add a section for the new version at the top of `CHANGELOG.md`, e.g. `## [1.3.1] — 2026-11-02`.
   The workflow uses it as the release notes.
2. Commit, then tag and push:

```bash
git tag v1.3.1
git push origin main v1.3.1
```

3. Watch **Actions → Release**. In about 5–10 minutes the
   [Releases page](https://github.com/malong954/Hush/releases) has `Hush-1.3.1.dmg` and its
   `.sha256`.

### What `release.sh` does (locally or in CI)

| Step | What happens |
|---|---|
| Preflight | Finds the Developer ID certificate and notarization credentials; stops with the fix if either is missing |
| Build | Universal binary (Apple silicon + Intel), release config |
| Assemble | `Hush.app` with icon, version from the tag, build number = commit count, LICENSE + NOTICE |
| Sign | Developer ID, hardened runtime, secure timestamp, `Resources/Hush.entitlements` |
| Package | `dist/Hush-<version>.dmg` with an Applications shortcut, signed |
| Notarize | Uploads to Apple and waits (usually 1–5 min); on rejection prints the command to see why |
| Staple | Attaches the ticket so it opens offline too, then checks Gatekeeper accepts it |
| Checksum | `dist/Hush-<version>.dmg.sha256` |

| Variable / flag | Default | Use |
|---|---|---|
| `SIGN_IDENTITY` | auto-detected | Pick a specific certificate if you have several |
| `NOTARY_PROFILE` | `hush-notary` | Keychain profile for local releases |
| `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID` | — | Used instead of the keychain profile when all three are set (CI) |
| `--adhoc` | off | Unsigned test build; recipients must use **Privacy & Security → Open Anyway** |

If a local universal build fails mentioning `xcbuild`: `sudo xcode-select -s /Applications/Xcode.app`

---

## CI on every push

`.github/workflows/ci.yml` compiles Hush for Apple silicon and Intel on every push to `main`
and every pull request, and attaches an unsigned `Hush.app` to the run for 7 days. It needs no
secrets.

## Why not the Mac App Store

| Hush needs to… | Why the App Store won't allow it |
|---|---|
| Read `~/Library/Developer/CoreSimulator/Devices/*/device.plist` | Outside the sandbox container |
| Read other processes' environment (`SIMULATOR_UDID`) to tell simulator windows apart | Blocked by the sandbox |
| Check the audio permission (`TCCAccessPreflight`) and credit helpers to their app (`responsibility_get_pid_responsible_for_pid`) | Private APIs, rejected in review |

## Optional next steps

- **Automatic updates (Sparkle 2):** an "Update available" prompt inside Hush, fed by an
  `appcast.xml` in this repo and signed with an EdDSA key.
- **Homebrew:** a cask in a `malong954/homebrew-tap` repo so people can
  `brew install --cask malong954/tap/hush`, using the DMG URL and `.sha256` from each release.
