# iOS Chess Helper

AI disclosure: this port and its tests/workflow were written with OpenCode
(OpenAI GPT-6.1 Sol). Human review is required before contributing upstream.

## Usage

On iOS, tap the lightbulb at the bottom right of a full interactive board.
The helper is off by default. Start it explicitly in the Position tab.
It supports standard chess only, like the source extension.

The panel includes live hints, a mini-board, SAN/UCI, white-perspective
evaluation, depth and nodes/second, real-turn and hypothetical player-preview
modes, color selectors, Elo/depth settings and MultiPV training weakening.
Settings, panel dimensions, pin and mini-board orientation are persisted.
Drag the header to move the panel or the bottom-right handle to resize it.
The menu flips only the mini-board, copies the real FEN, or resets the size.
Collapsing does not stop hints. Stop explicitly with the stop button.
Leaving the screen or backgrounding the app cancels the active search.
Returning resumes hints only if they were already enabled.

There is no game-review tab, batch analysis or move-classification statistics.
The evaluation bar is an approximation, not a probability of winning.
A requested weak move is not guaranteed to have a particular severity.
Its quota is consumed only if the recommended move is actually played.
Browser DOM/worker logic is replaced by the real chessboard model and the
app's native Stockfish; no remote engine scripts are downloaded.

**Using engine assistance in online games violates Lichess fair-play rules
and can result in account bans.**

## Build

The `iOS Chess Helper IPA` GitHub Actions workflow checks formatting,
analyzes the edited Dart files, runs helper/engine tests and builds a release
app on macOS. It packages `Runner.app` under `Payload/` as an unsigned IPA.
Download the `lichess-helper-unsigned-ipa` artifact from the workflow run.

This IPA must be signed separately before installation on a physical device.
No Apple certificate, provisioning profile or TestFlight upload is involved.
The optional `WS_SECRET` repository secret is passed to the existing socket
configuration. An empty/unaccepted value may prevent online play even when
the app builds successfully. Do not put credentials in source code.

An actual iPhone/iPad test is still needed for touch gestures, layout and
native Stockfish performance. CI compilation is not a device smoke test.
