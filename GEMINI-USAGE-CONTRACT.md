# Gemini Apps Usage Contract

Status: experimental and not yet live-verified by the CodexBar maintainer.

This integration reads the consumer Gemini Apps meters shown at
`gemini.google.com/usage`. It does not use Gemini API, Gemini CLI, Code Assist,
Vertex AI, or Antigravity quotas.

## Authentication and storage

The user pastes a Cookie header or JSON object through Google Gemini's Add
Account screen. CodexBar extracts `__Secure-1PSID` and the optional rotating
`__Secure-1PSIDTS` value, rejects malformed values, discards every other pasted
cookie, and stores only those selected values in iOS Keychain.

These are high-value Google session credentials, not a limited Gemini API key.
They may grant broader access to the Google account. CodexBar sends them only
to `gemini.google.com`, disables automatic cookie handling, rejects redirects
to another host, never logs response bodies, and never publishes credentials to
widgets or Apple Watch.

## Requests

The provider first sends an authenticated `GET` to
`https://gemini.google.com/usage`. From the returned page bootstrap it reads:

- `SNlM0e`: short-lived anti-CSRF token sent as the `at` form value.
- `cfb2h`: build label sent as the `bl` query value when present.
- `FdrFJe`: session identifier sent as the `f.sid` query value when present.

It then sends a form-encoded `POST` to
`https://gemini.google.com/_/BardChatUi/data/batchexecute` with:

- `rpcids=jSf9Qc`
- `source-path=/usage`
- `bl`, `f.sid`, `hl=en`, a request identifier, and `rt=c`
- `f.req=[[["jSf9Qc", "[]", null, "generic"]]]`
- `at=<SNlM0e>`

The RPC identifier and bootstrap field names are obfuscated private web
contract details and may change without notice.

## Response mapping

The response uses Google's anti-XSSI, length-prefixed `batchexecute` envelope.
CodexBar finds the `wrb.fr` row for `jSf9Qc`, decodes its JSON-string payload,
and accepts metric tuples shaped as:

```text
[limit, fractionUsed, period, [[resetEpochSeconds, resetNanoseconds]]]
```

Observed period values are `1` for the rolling 5-hour window and `2` for the
weekly window. CodexBar uses the period field rather than reset ordering, maps
`fractionUsed` directly to percent used, and preserves the exact reset epoch.
Unknown sibling buckets are ignored. A missing known bucket stays unavailable;
it does not become zero. Malformed or changed payloads fail closed and preserve
the last complete cached bars.

The current RPC does not include a verified account plan. CodexBar therefore
does not show a Gemini plan badge or infer a plan from prices, limits, page
marketing text, or usage values.

## Evidence and remaining gate

The sanitized shape was recorded on September 3, 2026 from the public
[`Nagi-ovo/gemini-voyager`](https://github.com/Nagi-ovo/gemini-voyager)
implementation and its captured response fixture. Google's help documentation
independently describes consumer Gemini Apps usage limits and the 5-hour and
weekly behavior. CodexBar's parser and request construction use independently
written Swift code and sanitized tests.

Before merge or App Store submission, a maintainer must compare CodexBar with
the same signed-in account's Gemini Usage page, confirm both percentages and
reset timestamps, review Google's current terms and App Review risk, and record
the redacted result on the pull request. Until then, the pull request remains a
working implementation for review rather than a release-ready integration.
