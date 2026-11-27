# iOS sign-in diagnostic build

AI disclosure: implemented and tested with OpenCode (OpenAI GPT-6.1 Sol).

This build enables `AUTH_DIAGNOSTICS=true` and uses iOS build number **3201**.
It does not change OAuth scopes, token signing, credentials or server access rules.
It diagnoses failures; it does not promise to fix sign-in.

## Checking a failed sign-in

1. Install the newly signed IPA. No need to delete the app or its saved data first.
2. Open the app log in settings. The diagnostic entries are named `AuthDiagnostics`.
   They use WARNING level so the normal log filter retains them.
3. Attempt browser sign-in once. If it fails, copy the diagnostic entries from
   `stage=browser` through `stage=account` or `stage=sessionStorage`.
4. If testing email sign-in, wait for any existing rate limit to end first.
   Copy `stage=emailRequest` / `stage=emailExchange` entries as well.

Stages distinguish a failed browser/token exchange, missing token, account rejection,
invalid account response and failure to store/activate the session.

`signing=missing` means the build received an empty signing secret.
`development-placeholder` means the source's default value was used.
`configured-unverified` only means a nonempty nondefault value was compiled in:
it is **not** evidence that the server accepts it.

For 429, `retryAfterSeconds` is taken from the server's `Retry-After` header.
`unknown` means no usable retry time was provided; the app does not invent a delay.
These requests are not automatically retried by the diagnostic helper.

## Privacy

Diagnostics never print access/refresh tokens, authorization headers, credentials,
email addresses, login codes, cookies, raw response bodies or arbitrary server messages.
Known OAuth/server error strings are converted to fixed categories; unknown text
is represented as `unrecognized`. Successful token/account bodies are not inspected
for logging. No additional token-validation requests are made.

The normal app log can still contain existing user-agent/account identifiers.
Review it before sharing; sending only the `AuthDiagnostics` entries is sufficient.
