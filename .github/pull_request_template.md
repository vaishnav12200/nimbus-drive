## What changed

<!-- One or two sentences. The "why" matters more than the "what". -->

## Why

<!-- The problem this solves. If it fixes a bug, describe the failure mode:
     what went wrong, under what conditions, and what the user saw. -->

Closes #

## How it was tested

<!-- Actual commands and results, not "tested locally". If you verified
     something by hand that tests do not cover, say what and how. -->

- [ ] `pytest` passes
- [ ] `ruff check` and `mypy` clean
- [ ] `flutter analyze` and `flutter test` pass (if mobile changed)
- [ ] Tested against a real Telegram channel (if the storage path changed)

## Checklist

- [ ] New behaviour has a test, exercised through the path production uses
- [ ] Model changes ship with a migration, and `alembic downgrade base && alembic upgrade head` works
- [ ] No secret is logged, returned by an API, or committed
- [ ] Every new query filters by the `user_id` from the JWT
- [ ] New errors raise a typed error and use a stable `error.code`
- [ ] Docs updated if behaviour, config or the API surface changed

## Screenshots

<!-- Required for UI changes. Before and after if you are altering something. -->

---

<!--
Things that will be checked in review and are easy to miss:

  • Another user's resource must 404, never 403 — a 403 confirms it exists.
  • Temp files are deleted in a `finally`, not on the happy path.
  • Nothing changes the KDF, its parameters or the salt for an existing
    account: that makes their files permanently unreadable.
  • Timestamps are UTC.
-->
