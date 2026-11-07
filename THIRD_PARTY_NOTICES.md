# Third-Party Notices

QuotaMeter is an independent reimplementation. No third-party code is vendored
in this repository; the items below are credited because QuotaMeter's data
layer follows the same service protocols those projects documented and
implemented first, and because it consumes a third-party data API at runtime.

## CodexBar

- Project: [steipete/CodexBar](https://github.com/steipete/CodexBar)
- Relationship: QuotaMeter's Muse (muse.ai) and Codex usage fetchers are
  reimplemented in Swift following the protocol behavior of CodexBar's
  providers (request shapes, headers, and the muse.ai server-action
  auto-discovery strategy). No CodexBar source code is copied.
- License: MIT
- Copyright: Copyright (c) 2026 Peter Steinberger

## Win-CodexBar

- Project: [nesszer/Win-CodexBar](https://github.com/nesszer/Win-CodexBar)
- Relationship: its Rust `museai` provider was consulted to verify the
  muse.ai request protocol (it is itself a port of CodexBar).
- License: MIT

## models.dev

- Project: [anomalyco/models.dev](https://github.com/anomalyco/models.dev)
- Relationship: QuotaMeter fetches model list prices from the public
  models.dev API at runtime to estimate Codex token costs (the same data
  source CodexBar uses). No models.dev data is bundled in this repository.
- License: MIT

---

The MIT License text covering the projects above:

```
MIT License

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
