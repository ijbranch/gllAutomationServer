# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

> The change record of the `gllAutomationServerTests` test suite (`Tests`).  Kept beside the suite since 2026-10-25
> (Ian: "every test suite should have its own change log"); test-only entries recorded before that in the repository's
> `CHANGELOG.md` were moved here the same day.  Product changes, including those that change a product unit together
> with its tests, stay in the repository's `CHANGELOG.md`.

## [In-Service]

### Added

- (2026-10-25) **This change log** — `CHANGELOG.md`.  The suite's own record, per the estate rule that every test
  suite has one; test-only history moved in from `..\CHANGELOG.md` ( 4 entries ).

### Changed

- (2026-10-25) **The screenshot-render tests use the shared window-station guard** - `Tests/TestGllAutomationServer.pas`, `Tests/gllAutomationServerTests.dproj`.  The private `RequireInteractiveSession` ( a `ProcessIdToSessionId = 0` test ) is replaced by `GllDUnitX.Station.RequireInteractiveStation`, which tests the window station's `WSF_VISIBLE` flag, the actual reason `PrintWindow` renders white under GITLAKMCP's `test_run`; the project adds `..\..\gllDUnitX\Source\Gll` to its unit search path.  Unchanged result there: 18 passed, 4 ignored.
- (2026-10-23) **The test suite now runs under the Aqua Light Slate VCL style, and the screenshot tests assert what the styled UI presents** - `Tests\gllAutomationServerTests.dpr`, `Tests\gllAutomationServerTests.dproj`, `Tests\TestGllAutomationServer.pas`.  Ian's rule (2026-10-23) is that any test producing UI uses the style "to ensure that all UI presents properly and completely"; the `.dproj` embeds it and the runner activates it with `TStyleManager.TrySetStyle`.  The runner also gained `{$R *.res}`, without which the embedded style is never linked.  Under the style the memo's client is painted in the style's edit colour, so `clFuchsia` no longer reached the screen and the two memo screenshot tests failed.  They now assert the active style's `scEdit` colour (after asserting the style is active), and because that colour is white - what a blank render also gives - each also requires the memo's text to be drawn on it; the form test also checks the bare form beside the memo is not the edit colour.  Mutation-proved: with the memo's text emptied, both text checks fail.  White and black are the same with and without the style, so both tests also assert the memo's left border is the one the active style draws (`teEditBorderNoScrollNormal`, `$D6D6D6`) and not the unstyled sunken edge (`clBtnShadow`, `$A0A0A0`): mutation-proved, with the memo's `StyleElements` emptied both fail there.  22/22 on Win64 and Win32 from a desktop session; 18 passed and 4 ignored under `test_run` (Session 0), as before.  The runner calls `TrySetStyle` without its error dialog and, when the style is not linked, prints one line and stops with exit code 251 (the runner-failed code), so it can neither hang on a modal nor run unstyled; a scratch build without the style proved it.

### Fixed

- (2026-10-23) **The test suite did not compile for Win32: `E2532 Couldn't infer generic type argument` on `AreEqual`** - `Tests\TestGllAutomationServer.pas`.  `Screenshot_MaxWidth_ScalesProportionally` compared `Round(...)` (`Int64`) with `TPngImage.Height` (`Integer`).  Win64 resolved it to gllDUnitX's `AreEqual(Int64, Integer)` overload, which exists only under `{$IFDEF CPU64BITS}` (`DUnitX.Assert.pas`); Win32 has no such overload, so it fell to `AreEqual<T>` and inference failed.  The call now names `AreEqual<Int64>` on both platforms, which compares the same two values (widening the height, not narrowing the rounded value).  Found by the 2026-10-23 Win32 pass over every gll* fork (Ian: "all our forks should be usable/up-to-date in Win32 and Win64").  Win32 Debug, desktop run: **22/22**.

## [1.0.0] - 2026-10-13

### Added

- (2026-10-13) **Test suite, moved from GITLAKLibUnitTests and extended: 18 tests** - `Tests\TestGllAutomationServer.pas`. The 10 registry and envelope tests came with the unit; 8 new ones cover paths and `Ambiguous`, docked and synthetic names, `Font.Size`, string lists and memo text, `NotScalar`, and `keys`. Mutation-proved: dropping Shift from typed text and resolving an ambiguous name to its first match each turned exactly one test red. The moved shadowing test pins the protocol version against a constant; in GITLAKLib it still asserted 0.9 after the 0.10 bump.
