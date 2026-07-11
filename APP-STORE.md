# App Store Release Tracker

This document tracks the work required to ship CodexBar for iOS and iPadOS through TestFlight and App Store review.

Status last reviewed: 2026-07-11

## Current Status

- App builds, installs, and launches on the connected development iPhone.
- Main dashboard, provider settings, widget support, and snapshot trend improvements are on `main`.
- Development signing is stable through the dedicated CodexBar keychain documented in `AGENTS.md`.
- Apple Developer Program membership is confirmed under `franz_hemmer@hotmail.com`, active for one year from 2026-07-05.
- App Store Connect app record is created as `CodexBar Usage Monitor` with app ID `6787769891`.
- The expanded Issue #22 six-scene screenshot set was regenerated, reviewed at full size, and synced to the App Store Connect 1.1 draft for iPhone and iPad on 2026-07-11 using safe demo data.
- App Store production distribution upload has succeeded for build `1.0 (1)`, and App Store Connect reports the build as valid and App Store eligible.
- Build `1.0 (1)` is selected for the App Store version.
- Product metadata, support URL, privacy policy URL, copyright, and App Review notes have been added in App Store Connect.
- TestFlight install has been confirmed by the user on iPhone and iPad.
- App Store Connect app information is set to primary category `Developer Tools`, secondary category `Utilities`, and age rating `4+`.

## Apple Requirements To Keep Current

- App uploads must be built with Xcode 26 or later and the iOS/iPadOS 26 SDK or later as of 2026-04-28.
- App privacy answers in App Store Connect must accurately describe CodexBar's data handling and any third-party SDK behavior.
- iOS App Store listings require a privacy policy URL.
- If review cannot exercise paid or account-specific provider features directly, provide clear App Review notes and a short demo video.
- Sign in with Apple is not expected to be required unless CodexBar adds its own account system or offers a general third-party/social login option for a CodexBar account. Provider-specific auth for accessing the user's existing provider data should be explained in review notes.

Reference links:

- [Apple upcoming requirements](https://developer.apple.com/news/upcoming-requirements/)
- [Submitting apps to the App Store](https://developer.apple.com/app-store/submitting/)
- [App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Manage app privacy in App Store Connect](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy/)
- [App Review preparation](https://developer.apple.com/distribute/app-review/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## Release Work

### 1. App Store Connect Setup

- [x] Confirm Apple Developer Program membership and team ownership. Membership confirmed under `franz_hemmer@hotmail.com`, active for one year from 2026-07-05.
- [x] Create the App Store Connect app record. Created as `CodexBar Usage Monitor`, app ID `6787769891`, on 2026-07-05.
- [x] Confirm bundle ID, SKU, primary language, category, and age rating. App Store Connect uses bundle ID `com.hemsoft.CodexBarIOS`, SKU `codexbar-ios`, primary language `English (U.S.)`, primary category `Developer Tools`, secondary category `Utilities`, and age rating `4+`.
- [x] Decide initial availability: iPhone and iPad.
- [ ] Decide pricing: likely free unless a paid distribution plan is introduced.

### 2. Production Signing And Upload

- [x] Confirm the project has App Store distribution signing available for the app and widget extension.
- [x] Archive a release build from Xcode or `xcodebuild`. Release archive created for version `1.0` build `1`.
- [x] Validate the archive.
- [x] Upload the build to App Store Connect. Build `1.0 (1)` uploaded successfully.
- [x] Confirm TestFlight processing completes for both app and widget extension. App Store Connect reports uploaded build `1.0 (1)` as valid.

### 3. Product Page Assets

- [x] Finalize app name and subtitle. App name is `CodexBar Usage Monitor`; subtitle is `AI usage, limits, and balances`.
- [x] Prepare promotional text in `fastlane/metadata/en-US/promotional_text.txt`.
- [x] Prepare the full app description in `fastlane/metadata/en-US/description.txt`.
- [x] Prepare keywords in `fastlane/metadata/en-US/keywords.txt`.
- [x] Sync the Issue #22 promotional text, description, and keywords to App Store Connect and verify their previews. The 1.1 draft was updated and verified on 2026-07-11.
- [x] Provide support URL and add it to App Store Connect. Public support page is `https://github.com/HemSoft/codexbar-ios/blob/main/SUPPORT.md`.
- [ ] Provide marketing URL if desired.
- [x] Provide privacy policy URL and add it to App Store Connect. Public privacy policy is `https://github.com/HemSoft/codexbar-ios/blob/main/PRIVACY.md`.
- [x] Prepare screenshots for required iPhone sizes. Six deterministic iPhone 17 Pro Max images at `1320x2868` were generated and reviewed at full size on 2026-07-11.
- [x] Prepare screenshots for required iPad sizes. Six deterministic iPad Pro 13-inch (M5) images at `2064x2752` were generated and reviewed at full size on 2026-07-11.
- [x] Upload the Issue #22 iPhone and iPad screenshot sets to App Store Connect and verify their order and cropping. Both device sets contain six ordered screenshots in the 1.1 draft as of 2026-07-11.
- [x] Confirm Apple Watch screenshots are not needed. Current repo has no watchOS app target, so Apple Watch screenshots are not required unless a watchOS app is added.
- [ ] Consider an app preview video after the first TestFlight build is stable.
- [ ] Verify the App Store icon renders correctly and has no transparency.

### Product Claim Matrix

| Product-page claim | Verified source or constraint | App Store wording guidance |
| --- | --- | --- |
| Tracks ChatGPT / Codex, GitHub Copilot, Claude, Cursor, OpenRouter, and OpenCode ZEN | Current provider list used by the app and screenshot plan | Name exactly these providers; do not imply official affiliation. |
| Shows usage, limits, balances, reset timing, refresh state, alerts, and history | Provider data varies by API/account type | Say metrics appear where each provider makes them available. |
| Supports multiple accounts and provider groups | Current app configuration model | Say multiple accounts/groups, not team management or shared org administration. |
| Offers Home Screen and Lock Screen widgets | Widget extension and configurable widget surfaces | Say configurable widgets; do not promise real-time refresh because iOS controls widget timing. |
| Stores credentials locally and uses Keychain where appropriate | Privacy policy and app behavior | Say credentials stay on device and are stored in Keychain where appropriate. |
| Makes provider requests directly from the device | Current network architecture | Say no CodexBar account and no HemSoft backend for provider credentials or usage data. |
| Independent provider dashboard | Legal/brand constraint | Include a clear non-affiliation disclaimer wherever provider names are used prominently. |

### Product Narrative

CodexBar is a local companion dashboard for people who use several AI coding
and assistant services. The App Store page should emphasize quick status
checking before work: what account is close to a limit, which balance changed,
what refreshed recently, and which widgets keep the most important providers
visible. Keep the tone practical and privacy-forward. Avoid claims about
provider completeness, guaranteed metric availability, automatic background
accuracy, official partnerships, or server-side syncing.

### Screenshot Regeneration Workflow

Use the deterministic simulator capture script whenever the App Store
screenshots need to be refreshed:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/capture-app-store-screenshots.sh
```

The app contract for each launch is:

```text
--app-store-screenshots --app-store-scene <scene> --app-store-appearance <light|dark> --app-store-settle-seconds <seconds>
```

The capture script defaults the scene-settling window to two seconds. Override
it with `SCREENSHOT_SETTLE_SECONDS` when a slower simulator or CI runner needs
more render time; the app clamps the supplied value to the `0...30` second
range before signaling readiness.

Readiness is complete only when this command returns the requested scene:

```sh
cat "$(xcrun simctl get_app_container <device-udid> com.hemsoft.CodexBarIOS data)/Library/Caches/app-store-screenshot-ready"
```

The script polls a marker in the app's simulator data container, with a timeout, instead of
using a fixed delay. It deletes stale generated PNGs from both
`AppStore/Screenshots` and `fastlane/screenshots/en-US`, builds once for the
simulator, then performs a clean uninstall/install/launch cycle for every scene.
Status bars are forced to `9:41` with full battery before capture.

Scene order:

1. `dashboard-overview` in light appearance
2. `dashboard-dark` in dark appearance
3. `widget-builder` in light appearance
4. `accounts` in dark appearance
5. `provider-copilot` in light appearance
6. `history` in dark appearance

Required output sizes:

| Family | Simulator | Pixel size |
| --- | --- | --- |
| iPhone | iPhone 17 Pro Max | `1320x2868` |
| iPad | iPad Pro 13-inch (M5) | `2064x2752` |

Primary generated filenames include family, scene, and appearance, for example
`iphone-17-pro-max_dashboard-overview_light.png`. The final ordered Fastlane
copies use stable numbered names in `fastlane/screenshots/en-US`, with iPhone
and iPad files sharing the same scene number.

### Full-Size Visual QA

Local QA completed on 2026-07-11 for all 12 generated images. Repeat this
review after any regeneration:

After regeneration, review the full-size PNGs before syncing:

- Confirm every screenshot matches the expected dimensions above.
- Open each image at full size, not only as Finder thumbnails.
- Confirm status bar time is `9:41`, battery is full, and no simulator chrome
  or debug overlays are visible.
- Confirm light/dark appearance matches the scene plan.
- Confirm provider/account demo data is safe, plausible, and not personally
  identifying.
- Confirm no text is clipped, overlapped, truncated awkwardly, or hidden behind
  the Dynamic Island, home indicator, or iPad safe areas.
- Confirm widgets, history, accounts, provider details, and dashboard images
  match the marketing claims in the description.

### App Store Connect Sync And Preview

Issue #22 metadata and screenshots were generated, locally verified, and synced
to the App Store Connect 1.1 draft on 2026-07-11:

1. [x] Regenerate screenshots with the command above.
2. [x] Run local validation for shell syntax, metadata limits, PNG dimensions,
   and full-size visual quality.
3. [x] Sync `fastlane/metadata/en-US` and `fastlane/screenshots/en-US` to App Store
   Connect. The metadata and twelve screenshots were added to the 1.1 draft in
   Safari on 2026-07-11.
4. [x] Preview the iPhone and iPad product pages in App Store Connect.
5. [x] Verify the subtitle, promotional text, description, keywords, and ordered
   screenshots render correctly in the preview.
6. [x] Record the sync date and any App Store Connect adjustments here before final
   submission. The two inherited 1.0 screenshots per device class were replaced
   with the six-scene 1.1 sets. Files were uploaded individually to preserve the
   intended numbered order after App Store Connect shuffled an initial batch
   upload. The prepared subtitle required no adjustment, and 1.1 release notes
   were added from `fastlane/metadata/en-US/release_notes.txt`.

### 4. Privacy And Data Handling

- [ ] Inventory all network calls made by provider fetchers.
- [x] Confirm credentials are stored locally in Keychain and are not sent to HemSoft servers.
- [x] Confirm widget data is stored only in the app group container.
- [x] Confirm analytics/crash reporting status. No analytics, advertising, or crash-reporting SDKs are present in the current release.
- [x] Draft privacy policy covering local credentials, third-party provider API calls, billing/usage data, and data retention.
- [ ] Complete App Store Connect privacy nutrition labels.
- [ ] Review third-party packages and SDKs for privacy manifests or signature requirements.

### 5. Brand And Legal Review

- [ ] Audit provider logos and names used in the app and widgets.
- [ ] Confirm logo usage is allowed under each provider's brand guidelines.
- [ ] Replace any risky brand asset with a permitted mark or neutral in-app icon.
- [ ] Add disclaimers where needed that CodexBar is not affiliated with tracked providers.
- [ ] Confirm any OpenRouter/OpenCode ZEN/Cursor/Copilot/Codex wording is accurate and not misleading.

### 6. App Review Readiness

- [x] Write App Review notes explaining that CodexBar is a local companion dashboard for user-owned provider accounts.
- [x] Explain that provider credentials remain on device in Keychain.
- [x] Explain which features require user-owned third-party accounts and API keys.
- [ ] Provide a reviewer path for seeing the dashboard without real paid accounts, if possible.
- [ ] If no demo mode is appropriate, provide a concise demo video showing configured providers, widgets, and refresh behavior.
- [ ] Verify all error states are helpful and do not strand the user.
- [ ] Verify settings can add, edit, refresh, and remove each provider cleanly.
- [x] Provide persistent Settings links for writing an App Store review and
  opening the public support channel.
- [x] Gate native rating requests behind sustained successful use, with no
  first-launch, onboarding, automatic-refresh, incentive, or sentiment gate.

### 7. TestFlight

- [x] Upload the first TestFlight build. Build `1.0 (1)` uploaded successfully from Xcode on 2026-07-05 and later reported `VALID` by App Store Connect.
- [x] Install from TestFlight on iPhone.
- [x] Install from TestFlight on iPad.
- [ ] Verify widgets after TestFlight install.
- [ ] Verify provider credentials survive app restarts.
- [ ] Verify background/widget refresh behavior.
- [ ] Verify accessibility basics: Dynamic Type, VoiceOver labels, contrast, and tappable target sizes.
- [ ] Collect crash logs and fix any launch, widget, or auth issues.

Review-request test note: development-signed builds expose **Test Rating
Prompt** in Settings and StoreKit displays the native request for UI testing.
The native request has no effect in TestFlight, so TestFlight verification must
use the persistent **Rate CodexBar** link instead.

### 8. Final Submission

- [x] Select the final build in App Store Connect. Selected build is `1.0 (1)`, build ID `ccdc123f-9635-485c-b472-7b0093e026ac`.
- [x] Complete export compliance project prep. `ITSAppUsesNonExemptEncryption` is set to `false` for the app and widget because CodexBar only uses exempt Apple platform encryption such as HTTPS and Keychain.
- [ ] Complete content rights.
- [x] Complete age rating. App Store Connect reports `4+`.
- [x] Complete review contact info.
- [x] Add App Review notes. Demo sign-in fields are filled in App Store Connect.
- [ ] Submit for review.
- [ ] Track reviewer questions or rejections here until approved.

## CodexBar-Specific Risks

- Provider integrations depend on third-party services that may return different data by account type or region.
- Some providers may block automation-like auth flows. Review notes should clarify that CodexBar uses user-supplied credentials/API keys to fetch the user's own account data.
- Brand asset permissions need a careful pass before submission.
- Widgets must continue to show useful stale/error states because iOS controls refresh timing.
- The OpenCode ZEN balance path is currently viable for this development environment because the needed values were recovered from an existing working setup. Before public release, confirm a clean setup path for new Mac-only or iPhone-only users.

## Nice-To-Have Before First Public Release

- [ ] In-app demo/sample mode for App Review and first-run exploration.
- [ ] One-tap diagnostics export that redacts secrets.
- [ ] Provider connection health screen.
- [x] Deterministic App Store screenshot automation for the six-scene iPhone
  and iPad marketing set.
- [ ] Release archive script that uses the same signing assumptions documented in `AGENTS.md`.
