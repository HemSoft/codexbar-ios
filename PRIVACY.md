# CodexBar Privacy Policy

Effective date: July 6, 2026

CodexBar Usage Monitor is a local dashboard for monitoring AI provider usage, limits, and API balances. It does not require a CodexBar account and does not send your provider credentials or usage data to HemSoft servers.

## Data CodexBar Stores On Your Device

CodexBar may store the following information locally on your iPhone, iPad, or
paired Apple Watch:

- Provider account labels and configuration choices you enter in the app.
- API keys, access tokens, refresh tokens, and similar credentials for providers you choose to connect.
- Usage, balance, refresh status, and snapshot history used to show cards, trends, alerts, and widgets.
- Widget configuration, including which tiles you choose to show.
- A presentation-only Apple Watch snapshot containing account labels, metric
  names and values, visualization choices, reset context, status, and freshness.

Provider credentials are stored using the iOS Keychain where appropriate. Widget snapshots and app settings are stored locally in the app container or app group container so the app and widgets can display your configured tiles.

The iPhone app sends only the latest presentation-ready dashboard snapshot to
the paired Apple Watch through Apple's Watch Connectivity framework. Provider
credentials, credential identifiers, cookies, raw provider responses, and
provider networking never move to the watch. The watch stores its last valid
snapshot locally so it can remain useful during a temporary disconnection.

## Third-Party Provider Requests

When you connect a provider, CodexBar uses the credentials you provide to request your own usage or balance data directly from that provider. Depending on what you configure, this may include services such as OpenAI/ChatGPT, Anthropic Claude, GitHub Copilot, Cursor, OpenRouter, OpenCode Go + Zen, and Moonshot AI (Kimi).

Those requests are made to the provider's own APIs or web endpoints. The provider may process the request according to its own terms and privacy policy.

For GitHub Copilot browser sign-in, CodexBar includes public OAuth application
credentials that identify the Copilot-compatible client. They are not personal
credentials and do not grant access to a GitHub account. You must authorize the
sign-in with GitHub, the authorization-code exchange is protected with PKCE,
and the account tokens returned for your session are stored in the iOS
Keychain.

## Data HemSoft Collects

HemSoft does not operate a backend service for CodexBar and does not collect your provider credentials, API keys, account balances, usage limits, widget configuration, or snapshot history.

CodexBar does not include third-party analytics, advertising, or crash-reporting SDKs in the current release.

When you explicitly choose **Report a Problem**, CodexBar first previews a
diagnostic built from a fixed list of non-secret categories: app version/build,
operating-system version, general device category, affected surface, provider
name when relevant, and optional booleans or categories for authentication
method, configured/secret-present state, normalized failure or HTTP status,
refresh/freshness, Widget freshness, or Apple Watch connection/freshness.
You can remove all optional technical details, copy the preview, cancel, or
explicitly open GitHub. If a safely prefilled URL would be too long, CodexBar
copies the preview instead of opening it.

CodexBar does not read or add provider credentials, account labels, email
addresses, account or device identifiers, balances, usage history, raw errors
or provider responses, widget selections, or Apple Watch snapshots to the
diagnostic or link. Nothing is uploaded or sent to GitHub until you explicitly
open the public bug form and submit it. **Suggest an Improvement** continues to
prefill only general app and device details.

## Sharing And Sale Of Data

HemSoft does not sell your data and does not share your CodexBar data with advertisers or data brokers.

## Data Retention And Deletion

CodexBar keeps local settings, credentials, and snapshots until you remove a provider, clear the relevant setting, or delete the app. Deleting the app removes app data stored in the app container. Some Keychain items may remain according to iOS Keychain behavior; you can remove saved provider credentials from CodexBar settings before deleting the app.

## Contact

For support or privacy questions, use the support information in [SUPPORT.md](SUPPORT.md).
