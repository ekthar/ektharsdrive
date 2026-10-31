# Contributing

- Keep the split: everything that does work lives in `EktharDriveCore` (testable with `swift test`). `EktharDrive` only renders state and forwards user actions.
- New rclone flags go through `MountCommandBuilder` and must exist in the installed rclone's `mount --help`. Add a unit test for the argument.
- Never put a secret in process arguments, rclone.conf (other than rclone's own token), SQLite, logs or activity. Run new log text through `Redactor`.
- Errors are `DriveError` cases. Add a case rather than a free-form string when the UI needs a different recovery action.
- Never display a value you did not measure. Use `nil` and show "Unavailable".
- Before a PR: `swift test --disable-sandbox --filter UnitTests`. If you touched mounting, also run the integration tests with `EKTHAR_RCLONE` set.
- Never commit rclone.conf, known_hosts, keys, caches or logs (`.gitignore` covers them).
