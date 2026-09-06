# Testing Strategy

## Test Layers

The repository uses four layers. Each layer has a different source of truth.

### Pure bridge and settings checks

Command:

```sh
swift run SelfTest
```

This layer covers:

- settings migration and round trips;
- selector parsing and persistence;
- bridge response parsing;
- generated bridge capabilities;
- Markdown, table, math, copy-button, readiness, and diagnostics contracts.

It does not execute JavaScript in a browser.

### Local WebKit smoke tests

Command:

```sh
sh scripts/build.sh
sh scripts/test-webkit-diagnostics.sh
```

The script serves deterministic HTML fixtures through localhost, launches the
real app bundle, and asserts on the JSON report. It covers:

- a home page with no conversation turns;
- delayed creation of 40 conversation turns;
- streaming-like mutations after the first render;
- an inner conversation scroller;
- code blocks and long-conversation metrics;
- the experimental render-tweak path;
- hidden-WebView performance sampling being reported as unsupported instead of
  being mistaken for zero jank.

This is the main regression loop for loading behavior. It does not depend on a
ChatGPT login, network timing, or production DOM selectors.

### Browser bridge fixtures

Command:

```sh
node scripts/test-browser-bridge.mjs
```

This test emits the deterministic bridge from the Swift target, injects it into
a real Chromium page, and verifies the user-visible DOM contract:

- rendered Markdown includes a table;
- math source is preserved as block LaTeX;
- code fences retain their language;
- the response-level Copy button wins over a code-block Copy button.

The test is optional on machines without Playwright. Set
`PLAYWRIGHT_PACKAGE` to the installed Playwright package directory to run it
from another checkout or CI image.

### Browser fixture tests

When bridge output formatting changes, add a fixture that exercises the
behavior through a real browser DOM. The preferred harness is Playwright:

```text
fixture page
  -> inject bridge
  -> perform one user-visible operation
  -> assert returned Markdown / readiness / diagnostics
```

Keep these tests local and deterministic. Do not use the production ChatGPT
page as a CI fixture.

### Live ChatGPT canary

The live page is only for release checks and selector discovery:

- load a known conversation;
- verify the assistant selector and response Copy button;
- run one Markdown/table/math extraction check;
- run one native Copy check;
- capture a diagnostic report.

It is intentionally not a required CI test because authentication, server
state, DOM shape, and network timing are outside this repository's control.

## Scenario Matrix

| Scenario | Pure | WebKit smoke | Live canary |
| --- | ---: | ---: | ---: |
| Home page has no turns | yes | yes | no |
| Delayed first turn | contract | yes | no |
| Streaming DOM mutations | contract | yes | optional |
| Inner scroll container | contract | yes | yes |
| Code blocks | contract | yes | yes |
| Markdown table | contract | fixture browser | yes |
| LaTeX source preservation | contract | fixture browser | yes |
| Response-level Copy button | contract | fixture browser | yes |
| Native ChatGPT Copy | no | no | yes |
| Selector update without reload | source contract | app integration | optional |
| Render-tweak path | source contract | yes | optional |
| Hidden WebView frame sampling | contract | yes | no |
| WebKit process termination | no | manual fault injection | manual |

## CI Contract

CI must run, in order:

```sh
swift build
swift run SelfTest
sh scripts/build.sh
sh scripts/test-webkit-diagnostics.sh
# Optional when Playwright is installed:
node scripts/test-browser-bridge.mjs
```

The smoke test must fail if:

- a home page waits for conversation turns;
- the first turn never appears within the fixture deadline;
- the real inner scroller is not reported;
- streaming changes are ignored;
- the optimization path does not apply its CSS;
- an unavailable frame sampler is reported as successful zero jank.

## Industry-Inspired Practices

The implementation follows common patterns from browser shells and large-list
systems:

- keep one warm WebView instead of recreating it on every panel show;
- separate navigation readiness from application-content readiness;
- use deterministic local fixtures for CI and reserve live pages for canaries;
- use trace-style metrics for attribution and JSON metrics for regression;
- virtualize only when the application owns the data and rendering tree;
- do not remove nodes from a third-party React tree as an optimization.

Useful primary references:

```text
https://playwright.dev/docs/test-intro
https://playwright.dev/docs/trace-viewer
https://developer.apple.com/documentation/webkit
https://webkit.org/testing/
https://www.electronjs.org/docs/latest/api/browser-window
https://developer.chrome.com/blog/infinite-scroller/
https://web.dev/articles/virtualize-long-lists-react-window
```
