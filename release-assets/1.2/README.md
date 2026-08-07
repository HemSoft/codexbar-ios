# CodexBar 1.2 release assets

Tracking issue: [#237](https://github.com/HemSoft/codexbar-ios/issues/237)

This directory contains customer-facing release copy and a privacy-safe
screenshot set for version 1.2. Every screenshot was generated from CodexBar's
deterministic App Store fixture mode. No signed-in account, physical-device app
state, credential, user name, organization name, usage history, or balance was
used.

## Privacy and file verification

- Source: debug simulator build with `--app-store-screenshots` fixtures
- Content: fictional account labels, organization, balances, usage values, and
  history samples defined in the repository
- iPhone and iPad status bars: standardized 9:41 time, full battery, and
  simulated connectivity
- Apple Watch status bar: native simulator capture time; watchOS does not
  support CoreSimulator status-bar overrides
- Format: flattened RGB PNG with no alpha channel
- iPhone family: 1320 x 2868 pixels, portrait
- iPad family: 2064 x 2752 pixels, portrait
- Apple Watch family: captured from a compatible isolated watchOS simulator at
  an Apple-accepted native size, with deterministic fictional dashboard data
- iPadOS window-resize affordance: present on iPad captures as standard iPadOS
  26 system UI for multitasking apps
- Mirroring chrome, pointer, notifications, and personal device data: absent
- Visual review: all 14 screenshots inspected after capture

The source simulator captures included an opaque alpha channel. The final files
were flattened to RGB for upload compatibility, and raw-pixel hashes confirmed
that the visible RGB pixels did not change.

## Recommended storefront sequence

Use the six iPhone images in numbered order for the iPhone storefront and the
matching six iPad images in the same scene order for iPad. Use both Apple Watch
images in numbered order for the Watch storefront:

1. Dashboard overview — usage across several providers at a glance.
2. Balance and quota dashboard — light and dark appearance coverage.
3. Widget Builder — configurable layouts and a live preview.
4. Accounts & Groups — broad provider support and organization.
5. GitHub Copilot settings — account configuration and browser-session support.
6. Usage history — trends, summaries, and recent samples.

The Watch sequence adds:

1. Usage dashboard — current limits, severity, reset timing, and visualization.
2. Balance dashboard — a fictional OpenCode Zen balance.

## Screenshot catalog

| File | Device | Scene |
| --- | --- | --- |
| `screenshots/01-iphone-dashboard-overview-light.png` | iPhone | Multi-provider dashboard in light appearance |
| `screenshots/02-iphone-dashboard-balances-dark.png` | iPhone | API balances and usage limits in dark appearance |
| `screenshots/03-iphone-widget-builder-light.png` | iPhone | Four-tile Widget Builder preview and controls |
| `screenshots/04-iphone-accounts-dark.png` | iPhone | Configured providers in Accounts & Groups |
| `screenshots/05-iphone-copilot-settings-light.png` | iPhone | GitHub Copilot organization configuration |
| `screenshots/06-iphone-usage-history-dark.png` | iPhone | Detailed usage chart, summary, and samples |
| `screenshots/07-ipad-dashboard-overview-light.png` | iPad | Two-column multi-provider dashboard in light appearance |
| `screenshots/08-ipad-dashboard-balances-dark.png` | iPad | Two-column balances and limits dashboard in dark appearance |
| `screenshots/09-ipad-widget-builder-light.png` | iPad | Wide Widget Builder preview and controls |
| `screenshots/10-ipad-accounts-dark.png` | iPad | Sidebar Settings and Accounts & Groups |
| `screenshots/11-ipad-copilot-settings-light.png` | iPad | GitHub Copilot organization configuration |
| `screenshots/12-ipad-usage-history-dark.png` | iPad | Wide usage chart, summary, and samples |
| `screenshots/13-watch-dashboard-overview.png` | Apple Watch | Fictional usage limits and severity on the Watch dashboard |
| `screenshots/14-watch-dashboard-balances.png` | Apple Watch | Fictional provider balances on the Watch dashboard |

## Remaining capture gaps

- Widget gallery and complication gallery presentation
- Alert-threshold configuration
- Card customization, including per-metric Watch visibility
- Feedback, support, diagnostics, and recovery flows
- Clean-install and first-run onboarding or empty-dashboard scenes, captured on
  a freshly erased isolated simulator or a separate device with no signed-in or
  restored production data

Do not fill these gaps with live signed-in data. Add deterministic fixture scenes
or use an isolated simulator populated only with fictional values before adding
more public release screenshots.
