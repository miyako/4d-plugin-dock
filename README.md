# 4d-plugin-dock

Dock is a macOS-only 4D plugin that controls the application's Dock tile through AppKit (`NSApplication`, `NSDockTile`): it can set or read the badge label, bounce the icon to request attention, replace or read the icon image, and run a 4D project method whenever the user clicks the application's Dock icon. Text results are `Text`, icon results are `Picture`, and bounce request identifiers are `Integer`.

| Command | Returns | Purpose |
|---|---|---|
| [Dock SET METHOD](#dock-set-method) | – | Registers (or clears) the method called when the Dock icon is clicked |
| [Dock Get method](#dock-get-method) | `Text` | Returns the registered method name |
| [DOCK SET BADGE](#dock-set-badge) | – | Sets or removes the badge label |
| [DOCK Get badge](#dock-get-badge) | `Text` | Returns the current badge label |
| [DOCK Bounce](#dock-bounce) | `Integer` | Bounces the Dock icon |
| [DOCK CANCEL BOUNCE](#dock-cancel-bounce) | – | Cancels a bounce |
| [DOCK SET ICON](#dock-set-icon) | – | Replaces the application icon |
| [DOCK Get icon](#dock-get-icon) | `Picture` | Returns the application icon |

**Platforms:** macOS only (4D, 4D Server on macOS). The plugin has no Windows implementation.

## Manual versioning and publication

**Bump version** and **Build** are independent manual Actions workflows. Choose
the branch with GitHub's built-in selector. Bump takes only `patch`, `minor`, or
`major`; Build has **zero custom inputs**. Neither branch pushes, PRs nor tags
trigger a native build. No branch-name publication restriction is imposed.
Every checkout uses the dispatch's immutable `github.sha`.

The original Bump header introduced in `18837da` explicitly coordinated
`MARKETING_VERSION`, `CURRENT_PROJECT_VERSION` and plist versions; that contract
governs despite its marketing-first implementation. At intake `3388001`, the
six marketing assignments and source plist short version were `2.0.2`; the
three current-project assignments and source English display were stale at
`2.0.1`. This migration repairs only those stale source tokens to `2.0.2`;
it does not increment the release authority or add the absent `CFBundleVersion`.
Future literal source versions co-bump. Supported `$(...)` / `${...}` references
are validated and preserved; missing optional build-version keys remain absent.
Unknown/cyclic references, noncanonical `X.Y.Z`, duplicates and drift fail before
any writes. UTF-8 BOM, individual line endings, modes and unrelated bytes survive.

Bump requires a clean checkout of the exact selected remote branch and creates
one nonempty source-only commit with a single direct parent. Its mandatory
executable pre-push guard checks the actual advertised old SHA/ref, literal new
SHA and HEAD, rejecting branch advance, rewind, deletion and same-result races.
The push is nonforce, explicit, and disables tag following in both Git config
and push options. Bump never creates tags, releases, builds or dispatches.

Build derives `vX.Y.Z`, `Dock-X.Y.Z.zip` and `Dock-X.Y.Z.dmg` from selected
source metadata. A repository-wide constant publication concurrency group queues
all refs without cancellation. Authenticated, fully paginated release checks
(including drafts) and exact remote tag absence run before native work and again
after every native gate. API/auth/network/schema errors, including 404, stop
publication rather than implying absence.

The actual pipeline remains macOS-only: `Dock.xcodeproj`, target `Dock`,
configuration `Default`, `arm64 x86_64`, deployment override `11.0`. It rebuilds
only generated executable/plist/localized/signature/intermediate outputs and
pins the configuration output to `test/Plugins` to avoid a `Default` subfolder.
It preserves committed resources, framework dependencies and Windows payloads;
the existing `Dock.vcxproj` v140/Win32/x64 configuration is not run or modified.
The project resource phases and deployment-only script remain unchanged.
Architecture checks require exact tokens without inventing slice-count or
extra-architecture restrictions. Built plist and actual English localization
(text, UTF-16, XML or binary plist) must match selected source before signing.
Developer ID signing, strict verification, both successful **Accepted** JSON
notarizations and DMG stapling are mandatory. Existing secret names are unchanged.

### Publication failure and manual recovery

Publication uses separate create-only operations: POST a new `git/refs` tag at
the selected SHA, verify that remote tag, POST a **new public, nonprerelease**
release with explicit tag/name/target/body/flags, then upload ZIP and DMG to the
new returned release ID with exact filenames. The original empty release body
and nongenerated-notes behavior are preserved.

There is **no** reuse, PATCH, update, DELETE, clobber, retry or rollback. A race
or any failed/malformed response stops immediately. A tag, release or earlier
uploaded asset may already exist and is intentionally retained. Inspect the
run log, selected SHA, exact tag, release ID and asset list before any manual
decision; never assume a failed response means no remote mutation happened.
Re-running Build for that occupied version will fail, not finish or replace it.
Resolve partial publication manually under maintainer review, or choose a new
source version with Bump and independently run Build. Never automatically delete
or retag an existing version.

Offline regression checks (no real native build or GitHub mutation):

```sh
actionlint
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s .github/tests -v
```

Tests adapt the pinned Native Encoding Detection, File Information, Common
String Algorithm, Window Button, Raw Picture Data and PRNG workflow safeguards
to Dock's actual source layout and macOS-only pipeline. Native workflow run
blocks execute only against closed-PATH stubs; no real Apple tools or 4D run.

---

## Requirements & platform notes

- **The plugin never raises a 4D error.** Every failure (an icon that cannot be decoded, an unreachable class, an invalid request ID) is silent: the command returns without effect. Check results yourself where it matters.
- **Dock commands act on the running application's own Dock tile.** On 4D Server for macOS they affect the server application, not a client.
- **All commands are declared thread-safe**, so they can be called from preemptive processes. The badge, bounce and icon commands (`DOCK SET BADGE` through `DOCK Get icon`) execute in 4D's main process; the calling process waits until the main process is free to run them. `Dock SET METHOD` and `Dock Get method` only touch plugin state.
- **The click callback depends on an internal 4D class** (`XMacApplicationDelegate`). If 4D ever renames it, `Dock SET METHOD` has no visible effect and no error is reported.
- **While a method is registered, a Dock click no longer triggers the application's default "reopen" handling.** After you clear the method, the original behavior is restored.
- Calls made from the `$xx` (On Exit) process to `Dock SET METHOD` are ignored. When the plugin unloads, the badge is cleared and the click hook is disabled.

---

## Dock SET METHOD

### Syntax

```4d
Dock SET METHOD ( method : Text )
```

| Parameter | Type | Description |
|---|---|---|
| `method` | Text | Name of a project method to run on each Dock click. An empty string disables the feature. |

### Description

Passing a non-empty name enables the Dock click notification and starts a background process named `DOCK_NOTIFICATION`. Each time the user clicks the application's Dock icon (the macOS "reopen" event), the plugin queues an event and the `DOCK_NOTIFICATION` process runs your method.

- **The method receives no parameters.** Do not declare any.
- **Delivery is not instantaneous.** The background process polls roughly once a second, so the method can run up to about a second after the click.
- **Clicks are queued and handled one at a time**, in order, in the `DOCK_NOTIFICATION` process. A slow method delays later calls but never blocks the main process.
- **The method name is looked up on every call.** If the name does not resolve to a project method, the plugin falls back to running it through 4D's `EXECUTE METHOD` mechanism; an invalid name is expected to produce a 4D error inside the `DOCK_NOTIFICATION` process on each click (this fallback was not traced further).
- **Passing an empty string** stops the background process, discards queued events and restores the original click behavior. Calling the command again with a different name while enabled just changes the method.
- The method runs in a cooperative process; the sample method is marked as not preemptive-capable (`"preemptive":"incapable"`).

### Example

From the plugin's own test method (`test.4dm`):

```4d
Dock SET METHOD("onDock")
```

The method it registers (`onDock.4dm`), which increments the badge on every click:

```4d
//%attributes = {"invisible":true,"preemptive":"incapable"}
#DECLARE()

//TRACE

$badge:=Num:C11(DOCK Get badge)
$badge+=1

DOCK SET BADGE(String:C10($badge))
```

Disable the notification, for example before quitting a long-running process that no longer needs it:

```4d
Dock SET METHOD("")
```

---

## Dock Get method

### Syntax

```4d
Dock Get method → Text
```

| Parameter | Type | Description |
|---|---|---|
| Result | Text | The name last passed to `Dock SET METHOD`, or an empty string if none is registered. |

### Description

Returns the registered method name. After `Dock SET METHOD("")` the result is an empty string.

### Example

```4d
Dock SET METHOD("onDock")
If (Dock Get method="onDock")
	// registered
End if
```

---

## DOCK SET BADGE

### Syntax

```4d
DOCK SET BADGE ( label : Text )
```

| Parameter | Type | Description |
|---|---|---|
| `label` | Text | Text shown in the red badge on the Dock icon. An empty string removes the badge. |

### Description

Sets the Dock tile's badge label and refreshes the tile. Any text is accepted; the Dock itself decides how to display or truncate long strings. Pass an empty string to clear it.

### Example

```4d
DOCK SET BADGE("3")   // show a badge
DOCK SET BADGE("")    // remove it
```

---

## DOCK Get badge

### Syntax

```4d
DOCK Get badge → Text
```

| Parameter | Type | Description |
|---|---|---|
| Result | Text | The current badge label, or an empty string when there is none. |

### Description

Reads the badge label. Because it returns text, convert with `Num` when you use it as a counter, as the `onDock` sample does.

### Example

```4d
$badge:=Num:C11(DOCK Get badge)
$badge+=1
DOCK SET BADGE(String:C10($badge))
```

---

## DOCK Bounce

### Syntax

```4d
DOCK Bounce ( type : Integer ) → Integer
```

| Parameter | Type | Description |
|---|---|---|
| `type` | Integer | The AppKit attention-request type. The value is passed to `NSApplication` unchanged. |
| Result | Integer | The request identifier to pass to `DOCK CANCEL BOUNCE`. `0` means no request was made. |

### Description

Asks the Dock to bounce the application icon. The two standard AppKit values are `0` (critical: the icon bounces until the application is activated or the request is cancelled) and `10` (informational: it bounces once). These numbers are AppKit's own, not plugin constants; the plugin does not validate them.

**If the application is already frontmost, AppKit makes no request and the result is `0`.** The request identifier is the function result. For backward compatibility the plugin also writes it back into `type` when you passed a variable, but do not rely on that.

### Example

```4d
// bounce once
$request:=DOCK Bounce(10)

// bounce until the user comes back, then cancel from code if needed
$request:=DOCK Bounce(0)
If ($request#0)
	DOCK CANCEL BOUNCE($request)
End if
```

---

## DOCK CANCEL BOUNCE

### Syntax

```4d
DOCK CANCEL BOUNCE ( request : Integer )
```

| Parameter | Type | Description |
|---|---|---|
| `request` | Integer | A request identifier returned by `DOCK Bounce`. |

### Description

Cancels the attention request. An identifier that is unknown or already finished has no effect and raises no error.

### Example

```4d
$request:=DOCK Bounce(0)
// ...later
DOCK CANCEL BOUNCE($request)
```

---

## DOCK SET ICON

### Syntax

```4d
DOCK SET ICON ( icon : Picture )
```

| Parameter | Type | Description |
|---|---|---|
| `icon` | Picture | The image to use as the application icon. |

### Description

Replaces the application icon shown in the Dock. The picture is converted to a native image at its own pixel size. **An empty picture, or one that cannot be converted, leaves the current icon unchanged.** The change lasts only for the current run of the application; it is not saved.

### Example

Round-trip the current icon back into the Dock (a harmless way to see it work). To load an image from disk or a form, use whichever picture command your 4D version provides; check the Language Reference for the exact syntax.

```4d
$icon:=DOCK Get icon
DOCK SET ICON($icon)
```

---

## DOCK Get icon

### Syntax

```4d
DOCK Get icon → Picture
```

| Parameter | Type | Description |
|---|---|---|
| Result | Picture | The application icon, encoded as TIFF. |

### Description

Returns the icon currently shown by the application (the custom one if `DOCK SET ICON` was used). It is rendered at the icon's native size, so large icons give a large uncompressed picture. **If the icon cannot be rendered or encoded, no picture is set** and the result should be treated as empty.

### Example

```4d
$icon:=DOCK Get icon
// combine with any of 4D's picture or document commands to save or display it
```

---

## Error handling & troubleshooting

- **Nothing happens on Dock click.** Check `Dock Get method` returns your name, that the click is on the running app's Dock icon, and allow up to about a second for delivery. If 4D's internal delegate class changed, the hook silently does nothing.
- **Method error on every click.** The registered name does not resolve to a method; the plugin reports no error of its own, so 4D raises one in the `DOCK_NOTIFICATION` process.
- **The method does not receive the event.** By design it is called with no parameters.
- **Default Dock-click behavior disappears.** While a method is registered the click does not run AppKit's default reopen handling. Call `Dock SET METHOD("")` to restore it.
- **`DOCK Bounce` returns 0.** The application is already active, so AppKit made no request; there is nothing to cancel.
- **Icon did not change.** The picture was empty or could not be decoded; the command fails silently.
- **Calls seem slow.** Badge, bounce and icon commands wait for the main process; a busy or modal main process delays them.
- **Settings reset on restart.** Badge, custom icon and the registered method are not persisted; register the method again at startup.

---

## Quick reference

```4d
Dock SET METHOD("onDock")      // react to Dock clicks
$m:=Dock Get method
Dock SET METHOD("")            // stop reacting

DOCK SET BADGE("5")
$b:=DOCK Get badge
DOCK SET BADGE("")

$r:=DOCK Bounce(10)            // 10 = once, 0 = until activated
DOCK CANCEL BOUNCE($r)

$icon:=DOCK Get icon
DOCK SET ICON($icon)
```
