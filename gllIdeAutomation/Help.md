# Help — gllIdeAutomation

`gllIdeAutomation` is a **design-time package** (`{$DESIGNONLY}`) that starts the GITLAK
automation server **inside `bds.exe`**, so the running Delphi IDE can be driven and inspected
from outside it over a loopback socket. It exists because some questions can only be answered by
a running IDE — what the evaluator calls a type, whether a visualizer is offered, how a value
renders — and none of that is visible to the compiler.

It targets **Delphi 13 / RAD Studio 37.0** only, VCL, **Win32 + Win64**: the units stop
with a `{$MESSAGE FATAL}` below `CompilerVersion 37.0` (until 2026-10-13 they carried a 10.3 Rio floor
and a `{$LIBSUFFIX}` ladder, from when the package was public). Proprietary, in-house.

This file is the **lookup** document for what this package adds: the gate, the 22 commands it
registers, their error codes, and the IDE-specific failures with their exact text. The automation
server itself (transport, discovery, addressing, the built-in commands and their error codes,
threading, `keys`) is the runtime package `gllAutomationServer`, documented in
`D:\gllAutomationServer\Help.md` ([GitHub](https://github.com/ijbranch/gllAutomationServer)).
For how to get it running and drive it, read
[Users Guide.md](Users%20Guide.md). The history is in [CHANGELOG.md](CHANGELOG.md); the
rationale and the tooling are in [README.md](README.md).

> `docs/HELP.md` and `docs/Users Guide.md` predate the estate documentation standard and are
> still present. This pair in the package folder is the conforming one.

---

## 1. The Pascal surface

The units are in `src\`, all listed in the `.dpk` `contains` clause: `gllIdeAutomation.Starter`,
`gllIdeAutomation.TreeText` and `gllIdeAutomation.IdeCommands`. There is no component to drop on
a form and no public class of this package's own: everything is built on `TAutomationServer` from
the `gllAutomationServer` runtime package.

### What it uses from `gllAutomationServer`

The server is its own package, at the root of this repository, `D:\gllAutomationServer` (unit
`gllAutomationServer`, package version 1.0.0.0, wire protocol version `0.12`), which this package
`requires`. Its full API is in `D:\gllAutomationServer\Help.md`; the parts used here:

| Member | Used for |
|---|---|
| `TAutomationServer.Start( const AAppName: string; ADisableIdleTimers: Boolean = True )` | Called by the starter as `Start( APP_NAME, False )`. `False` leaves the IDE's idle timers alone: they belong to its plug-ins. |
| `TAutomationServer.Stop` | Called by the starter's `finalization`; removes the discovery file. |
| `TAutomationServer.RegisterCommand` / `UnregisterCommand` | The 22 commands of `gllIdeAutomation.IdeCommands`. Built-in commands are matched first, so a registered name can never shadow one. |
| `TAutomationServer.ResolveForm( ARequest: TJSONObject ): TForm` / `ResolveComponent( ARequest: TJSONObject; AForm: TForm ): TComponent` | `tree_text` resolves `form` and `name` exactly as the built-ins do, so it takes dotted paths and synthetic names and answers `NoForm` / `NoComp` / `Ambiguous` the same way. |
| `EAutoError` | How a registered command fails with a code of its own. |

### `gllIdeAutomation.Starter`

No interface section at all — it is `interface` / `implementation` with an empty interface. Its
entire job is the gate:

| Constant | Value | Meaning |
|---|---|---|
| `ENV_GATE` | `GITLAK_IDE_AUTOMATION` | Must be `1` (after `Trim`) or nothing starts. |
| `APP_NAME` | `DelphiIDE` | The name the IDE is advertised under — this is what `app_list` shows. |

It starts the server with `TAutomationServer.Start( APP_NAME, False )`, then calls
`RegisterIdeCommands` from `gllIdeAutomation.IdeCommands`; on the way out it stops the server and
calls `UnregisterIdeCommands`. See [Registered commands](#registered-commands).

Both `initialization` and `finalization` are wrapped in a bare `try..except` that swallows
everything **deliberately**: an exception escaping a design-time package's initialisation is
reported to the user as a package load failure, for a facility they did not ask for. A port clash
must cost the automation server, never the IDE.

---

## 2. The wire protocol

### The server, in brief

Loopback TCP (`127.0.0.1`, port scanned upward from `8730`), one JSON object per line in, one
line out. Every request carries the per-session `token` from the instance's discovery file
(`C:\ProgramData\GITLAK\Automation\<pid>.json`, `app` = `DelphiIDE`, **written with a UTF-8 BOM**,
so read it with `encoding="utf-8-sig"`), an optional `id` echoed on every reply, and `cmd`.
Every request gets a reply; a failure is `{ id, ok:false, error:{ code, message, data? } }`.
A discovery file left behind means the host died: the name is the PID, so check the process is
alive before trusting it. The server sweeps dead PIDs' files on start.

The built-in commands are `ping` / `info`, `tree`, `get`, `set`, `click`, `action`, `keys`,
`dialogs`, `screenshot`, `dataset`, `dataset_op`, `field_get` and `field_set`. Inside the IDE,
`ping` reports `version` as `bds.exe`'s, `package` as the `gllAutomationServer` BPL's (`1.0.0.0`)
and `server` as the protocol version (`0.12`). Since 0.11 a component `name` may be a dotted path
(`fraA.edtTown`) or a synthetic name for an unnamed component (`@TButton#2`), reaches frame-owned
and docked controls, and a name that matches several is `Ambiguous`; `prop` may be a dotted path
(`Font.Size`) and `TStrings` read and write as text.

Their fields, results, error codes, threading and the `keys` vocabulary are documented once, in
`D:\gllAutomationServer\Help.md`. This file does not repeat them.

There is no general `wait` command. Polling is a client concern; a blocking wait would hold the
connection and the VCL thread it marshals onto. The one exception is the debugger commands that set
a process running, which take a `wait` of their own: only the debugger can say when a process has
stopped, and they wait on the worker thread, not the VCL thread.

### Registered commands

`src\gllIdeAutomation.IdeCommands.pas` registers 22 commands through
`TAutomationServer.RegisterCommand`: `tree_text` and the 21 ToolsAPI commands. `COMMAND_NAMES`
lists them, `tree_text` first. To a caller they are no different from built-ins.

#### `tree_text`

| `cmd` | Request fields | Result |
|---|---|---|
| `tree_text` | `form?`, `name`, `max?` | `{ name, class, columns, rows:[ { level, cells } … ], rowsRead, rootCount, complete, notes }` — every **displayed** row of a virtual tree, in display order. `columns` are the header captions by column index; `cells` are indexed the same way, trailing empty cells dropped; `level` is the nesting depth, `-1` if unreadable. `complete:false` always comes with a note saying why. `form` and `name` are resolved by the server's `ResolveForm` / `ResolveComponent`, so they are addressed exactly as for `get` |

Its handler, `CmdTreeText`, runs on the main thread; the reader is
`src\gllIdeAutomation.TreeText.pas`. See [`get` cannot read the debugger panes](#get-cannot-read-the-debugger-panes--use-tree_text).

#### ToolsAPI commands

Chosen after reading GxInspect's README, whose measured findings shaped several of them; each is
cited in the unit. The code is written here against `ToolsAPI.pas`, not taken from GxInspect (MPL).

| `cmd` | Request fields | Result |
|---|---|---|
| `ide_modified` | - | `{ count, modified:[ { file, kind, untitled } ] }` - everything that would make closing stop and ask. `kind` is `buffer` (an edited file) or `options` (changed project options); `untitled` means it has never been saved. An unsaved project group the IDE invented is left out: it never asks about one |
| `ide_quit` | `mode?` | `{ mode, closing:true, saved? \| discarded? }`; the IDE closes about 150 ms after the answer. `mode` is `refuse` (default: fail with `Modified` if anything is unsaved), `save`, `discard` or `ask`. **Script with `discard`**, not `save`: the IDE dirties files merely by opening them |
| `ide_menu` | `path?`, `depth?` | No `path`: `{ items:[ … ] }` for the menu bar. With one: that item, and its branch `depth` levels deep (default 1, at most 6). Each item: `{ name, caption, action?, enabled, visible, checked, separator, count, items? }` |
| `ide_menu_click` | `path` | `{ clickScheduled:true, item }`. The click happens after the answer, so a command that opens a dialog does not hold it up; ask `dialogs` next |
| `debug_state` | - | `{ activeProject, processes:[ { pid, exe, state, current } ], current:{ state, pid, exe, location? } }` |
| `debug_attach` | `pid`, `pause?` | `{ requested:true, pid, pause }` - answered **before** the attach happens; `debug_state` confirms it. Reset in the IDE then detaches rather than kills |
| `debug_detach` | - | `{ detached:true, pid }` - the process keeps running |
| `debug_pause` | - | `{ requested:true, pid }` - answered before it has stopped |
| `debug_run` | `wait?` | As `debug_step`. `wait` defaults to 0: answer at once |
| `debug_step` | `mode?`, `wait?` | `{ stopped, waitedMs, state, pid, exe, location:{ thread, file, line, … } }` - answered **once the process has stopped again**, saying where. `stopped:false` means `wait` (default 10000 ms) ran out first |
| `debug_run_to` | `file`, `line`, `wait?` | As `debug_step`. `file` is a path, or a file name open in the IDE |
| `debug_terminate` | - | `{ terminated:true, pid }` - the one command that ends the process |
| `debug_threads` | - | `{ pid, threads:[ { thread, name, state, current, file?, line? } ] }` |
| `debug_set_thread` | `thread` | The thread, as in `debug_threads` |
| `debug_stack` | `thread?`, `max?` | `{ thread, count, frames:[ { index, header, file, line } ] }` - what the Call Stack pane shows. `max` defaults to 100 |
| `debug_registers` | `thread?` | `{ thread, bits, registers:{ rax … r15, rip, eflags } }` (or the 32-bit set in the 32-bit IDE), as hex |
| `debug_memory` | `address`, `count?` | `{ address, requested, read, hex, stoppedAt?, reason? }`. `address` is a number, `$hex` or `0xhex`; `count` defaults to 64, at most 4096. Read a page at a time, so a range running into unreadable memory returns what it could |
| `debug_eval` | `expr`, `thread?`, `sideEffects?` | `{ expr, result, canModify, address, size }` - the IDE's own evaluator, so the text is what the IDE shows |
| `debug_breakpoints` | - | `{ breakpoints:[ { file, line, enabled, condition, passCount } ] }` - source breakpoints |
| `debug_breakpoint_set` | `file`, `line`, `condition?`, `passCount?`, `enabled?` | The breakpoint. Updates the one already on that line rather than adding a second. `enabled` defaults to true |
| `debug_breakpoint_delete` | `file`, `line` | `{ deleted:true, file, line }` |

**The debugger commands act on the debugger's CURRENT process, and that follows the ACTIVE
PROJECT.** Make another project active while a process is stopped and the process is still there
but no longer current, and every command here answers `NoProcess`, saying why (GxInspect,
measured). Make the project that was run active again and everything comes back.

**A paused process cannot answer its own automation server.** Talk to the IDE instead.

**Measured while building these, and worth knowing before you script against them:**

- `IOTAProcess.GetProcessType` answers `optOSX64` for a Win64 program in the 64-bit IDE, so the
  bitness is asked of Windows (`IsWow64Process`).
- `IOTAProcess.Run( ormRunToCursor )` runs straight past the line under the cursor. `debug_run_to`
  uses the editor view's `IOTAEditActions.RunToCursor`, which stops there.
- Reading an unmapped address raises `EDbkError: Debugger Kernel BORDBK370.DLL or BORDBK370N.DLL is
  missing or could not be loaded`. Nothing is missing; that is how the 64-bit IDE says the address is
  unreadable. `debug_memory` reports it as `Unreadable` with that explanation.
- The 64-bit IDE sees only the WOW64 layer of a 32-bit process, so `debug_registers` and
  `debug_memory` refuse there with `Unsupported`; the 32-bit IDE handles both.
- `ide_quit` with `discard` closed a project and an unsaved new unit without a prompt, and the
  project's `.dpr` on disk was byte-identical afterwards. The IDE then took over 8 s to exit.

### Command arguments with a fixed vocabulary

| Field | Command | Accepted values |
|---|---|---|
| `max` | `tree_text` | Row limit, default `2000`; clamped to `1`..`100000`. Reaching it ends the read with `complete:false` and a note. |
| `mode` | `ide_quit` | `refuse` (default), `save`, `discard`, `ask`. Anything else → `BadRequest`. |
| `mode` | `debug_step` | `over` (default), `into`, `out` (run until the function returns), `toSource`, `instInto`, `instOver`. Anything else → `BadRequest`. |
| `path` | `ide_menu`, `ide_menu_click` | Steps separated by `\|`, from the menu bar down. Each step is a component name or a caption; a caption is compared without its `&` and without case, and matches by its beginning when nothing matches it whole. A beginning that matches several items → `AmbiguousMenuItem`. Names are the dependable choice in a localised IDE; what the IDE generates (Reopen, Desktops, the user's tools) has no name and can only be named by caption. |
| `wait` | `debug_run`, `debug_step`, `debug_run_to` | Milliseconds, clamped to `0`..`120000`. |

The built-in commands' vocabularies (`click` `mode` and `count`, `dataset_op` `op`, `keys` chords
and `timeoutMs`, `screenshot` `area`) are in `D:\gllAutomationServer\Help.md`.

### Which thread a registered command runs on

This is not cosmetic — it is why some commands work while a modal dialog is blocking and others
do not.

| Registered `actWorkerThread` | Registered `actMainThread` (marshalled to the VCL thread) |
|---|---|
| `debug_run`, `debug_step`, `debug_run_to` | `tree_text` and every other `ide_*` / `debug_*` command |

The worker-thread three wait for the debugger to stop the process, and synchronise each step onto
the main thread themselves. Which built-ins run on the worker thread (`dialogs`, `screenshot`, and
`keys` after its start) is documented with the server.

---

## 3. Error codes

Every failure returns `{ id, ok:false, error:{ code, message } }` with a stable `code`. The
envelope and built-in codes (`Unauthorised`, `UnknownCmd`, `RequestTooLong`, `Internal`, `NoProp`,
`Ambiguous`, `NotObject`, `NilObject`, `NotScalar`, `ReadOnlyProp`, the `click` / `keys` / dataset
codes and the rest) are listed in `D:\gllAutomationServer\Help.md`. The codes the 22 registered
commands raise, from their `EAutoError.CreateCode` / `CreateCodeData` sites:

| Code | Raised when |
|---|---|
| `BadRequest` | a registered command's argument is missing or of the wrong JSON type (`tree_text` with no `name`, or a `name` that is not a control; `debug_memory` with an unparseable `address`; an empty menu path); or a `mode` outside its vocabulary |
| `NoForm` / `NoComp` / `Ambiguous` | `tree_text`'s target, from the server's `ResolveForm` / `ResolveComponent`, exactly as for a built-in |
| `NotVirtualTree` | `tree_text` on a control that is not a `TBaseVirtualTree` descendant (judged by class name) |
| `NoWindow` | `tree_text` on a tree with no window handle yet |
| `NotOnScreen` | `tree_text` on a tree whose window is not visible — a hidden pane, or a visible tree inside a hidden parent. Its text only exists while it paints, so show the window first |
| `NoGetText` | `tree_text` on a tree with no `OnGetText` event, or none assigned — nothing supplies its text |
| `SignatureMismatch` | `tree_text` on a tree whose `OnGetText` type, read from RTTI, is not the shape the reader stands in for. The message quotes the actual declaration. Nothing was hooked |
| `NoService` | the IDE does not offer the ToolsAPI service a command needs (module, debugger, main menu) |
| `Modified` | `ide_quit` in `refuse` mode with something unsaved; `error.data` lists it as `ide_modified` does |
| `Untitled` | `ide_quit` in `save` mode with a file that has never been saved - saving it would open Save As; `error.data` lists them |
| `SaveFailed` / `CloseFailed` | `ide_quit` - the IDE declined to save or close a module |
| `NoMenuItem` | a menu path step matches nothing; `error.data` lists what is there |
| `AmbiguousMenuItem` | a caption beginning matches several items; `error.data` lists them |
| `NotClickable` | `ide_menu_click` on a separator, a submenu, or an item that is disabled or hidden or sits in one that is |
| `NoProcess` | a debugger command with nothing being debugged, or with no CURRENT process because another project is active |
| `NotStopped` | a debugger command that needs the process (or thread) stopped |
| `NoThread` | no such thread in the current process |
| `NoProject` | `debug_attach` with no project open - the debugger takes the platform from it, and without one the attach silently does nothing |
| `NoFile` / `NoEditor` | `debug_run_to` - the file could not be opened, or has no editor view offering Run to Cursor |
| `StackBusy` | `debug_stack` - the stack is temporarily unavailable; ask again shortly |
| `StackInaccessible` | `debug_stack` - the debugger cannot read this thread's stack |
| `Unsupported` | `debug_registers` / `debug_memory` on a 32-bit process in the 64-bit IDE |
| `NoAccess` | Windows would not say whether the debugged process is 64-bit |
| `Unreadable` | `debug_memory` could not read even the first byte |
| `EvalError` / `EvalDeferred` / `EvalBusy` | `debug_eval` - the evaluator's error text; it had to call into the process and has no result yet; it is busy |
| `BreakpointFailed` / `NoBreakpoint` | the debugger set no breakpoint; there is none on that line to delete |

Any other exception escaping a registered handler comes back as the server's `Internal`. A
connection closed with no reply is a genuine fault and worth reporting; the one deliberate close is
`RequestTooLong`, which answers first.

---

## 4. Scope of this package

**There is no upstream.** Since 2026-10-13 this package lives in the `gllAutomationServer` repository
(`https://github.com/ijbranch/gllAutomationServer`, folder `gllIdeAutomation\`), beside the server it
requires; its earlier history came with it, and its old tags are `gllIdeAutomation-v1.0.0`,
`-v1.0.1` and `-v1.2.0`. This is a GITLAK original, not a fork of a third-party project, so there is
nothing to merge from and no divergence to justify.

- **The server is not part of this package.** It is the shared runtime package
  `gllAutomationServer` (`D:\gllAutomationServer`,
  [GitHub](https://github.com/ijbranch/gllAutomationServer)), which this package `requires`, so the
  IDE loads the same server unit as every other host. Until 2026-10-13 this package's own repository carried its
  own copy; that copy is gone, and with it any need to keep two copies in step.
- **What is here is what only the IDE needs:** the gate (`gllIdeAutomation.Starter`), `tree_text`
  (the reader in `gllIdeAutomation.TreeText`, the `CmdTreeText` handler in
  `gllIdeAutomation.IdeCommands`) and the 21 ToolsAPI commands (`gllIdeAutomation.IdeCommands`). All 22 reach the server only through
  `TAutomationServer.RegisterCommand`, and `tree_text` resolves its target through the server's
  public `ResolveForm` / `ResolveComponent`, so its wire behaviour is that of a built-in.
- **`tree_text` lives here** because no application we ship carries a virtual tree. The technique
  is Thomas Mueller's, from `TREETEXT` in GxInspect, the GExperts inspection server —
  re-implemented here, not copied; the unit header says so.
- **The package requires `designide`** (2026-09-29), for `ToolsAPI`; a design-only package running
  in the IDE loses nothing by it. The server package does not use the ToolsAPI.
- **The IDE's idle timers are left alone:** the starter passes `ADisableIdleTimers = False` to
  `Start`.

Verified live 2026-10-13: the IDE loaded the shared package (`ping` answered `package: "1.0.0.0"`,
`server: "0.11"`) and `tree_text` answered as a registered command.

The version comes from the `.dproj`'s `VerInfo_*` (since 2026-10-06; it was a hand-maintained
`gllIdeAutomationVersion.rc` before). The build number auto-increments on every build, separately
for Win64 Release and Win64 Debug, and the BPL reports the number from before that build's bump.

---

## 5. Building

`gllIdeAutomation.dproj` is a package project and follows the estate package rules.

- **Build `gllAutomationServer` first, in all four modes.** This package `requires` it, so its
  `.dcp` must exist for the platform and configuration being built, and its BPL must be on `PATH`
  (the shared `Bpl\<Platform>` folder) for the IDE to load this one. After a change to the server,
  rebuild it and then this package.
- **Four modes.** Win32 + Win64 × Debug + Release. `<Platforms>` declares exactly `Win32=True`
  and `Win64=True`, and `TargetedPlatforms` is `3` to match. The package is only finished when
  all four are built.
- **Which platform you actually need to install** is the bitness of the IDE: `bin64\bds.exe`
  loads the **Win64** BPL, `bin\bds.exe` loads the **Win32** one. The wrong one silently never
  loads.
- **Output.** The `.dproj` carries the estate standard: one plain value per group, no `Condition`
  on the property (an in-IDE build re-save keeps only one value per property per group, and
  deleted the Release paths of the old `Condition=` form - see `CHANGELOG.md`, 2026-10-07):

  ```xml
  <!-- Base group -->
  <DCC_BplOutput>$(BDSCOMMONDIR)\Bpl\$(Platform)\$(Config)</DCC_BplOutput>
  <DCC_DcpOutput>$(BDSCOMMONDIR)\Dcp\$(Platform)\$(Config)</DCC_DcpOutput>
  <!-- Release config group -->
  <DCC_BplOutput>$(BDSCOMMONDIR)\Bpl\$(Platform)</DCC_BplOutput>
  <DCC_DcpOutput>$(BDSCOMMONDIR)\Dcp\$(Platform)</DCC_DcpOutput>
  ```

  Release stays in the shared platform folder because that folder is on `PATH` and is where
  dependent packages resolve their `requires`; only Debug is diverted, which is enough to stop a
  Debug build replacing the installed Release package.
- **DCUs are project-local and per-platform, per-config:** `DCC_DcuOutput` is
  `.\dcu\$(Platform)\$(Config)`. Do not flatten it — one folder shared by two architectures gives
  every consumer `F2048 Bad unit format`.
- `DCC_CBuilderOutput` is `None`. C++Builder is never in scope.
- The BPL name carries the compiler's version suffix through `{$LIBSUFFIX AUTO}` (`370` on 13
  Florence), matched by `<DllSuffix>$(Auto)</DllSuffix>` in the `.dproj`.

---

## 6. Troubleshooting

### Building fails with **two** `F2039 Could not create output file` errors

```
F2039 Could not create output file '...\Bpl\Win64\gllIdeAutomation370.bpl'
F2039 Could not create output file '...\Dcp\Win64\gllIdeAutomation.dcp'
```

An IDE with the package installed holds **both** outputs open. The count is the diagnostic: two
errors, no compilation errors, and the compiler reports its unit count normally. This is a file
lock, not a code fault, and it applies to MSBuild and `dcc64` exactly as it does to a build from
inside the IDE.

Untick the package in **Component > Install Packages**, build, re-tick; or build with `bds.exe`
closed.

**Never pass `clean` while the IDE holds it.** `CleanOutputs` deletes the `.dcp` *first* and only
then discovers it cannot delete the loaded `.bpl`, so a failed clean build leaves the DCP gone and
every consumer failing `E2202 Required package '<x>' not found` — and it cannot be regenerated
until the IDE closes, because the link step that writes the DCP is the one being blocked.

### The package is installed but the IDE never appears in the discovery directory

Work down this list; in practice it is always one of them.

1. **The gate was not set in the launching environment.** A process gets its environment at
   creation, so setting `GITLAK_IDE_AUTOMATION` *after* the IDE started does nothing. The gate is
   `Trim(value) = '1'` — not "set", not "true".
2. **Wrong bitness.** Win64 BPL for `bin64\bds.exe`, Win32 for `bin\bds.exe`.
3. **The package is registered under the wrong IDE key.** Design packages register per IDE
   bitness: `HKCU\…\BDS\37.0\Known Packages` is the 32-bit IDE's list, `Known Packages x64` the
   64-bit one. Install from `bin64\bds.exe`.
4. **The tick is cleared** in Component > Install Packages — the IDE loaded it, failed, and
   disabled it.
5. **It is not the process you think.** The discovery filename is the PID; check it against
   `Get-Process bds`.

### `Error Reading Form: Class TXxx not found`

Not this package's own failure mode, but the symptom of the mis-registration in point 3 above for
any design-time package. **Never click Ignore** — it drops the component and its property values
from the form, and saving writes the loss into the `.dfm`.

### It worked yesterday

- **A RAD Studio update.** The BPL is version-suffixed and registration is per-version. Rebuild
  and re-register.
- **The IDE is loading an older build.** Check rather than assume:

  ```powershell
  (Get-Item "$env:PUBLIC\Documents\Embarcadero\Studio\37.0\Bpl\Win64\gllIdeAutomation370.bpl").VersionInfo.FileVersion
  ```

  If that number has not moved since the last build of the same configuration, the build did not
  reach the BPL the IDE loads: every build advances it. Compare like with like - Release and Debug
  count separately.
- **The IDE was launched from somewhere that does not carry the variable** — a shortcut, a file
  association, another tool.

### A command returns `Unauthorised`

The token is per-session: it is a fresh `TGuid.NewGuid` every time the server starts, so a cached
one goes stale the moment the IDE restarts. Re-read the discovery file.

### The port is not 8730

Expected. The constructor scans upward from `AUTOMATION_PORT_BASE` (8730) for up to
`AUTOMATION_PORT_SPAN` (200) ports, so two gated IDEs get different ones. Always read `port` from
the discovery file. If all 200 fail, `Start` raises
`gllAutomationServer: no free loopback port in range` — and the starter swallows it, so the symptom
is simply no discovery file.

### `NoForm` / `NoComp` / `Ambiguous` / `NoProp`

- `NoForm` — send `tree` with no `form` to list what is actually open. Many IDE windows exist but
  are not visible until first used.
- `NoComp` — nothing of that name is reachable from that form. Send `tree` with the form name and
  `deep:true` to see what is, including frame and docked controls and the synthetic names of
  unnamed ones.
- `Ambiguous` — several components match the name; `error.data.candidates` lists a path to each.
  Send one of those paths instead.
- `NoProp` — the property is not published. This is the usual wall; see the next entry.

### `get` cannot read the debugger panes — use `tree_text`

**Local Variables, Watch, Call Stack and the Structure pane are `TVirtualStringTree`. Their cell
text is not a published property, and neither is the selection.** No amount of `get` will reach
it: a virtual tree holds no text at all, it asks its `OnGetText` handler for each cell as it
paints.

**`tree_text` reads it anyway**, by standing in front of that handler for one read: it walks the
tree a page at a time so every displayed row paints, records what the real handler answers, puts
the handler back and returns the tree to its scroll position. Measured 2026-09-25 against the
running IDE, the three panes are plain `TVirtualStringTree` - not IDE subclasses - each with
`OnGetText`:

| Pane | `form` | `name` |
|---|---|---|
| Local Variables | `LocalVarsWindow` | `LocalsTreeView` |
| Watch | `WatchWindow` | `WatchTree` |
| Call Stack | `CallStackWindow` | `CallStackTree` |

**Check that the debugger is actually paused before reading.** `get` on the `AppBuilder` form's
`Caption` shows the state, e.g. `… [Stopped]` or `… [Running]`. While the program runs, the Call
Stack holds only the IDE's "Process is not accessible" line, and Local Variables and Watch are
empty. `tree_text` reports that faithfully, so it looks like a failed read when it is not.

Three things it cannot do, by construction:

- **It reads displayed rows only.** A collapsed node's children are never painted, so expand the
  node first. `rootCount` is the tree's own count of top-level rows, and a read with fewer rows
  than that is reported `complete:false`.
- **The pane must be on screen** (`NotOnScreen` otherwise). Windows paints nothing into a hidden
  window. For a docked pane on a hidden tab, bring its tab forward.
- **It scrolls the pane visibly** while it reads. Harmless, but do not mistake it for the IDE
  misbehaving.

Before hooking anything it checks the event's signature against RTTI and refuses with
`SignatureMismatch` if the IDE's VirtualTrees ever changes it, because a mismatch would not be a
compile error but corrupted text or an access violation inside the IDE's paint. **That check has
already earned its keep:** the first live run, on 2026-09-25, refused all three panes, because the
64-bit Delphi 13 IDE declares the cell text `var CellText: WideString`, not `string` as current
VirtualTrees does. A `WideString` is a COM BSTR, and reading it as a reference-counted `string`
gets the length wrong and writes a reference count into memory that is not a string header. The
reader now takes either shape and installs the handler that matches what RTTI reports.

**This applies to every IDE, not only the 64-bit one.** Thomas Mueller, who fixed the same issue in
GxInspect (r5813, 2026-09-27), measured the 64-bit and 32-bit Delphi 13.2 IDEs and Delphi 2007. All
three declare `WideString`, because the IDE carries its own older copy of VirtualTrees
(`Idevirtualtrees` in `vclide<ver>.bpl`). He also showed that a mismatch is fatal, not cosmetic: a
`string` handler forced into the 64-bit IDE raised "Invalid pointer operation" from
`System.@UStrClr` and the IDE had to be killed.

The older way round still works and is kept as a fallback: the panes' popup menu items *are*
addressable components, so select a row with a real mouse click, fire Copy Value and read the
clipboard (`tools/read_pane.py`). The two panes do not share naming — Locals has `lvCopyValue` /
`lvCopyName`, Watch has `CopyWatchValue` / `CopyWatchName`. It needs screen coordinates, which is
exactly what `tree_text` avoids.

### Copy Value produces nothing

No row is selected. Firing the popup item acts on the current selection; an empty selection gives
an empty clipboard. Click the row first. `read_pane.py` primes the clipboard with a sentinel so
"nothing was copied" and "the value is genuinely empty" do not look identical.

### The `app_*` tools cannot see an add-in's frame

**Before protocol 0.11 they walked form ownership only**, so an add-in that parents a frame into
an IDE window without that window owning it was unreachable. Since 0.11 a component `name` also
reaches frame-owned and docked (parented-only) controls, and `tree` with `deep:true` lists them;
the forms themselves are still found through `Screen.Forms`.

To establish that an add-in BPL is loaded at all, **look at the process module list** — enumerate
the modules of the `bds.exe` process and look for the BPL by name. That is a fact about the
process, not about the VCL ownership graph, so it answers the question the automation server
cannot.

### The IDE hangs while a command runs

A command whose handler opens a modal dialog blocks until the dialog closes, because the reply
waits for the handler to return. Use `"mode":"message"` on `click` for button-class controls — it
posts `BM_CLICK` and replies immediately — then answer the dialog with `dialogs`.

### A click lands in the wrong place

Only relevant to `tools/click.py` and anything else synthesising real mouse input; the protocol
itself is coordinate-free. On a scaled display, screenshot pixels and cursor coordinates are
**different spaces**, and `SendInput` reports success either way, so a mis-scaled click fails
silently rather than erroring. Take coordinates from a fresh screenshot every time — row
positions shift when a node is expanded, and a stale coordinate reads a *different row* perfectly
happily.

`click.py` declares `PER_MONITOR_AWARE_V2` so both spaces are physical, and it refuses to click
if the cursor will not stay where it was put, so a human on the mouse does not receive the click.

---

## 7. Dependencies

Everything but `gllAutomationServer` ships with Delphi.

| `requires` | Needed for |
|---|---|
| `rtl` | — |
| `vcl` | `Vcl.Forms`, `Vcl.Controls`, `Vcl.Menus` — `tree_text`'s target and the `ide_menu*` commands |
| `designide` | `ToolsAPI` — the `ide_*` and `debug_*` commands in `gllIdeAutomation.IdeCommands` |
| `gllAutomationServer` | `TAutomationServer`, `EAutoError` — the server itself (`D:\gllAutomationServer`) |

`vclimg`, `dbrtl`, `IndySystem` and `IndyCore` are no longer required here: the server package
requires them (for `screenshot`, the dataset commands and the Indy loopback listener), and they
reach this package through it. `gllAutomationServer` is ours and must be built before this
package; everything else ships with Delphi.

---

## 8. Security

Loopback only (`127.0.0.1`), and every command must carry the per-session GUID token from
`C:\ProgramData\GITLAK\Automation\<pid>.json`. Another local process cannot drive the IDE without
reading that file. There is no remote surface.

**The token file's permissions are therefore the real control, and the default ACL does not
provide them.** `C:\ProgramData` grants `BUILTIN\Users` read, and that is inherited all the way
down, so a discovery directory created with an ordinary `CreateDirectory` hands the token to every
account on the machine. The server (in `gllAutomationServer`; here since 1.1.0) therefore
creates the directory with an explicit **protected** DACL — inheritance broken — naming only `SYSTEM`, `BUILTIN\Administrators` and the account the host
process runs as.

Two limits worth knowing. An **existing** directory is left exactly as it is: it is shared with the
rest of the GITLAK tooling and its permissions are the estate's to set, not the server's to
rewrite underneath whatever else is using it — so the hardening applies from first creation, and
after anyone deletes the folder. And if the restricted create fails the directory is still created
with the inherited ACL, because failing to advertise is worse; that fallback announces itself
through `OutputDebugString` rather than passing silently. To check an existing one:

```powershell
(Get-Acl 'C:\ProgramData\GITLAK\Automation').Access |
  Where-Object { $_.IdentityReference -like '*\Users' }
```

Anything returned there means every local user can read the session token.

That said, this is a development tool: anything that can click buttons and set properties in an
IDE deserves the suspicion you would apply to a debugger. It is off by default for that reason,
and the package is inert unless the gate is set — so leaving it installed costs nothing, and
whether to set the variable permanently is the decision to take deliberately.

The server starts only when a host explicitly opts in; that is the consumer's discipline, not
something the server package can enforce (see *Gating* in `D:\gllAutomationServer\Help.md`). In
the IDE the opt-in is `GITLAK_IDE_AUTOMATION=1`.
