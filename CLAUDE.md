# gllAutomationServer — project notes

Two packages in one repository (merged 2026-10-13):

- **`gllAutomationServer`** (root) — the in-app automation server, runtime-only. Reference `Help.md`,
  history `CHANGELOG.md`.
- **`gllIdeAutomation\`** — the design-time package that hosts the server inside the Delphi IDE and
  registers the IDE-only commands (`ide_*`, `debug_*`, `tree_text`). Its own `README.md`, `Help.md`,
  `Users Guide.md` and `CHANGELOG.md` are in that folder; its old tags are `gllIdeAutomation-v*`.

Build order: the server package (all four modes), then `gllIdeAutomation\gllIdeAutomation.dproj` (all
four). A change that crosses the two goes in one commit, with an entry in each CHANGELOG.

## The one rule: this is the only copy

Until 2026-10-13 the unit lived in GITLAKLib with a renamed copy in gllIdeAutomation, synced by hand.
Do not reintroduce a copy anywhere. A host that needs different behaviour gets a `Start` parameter or
a registered command (`RegisterCommand` + `ResolveForm` / `ResolveComponent`), not a fork.

## Consumers, and what a change costs

- **27 DBiWorkflow apps** link it statically through the library path
  (`D:\gllAutomationServer\37.0\<Platform>\Release`, in `Library\Win32`/`Win64` and `EnvOptions.proj`).
  A change reaches an app only when the app is rebuilt.
- **gllIdeAutomation** (in `gllIdeAutomation\`) `requires` the package; the IDE loads `gllAutomationServer370.bpl` from the shared
  `Bpl\<Platform>` folder. **Close the IDE before building Release** (`F2039` otherwise), and restart it to
  pick up a change.
- **GITLAKMCP**'s `app_*` tools are the client (`src\Tools\GitLAKMCP.Tool.AppAutomation.pas`). A new
  command or field usually wants a tool or a parameter there too.
- **`gllAutomationServer.Client.pas`** (in this package) is the test-side client, for DUnitX suites that launch
  and drive an app, and the one implementation of discovery, the trust checks and the send. A new command
  usually wants a `TAutomationApp` method too; a change to the wire format changes both clients.

## Build and test

- Package: all four modes (Win32 + Win64 × Debug + Release), Release last. Zero hints, zero warnings.
- Tests: `Tests\gllAutomationServerTests.dproj` (DUnitX console, Win64 Debug). It links the package's DCUs
  from `..\37.0\<Platform>\<Config>`, so **rebuild the package first** or the run tests the old binary.
  Run `Tests\Win64\Debug\gllAutomationServerTests.exe --exitbehavior:Continue`.
- **A service's window station paints nothing.** Since 2026-10-25 GITLAKMCP runs it on a hidden desktop of the interactive window station ( it is in `settings.ini [TestRunner] DesktopTargets`, GITLAKMCP f8b28a3 ), so `test_run` is 22/22.
  Only if that falls back to the service's own station do the 4 screenshot-render tests ignore themselves
  ( `GllDUnitX.Station.RequireInteractiveStation`, from `gllDUnitX\Source\Gll` ) (18 passed / 4 ignored). Run the exe from a desktop session to exercise them (22/22).
- Bump `SERVER_VERSION` (the wire-protocol version `ping` reports) when commands or fields change, and the
  `PROTOCOL_VERSION` constant in the test with it. It is separate from the package's file version.
- A stale `gllAutomationServer.dcu` anywhere on the library path shadows this one. GITLAKLib's output
  folders were cleaned on 2026-10-13; if `ping` reports an old `server`, look there first.

## Licence

Proprietary, in-house (Ian, 2026-10-13: "the two automation projects are now purely ours"). Every source file
opens with the GITLAK header block - the GITLAKMCP form, without GITLAKLib's old licensee clause - followed by
its own descriptive comment. Until that day the code was MIT and gllIdeAutomation was public; `LICENSE` says
copies taken under MIT before then keep those rights. Estate rules apply in full: Delphi 13 floor
(`CompilerVersion >= 37`), FULL DocInsight, zero hints and warnings.
