# Personal API token sign-in (iOS build 3202)

AI disclosure: implemented and tested with OpenCode (OpenAI GPT-6.1 Sol).
The official App Store IPA was not inspected and no official-client secret was extracted.

In the iOS sign-in menu, choose **Sign in with API token**. Create a new token on
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

Old stored OAuth/email sessions keep their original signed-token mode.
Do not paste a password, email login code, full Authorization header or a signed token.
Token prefixes are not used to infer authentication mode.

This is public API access, not a replacement for private mobile-client permissions.
Some screens, notifications and native WebSocket gameplay may reject personal tokens
or require additional public API integration. A successful profile request does not prove
that every app feature is compatible. Existing server-side permission and fair-play
restrictions are unchanged. Engine assistance in human games is prohibited.
