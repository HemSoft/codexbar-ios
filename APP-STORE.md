# App Store Release Tracker

This document tracks the work required to ship CodexBar for iOS and iPadOS through TestFlight and App Store review.

Status last reviewed: 2026-07-06

## Current Status

- App builds, installs, and launches on the connected development iPhone.
- Main dashboard, provider settings, widget support, and snapshot trend improvements are on `main`.
- Development signing is stable through the dedicated CodexBar keychain documented in `AGENTS.md`.
- Apple Developer Program membership is confirmed under `franz_hemmer@hotmail.com`, active for one year from 2026-07-05.
- App Store Connect app record is created as `CodexBar Usage Monitor` with app ID `6787769891`.
- Initial simulator App Store screenshots have been captured and uploaded for iPhone and iPad using safe demo data.
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
- [x] Write promotional text and add it to App Store Connect.
- [x] Write the full app description and add it to App Store Connect.
- [x] Write keywords and add them to App Store Connect.
- [x] Provide support URL and add it to App Store Connect. Public support page is `https://github.com/HemSoft/codexbar-ios/blob/main/SUPPORT.md`.
- [ ] Provide marketing URL if desired.
- [x] Provide privacy policy URL and add it to App Store Connect. Public privacy policy is `https://github.com/HemSoft/codexbar-ios/blob/main/PRIVACY.md`.
- [x] Prepare and upload screenshots for required iPhone sizes. Initial dashboard screenshot is in `AppStore/Screenshots` and uploaded to App Store Connect.
- [x] Prepare and upload screenshots for required iPad sizes. Initial dashboard screenshot is in `AppStore/Screenshots` and uploaded to App Store Connect.
- [x] Confirm Apple Watch screenshots are not needed. Current repo has no watchOS app target, so Apple Watch screenshots are not required unless a watchOS app is added.
- [ ] Consider an app preview video after the first TestFlight build is stable.
- [ ] Verify the App Store icon renders correctly and has no transparency.

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
- [ ] App Store screenshot automation.
- [ ] Release archive script that uses the same signing assumptions documented in `AGENTS.md`.
