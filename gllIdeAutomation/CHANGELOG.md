# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added
- (2026-10-30) **16 commands from GExperts' GxInspect: the form designer, modules and projects, IDE actions, disassembly** - `src\gllIdeAutomation.IdeCommands.pas`, `src\gllIdeAutomation.Rules.pas` (new), `gllIdeAutomation.dpk`, `gllIdeAutomation.dproj`, `..\Tests\TestGllIdeAutomationRules.pas` (new), `Help.md`, `Users Guide.md`.  Ian, 2026-10-30: add what GxInspect has and we lack, porting or reimplementing whichever is better per feature.  **Designer:** `ide_designer_show`, `ide_designer_screenshot` (rendered, not screen-copied, through the server's new `RenderControl`), `ide_designer_selection`, `ide_designer_select` (every name found before anything is selected), `ide_designer_deselect`, `ide_view_as_text`, `ide_view_as_form`.  **Modules and projects:** `ide_open_file` (refuses a unit whose `.dfm` is open as text, where the IDE raises `EModuleAbort` yet opens it), `ide_modules`, `ide_close_module` (refuse / save / discard, as `ide_quit`), `ide_save`, `ide_projects`, `ide_set_project`.  **Actions:** `ide_actions` (filtered by name, caption or category) and `ide_action` (brought up to date, refused when disabled, executed just after the answer; also finds the actions in the IDE's own data modules, which `INTAServices` does not list).  **Debugger:** `debug_disasm` through the CPU window's `TDisassemblerView` handlers, each checked by RTTI first; `debug_breakpoint_set` takes `group`, `doBreak`, `logMessage`, `evalExpression`, `logResult`, `enableGroup`, `disableGroup`, `handleExceptions`, `ignoreExceptions`, `stackFramesToLog` and `threadCondition`, and every breakpoint reports them with `curPassCount` and, while debugging, `validHere`.  **Ported** (svn r6031, `ide\GxInspect_Ide.pas`, credited in both unit headers): the disassembler, the event-shape check, the form-view swap, the two-pass form lookup, the keep-the-foreground open; **reimplemented**: the rest.  The pure parts (argument readers moved out of `IdeCommands`, file, action and name matching, the break-in and quit rules, `EventShape`) are in the new ToolsAPI-free `gllIdeAutomation.Rules`, which the server's suite compiles from source: 16 tests, mutation-proved with `test_mutate` (8 mutants, 8 killed).  What needs a live IDE is on the live-test list in the 2026-10-30 report; not yet run.
- (2026-10-13) **`keys` command: keyboard input through the host's own message loop** - `src\gllIdeAutomation.Server.pas`, `Help.md`, `README.md`, `Users Guide.md`, `docs\Users Guide.md`. Types `text`, then sends `keys` chords (`Ctrl+S`, `Tab Enter`, `Shift+F10`), to a windowed control, setting the modifier state per stroke and restoring it after; shortcuts, `KeyPreview`, dialog navigation and `OnKeyDown`/`OnKeyPress`/`OnKeyUp` fire as for a real keyboard, with no global input and no need for the host to be in the foreground. Runs on the worker thread and answers once delivered; a stroke that opens a modal window stops the sequence (`stoppedReason:"modal"`). New codes `BadKeys`, `Busy`, `NotTypable`, `Blocked`. Server version 0.10. Ported in the same change as GITLAKLib's `gllAutomationServer`; the bodies differ only by the documented list (no `DisableIdleTimers` call here; the step marker is registered as `gllIdeAutomation.KeyStep`). **Why:** shortcut-only commands and key-handler logic could not be driven at all; the idea came from reviewing Autopilot for Delphi (no code taken - its licence forbids it). Four modes build clean; exercised live on GITLAKLib's identical body, not yet inside the IDE.

### Removed
- (2026-10-13) **The vendored server copy: this package now `requires` the shared gllAutomationServer package** - `src\gllIdeAutomation.Server.pas` (deleted), `gllIdeAutomation.dpk`, `gllIdeAutomation.dproj`, `src\gllIdeAutomation.Starter.pas`, `src\gllIdeAutomation.IdeCommands.pas`, `src\gllIdeAutomation.TreeText.pas`, `README.md`, `Help.md`, `Users Guide.md`, `docs\HELP.md`, `docs\Users Guide.md`. The server unit moved out of GITLAKLib into its own runtime package, [gllAutomationServer](https://github.com/ijbranch/gllAutomationServer) (`D:\gllAutomationServer`), and this package uses it instead of carrying a renamed copy. `requires` is now `rtl`, `vcl`, `designide`, `gllAutomationServer`; `vclimg`, `dbrtl`, `IndySystem` and `IndyCore` come with the server package. What the copy used to change is now chosen by the host: `Starter` calls `TAutomationServer.Start( APP_NAME, False )` so the IDE's plug-in timers are left alone, and `tree_text` is registered by `IdeCommands` (`CmdTreeText`) on the new public `ResolveForm` / `ResolveComponent`, so its wire behaviour is unchanged. The server arrives at protocol 0.11 (component paths, synthetic and reachable names, dotted properties; see its `CHANGELOG.md`). Four modes build clean; verified live in the 64-bit IDE: `ping` reports `package` 1.0.0.0 and `server` 0.11, and `tree_text` answers as a registered command. **Why:** the two copies drifted 283 lines apart once and every change had to be made twice.
- (2026-10-08) **Unused `System.StrUtils`** - `gllIdeAutomation.IdeCommands.pas`. Left behind when its `IfThen` call became an `if` expression; the removal compiled with identical code bytes.

### Changed
- (2026-10-31) **Built against protocol 0.14 of the server, whose `close` is refused in the IDE** - `Help.md`, `gllIdeAutomation.dproj`.  The server package gained `gllAutomationServer.Client` and `close` ( see its CHANGELOG ); inside `bds.exe` `close` answers `HostedInIde`, so the IDE is still closed with `ide_quit`.  Rebuilt in all four modes; no source change here.
- (2026-10-13) **Proprietary and Delphi 13 only: the package is in-house** - `gllIdeAutomation.dpk`, `gllIdeAutomation.dproj`, `src\gllIdeAutomation.IdeCommands.pas`, `src\gllIdeAutomation.Starter.pas`, `src\gllIdeAutomation.TreeText.pas`, `LICENSE` (deleted; the repository root's `LICENSE` covers it), `README.md`, `Help.md`. Ian, 2026-10-13: "the two automation projects are now purely ours". The MIT headers become the GITLAK proprietary header (prepended to `Starter` and the `.dpk`, which had none), `LegalCopyright` follows, and the 10.3 Rio floor goes: the `{$LIBSUFFIX}` ladder is now plain `{$LIBSUFFIX AUTO}`, and the units' guards stop below `CompilerVersion 37.0` (Delphi 13). **Found while doing it:** a `CompilerVersion` test in a `.dpk` cannot work - the System unit is not loaded there, so the name is undeclared and every comparison on it is TRUE (a probe package printed `>= 37`, `>= 36` and `< 37` together). The old ladder only ever took its first branch, which happened to be the right one on 12 and 13; on an older IDE it would never have reached its own fallbacks. The floor is therefore enforced in the units, and the `.dpk` says why it has no guard.
- (2026-10-13) **Moved into the gllAutomationServer repository, folder `gllIdeAutomation\`, with its history** - `Help.md`, `CHANGELOG.md`, `README.md`, `docs\HELP.md`, `docs\Users Guide.md` (wording that meant "this repository" now says "this package's folder"). The package is unchanged - same name, same `.dpk`, same BPL name and output folder, so the installed IDE package needs no re-registration. Old tags are now `gllIdeAutomation-v1.0.0` / `-v1.0.1` / `-v1.2.0` in the new repository, and the links at the foot of this file point there. `ijbranch/gllIdeAutomation` is archived. **Why:** this package `requires` gllAutomationServer, and changes that cross the two belong in one commit.
- (2026-10-08) **D13 language features adopted** - `gllIdeAutomation.IdeCommands.pas`, `gllIdeAutomation.Server.pas`, `gllIdeAutomation.TreeText.pas`. 10 `not ( X in S )` / `not ( X is T )` rewritten as the D13 `not in` / `is not` operators (generated code byte-identical, verified per platform and configuration); 1 `IfThen(...)` call replaced by the `if ... then ... else` expression, which evaluates only the branch it picks.
- (2026-10-06) **The version now comes from the `.dproj` and the build number auto-increments; `gllIdeAutomationVersion.rc` and `tools/bump-build.py` are gone** - `gllIdeAutomation.dproj`, `gllIdeAutomation.dpk`, `gllIdeAutomationVersion.rc`, `tools/bump-build.py`, `.gitignore`, `src/gllIdeAutomation.Server.pas`, `README.md`, `Help.md`, `Users Guide.md`, `docs/HELP.md`, `docs/Users Guide.md`. Ian, 2026-10-06: build auto-increment on for all our libraries and packages, and for this package Delphi's own mechanism rather than an automated `.rc` bump. `VerInfo_IncludeVerInfo` is on with the same identity the `.rc` carried (1.2.0, GITLAK Software, the MIT copyright line); the `{$R ...Version.rc}` directive, its `RcCompile` item and `.res` reference are removed. The counters live in `Cfg_1_Win64` (Debug) and `Cfg_2_Win64` (Release), the only groups Delphi's `IncrementBuildNumber` writes to; the existing Win32 Debug group counts too. **Why the `.rc` existed, and why that no longer holds:** it avoided Delphi's per-configuration copies and their `ProductVersion`-lags-`FileVersion` drift; that drift is now corrected at commit by the estate's `sync_dproj_productversion.py` hook. Four modes build; the BPL reports `1.2.0.0` with the old company and copyright strings.

- (2026-09-29) **Every `FORK` fix is now in GITLAKLib too** - `src\gllIdeAutomation.Server.pas` (header only), `Help.md`. GITLAKLib's `gllAutomationServer` was rebuilt from this body the same day. The two now differ only by a list at the top of GITLAKLib's unit, which a comment-stripped diff confirms is complete. The header here no longer says the other fixes are still to go back. No code change here.

### Fixed

- (2026-10-30) **A failed start-up left no trace, and `debug_stack` answers were buried in parameter dumps** - `src\gllIdeAutomation.Starter.pas`, `src\gllIdeAutomation.Rules.pas`, `src\gllIdeAutomation.IdeCommands.pas`, `Help.md`.  The start-up swallowed every exception, so when registration failed (see the repo CHANGELOG) the server answered ping with no command and nothing said why; start-up and shut-down now write each step, and any failure with its exception, to `%LOCALAPPDATA%\GITLAK\gllIdeAutomation-startup.log` (still never shown to the user), plus `OutputDebugString`.  `debug_stack`'s frame headers carried every field of every object parameter (over 20 KB for one form `Self`, measured live); the header is now the routine's name (`BriefCallHeader`), and `params:true` returns the debugger's whole header.  Found while driving 0.13 in a live IDE (2026-10-30), where the rest of the checklist passed: open file, modules, designer show / select / selection / deselect / screenshot, View as Text and back, actions, projects, `validHere`, `IdeAsking`, `dialogs` on the exception box, `DebugBreak` stepping, `BreakInThread`, `debug_disasm`, the `Debugging` refusals, a condition-only edit keeping a breakpoint disabled, and `ide_quit terminate:true`.

- (2026-10-30) **Second pass after an independent review of the day's commands** - `src\gllIdeAutomation.IdeCommands.pas`, `src\gllIdeAutomation.Rules.pas`, `..\Tests\TestGllIdeAutomationRules.pas`, `Help.md`.  (a) **A bare file name took the first match:** with `Unit1.pas` open from two projects, `ide_close_module {file:"Unit1.pas", mode:"discard"}` discarded whichever came first.  `FindModule`, the designer and view lookups and `ide_set_project` now go through `FindFileMatch`, which refuses several matches with `Ambiguous` (listing them) and a relative path with `BadRequest`; `ide_open_file` takes a full path only.  (b) **`ide_close_module` on a project ignored its open units:** refuse mode went ahead into the IDE's "Save changes?" box.  The units that close with a project or group now count: refused and listed, saved, or each force-closed first; and closing a project while anything is being debugged is refused with `Debugging`.  (c) **`ide_quit terminate:true` ended the processes too late,** after closing modules, and without waiting.  It now runs on the worker thread, ends them first, waits up to 15 s for the debugger to let go (`TerminateFailed`, nothing closed, if it does not), then closes; an unknown mode is `BadRequest` before the debug check, where it read `Debugging`.  (d) **`debug_breakpoint_set` switched a disabled breakpoint back on** when only its condition changed; `Enabled` is now set only when `enabled` is passed, or on a new breakpoint.  (e) **`BreakInThread` refused a program thread stopped in `DebugBreak()`,** which sits in `DbgBreakPoint` as the break-in thread does; `IsBreakInStack` now looks for `DbgUiRemoteBreakin` among the top three frames (red first: the old rule failed `IsBreakInStack_DebugBreakIsTheProgramsOwn`).  (f) **`debug_disasm` matched the IDE's `TCPUSourcePos` by name alone;** its size is now read from RTTI and must be over 8 bytes (a smaller record travels in a register in Win64) and no larger than ours, or source lines are left out with a note.  (a) and (e) are tested in the new rules: 5 tests, 4 mutants, 4 killed; (b), (c), (d) and (f) need a live IDE and are on the live-test list.
- (2026-10-30) **A step or run issued while the IDE was asking something did nothing, and answered `stopped:false` ten seconds later** - `src\gllIdeAutomation.IdeCommands.pas`.  The debugger's exception notification leaves the process reading as stopped, so `debug_step`, `debug_run` and `debug_run_to` went ahead, waited out their timeout, and the process ran on once the box was answered.  They now refuse with `IdeAsking`, naming the prompt (a modal VCL form, or a Win32 dialog of the main thread), and point to `dialogs`.  Needs a live IDE to prove; on the live-test list.  Found by the 2026-10-30 GxInspect traps review.
- (2026-10-30) **`debug_step` after `debug_pause` stepped the debugger's own break-in thread, so the process ran on** - `src\gllIdeAutomation.IdeCommands.pas`, `src\gllIdeAutomation.Rules.pas`, `Help.md`.  After a pause the current thread is the one Windows creates to break in (`ntdll.DbgUiRemoteBreakin`); stepping it lets the process go and the step answers `stopped:false`.  A step now refuses with `BreakInThread` when the current thread's top frame is `DbgUiRemoteBreakin` or `DbgBreakPoint`, and says to `debug_set_thread` first.  The frame rule is `IsBreakInFrame`, tested and mutation-proved; the refusal itself is on the live-test list.
- (2026-10-30) **`ide_quit` closed into the IDE's "end the debug session?" prompt, which nobody would answer** - `src\gllIdeAutomation.IdeCommands.pas`, `src\gllIdeAutomation.Rules.pas`, `Help.md`.  No mode looked at the debugger.  Every mode but `ask` now refuses with `Debugging` while a process is being debugged, unless the request says `"terminate":true`, which ends each process first.  The rule is `DebugSessionBlocksQuit`, tested and mutation-proved; whether Delphi 13 still asks is on the live-test list.
- (2026-10-30) **A breakpoint on a line with no code was reported as a plain enabled breakpoint** - `src\gllIdeAutomation.IdeCommands.pas`.  The debugger rejects one only once the process runs, so a script waited for a stop that could not come.  `debug_breakpoint_set` and `debug_breakpoints` now report `validHere` while a process is being debugged, and `debug_breakpoint_set` adds a `note` saying whether the line's code is known.  `debug_breakpoint_set` also reads and checks every argument BEFORE it creates anything, where a bad `passCount` used to leave a new, half-set breakpoint behind.
- (2026-10-30) **Answers leaked when the IDE raised half-way through building them** - `src\gllIdeAutomation.IdeCommands.pas`.  `debug_stack` (a frame read), `debug_breakpoints`, `debug_threads` and `ide_menu` (filling a submenu clicks it, which runs the IDE's code) left their half-built JSON behind when a call raised; each now frees it on the way out, as the other commands already did.
- (2026-10-30) **An argument of the wrong JSON type could be converted instead of refused** - `src\gllIdeAutomation.Rules.pas`, `src\gllIdeAutomation.IdeCommands.pas`.  The argument readers relied on `TryGetValue<T>`, whose conversions between JSON types are the RTL's, not this package's contract; they now test the JSON type and answer `BadRequest`, as their documentation always said.  Moved into `gllIdeAutomation.Rules` with tests, which also pin the default-kept rule that once made every new breakpoint come out disabled.
- (2026-10-07) **An in-IDE build re-saved the package `.dproj` without its Release output paths** —
  `gllIdeAutomation.dproj`. The output standard was two `Condition`-ed `DCC_BplOutput` / `DCC_DcpOutput` lines in the
  Base group, and the IDE keeps one value per property per group when it re-saves the project on a build, so it wrote
  back only the active config's: a committed re-save sent Release builds to the root `Bpl` / `Dcp` folders. Now one
  plain value per group, the form the IDE writes itself: Base `$(BDSCOMMONDIR)\Bpl\$(Platform)\$(Config)` (and `Dcp`),
  overridden in the Release config group by `$(BDSCOMMONDIR)\Bpl\$(Platform)`. Same output; built in all four modes
  with the `dcc` `-LE`/`-LN` paths checked per mode. **Added `DllSuffix`** to `gllIdeAutomation.dproj`, matching the
  `.dpk`'s `{$LIBSUFFIX}`: the IDE's reinstall after an in-IDE build of an installed package takes the file name from
  `DllSuffix`, so without it the build ended in `[Fatal Error] Can't load package` (found in gllDelphiRefactoringLight
  the same day).

## [1.2.0] - 2026-09-29

> Wire protocol `0.9`, tagged `v1.2.0`. It contains everything since 1.0.1: the entries in this section and the
> `[In-Service]` record below, which covers the continuously deployed builds in between.
> **There is no 1.1.0 release.** The version resource read 1.1.0 from `fc8da69` (2026-09-21) while this work
> was in progress, and was never tagged; tagging it now would give that number to a build no 1.1.0 binary
> ever was. A BPL reporting 1.1.0.x is an untagged in-progress build.

### Added

- (2026-09-29) **Release 1.2.0** - `gllIdeAutomationVersion.rc`, `README.md`, `CHANGELOG.md`. The version resource moves to 1.2.0.0 and the commit is tagged `v1.2.0`.
- (2026-09-29) **ToolsAPI commands: close the IDE without a prompt, walk and click its main menu, and drive its
  own debugger** — `src\gllIdeAutomation.IdeCommands.pas` (new),
  `src\gllIdeAutomation.Server.pas`, `src\gllIdeAutomation.Starter.pas`, `gllIdeAutomation.dpk`,
  `gllIdeAutomation.dproj`, `Help.md`, `README.md`, `Users Guide.md`. 21 commands:
  `ide_modified`, `ide_quit` (`refuse`/`save`/`discard`/`ask`), `ide_menu`, `ide_menu_click`, and
  `debug_state`, `debug_attach`, `debug_detach`, `debug_pause`, `debug_run`, `debug_step`,
  `debug_run_to`, `debug_terminate`, `debug_threads`, `debug_set_thread`, `debug_stack`,
  `debug_registers`, `debug_memory`, `debug_eval`, `debug_breakpoints`, `debug_breakpoint_set`,
  `debug_breakpoint_delete`. **Why:** the package could only reach what the VCL shows. Closing the IDE
  from a script could stall on the "save changes?" API message box, which blocks every Release package
  build that needs the IDE closed. Menu items with no action behind them were out of reach, and the
  IDE's own debugger (its evaluator, its view of the stack) could only be read off the panes.
  Chosen after reading GxInspect's README (Thomas Mueller, GExperts), whose measured findings are cited
  at each command. The code was written here against `ToolsAPI.pas`, not taken from GxInspect, which is MPL.
  `debug_run`/`debug_step`/`debug_run_to` run on the worker thread and wait for a debugger notifier
  to count the next stop, because the IDE processes debug events on the main thread.
  **Built in four modes with zero hints. Verified live in the 64-bit IDE against a scratch Win64
  program:**
  - Stepping: over 17→18→19, into `Inner` (line 10), out back to 19, each answered in about 110 ms
    with the new location.
  - `debug_eval`: `AValue` = 1, `iTotal` = 12 after `run_to` line 20, and an unknown identifier
    returned as `EvalError` with the evaluator's text.
  - `debug_stack` matched the Call Stack pane frame for frame. `debug_registers` gave RIP and RSP, and
    `debug_memory` read 16 bytes at RSP.
  - `debug_run` with `wait` stopped at a new breakpoint. `debug_attach` with `pause` stopped an
    externally started process, and `debug_detach` left it running.
  - `ide_menu` reported an ambiguous path with its four candidates. File, New grew from 4 to 21 items
    once filled.
  - `ide_quit`: `refuse` and `save` refused, correctly, with an unsaved new unit open. `discard` closed
    the IDE with no prompt and left the project's `.dpr` byte-identical; `refuse` closed a clean IDE.
  - `save`: with the `.dpr` edited in the IDE's buffer, the edit reached the disk and the IDE closed with
    no prompt. `ask`: the IDE showed its own "Confirm" prompt, a VCL `TMessageForm` in Delphi 13, not the
    plain API box GxInspect saw in older IDEs. `dialogs` answered it "No", the IDE exited, and the edit was
    not saved.

- (2026-09-25) **`tree_text` reads the debugger panes: Local Variables, Watch and Call Stack** —
  `src\gllIdeAutomation.TreeText.pas`, `src\gllIdeAutomation.Server.pas`, `gllIdeAutomation.dpk`,
  `gllIdeAutomation.dproj`, `Help.md`, `README.md`, `Users Guide.md`. `get` could never reach them:
  a `TVirtualStringTree` holds no text and asks its `OnGetText` handler for each cell as it paints,
  so the only route was `tools\read_pane.py`, one row per real mouse click at screen coordinates.
  `tree_text` stands in front of `OnGetText` for one read, walks the tree a page at a time so every
  displayed row paints, records what the real handler answers, then restores the handler and the
  scroll position. It returns `{ level, cells }` per row, the header captions, the tree's own
  `rootCount`, and `complete` with a note whenever that is false. Before hooking, it checks the
  event's signature against RTTI and refuses with `SignatureMismatch` rather than risk an access
  violation inside the IDE's paint. That check caught a real mismatch on the first live run: the 64-bit
  IDE's VirtualTrees passes the cell text as `var WideString`, not `var string`, so the reader now
  installs whichever of the two handler shapes RTTI reports. Five new error codes: `NotVirtualTree`, `NoWindow`,
  `NotOnScreen`, `NoGetText`, `SignatureMismatch`. Measured against the running IDE first: all
  three panes are plain `TVirtualStringTree` with `OnGetText`, not IDE subclasses that could supply
  text some other way. **The technique is Thomas Mueller's**, from `TREETEXT` in GxInspect, the
  GExperts inspection server; this is a re-implementation, credited in the unit header. Fork-only:
  nothing goes back to GITLAKLib, whose applications carry no virtual tree. **Built in four modes
  with zero hints. Verified live in the 64-bit IDE:** all three panes hooked and restored with the
  IDE responsive throughout. It read header captions (`Name`/`Value`, `Watch Name`/`Value`) and
  real cell text (the Call Stack's "Process is not accessible", 23 of 23 rows in 17 ms), and
  reported empty panes as `complete` with no rows. **Then, with the debugger paused at a
  breakpoint in `TMainForm.FormShow`, every row matched what the IDE displayed:** Call Stack
  22 of 22 frames in 721 ms, more than fit on screen, so the page walk was exercised. Local
  Variables 4 of 4 (`Self`, `Sender`, `E`, `__frame`) in 124 ms. Watch empty, as it was. Each read
  was `complete`, with no notes. **With `Self` expanded, nesting matched too:** 39 rows (4 at level
  0, 35 at level 1: `TCustomForm` … `sJobNumber`) in 1,057 ms, with levels read through
  `GetNodeLevel` via RTTI. Names the pane truncates (`TCustomF`, `FShuttingI`) come back whole,
  because the text comes from the IDE's handler, not from the pixels.

- (2026-09-21) **`ping`/`info` reports `package`, this package's OWN version** —
  `src\gllIdeAutomation.Server.pas`, `Help.md`. `version` has always been `ParamStr( 0 )`'s, which
  inside the IDE is `bds.exe`'s — measured on the live IDE, `37.0.60952.8797`. So the single-source
  version in `gllIdeAutomationVersion.rc`, and the whole `VerInfo_IncludeVerInfo=false` apparatus
  that exists to keep it single, could not be read at run time at all: there was no way to tell
  which build of `gllIdeAutomation` an IDE had loaded. `GetPackageFileVersion` reads the version
  resource of `HInstance`, which in a package is the BPL itself. Verified live: `"package":"1.1.0.0"`
  alongside `"version":"37.0.60952.8797"`. **Carry back to GITLAKLib.**
- (2026-09-21) **Stale discovery files are swept at startup** —
  `src\gllIdeAutomation.Server.pas`, `Help.md`. `DeleteDiscovery` runs only on an orderly shutdown,
  so a host that was killed or crashed left its `<pid>.json` advertisement behind for ever.
  Consumers take the **first** file whose `app` matches — `tools/read_pane.py` does exactly that —
  so a single corpse is enough to make a running IDE look unreachable. `SweepStaleDiscovery` now
  deletes any `<pid>.json` whose process is gone; a PID that has since been reused reads as alive
  and is kept, which errs towards keeping a stale file rather than deleting a live one.
  Verified twice against a live IDE, once with a planted `999123.json` and once with a genuine
  leftover from a previous run. **Carry back to GITLAKLib.**
- (2026-09-21) **A request-line size limit, and the `RequestTooLong` error code** —
  `src\gllIdeAutomation.Server.pas`, `Help.md`. Indy's default `MaxLineAction` is `maSplit`, which
  silently cuts an over-long request in two: the first half fails to parse as JSON and the second
  half is then dispatched **as if it were a separate request**. `MAX_REQUEST_BYTES` (1 MB) plus
  `maException` makes that a diagnosable failure instead. The reply is written before the
  connection is dropped, because the remainder of the line is still buffered and anything read
  from it would be a fragment masquerading as the next request. Verified with a 2 MB line.
  **Carry back to GITLAKLib.**

- (2026-09-18) **`Help.md` and `Users Guide.md`, to the estate documentation standard**.
  `Help.md` carries both flavours: the Pascal surface is tiny (`TAutomationServer.Start` /
  `Stop` / `IsRunning` / `Port`), but the API people actually write against is the **wire
  protocol** — 13 commands, a fixed argument vocabulary and 23 stable error codes — which is a
  lookup table by any measure, plus failures by symptom since the package is consumed as-is.
  `Users Guide.md` is task-ordered: start the gated IDE, connect, read a form, drive a control.
  **The two structural limits are documented with their mechanism**, not just asserted: `get`
  reads published properties through RTTI and `TVirtualStringTree` publishes neither cell text
  nor selection, so debugger-pane *contents* are unreachable; and `AutoCmdTree` enumerates forms
  then each form's **owned** components one level deep, so an add-in frame is out of reach — for
  which the process module list is the way to prove a BPL loaded.
  §3 records the real divergence here: `src\gllIdeAutomation.Server.pas` is **vendored** from
  GITLAKLib's `gllAutomationServer` and deliberately renamed, because a Delphi unit may exist in
  only one loaded package — and nothing keeps the two copies in step.

### Fixed

- (2026-09-29) **`tree_text` without `max` read ONE row, not 2,000** — `src\gllIdeAutomation.Server.pas`.
  `TJSONValue.TryGetValue<T>` sets its out parameter to `Default( T )` when the key is MISSING
  (`System.JSON.pas`: `if not Result then AValue := Default(T)`). So the pattern "assign the
  default, then TryGetValue" silently replaced it with 0, and the reader clamped that to 1. The MCP
  tool always sends `max`, which is why nobody saw it. Found while building the ToolsAPI commands,
  where the same pattern made every new breakpoint come out disabled. They read optional arguments
  through `OptString`/`OptInteger`/`OptBoolean`, which keep the default and reject a wrongly typed
  value. GITLAKLib's `gllAutomationServer` was checked the same day and has no `TryGetValue` call, so
  the defect was fork-only.

- (2026-09-21) **The vendored body was 283 lines and one wire version behind GITLAKLib, with two live bugs;
  re-synced from `gllAutomationServer` 0.8** — `src\gllIdeAutomation.Server.pas`.
  The unit header asserted the body was "unchanged - only this header, the unit name and one
  exception message differ". It was not: this copy sat at `SERVER_VERSION` **0.7** against
  upstream's **0.8**, 1425 lines against 1709. Nothing keeps the two in step and nothing had.
  The two that were **defects, not missing features**:
  - **The port-scan `except` was bare here.** Upstream narrowed it to `on EIdException do ;` so
    that a genuine fault — an access violation, a bad configuration — is no longer disguised as a
    busy port and retried silently against 200 addresses, leaving only the misleading
    `no free loopback port in range`. That narrowing had never been carried across.
  - **A `dialogs` click could not dismiss a styled button, and reported success anyway.** A
    custom-drawn control keeps a window class containing `button`, so the search finds it, but its
    window procedure does not implement `BM_CLICK` — the send succeeds while nothing happens.
    Upstream falls back to `WM_LBUTTONDOWN`/`WM_LBUTTONUP` at the client-rect centre, then polls
    `IsWindow` for up to `DISMISS_WAIT_MS` and reports `dismissed`. **This one matters most
    precisely here**, because the host is `bds.exe`, which is full of styled dialogs.
  Also brought across: `click` `count` / `clicksDispatched` / `stoppedReason`, `set` `previous` /
  `changed`, and `NoProp` carrying the object's property surface in `error.data`. All three
  verified against the live IDE — `previous:"Delphi 13 (64-bit)"`, and a `NoProp` reply listing 59
  properties with `total` / `truncated`.
  The header now says what actually diverges, and every fork-only change is marked `FORK` in the
  source so the next re-sync can find them. `Help.md` §4 and `README.md`'s Provenance section
  repeated the old "unchanged body" claim — §4 asserted it in the very words the unit header now
  forbids, and README said driving the IDE "turned out to need no changes at all" — so both were
  rewritten to describe the divergence and point at the `FORK` markers. The re-sync itself is a
  separate commit, deliberately, so a future merge can diff against exactly the upstream state.
- (2026-09-21) **A wrongly typed envelope field dropped the connection with no reply** —
  `src\gllIdeAutomation.Server.pas`, `Help.md`. `GetValue<T>` routes to `TJSONValue.AsType<T>`,
  which **raises** when a field is present but of the wrong type — `{"id":"abc"}` was enough. Both
  envelope reads sat outside `ExecuteCommand`'s own `try`, so the raise escaped with the response
  object already allocated (leaking it), was re-raised on the Indy worker by `TThread.Synchronize`,
  passed the `try..finally` in `HandleLine`, and reached Indy, which closed the socket. The caller
  saw a dropped connection rather than an error, which reads as the server having crashed.
  `DisableIdleTimers`, being inside the marshalled block but outside any handler, had the same
  reach. Now: `TryGetValue` for the envelope, a broad-but-**reported** handler around the
  marshalled call, and every reply carries the `id`. Verified live — four previously fatal
  requests (`id` a string, `cmd` an object, `token` a number, a bad token) all now answer, and the
  probe reports **0 dropped connections**. **Carry back to GITLAKLib.**
- (2026-09-21) **The discovery directory is created with a restricted DACL** —
  `src\gllIdeAutomation.Server.pas`, `Help.md`. The discovery file holds the session token, which
  is the only thing between a local user and a server that can drive the UI and write datasets —
  and the code asserted nothing about its permissions. Measured: `C:\ProgramData` grants
  `BUILTIN\Users` `ReadAndExecute`, inherited by `C:\ProgramData\GITLAK`, so a directory created
  with `TDirectory.CreateDirectory` hands the token to every account on the machine. (The live
  folder on this machine happened to have had its inheritance broken **out of band** — nothing in
  this repository did that, and deleting the folder would have lost it.) `EnsureDiscoveryDir` now
  creates the leaf with a protected DACL naming only `SYSTEM`, `BUILTIN\Administrators` and the
  host's own account. An **existing** directory is deliberately left alone — it is shared with the
  rest of the GITLAK tooling — and a failed hardening still creates the directory but says so
  through `OutputDebugString` instead of passing silently. The SDDL was verified to produce
  exactly that ACL, with the current user still able to write. **Carry back to GITLAKLib.**
- (2026-09-21) **The screenshot path assumed `%USERPROFILE%\Desktop`** —
  `src\gllIdeAutomation.Server.pas`. The Desktop is routinely redirected (OneDrive does it by
  default), and the failure was not a miss but something worse: `CaptureRect` calls
  `ForceDirectories`, so the old path would **create** a second, empty `%USERPROFILE%\Desktop` and
  drop the PNG into a folder the user never opens, while reporting success. Now resolved through
  `SHGetKnownFolderPath( FOLDERID_Desktop )`, falling back to the old path only if that fails.
  `GetTickCount64` replaces `GetTickCount` in the filename, whose 32-bit counter wraps every 49
  days and is the only thing keeping the names apart. Not reproducible on this machine — the
  Desktop here is not redirected — so this is a latent fault fixed on inspection, not a measured
  one. **Carry back to GITLAKLib.**
- (2026-09-21) **`tree` and `dialogs` leaked their result on an error path** —
  `src\gllIdeAutomation.Server.pas`. Both built a `TJSONArray` that nothing owned yet and filled it
  before parenting it, so an exception part-way through — `CompToJSON` reads live published
  properties, and a getter can raise — abandoned the array, while the caller never received the
  object either because the assignment to `Result` had not happened. Both now create and parent
  first, under `try..except oRes.Free; raise;`. Bounded, but this runs inside an IDE that stays
  open for days. **Carry back to GITLAKLib.**
- (2026-09-21) **`DisableIdleTimers` is no longer called in this host** —
  `src\gllIdeAutomation.Server.pas`. Upstream runs it before every VCL command because it drives
  an **application** that may log itself out mid-test. `bds.exe` has no such timeout, so the only
  thing the sweep could achieve here was to reach into a third-party IDE plug-in, set an `Enabled`
  it does not own to `False`, and never put it back — a permanent, unannounced change to the
  user's IDE, made by a tool whose entire job is to observe it. The routine is retained, and
  documented as retained, so the two copies still read alike. **This one is FORK-ONLY — do not
  carry it back**, since it is correct upstream.
- (2026-09-21) **A bare `CR` inside `CHANGELOG.md` swallowed a heading**. `### Fixed` and the
  bullet after it were joined by a lone `\r` rather than a `CRLF`, so the whole 2026-08-26
  C++Builder paragraph rendered as one `<h3>`. A repository-wide scan found this to be the only
  such character in any tracked `.md`, `.pas`, `.py`, `.ps1`, `.rc` or project file.
  **This file's line endings are now uniform, and that is most of this commit's `CHANGELOG.md`
  diff.** It was the one tracked file whose *stored* blob carried literal `CRLF` — 188 of them
  against 37 bare `LF`, a mix, which is how a lone `CR` survived unnoticed. Every other file is
  stored as `LF` and converted on checkout by `core.autocrlf=true`. Normalising costs ~180 lines
  of whitespace-only churn once and stops the file being a special case; it is recorded here so
  nobody mistakes it for lost content.
- (2026-09-18) **`README.md` claimed `Screen.CustomForms`; the code uses `Screen.Forms`** (
  corrected and actually fixed 2026-09-21) — `README.md`, `Help.md`, `docs/Users Guide.md`.
  `Screen.Forms` is a strict **subset** of `Screen.CustomForms`, so the documents claimed a
  broader reach than the code has. Now corrected at all five sites, including `Help.md`'s
  `requires` table, which contradicted `Help.md`'s own §2 two hundred lines earlier, and
  `docs/Users Guide.md`, which additionally said the walk is over `TControl`/`TWinControl` when
  `CompToJSON` takes a `TComponent`.
  **Two errors in the original entry, both corrected here:** it named the `Starter.pas` docstring
  as a second offender — that unit contains no occurrence of `CustomForms` and never did — and it
  said "all four enumeration sites" when there are **three** `Screen.FormCount` loops
  (`AutoCmdTree` twice over, `AutoResolveForm`, `DisableIdleTimers`); the fourth `Screen.`
  reference is `Screen.ActiveForm`, which enumerates nothing.
- (2026-09-18) **`docs/Users Guide.md` listed a `dataset_op` value that does not exist** (
  **actually fixed 2026-09-21**). Its table gave "insert / append / edit / post / cancel /
  refresh / **navigate**", and the Server unit header used the same shorthand. `AutoCmdDatasetOp`
  accepts `insert`, `append`, `edit`, `post`, `cancel`, `refresh`, `first`, `last`, `next`,
  `prior`; `"op":"navigate"` returns `BadOp`. The 2026-09-18 entry recorded this under **Fixed**
  while leaving both the table row and the unit header untouched — they are corrected now.
- (2026-09-18) **The coordinate tables in `README.md` and `docs/` quote 150% scaling** (superseded
  2026-09-21). The original entry called them stale because the scaling changed on 2026-09-14; it
  went **back to 150% on 2026-09-20**, so the figures happen to be correct again. Neither fact is
  worth relying on. The root documents deliberately give the coordinate guidance with no scale
  factor or pixel figures at all, because a recorded coordinate must be re-measured, never
  rescaled — and `tools/click.py` now says so in its own docstring.
- (2026-09-18) **A pre-standard pair survives at `docs/HELP.md` and `docs/Users Guide.md`** —
  wrong location and wrong capitalisation. Left in place; the root `Help.md` says they predate
  the standard, and as of 2026-09-21 `README.md` says so too instead of presenting them as the
  current documentation under a second, anchor-colliding `## Documentation` heading. Whether to
  delete them or reduce them to a redirect is a decision, not a tidy-up.

- (2026-09-17) **Two `except` blocks no longer hide what went wrong, matching the fix already made in
  `gllAutomationServer`** - `src\gllIdeAutomation.Server.pas`. This unit is a sibling of
  GITLAKLib's `gllAutomationServer` and carried the identical code; a Pascal Analyzer sweep found both.
  - **The stopper thread's bare `except` was LOAD BEARING**, so it stays broad. `Stop` waits on
    `while not LFinished do CheckSynchronize( 50 )` and `LFinished := True` sat AFTER the handler, so
    anything escaping would have left that loop spinning for ever. The assignment moves into a
    `finally` and the failure is captured and reported after the join via `OutputDebugString` - not a
    logger, because this is hosted inside `bds.exe` at shutdown, where there is none to reach.
  - **`DeleteDiscovery` narrowed to `EInOutError`** and given the comment it never had; `TFile.Delete`
    raises exactly that on a locked, ACL-denied or already-gone file.
  - Built clean in all four modes, with the DCU timestamps checked in each.

- (2026-09-10) `TargetedPlatforms` brought into line with the `<Platforms>` block in 1 `.dproj`
  The earlier platform sweep removed the non-Windows `<Platform>` entries but left the
  `<TargetedPlatforms>` bitmask untouched, so projects still advertised targets they no
  longer declared — values such as `1048579` and `135171` encode Android/Linux/iOS, and
  several Win32+Win64 projects still read `2` (Win64 only) or `1` (Win32 only).
  Now `3` for Win32+Win64, `2` where only Win64 is declared.
  **Why:** the mask is what the IDE reads for the Project Manager's platform list, so a
  stale one puts dead platforms back in front of the reader.

### Changed

- (2026-09-29) **Wire protocol 0.9: commands can be registered from outside the server; the package now requires
  `designide`** — `src\gllIdeAutomation.Server.pas`, `gllIdeAutomation.dpk`,
  `gllIdeAutomation.dproj`. `TAutomationServer.RegisterCommand`/`UnregisterCommand` add a command
  on the main or the worker thread, and `EAutoError` moved to the interface so such a command fails
  with a code of its own. Both are marked `FORK` and are generic, so both belong upstream in
  GITLAKLib. `designide` reverses the earlier "deliberately not" choice, which was made while
  nothing needed the ToolsAPI.

- (2026-09-27) **The `tree_text` `WideString` finding is IDE-wide, not 64-bit-only — confirmed upstream**
  — `CHANGELOG.md`, `Help.md`, `src\gllIdeAutomation.TreeText.pas` (a doc comment only). No code change. Thomas Mueller closed our GExperts
  `TREETEXT` report as fixed in **GxInspect r5813** (GxInspect now lives in its own svn branch,
  `https://svn.code.sf.net/p/gexperts/code/GxInspect/trunk`, pulled into GExperts as an external).
  He measured the event's type information in the 64-bit and 32-bit Delphi 13.2 IDEs and in
  Delphi 2007: all declare `var CellText: WideString`, because the IDE carries its own older
  VirtualTrees (`Idevirtualtrees` in `vclide<ver>.bpl`). The 2026-09-25 entry above describes it as
  "the 64-bit IDE's VirtualTrees"; the 32-bit IDE is the same. He also confirmed that a mismatched
  handler is fatal rather than cosmetic: forcing a `string` handler in the 64-bit IDE raised "Invalid
  pointer operation" from `System.@UStrClr` / `@FreeMem` inside `DoGetText`, and the IDE had to be
  killed. Nothing to change here, because `SignatureMismatch` already chooses the handler shape from
  type information rather than bitness and refuses anything else. He reached the same design
  independently, using the classic TypInfo `ParamList` instead of `System.Rtti`.
- (2026-09-21) **Version raised to 1.1.0.0** — `gllIdeAutomationVersion.rc`. A minor bump rather
  than a build bump, because the wire contract moved: `SERVER_VERSION` 0.7 → 0.8, `ping` gained a
  field, and two error codes were added. `tools/bump-build.py --show` confirms the numeric defines
  and `VER_STRING` agree, and the built Release BPL reports `1.1.0.0` for both `FileVersion` and
  `ProductVersion`.

- (2026-09-10) Project platforms normalised to Win32 + Win64 only in 1 `.dproj` file
  Non-Windows targets (`Android`, `Android64`, `iOS*`, `OSX*`, `Linux64`) and the
  `Win64x` / `WinARM64EC` variants were removed together with their `Base_<Plat>` and
  `Cfg_N_<Plat>` property groups, `<Deployment>` platform nodes and `<ProjectRoot>`
  entries; a deactivated `Win32` or `Win64` was switched on.
  **Why:** standing suite rule — every gll* project is Delphi 13, Win32 + Win64, nothing
  else, so the four-mode package sweep is always possible.

- (2026-09-05) Codeberg is retired; every repository URL points at GitHub again.
  **Why:** hosting consolidated back on GitHub. `origin` is the GitHub URL, the stale
  `codeberg` remote has been removed from the working checkout, and the documentation that
  says where to clone from was updated to match. The Codeberg entry below is superseded;
  its URLs are left as written because rewriting them would falsify the record.

- (2026-09-03) Repository moved to the `GITLAK-forks` Codeberg organisation: `origin` is now `https://codeberg.org/GITLAK-forks/gllIdeAutomation.git`, and the documentation references were updated to match. **Why:** the `GITLAK` account had reached Codeberg's hard limit of 100 repositories, and an organisation carries its own allowance — `CHANGELOG.md`
  **Superseded 2026-09-05:** Codeberg is no longer used; see the entry above.

## [In-Service]

> Libraries and packages are continuously deployed: changes below were live as soon as the package was rebuilt and installed. Tagged version snapshots are listed beneath.
>
> This section is the historical record kept under that model. `## [Unreleased]` above is the
> current one — the note here used to claim there was no `[Unreleased]` backlog while one sat at
> the top of the same file, which was simply wrong. New entries go under `## [Unreleased]`.

### Fixed

- (2026-08-26) **C++Builder output turned off**. `DCC_CBuilderOutput` was `All`, so every build emitted `.hpp` / `.bpi` / `.a` / `.obj` files for a compiler that is **never in scope here** (standing rule: "I dont use C++ at all"). Across the estate that was 616 files and 90 MB of output nobody consumes, regenerated on every build; `gllSynEdit` alone accounted for 560. Now `None`. The `DCC_HppOutput` / `DCC_BpiOutput` / `DCC_ObjOutput` properties are left in place deliberately - they only say *where* such files would go, so with generation off they are inert, and removing them would enlarge the diff without changing behaviour. Verified: the affected packages rebuilt clean in every enabled mode, emitted no C++ artefacts, and rebuilt clean again after the existing ones were deleted (so nothing was load-bearing).

- (2026-08-24) Debug and Release package output no longer collide
  **Why:** RAD Studio defaults `DCC_BplOutput` to `$(BDSCOMMONDIR)\Bpl\$(Platform)` and `DCC_DcpOutput` to `\Dcp\$(Platform)`, neither carrying `$(Config)`, so whichever configuration was built last was the one left installed. `.dcu` output was already separated, which masked it.
  Release still writes to the shared `Bpl`/`Dcp` folders - that is what is on `PATH`, and it is where dependent packages resolve their `requires` from - while Debug is diverted to a `$(Config)` subfolder. Separating Release as well breaks package loading, so only Debug moves.
  Verified by building the package in both configurations.

### Added

- (2026-08-08) Documented that a build fails with two `F2039 Could not create output file` errors when an IDE
  has the package installed, because it holds both the `.bpl` and the `.dcp` open — and that this
  applies to command-line builds too, not just builds from inside the IDE. **Why:** it is the
  first wall anyone changing the source hits, the error text does not mention the cause, and the
  error *count* is the diagnostic. Reproduced twice. — `docs/HELP.md`, `README.md`

## [1.0.1] - 2026-08-08

The release the announcement points at. Delphi 13 Florence, Win32 or Win64, MIT licensed.

### Added

- (2026-08-08) Initial package: starts the automation server inside the Delphi IDE, so external agent tools can drive the IDE through the live VCL component model instead of
  synthesising keystrokes. **Why:** IDE-side behaviour — whether a debug visualizer is offered,
  how a value renders — is invisible to the compiler, and driving the IDE by `SendKeys` plus
  screenshots is slow, expensive in context, and carries a standing risk of typing into the
  wrong window. The server unit already existed for driving VCL applications under test; nobody was calling
  `Start` inside the IDE. — `src/gllIdeAutomation.Starter.pas`,
  `gllIdeAutomation.dpk`, `gllIdeAutomation.dproj`
- (2026-08-08) `tools/click.py` — clicks at a screen coordinate, which is what makes debugger panes readable.
  Select a row with it, fire `lvCopyValue` through `app_click`, read the clipboard: the value
  arrives as text. Verified on two rows against what the pane displayed. **Why it needs care:**
  with two 4K monitors at 150%, screenshots come back in *physical* pixels (`CopyFromScreen`
  crops, it does not scale) while `SetCursorPos` in a DPI-unaware process takes *virtualised*
  ones — a factor of exactly 1.5, so a coordinate read off a screenshot lands two thirds of the
  way to its target and `SendInput` still reports success. The tool declares
  `PER_MONITOR_AWARE_V2` so both spaces are physical, and refuses to click if the cursor will not
  stay put, so a human using the mouse does not receive the click. — `tools/click.py`
- (2026-08-08) Gated on the `GITLAK_IDE_AUTOMATION=1` environment variable, so an IDE launched any other way
  is unaffected. **Why not a command-line switch:** `bds.exe` parses its own command
  line and treats unrecognised arguments as files to open. —
  `src/gllIdeAutomation.Starter.pas`
- (2026-08-08) Version information on the BPL, defined once in `gllIdeAutomationVersion.rc` and linked by the
  `.dpk`. **Why:** the BPL is installed into a shared IDE, so when one misbehaves the first
  question is which build is loaded — and an unversioned DLL cannot answer it. Documented with the
  one-line command that reads it back. — `gllIdeAutomationVersion.rc`,
  `gllIdeAutomation.dpk`, `gllIdeAutomation.dproj`, `README.md`, `docs/HELP.md`,
  `docs/Users Guide.md`
- (2026-08-08) `tools/bump-build.py` — increments the build number in the `.rc`, rewriting the numeric
  `VER_BUILD` and the display `VER_STRING` together so they cannot drift, and refusing to write
  unless it matched exactly one of each. — `tools/bump-build.py`, `README.md`,
  `docs/HELP.md`, `docs/Users Guide.md`
- (2026-08-08) `$LIBSUFFIX` is now chosen by `CompilerVersion`, so the package builds on 10.3 Rio through 13
  Florence rather than 12 and later only. **Why:** `{$LIBSUFFIX AUTO}` is itself a 12-and-later
  feature, so on an older IDE the directive that was meant to supply the suffix was the thing that
  broke the build. Anything older than 10.3 stops with a `{$MESSAGE FATAL}` naming the requirement
  instead of failing obscurely further in. — `gllIdeAutomation.dpk`, `README.md`
- (2026-08-08) `gllIdeAutomation.diproj` — the DocInsight project that builds the API documentation from the
  units' XML doc comments. It carries only relative paths, so it works from any clone. The
  generated `build/docs` output is not tracked. — `gllIdeAutomation.diproj`,
  `.gitignore`, `README.md`

### Changed

- (2026-08-08) The version moved out of the `.dproj`'s `VerInfo_*` properties and into a resource script,
  `gllIdeAutomationVersion.rc`, with `VerInfo_IncludeVerInfo=false`. **Why:** Delphi's mechanism
  cannot be reduced to one definition — the `.dproj` keeps a Base copy plus one per build
  configuration, and deleting the per-configuration copy only makes the next build of that
  configuration write it back, byte for byte. The IDE's auto-increment then advances `FileVersion`
  in that copy on Build while leaving `ProductVersion` behind, so the facility meant to manage the
  version is itself capable of shipping a BPL whose two version strings disagree. Verified after
  the move: building both configurations regenerates nothing, and exactly one file in the repo
  defines a version. — `gllIdeAutomationVersion.rc`, `gllIdeAutomation.dpk`,
  `gllIdeAutomation.dproj`, `.gitignore`
- (2026-08-08) `tools/Start-IDE.ps1` finds the IDE in the registry (`Software\Embarcadero\BDS\<ver>\RootDir`,
  HKCU then HKLM) instead of hard-coding one install path, preferring `bin64\bds.exe` where a
  version ships one. `-Version` and `-BdsPath` override it. **Why:** the path it hard-coded was
  13 Florence's, so on any other IDE the first script a new user runs threw — while the README
  offered 10.3 Rio and later. When the server fails to start it now names the BPL and the
  `Known Packages` key for the IDE that was actually launched. — `tools/Start-IDE.ps1`,
  `README.md`
- (2026-08-08) The supported range is stated as targeted rather than tested: 13 Florence is the only version
  the package has been built on. **Why:** an ambitious claim a stranger disproves in five minutes
  costs more than an honest one, and the 10.3–12 `$LIBSUFFIX` branches have never been
  exercised. — `README.md`
- (2026-08-08) Older IDEs are supported through the `.dpk` rather than through the `.dproj`. `<ProjectVersion>`
  was briefly lowered to 18.8 so an older IDE would open the project; that was abandoned because
  13 Florence rewrites it to 20.5 on every open, so the setting had to be reverted after each IDE
  session to stay committed. **Why this way instead:** the `.dpk` is the actual project and is
  version-agnostic — verified by compiling it with `dcc64` and no `.dproj` present at all, which
  produced a correct, correctly-versioned BPL. A `.dproj` is only the MSBuild wrapper belonging to
  whichever IDE wrote it, so an older IDE generates its own. Separate per-version project files
  were considered and rejected: five copies of the same settings would drift, and only the 13
  Florence one could be tested here. — `gllIdeAutomation.dproj`, `README.md`,
  `docs/Users Guide.md`
- (2026-08-08) The `.dproj` now holds whatever 13 Florence writes — `ProjectVersion` 20.5, the Win64x platform,
  a `DCCReference` to the generated version resource, four-space indentation. It is treated as the
  IDE's file rather than a hand-maintained one, so opening the project no longer produces a diff
  to revert. A fresh checkout still builds: MSBuild compiles the `.rc` before resolving the
  reference to its output. — `gllIdeAutomation.dproj`

### Fixed

- (2026-08-08) Three illegal control characters in the starter unit's doc comment, which stopped DocInsight
  transforming the topic to HTML (`0xC00CE508: An invalid character was found in text content`).
  The example path had been written through a layer that interprets C escape sequences, so
  `\37` became octal `0x1F` and each `\b` a backspace `0x08` — `Studio\37.0\bin64\bds.exe` was
  stored as `Studio·.0·in64·ds.exe`. The other backslashes survived only because `\P`, `\E` and
  `\S` are not escape sequences. **Why it went unnoticed:** control characters are invisible in an
  editor and legal in Pascal comments, so the package compiled clean throughout — nothing but an
  XML parser was ever going to object. All four doc blocks now parse as XML, and no tracked text
  file contains a character below 0x20 other than tab, CR or LF. —
  `src/gllIdeAutomation.Starter.pas`
- (2026-08-08) The two entries above naming the starter unit called it `u_gllIdeAutomationStarter.pas`, which
  has never existed here — it is `src/gllIdeAutomation.Starter.pas`. —
  `CHANGELOG.md`
- (2026-08-08) The docs said MSBuild "ignores" `VerInfo_AutoIncVersion`. It does not ignore it — it tries and
  fails, which is only visible below the default MSBuild verbosity. Right outcome, wrong reason,
  in four places. — `README.md`, `docs/HELP.md`, `docs/Users Guide.md`,
  `tools/bump-build.py`
- (2026-08-08) The note on why every copy of the version is rewritten now records two things that were
  measured rather than assumed: the per-configuration copy cannot be removed — delete it and the
  next build of that configuration writes it back, byte for byte — and the IDE's own
  auto-increment advances `FileVersion` while leaving `ProductVersion` behind, so a Build from
  the IDE is by itself enough to produce a BPL whose two version strings disagree. —
  `tools/bump-build.py`

## [1.0.0] - 2026-08-08

Tagged before the fixes above and superseded within the day — **use 1.0.1**. It carried no version
information on the BPL, a `tools/Start-IDE.ps1` hard-coded to one Delphi install path, and three
invisible control characters in a doc comment that stopped the documentation building. Left in
place rather than moved, because it was already published and genuinely was that code.

[Unreleased]: https://github.com/ijbranch/gllAutomationServer/compare/gllIdeAutomation-v1.0.1...main
[1.0.1]: https://github.com/ijbranch/gllAutomationServer/releases/tag/gllIdeAutomation-v1.0.1
[1.0.0]: https://github.com/ijbranch/gllAutomationServer/releases/tag/gllIdeAutomation-v1.0.0
