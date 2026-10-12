# gllAutomationServer — project notes

The in-app automation server (`gllAutomationServer.pas`), one runtime-only package. Reference:
`Help.md`. History: `CHANGELOG.md`.

## The one rule: this is the only copy

Until 2026-10-13 the unit lived in GITLAKLib with a renamed copy in gllIdeAutomation, synced by hand.
Do not reintroduce a copy anywhere. A host that needs different behaviour gets a `Start` parameter or
a registered command (`RegisterCommand` + `ResolveForm` / `ResolveComponent`), not a fork.

## Consumers, and what a change costs

- **27 DBiWorkflow apps** link it statically through the library path
  (`D:\gllAutomationServer\37.0\<Platform>\Release`, in `Library\Win32`/`Win64` and `EnvOptions.proj`).
  A change reaches an app only when the app is rebuilt.
- **gllIdeAutomation** `requires` the package; the IDE loads `gllAutomationServer370.bpl` from the shared
  `Bpl\<Platform>` folder. **Close the IDE before building Release** (`F2039` otherwise), and restart it to
  pick up a change.
- **GITLAKMCP**'s `app_*` tools are the client (`src\Tools\GitLAKMCP.Tool.AppAutomation.pas`). A new
  command or field usually wants a tool or a parameter there too.

## Build and test

- Package: all four modes (Win32 + Win64 × Debug + Release), Release last. Zero hints, zero warnings.
- Tests: `Tests\gllAutomationServerTests.dproj` (DUnitX console, Win64 Debug). It links the package's DCUs
  from `..\37.0\<Platform>\<Config>`, so **rebuild the package first** or the run tests the old binary.
  Run `Tests\Win64\Debug\gllAutomationServerTests.exe --exitbehavior:Continue`.
- Bump `SERVER_VERSION` (the wire-protocol version `ping` reports) when commands or fields change, and the
  `PROTOCOL_VERSION` constant in the test with it. It is separate from the package's file version.
- A stale `gllAutomationServer.dcu` anywhere on the library path shadows this one. GITLAKLib's output
  folders were cleaned on 2026-10-13; if `ping` reports an old `server`, look there first.

## Licence

MIT (`LICENSE`), because the code was already published under MIT inside gllIdeAutomation. New files take
the short MIT header the unit carries, not the GITLAK proprietary block.
