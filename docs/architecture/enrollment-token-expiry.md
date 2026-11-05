# Enrollment token expiry

The portal offers one day, one calendar month, one calendar year, no expiry,
and an exact local date/time. Calendar month/year addition clamps to the final
valid day (for example, January 31 + one month becomes February 28/29).
Exact dates are converted from the browser's local time zone to a UTC timestamp.

`POST /v1/enrollment-tokens` accepts `label`, `max_enrollments`, and
`expires_at` (an RFC 3339 future timestamp, or `null` for no expiry).
The legacy `expires_in_hours` field remains supported for 1–8784 hours.
Do not supply both a non-null timestamp and a non-null duration.
Omitting both expiry fields also means no expiry.

Responses return a nullable `expires_at`. Both enrollment claim paths accept
null expiry while still enforcing revocation and usage limits. Existing tokens
retain their expiry values.

`PATCH /v1/enrollment-tokens/:id` edits expiry with the same `expires_at`
timestamp/null representation. The field is mandatory, and unknown fields are
rejected. Requires an administrator and same-origin request. Revoked or missing
tokens return 404; expired tokens can be extended. Updating expiry does not
rotate the token, reset its usage count, or change its enrollment limit. Every
successful update writes an audit event in the same database transaction.
The portal pencil next to Expires opens the editor with the current expiry;
relative presets are calculated from save time, not the previous expiry.

Deploy the API with migration `0018_enrollment_token_optional_expiry.sql` before
the updated portal. An older API does not accept the portal's new request shape.
