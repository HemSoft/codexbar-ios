# CodexBar Support

CodexBar Usage Monitor is maintained by HemSoft.

Use the destination that best matches what you need:

- Email a problem report or improvement suggestion privately to
  `fphemmer@gmail.com` from **Settings > Feedback & Support**. No GitHub account
  is required.
- [Report a problem](https://github.com/HemSoft/codexbar-ios/issues/new?template=bug_report.yml)
- [Suggest an improvement](https://github.com/HemSoft/codexbar-ios/issues/new?template=feature_request.yml)
- [View known issues](https://github.com/HemSoft/codexbar-ios/issues?q=is%3Aissue%20is%3Aopen)

The iPhone and iPad app exposes these destinations together under
**Settings > Feedback & Support**, alongside the support guide and App Store
rating link. The private email actions first show individually copyable
recipient, subject, and message fields; problem reports and improvement
suggestions use distinct subjects beginning exactly `[CodexBar Feedback]`.

Choosing **Report a Problem** first shows an on-device preview. It contains
general app/device details and an affected surface/provider, plus optional fixed
categories for configuration, authentication, failure, refresh, Widget
freshness, or Apple Watch connection state. You can remove the optional
technical details, copy the diagnostic, cancel, review or copy the private
email fields, or use the public GitHub form. **Suggest an Improvement** shows a
structured message with general app and device details in the same copy-first
view.

If you choose **Open Email Draft** after reviewing those fields, CodexBar warns
that the external mail app may display and use its currently selected sending
account. Opening the composer does not send a message; review the selected
account and explicitly send. iOS does not provide an app with a supported way
to hide another mail app's system-managed sender row. CodexBar never reads,
stores, logs, or prefills that address, and generates `mailto:` URLs with only
the recipient, subject, and message. Apple's relevant platform documentation is
available for
[`UIApplication.open`](https://developer.apple.com/documentation/uikit/uiapplication/open(_:options:completionhandler:))
and
[`MFMailComposeViewController`](https://developer.apple.com/documentation/messageui/mfmailcomposeviewcontroller).

Provider-card report actions appear only after you expand a visible problem.
Widget and Apple Watch report entries are available under **Feedback &
Support** and use presentation-safe state categories rather than stored
snapshots.

Email sent to `fphemmer@gmail.com` is processed by your configured email
provider and by Gmail, which hosts the recipient mailbox. GitHub bug reports
and feature requests remain public and require a GitHub account. Before
reporting a problem, gather:

- Your iOS or iPadOS version.
- The CodexBar app version and build.
- Which provider or widget is affected.
- Whether the iPhone or Apple Watch dashboard is affected, and when the watch
  last showed an update.
- A short description of what you expected and what happened.

Do not include API keys, access or refresh tokens, passwords, cookies,
authorization headers, account identifiers, or other secrets in email. Do not
include email addresses or any of these sensitive values in public GitHub issues
or attachments.

CodexBar never prefills credentials, tokens, cookies, account labels or
identifiers, your email address, balances, usage history, raw provider responses
or errors, widget selections, Watch snapshots, logs, files, or screenshots.
Your email app supplies your sender address when you send. Screenshots and
other attachments are additions you choose; redact private details before
adding them.

HemSoft may convert useful emailed feedback into a de-identified public GitHub
issue so the work can be tracked. The sender's email address, name, personal
details, and other identifying content will not be published as part of that
conversion. Do not post security or privacy-sensitive details in a public
GitHub issue.

If the Apple Watch dashboard is empty or stale, open CodexBar on the paired
iPhone, refresh the dashboard, and then open CodexBar on the watch. The last
valid watch snapshot remains visible while the phone is temporarily
unavailable; a stale or disconnected label explains when it was last updated.
