# gllAutomationServer — Help

In-app automation server for **unattended GUI testing** of VCL applications. An external agent (the `gitlak-mcp` `app_*` tools) drives and asserts on a running app — clicking, typing, reading/writing properties, answering modal dialogs, inspecting datasets, and screenshotting — over a loopback socket, with no human at the keyboard. It operates on the live VCL component model (not pixels), so it is coordinate-free, DPI/monitor-independent, and works on any build including an EurekaLog-packed one (it needs no debug symbols).

This file is the lookup reference.  Task-by-task walkthroughs are in [Users Guide.md](Users%20Guide.md), and the change record is `CHANGELOG.md`.


**Hosts.** Two kinds use this one unit:

- **Applications** (the 27 DBiWorkflow VCL apps) link it statically through the library path and start it on `/AUTOMATION`.
- **gllIdeAutomation** (`gllIdeAutomation\` in this repository) loads this package into the Delphi IDE through its `requires` clause, starts it on `GITLAK_IDE_AUTOMATION=1`, and adds its ToolsAPI and `tree_text` commands with `RegisterCommand`.

Until 2026-10-13 the unit lived in GITLAKLib with a renamed, hand-synced copy in gllIdeAutomation. See the `CHANGELOG.md` entry for 1.0.0.

---

## When to use

- Drive an app end-to-end unattended (auto-login → navigate → assert → screenshot).
- Assert on real state behind the UI (a dataset field, a control property) rather than reading pixels.
- Answer a modal dialog that is blocking the app.
- Exercise keyboard behaviour: shortcuts, `KeyPreview`, Tab-out validation.

## When NOT to use

- Low-level/crash analysis — use the `dbg_*` debugger tools.
- Pixel-perfect visual regression — `screenshot` is confirmation only.

---

## Gating — an explicit opt-in, and nothing else

An application references the unit **unconditionally, in BOTH Release and Debug**, and starts it only on an explicit opt-in. One line per app, in the `.dpr`:

```pascal
if FindCmdLineSwitch( 'AUTOMATION' ) then
  TAutomationServer.Start( 'DBiScheduledEvents' );
```

**Why there is no compile-time gate (removed 2026-08-10):** Release is the configuration actually deployed, and the one that produces the EurekaLog reports — and it was the only configuration that could not be driven or inspected.

**What that means for exposure — stated honestly:**

- **No switch ⇒ nothing exists.** `Start` is never called, so no listener is created and no discovery file is written. A normally launched build behaves exactly as it did before.
- **When it *is* started it is loopback-only and token-authenticated** — `127.0.0.1` only, and every request must carry the per-session GUID token from the discovery file, else `Unauthorised`.
- **The real delta:** a deployed exe *contains* the server code, so anyone who can already launch that exe on that machine with an extra command-line switch can drive it. It is not a remote exposure, and it grants nothing that running the app interactively on the same box does not.

> **EurekaLog note:** a `build_project`/MSBuild exe links EurekaLog but is **not** injected, so the *first* runtime exception trips EL's *"options not on board"* fatal dialog. Before running, `ecc32`-post-process the exe, or use an IDE build, which injects EL automatically. The injected exe is packed (no source-level debugging) but the server drives it fine.

---

## DBiWorkflow deployment

Wired into **27 DBiWorkflow VCL apps**. The `.dpr` adds `gllAutomationServer` to its plain uses clause and calls `Start` after `InstallSuiteLogger` (or after `Application.Initialize`). **Excluded:** DBManager, DBiServer (service), DBiFunctions (DLL), console/test tools, and a few trivial run-and-exit utilities.

The 27: DBiAccounts, DBiAdmin, DBiAnalytics, DBiAutoJob, DBiBackup, DBiConfig, DBiDashBoard, DBiDevDiag, DBiFieldTech, DBiFinance, DBiLogTriage, DBiLogViewer, DBiMaint, DBiManager, DBiOnLine, DBiPV, DBiReporter, DBiScheduledEvents, DBiScheduledReports, DBiScrap, DBiSCtoXX, DBiStore, DBiTaskViewer, DBiTimeSync, DBiUsers, DBiWhoIsOn, DBiWorkflow.

App-specific awareness when driving:
- **DBiOnLine** — log in with the **customer** account (`/company=CUSTOMER_KEY`); this Web-Portal app rejects admin accounts.
- **DBiFieldTech / DBiOnLine** — Web-Portal apps; on the desktop they warn they're web-only and may keep MainForm hidden. The server still runs (verify via `ping` / `dialogs`).
- **DBiMaint** — refuses to start while any other DBiWorkflow app is running, and once it *is* running no other app will start. Never drive other apps alongside it.
- **DBiDevDiag** — hard-coded gate in `FormCreate`; the server starts before it, but MainForm only appears after that bespoke login.
- **DBiTimeSync** — must be `ecc32`-injected with its **own** EurekaLog profile, not the shared `DBiWorkflow.eof`.

> **The apps find the unit through the library path** (`D:\gllAutomationServer\37.0\<Platform>\Release`). After a change here, rebuild this package (all four modes) and then the app; `ping`'s `server` field says which protocol version an app is running.

---

## Transport, discovery & auth

- **Transport:** loopback TCP (`127.0.0.1`, port auto-scanned from `8730`), newline-delimited JSON — one JSON object per line, request and response (Indy `TIdTCPServer`).
- **Discovery:** each running instance writes `C:\ProgramData\GITLAK\Automation\<pid>.json` = `{ app, pid, port, token, started }`, a **fixed, account-independent** directory. Deleted on clean shutdown; stale files of dead processes are swept on start. When the server creates the directory it gives it a **protected DACL** (SYSTEM, Administrators and the current user only), because the file holds the session token.
- **Auth:** a per-session GUID **token**. Every request must carry it; bad/missing token → `Unauthorised`.
- **Every request gets a reply**, carrying the request's `id`, the pre-dispatch failures (`Unauthorised`, `BadRequest`, `RequestTooLong`) included. A wrongly typed envelope field is treated as absent (`"id":"abc"` gives `id` 0), and an exception anywhere in the marshalled body comes back as `Internal`, never as a closed connection.
- **A request line is at most 1 MB.** A longer one is answered `RequestTooLong` and the connection closed.

```json
{ "token":"…", "id":1, "cmd":"set", "form":"active", "name":"edtUserID", "prop":"Text", "value":"USER01" }
{ "id":1, "ok":true, "result":{ "name":"edtUserID", "prop":"Text", "value":"USER01" } }
{ "id":1, "ok":false, "error":{ "code":"NoComp", "message":"component \"x\" not found on LogInForm" } }
```

### Addressing a form (`form`)

A form `Name`, `"main"` (→ `Application.MainForm`), or `"active"` (→ `Screen.ActiveForm`). Omitted = `main`.

### Addressing a component (`name`) — 0.11

Omitted = the form itself. Otherwise, in this order:

1. **A name the form owns** (`form.FindComponent`) — the common case, and the only one before 0.11.
2. **A name reachable from the form** — a frame's control (owned by the frame, not the form), or a control **docked in** from elsewhere (parented into the form, owned by something else; an add-in's frame in the IDE). One match resolves; **several match → `Ambiguous`**, with `error.data.candidates` listing a path that reaches each.
3. **A dotted path** — `fraAddress.edtTown`: each step is found inside the previous one the same way.
4. **A synthetic name** — `@TButton#2`: the second unnamed `TButton`, numbered per class in a fixed order (the form's own components in `Components` order first, then what they own, then docked controls). `tree` reports unnamed components under these names, and they resolve back to the same component.

### Addressing a property (`prop`) — 0.11

- A published scalar property: `Caption`, `Enabled`, `ItemIndex`.
- **A dotted path through object properties:** `Font.Size`, `Margins.Left`. A step through a scalar → `NotObject`; through an unassigned object → `NilObject`.
- **A `TStrings` reads and writes as its text:** `Lines` and `Lines.Text` are the same thing; `Lines.Count` reads the count (read-only, `ReadOnlyProp` on a write). Before 0.11 `Lines` returned the object's address as a number.
- **An unpublished `Text` / `Caption` on a control** falls back to its window text — `TMemo.Text`, which TMemo does not publish.
- A path that ends on any other object (`Font`) → **`NotScalar`**, with that object's properties in `error.data.properties`.
- A `NoProp` failure lists the properties of the object where the step failed; object-typed ones are flagged `nested:true` (no value), so the caller knows it can reach into them.

---

## Command reference

| cmd | fields | result / effect |
|---|---|---|
| `ping` / `info` | — | `{ app, pid, version, package, exe, mainForm, server }`. `version` is the host exe's; `package` is the module holding this unit (this package's BPL inside the IDE, otherwise the exe again); `server` is the protocol version (`0.11`) |
| `tree` | `form?`, `deep?` | no form → `{ forms:[{name,class,visible}] }`; with form → `{ form, class, components:[{name,class,path?,props}] }` — the form's own components, plus with `deep:true` everything reachable (frame controls, docked controls). An unnamed component is listed under its synthetic name; `path` appears where the plain name is not what reaches it. Key published props: Caption/Text/Visible/Enabled/Checked/ItemIndex/bounds |
| `get` | `form?`, `name?`, `prop` | `{ name, prop, value }` — see *Addressing a property*. On `NoProp` the failure carries `error.data` = `{ properties:[{name,type,value \| nested}], total, truncated }` |
| `set` | `form?`, `name?`, `prop`, `value` | writes the property and reads it back → `{ name, prop, value, previous, changed }`. `changed:false` = it already held that value, so an `OnChange` almost certainly did not fire; the write is **not** elided. `NoProp` carries the **writable** property list |
| `click` | `form?`, `name`, `mode?`, `count?` | `mode=direct` (default) fires the component's `OnClick` — the reply waits for the handler; `mode=message` posts `BM_CLICK` (button-class controls only; visible+enabled required) and replies **before** the click runs, so a modal-opening handler can't block the command. Reply carries `mode` (+ `posted:true`), `clicksDispatched`. `count` (1..1000) repeats the click in one round-trip |
| `action` | `form?`, `name` | executes a `TBasicAction` by name, or the `Action` assigned to a named control. Refuses a disabled action (`ActionDisabled`) |
| `keys` | `form?`, `name?`, `text?`, `keys?`, `focus?`, `timeoutMs?` | (0.10) types `text`, then sends `keys` chords, to a windowed control (no `name`: the form's focused control) through the app's own message loop, and answers once delivered: `{ target, strokes, strokesSent, completed, modalOpen, stoppedReason? }`. See *Keyboard input* |
| `dialogs` | `button?` | no button → lists open top-level windows + their **visible, enabled** buttons; with button → clicks the first match (caption, `&` ignored) → `{ clicked, dialog, dismissed }` |
| `field_get` | `form?`, `name`, `field` | `{ dataset, field, type, isNull, value }` — `name` is a `TDataSet` or `TDataSource` |
| `field_set` | `form?`, `name`, `field`, `value` | `{ dataset, field, state, isNull, value }` — writes the field (JSON `null` clears it), putting a **browsing** dataset into edit mode first; an existing insert/edit is left alone and nothing is posted. Writes the data directly, so control-level `OnExit` / validation does **not** run — use `keys` for that path |
| `dataset_op` | `form?`, `name`, `op` | `{ dataset, op, state, recNo }` — `op` = `insert` `append` `edit` `post` `cancel` `refresh` `first` `last` `next` `prior` (else `BadOp`). Needed because `TwwNavButton` does its dataset work in the navigator, not in `OnClick` |
| `dataset` | `form?`, `name`, `fields?` | `{ dataset, active, recordCount, recNo, bof, eof }`; `fields:true` adds the current record's values |
| `screenshot` | `form?`, `name?`, `area?`, `maxWidth?` | PNG saved to the real **Desktop** (Known Folder API) → `{ path, width, height, area, target?, renderer?, sourceWidth?, sourceHeight? }`. **Render mode** (0.12) — with a `name`, or a `form` and no `area`: the target's top-level window is rendered as it paints itself and the target cropped from it, at the host's own logical size, so it is legible at full detail and **correct even when the window is covered or off-screen**; `area` is `control` or `form`, `renderer` is `dwm` (or `paintTo`, a weaker fallback that may miss a form's child windows). **Capture mode** — otherwise: screen pixels of the monitor the active form/dialog is on, `area:"window"` that window, `area:"virtual"` the whole desktop — whatever is in front of the app is what you get. `maxWidth` scales either down proportionally (`sourceWidth`/`sourceHeight` then give the original). See *Screenshots* below |

**Error codes:** `Unauthorised`, `UnknownCmd`, `NotVisual`, `NotShowing`, `NoForm`, `NoComp`, `Ambiguous`, `NoProp`, `NotObject`, `NilObject`, `NotScalar`, `ReadOnlyProp`, `NoOnClick`, `NoHandler`, `NotButton`, `NotClickable`, `BadMode`, `BadCount`, `NoAction`, `ActionDisabled`, `NotDataSet`, `DataSetClosed`, `NoField`, `ReadOnlyField`, `BadOp`, `NoButton`, `CaptureFailed`, `BadKeys`, `Busy`, `NotTypable`, `Blocked`, `BadRequest`, `RequestTooLong`, `Internal`. A failure may carry `error.data` (`NoProp`, `NotScalar`, `Ambiguous`).

### ⚠ `click mode=direct` is an exception firewall — the global error path never runs

`direct` mode invokes `OnClick` **inside** the command, so an exception the handler raises is caught here and reported as `stoppedReason: "exception:<ClassName>"` + `stoppedMessage`. It never reaches `Application.HandleException`, so **EurekaLog does not fire, no `.elp` is written, and no error dialog appears** — a result that reads exactly like a broken crash handler. **To exercise a global error path, use `mode=message`:** the posted `BM_CLICK` runs the handler from the app's own message loop, so the exception takes the route it would from a real user click.

### Screenshots: render, don't capture

Capture mode copies screen pixels, so a window behind another — your editor, a tooltip — or off-screen comes out as whatever is in front of it, with no error. Render mode asks the window to paint itself instead:

- The main thread only **plans**: it resolves the target and works out its top-level window and the target's rectangle inside it, in the host's own DPI space.
- The **worker thread** then calls `PrintWindow( root, dc, PW_RENDERFULLCONTENT )` — DWM's rendering of the whole window, frame and every child — into a **32-bit** bitmap, and crops the target out. Measured 2026-10-13, each of these silently fails: calling `PrintWindow` from the window's own thread (DWM returns FALSE: the window has to repaint and its thread is busy running the caller); the classic `PrintWindow` on a VCL child control (TRUE, blank image); a 24-bit bitmap (TRUE, blank image); and a VCL bitmap canvas used off the main thread without `Canvas.Lock` (the VCL reclaims its DC).
- DWM refuses a child window, so a control is always cropped from its top-level window's rendering — windowed or not, a `TLabel` included.
- **Session 0** (a process launched from a service) has no interactive desktop: render mode returns a blank image there. Real applications run in a user session; the test suite's render tests ignore themselves in Session 0.
- Render mode synchronises its planning onto the main thread, so it waits while a native dialog blocks that thread; capture mode does not, and is the one to use then.
- Errors: `NotVisual` (not a control), `NotShowing` (hidden, on a hidden parent, or outside its window).

### Keyboard input (`keys`)

Chords are separated by spaces or commas, each one key with optional `Ctrl+` / `Shift+` / `Alt+`: `A`-`Z`, `0`-`9`, a single character the layout types with at most Shift, `F1`-`F24`, `Enter` `Return` `Tab` `Esc` `Escape` `Space` `Backspace` `Delete` `Del` `Insert` `Ins` `Home` `End` `PgUp` `PgDn` `Up` `Down` `Left` `Right` `Plus` `Minus` `Comma` `Period` `Apps`. `text` goes first, then `keys`. `focus` (default true) focuses the control first, firing the previous control's `OnExit` and this one's `OnEnter`. `timeoutMs` default 5000, clamped 100..60000.

Each stroke sets the main thread's keyboard state (the modifiers VCL reads through `GetKeyState`; Caps Lock cleared), posts the key-down and key-up to the control, and posts a step marker to the server's **own hidden window**, reposted once so the `WM_CHAR` that `TranslateMessage` queues lands before the next stroke. (Before 1.0.0 the marker went to `Application.Handle`; a host without an application window — a console test runner — stalled after one stroke.) Because the messages run through the app's own loop, `Application.OnMessage`, `KeyPreview`, menu/action shortcuts, Tab/Enter/Esc dialog navigation and `OnKeyDown`/`OnKeyPress`/`OnKeyUp` all fire as for a real keyboard — no global input, no need for the app to be in the foreground. The saved keyboard state is restored at the end.

- Text is typed with the key (plus Shift) the current layout uses for each character; one no key produces without Ctrl/Alt is posted as a bare `WM_CHAR` (`OnKeyPress` only). A line break is typed as Enter.
- A stroke that opens a modal window is caught at the next step (the target's form is disabled): the sequence stops with `stoppedReason:"modal"`, the modifiers are released, and nothing is typed into the control behind it. Answer the modal with `dialogs`.
- One sequence at a time (`Busy`). An Alt chord that opens a menu enters the menu's own modal loop and is best-effort.
- Errors: `BadKeys` (nothing to send, > 4096 strokes, unknown key, modifiers with no key), `NotTypable` (not windowed, or not visible+enabled), `Blocked` (a modal window is already open over the form).

---

## Threading model (important)

Most commands touch the VCL, which is not thread-safe, so they are marshalled from the Indy worker thread to the **main VCL thread** via `TThread.Synchronize`. A VCL `ShowModal` keeps pumping `CheckSynchronize`, so these still work while a *VCL* modal form is up.

A **registered** command runs where it was registered to: `actMainThread` (the default) is marshalled like the built-ins, and `actWorkerThread` runs on the worker for a handler that must wait on the main thread.

**`keys` runs on the worker thread but synchronises its start** (resolve, validate, focus), then waits there while the main thread delivers the strokes.

**`dialogs` and `screenshot` deliberately run on the worker thread (no `Synchronize`)** — pure Win32 / GDI. A native `TaskDialog` / `StyledTaskDialog` / EurekaLog dialog runs its own message loop that **never** pumps `CheckSynchronize`, so `Synchronize` would deadlock. `dialogs` clicks via `SendMessageTimeout(BM_CLICK, SMTO_ABORTIFHUNG)` and reads text the same way (`GetWindowText` has **no timeout** against a same-process hung thread); `screenshot` BitBlts from the desktop DC.

- **Visible-button filter:** styled `TaskDialog`s ship every possible button as a hidden child window — `dialogs` only lists/clicks visible, enabled buttons.
- **High-DPI capture:** `screenshot` sets its own thread to `PER_MONITOR_AWARE_V2` so it captures at native resolution. This affects only the capture thread.

**Idle timers.** Unless the host passes `ADisableIdleTimers = False` to `Start`, every command that touches the VCL first disables components whose class name contains `IDLETIMER`, so an application cannot log itself out mid-test. gllIdeAutomation passes `False`: the IDE's timers belong to its plug-ins.

---

## Auto-login (removed)

---

## Agent side — `gitlak-mcp` `app_*` tools

| Tool | cmd |
|---|---|
| `app_list` | scans the discovery dir → running instances |
| `app_ping` | `ping`/`info` |
| `app_tree` | `tree` |
| `app_get` / `app_set` | `get` / `set` |
| `app_click` | `click` |
| `app_action` | `action` |
| `app_keys` | `keys` |
| `app_dialogs` | `dialogs` (list / answer) |
| `app_field_get` / `app_field_set` | `field_get` / `field_set` |
| `app_dataset` / `app_dataset_op` | `dataset` / `dataset_op` |
| `app_screenshot` | `screenshot` (returns a Desktop PNG path to `Read`) |
| `app_command` | any command, including registered ones (`tree_text`, `ide_*`, `debug_*` in the IDE) and `tree` with `deep` |

`target` accepts an app name or PID, or is omitted when only one instance is running. Source: `D:\GITLAKMCP\src\Tools\GitLAKMCP.Tool.AppAutomation.pas`.

---

## API

```pascal
TAutomationServer = class
  class procedure Start( const AAppName: string; ADisableIdleTimers: Boolean = True );
  class procedure Stop;                             // stop + delete discovery file
  class function  IsRunning: Boolean;
  class function  Port: Word;
  // commands from outside this unit
  class procedure RegisterCommand( const AName: string; const AHandler: TAutomationCommand;
    AThread: TAutomationCommandThread = actMainThread );
  class procedure UnregisterCommand( const AName: string );
  // addressing, exactly as the built-ins do it - for a registered command's handler
  class function  ResolveForm( ARequest: TJSONObject ): TForm;
  class function  ResolveComponent( ARequest: TJSONObject; AForm: TForm ): TComponent;
end;

TAutomationCommand       = reference to function( ARequest: TJSONObject ): TJSONValue;
TAutomationCommandThread = ( actMainThread, actWorkerThread );
EAutoError               = class( Exception )   // CreateCode( Code, Msg ) / CreateCodeData( Code, Msg, Data )
```

## Registered commands

A host can add commands of its own without touching this unit:

```pascal
TAutomationServer.RegisterCommand( 'myapp_state',
  function( ARequest: TJSONObject ): TJSONValue
  begin
    Result := TJSONObject.Create.AddPair( 'jobs', TJSONNumber.Create( JobCount ) );
  end );
```

- **Built-in commands are matched first**, so a registered name can never shadow one.
- Names are matched without regard to case, and registering a name again replaces its handler.
- The handler returns the `result` value, and the server owns it. To fail, **raise `EAutoError`**: its `Code`, message and optional `Data` come back as `error`. Any other exception is `Internal`.
- Register before `Start`, or at any time after: the registry is guarded.
- Address forms and components with `ResolveForm` / `ResolveComponent`, so a registered command understands paths, synthetic names and `Ambiguous` exactly as the built-ins do.
- gllIdeAutomation registers 22 commands this way: `tree_text` and the ToolsAPI set (`ide_quit`, `ide_menu_click`, `debug_step`, ...).

## Tests

`Tests\gllAutomationServerTests.dproj` — 22 end-to-end DUnitX tests over loopback: the command registry, the envelope contract, addressing (paths, `Ambiguous`, docked and synthetic names), property paths, `keys`, and screenshot render mode (an off-screen control's own colour, a cropped `TLabel`, a whole form with its children, `maxWidth`). The four screenshot tests ignore themselves in Session 0, so through GITLAKMCP's `test_run` (a service) expect 18 passed / 4 ignored; run the exe from a desktop session for 22. The test project links this package's DCUs from `..\37.0\<Platform>\<Config>`, so **build the package first**. Mutation-proved on 2026-10-13: dropping the Shift state from typed text and resolving an ambiguous name to its first match each turned exactly one test red; rendering into a 24-bit bitmap turned the three pixel-checking screenshot tests red.

## Related

- `D:\GITLAKMCP\src\Tools\GitLAKMCP.Tool.AppAutomation.pas` — the agent-side tools.
- `gllIdeAutomation\` in this repository — the IDE host and its registered commands.
