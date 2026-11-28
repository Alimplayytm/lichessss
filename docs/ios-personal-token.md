# Public API sign-in and online play (iOS build 3203)

AI disclosure: implemented and tested with OpenCode (OpenAI GPT-6.1 Sol).
The official App Store IPA was not inspected and no official-client secret was extracted.

Prefer **Sign in with browser**: the app now requests public OAuth authorization using PKCE,
the fork's own client ID, and `board:play`, not the private `web:mobile` permission.
The app validates the raw bearer at `/api/account` and stores the public OAuth mode securely.
App-issued OAuth tokens are revoked on logout. Old stored OAuth/email sessions retain their
original signed-token mode; sign out and use the browser flow to migrate.

Alternatively choose **Sign in with API token**. Create a new token with **board:play** on
https://lichess.org/account/oauth/token and paste only its value into the obscured field.
Revoke any previously shared token first. Never send the replacement to someone else.
Use minimal scopes for the public API features you actually need.

The app verifies the token using `GET /api/account` with `Authorization: Bearer <token>`.
It does not append an official-client signature or use the official client's identity.
The authentication mode is stored alongside the token in the existing secure storage
(Keychain on iOS), survives restarts and account switches, and controls subsequent headers.
Tokens are not put in URLs, logs, source code, CI secrets or generated IPA files.
Signing out or replacing an imported personal token forgets it locally without revoking it
for other applications. Revoke it yourself on the token management page when necessary.

Do not paste a password, email login code, full Authorization header or a signed token.
Token prefixes are not used to infer authentication mode.

## Online play

Choose **Play → Play online · Public API**. Starting an online game from the old lobby
also opens this new lobby for public sessions; no seek is silently made as an anonymous user.
The lobby connects `/api/stream/event` before permitting a real-time seek.

- Standard Rapid/Classical random pairing: 10+5, 15+5, 30+5; casual or rated.
- Direct Standard challenges by username: 3+2, 5+2, 10+2, with incoming accept/decline.
- Casual correspondence seek: two days per move.
- Resume ongoing games via `/api/account/playing`.
- Native board driven by `/api/board/game/stream/{id}`, sending moves via the public move endpoint.
- Server-authoritative clocks, reconnects, complete move-list resynchronization, draw, abort, resign.
- Cancelling search or backgrounding the lobby closes the seek's own HTTP connection.
- No automatic retry of move submissions; stream reconnections wait one minute on HTTP 429.
- The new board screen does not instantiate a chess-helper/engine overlay or change its preferences.

For public sessions, the request aggregator uses individual endpoints instead of `/api/mobile/*`.
Site/watch WebSockets connect anonymously with an explicit `sri`; they do not impersonate an
authenticated native mobile socket. Board API game connectivity is shown separately in its screen.

This is an initial public-API integration, not full compatibility with every official-app feature.
Bullet/random Blitz pairing are not supported by the Board API. Tournament participation,
chat, offline correspondence move synchronization, push notifications and all private mobile
services have not been migrated here. Existing settings and anonymous/offline modes are preserved.
The old email-code route is retained but is not a public-API authentication solution.
Device validation is still required; local tests use synthetic credentials and mocked HTTP.
Existing server-side permission and fair-play restrictions are unchanged.
Engine assistance in human games is prohibited.
