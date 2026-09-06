# Local Automation

Open Clipy Settings → Automation, enable access, and grant the permissions
your program needs. Access starts with no permissions. All programs running as
your macOS account share this connection; deletion requires its own confirmation
when granting access.

When access is disabled and no client credential remains, opening Settings
does not access the Keychain. Enable first removes server credentials left by
an interrupted enrollment that has no saved connection, including those whose
client file has disappeared; cleanup must succeed before creating a new
connection. Revoked connections retain their server verifier so previously
issued credentials continue to receive an explicit revoked response.

The client is bundled at `Clipy.app/Contents/MacOS/clipyctl`. It accepts one
UTF-8 JSON request on stdin and returns one JSON reply on stdout. For a Clipy
installation in `/Applications`, list recent items with:

```sh
printf '%s\n' '{"protocolVersion":1,"requestID":"12345678-1234-1234-1234-123456789abc","operation":"browsePreview","arguments":{"limit":20}}' |
  /Applications/Clipy.app/Contents/MacOS/clipyctl
```

`browsePreview` also supports search: add `"query":"example"` and
`"mode":"exact"` (or `"fuzzy"` / `"regexp"`) to its arguments. To continue
either query, pass the returned `nextCursor` as `cursor` with the same arguments.

Use a returned item's `locator` for these operations:

| Operation | Arguments | Permission |
| --- | --- | --- |
| `browsePreview` | `limit`, optional `cursor`; search additionally requires `query` and `mode` | Browse Previews |
| `detailsEffective` | `locator` | Read Current Content |
| `pasteEffective` | `locator` | Read Current Content |
| `pin` / `unpin` | `locator` | Pin and Unpin Items |
| `delete` | `locator` | Delete Items |

The two content operations return current representations as type identifiers
and base64 bytes. `pasteEffective` returns a payload to your program; it does
not change the system clipboard or simulate a paste. Original content and old
revisions are not disclosed. Locators and cursors are opaque and expire across
an app restart; rerun browse/search when they expire.

The client launches its containing app when necessary and waits briefly for
the service to become ready. Requests cannot choose a store, socket, or
credential path. A connection error after sending a mutation returns
`outcome_unknown`; the client never repeats that mutation automatically.
stdin must finish within ten seconds, and stdout/stderr delivery has a separate
ten-second limit. A stalled producer or consumer ends with exit status `5`.

Exit status is `0` for success, `2` for invalid input, `3` for denied access,
`4` for missing/stale items or cursors, `5` for temporary unavailability or an
unknown outcome, and `6` for a persistence failure. stderr contains only a
short error code. Revoke access in Settings to disable further operations.
