# Local Automation

Open Clipy Settings → Automation, enable access, and grant the permissions
your program needs. Access starts with no permissions. All programs running as
your macOS account share this connection. Deletion and revision each require
their own confirmation when granting access. Cancelling either confirmation
leaves that permission off. Revision permission does not grant reading or
deletion; each permission can be revoked independently.

Revising content appends an immutable revision. Original content and older
revisions remain retained until removed by retention or item deletion; a
revision does not erase the previous bytes. Programs with revision permission
may make further changes without asking again, subject to the supplied content
version matching the item's current version.

The server credential is kept in a separate owner-only directory under
`Application Support/Clipy/LocalAutomationServer`, one connection UUID per
subdirectory. Directories use mode `0700` and credential files use `0600`.
The client has its own credential copy; deleting it does not erase the server
verifier needed to report a revoked connection. This is account-wide access,
not protection against a malicious program already running as your account.
There is no Keychain fallback, signature requirement, or old-custody migration.

When access is disabled and no client credential remains, opening Settings
does not read server credentials. Enable first removes server credentials left by
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
| `reviseContent` | `locator`, `expectedContentVersion`, complete `representations` | Revise Content |

The two content operations return `contentVersion` together with current
representations as type identifiers and base64 bytes. `pasteEffective` returns a payload to your program; it does
not change the system clipboard or simulate a paste. Original content and old
revisions are not disclosed. Locators and cursors are opaque and expire across
an app restart; rerun browse/search when they expire.

To revise an item, first read its Effective content and retain that reply's
`contentVersion`. Submit `reviseContent` with that number as
`expectedContentVersion` and a complete desired representation array. Each
entry contains exactly `typeIdentifier` and `bytesBase64`. Bytes are preserved
exactly, including NUL, line endings, and Unicode spelling. Base64 must use its
standard alphabet and padding, without whitespace. Empty payloads, duplicate
types, and types absent from the item's original content are rejected. Omitted
original types become hidden from Effective content.

The whole request, including Base64 and JSON, must fit within 65,536 UTF-8
bytes. This limits this initial CLI revision operation to slightly less than
48 KiB of raw content even when the content read returns more. A stale expected
version returns `content_stale` with exit status `4` and leaves the item
unchanged. A successful byte-identical submission returns `changed: false`.

This Python example replaces a text item's UTF-8 representation while retaining
the other representations from the same read:

```python
import base64
import json
import subprocess
import uuid

client = "/Applications/Clipy.app/Contents/MacOS/clipyctl"

def call(operation, arguments):
    request = {
        "protocolVersion": 1,
        "requestID": str(uuid.uuid4()),
        "operation": operation,
        "arguments": arguments,
    }
    completed = subprocess.run(
        [client], input=json.dumps(request), encoding="utf-8",
        capture_output=True, timeout=30, check=False,
    )
    reply = json.loads(completed.stdout)
    if completed.returncode:
        raise RuntimeError(reply["error"]["code"])
    return reply["result"]

locator = "<locator returned by browsePreview>"
current = call("detailsEffective", {"locator": locator})
representations = current["representations"]
text = next(rep for rep in representations
            if rep["typeIdentifier"] == "public.utf8-plain-text")
text["bytesBase64"] = base64.b64encode(b"literal replacement\n").decode("ascii")
result = call("reviseContent", {
    "locator": locator,
    "expectedContentVersion": current["contentVersion"],
    "representations": representations,
})
print(result["changed"])
```

Read and revision permissions are separate. The revision result contains only
`changed`; obtaining a fresh version or current bytes requires another explicit
content read. The example deliberately does not retry a conflict or an unknown
write outcome automatically.

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
