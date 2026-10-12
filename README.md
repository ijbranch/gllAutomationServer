# gllAutomationServer

An in-app automation server for Delphi VCL applications. Link one unit, start it on an explicit
opt-in, and an external agent can drive and inspect the running application over a loopback
socket: click, type, read and write properties (including nested ones like `Font.Size`), answer
modal dialogs, read and edit datasets, and take screenshots. It works on the live VCL component
model, not on pixels, so it is coordinate-free and DPI-independent, and it runs in Release builds.

Built for unattended UI testing by an AI agent (the `gitlak-mcp` `app_*` tools), but the protocol is
plain newline-delimited JSON, and any client can speak it.

- **[Users Guide.md](Users%20Guide.md)** — add it to an application and drive it.
- **[Help.md](Help.md)** — the reference: commands, addressing, error codes, threading, API.
- **[CHANGELOG.md](CHANGELOG.md)** — the history.

## At a glance

```pascal
// the .dpr
uses ..., gllAutomationServer;
...
Application.Initialize;
if FindCmdLineSwitch( 'AUTOMATION' ) then
  TAutomationServer.Start( 'MyApp' );
```

```json
{ "token":"…", "id":1, "cmd":"keys", "form":"main", "name":"edtCustomer", "text":"ACME", "keys":"Tab" }
{ "id":1, "ok":true, "result":{ "target":"edtCustomer", "strokes":5, "strokesSent":5, "completed":true, "modalOpen":false } }
```

Without the opt-in nothing is created. With it, the server listens on `127.0.0.1` only, and every
request must carry a per-session token from a discovery file that only the current user,
Administrators and SYSTEM can read.

## Requirements

- **Delphi 13 Florence** (RAD Studio 37.0), VCL, **Win32 and Win64**.
- Packages that ship with Delphi: `rtl`, `vcl`, `vclimg`, `dbrtl`, `IndySystem`, `IndyCore`.

## Building

`gllAutomationServer.dproj` is a runtime-only package (`{$RUNONLY}`). Build all four modes (Win32 and
Win64, Debug and Release). The DCUs land in `37.0\<Platform>\<Config>`, and the BPL and DCP go to the
shared `Bpl` / `Dcp` folders (Release in `<Platform>`, Debug in `<Platform>\Debug`).

- **An application** links the unit statically: put `D:\gllAutomationServer\37.0\<Platform>\Release`
  on the IDE's library path (Tools > Options > Language > Delphi > Library) for both platforms.
- **A package** that uses it (gllIdeAutomation does) puts `gllAutomationServer` in its `requires`
  clause.

Tests: `Tests\gllAutomationServerTests.dproj`, a DUnitX console project. It links this package's
DCUs, so build the package first.

## Who uses it

- The 27 applications of GITLAK Software's DBiWorkflow suite, started on `/AUTOMATION`.
- **gllIdeAutomation**, in [`gllIdeAutomation\`](gllIdeAutomation/README.md) in this repository: a
  design-time package that runs the server inside the Delphi IDE and adds the IDE's own commands
  (ToolsAPI, debugger panes) with `RegisterCommand`. It has its own README, Help, Users Guide and
  CHANGELOG there.

## Repository layout

```
gllAutomationServer.dpk / .dproj / .pas   the server - a runtime package, linked by applications
Tests\                                    its DUnitX suite
gllIdeAutomation\                         the IDE host - a design-time package that requires the server
```

The two were separate repositories until 2026-10-13; gllIdeAutomation's history came across in a
subtree merge, and its old tags are `gllIdeAutomation-v1.0.0`, `-v1.0.1` and `-v1.2.0`.

## Licence

MIT — see [LICENSE](LICENSE).
