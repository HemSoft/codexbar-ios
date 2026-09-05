# Gemini website sign-in

Issue [#299](https://github.com/HemSoft/codexbar-ios/issues/299) replaces routine
manual credential transfer with Google website sign-in. The implementation
retains the consumer Gemini Apps usage contract introduced by #296.

## Reference and mechanism

The desktop reference selected by Franz is Google's official
[Gemini for macOS app](https://gemini.google/mac/). Its first-party OAuth and
`GetUsageInfo` behavior did not establish a consumer-usage authorization grant
available to CodexBar. The website-session path was selected after that scope
feasibility investigation. Gemini CLI and Code Assist quotas do not establish
access to the consumer Gemini Apps meters required here.

This iOS implementation uses the ordinary Google website in `WKWebView`, with a
fresh [nonpersistent website data store](https://developer.apple.com/documentation/webkit/wkwebsitedatastore/nonpersistent())
for each attempt and the standard user agent. It performs no OAuth authorization
request and needs no OAuth registration or callback URL scheme. Google's
[OAuth embedded-user-agent restriction](https://developers.google.com/identity/protocols/oauth2/native-app#disallowed_useragent)
still applies to OAuth flows. The verified website-session path is a separate,
undocumented integration, with no claim of a public OAuth grant.

The return path is local to the browser sheet. Main-frame Google navigation and
cookie-store changes prompt inspection through [WKHTTPCookieStore](https://developer.apple.com/documentation/webkit/wkhttpcookiestore/getallcookies(_:)).
After Google sign-in finishes, an authenticated `myaccount.google.com` landing
returns to the exact Gemini Usage URL once per fresh session credential. A
repeat landing keeps the window open with a Gemini Usage retry action. Google links that request a new
window open in the same temporary view. Browser controls allow Back, Gemini
Usage, and Cancel. Only secure HTTPS Google website navigation is allowed;
unsafe or external links remain blocked with a visible explanation.

Only secure, unexpired `.google.com` root-path cookies named `__Secure-1PSID` and
optional `__Secure-1PSIDTS` are accepted. Host-only and narrower-path cookies are
excluded, and conflicting cookie values fail closed. Password fields, page
contents, and JavaScript are never inspected. The existing native provider reads
both meters using an immutable in-memory credential store before any Keychain
replacement. Connection requires the expected account result, both meter keys,
and reset times. The browser store is discarded. A canceled attempt or late
validation response cannot write credentials after disconnect.

## Sanitized feasibility proof

On September 4, 2026 EDT, Franz completed Google website sign-in in a temporary
native app on an iPhone 17 simulator running iOS 26.5. The unchanged
`GeminiUsageProvider.swift` from main at
`04f8c62d447ee126d6e71066805d9e0cf76803e2` then fetched consumer usage with only
the two supported cookie names, kept in memory. The website and native results
matched at the website's displayed precision.

| Meter | Native usage | Website usage | Reset in America/New_York |
| --- | --- | --- | --- |
| Five-hour | 0% | 0% | September 5, 2026, 3:44:44 AM EDT |
| Weekly | 0.718348% | 1% | September 8, 2026, 7:44:44 PM EDT |

The website displays reset times to the minute; native responses supplied
seconds. No credentials, passwords, bootstrap tokens, or response bodies were
printed or exported. The [issue evidence](https://github.com/HemSoft/codexbar-ios/issues/299#issuecomment-5548908907)
records the limitations of that probe, including its manual debugger return
from Google Account. Production adds the return handling described above.

## Verification boundaries

Sanitized tests cover cookie and navigation policy, nonpersistent-store
isolation, cancellation, stale validation, failed validation and persistence,
account migration, relaunch persistence, and scoped disconnect. The provider
fixture checks the consumer endpoint, both meter values, and supplied resets.

The earlier probe does not prove production end-to-end behavior on a connected
iPhone. Before release, complete Google sign-in in the production window,
compare both meters and reset times to the same account's Usage page, and check
cancellation, denied access, offline retry, relaunch, reauthentication, account
switching, and reconnecting a manually configured account. Record sanitized
results on the PR. Browser sign-in remains dependent on Google's web behavior.
