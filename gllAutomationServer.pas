(* GITLAK Software
  ***************************************************************************

    (C) 2016-2026 Ian Branch (GITLAK Software). All rights reserved.

    Portions derived from GExperts' GxInspect by Thomas Mueller (dummzeuch),
    svn r6031, all from host\GxInspect_Server.pas: WndCanBeClicked (from
    GxCanBeClicked), WndIsModal (from EnumDialogProc), ClickOutcome (the three
    outcomes of CmdDismiss), WindowAtControlPoint (from TryGetWindowAtPoint)
    and BuildDropHandle (from GxMakeHDrop).  Each is adapted to this unit's
    commands and style.

    This code and all associated intellectual property are the exclusive
    property of Ian Branch (GITLAK Software).  The portions named above are
    used under the written permission of Thomas Mueller, sole developer of
    GxInspect, given 2026-10-31 (see LICENSE).

    Any reproduction, distribution, or use, in whole or in part, by any other
    party is strictly prohibited without the express written permission of the
    Author.

    Development history: https://github.com/ijbranch/gllAutomationServer

    THIS SOFTWARE IS PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED.
    IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DAMAGES ARISING IN CONNECTION
    WITH THE USE OF THIS SOFTWARE.

  ***************************************************************************

  Author(s) :
  Ian Branch - GITLAK Software.
  Co-developed: Thomas Mueller (dummzeuch) - GExperts' GxInspect, the portions
  named above.

  ***************************************************************************
*)

(*
  gllAutomationServer - in-app automation server for VCL applications

  ONE COPY. Until 2026-10-13 this unit lived in GITLAKLib, with a renamed, hand-synced copy in
  gllIdeAutomation (gllIdeAutomation.Server) because a unit may exist in only one loaded package.
  The two drifted 283 lines apart once and every change had to be made twice, so the unit now has
  this package to itself and both consumers use it: GITLAKLib's applications statically, through
  the library path, and gllIdeAutomation through `requires`. What used to differ between the copies
  is now chosen by the host - see TAutomationServer.Start's ADisableIdleTimers, and RegisterCommand
  plus ResolveForm / ResolveComponent, which is how gllIdeAutomation adds its tree_text command.
*)
/// <summary>
///   In-app automation server for driving and asserting on a running VCL app
///   from an external agent (e.g. gitlak-mcp app_* tools).
///   Listens on loopback TCP, newline-delimited JSON, token-authenticated;
///   command bodies are marshalled to the main VCL thread. An application
///   references it unconditionally in BOTH Release and Debug builds and starts
///   it only on an explicit opt-in (the DBiWorkflow suite's /AUTOMATION switch,
///   gllIdeAutomation's GITLAK_IDE_AUTOMATION=1): without one the listener is
///   never created, so a normally launched build behaves exactly as it did
///   before. Until 2026-08-10 the suite wrapped both the uses entry and the Start
///   call in {$IFDEF DEBUG}, which left the Release builds that are actually
///   deployed - and that produce the EurekaLog reports - the one configuration
///   that could not be driven or inspected.
///   M-A: ping / info + discovery + token.
///   M-B: tree (forms / components) · get / set (published props) · click
///   (fire OnClick directly, or mode=message: post BM_CLICK so the reply
///   returns BEFORE a modal-opening handler runs) · action (fire a named
///   TAction's Execute). Forms addressed by name / 'main' / 'active'; components by
///   owned name; failures return a stable error code (NoForm/NoComp/NoProp/…).
///   M-D: dialogs (list / click modal-dialog buttons — runs OFF the VCL thread
///   so it still works while a modal loop blocks Synchronize) · field_get ·
///   field_set (write a field — reaches values that data-aware controls hide,
///   e.g. the LMD DB edits publish no Text) · dataset_op (insert/append/edit/
///   post/cancel/refresh/navigate — reaches what TwwNavButton does in the
///   navigator rather than in OnClick) · dataset (assert on TDataSet state).
///   M-E: screenshot (PNG of the monitor the active form/dialog is on — also
///   OFF the VCL thread, so it can capture a blocking dialog; saved to Desktop).
///   0.8: click takes a count (1..CLICK_COUNT_MAX) and reports clicksDispatched
///   + stoppedReason when a handler raised (direct mode catches it here, so it
///   never reaches Application.HandleException / EurekaLog — use mode=message to
///   exercise a global error path) · set reports previous + changed · a NoProp
///   failure carries the object's property surface, with live values, in
///   error.data so the caller self-corrects without another round-trip.
///   0.9: TAutomationServer.RegisterCommand adds commands from outside this unit, on the
///   main or the worker thread; EAutoError is public so they can fail with a code of their own.
///   0.10: keys - types text and sends key chords (Ctrl+S, Tab, Enter, ...) to a control through
///   the app's own message loop, so KeyPreview, shortcuts, dialog navigation and the OnKey*
///   events run as for a real keyboard; runs on the worker thread and waits for delivery.
///   0.11: a component name also reaches what the form does not own directly (a frame's controls,
///   a control docked in from elsewhere), takes a dotted path (fraAddress.edtTown) and the synthetic
///   name tree gives an unnamed component (@TButton#2), and a name several components share fails
///   Ambiguous with a path for each; tree takes deep. get / set take a dotted property path through
///   object properties (Font.Size), read and write a TStrings as its text (Lines), and fall back to
///   a control's window text for an unpublished Text / Caption (TMemo.Text). The unit moves to its
///   own package; Start takes ADisableIdleTimers, and ResolveForm / ResolveComponent are public so a
///   registered command addresses forms and components exactly as the built-ins do.
///   0.12: screenshot takes name (and form): the target's top-level window is rendered through DWM
///   from the worker thread and the target cropped from it, so a covered or off-screen window comes
///   out as itself; maxWidth scales any screenshot down.
/// </summary>
unit gllAutomationServer;

interface

uses
  System.SysUtils, System.Classes, System.JSON,
  Vcl.Controls, Vcl.Forms;

type
  /// <summary>Command-level failure carrying a stable machine-readable code.</summary>
  /// <remarks>
  ///   declared in the interface so that a command registered through
  ///   <see cref="TAutomationServer.RegisterCommand"/> can fail with a code of its own, exactly as a
  ///   built-in command does.
  /// </remarks>
  EAutoError = class( Exception )
  public
    /// <summary>Stable error code surfaced in the response's <c>error.code</c> (e.g. <c>NoForm</c>, <c>NoProp</c>).</summary>
    Code: string;
    /// <summary>
    ///   Optional machine-readable payload copied into the response's <c>error.data</c>
    ///   (e.g. the writable-property list carried by a <c>NoProp</c> failure, so the
    ///   caller can self-correct without a second round-trip). Owned by the exception.
    /// </summary>
    Data: TJSONValue;
    /// <summary>Creates the error with a machine code and a human message.</summary>
    /// <param name="ACode">The stable error code.</param>
    /// <param name="AMsg">The human-readable message.</param>
    constructor CreateCode( const ACode, AMsg: string );
    /// <summary>Creates the error with a machine code, a human message, and an owned <c>error.data</c> payload.</summary>
    /// <param name="ACode">The stable error code.</param>
    /// <param name="AMsg">The human-readable message.</param>
    /// <param name="AData">The payload; ownership passes to the exception (freed with it).</param>
    constructor CreateCodeData( const ACode, AMsg: string; AData: TJSONValue );
    /// <summary>Frees the owned <c>Data</c> payload.</summary>
    destructor Destroy; override;
  end;

  /// <summary>Which thread a registered command's handler is called on.</summary>
  TAutomationCommandThread = (
    /// <summary>Marshalled to the main VCL thread, like every built-in VCL command.</summary>
    actMainThread,
    /// <summary>
    ///   Called on the connection's worker thread. For a handler that must WAIT for the main thread
    ///   to do something - it synchronises each step itself and sleeps between them, which a handler
    ///   running on the main thread could not do without stopping the very thing it waits for.
    /// </summary>
    actWorkerThread );

  /// <summary>A command added from outside this unit.</summary>
  /// <param name="ARequest">The whole parsed request; read arguments from it, never free it.</param>
  /// <returns>The <c>result</c> value; ownership passes to the server. Fail by raising <see cref="EAutoError"/>.</returns>
  TAutomationCommand = reference to function( ARequest: TJSONObject ): TJSONValue;

  /// <summary>
  ///   Static facade controlling the singleton automation server. Call
  ///   <c>Start</c> once at app startup (after Application.Initialize) when the
  ///   /AUTOMATION switch is present.
  /// </summary>
  TAutomationServer = class
  public
    /// <summary>
    ///   Adds a command to the dispatcher. Built-in commands are matched first, so a registered
    ///   name can never shadow one. A name already registered is REFUSED (since 0.13): replacing it let a
    ///   second provider take it over silently, and the first provider's unregister then removed the
    ///   second's command.
    /// </summary>
    /// <param name="AName">The command name, matched without regard to case.</param>
    /// <param name="AHandler">The handler.</param>
    /// <param name="AThread">The thread the handler is called on.</param>
    /// <exception cref="EArgumentException">An empty name, a nil handler, or a name already registered.</exception>
    class procedure RegisterCommand( const AName: string; const AHandler: TAutomationCommand;
      AThread: TAutomationCommandThread = actMainThread );
    /// <summary>Removes a registered command; unknown names are ignored.</summary>
    /// <param name="AName">The command name.</param>
    class procedure UnregisterCommand( const AName: string );
    /// <summary>Starts the loopback automation server (idempotent).</summary>
    /// <param name="AAppName">The name the server advertises in its discovery file (<c>app_list</c> shows it).</param>
    /// <param name="ADisableIdleTimers">
    ///   True (the default) to disable the host's idle / auto-logout timers before every command that
    ///   touches the VCL, so an application cannot log itself out mid-test. Pass False in a host that
    ///   must be left exactly as it is - the Delphi IDE, whose plug-ins own their timers.
    /// </param>
    class procedure Start( const AAppName: string; ADisableIdleTimers: Boolean = True );
    /// <summary>
    ///   Resolves the request's <c>"form"</c> exactly as the built-in commands do: a form name,
    ///   <c>main</c> (the default) or <c>active</c>. For a registered command's handler.
    /// </summary>
    /// <param name="ARequest">The request.</param>
    /// <returns>The form.</returns>
    /// <exception cref="EAutoError"><c>NoForm</c> when no form matches.</exception>
    class function ResolveForm( ARequest: TJSONObject ): TForm;
    /// <summary>
    ///   Resolves the request's <c>"name"</c> on a form exactly as the built-in commands do: a plain
    ///   name, a dotted path, or a synthetic <c>@TClass#N</c>; empty gives the form itself. For a
    ///   registered command's handler.
    /// </summary>
    /// <param name="ARequest">The request.</param>
    /// <param name="AForm">The form, usually from <see cref="ResolveForm"/>.</param>
    /// <returns>The component.</returns>
    /// <exception cref="EAutoError"><c>NoComp</c> when nothing matches; <c>Ambiguous</c> when a plain name matches several.</exception>
    class function ResolveComponent( ARequest: TJSONObject; AForm: TForm ): TComponent;
    /// <summary>
    ///   Renders a control to a PNG on the user's Desktop exactly as <c>screenshot</c> renders a named one - legible,
    ///   and right even when the window is covered or off-screen - for a registered command whose target the
    ///   built-in addressing cannot reach (the IDE's form designer).  Call it from an <c>actWorkerThread</c>
    ///   handler: it synchronises <paramref name="AResolve"/> onto the main thread and renders on the calling one.
    /// </summary>
    /// <param name="AResolve">Finds the control; called on the main thread, once to plan and again only for the fallback renderer.</param>
    /// <param name="AMaxWidth">Scale down to at most this width; 0 for none.</param>
    /// <param name="AFileStem">The start of the PNG's file name, e.g. the host's name.</param>
    /// <returns><c>{ path, width, height, area, target, renderer, sourceWidth?, sourceHeight? }</c>; the caller owns it.</returns>
    /// <exception cref="EAutoError">
    ///   <c>NotShowing</c> when the control is hidden or outside its window; whatever <paramref name="AResolve"/> raises.
    /// </exception>
    class function RenderControl( const AResolve: TFunc<TControl>; AMaxWidth: Integer; const AFileStem: string ): TJSONObject;
    /// <summary>Stops and frees the server (idempotent).</summary>
    class procedure Stop;
    /// <summary>True while the server is running.</summary>
    class function IsRunning: Boolean;
    /// <summary>The bound loopback port (0 if not running).</summary>
    class function Port: Word;
  end;

implementation

uses
  System.Types, System.IOUtils, System.DateUtils, System.Math, System.Diagnostics,
  System.TypInfo, System.Variants, System.Generics.Collections,
  Winapi.Windows, Winapi.Messages, Winapi.MultiMon,
  System.SyncObjs,
  Data.DB,
  Vcl.Graphics, Vcl.Imaging.pngimage, Vcl.StdCtrls,
  //  Winapi.ShlObj + Winapi.KnownFolders resolve the REAL Desktop rather than assuming
  //  %USERPROFILE%\Desktop; IdIOHandler + IdExceptionCore give the request-line size policy.
  Winapi.ShlObj, Winapi.KnownFolders, Winapi.ActiveX,
  IdTCPServer, IdContext, IdGlobal, IdException, IdIOHandler, IdExceptionCore,
  gllAutomationServer.Client;

const
  /// <summary>First loopback port tried when binding the listener; the constructor scans upward from here.</summary>
  AUTOMATION_PORT_BASE = 8730; // loopback port scan base
  /// <summary>Number of consecutive ports probed from <c>AUTOMATION_PORT_BASE</c> before the bind attempt is abandoned.</summary>
  AUTOMATION_PORT_SPAN = 200; // ports to try before giving up
  /// <summary>Wire-protocol/feature version reported by the <c>ping</c>/<c>info</c> command's <c>server</c> field; bump when commands change.</summary>
  SERVER_VERSION    = '0.14'; // + screenshot path, the Client unit · 0.13: click_at, drop_files, dialogs hwnd/outcome/clickable/modal/texts · 0.12: screenshot name/form render, maxWidth · 0.11: reachable/synthetic/path names, dotted props · 0.10: keys · 0.9: registered commands · 0.8: click count/stoppedReason · set changed/previous
  /// <summary>Upper bound on <c>click</c>'s <c>count</c> (a mistyped count must not lock the UI thread for minutes).</summary>
  CLICK_COUNT_MAX   = 1000;
  /// <summary>Upper bound on the property list returned with a <c>NoProp</c> failure; the reply is read by an agent, so it stays bounded.</summary>
  PROPLIST_MAX      = 100;
  /// <summary>How long a dialog click waits for its window to go before reporting what came of it (GxInspect's measured 1.5 s).</summary>
  DISMISS_WAIT_MS   = 1500;
  /// <summary>Polling step while waiting for a clicked dialog to close.</summary>
  DISMISS_POLL_MS   = 25;
  /// <summary>Default of <c>dialogs</c>' <c>wait</c>: how long a click may stay queued or running before it is reported <c>pending</c>.</summary>
  DIALOG_HANDLED_WAIT_MS = 5000;
  /// <summary>The time a window's static texts may take to read between them, so a busy main thread cannot make a listing slow.</summary>
  TEXTS_BUDGET_MS   = 500;
  // Fixed, account-independent discovery dir so the agent (which may resolve a
  // different %TEMP%, e.g. a service) and the app always agree. The MCP side
  // can override via settings.ini [Automation] DiscoveryDir.
  /// <summary>Fixed directory holding per-PID discovery files so an external agent and the app always agree on it regardless of account or %TEMP%; defined once, in the client unit that reads them.</summary>
  DISCOVERY_DIR     = AUTOMATION_DISCOVERY_DIR;

  //  the discovery file carries the session TOKEN, which is the only thing standing
  //  between a local user and a server that can drive the UI and write datasets. The default
  //  ACL does NOT protect it: C:\ProgramData grants BUILTIN\Users ReadAndExecute and that is
  //  inherited all the way down, so a directory created with TDirectory.CreateDirectory hands
  //  the token to every account on the machine. The leaf is therefore created with an explicit
  //  PROTECTED DACL - inheritance broken - naming only SYSTEM, the local Administrators group
  //  and the account the host process is running as.
  /// <summary>SDDL for the discovery directory: a protected DACL granting full control to SYSTEM (<c>SY</c>), Administrators (<c>BA</c>) and the current user, and to nobody else. <c>%s</c> takes the user's SID.</summary>
  DISCOVERY_DIR_SDDL = 'D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;%s)';
  /// <summary>SDDL revision accepted by <c>ConvertStringSecurityDescriptorToSecurityDescriptor</c>.</summary>
  SDDL_REVISION_1   = 1;

  //  Indy's default MaxLineAction is maSplit, which SILENTLY cuts an over-long request
  //  in two - the first half fails to parse as JSON and the second half is then dispatched as
  //  if it were a separate request. A bounded length plus a hard failure is diagnosable; a
  //  split is not. The bound is generous: the largest legitimate request is a `set` carrying a
  //  memo's text.
  /// <summary>Largest request line accepted, in bytes; a longer one is refused with <c>RequestTooLong</c> rather than silently split.</summary>
  MAX_REQUEST_BYTES = 1024 * 1024;

type
  /// <summary>
  ///   Concrete automation server (one per process). Owns the Indy TCP listener,
  ///   the per-session token and the discovery file, and dispatches each request
  ///   line to the correct thread — Win32-only commands (<c>dialogs</c>,
  ///   <c>screenshot</c>) on the worker thread; everything else marshalled to the
  ///   main VCL thread. Created and freed through the <see cref="TAutomationServer"/> facade.
  /// </summary>
  TServerImpl = class
  private
    /// <summary>The loopback Indy TCP listener.</summary>
    FServer: TIdTCPServer;
    /// <summary>Application name reported by <c>ping</c>/<c>info</c> and written to the discovery file.</summary>
    FAppName: string;
    /// <summary>Per-session GUID token that every request must carry.</summary>
    FToken: string;
    /// <summary>The bound loopback port.</summary>
    FPort: Word;
    /// <summary>Full path of this process's discovery file.</summary>
    FDiscoveryPath: string;
    /// <summary>Set to 1 by <c>close</c> on the main thread; the worker that wrote its reply clears it and only then queues the close, so the reply is never lost to the app's exit.</summary>
    FCloseRequested: Integer;
    /// <summary>Indy <c>OnConnect</c> handler: applies this connection's request-line size policy (worker thread).</summary>
    /// <param name="AContext">The Indy connection context.</param>
    procedure DoConnect( AContext: TIdContext );
    /// <summary>Indy <c>OnExecute</c> handler: reads one request line, writes the response (worker thread).</summary>
    /// <param name="AContext">The Indy connection context.</param>
    procedure DoExecute( AContext: TIdContext );
    /// <summary>Parses + token-authenticates one request line and routes it to the correct thread (worker thread).</summary>
    /// <param name="ALine">The raw newline-delimited JSON request.</param>
    /// <returns>The JSON response line.</returns>
    function HandleLine( const ALine: string ): string;
    /// <summary>Dispatches one parsed command and builds its JSON response (runs on the main VCL thread for VCL commands).</summary>
    /// <param name="AReq">The parsed request object.</param>
    /// <returns>A new response object the caller frees: <c>{ id, ok, result | error }</c>.</returns>
    function ExecuteCommand( AReq: TJSONObject ): TJSONObject;
    /// <summary>Writes the per-PID discovery file (<c>app / pid / port / token / started</c>) into <c>DISCOVERY_DIR</c>.</summary>
    procedure WriteDiscovery;
    /// <summary>Deletes this process's discovery file (best-effort, swallows errors).</summary>
    procedure DeleteDiscovery;
  public
    /// <summary>Creates the server, scans for a free loopback port from <c>AUTOMATION_PORT_BASE</c>, binds it, and writes the discovery file.</summary>
    /// <param name="AAppName">The application name to advertise.</param>
    constructor Create( const AAppName: string );
    /// <summary>Stops the listener and removes the discovery file.</summary>
    destructor Destroy; override;
    /// <summary>The bound loopback port (0 before binding).</summary>
    property Port: Word read FPort;
  end;

  /// <summary>A command added through <c>TAutomationServer.RegisterCommand</c>.</summary>
  TRegisteredCommand = record
    /// <summary>The handler.</summary>
    Handler: TAutomationCommand;
    /// <summary>The thread it is called on.</summary>
    Thread: TAutomationCommandThread;
  end;

var
  /// <summary>The process-wide automation-server singleton (<c>nil</c> when stopped).</summary>
  GImpl             : TServerImpl = nil;
  /// <summary>Whether commands disable the host's idle timers first; set by <c>TAutomationServer.Start</c>.</summary>
  GDisableIdleTimers: Boolean = True;
  /// <summary>
  ///   commands registered from outside, keyed by lower-cased name. Read on worker threads and
  ///   written on the main thread, so every access holds the dictionary's own monitor.
  /// </summary>
  GCommands         : TDictionary<string, TRegisteredCommand> = nil;

var
  /// <summary>Set by this unit's finalization: from then on the table is gone for good, and is not re-created.</summary>
  GCommandsFinalized: Boolean = False;

/// <summary>The command table, created on first use.
///  <para>Not left to this unit's initialization alone: inside the IDE (2026-10-30) gllIdeAutomation's first
///  <c>RegisterCommand</c> met a nil table, an access violation in <c>TMonitor.GetMonitor( nil )</c> that its
///  start-up swallowed, so the server answered ping with no IDE command at all.  WHY the table was nil is not
///  established: the IDE package requires this one, whose initialization should therefore have run first.  Creating
///  the table on first use removes the failure whatever the order (proved live); the start-up log in
///  gllIdeAutomation records any recurrence.  Created under an atomic compare-exchange, so two threads asking at
///  once cannot both create it.</para></summary>
/// <returns>The table; never nil.</returns>
/// <exception cref="EInvalidOpException">Asked for after this unit's finalization, which would otherwise re-create
///  a table nothing frees.</exception>
function CommandTable: TDictionary<string, TRegisteredCommand>;
begin

  Result            := GCommands;
  if Result <> nil then Exit;
  if GCommandsFinalized then
    raise EInvalidOpException.Create( 'gllAutomationServer is finalized; no command can be registered any more' );
  var oNew          := TDictionary<string, TRegisteredCommand>.Create;
  if TInterlocked.CompareExchange( Pointer( GCommands ), Pointer( oNew ), nil ) <> nil then
    oNew.Free;   // another thread won the race
  Result            := GCommands;

end;

/// <summary>Looks up a registered command.</summary>
/// <param name="AName">The command name as the request gave it.</param>
/// <param name="ACommand">Receives the command when found.</param>
/// <returns>True when the name is registered.</returns>
function FindRegisteredCommand( const AName: string; out ACommand: TRegisteredCommand ): Boolean;
begin

  Result            := False;
  if ( AName = '' ) or ( GCommands = nil ) then Exit;

  System.TMonitor.Enter( GCommands );
  try
    Result          := GCommands.TryGetValue( LowerCase( AName ), ACommand );
  finally
    System.TMonitor.Exit( GCommands );
  end;

end;

{ ── Helpers ─────────────────────────────────────────────────────────────── }

/// <summary>Reads a binary's file version from its version resource.</summary>
/// <param name="AFileName">Full path of the executable or package to read.</param>
/// <returns><c>major.minor.release.build</c> (e.g. <c>4.0.0.13</c>), or '' when no version info is present.</returns>
function GetFileVersionOf( const AFileName: string ): string;
var
  iHandle           : DWORD;
  iSize             : DWORD;
  naBuf             : TBytes;
  pFixed            : PVSFixedFileInfo;
  iLen              : UINT;
begin

  Result            := '';
  if AFileName = '' then Exit;

  iSize             := GetFileVersionInfoSize( PChar( AFileName ), iHandle );
  if iSize = 0 then Exit;

  SetLength( naBuf, iSize );
  if ( not GetFileVersionInfo( PChar( AFileName ), iHandle, iSize, naBuf ) ) then Exit;

  if VerQueryValue( naBuf, '\', Pointer( pFixed ), iLen ) and ( iLen >= SizeOf( TVSFixedFileInfo ) ) then
    Result          := Format( '%d.%d.%d.%d', [ HiWord( pFixed.dwFileVersionMS ), LoWord( pFixed.dwFileVersionMS ),
        HiWord( pFixed.dwFileVersionLS ), LoWord( pFixed.dwFileVersionLS ) ] );

end;

/// <summary>Reads the running executable's file version from its version resource.</summary>
/// <returns><c>major.minor.release.build</c>, or '' when no version info is present.</returns>
function GetExeFileVersion: string;
begin

  Result            := GetFileVersionOf( ParamStr( 0 ) );

end;

/// <summary>
///   Reads THIS package's own file version, not the host executable's.
/// </summary>
/// <returns><c>major.minor.release.build</c> of the loaded BPL, or '' when it carries no version resource.</returns>
/// <remarks>
///   <c>ping</c> used to report only <c>ParamStr( 0 )</c>'s version: the host's. When the
///   host loads this unit as a runtime package (gllIdeAutomation inside the IDE), that says
///   nothing about WHICH gllAutomationServer build is loaded; <c>HInstance</c> is this module's
///   own handle, so <c>package</c> names it (and equals <c>version</c> when the unit is linked
///   into the exe).
/// </remarks>
function GetPackageFileVersion: string;
begin

  var naName: array[ 0..MAX_PATH ] of Char;
  var iLen          := GetModuleFileName( HInstance, @naName[ 0 ], Length( naName ) );
  if iLen = 0 then Exit( '' );

  Result            := GetFileVersionOf( string( naName ) );

end;

{ ── discovery-directory hardening and stale-file sweep ─────────────── }

/// <summary>advapi32 import: builds a security descriptor from an SDDL string. Not declared in this RTL's <c>Winapi.Windows</c>.</summary>
/// <param name="AStringSD">The SDDL text.</param>
/// <param name="ARevision">Always <c>SDDL_REVISION_1</c>.</param>
/// <param name="ASD">Receives a LocalAlloc'd security descriptor the caller must <c>LocalFree</c>.</param>
/// <param name="ASize">Optionally receives its size; may be nil.</param>
/// <returns>True on success.</returns>
function ConvertStringSecurityDescriptorToSecurityDescriptorW( AStringSD: PWideChar; ARevision: DWORD;
  var ASD: Pointer; ASize: PULONG ): BOOL; stdcall; external 'advapi32.dll';

/// <summary>advapi32 import: renders a SID in its <c>S-1-…</c> string form.</summary>
/// <param name="ASid">The SID to convert.</param>
/// <param name="AStringSid">Receives a LocalAlloc'd string the caller must <c>LocalFree</c>.</param>
/// <returns>True on success.</returns>
function ConvertSidToStringSidW( ASid: PSID; var AStringSid: PWideChar ): BOOL; stdcall; external 'advapi32.dll';

/// <summary>Returns the SID of the account this process is running as, in <c>S-1-…</c> string form.</summary>
/// <returns>The SID string, or '' when the token cannot be read.</returns>
function CurrentUserSidString: string;
begin

  Result            := '';

  var hToken: THandle := 0;
  if not OpenProcessToken( GetCurrentProcess, TOKEN_QUERY, hToken ) then Exit;
  try

    var iNeeded: DWORD := 0;
    GetTokenInformation( hToken, TokenUser, nil, 0, iNeeded ); // sizing call; expected to fail
    if iNeeded = 0 then Exit;

    var naBuf: TBytes;
    SetLength( naBuf, iNeeded );
    if not GetTokenInformation( hToken, TokenUser, Pointer( naBuf ), iNeeded, iNeeded ) then Exit;

    var pSid: PWideChar := nil;
    if not ConvertSidToStringSidW( PTokenUser( naBuf )^.User.Sid, pSid ) then Exit;
    try
      Result        := string( pSid );
    finally
      LocalFree( HLOCAL( pSid ) );
    end;

  finally
    CloseHandle( hToken );
  end;

end;

/// <summary>
///   Creates the discovery directory with a protected DACL naming only SYSTEM, Administrators
///   and the current account, so the session token it will hold is not readable by every local
///   user. Does nothing when the directory already exists.
/// </summary>
/// <param name="ADir">The directory to create.</param>
/// <remarks>
///   An EXISTING directory is left exactly as it is, deliberately: it is shared with the rest
///   of the GITLAK tooling and its permissions are the estate's to set, not this package's to
///   rewrite underneath whatever else is using it. The hardening therefore applies from the
///   moment the directory is first created — including after someone deletes it.
///   A directory that could not be hardened is still created, because failing to advertise is
///   worse than advertising with the inherited ACL, but the fallback says so through
///   <c>OutputDebugString</c> rather than passing silently.
/// </remarks>
procedure EnsureDiscoveryDir( const ADir: string );
begin

  if TDirectory.Exists( ADir ) then Exit;

  //  Parents keep the ordinary inherited ACL; only the leaf that holds tokens is locked down.
  var sParent       := TPath.GetDirectoryName( ADir );
  if ( sParent <> '' ) and ( not TDirectory.Exists( sParent ) ) then
    TDirectory.CreateDirectory( sParent );

  var sSid          := CurrentUserSidString;
  if sSid <> '' then
  begin
    var pSD: Pointer := nil;
    if ConvertStringSecurityDescriptorToSecurityDescriptorW(
      PWideChar( Format( DISCOVERY_DIR_SDDL, [ sSid ] ) ), SDDL_REVISION_1, pSD, nil ) then
      try
        var oAttrs: TSecurityAttributes;
        oAttrs.nLength := SizeOf( oAttrs );
        oAttrs.lpSecurityDescriptor := pSD;
        oAttrs.bInheritHandle := False;
        if CreateDirectory( PChar( ADir ), @oAttrs ) then Exit;
      finally
        LocalFree( HLOCAL( pSD ) );
      end;
  end;

  OutputDebugString( PChar( 'gllAutomationServer: could not create ' + ADir +
      ' with a restricted DACL; falling back to the inherited one, which may let other local users read the session token' ) );
  TDirectory.CreateDirectory( ADir );

end;

/// <summary>Reports whether a process id belongs to a process that is still running.</summary>
/// <param name="APid">The process id to test.</param>
/// <returns>True when the process exists; True also when it exists but is not ours to open.</returns>
/// <remarks>Access-denied means the process is there and belongs to somebody else, so it counts as alive — the safe direction, since the caller deletes what this reports dead.</remarks>
function ProcessIsAlive( APid: DWORD ): Boolean;
begin

  var hProc         := OpenProcess( SYNCHRONIZE, False, APid );
  if hProc = 0 then
    Exit( GetLastError = ERROR_ACCESS_DENIED );

  try
    //  A process object that is already signalled has exited but is still referenced.
    Result          := WaitForSingleObject( hProc, 0 ) = WAIT_TIMEOUT;
  finally
    CloseHandle( hProc );
  end;

end;

/// <summary>
///   Deletes discovery files left behind by processes that are no longer running.
/// </summary>
/// <param name="ADir">The discovery directory to sweep.</param>
/// <remarks>
///   <c>DeleteDiscovery</c> only runs on an orderly shutdown, so a killed or crashed host
///   leaves its advertisement behind for ever. Consumers pick the FIRST file whose <c>app</c>
///   matches — <c>tools/read_pane.py</c> does exactly that — so one stale file is enough to
///   make a running IDE look unreachable. Best-effort throughout: a file that cannot be read,
///   parsed or deleted is simply left alone, and a PID that has been reused reads as alive,
///   which errs towards keeping a file rather than deleting a live one.
/// </remarks>
procedure SweepStaleDiscovery( const ADir: string );
begin

  if not TDirectory.Exists( ADir ) then Exit;

  for var sFile in TDirectory.GetFiles( ADir, '*.json' ) do
  begin

    //  The file is named for the PID that wrote it, which is the whole liveness test.
    var iPid        := StrToIntDef( TPath.GetFileNameWithoutExtension( sFile ), 0 );
    if ( iPid <= 0 ) or ( DWORD( iPid ) = GetCurrentProcessId ) then Continue;
    if ProcessIsAlive( iPid ) then Continue;

    try
      TFile.Delete( sFile );
    except
      //  Locked, ACL-denied or already gone: another host may be sweeping the same directory.
      //  Narrowed, so a genuine fault still escapes rather than being absorbed here.
      on EInOutError do ;
    end;

  end;

end;

/// <summary>Builds a minimal error-response JSON line for a failure that never reached the command dispatcher.</summary>
/// <param name="ACode">Stable machine-readable error code.</param>
/// <param name="AMessage">Human-readable message (embedded double quotes are replaced with single quotes).</param>
/// <param name="AId">The request's <c>id</c>, echoed so the caller can correlate the reply; 0 when the id is not knowable.</param>
/// <returns>A one-line JSON object: <c>{"id":…,"ok":false,"error":{"code":…,"message":…}}</c>.</returns>
/// <remarks>
///   the <c>id</c> used to be omitted entirely here, so a caller that matches replies to
///   requests by id could not match ANY authentication or parse failure — the two failures it
///   most needs to attribute to a particular request. Every reply now carries the field, and
///   <c>ExecuteCommand</c>'s replies always did.
/// </remarks>
function ErrorJSON( const ACode, AMessage: string; AId: Integer = 0 ): string;
begin

  Result            := Format( '{"id":%d,"ok":false,"error":{"code":"%s","message":"%s"}}',
    [ AId, ACode, StringReplace( AMessage, '"', '''', [ rfReplaceAll ] ) ] );

end;

{ ── TServerImpl ─────────────────────────────────────────────────────────── }

constructor TServerImpl.Create( const AAppName: string );
begin

  inherited Create;

  FAppName          := AAppName;
  FToken            := TGuid.NewGuid.ToString;
  FPort             := 0;

  FServer           := TIdTCPServer.Create( nil );
  FServer.OnConnect := DoConnect;
  FServer.OnExecute := DoExecute;

  // Scan for a free loopback port (Port=0 isn't reliably reflected back by Indy).
  for var iTry := 0 to AUTOMATION_PORT_SPAN - 1 do
  begin

    try
      FServer.Active := False;
      FServer.Bindings.Clear;
      var bnd       := FServer.Bindings.Add;
      bnd.IP        := '127.0.0.1';
      bnd.Port      := AUTOMATION_PORT_BASE + iTry;
      FServer.Active := True;
      FPort         := AUTOMATION_PORT_BASE + iTry;
      Break;
    except
      //  Port in use - try the next. Narrowed to Indy's own exception root
      //  (EIdCouldNotBindSocket and EIdSocketError both descend from it), so a
      //  bind failure still advances the scan while a genuine fault - an access
      //  violation, a bad configuration - is no longer disguised as a busy port
      //  and silently retried against 100 addresses.
      on EIdException do ;
    end;
  end;

  if FPort = 0 then
    raise Exception.Create( 'gllAutomationServer: no free loopback port in range' );

  WriteDiscovery;

end;

destructor TServerImpl.Destroy;
begin

  DeleteDiscovery;

  if Assigned( FServer ) then
  begin
    // Deactivate Indy on a helper thread while pumping CheckSynchronize here.
    // A connection thread may be blocked in TThread.Synchronize (HandleLine
    // marshals VCL commands to the main thread); FServer.Active := False waits
    // for that thread to terminate, so calling it directly on the main thread
    // would deadlock — the worker waits for the main thread to service its
    // Synchronize while the main thread waits for the worker to finish. Pumping
    // CheckSynchronize lets the worker drain and terminate. (Stop/finalisation
    // both run on the main thread.)
    if FServer.Active then
    begin
      var LFinished := False;
      var LStopError := '';
      var LStopper  := TThread.CreateAnonymousThread(
        procedure
        begin
          try
            try
              FServer.Active := False;
            except
              //  Deliberately BROAD, and deliberately recorded rather than
              //  merely swallowed. Broad because anything escaping this handler
              //  would skip the assignment below and leave the loop that waits
              //  on LFinished spinning for ever - the empty handler was load
              //  bearing, not an oversight. Recorded because a deactivate that
              //  failed used to report success and leave no trace at all.
              on E: Exception do
                LStopError := Format( '%s: %s', [ E.ClassName, E.Message ] );
            end;
          finally
            //  The waiting loop below is released by this, whatever happened.
            LFinished := True;
          end;
        end );
      LStopper.FreeOnTerminate := False;
      LStopper.Start;
      try
        while not LFinished do
          CheckSynchronize( 50 );
        LStopper.WaitFor;
      finally
        LStopper.Free;
      end;

      //  Reported after the join, on the main thread, and through
      //  OutputDebugString rather than the suite logger: Stop and finalisation
      //  both run at shutdown, where the logger may already have gone. The
      //  DBG_* capture tools pick this up.
      if LStopError <> '' then
        OutputDebugString( PChar( 'gllAutomationServer: deactivating the server failed - ' + LStopError ) );
    end;
    FServer.Free;
  end;

  inherited;

end;

procedure TServerImpl.WriteDiscovery;
begin

  var sDir          := DISCOVERY_DIR;
  EnsureDiscoveryDir( sDir ); // restricted DACL on first creation - the file holds the token
  SweepStaleDiscovery( sDir ); // clear advertisements left by hosts that were killed

  FDiscoveryPath    := TPath.Combine( sDir, Format( '%d.json', [ GetCurrentProcessId ] ) );

  var o             := TJSONObject.Create;
  try
    o.AddPair( 'app', FAppName );
    o.AddPair( 'pid', TJSONNumber.Create( GetCurrentProcessId ) );
    o.AddPair( 'port', TJSONNumber.Create( FPort ) );
    o.AddPair( 'token', FToken );
    o.AddPair( 'started', DateToISO8601( Now, False ) ); // Now is local; AInputIsUTC defaults True and would stamp a false 'Z'
    TFile.WriteAllText( FDiscoveryPath, o.ToJSON, TEncoding.UTF8 );
  finally
    o.Free;
  end;

end;

procedure TServerImpl.DeleteDiscovery;
begin

  if ( FDiscoveryPath <> '' ) and TFile.Exists( FDiscoveryPath ) then
    try
      TFile.Delete( FDiscoveryPath );
    except
      //  Best-effort cleanup of the discovery advertisement. TFile.Delete raises
      //  EInOutError when the file is locked, ACL-denied or already gone, and
      //  none of those is worth failing shutdown over. Narrowed deliberately, so
      //  a programming error - a bad path, an access violation - still escapes
      //  instead of being absorbed here.
      on EInOutError do ;
    end;

end;

procedure TServerImpl.DoConnect( AContext: TIdContext );
begin

  //  see MAX_REQUEST_BYTES. Set per connection, because the IOHandler is per connection.
  AContext.Connection.IOHandler.MaxLineLength := MAX_REQUEST_BYTES;
  AContext.Connection.IOHandler.MaxLineAction := maException;

end;

procedure TServerImpl.DoExecute( AContext: TIdContext );
begin

  var sLine         := '';
  try
    sLine           := AContext.Connection.IOHandler.ReadLn( IndyTextEncoding_UTF8 );
  except
    //  an over-long request line. Answer it, then drop the connection: the remainder of
    //  that line is still in the buffer and anything read from it now would be a fragment
    //  masquerading as the next request - which is precisely the confusion maSplit causes.
    on EIdReadLnMaxLineLengthExceeded do
    begin
      AContext.Connection.IOHandler.WriteLn(
        ErrorJSON( 'RequestTooLong', Format( 'request line exceeds %d bytes', [ MAX_REQUEST_BYTES ] ) ),
        IndyTextEncoding_UTF8 );
      AContext.Connection.Disconnect;
      Exit;
    end;
  end;

  if sLine = '' then Exit;

  var sResp         := HandleLine( sLine );
  try
    AContext.Connection.IOHandler.WriteLn( sResp, IndyTextEncoding_UTF8 );
  finally
    //  close's reply is on the wire (or the caller has gone): only now may the app start closing
    if TInterlocked.Exchange( FCloseRequested, 0 ) = 1 then
      TThread.Queue( nil,
        procedure
        begin
          if Assigned( Application.MainForm ) then
            Application.MainForm.Close
          else
            Application.Terminate; // ends Application.Run
        end );
  end;

end;

/// <summary>
///   Keeps a driven app alive: disables any inactivity idle-timer on every open
///   form so it can't auto-close mid-test. Matched by class name (<c>*IdleTimer*</c>,
///   e.g. <c>TZylIdleTimer</c>) via RTTI, so this unit needs no dependency on the
///   timer's unit. Idempotent; called on the main thread before each VCL command,
///   so it catches the login form's timer and the MainForm's once it exists — no
///   per-app MainForm change needed. Only ever runs under <c>/AUTOMATION</c>.
/// </summary>
/// <remarks>
///   Called before every main-thread command, including a registered one. The IDE's copy of
///   this server keeps the routine but must never call it: inside bds.exe the sweep could only
///   switch off an Enabled that belongs to a third-party plug-in, and never put it back.
/// </remarks>
procedure DisableIdleTimers;
begin

  for var iFrm := 0 to Screen.FormCount - 1 do
  begin
    var oForm       := Screen.Forms[ iFrm ];
    for var iC := 0 to oForm.ComponentCount - 1 do
    begin
      var oComp     := oForm.Components[ iC ];
      if ( Pos( 'IDLETIMER', UpperCase( oComp.ClassName ) ) > 0 ) and IsPublishedProp( oComp, 'Enabled' ) then
        SetPropValue( oComp, 'Enabled', False );
    end;
  end;

end;

function TServerImpl.HandleLine( const ALine: string ): string;
begin

  // Parse defensively: valid-JSON-but-not-an-object input (array/number/string)
  // makes `as TJSONObject` raise EInvalidCast AND leak the parsed value. Test the
  // type instead and free the non-object value on the reject path.
  var oVal          := TJSONObject.ParseJSONValue( ALine );
  if oVal is not TJSONObject then
  begin
    oVal.Free; // no-op if nil; frees a non-object JSON value otherwise
    Exit( ErrorJSON( 'BadRequest', 'invalid JSON' ) );
  end;

  var oReq          := TJSONObject( oVal );
  try
    //  every envelope read below goes through TJSONValue.AsType<T>, which RAISES
    //  EJSONException when the value is present but of the wrong type - {"id":"abc"} is enough.
    //  Unhandled, that exception left ExecuteCommand's freshly created result object behind,
    //  was re-raised on this worker thread by TThread.Synchronize, escaped past the try..finally
    //  below and reached Indy, which closed the socket. The caller saw a dropped connection
    //  instead of an error, which reads as the server having crashed. Nothing in this routine
    //  may now escape without a reply.
    var iId         := 0;
    oReq.TryGetValue<Integer>( 'id', iId ); // a non-numeric id simply leaves iId at 0

    var sToken      := '';
    oReq.TryGetValue<string>( 'token', sToken );
    if sToken <> FToken then
      Exit( ErrorJSON( 'Unauthorised', 'bad or missing token', iId ) );

    var sResp       := '';

    // 'dialogs' and 'screenshot' are Win32/GDI-only and MUST run on this
    // (background) thread: the main thread may be blocked inside a modal dialog
    // loop that never pumps CheckSynchronize, which would deadlock
    // TThread.Synchronize (and we still want to see/answer that dialog). 'keys'
    // runs here too: it synchronises only its start, then WAITS for the main thread
    // to deliver the keystrokes, which it could not do while occupying that thread.
    // Every other command touches the VCL and is marshalled to the main thread.
    var sPeekCmd    := '';
    oReq.TryGetValue<string>( 'cmd', sPeekCmd );

    //  whatever happens inside the marshalled block is reported as a response. An
    //  exception crossing TThread.Synchronize is re-raised HERE, on the worker thread, so
    //  catching it here covers the main-thread body as well as this one.
    try

      //  a registered command declares its own thread. One that waits on the main thread
      //  (a debugger step, say) has to run here, since waiting there would block what it awaits.
      var rReg: TRegisteredCommand;
      var bOnWorker := SameText( sPeekCmd, 'dialogs' ) or SameText( sPeekCmd, 'screenshot' ) or
        SameText( sPeekCmd, 'keys' ) or ( FindRegisteredCommand( sPeekCmd, rReg ) and ( rReg.Thread = actWorkerThread ) );

      if bOnWorker then
      begin
        var oResp   := ExecuteCommand( oReq );
        try
          sResp     := oResp.ToJSON;
        finally
          oResp.Free;
        end;
      end
      else
        TThread.Synchronize( nil,
          procedure
          begin
            if GDisableIdleTimers then
              DisableIdleTimers; // keep the app alive while an agent drives it
            var oResp := ExecuteCommand( oReq );
            try
              sResp := oResp.ToJSON;
            finally
              oResp.Free;
            end;
          end );

    except
      //  Deliberately BROAD, and deliberately reported rather than swallowed. Broad because the
      //  contract is that a request always gets a reply, and the alternative is the silent
      //  disconnect described above; reported because the class name and message are the only
      //  evidence a caller would otherwise have of a bridge fault.
      on E: Exception do
        Exit( ErrorJSON( 'Internal', Format( '%s: %s', [ E.ClassName, E.Message ] ), iId ) );
    end;

    Result          := sResp;
  finally
    oReq.Free;
  end;

end;

{ ── Phase-2 drive / introspect helpers ──────────────────────────────────── }

constructor EAutoError.CreateCode( const ACode, AMsg: string );
begin

  inherited Create( AMsg );
  Code              := ACode;

end;

constructor EAutoError.CreateCodeData( const ACode, AMsg: string; AData: TJSONValue );
begin

  inherited Create( AMsg );
  Code              := ACode;
  Data              := AData;

end;

destructor EAutoError.Destroy;
begin

  Data.Free;

  inherited;

end;

/// <summary>
///   Resolves the target form from the request's optional <c>"form"</c> key:
///   '' / 'main' → <c>Application.MainForm</c>; 'active' → <c>Screen.ActiveForm</c>;
///   otherwise the open form whose <c>Name</c> matches.
/// </summary>
/// <param name="AReq">The request object.</param>
/// <returns>The resolved form.</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>NoForm</c> when no matching form exists.</remarks>
function AutoResolveForm( AReq: TJSONObject ): TForm;
begin

  var sForm         := AReq.GetValue<string>( 'form', '' );

  if ( sForm = '' ) or SameText( sForm, 'main' ) then
  begin
    Result          := Application.MainForm;
    if Result = nil then
      raise EAutoError.CreateCode( 'NoForm', 'no main form yet (the app may still be at login)' );
    Exit;
  end;

  if SameText( sForm, 'active' ) then
  begin
    Result          := Screen.ActiveForm;
    if Result = nil then
      raise EAutoError.CreateCode( 'NoForm', 'no active form' );
    Exit;
  end;

  for var i := 0 to Screen.FormCount - 1 do
    if SameText( Screen.Forms[ i ].Name, sForm ) then
      Exit( Screen.Forms[ i ] );

  raise EAutoError.CreateCode( 'NoForm', 'form not found: ' + sForm );

end;

/// <summary>
///   Every component reachable from <paramref name="ARoot"/>, in a fixed order: the components it owns
///   directly, then what those own (a frame's controls, recursively), then - for a windowed root -
///   controls PARENTED inside it that nothing in the first two passes owns (an add-in's frame docked
///   into a form it does not belong to). Each component appears once.
/// </summary>
/// <param name="ARoot">The form, or a container a path has already resolved to.</param>
/// <returns>The components; the first <c>ARoot.ComponentCount</c> are its directly owned ones, in <c>Components</c> order.</returns>
/// <remarks>The order is what makes synthetic names (<c>@TClass#N</c>) stable: direct ownership comes first, so a form's own unnamed components keep their numbers whatever is docked into it.</remarks>
function EnumReachable( ARoot: TComponent ): TArray<TComponent>;
begin

  // Both closures recurse through these variables, so the closure frame refers to itself; they are
  // cleared in the finally to break that cycle, or the frame - and the dictionary it captured - leaks.
  var AddOwned: TProc<TComponent>     := nil;
  var AddParented: TProc<TWinControl> := nil;
  var oList         := TList<TComponent>.Create;
  var oSeen         := TDictionary<TComponent, Boolean>.Create;
  try
    AddOwned        :=
      procedure( AOwner: TComponent )
      begin
        for var i := 0 to AOwner.ComponentCount - 1 do
        begin
          var oComp := AOwner.Components[ i ];
          if oSeen.ContainsKey( oComp ) then Continue;
          oSeen.Add( oComp, True );
          oList.Add( oComp );
          AddOwned( oComp );
        end;
      end;

    AddParented     :=
      procedure( AParent: TWinControl )
      begin
        for var i := 0 to AParent.ControlCount - 1 do
        begin
          var oCtl  := AParent.Controls[ i ];
          if not oSeen.ContainsKey( oCtl ) then
          begin
            oSeen.Add( oCtl, True );
            oList.Add( oCtl );
            AddOwned( oCtl ); // a docked frame's own controls
          end;
          if oCtl is TWinControl then
            AddParented( TWinControl( oCtl ) );
        end;
      end;

    // Pass 1 on its own, so the directly owned components lead the list in Components order.
    for var i := 0 to ARoot.ComponentCount - 1 do
    begin
      oSeen.Add( ARoot.Components[ i ], True );
      oList.Add( ARoot.Components[ i ] );
    end;
    for var i := 0 to ARoot.ComponentCount - 1 do
      AddOwned( ARoot.Components[ i ] );
    if ARoot is TWinControl then
      AddParented( TWinControl( ARoot ) );

    Result          := oList.ToArray;
  finally
    AddOwned        := nil;
    AddParented     := nil;
    oSeen.Free;
    oList.Free;
  end;

end;

/// <summary>Synthetic names for the unnamed components in a list: <c>@TClass#N</c>, numbered per class in list order from 1.</summary>
/// <param name="AComps">The components, as returned by <c>EnumReachable</c>.</param>
/// <returns>One entry per component: its synthetic name, or empty for a named component.</returns>
function SyntheticNames( const AComps: TArray<TComponent> ): TArray<string>;
begin

  SetLength( Result, Length( AComps ) );
  var oCounts       := TDictionary<string, Integer>.Create;
  try
    for var i := 0 to High( AComps ) do
    begin
      if AComps[ i ].Name <> '' then Continue;
      var sClass    := AComps[ i ].ClassName;
      var iNumber   := 0;
      oCounts.TryGetValue( sClass, iNumber );
      Inc( iNumber );
      oCounts.AddOrSetValue( sClass, iNumber );
      Result[ i ]   := Format( '@%s#%d', [ sClass, iNumber ] );
    end;
  finally
    oCounts.Free;
  end;

end;

/// <summary>The <c>name</c> value that resolves to a component from its form: its own name if that is all it needs, else a dotted path of named owners (or, failing that, named parents) leading to it.</summary>
/// <param name="AComp">The component.</param>
/// <param name="AForm">The form it is reached from.</param>
/// <param name="ASynthetic">Its synthetic name, used when it has no name of its own.</param>
/// <returns>The path, e.g. <c>Edit1</c>, <c>fraAddress.edtTown</c>, <c>@TButton#2</c>.</returns>
function CompPath( AComp: TComponent; AForm: TForm; const ASynthetic: string ): string;
begin

  if AComp.Name = '' then Exit( ASynthetic );
  if AComp.Owner = AForm then Exit( AComp.Name );

  Result            := AComp.Name;

  // Owned somewhere inside the form (a frame's control): the chain of named owners.
  var oOwner        := AComp.Owner;
  var sChain        := '';
  while ( oOwner <> nil ) and ( oOwner <> AForm ) do
  begin
    if oOwner.Name <> '' then sChain := oOwner.Name + '.' + sChain;
    oOwner          := oOwner.Owner;
  end;
  if oOwner = AForm then Exit( sChain + Result );

  // Owned outside it and only parented in (a docked add-in frame): the chain of named parents.
  if AComp is TControl then
  begin
    sChain          := '';
    var oParent     := TControl( AComp ).Parent;
    while ( oParent <> nil ) and ( oParent <> AForm ) do
    begin
      if oParent.Name <> '' then sChain := oParent.Name + '.' + sChain;
      oParent       := oParent.Parent;
    end;
    Result          := sChain + Result;
  end;

end;

/// <summary>Finds one name inside a container: what it owns directly first, then anything reachable from it (<c>EnumReachable</c>).</summary>
/// <param name="AContainer">The form, or a component an earlier path step resolved to.</param>
/// <param name="AName">The component name.</param>
/// <param name="AForm">The form, for the candidate paths an ambiguity reports.</param>
/// <returns>The component.</returns>
/// <remarks>Raises <c>EAutoError</c> - Code <c>NoComp</c> when nothing matches; <c>Ambiguous</c> (with <c>error.data.candidates</c>, the paths that would each resolve) when several do.</remarks>
function FindReachable( AContainer: TComponent; const AName: string; AForm: TForm ): TComponent;
begin

  Result            := AContainer.FindComponent( AName );
  if Result <> nil then Exit;

  var aMatches: TArray<TComponent> := nil;
  for var oComp in EnumReachable( AContainer ) do
    if SameText( oComp.Name, AName ) then
      aMatches      := aMatches + [ oComp ];

  if Length( aMatches ) = 1 then Exit( aMatches[ 0 ] );

  if Length( aMatches ) = 0 then
    raise EAutoError.CreateCode( 'NoComp', Format( 'component "%s" not found on %s', [ AName, AContainer.Name ] ) );

  var oData         := TJSONObject.Create;
  var oCands        := TJSONArray.Create;
  oData.AddPair( 'candidates', oCands );
  for var oComp in aMatches do
    oCands.Add( CompPath( oComp, AForm, '' ) );
  raise EAutoError.CreateCodeData( 'Ambiguous', Format( '%d components are named "%s" on %s - name one by a path from ' +
    'error.data.candidates', [ Length( aMatches ), AName, AForm.Name ] ), oData );

end;

/// <summary>
///   Resolves a component by the request's <c>"name"</c> key; an empty name targets the form itself.
///   Accepts a plain name (owned by the form, else anywhere reachable from it - inside a frame, or a
///   control docked in without being owned), a dotted path whose steps narrow it
///   (<c>fraAddress.edtTown</c>), or the synthetic name <c>app_tree</c> gives an unnamed component
///   (<c>@TButton#2</c>).
/// </summary>
/// <param name="AReq">The request object.</param>
/// <param name="AForm">The form to search.</param>
/// <returns>The component, or <paramref name="AForm"/> when no name is supplied.</returns>
/// <remarks>Raises <c>EAutoError</c> - Code <c>NoComp</c> when nothing matches; <c>Ambiguous</c> when a plain name matches several (the reply lists a path for each).</remarks>
function AutoResolveComp( AReq: TJSONObject; AForm: TForm ): TComponent;
begin

  var sName         := AReq.GetValue<string>( 'name', '' );
  if sName = '' then Exit( AForm );

  // The common case, and the only one before 0.10: owned by the form under that exact name.
  Result            := AForm.FindComponent( sName );
  if Result <> nil then Exit;

  if sName.StartsWith( '@' ) then
  begin
    var aComps      := EnumReachable( AForm );
    var aSynth      := SyntheticNames( aComps );
    for var i := 0 to High( aComps ) do
      if SameText( aSynth[ i ], sName ) then
        Exit( aComps[ i ] );
    raise EAutoError.CreateCode( 'NoComp', Format( 'no unnamed component "%s" on %s - app_tree lists the synthetic names',
      [ sName, AForm.Name ] ) );
  end;

  Result            := AForm;
  for var sStep in sName.Split( [ '.' ] ) do
  begin
    if sStep = '' then
      raise EAutoError.CreateCode( 'NoComp', Format( '"%s" has an empty step', [ sName ] ) );
    Result          := FindReachable( Result, sStep, AForm );
  end;

end;

/// <summary>Converts a Variant to a JSON value, typed where the variant carries enough information (bool / number / string / null).</summary>
/// <param name="V">The source value.</param>
/// <returns>A new <c>TJSONValue</c>.</returns>
function VarToJSON( const V: Variant ): TJSONValue;
begin

  case VarType( V ) and varTypeMask of
    varEmpty, varNull:
      Result        := TJSONNull.Create;
    varBoolean:
      Result        := TJSONBool.Create( V );
    varShortInt, varByte, varWord, varSmallint, varInteger, varLongWord, varInt64, varUInt64:
      Result        := TJSONNumber.Create( Int64( V ) );
    varSingle, varDouble, varCurrency:
      Result        := TJSONNumber.Create( Double( V ) );
  else
    Result          := TJSONString.Create( VarToStr( V ) );
  end;

end;

/// <summary>Converts a JSON value to a Variant suitable for <c>SetPropValue</c> (which then coerces it to the property type).</summary>
/// <param name="V">The source JSON value (may be nil).</param>
/// <returns>The Variant: Null / Boolean / Int64 / Double / string.</returns>
function JSONToVar( V: TJSONValue ): Variant;
begin

  if ( V = nil ) or ( V is TJSONNull ) then
    Result          := Null
  else if V is TJSONBool then
    Result          := TJSONBool( V ).AsBoolean
  else if V is TJSONNumber then
  begin
    var d           := TJSONNumber( V ).AsDouble;
    Result          := if Frac( d ) = 0 then Int64( Trunc( d ) ) else d;
  end
  else
    Result          := V.Value;

end;

/// <summary>Builds a compact JSON description of one component: name, class, and the safe subset of published props it actually exposes.</summary>
/// <param name="AComp">The component to describe.</param>
/// <param name="AName">The name to report: its own, or its synthetic <c>@TClass#N</c> when it has none.</param>
/// <param name="APath">The <c>name</c> value that resolves to it; reported as <c>path</c> only when it differs from <paramref name="AName"/>.</param>
/// <returns>A new <c>{ name, class, path?, props }</c> object.</returns>
function CompToJSON( AComp: TComponent; const AName, APath: string ): TJSONObject;
const
  PROPS             : array[ 0..9 ] of string =
    ( 'Caption', 'Text', 'Visible', 'Enabled', 'Checked', 'ItemIndex',
    'Left', 'Top', 'Width', 'Height' );
begin

  Result            := TJSONObject.Create;
  Result.AddPair( 'name', AName );
  Result.AddPair( 'class', AComp.ClassName );
  if APath <> AName then
    Result.AddPair( 'path', APath );

  var oProps        := TJSONObject.Create;
  for var sP in PROPS do
    if IsPublishedProp( AComp, sP ) then
      oProps.AddPair( sP, VarToJSON( GetPropValue( AComp, sP ) ) );
  Result.AddPair( 'props', oProps );

end;

{ ── Phase-2 commands ────────────────────────────────────────────────────── }

/// <summary>
///   <c>tree</c> command: with no <c>"form"</c> key, a shallow list of all open forms; with a
///   <c>"form"</c>, that form's owned components (one level) with their key props - and with
///   <c>"deep":true</c>, also everything reachable beyond them (a frame's controls, controls docked
///   in without being owned). An unnamed component is reported under its synthetic name
///   (<c>@TClass#N</c>), and one a plain name does not reach carries the <c>path</c> that does.
/// </summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>deep?</c>).</param>
/// <returns><c>{ forms:[…] }</c> or <c>{ form, class, components:[…] }</c>.</returns>
function AutoCmdTree( AReq: TJSONObject ): TJSONValue;
begin

  //  Throughout: the container is created and PARENTED FIRST, then filled. Built the
  //  other way round, an exception part-way through the loop - CompToJSON reads live published
  //  properties, so a getter can raise - abandoned an array that nothing owned yet, and the
  //  caller never got the object either, because the assignment to Result had not happened.
  var oRes          := TJSONObject.Create;
  try

    if AReq.GetValue<string>( 'form', '' ) = '' then
    begin
      var oForms    := TJSONArray.Create;
      oRes.AddPair( 'forms', oForms );
      for var i := 0 to Screen.FormCount - 1 do
      begin
        var oFrm    := TJSONObject.Create;
        oForms.AddElement( oFrm );
        oFrm.AddPair( 'name', Screen.Forms[ i ].Name );
        oFrm.AddPair( 'class', Screen.Forms[ i ].ClassName );
        oFrm.AddPair( 'visible', TJSONBool.Create( Screen.Forms[ i ].Visible ) );
      end;
      Exit( oRes );
    end;

    var oForm       := AutoResolveForm( AReq );
    oRes.AddPair( 'form', oForm.Name );
    oRes.AddPair( 'class', oForm.ClassName );

    var oComps      := TJSONArray.Create;
    oRes.AddPair( 'components', oComps );

    // Synthetic names are numbered over everything reachable even when only the owned components are
    // listed, so a name read here resolves the same way in every other command.
    var aComps      := EnumReachable( oForm );
    var aSynth      := SyntheticNames( aComps );
    var iCount      := if AReq.GetValue<Boolean>( 'deep', False ) then Length( aComps ) else oForm.ComponentCount;
    for var i := 0 to iCount - 1 do
    begin
      var sName     := if aComps[ i ].Name <> '' then aComps[ i ].Name else aSynth[ i ];
      oComps.AddElement( CompToJSON( aComps[ i ], sName, CompPath( aComps[ i ], oForm, aSynth[ i ] ) ) );
    end;

    Result          := oRes;

  except
    oRes.Free;
    raise;
  end;

end;

/// <summary>Reads an object-typed published property, treating a getter that raises as unassigned.</summary>
/// <param name="AObj">The instance.</param>
/// <param name="AProp">The property.</param>
/// <returns>The object, or <c>nil</c> when it is unassigned or its getter raised.</returns>
function ObjectPropOrNil( AObj: TObject; AProp: PPropInfo ): TObject;
begin

  try
    Result          := GetObjectProp( AObj, AProp );
  except
    on E: Exception do
      Result        := nil; // listed as absent, exactly as an unassigned object is
  end;

end;

/// <summary>
///   Enumerates an object's published properties as
///   <c>{ properties:[ { name, type, value? } ], total, truncated }</c> — the payload
///   attached to a <c>NoProp</c> failure so the caller learns the real property surface
///   (with live values) from the failed call instead of guessing again.
/// </summary>
/// <param name="AObj">The component or form to enumerate.</param>
/// <param name="AWritableOnly">True to list only properties that have a setter (the <c>set</c> command's view).</param>
/// <returns>A new object; the array is capped at <c>PROPLIST_MAX</c> entries with <c>truncated</c> set.</returns>
/// <remarks>
///   Only properties <c>get</c>/<c>set</c> can act on are listed. Scalar ones carry their
///   value, read under its own guard since a getter may raise. Assigned object-typed ones
///   (<c>Font</c>, <c>Lines</c>) carry <c>nested:true</c> and no value: a dotted path reaches
///   into them. Events, interface and array properties are left out.
/// </remarks>
function PropsJSON( AObj: TObject; AWritableOnly: Boolean ): TJSONObject;
const
  VALUE_KINDS       = [ tkInteger, tkChar, tkEnumeration, tkFloat, tkString, tkSet,
    tkWChar, tkLString, tkWString, tkVariant, tkInt64, tkUString ];
begin

  Result            := TJSONObject.Create;

  var oProps        := TJSONArray.Create;
  var iTotal        := 0;
  var pList: PPropList;
  var iCount        := GetPropList( AObj, pList );
  try
    for var i := 0 to iCount - 1 do
    begin
      var pProp     := pList^[ i ];

      // An object-typed property (TFont, TMargins, TStrings…) is listed WITHOUT a value and flagged
      // nested: get/set reach into it with a dotted path (Font.Size), and a TStrings one reads
      // and writes as its text. Assigned ones only - a nil object has nothing to reach.
      if pProp^.PropType^.Kind = tkClass then
      begin
        if ( pProp^.GetProc = nil ) or ( ObjectPropOrNil( AObj, pProp ) = nil ) then Continue;
        Inc( iTotal );
        if oProps.Count >= PROPLIST_MAX then Continue;
        var oNested := TJSONObject.Create;
        oNested.AddPair( 'name', string( pProp^.Name ) );
        oNested.AddPair( 'type', string( pProp^.PropType^.Name ) );
        oNested.AddPair( 'nested', TJSONBool.Create( True ) );
        oProps.AddElement( oNested );
        Continue;
      end;

      // Otherwise list only what get/set can act on as a scalar. Events, interface and array
      // properties are neither readable as a value nor writable through SetPropValue - listing
      // them is pure noise in a payload the caller pays for by the token.
      if pProp^.PropType^.Kind not in VALUE_KINDS then Continue;
      if pProp^.GetProc = nil then Continue;
      if AWritableOnly and ( pProp^.SetProc = nil ) then Continue;

      Inc( iTotal );
      if oProps.Count >= PROPLIST_MAX then Continue; // keep counting, stop listing

      var oEntry    := TJSONObject.Create;
      oEntry.AddPair( 'name', string( pProp^.Name ) );
      oEntry.AddPair( 'type', string( pProp^.PropType^.Name ) );

      try
        oEntry.AddPair( 'value', VarToJSON( GetPropValue( AObj, string( pProp^.Name ) ) ) );
      except
        // A getter that raises must not sink the whole listing - report that one as null.
        on E: Exception do
          oEntry.AddPair( 'value', TJSONNull.Create );
      end;

      oProps.AddElement( oEntry );
    end;
  finally
    if iCount > 0 then FreeMem( pList );
  end;

  Result.AddPair( 'properties', oProps );
  Result.AddPair( 'total', TJSONNumber.Create( iTotal ) );
  Result.AddPair( 'truncated', TJSONBool.Create( iTotal > oProps.Count ) );

end;

/// <summary>Builds the <c>NoProp</c> failure for a component, carrying its property surface as <c>error.data</c>.</summary>
/// <param name="AObj">The component or form the property was looked for on.</param>
/// <param name="AName">The component name to quote in the message.</param>
/// <param name="AProp">The property name that was not found.</param>
/// <param name="AWritableOnly">True when the caller was writing (list only settable properties).</param>
/// <returns>The exception to raise (never nil).</returns>
function NoPropError( AObj: TObject; const AName, AProp: string; AWritableOnly: Boolean ): EAutoError;
begin

  var sWhich        := 'published';
  if AWritableOnly then sWhich := 'writable';

  Result            := EAutoError.CreateCodeData( 'NoProp',
    Format( '%s has no published property "%s" - error.data.properties lists its %s properties with their live values',
      [ AName, AProp, sWhich ] ),
    PropsJSON( AObj, AWritableOnly ) );

end;

type
  /// <summary>How a resolved property path is read and written.</summary>
  TPropAccess = (
    /// <summary>A published scalar property, through <c>GetPropValue</c> / <c>SetPropValue</c>.</summary>
    paPublished,
    /// <summary>A <c>TStrings</c> object, as its <c>Text</c>.</summary>
    paStringsText,
    /// <summary>A <c>TStrings</c> object's <c>Count</c> (read-only).</summary>
    paStringsCount,
    /// <summary>A control's window text through <c>GetTextBuf</c> / <c>SetTextBuf</c>: <c>Text</c> or <c>Caption</c> where the class does not publish it (<c>TMemo.Text</c>).</summary>
    paControlText );

  /// <summary>A property path resolved to the object that holds the final property, and how to reach it.</summary>
  TPropTarget = record
    /// <summary>The object the final step is read from or written to.</summary>
    Obj: TObject;
    /// <summary>The final property name (for <c>paPublished</c>).</summary>
    Prop: string;
    /// <summary>How the value is read and written.</summary>
    Access: TPropAccess;
  end;

/// <summary>
///   Resolves a property path on a component: <c>Caption</c>, or dotted through object-typed
///   properties - <c>Font.Size</c>, <c>Margins.Left</c>, <c>Lines.Text</c>. A <c>TStrings</c>
///   reads and writes as its text, whether named on its own (<c>Lines</c>) or as <c>Lines.Text</c>;
///   <c>Lines.Count</c> reads its count. <c>Text</c> / <c>Caption</c> on a control that does not
///   publish them fall back to its window text, so <c>TMemo.Text</c> is reachable.
/// </summary>
/// <param name="AComp">The component the path starts from.</param>
/// <param name="APath">The property path.</param>
/// <param name="AWriting">True for <c>set</c>: a <c>NoProp</c> failure then lists writable properties.</param>
/// <returns>The resolved target.</returns>
/// <remarks>
///   Raises <c>EAutoError</c> - Code <c>NoProp</c> (with the property surface of the object where the
///   step failed in <c>error.data</c>); <c>NotObject</c> (a dotted step through a scalar);
///   <c>NilObject</c> (a step through an unassigned object); <c>NotScalar</c> (the path ends on an
///   object that is not a <c>TStrings</c> - its properties are in <c>error.data</c>).
/// </remarks>
function ResolvePropPath( AComp: TComponent; const APath: string; AWriting: Boolean ): TPropTarget;
begin

  var aSteps        := APath.Split( [ '.' ] );
  if ( Length( aSteps ) = 0 ) or ( APath = '' ) then
    raise NoPropError( AComp, AComp.Name, APath, AWriting );

  var oObj: TObject := AComp;
  var sWhere        := AComp.Name;

  for var i := 0 to High( aSteps ) - 1 do
  begin
    var sStep       := aSteps[ i ];
    if ( oObj is TStrings ) or not IsPublishedProp( oObj, sStep ) then
      raise NoPropError( oObj, sWhere, sStep, AWriting );
    if PropType( oObj, sStep ) <> tkClass then
      raise EAutoError.CreateCode( 'NotObject', Format( '%s.%s is not an object, so it has no "%s"',
        [ sWhere, sStep, aSteps[ i + 1 ] ] ) );
    var oNext       := GetObjectProp( oObj, sStep );
    if oNext = nil then
      raise EAutoError.CreateCode( 'NilObject', Format( '%s.%s is not assigned', [ sWhere, sStep ] ) );
    oObj            := oNext;
    sWhere          := sWhere + '.' + sStep;
  end;

  var sLast         := aSteps[ High( aSteps ) ];
  Result.Obj        := oObj;
  Result.Prop       := sLast;
  Result.Access     := paPublished;

  if oObj is TStrings then
  begin
    if SameText( sLast, 'Text' ) then
      Result.Access := paStringsText
    else if SameText( sLast, 'Count' ) then
      Result.Access := paStringsCount
    else
      raise EAutoError.CreateCode( 'NoProp', Format( '%s is a string list: read or write it whole, or name Text or Count', [ sWhere ] ) );
    Exit;
  end;

  if IsPublishedProp( oObj, sLast ) then
  begin
    if PropType( oObj, sLast ) <> tkClass then Exit;

    var oValue      := GetObjectProp( oObj, sLast );
    if oValue is TStrings then
    begin
      Result.Obj    := oValue;
      Result.Access := paStringsText;
      Exit;
    end;

    if oValue = nil then
      raise EAutoError.CreateCode( 'NilObject', Format( '%s.%s is not assigned', [ sWhere, sLast ] ) );
    raise EAutoError.CreateCodeData( 'NotScalar', Format( '%s.%s is an object (%s): name one of its properties, e.g. %s.<Prop> - ' +
      'error.data.properties lists them', [ sWhere, sLast, oValue.ClassName, sLast ] ), PropsJSON( oValue, AWriting ) );
  end;

  if ( oObj is TControl ) and ( SameText( sLast, 'Text' ) or SameText( sLast, 'Caption' ) ) then
  begin
    Result.Access   := paControlText;
    Exit;
  end;

  raise NoPropError( oObj, sWhere, sLast, AWriting );

end;

/// <summary>Reads a resolved property target.</summary>
/// <param name="ATarget">The target from <c>ResolvePropPath</c>.</param>
/// <returns>The value.</returns>
function ReadPropTarget( const ATarget: TPropTarget ): Variant;
begin

  case ATarget.Access of
    paStringsText:
      Result        := TStrings( ATarget.Obj ).Text;
    paStringsCount:
      Result        := TStrings( ATarget.Obj ).Count;
    paControlText:
    begin
      var oCtl      := TControl( ATarget.Obj );
      var sBuf      := '';
      SetLength( sBuf, oCtl.GetTextLen + 1 );
      SetLength( sBuf, oCtl.GetTextBuf( PChar( sBuf ), Length( sBuf ) ) );
      Result        := sBuf;
    end;
  else
    Result          := GetPropValue( ATarget.Obj, ATarget.Prop );
  end;

end;

/// <summary>Writes a resolved property target.</summary>
/// <param name="ATarget">The target from <c>ResolvePropPath</c>.</param>
/// <param name="AValue">The value; text for a string list or a control's window text.</param>
/// <remarks>Raises <c>EAutoError</c> - Code <c>ReadOnlyProp</c> for a string list's <c>Count</c>.</remarks>
procedure WritePropTarget( const ATarget: TPropTarget; const AValue: Variant );
begin

  case ATarget.Access of
    paStringsText:
      TStrings( ATarget.Obj ).Text := VarToStr( AValue );
    paStringsCount:
      raise EAutoError.CreateCode( 'ReadOnlyProp', 'a string list''s Count is read-only - write its Text' );
    paControlText:
      TControl( ATarget.Obj ).SetTextBuf( PChar( VarToStr( AValue ) ) );
  else
    SetPropValue( ATarget.Obj, ATarget.Prop, AValue );
  end;

end;

/// <summary><c>get</c> command: reads one property of a component (or the form) - a published property, or a dotted path through object-typed ones (<c>Font.Size</c>, <c>Lines</c>).</summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name?</c>, <c>prop</c>).</param>
/// <returns><c>{ name, prop, value }</c>.</returns>
/// <remarks>Raises <c>EAutoError</c> - the codes of <c>ResolvePropPath</c>; <c>NoProp</c> carries the property surface in <c>error.data</c>.</remarks>
function AutoCmdGet( AReq: TJSONObject ): TJSONValue;
begin

  var oForm         := AutoResolveForm( AReq );
  var oComp         := AutoResolveComp( AReq, oForm );
  var sProp         := AReq.GetValue<string>( 'prop', '' );
  var rTarget       := ResolvePropPath( oComp, sProp, False );

  Result            := TJSONObject.Create;
  TJSONObject( Result ).AddPair( 'name', oComp.Name );
  TJSONObject( Result ).AddPair( 'prop', sProp );
  TJSONObject( Result ).AddPair( 'value', VarToJSON( ReadPropTarget( rTarget ) ) );

end;

/// <summary>
///   <c>set</c> command: writes one published property (variant-coerced), then reads it back
///   and reports whether the write actually moved the value.
/// </summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name?</c>, <c>prop</c>, <c>value</c>).</param>
/// <returns><c>{ name, prop, value, previous, changed }</c> — <c>value</c> is the read-back.</returns>
/// <remarks>
///   Raises <c>EAutoError</c> —Code <c>NoProp</c> (carrying the writable-property list in
///   <c>error.data</c>) when the property isn't published.
///   <para>
///   <c>changed:false</c> means the property already held this value, so an <c>OnChange</c>
///   hanging off it almost certainly did NOT fire (VCL setters conventionally guard on
///   equality). The write is still performed rather than elided: a setter may do work even
///   for an unchanged value, and suppressing that would make the bridge lie about what a
///   real assignment does.
///   </para>
/// </remarks>
function AutoCmdSet( AReq: TJSONObject ): TJSONValue;
begin

  var oForm         := AutoResolveForm( AReq );
  var oComp         := AutoResolveComp( AReq, oForm );
  var sProp         := AReq.GetValue<string>( 'prop', '' );
  var rTarget       := ResolvePropPath( oComp, sProp, True );

  // Snapshot first so the reply can say whether this call moved the value or merely
  // restated it - the difference between "I caused that" and "it was already correct".
  var vOld          := Null;
  var bHaveOld      := True;
  try
    vOld            := ReadPropTarget( rTarget );
  except
    on E: Exception do
      bHaveOld      := False; // write-only or raising getter: report unknown, not a failure
  end;

  WritePropTarget( rTarget, JSONToVar( AReq.GetValue( 'value' ) ) );

  var vNew          := ReadPropTarget( rTarget );

  Result            := TJSONObject.Create;
  TJSONObject( Result ).AddPair( 'name', oComp.Name );
  TJSONObject( Result ).AddPair( 'prop', sProp );
  TJSONObject( Result ).AddPair( 'value', VarToJSON( vNew ) );

  if bHaveOld then
  begin
    TJSONObject( Result ).AddPair( 'previous', VarToJSON( vOld ) );
    TJSONObject( Result ).AddPair( 'changed', TJSONBool.Create( VarCompareValue( vOld, vNew ) <> vrEqual ) );
  end;

end;

/// <summary>
///   <c>click</c> command: fires a component's <c>OnClick</c> handler (<c>Sender</c> = the
///   component), or with <c>"mode":"message"</c> posts <c>BM_CLICK</c> to a button-class
///   control instead — the reply is written BEFORE the message loop delivers the click, so
///   a handler that opens a modal dialog cannot block this command (answer the dialog with
///   <c>dialogs</c> afterwards). <c>BM_CLICK</c> drives the full <c>WM_LBUTTONDOWN/UP</c>
///   path, so <c>Action</c>, <c>ModalResult</c> and <c>OnClick</c> all fire as for a real
///   mouse click.
/// </summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name</c>, <c>mode?</c> — <c>direct</c> (default) / <c>message</c>, <c>count?</c> — 1..<c>CLICK_COUNT_MAX</c>).</param>
/// <returns>
///   <c>{ clicked, mode, clicksDispatched }</c>; message mode adds <c>posted:true</c> (the clicks
///   have not yet run when the reply is written). Direct mode adds <c>stoppedReason</c> +
///   <c>stoppedMessage</c> when a handler raised.
/// </returns>
/// <remarks>
///   Raises <c>EAutoError</c> —Code <c>NoOnClick</c> / <c>NoHandler</c> (direct mode: no assigned handler);
///   <c>NotButton</c> (message mode: not a button-class windowed control, e.g. a TSpeedButton);
///   <c>NotClickable</c> (message mode: not visible+enabled — a user could not click it);
///   <c>BadMode</c> (unknown <c>mode</c> value); <c>BadCount</c> (<c>count</c> outside 1..<c>CLICK_COUNT_MAX</c>).
///   <para>
///   EXCEPTION FIREWALL — direct mode invokes the handler inside this command, so anything it
///   raises is caught here (reported as <c>stoppedReason:"exception:&lt;ClassName&gt;"</c>) and
///   NEVER reaches <c>Application.HandleException</c>. EurekaLog, <c>Application.OnException</c>
///   and any <c>TApplicationEvents.OnException</c> therefore do not fire, and the app shows no
///   error dialog — which reads exactly like "EurekaLog is broken" when in fact it was never
///   invoked. To exercise a global error path, use <c>mode=message</c>: the posted BM_CLICK runs
///   the handler from the app's own message loop, outside this call, so the exception takes the
///   same route it would from a real user click. (Before 0.8 the raise escaped to the generic
///   command handler and came back as code <c>Internal</c>, indistinguishable from a bridge fault
///   — the swallowing is not new, only the reporting.)
///   </para>
/// </remarks>
function AutoCmdClick( AReq: TJSONObject ): TJSONValue;
begin

  var oForm         := AutoResolveForm( AReq );
  var oComp         := AutoResolveComp( AReq, oForm );
  var sMode         := AReq.GetValue<string>( 'mode', 'direct' );
  var iCount        := AReq.GetValue<Integer>( 'count', 1 );

  if ( iCount < 1 ) or ( iCount > CLICK_COUNT_MAX ) then
    raise EAutoError.CreateCode( 'BadCount', Format( 'count %d is outside 1..%d', [ iCount, CLICK_COUNT_MAX ] ) );

  if SameText( sMode, 'message' ) then
  begin
    // Async click: post BM_CLICK and let the reply go out before the message loop
    // delivers it. Only button-class window procedures implement BM_CLICK, so
    // anything else (incl. the unwindowed TSpeedButton) must use direct mode.
    if oComp is not TButtonControl then
      raise EAutoError.CreateCode( 'NotButton',
        Format( '%s (%s) cannot take mode=message: BM_CLICK is only handled by button-class controls', [ oComp.Name, oComp.ClassName ] ) );

    var oBtn        := TButtonControl( oComp );
    // Faithful to a real invocation: a user cannot click a hidden or disabled button.
    if ( not oBtn.Visible ) or ( not oBtn.Enabled ) then
      raise EAutoError.CreateCode( 'NotClickable', oBtn.Name + ' is not visible+enabled' );

    for var i := 1 to iCount do
      if not PostMessage( oBtn.Handle, BM_CLICK, 0, 0 ) then
        RaiseLastOSError;

    Result          := TJSONObject.Create;
    TJSONObject( Result ).AddPair( 'clicked', oComp.Name );
    TJSONObject( Result ).AddPair( 'mode', 'message' );
    TJSONObject( Result ).AddPair( 'posted', TJSONBool.Create( True ) );
    TJSONObject( Result ).AddPair( 'clicksDispatched', TJSONNumber.Create( iCount ) );
    Exit;
  end;

  if not SameText( sMode, 'direct' ) then
    raise EAutoError.CreateCode( 'BadMode', Format( 'unknown click mode "%s" (expected direct / message)', [ sMode ] ) );

  var pInfo         := GetPropInfo( oComp, 'OnClick' );
  if pInfo = nil then
    raise EAutoError.CreateCode( 'NoOnClick', oComp.Name + ' has no OnClick property' );

  var m             := GetMethodProp( oComp, pInfo );
  if not Assigned( m.Code ) then
    raise EAutoError.CreateCode( 'NoHandler', oComp.Name + '.OnClick is not assigned' );

  var oEvent: TNotifyEvent;
  TMethod( oEvent ) := m;

  var iDone         := 0;
  var sStopped      := '';
  var sStopMsg      := '';
  for var i := 1 to iCount do
    try
      oEvent( oComp );
      Inc( iDone );
    except
      // Report the raise instead of letting it reach the generic handler as 'Internal':
      // one failing click must not look like a bridge fault, and must not abort a count run
      // silently. See the EXCEPTION FIREWALL note above - this never reaches EurekaLog.
      on E: Exception do
      begin
        sStopped    := 'exception:' + E.ClassName;
        sStopMsg    := E.Message;
        Break;
      end;
    end;

  Result            := TJSONObject.Create;
  TJSONObject( Result ).AddPair( 'clicked', oComp.Name );
  TJSONObject( Result ).AddPair( 'mode', 'direct' );
  TJSONObject( Result ).AddPair( 'clicksDispatched', TJSONNumber.Create( iDone ) );

  if sStopped <> '' then
  begin
    TJSONObject( Result ).AddPair( 'stoppedReason', sStopped );
    TJSONObject( Result ).AddPair( 'stoppedMessage', sStopMsg );
  end;

end;

/// <summary>
///   <c>action</c> command: executes a <c>TBasicAction</c> named by <c>"name"</c>
///   (or the action assigned to the named control's <c>Action</c> property) by
///   calling <c>Execute</c> — the same path the VCL uses for a menu / toolbar
///   click, so it covers commands that have no clickable control. A disabled
///   action is refused (a user could not trigger it either). Direct invocation:
///   it does NOT first commit the focused edit's <c>OnExit</c> / validation.
/// </summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name</c>).</param>
/// <returns><c>{ executed, fromComponent }</c>.</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>NoAction</c> when the target is neither a <c>TBasicAction</c> nor an action-bearing control; <c>ActionDisabled</c> when the resolved action is disabled.</remarks>
function AutoCmdAction( AReq: TJSONObject ): TJSONValue;
begin

  var oForm         := AutoResolveForm( AReq );
  var oComp         := AutoResolveComp( AReq, oForm );

  var oAction: TBasicAction := nil;
  if oComp is TBasicAction then
    oAction         := TBasicAction( oComp )
  else if IsPublishedProp( oComp, 'Action' ) then
  begin
    var oObj        := GetObjectProp( oComp, 'Action' );
    if oObj is TBasicAction then
      oAction       := TBasicAction( oObj );
  end;

  if oAction = nil then
    raise EAutoError.CreateCode( 'NoAction', oComp.Name + ' is not a TAction and has no assigned Action' );

  // Faithful to a real invocation: a user cannot trigger a disabled action, so refuse it.
  if IsPublishedProp( oAction, 'Enabled' ) then
  begin
    var bEnabled: Boolean := GetPropValue( oAction, 'Enabled' );
    if not bEnabled then
      raise EAutoError.CreateCode( 'ActionDisabled', oAction.Name + ' is disabled' );
  end;

  oAction.Execute;

  Result            := TJSONObject.Create;
  TJSONObject( Result ).AddPair( 'executed', oAction.Name );
  TJSONObject( Result ).AddPair( 'fromComponent', oComp.Name );

end;

{ ── M-D: dialogs (Win32, off the VCL thread) ─────────────────────────────── }

const
  /// <summary>The longest window text read, in characters; a longer one is cut there, and <see cref="WndTextRead"/> says so.</summary>
  MAX_WND_TEXT      = 4096;

/// <summary>
///   Reads a window's text, safely even when the window's owning thread is hung, and says whether it was read in full.
///   <c>GetWindowText</c> / <c>GetWindowTextLength</c> send <c>WM_GETTEXT(LENGTH)</c> to a same-process window with NO
///   timeout, so a hung UI thread would deadlock this worker thread - the exact situation the off-thread
///   <c>dialogs</c> command exists for - so it is read through <c>SendMessageTimeout</c> instead, into a fixed buffer
///   (a length query could hang as well).
/// </summary>
/// <param name="AWnd">The window handle.</param>
/// <param name="ATimeoutMs">How long the owning thread may take to answer.</param>
/// <param name="AText">Receives the text, '' when it could not be read.</param>
/// <param name="ATruncated">Receives True when the text filled the buffer, so it was probably cut at <c>MAX_WND_TEXT</c>.</param>
/// <returns>False when the owning thread did not answer in time.</returns>
function WndTextRead( AWnd: HWND; ATimeoutMs: UINT; out AText: string; out ATruncated: Boolean ): Boolean;
begin

  SetLength( AText, MAX_WND_TEXT );
  var iCopied: DWORD_PTR := 0;
  Result            := SendMessageTimeout( AWnd, WM_GETTEXT, MAX_WND_TEXT, LPARAM( PChar( AText ) ), SMTO_ABORTIFHUNG, ATimeoutMs,
    @iCopied ) <> 0;
  if not Result then
    iCopied         := 0;
  SetLength( AText, iCopied );
  ATruncated        := iCopied >= MAX_WND_TEXT - 1;

end;

/// <summary>Returns a window's caption or a control's text, as <see cref="WndTextRead"/> reads it with a 2 s timeout.</summary>
/// <param name="AWnd">The window handle.</param>
/// <returns>The window text; '' when empty or when the owning thread is hung or times out; cut at <c>MAX_WND_TEXT</c>.</returns>
function WndText( AWnd: HWND ): string;
begin

  var bTruncated: Boolean;
  WndTextRead( AWnd, 2000, Result, bTruncated );

end;

/// <summary>Returns a window's class name (<c>GetClassName</c>) as a Delphi string.</summary>
/// <param name="AWnd">The window handle.</param>
/// <returns>The class name.</returns>
function WndClass( AWnd: HWND ): string;
begin

  SetLength( Result, 256 );
  var iLen          := GetClassName( AWnd, PChar( Result ), 256 );
  SetLength( Result, iLen );

end;

/// <summary><c>EnumWindows</c> callback collecting this process's visible top-level windows into the <c>TList&lt;HWND&gt;</c> passed via <paramref name="AParam"/>.</summary>
/// <param name="AWnd">The enumerated window.</param>
/// <param name="AParam">Pointer to the target <c>TList&lt;HWND&gt;</c>.</param>
/// <returns>Always <c>True</c> to continue enumeration.</returns>
function EnumTopProc( AWnd: HWND; AParam: LPARAM ): BOOL; stdcall;
begin

  Result            := True;

  var iPid: DWORD   := 0;
  GetWindowThreadProcessId( AWnd, iPid );
  if ( iPid = GetCurrentProcessId ) and IsWindowVisible( AWnd ) then
    TList<HWND>( Pointer( AParam ) ).Add( AWnd );

end;

/// <summary><c>EnumChildWindows</c> callback collecting every child window into the <c>TList&lt;HWND&gt;</c> passed via <paramref name="AParam"/>.</summary>
/// <param name="AWnd">The enumerated child window.</param>
/// <param name="AParam">Pointer to the target <c>TList&lt;HWND&gt;</c>.</param>
/// <returns>Always <c>True</c> to continue enumeration.</returns>
function EnumChildProc( AWnd: HWND; AParam: LPARAM ): BOOL; stdcall;
begin

  TList<HWND>( Pointer( AParam ) ).Add( AWnd );
  Result            := True;

end;

/// <summary>Whether a window is of a button class, judged as the listing always has: its class name contains <c>button</c>.</summary>
/// <param name="AWnd">The window.</param>
/// <returns>True for <c>Button</c>, <c>TButton</c>, <c>TBitBtn</c>, a styled button and the like.</returns>
function IsButtonWindow( AWnd: HWND ): Boolean;
begin

  Result            := Pos( 'button', LowerCase( WndClass( AWnd ) ) ) > 0;

end;

/// <summary>
///   Whether clicking a window could have any effect: it and every window it sits in visible and enabled.
///   <c>IsWindowVisible</c> already answers for the whole chain, <c>IsWindowEnabled</c> only for the window
///   asked about, and a button in a window that something modal is on top of is enabled in its own right while
///   a user could not reach it.  The walk stops at the first window that is not a child, because
///   <c>GetParent</c> answers for a top-level window with its OWNER - for a message box, the very window it
///   disabled (GxInspect, <c>GxCanBeClicked</c>).
/// </summary>
/// <param name="AWnd">The window, usually a button.</param>
/// <returns>True when a user could click it.</returns>
function WndCanBeClicked( AWnd: HWND ): Boolean;
begin

  Result            := False;
  if not IsWindowVisible( AWnd ) then Exit;

  var hStep         := AWnd;
  while hStep <> 0 do
  begin
    if not IsWindowEnabled( hStep ) then Exit;
    if ( GetWindowLong( hStep, GWL_STYLE ) and WS_CHILD ) = 0 then Break;
    hStep           := GetParent( hStep );
  end;
  Result            := True;

end;

/// <summary>
///   Whether a top-level window is waiting to be answered: visible, enabled, and either of the dialog class
///   (<c>#32770</c>) or owned by a window it has disabled, which is what modality looks like from outside and
///   catches a VCL message form as well as a Win32 message box (GxInspect).
/// </summary>
/// <param name="AWnd">The top-level window.</param>
/// <returns>True for a modal window a user could answer now.</returns>
/// <remarks>
///   A known limit, kept deliberately: a MODELESS window owned by the window a Win32 message box disabled answers True
///   as well, since from outside it looks the same.  A sharper test (<c>GetLastActivePopup</c> of the owner) depends on
///   which window was activated last, which a script cannot control.  The harm is bounded: <c>dialogs</c> prefers a
///   modal match only when it is the only one, so two such windows are refused as ambiguous, never guessed between.
/// </remarks>
function WndIsModal( AWnd: HWND ): Boolean;
begin

  Result            := False;
  if not ( IsWindowVisible( AWnd ) and IsWindowEnabled( AWnd ) ) then Exit;

  var hOwner        := GetWindow( AWnd, GW_OWNER );
  Result            := ( WndClass( AWnd ) = '#32770' ) or ( ( hOwner <> 0 ) and not IsWindowEnabled( hOwner ) );

end;

/// <summary>
///   The SYSTEM class a window is built on, as <c>RealGetWindowClass</c> names it: <c>Button</c> for a VCL
///   <c>TButton</c>, <c>Static</c> for a <c>TStaticText</c>, and the window's own class for a control that is not built on
///   a system class.
/// </summary>
/// <param name="AWnd">The window.</param>
/// <returns>The class name.</returns>
function WndRealClass( AWnd: HWND ): string;
begin

  SetLength( Result, 256 );
  SetLength( Result, RealGetWindowClass( AWnd, PChar( Result ), 256 ) );

end;

/// <summary>
///   Whether a button window implements <c>BM_CLICK</c>: it is a standard Windows button, or a superclass of one
///   such as the VCL's <c>TButton</c> and <c>TBitBtn</c>.  <c>RealGetWindowClass</c> names the system class a
///   window is built on, so it answers <c>Button</c> for those and the control's own class for a custom-drawn
///   one such as Ethea's <c>TStyledButton</c>, which keeps <c>button</c> in its class name but ignores
///   <c>BM_CLICK</c>.
/// </summary>
/// <param name="AWnd">The button window.</param>
/// <returns>True when <c>BM_CLICK</c> clicks it.</returns>
function WndTakesBmClick( AWnd: HWND ): Boolean;
begin

  Result            := SameText( WndRealClass( AWnd ), 'Button' );

end;

/// <summary>A caption as a button is matched by: without its accelerator ampersands and surrounding space.</summary>
/// <param name="ACaption">The caption.</param>
/// <returns>The plain caption; compare it without case.</returns>
function PlainButtonCaption( const ACaption: string ): string;
begin

  Result            := Trim( StringReplace( ACaption, '&', '', [ rfReplaceAll ] ) );

end;

/// <summary>The button-class children (at any depth) of a window, in enumeration order.</summary>
/// <param name="AWnd">The window.</param>
/// <returns>The button windows; hidden ones included, the caller decides.</returns>
function ButtonWindowsOf( AWnd: HWND ): TArray<HWND>;
begin

  var lst           := TList<HWND>.Create;
  try
    EnumChildWindows( AWnd, @EnumChildProc, LPARAM( Pointer( lst ) ) );
    for var iChild := lst.Count - 1 downto 0 do
      if not IsButtonWindow( lst[ iChild ] ) then
        lst.Delete( iChild );
    Result          := lst.ToArray;
  finally
    lst.Free;
  end;

end;

/// <summary>Builds a JSON array of a window's <i>visible</i> button-class children.</summary>
/// <param name="ADlg">The dialog/window whose buttons to enumerate.</param>
/// <returns>
///   A new array of <c>{ text, id, enabled, hwnd, clickable }</c>; hidden buttons (styled TaskDialog templates ship
///   many) are skipped.  <c>enabled</c> is the button's own state; <c>clickable</c> also needs every window it sits
///   in enabled.  <c>hwnd</c> names the button: the IDE's own Confirm box answers <c>GetDlgCtrlID</c> with 0.
/// </returns>
function ButtonsOf( ADlg: HWND ): TJSONArray;
begin

  Result            := TJSONArray.Create;
  try
    for var hb in ButtonWindowsOf( ADlg ) do
    begin
      // Styled TaskDialogs ship EVERY possible button as a hidden child — list
      // only the ones actually on screen, else a click "succeeds" on a no-op.
      if not IsWindowVisible( hb ) then Continue;
      var oB        := TJSONObject.Create;
      Result.AddElement( oB );
      oB.AddPair( 'text', WndText( hb ) );
      oB.AddPair( 'id', TJSONNumber.Create( GetDlgCtrlID( hb ) ) );
      oB.AddPair( 'enabled', TJSONBool.Create( IsWindowEnabled( hb ) ) );
      oB.AddPair( 'hwnd', TJSONNumber.Create( IntPtr( hb ) ) );
      oB.AddPair( 'clickable', TJSONBool.Create( WndCanBeClicked( hb ) ) );
    end;
  except
    Result.Free;
    raise;
  end;

end;

/// <summary>
///   The text a window shows in static controls - a message box's message, a VCL <c>TStaticText</c> - matched by the
///   system class they are built on (<see cref="WndRealClass"/>), since a VCL control's own class name is not
///   <c>Static</c>.  The reads share one time budget, so a busy main thread cannot make a listing of many windows slow.
/// </summary>
/// <param name="ADlg">The window.</param>
/// <param name="ABudgetMs">The time the reads may take between them.</param>
/// <param name="AComplete">Receives False when the budget ran out before every text was read, or a text was cut at <c>MAX_WND_TEXT</c>.</param>
/// <returns>A new array of the non-empty texts.</returns>
/// <remarks>
///   Read with <c>WM_GETTEXT</c>, so only WINDOWED text is found: a VCL <c>TLabel</c> (the message of a
///   <c>TMessageForm</c>) has no window and cannot be read from this thread.
/// </remarks>
function TextsOf( ADlg: HWND; ABudgetMs: Integer; out AComplete: Boolean ): TJSONArray;
begin

  AComplete         := True;
  Result            := TJSONArray.Create;
  var lst           := TList<HWND>.Create;
  try
    EnumChildWindows( ADlg, @EnumChildProc, LPARAM( Pointer( lst ) ) );
    var rWatch      := TStopwatch.StartNew;
    for var hChild in lst do
      if IsWindowVisible( hChild ) and SameText( WndRealClass( hChild ), 'Static' ) then
      begin
        var iLeft   := ABudgetMs - Integer( rWatch.ElapsedMilliseconds );
        if iLeft <= 0 then
        begin
          AComplete := False;
          Break;
        end;
        var sText   := '';
        var bCut    := False;
        if not WndTextRead( hChild, UINT( iLeft ), sText, bCut ) then
        begin
          AComplete := False;
          Continue;
        end;
        if bCut then
          AComplete := False;
        if Trim( sText ) <> '' then
          Result.Add( sText );
      end;
  finally
    lst.Free;
  end;

end;

/// <summary>Describes a button for an error's <c>error.data</c>: <c>{ hwnd, text, dialog, dialogHwnd, modal }</c>; pass <c>hwnd</c> back as <c>buttonHwnd</c>.</summary>
/// <param name="AButton">The button.</param>
/// <returns>A new object.</returns>
function ButtonRef( AButton: HWND ): TJSONObject;
begin

  var hRoot         := GetAncestor( AButton, GA_ROOT );
  Result            := TJSONObject.Create;
  Result.AddPair( 'hwnd', TJSONNumber.Create( IntPtr( AButton ) ) );
  Result.AddPair( 'text', WndText( AButton ) );
  Result.AddPair( 'dialog', WndText( hRoot ) );
  Result.AddPair( 'dialogHwnd', TJSONNumber.Create( IntPtr( hRoot ) ) );
  Result.AddPair( 'modal', TJSONBool.Create( WndIsModal( hRoot ) ) );

end;

/// <summary>
///   What became of a HANDLED click on a button of <paramref name="ADlg"/>, looked at for up to <c>DISMISS_WAIT_MS</c>
///   rather than promised: <c>gone</c> (the window was destroyed or hidden - a VCL modal form is hidden when its modal
///   result is set), <c>covered</c> (still up, with something modal on top of it), or <c>unchanged</c> (still up and
///   enabled: nothing came of the click, or the button does not close its window).  Windows reuses handles, so
///   <c>unchanged</c> means only that something is still waiting (GxInspect).  Timed by a stopwatch: counting
///   <c>Sleep</c> steps overshoots, each lasting a timer tick rather than the time asked for.
/// </summary>
/// <param name="ADlg">The top-level window the button sits in.</param>
/// <returns><c>gone</c>, <c>covered</c> or <c>unchanged</c>.</returns>
function ClickOutcome( ADlg: HWND ): string;
begin

  var rWatch        := TStopwatch.StartNew;
  repeat
    if ( not IsWindow( ADlg ) ) or ( not IsWindowVisible( ADlg ) ) then Exit( 'gone' );
    Sleep( DISMISS_POLL_MS );
  until rWatch.ElapsedMilliseconds >= DISMISS_WAIT_MS;

  Result            := if IsWindowEnabled( ADlg ) then 'unchanged' else 'covered';

end;

const
  /// <summary>The message the click marker window answers; its <c>WParam</c> is the ticket.</summary>
  WM_CLICKMARK      = WM_APP + $1D2;

type
  /// <summary>
  ///   A hidden window of the MAIN thread that tells a worker when the main thread has handled a posted click.  Posted
  ///   messages of one thread are retrieved in the order they were posted, so a marker posted straight after the click
  ///   is handled only once the click's handler has returned - or once a modal loop the handler opened is pumping,
  ///   which is when the click has had its effect too.  A SENT message could not do this: Windows delivers sent
  ///   messages before posted ones.
  /// </summary>
  TClickMarkWindow = class
  private
    /// <summary>The window handle, from <c>AllocateHWnd</c>.</summary>
    FHandle         : HWND;
    /// <summary>The highest ticket handled so far; read and written through <c>TInterlocked</c>.</summary>
    FSeen           : Integer;
    /// <summary>The last ticket given out.</summary>
    FIssued         : Integer;
    /// <summary>Records a marker's ticket; everything else goes to <c>DefWindowProc</c>.</summary>
    /// <param name="AMsg">The message.</param>
    procedure WndProc( var AMsg: TMessage );
  public
    /// <summary>Creates the window; call on the main thread, so the window belongs to it.</summary>
    constructor Create;
    /// <summary>Destroys the window.</summary>
    destructor Destroy; override;
    /// <summary>Posts a marker behind whatever was posted to the main thread so far, and waits for it to be handled.</summary>
    /// <param name="AWaitMs">How long to wait.</param>
    /// <returns>True once the marker was handled; False when the wait ran out first.</returns>
    function WaitForMainThread( AWaitMs: Integer ): Boolean;
    /// <summary>The window, which belongs to the main thread: what <c>mainThreadBusy</c> asks.</summary>
    property Handle: HWND read FHandle;
  end;

var
  /// <summary>The click marker window, created by <c>TAutomationServer.Start</c> on the main thread; nil when started on another.</summary>
  GClickMark        : TClickMarkWindow = nil;

constructor TClickMarkWindow.Create;
begin

  inherited Create;
  FHandle           := AllocateHWnd( WndProc );

end;

destructor TClickMarkWindow.Destroy;
begin

  DeallocateHWnd( FHandle );
  inherited;

end;

procedure TClickMarkWindow.WndProc( var AMsg: TMessage );
begin

  if AMsg.Msg = WM_CLICKMARK then
    TInterlocked.Exchange( FSeen, Integer( AMsg.WParam ) )
  else
    AMsg.Result     := DefWindowProc( FHandle, AMsg.Msg, AMsg.WParam, AMsg.LParam );

end;

function TClickMarkWindow.WaitForMainThread( AWaitMs: Integer ): Boolean;
begin

  var iTicket       := TInterlocked.Increment( FIssued );
  if not PostMessage( FHandle, WM_CLICKMARK, WPARAM( iTicket ), 0 ) then
    Exit( False );
  var rWatch        := TStopwatch.StartNew;
  repeat
    if TInterlocked.CompareExchange( FSeen, 0, 0 ) >= iTicket then Exit( True );
    Sleep( 10 );
  until rWatch.ElapsedMilliseconds >= AWaitMs;
  Result            := TInterlocked.CompareExchange( FSeen, 0, 0 ) >= iTicket;

end;

/// <summary>Reads a window handle argument of <c>dialogs</c>, if present.</summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <returns>The handle, or 0 when the argument is absent.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when it is present but not a number; <c>NoWindow</c> when it is not a window of this process.</exception>
function DialogsHandleArg( AReq: TJSONObject; const AKey: string ): HWND;
begin

  var oValue        := AReq.GetValue( AKey );
  if oValue = nil then Exit( 0 );
  if oValue is not TJSONNumber then
    raise EAutoError.CreateCode( 'BadRequest', Format( '"%s" must be a window handle, as dialogs lists it', [ AKey ] ) );
  Result            := HWND( TJSONNumber( oValue ).AsInt64 );
  var iPid: DWORD   := 0;
  if IsWindow( Result ) then
    GetWindowThreadProcessId( Result, iPid );
  if iPid <> GetCurrentProcessId then
    raise EAutoError.CreateCode( 'NoWindow', Format( '%s %d is not a window of this process; ask dialogs again, handles do not last',
      [ AKey, IntPtr( Result ) ] ) );

end;

/// <summary>
///   <c>dialogs</c> command (Win32-only, runs OFF the VCL thread).  With neither <c>"button"</c> nor <c>"buttonHwnd"</c> it
///   lists the open top-level windows, each with its buttons, its static texts and whether it is modal.  With a
///   <c>"button"</c> it clicks the ONE button whose caption matches (case-insensitive, '&amp;' accelerators ignored) and
///   that a user could click; <c>"hwnd"</c> narrows the search to one top-level window, and <c>"buttonHwnd"</c> names the
///   button itself.  Safe while a modal loop blocks the main thread.
/// </summary>
/// <param name="AReq">The request object (<c>button?</c>, <c>buttonHwnd?</c>, <c>hwnd?</c>, <c>modalOnly?</c>, <c>wait?</c>).</param>
/// <returns>
///   <c>{ windows:[ { hwnd, class, caption, owned, enabled, modal, texts, textsComplete, buttons } ], mainThreadBusy }</c>
///   (list) or <c>{ clicked, dialog, hwnd, buttonHwnd, dismissed, outcome, method }</c> (click).
/// </returns>
/// <exception cref="EAutoError">
///   <c>NoButton</c> when no open window has a button of that caption; <c>NotClickable</c> when the only ones are hidden
///   or disabled or sit in a disabled window (one with a modal on top); <c>AmbiguousButton</c> when several could be
///   clicked and not exactly one of them is in a modal window, listed in <c>error.data</c>; <c>NoWindow</c> when
///   <c>hwnd</c> is not a top-level window of this process or <c>buttonHwnd</c> not a button of it; <c>BadRequest</c> for
///   a handle that is not a number, or a <c>buttonHwnd</c> outside the <c>hwnd</c> given.
/// </exception>
/// <remarks>
///   The click is POSTED, once: <c>BM_CLICK</c> to a button that implements it, the mouse messages to one that does not
///   (a custom-drawn <c>TStyledButton</c>), never both.  The outcome is judged once the main thread has HANDLED the
///   click - a marker posted behind it says so - for up to <c>wait</c> ms (default 5000); a click still queued or
///   running then answers <c>pending</c>, never <c>unchanged</c>.  Until 0.13 <c>BM_CLICK</c> was sent and the mouse
///   messages sent after it as well, so a button that does not close its window ran twice.
/// </remarks>
function AutoCmdDialogs( AReq: TJSONObject ): TJSONValue;
begin

  var sButton       := AReq.GetValue<string>( 'button', '' );
  var bModalOnly    := AReq.GetValue<Boolean>( 'modalOnly', False );
  var iWait         := Min( Max( AReq.GetValue<Integer>( 'wait', DIALOG_HANDLED_WAIT_MS ), 0 ), 60000 );

  var hOnly         := DialogsHandleArg( AReq, 'hwnd' );
  if ( hOnly <> 0 ) and ( GetAncestor( hOnly, GA_ROOT ) <> hOnly ) then
    raise EAutoError.CreateCode( 'NoWindow', Format( 'hwnd %d is not a top-level window; ask dialogs again', [ IntPtr( hOnly ) ] ) );
  var hNamed        := DialogsHandleArg( AReq, 'buttonHwnd' );
  if ( hNamed <> 0 ) and not IsButtonWindow( hNamed ) then
    raise EAutoError.CreateCode( 'NoWindow', Format( 'buttonHwnd %d is not a button; ask dialogs again', [ IntPtr( hNamed ) ] ) );
  if ( hNamed <> 0 ) and ( hOnly <> 0 ) and ( GetAncestor( hNamed, GA_ROOT ) <> hOnly ) then
    raise EAutoError.CreateCode( 'BadRequest', 'buttonHwnd is not a button of the window hwnd names' );

  var tops          := TList<HWND>.Create;
  try
    if hOnly <> 0 then
      tops.Add( hOnly )
    else
      EnumWindows( @EnumTopProc, LPARAM( Pointer( tops ) ) );

    if ( sButton = '' ) and ( hNamed = 0 ) then
    begin
      var oRes      := TJSONObject.Create;
      try
        //  Asked FIRST: a main thread that does not answer within half a second is busy, so a dialog may be on its way
        //  that is not up yet (the first Tools > Options of an IDE takes seconds) - an empty list then means "ask
        //  again".  Asked after the listing it would only measure whether the thread had caught up meanwhile.
        //  Asked of the click marker, a window of the main thread in every host: a console host has no
        //  Application.Handle, which made the answer always "not busy" there.
        var hProbe: HWND := if Assigned( GClickMark ) then GClickMark.Handle else Application.Handle;
        var iDummy: DWORD_PTR := 0;
        var bBusy   := ( hProbe <> 0 ) and
          ( SendMessageTimeout( hProbe, WM_NULL, 0, 0, SMTO_ABORTIFHUNG, 500, @iDummy ) = 0 );
        //  parented before filling, for the reason given in AutoCmdTree.
        var oArr    := TJSONArray.Create;
        oRes.AddPair( 'windows', oArr );
        for var hw in tops do
        begin
          var bModal := WndIsModal( hw );
          if bModalOnly and not bModal then Continue;
          var oD := TJSONObject.Create;
          oArr.AddElement( oD );
          oD.AddPair( 'hwnd', TJSONNumber.Create( IntPtr( hw ) ) );
          oD.AddPair( 'class', WndClass( hw ) );
          oD.AddPair( 'caption', WndText( hw ) );
          oD.AddPair( 'owned', TJSONBool.Create( GetWindow( hw, GW_OWNER ) <> 0 ) );
          oD.AddPair( 'enabled', TJSONBool.Create( IsWindowEnabled( hw ) ) );
          oD.AddPair( 'modal', TJSONBool.Create( bModal ) );
          var bComplete: Boolean;
          oD.AddPair( 'texts', TextsOf( hw, TEXTS_BUDGET_MS, bComplete ) );
          oD.AddPair( 'textsComplete', TJSONBool.Create( bComplete ) );
          oD.AddPair( 'buttons', ButtonsOf( hw ) );
        end;
        oRes.AddPair( 'mainThreadBusy', TJSONBool.Create( bBusy ) );
      except
        oRes.Free;
        raise;
      end;
      Exit( oRes );
    end;

    var aClickable: TArray<HWND> := [];
    var aBlocked: TArray<HWND> := [];
    if hNamed <> 0 then
    begin
      if WndCanBeClicked( hNamed ) then
        aClickable  := [ hNamed ]
      else
        aBlocked    := [ hNamed ];
    end
    else
    begin
      //  Every match is looked at, not only the first: two clickable ones mean the caller has to say which, and an
      //  unclickable one is worth naming in the refusal.
      var sWant     := PlainButtonCaption( sButton );
      for var hw in tops do
        for var hb in ButtonWindowsOf( hw ) do
          if SameText( PlainButtonCaption( WndText( hb ) ), sWant ) then
          begin
            if WndCanBeClicked( hb ) then
              aClickable := aClickable + [ hb ]
            else if IsWindowVisible( hb ) then
              aBlocked := aBlocked + [ hb ];
          end;
    end;

    //  A message box disables only its OWNER, so another open window's button of the same caption is clickable too;
    //  the one in the window that is waiting for an answer is the one meant.  Only when that does not settle it is the
    //  caption refused.
    if Length( aClickable ) > 1 then
    begin
      var aModal: TArray<HWND> := [];
      for var hb in aClickable do
        if WndIsModal( GetAncestor( hb, GA_ROOT ) ) then
          aModal    := aModal + [ hb ];
      if Length( aModal ) = 1 then
        aClickable  := aModal;
    end;

    if Length( aClickable ) > 1 then
    begin
      var oData     := TJSONArray.Create;
      for var hb in aClickable do
        oData.AddElement( ButtonRef( hb ) );
      raise EAutoError.CreateCodeData( 'AmbiguousButton', Format( '%d buttons "%s" could be clicked; name the one meant with ' +
        '"buttonHwnd" (each one''s hwnd is in error.data), or its window with "hwnd"', [ Length( aClickable ), sButton ] ), oData );
    end;

    if Length( aClickable ) = 0 then
    begin
      if Length( aBlocked ) = 0 then
        raise EAutoError.CreateCode( 'NoButton', Format( 'no open dialog has a button matching "%s"', [ sButton ] ) );
      var oData     := TJSONArray.Create;
      for var hb in aBlocked do
        oData.AddElement( ButtonRef( hb ) );
      raise EAutoError.CreateCodeData( 'NotClickable', Format( 'the button "%s" is hidden or disabled, or the window it sits in ' +
        'is - a window goes disabled while something modal is on top of it; ask dialogs for the one that is waiting',
        [ if hNamed <> 0 then WndText( hNamed ) else sButton ] ), oData );
    end;

    var hTarget     := aClickable[ 0 ];
    var hDlg        := GetAncestor( hTarget, GA_ROOT );
    // Captions BEFORE the click: it may destroy the dialog and its button.
    var sBtnText    := WndText( hTarget );
    var sDlgText    := WndText( hDlg );

    var sMethod     := 'bmClick';
    if WndTakesBmClick( hTarget ) then
      PostMessage( hTarget, BM_CLICK, 0, 0 )
    else
    begin
      //  A STYLED or otherwise custom-drawn control keeps a window class containing 'button' - so the search
      //  finds it - but its window procedure does not implement BM_CLICK.  Ethea's TStyledButton on a
      //  TStyledTaskDialog is exactly this.  The mouse messages every TControl handles click it instead.
      sMethod       := 'mouse';
      var rc: TRect;
      GetClientRect( hTarget, rc );
      var lp: LPARAM := MakeLParam( rc.Width div 2, rc.Height div 2 );
      PostMessage( hTarget, WM_LBUTTONDOWN, MK_LBUTTON, lp );
      PostMessage( hTarget, WM_LBUTTONUP, 0, lp );
    end;

    //  Judged from when the click was HANDLED, not when it was posted: a slow handler, or a busy main thread, would
    //  otherwise read as "nothing came of it" while the click is still queued or running, and a caller that retried
    //  would click twice.  Without the marker window (a server started off the main thread) it is judged as before.
    var sOutcome: string;
    if Assigned( GClickMark ) and not GClickMark.WaitForMainThread( iWait ) then
      sOutcome      := 'pending'
    else
      sOutcome      := ClickOutcome( hDlg );

    var oRes        := TJSONObject.Create;
    oRes.AddPair( 'clicked', sBtnText );
    oRes.AddPair( 'dialog', sDlgText );
    oRes.AddPair( 'hwnd', TJSONNumber.Create( IntPtr( hDlg ) ) );
    oRes.AddPair( 'buttonHwnd', TJSONNumber.Create( IntPtr( hTarget ) ) );
    //  Whether the click TOOK EFFECT, not merely whether a message was sent: the window it was in went away.
    oRes.AddPair( 'dismissed', TJSONBool.Create( sOutcome = 'gone' ) );
    oRes.AddPair( 'outcome', sOutcome );
    oRes.AddPair( 'method', sMethod );
    Result          := oRes;
  finally
    tops.Free;
  end;

end;

{ ── click_at / drop_files (VCL — main thread) ──────────────────────────── }

/// <summary>Reads the <c>shift</c> argument of <c>click_at</c>: <c>Shift</c>, <c>Ctrl</c> or <c>Shift+Ctrl</c>, empty for none.</summary>
/// <param name="AText">The argument.</param>
/// <returns>The <c>MK_SHIFT</c> / <c>MK_CONTROL</c> flags a mouse message carries.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> for any other key.</exception>
function ParseClickShift( const AText: string ): WPARAM;
begin

  Result            := 0;
  for var sPart in AText.Split( [ '+' ] ) do
  begin
    var sKey        := Trim( sPart );
    if sKey = '' then Continue;
    if SameText( sKey, 'Shift' ) then
      Result        := Result or MK_SHIFT
    else if SameText( sKey, 'Ctrl' ) then
      Result        := Result or MK_CONTROL
    else
      raise EAutoError.CreateCode( 'BadRequest', Format( '"shift" is Shift, Ctrl or Shift+Ctrl, not "%s"', [ AText ] ) );
  end;

end;

/// <summary>Reads a required integer argument of a built-in command.</summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ACommand">The command, for the message.</param>
/// <returns>The value.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when the argument is missing or not a number.</exception>
function NeedIntArg( AReq: TJSONObject; const AKey, ACommand: string ): Integer;
begin

  if not ( AReq.GetValue( AKey ) is TJSONNumber ) then
    raise EAutoError.CreateCode( 'BadRequest', Format( '%s needs "%s", a number', [ ACommand, AKey ] ) );
  Result            := TJSONNumber( AReq.GetValue( AKey ) ).AsInt;

end;

/// <summary>
///   Finds the window that input at a point of a control lands in: the control's own window, or for a control
///   without one its parent's, and in it whatever child window lies on top there - as Windows itself would route a
///   real click (GxInspect, <c>TryGetWindowAtPoint</c>).
/// </summary>
/// <param name="ACtl">The control.</param>
/// <param name="AX">The point's horizontal position, in the control's client coordinates.</param>
/// <param name="AY">The point's vertical position, in the control's client coordinates.</param>
/// <param name="APoint">Receives the point in the returned window's client coordinates.</param>
/// <returns>The window.</returns>
/// <exception cref="EAutoError">
///   <c>OutsideControl</c> for a point outside the client area; <c>NotClickable</c> when the control, or the window
///   at the point or one it sits in, is hidden or disabled (a modal dialog in front disables it); <c>NoWindow</c> when
///   the control has no window yet.
/// </exception>
function WindowAtControlPoint( ACtl: TControl; AX, AY: Integer; out APoint: TPoint ): HWND;
begin

  if ( AX < 0 ) or ( AY < 0 ) or ( AX >= ACtl.ClientWidth ) or ( AY >= ACtl.ClientHeight ) then
    raise EAutoError.CreateCode( 'OutsideControl', Format( '%d,%d is outside %s, whose client area is %d x %d',
      [ AX, AY, ACtl.Name, ACtl.ClientWidth, ACtl.ClientHeight ] ) );
  if not ( ACtl.Visible and ACtl.Enabled ) then
    raise EAutoError.CreateCode( 'NotClickable', ACtl.Name + ' is hidden or disabled, so a user could not reach it' );

  // A control without a window of its own gets its mouse messages through its parent.
  if ACtl is TWinControl then
  begin
    if not TWinControl( ACtl ).HandleAllocated then
      raise EAutoError.CreateCode( 'NoWindow', ACtl.Name + ' has no window yet, so it is not on screen' );
    Result          := TWinControl( ACtl ).Handle;
    APoint          := Point( AX, AY );
  end
  else
  begin
    if ( ACtl.Parent = nil ) or not ACtl.Parent.HandleAllocated then
      raise EAutoError.CreateCode( 'NoWindow', ACtl.Name + ' is in no window, so it is not on screen' );
    Result          := ACtl.Parent.Handle;
    APoint          := Point( ACtl.Left + AX, ACtl.Top + AY );
  end;

  repeat
    var hChild      := ChildWindowFromPointEx( Result, APoint, CWP_SKIPINVISIBLE or CWP_SKIPTRANSPARENT );
    if ( hChild = 0 ) or ( hChild = Result ) then Break;
    MapWindowPoints( Result, hChild, APoint, 1 );
    Result          := hChild;
  until False;

  if not WndCanBeClicked( Result ) then
    raise EAutoError.CreateCode( 'NotClickable', 'The window at that point, or one it sits in, is hidden or disabled - ' +
      'a modal dialog in front disables it; ask dialogs' );

end;

/// <summary>The control a point of a window reaches, for the reply: its name, or its class when unnamed, or the window class when it is no VCL window.</summary>
/// <param name="AWnd">The window.</param>
/// <param name="APoint">The point, in its client coordinates.</param>
/// <returns>The description.</returns>
function DescribeReached( AWnd: HWND; const APoint: TPoint ): string;
begin

  var oReached: TControl := FindControl( AWnd );
  if oReached is TWinControl then
  begin
    var oOnTop      := TWinControl( oReached ).ControlAtPos( APoint, False );
    if Assigned( oOnTop ) then
      oReached      := oOnTop;
  end;
  if oReached = nil then
    Result          := WndClass( AWnd )
  else if oReached.Name <> '' then
    Result          := oReached.Name
  else
    Result          := oReached.ClassName;

end;

/// <summary>
///   <c>click_at</c> command: a real left click at a point of a control, in its client coordinates - the mouse
///   messages a user's click produces, posted to whatever window lies at that point, so a control that reacts to
///   WHERE it is clicked (a grid cell, a list item, a paint box) is driven as a user drives it.  For a click on the
///   control as a whole, <c>click</c> is the simpler choice.
/// </summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name</c>, <c>x</c>, <c>y</c>, <c>shift?</c>).</param>
/// <returns><c>{ clicked, x, y, shift, reaches }</c>; <c>reaches</c> names what is at the point, which need not be the control named.</returns>
/// <exception cref="EAutoError">
///   The addressing codes; <c>NotVisual</c> (not a control); <c>BadRequest</c> (no <c>x</c> / <c>y</c>, or an unknown
///   key in <c>shift</c>); and <see cref="WindowAtControlPoint"/>'s codes.
/// </exception>
/// <remarks>
///   Posted, so the reply goes out before the click is handled: a click that opens a modal dialog cannot hold it up.
///   Shift and Ctrl travel in the messages' key flags, which is where the VCL's mouse events read them; code that
///   asks <c>GetKeyState</c> instead does not see them.
/// </remarks>
function AutoCmdClickAt( AReq: TJSONObject ): TJSONValue;
begin

  var oForm         := AutoResolveForm( AReq );
  var oComp         := AutoResolveComp( AReq, oForm );
  if oComp is not TControl then
    raise EAutoError.CreateCode( 'NotVisual', Format( '%s (%s) is not a control, so it cannot be clicked at a point',
      [ oComp.Name, oComp.ClassName ] ) );

  var iX            := NeedIntArg( AReq, 'x', 'click_at' );
  var iY            := NeedIntArg( AReq, 'y', 'click_at' );
  var sShift        := AReq.GetValue<string>( 'shift', '' );
  var iKeys         := ParseClickShift( sShift );

  var ptAt: TPoint;
  var hAt           := WindowAtControlPoint( TControl( oComp ), iX, iY, ptAt );
  var lp: LPARAM    := MakeLParam( Word( ptAt.X ), Word( ptAt.Y ) );

  PostMessage( hAt, WM_MOUSEMOVE, iKeys, lp );
  PostMessage( hAt, WM_LBUTTONDOWN, iKeys or MK_LBUTTON, lp );
  PostMessage( hAt, WM_LBUTTONUP, iKeys, lp );

  var oRes          := TJSONObject.Create;
  oRes.AddPair( 'clicked', oComp.Name );
  oRes.AddPair( 'x', TJSONNumber.Create( iX ) );
  oRes.AddPair( 'y', TJSONNumber.Create( iY ) );
  oRes.AddPair( 'shift', sShift );
  oRes.AddPair( 'reaches', DescribeReached( hAt, ptAt ) );
  Result            := oRes;

end;

/// <summary>Builds the <c>CF_HDROP</c> block <c>WM_DROPFILES</c> carries: a <c>DROPFILES</c> header, then the names, each ended by #0, and one more #0.</summary>
/// <param name="AFiles">The files.</param>
/// <param name="APoint">The drop point, in the receiving window's client coordinates.</param>
/// <returns>The block; whoever it is handed to frees it, with <c>DragFinish</c>.</returns>
/// <exception cref="EOSError">When the memory cannot be allocated.</exception>
function BuildDropHandle( const AFiles: TArray<string>; const APoint: TPoint ): HGLOBAL;
begin

  var iSize         := SizeOf( TDropFiles ) + SizeOf( Char );
  for var sFile in AFiles do
    Inc( iSize, ( Length( sFile ) + 1 ) * SizeOf( Char ) );

  Result            := GlobalAlloc( GMEM_MOVEABLE or GMEM_ZEROINIT, iSize );
  if Result = 0 then
    RaiseLastOSError;

  var pBlock        := GlobalLock( Result );
  try
    var pHeader     := PDropFiles( pBlock );
    pHeader.pFiles  := SizeOf( TDropFiles );
    pHeader.pt      := APoint;
    pHeader.fNC     := False;
    pHeader.fWide   := True;
    var pDest       := PChar( PByte( pBlock ) + SizeOf( TDropFiles ) );
    for var sFile in AFiles do
    begin
      if sFile <> '' then
        Move( PChar( sFile )^, pDest^, Length( sFile ) * SizeOf( Char ) );
      Inc( pDest, Length( sFile ) + 1 );
    end;
  finally
    GlobalUnlock( Result );
  end;

end;

/// <summary>
///   <c>drop_files</c> command: drops files on a control as if dragged there from Explorer, through the
///   <c>WM_DROPFILES</c> Windows hands to the nearest window up the chain that accepts files
///   (<c>WS_EX_ACCEPTFILES</c>, set by <c>DragAcceptFiles</c>).
/// </summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name</c>, <c>files</c> - an array of paths, <c>x?</c>, <c>y?</c> - the drop point in the control's client coordinates, its centre by default).</param>
/// <returns><c>{ dropped, target, x, y }</c>; <c>target</c> names the window that took the drop.</returns>
/// <exception cref="EAutoError">
///   The addressing codes; <c>NotVisual</c>; <c>BadRequest</c> for a missing or empty <c>files</c>; <c>NoFile</c> for a
///   file or folder that does not exist (Explorer drops only those that do); <c>NoDropTarget</c> when no window up
///   the chain accepts files; and <see cref="WindowAtControlPoint"/>'s codes.
/// </exception>
/// <remarks>
///   Posted, so the reply goes out first; the receiver frees the block with <c>DragFinish</c>.  A control that takes
///   files only through OLE drag and drop (<c>RegisterDragDrop</c>) is not reached this way.
/// </remarks>
function AutoCmdDropFiles( AReq: TJSONObject ): TJSONValue;
begin

  var oForm         := AutoResolveForm( AReq );
  var oComp         := AutoResolveComp( AReq, oForm );
  if oComp is not TControl then
    raise EAutoError.CreateCode( 'NotVisual', Format( '%s (%s) is not a control, so nothing can be dropped on it',
      [ oComp.Name, oComp.ClassName ] ) );
  var oCtl          := TControl( oComp );

  var oFiles        := AReq.GetValue( 'files' );
  if not ( oFiles is TJSONArray ) or ( TJSONArray( oFiles ).Count = 0 ) then
    raise EAutoError.CreateCode( 'BadRequest', 'drop_files needs "files", an array of paths' );
  var aFiles: TArray<string> := [];
  for var oFile in TJSONArray( oFiles ) do
  begin
    if oFile is not TJSONString then
      raise EAutoError.CreateCode( 'BadRequest', '"files" holds paths, as strings' );
    var sFile       := TJSONString( oFile ).Value;
    if not ( FileExists( sFile ) or DirectoryExists( sFile ) ) then
      raise EAutoError.CreateCode( 'NoFile', sFile + ' does not exist, and Explorer drops only what does' );
    aFiles          := aFiles + [ sFile ];
  end;

  var iX            := if AReq.GetValue( 'x' ) <> nil then NeedIntArg( AReq, 'x', 'drop_files' ) else oCtl.ClientWidth div 2;
  var iY            := if AReq.GetValue( 'y' ) <> nil then NeedIntArg( AReq, 'y', 'drop_files' ) else oCtl.ClientHeight div 2;

  var ptAt: TPoint;
  var hTarget       := WindowAtControlPoint( oCtl, iX, iY, ptAt );
  while ( GetWindowLong( hTarget, GWL_EXSTYLE ) and WS_EX_ACCEPTFILES ) = 0 do
  begin
    if ( GetWindowLong( hTarget, GWL_STYLE ) and WS_CHILD ) = 0 then
      raise EAutoError.CreateCode( 'NoDropTarget', oCtl.Name + ' does not accept dropped files, nor does any window it sits in' );
    var hParent     := GetParent( hTarget );
    MapWindowPoints( hTarget, hParent, ptAt, 1 );
    hTarget         := hParent;
  end;

  var hDrop         := BuildDropHandle( aFiles, ptAt );
  if not PostMessage( hTarget, WM_DROPFILES, WPARAM( hDrop ), 0 ) then
  begin
    GlobalFree( hDrop );
    RaiseLastOSError;
  end;

  var oRes          := TJSONObject.Create;
  oRes.AddPair( 'dropped', TJSONNumber.Create( Length( aFiles ) ) );
  oRes.AddPair( 'target', DescribeReached( hTarget, ptAt ) );
  oRes.AddPair( 'x', TJSONNumber.Create( iX ) );
  oRes.AddPair( 'y', TJSONNumber.Create( iY ) );
  Result            := oRes;

end;

{ ── M-D: dataset assertions (VCL — main thread) ──────────────────────────── }

/// <summary>Resolves a component to its <c>TDataSet</c> — the dataset itself, or a <c>TDataSource</c>'s dataset.</summary>
/// <param name="AComp">The dataset or datasource component.</param>
/// <returns>The underlying dataset.</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>NotDataSet</c> when the component is neither.</remarks>
function AsDataSet( AComp: TComponent ): TDataSet;
begin

  if AComp is TDataSet then Exit( TDataSet( AComp ) );
  if AComp is TDataSource then Exit( TDataSource( AComp ).DataSet );

  raise EAutoError.CreateCode( 'NotDataSet', AComp.Name + ' is not a TDataSet or TDataSource' );

end;

/// <summary><c>field_get</c> command: reads one field of a dataset's current record (typed value, field type, null flag).</summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name</c>, <c>field</c>).</param>
/// <returns><c>{ dataset, field, type, isNull, value }</c>.</returns>
/// <remarks>Raises <c>EAutoError</c> —Code <c>DataSetClosed</c> / <c>NoField</c>.</remarks>
function AutoCmdFieldGet( AReq: TJSONObject ): TJSONValue;
begin

  var oForm         := AutoResolveForm( AReq );
  var oDS           := AsDataSet( AutoResolveComp( AReq, oForm ) );
  var sField        := AReq.GetValue<string>( 'field', '' );

  if not oDS.Active then
    raise EAutoError.CreateCode( 'DataSetClosed', oDS.Name + ' is not open' );

  var oFld          := oDS.FindField( sField );
  if oFld = nil then
    raise EAutoError.CreateCode( 'NoField', Format( '%s has no field "%s"', [ oDS.Name, sField ] ) );

  Result            := TJSONObject.Create;
  TJSONObject( Result ).AddPair( 'dataset', oDS.Name );
  TJSONObject( Result ).AddPair( 'field', sField );
  TJSONObject( Result ).AddPair( 'type', GetEnumName( TypeInfo( TFieldType ), Ord( oFld.DataType ) ) );
  TJSONObject( Result ).AddPair( 'isNull', TJSONBool.Create( oFld.IsNull ) );
  if oFld.IsNull then
    TJSONObject( Result ).AddPair( 'value', TJSONNull.Create )
  else
    TJSONObject( Result ).AddPair( 'value', VarToJSON( oFld.Value ) );

end;

/// <summary><c>field_set</c> command: writes one field of a dataset's current record, promoting a browsing dataset into edit mode first.</summary>
/// <param name="AReq">The request object ( <c>form?</c>, <c>name</c>, <c>field</c>, <c>value</c> ).</param>
/// <returns><c>{ dataset, field, state, isNull, value }</c> with the read-back value.</returns>
/// <remarks>
///   Exists because data-aware controls commonly do NOT publish their text property — the LMD
///   data-aware edits (<c>TLMDDBEdit</c> and descendants such as <c>TLMDDBLabeledEdit</c>)
///   publish <c>Field</c> read-only and no <c>Text</c> — so <c>set</c> cannot reach the value at
///   all. Writing through the dataset works whatever the control class, and works for fields
///   that have no control on the form.
///   Raises <c>EAutoError</c> — Code <c>DataSetClosed</c> / <c>NoField</c> / <c>ReadOnlyField</c>.
/// </remarks>
function AutoCmdFieldSet( AReq: TJSONObject ): TJSONValue;
begin

  var oForm         := AutoResolveForm( AReq );
  var oDS           := AsDataSet( AutoResolveComp( AReq, oForm ) );
  var sField        := AReq.GetValue<string>( 'field', '' );

  if not oDS.Active then
    raise EAutoError.CreateCode( 'DataSetClosed', oDS.Name + ' is not open' );

  var oFld          := oDS.FindField( sField );
  if oFld = nil then
    raise EAutoError.CreateCode( 'NoField', Format( '%s has no field "%s"', [ oDS.Name, sField ] ) );

  if oFld.ReadOnly then
    raise EAutoError.CreateCode( 'ReadOnlyField', Format( '%s.%s is read-only', [ oDS.Name, sField ] ) );

  // Only dsBrowse is promoted. An existing dsEdit/dsInsert is deliberately left alone so that
  // filling a half-completed insert cannot restart or post the record underneath the caller.
  if oDS.State = dsBrowse then
    oDS.Edit;

  var oVal          := AReq.GetValue( 'value' );
  if ( oVal = nil ) or ( oVal is TJSONNull ) then
    oFld.Clear
  else
    oFld.Value      := JSONToVar( oVal );

  Result            := TJSONObject.Create;
  var o             := TJSONObject( Result );
  o.AddPair( 'dataset', oDS.Name );
  o.AddPair( 'field', sField );
  o.AddPair( 'state', GetEnumName( TypeInfo( TDataSetState ), Ord( oDS.State ) ) );
  o.AddPair( 'isNull', TJSONBool.Create( oFld.IsNull ) );
  if oFld.IsNull then
    o.AddPair( 'value', TJSONNull.Create )
  else
    o.AddPair( 'value', VarToJSON( oFld.Value ) );

end;

/// <summary><c>dataset_op</c> command: performs one dataset navigation or editing operation.</summary>
/// <param name="AReq">The request object ( <c>form?</c>, <c>name</c>, <c>op</c> ).</param>
/// <returns><c>{ dataset, op, state, recNo }</c>.</returns>
/// <remarks>
///   <c>op</c> is one of <c>insert</c>, <c>append</c>, <c>edit</c>, <c>post</c>, <c>cancel</c>,
///   <c>refresh</c>, <c>first</c>, <c>last</c>, <c>next</c>, <c>prior</c>.
///   Needed because the suite's navigator buttons (<c>TwwNavButton</c> with
///   <c>Style = nbsInsert</c>) perform the dataset action in the navigator itself, NOT in
///   <c>OnClick</c> — so <c>click</c> fires only the handler's UI half and never enters insert
///   mode. <c>TwwNavButton</c> is also not button-class, so <c>click</c>'s <c>message</c> mode
///   cannot reach it either.
///   Raises <c>EAutoError</c> — Code <c>DataSetClosed</c> / <c>BadOp</c>.
/// </remarks>
function AutoCmdDatasetOp( AReq: TJSONObject ): TJSONValue;
begin

  var oForm         := AutoResolveForm( AReq );
  var oDS           := AsDataSet( AutoResolveComp( AReq, oForm ) );
  var sOp           := LowerCase( Trim( AReq.GetValue<string>( 'op', '' ) ) );

  if not oDS.Active then
    raise EAutoError.CreateCode( 'DataSetClosed', oDS.Name + ' is not open' );

  if sOp = 'insert' then
    oDS.Insert
  else if sOp = 'append' then
    oDS.Append
  else if sOp = 'edit' then
    oDS.Edit
  else if sOp = 'post' then
    oDS.Post
  else if sOp = 'cancel' then
    oDS.Cancel
  else if sOp = 'refresh' then
    oDS.Refresh
  else if sOp = 'first' then
    oDS.First
  else if sOp = 'last' then
    oDS.Last
  else if sOp = 'next' then
    oDS.Next
  else if sOp = 'prior' then
    oDS.Prior
  else
    raise EAutoError.CreateCode( 'BadOp', Format( '"%s" is not a recognised dataset op', [ sOp ] ) );

  Result            := TJSONObject.Create;
  var o             := TJSONObject( Result );
  o.AddPair( 'dataset', oDS.Name );
  o.AddPair( 'op', sOp );
  o.AddPair( 'state', GetEnumName( TypeInfo( TDataSetState ), Ord( oDS.State ) ) );
  o.AddPair( 'recNo', TJSONNumber.Create( oDS.RecNo ) );

end;

/// <summary><c>dataset</c> command: reports a dataset's state (active / record count / RecNo / BOF / EOF); with <c>"fields":true</c>, also the current record's field values.</summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name</c>, <c>fields?</c>).</param>
/// <returns><c>{ dataset, active, recordCount, recNo, bof, eof, fields? }</c>.</returns>
function AutoCmdDataset( AReq: TJSONObject ): TJSONValue;
begin

  var oForm         := AutoResolveForm( AReq );
  var oDS           := AsDataSet( AutoResolveComp( AReq, oForm ) );

  Result            := TJSONObject.Create;
  var o             := TJSONObject( Result );
  o.AddPair( 'dataset', oDS.Name );
  o.AddPair( 'active', TJSONBool.Create( oDS.Active ) );
  if not oDS.Active then Exit;

  o.AddPair( 'recordCount', TJSONNumber.Create( oDS.RecordCount ) );
  o.AddPair( 'recNo', TJSONNumber.Create( oDS.RecNo ) );
  o.AddPair( 'bof', TJSONBool.Create( oDS.Bof ) );
  o.AddPair( 'eof', TJSONBool.Create( oDS.Eof ) );

  if AReq.GetValue<Boolean>( 'fields', False ) then
  begin
    var oFlds       := TJSONObject.Create;
    for var i := 0 to oDS.FieldCount - 1 do
    begin
      var f         := oDS.Fields[ i ];
      if f.IsNull then
        oFlds.AddPair( f.FieldName, TJSONNull.Create )
      else
        oFlds.AddPair( f.FieldName, VarToJSON( f.Value ) );
    end;
    o.AddPair( 'fields', oFlds );
  end;

end;

{ ── M-F: keys (keyboard input through the app's own message loop) ─────────── }

const
  /// <summary>Upper bound on the keystrokes one <c>keys</c> request may carry (text characters plus chords).</summary>
  KEYS_MAX          = 4096;
  /// <summary>Default wait, in milliseconds, for a <c>keys</c> sequence to be delivered.</summary>
  KEYS_TIMEOUT_DEFAULT = 5000;
  /// <summary>Lower clamp on a <c>keys</c> request's <c>timeoutMs</c>.</summary>
  KEYS_TIMEOUT_MIN  = 100;
  /// <summary>Upper clamp on a <c>keys</c> request's <c>timeoutMs</c>.</summary>
  KEYS_TIMEOUT_MAX  = 60000;
  /// <summary>Step marker <c>WParam</c>: the stroke's key messages are queued; repost once so its generated <c>WM_CHAR</c> is delivered first.</summary>
  KEYSTEP_POSTED    = 1;
  /// <summary>Step marker <c>WParam</c>: the previous stroke has been fully delivered; send the next one.</summary>
  KEYSTEP_SETTLED   = 2;
  /// <summary>Transition and previous-state bits (31 and 30) of a key-up message's <c>LParam</c>.</summary>
  KEYUP_LPARAM_BITS = $C0000000;

type
  /// <summary>One keystroke of a <c>keys</c> sequence.</summary>
  TKeyStroke = record
    /// <summary>Virtual-key code; <c>0</c> for a character posted as a bare <c>WM_CHAR</c>.</summary>
    Vk: Word;
    /// <summary>The character posted as <c>WM_CHAR</c> when <c>Vk</c> is <c>0</c> (no key on the layout produces it).</summary>
    Ch: Char;
    /// <summary>Shift is held for this stroke.</summary>
    Shift: Boolean;
    /// <summary>Ctrl is held for this stroke.</summary>
    Ctrl: Boolean;
    /// <summary>Alt is held for this stroke; the key is posted as <c>WM_SYSKEYDOWN</c> / <c>WM_SYSKEYUP</c>.</summary>
    Alt: Boolean;
  end;

  /// <summary>The worker thread's view of a <c>keys</c> sequence being delivered on the main thread.</summary>
  IKeySequence = interface
    ['{6F0B7C1E-3A52-4D8B-9E61-2C4F5A7D8B90}']
    /// <summary>Waits for the sequence to finish.</summary>
    /// <param name="ATimeoutMs">The longest wait, in milliseconds.</param>
    /// <returns><c>True</c> when it finished (completed or stopped) within the wait.</returns>
    function Wait( ATimeoutMs: Cardinal ): Boolean;
    /// <summary>Asks the sequence to stop at its next step (it then releases the modifier keys).</summary>
    procedure Abort;
    /// <summary>The number of strokes posted so far.</summary>
    /// <returns>The count; exact once <c>Wait</c> has returned <c>True</c>.</returns>
    function StrokesSent: Integer;
    /// <summary>Why the sequence stopped early: <c>modal</c>, <c>targetGone</c>, <c>timeout</c>, or empty when it completed.</summary>
    /// <returns>The reason; valid once <c>Wait</c> has returned <c>True</c>.</returns>
    function StopReason: string;
    /// <summary>True when the target's form was disabled (a modal window open over it) as the sequence finished.</summary>
    /// <returns>The flag; valid once <c>Wait</c> has returned <c>True</c>.</returns>
    function ModalOpen: Boolean;
  end;

  /// <summary>
  ///   Delivers a list of keystrokes to one control, one stroke at a time, through the app's own
  ///   message loop - so <c>Application.OnMessage</c>, <c>KeyPreview</c>, menu and action shortcuts,
  ///   Tab / Enter / Esc dialog navigation and <c>TranslateMessage</c> all run exactly as for a real
  ///   key press. Lives on the main thread; the worker thread only waits on it.
  /// </summary>
  /// <remarks>
  ///   Each stroke sets the thread's keyboard state (the modifiers VCL reads through
  ///   <c>GetKeyState</c>), posts its key-down and key-up, then posts a step marker to the
  ///   unit's own key-step window. The marker is reposted once before the next stroke, so the
  ///   <c>WM_CHAR</c> that <c>TranslateMessage</c> queues behind the key-down is delivered while the
  ///   stroke's modifiers are still set. A stroke whose handler opens a modal window is detected at
  ///   the next step (the target's form is disabled) and the sequence stops there rather than typing
  ///   into a control behind the modal. The saved keyboard state is restored when it finishes.
  /// </remarks>
  TKeySequence = class( TInterfacedObject, IKeySequence )
  private
    /// <summary>The strokes to deliver, in order.</summary>
    FStrokes: TArray<TKeyStroke>;
    /// <summary>Index of the next stroke to post.</summary>
    FNext: Integer;
    /// <summary>The control the key messages are posted to.</summary>
    FTarget: HWND;
    /// <summary>The target's top-level window, disabled while a modal window is open over it.</summary>
    FRoot: HWND;
    /// <summary>The keyboard state saved at the start, restored when the sequence finishes.</summary>
    FSaved: TKeyboardState;
    /// <summary>Signalled when the sequence finishes.</summary>
    FDone: TEvent;
    /// <summary>Non-zero once the worker has given up waiting; read with <c>TInterlocked</c>.</summary>
    FAborted: Integer;
    /// <summary>See <see cref="IKeySequence.StopReason"/>.</summary>
    FStopReason: string;
    /// <summary>See <see cref="IKeySequence.ModalOpen"/>.</summary>
    FModalOpen: Boolean;
    /// <summary>Sets the stroke's modifier state and posts its key messages to the target.</summary>
    /// <param name="AStroke">The stroke.</param>
    procedure PostStroke( const AStroke: TKeyStroke );
    /// <summary>Posts the next stroke, or finishes when there is none or the target can no longer take it.</summary>
    procedure Advance;
    /// <summary>Restores the keyboard state and signals the waiting worker.</summary>
    /// <param name="AReason">The stop reason; empty when every stroke was delivered.</param>
    procedure Finish( const AReason: string );
  public
    /// <summary>Handles one step marker from the key-step window: reposts a <c>KEYSTEP_POSTED</c> one, advances on a <c>KEYSTEP_SETTLED</c> one.</summary>
    /// <param name="APhase">The marker's phase (its <c>WParam</c>).</param>
    procedure Step( APhase: WPARAM );
    /// <summary>Creates the sequence; nothing is sent until <c>Start</c>.</summary>
    /// <param name="AStrokes">The strokes, in order.</param>
    /// <param name="ATarget">The control's window handle.</param>
    constructor Create( const AStrokes: TArray<TKeyStroke>; ATarget: HWND );
    /// <summary>Frees the completion event.</summary>
    destructor Destroy; override;
    /// <summary>Saves the keyboard state and posts the first stroke. Main thread only.</summary>
    procedure Start;
    /// <summary>See <see cref="IKeySequence.Wait"/>.</summary>
    /// <param name="ATimeoutMs">The longest wait, in milliseconds.</param>
    /// <returns><c>True</c> when the sequence finished within the wait.</returns>
    function Wait( ATimeoutMs: Cardinal ): Boolean;
    /// <summary>See <see cref="IKeySequence.Abort"/>.</summary>
    procedure Abort;
    /// <summary>See <see cref="IKeySequence.StrokesSent"/>.</summary>
    /// <returns>The number of strokes posted so far.</returns>
    function StrokesSent: Integer;
    /// <summary>See <see cref="IKeySequence.StopReason"/>.</summary>
    /// <returns>The stop reason.</returns>
    function StopReason: string;
    /// <summary>See <see cref="IKeySequence.ModalOpen"/>.</summary>
    /// <returns>The flag.</returns>
    function ModalOpen: Boolean;
  end;

  /// <summary>
  ///   A hidden window, owned by this unit, that the <c>keys</c> step markers are posted to. Its own
  ///   window rather than <c>Application.Handle</c>: a host need not have an application window (a
  ///   console test runner has none, so markers posted there went nowhere and a sequence stalled after
  ///   its first stroke), and a private window keeps the marker out of every other hook's way.
  /// </summary>
  TKeyStepWindow = class
  private
    /// <summary>The window handle, from <c>AllocateHWnd</c>.</summary>
    FHandle: HWND;
    /// <summary>Hands a step marker to the running sequence; everything else goes to <c>DefWindowProc</c>.</summary>
    /// <param name="AMsg">The message.</param>
    procedure WndProc( var AMsg: TMessage );
  public
    /// <summary>Creates the window. Main thread only: its messages are dispatched by that thread's loop.</summary>
    constructor Create;
    /// <summary>Destroys the window.</summary>
    destructor Destroy; override;
    /// <summary>The window handle.</summary>
    property Handle: HWND read FHandle;
  end;

const
  /// <summary>The <c>keys</c> step marker, private to <c>TKeyStepWindow</c>.</summary>
  WM_KEYSTEP        = WM_APP + 1;

var
  /// <summary>The key-step window; created on the first <c>keys</c> request (main thread), freed in finalization.</summary>
  GKeyWindow        : TKeyStepWindow;
  /// <summary>The sequence currently being delivered, kept alive here until it finishes. Main thread only.</summary>
  GKeysRunning      : IKeySequence;

/// <summary>Sets or clears the pressed bit of a modifier in a keyboard-state array, for the generic key and both sides.</summary>
/// <param name="AState">The keyboard state to change.</param>
/// <param name="AGeneric">The side-neutral virtual key (<c>VK_SHIFT</c>, <c>VK_CONTROL</c>, <c>VK_MENU</c>).</param>
/// <param name="ALeft">The left-hand virtual key, set with the generic one.</param>
/// <param name="ARight">The right-hand virtual key, always released.</param>
/// <param name="ADown">True to press the modifier, False to release it.</param>
procedure SetModifierState( var AState: TKeyboardState; AGeneric, ALeft, ARight: Byte; ADown: Boolean );
begin

  if ADown then
  begin
    AState[ AGeneric ] := AState[ AGeneric ] or $80;
    AState[ ALeft ] := AState[ ALeft ] or $80;
  end
  else
  begin
    AState[ AGeneric ] := AState[ AGeneric ] and $7F;
    AState[ ALeft ] := AState[ ALeft ] and $7F;
  end;
  AState[ ARight ]  := AState[ ARight ] and $7F;

end;

/// <summary>Builds the <c>LParam</c> of a posted key-down message: repeat count 1, the scan code, the extended-key bit for the navigation block, and the context bit for Alt.</summary>
/// <param name="AVk">The virtual key.</param>
/// <param name="AAlt">True when Alt is held.</param>
/// <returns>The key-down <c>LParam</c>; OR in <c>KEYUP_LPARAM_BITS</c> for the key-up.</returns>
function KeyDownLParam( AVk: Word; AAlt: Boolean ): NativeUInt;
begin

  Result            := 1 or ( NativeUInt( MapVirtualKey( AVk, MAPVK_VK_TO_VSC ) and $FF ) shl 16 );

  case AVk of
    VK_PRIOR, VK_NEXT, VK_END, VK_HOME, VK_LEFT, VK_UP, VK_RIGHT, VK_DOWN, VK_INSERT, VK_DELETE:
      Result        := Result or ( NativeUInt( 1 ) shl 24 );
  end;

  if AAlt then
    Result          := Result or ( NativeUInt( 1 ) shl 29 );

end;

/// <summary>Maps one key name of a <c>keys</c> chord to its virtual key.</summary>
/// <param name="AName">A letter or digit, a single printable character, <c>F1</c>..<c>F24</c>, or a named key (Enter, Tab, Esc, Space, Backspace, Delete, Insert, Home, End, PgUp, PgDn, Up, Down, Left, Right, Plus, Minus, Comma, Period).</param>
/// <param name="AVk">Receives the virtual key.</param>
/// <param name="AShift">Receives True when the layout needs Shift to produce a single character (e.g. <c>?</c>).</param>
/// <returns><c>True</c> when the name is recognised.</returns>
function KeyNameToVk( const AName: string; out AVk: Word; out AShift: Boolean ): Boolean;
const
  /// <summary>Named keys and their virtual keys, matched without regard to case.</summary>
  KEY_NAMES: array[ 0..23 ] of record N: string; V: Word; end = (
    ( N: 'Enter';     V: VK_RETURN ), ( N: 'Return';   V: VK_RETURN ), ( N: 'Tab';      V: VK_TAB ),
    ( N: 'Esc';       V: VK_ESCAPE ), ( N: 'Escape';   V: VK_ESCAPE ), ( N: 'Space';    V: VK_SPACE ),
    ( N: 'Backspace'; V: VK_BACK ),   ( N: 'Delete';   V: VK_DELETE ), ( N: 'Del';      V: VK_DELETE ),
    ( N: 'Insert';    V: VK_INSERT ), ( N: 'Ins';      V: VK_INSERT ), ( N: 'Home';     V: VK_HOME ),
    ( N: 'End';       V: VK_END ),    ( N: 'PgUp';     V: VK_PRIOR ),  ( N: 'PgDn';     V: VK_NEXT ),
    ( N: 'Up';        V: VK_UP ),     ( N: 'Down';     V: VK_DOWN ),   ( N: 'Left';     V: VK_LEFT ),
    ( N: 'Right';     V: VK_RIGHT ),  ( N: 'Plus';     V: VK_OEM_PLUS ), ( N: 'Minus';  V: VK_OEM_MINUS ),
    ( N: 'Comma';     V: VK_OEM_COMMA ), ( N: 'Period'; V: VK_OEM_PERIOD ), ( N: 'Apps'; V: VK_APPS ) );
begin

  AVk               := 0;
  AShift            := False;

  if Length( AName ) = 1 then
  begin
    var ch          := UpCase( AName[ 1 ] );
    if CharInSet( ch, [ 'A'..'Z', '0'..'9' ] ) then
    begin
      AVk           := Ord( ch );
      Exit( True );
    end;

    // Any other single character: whatever key the current layout produces it with, provided
    // that needs no more than Shift (an AltGr character cannot be a chord's key).
    var iScan       := VkKeyScanEx( AName[ 1 ], GetKeyboardLayout( 0 ) );
    if ( iScan = -1 ) or ( ( Word( iScan ) shr 8 ) and 6 <> 0 ) then Exit( False );
    AVk             := Word( iScan ) and $FF;
    AShift          := ( Word( iScan ) shr 8 ) and 1 <> 0;
    Exit( True );
  end;

  var iFn: Integer;
  if ( Length( AName ) in [ 2, 3 ] ) and ( UpCase( AName[ 1 ] ) = 'F' ) and TryStrToInt( Copy( AName, 2 ), iFn ) and
    ( iFn >= 1 ) and ( iFn <= 24 ) then
  begin
    AVk             := VK_F1 + iFn - 1;
    Exit( True );
  end;

  for var i := Low( KEY_NAMES ) to High( KEY_NAMES ) do
    if SameText( KEY_NAMES[ i ].N, AName ) then
    begin
      AVk           := KEY_NAMES[ i ].V;
      Exit( True );
    end;

  Result            := False;

end;

/// <summary>Parses a <c>keys</c> string - chords separated by spaces or commas, each a key name with optional <c>Ctrl+</c> / <c>Shift+</c> / <c>Alt+</c> prefixes - into strokes.</summary>
/// <param name="AKeys">The chord list, e.g. <c>Ctrl+S</c>, <c>Tab Tab Enter</c>, <c>Shift+F10</c>.</param>
/// <returns>One stroke per chord.</returns>
/// <remarks>Raises <c>EAutoError</c> - Code <c>BadKeys</c> - for an unknown key name or a chord with no key, or with two.</remarks>
function ParseKeyChords( const AKeys: string ): TArray<TKeyStroke>;
begin

  Result            := nil;

  for var sChord in AKeys.Split( [ ' ', ',', #9, #13, #10 ], TStringSplitOptions.ExcludeEmpty ) do
  begin
    var r           := Default( TKeyStroke );
    var bHaveKey    := False;

    for var sPart in sChord.Split( [ '+' ] ) do
    begin
      if SameText( sPart, 'Ctrl' ) or SameText( sPart, 'Control' ) then
        r.Ctrl      := True
      else if SameText( sPart, 'Shift' ) then
        r.Shift     := True
      else if SameText( sPart, 'Alt' ) then
        r.Alt       := True
      else
      begin
        var wVk: Word;
        var bShift: Boolean;
        if bHaveKey or not KeyNameToVk( sPart, wVk, bShift ) then
          raise EAutoError.CreateCode( 'BadKeys', Format( '"%s" is not a key chord (one key, optionally with Ctrl+ / Shift+ / Alt+; ' +
            'named keys: Enter Tab Esc Space Backspace Delete Insert Home End PgUp PgDn Up Down Left Right Plus Minus Comma ' +
            'Period Apps F1..F24)', [ sChord ] ) );
        r.Vk        := wVk;
        r.Shift     := r.Shift or bShift;
        bHaveKey    := True;
      end;
    end;

    if not bHaveKey then
      raise EAutoError.CreateCode( 'BadKeys', Format( '"%s" has modifiers but no key', [ sChord ] ) );

    Result          := Result + [ r ];
  end;

end;

/// <summary>Turns literal text into strokes: each character as the key (plus Shift) the current layout types it with, or a bare <c>WM_CHAR</c> when no key on the layout produces it without Ctrl/Alt.</summary>
/// <param name="AText">The text; CR LF and a lone LF are both typed as Enter.</param>
/// <returns>One stroke per character.</returns>
function TextToStrokes( const AText: string ): TArray<TKeyStroke>;
begin

  Result            := nil;

  var hLayout       := GetKeyboardLayout( 0 );
  for var ch in AText.Replace( #13#10, #13 ).Replace( #10, #13 ) do
  begin
    var r           := Default( TKeyStroke );
    var iScan       := VkKeyScanEx( ch, hLayout );
    if ( iScan <> -1 ) and ( ( Word( iScan ) shr 8 ) and 6 = 0 ) then
    begin
      r.Vk          := Word( iScan ) and $FF;
      r.Shift       := ( Word( iScan ) shr 8 ) and 1 <> 0;
    end
    else
      r.Ch          := ch;
    Result          := Result + [ r ];
  end;

end;

constructor TKeySequence.Create( const AStrokes: TArray<TKeyStroke>; ATarget: HWND );
begin

  inherited Create;
  FStrokes          := AStrokes;
  FTarget           := ATarget;
  FRoot             := GetAncestor( ATarget, GA_ROOT );
  FDone             := TEvent.Create( nil, True, False, '' );

end;

destructor TKeySequence.Destroy;
begin

  FDone.Free;
  inherited;

end;

constructor TKeyStepWindow.Create;
begin

  inherited Create;
  FHandle           := AllocateHWnd( WndProc );

end;

destructor TKeyStepWindow.Destroy;
begin

  DeallocateHWnd( FHandle );
  inherited;

end;

procedure TKeyStepWindow.WndProc( var AMsg: TMessage );
begin

  if AMsg.Msg <> WM_KEYSTEP then
  begin
    AMsg.Result     := DefWindowProc( FHandle, AMsg.Msg, AMsg.WParam, AMsg.LParam );
    Exit;
  end;

  // A marker left over from a sequence that has already finished finds nothing running: ignore it.
  if GKeysRunning <> nil then
    ( GKeysRunning as TKeySequence ).Step( AMsg.WParam );

end;

procedure TKeySequence.Start;
begin

  if GKeyWindow = nil then
    GKeyWindow      := TKeyStepWindow.Create;

  GetKeyboardState( FSaved );
  Advance;

end;

procedure TKeySequence.Step( APhase: WPARAM );
begin

  // Finish drops GKeysRunning's reference; if the worker has already given up, that was the last
  // one. Hold our own until this call is over.
  _AddRef;
  try
    if APhase = KEYSTEP_POSTED then
      PostMessage( GKeyWindow.Handle, WM_KEYSTEP, KEYSTEP_SETTLED, 0 )
    else
      Advance;
  finally
    _Release;
  end;

end;

procedure TKeySequence.PostStroke( const AStroke: TKeyStroke );
begin

  var kb            := FSaved;
  SetModifierState( kb, VK_SHIFT, VK_LSHIFT, VK_RSHIFT, AStroke.Shift );
  SetModifierState( kb, VK_CONTROL, VK_LCONTROL, VK_RCONTROL, AStroke.Ctrl );
  SetModifierState( kb, VK_MENU, VK_LMENU, VK_RMENU, AStroke.Alt );
  kb[ VK_CAPITAL ]  := 0; // a Caps Lock left on would invert the case TranslateMessage types
  SetKeyboardState( kb );

  if AStroke.Vk = 0 then
  begin
    PostMessage( FTarget, WM_CHAR, WPARAM( Ord( AStroke.Ch ) ), 1 );
    Exit;
  end;

  // Alt chords and F10 are system keys: a real keyboard sends them as WM_SYSKEY*.
  var bSys          := AStroke.Alt or ( AStroke.Vk = VK_F10 );
  var nLParam       := KeyDownLParam( AStroke.Vk, AStroke.Alt );
  PostMessage( FTarget, if bSys then WM_SYSKEYDOWN else WM_KEYDOWN, WPARAM( AStroke.Vk ), LPARAM( nLParam ) );
  PostMessage( FTarget, if bSys then WM_SYSKEYUP else WM_KEYUP, WPARAM( AStroke.Vk ), LPARAM( nLParam or KEYUP_LPARAM_BITS ) );

end;

procedure TKeySequence.Advance;
begin

  if TInterlocked.CompareExchange( FAborted, 0, 0 ) <> 0 then
    Finish( 'timeout' )
  else if FNext > High( FStrokes ) then
    Finish( '' )
  else if not IsWindow( FTarget ) then
    Finish( 'targetGone' )
  else if not IsWindowEnabled( FRoot ) then
    Finish( 'modal' ) // the last stroke opened a modal: do not type into the control behind it
  else
  begin
    PostStroke( FStrokes[ FNext ] );
    Inc( FNext );
    PostMessage( GKeyWindow.Handle, WM_KEYSTEP, KEYSTEP_POSTED, 0 );
  end;

end;

procedure TKeySequence.Finish( const AReason: string );
begin

  SetKeyboardState( FSaved );

  FStopReason       := AReason;
  FModalOpen        := IsWindow( FRoot ) and not IsWindowEnabled( FRoot );
  FDone.SetEvent;

  GKeysRunning      := nil; // StartKeySequence admits one sequence at a time, so this is us

end;

function TKeySequence.Wait( ATimeoutMs: Cardinal ): Boolean;
begin

  Result            := FDone.WaitFor( ATimeoutMs ) = wrSignaled;

end;

procedure TKeySequence.Abort;
begin

  TInterlocked.Exchange( FAborted, 1 );

end;

function TKeySequence.StrokesSent: Integer;
begin

  Result            := FNext;

end;

function TKeySequence.StopReason: string;
begin

  Result            := FStopReason;

end;

function TKeySequence.ModalOpen: Boolean;
begin

  Result            := FModalOpen;

end;

/// <summary>Main-thread half of <c>keys</c>: resolves and validates the target, focuses it, and starts delivering the strokes.</summary>
/// <param name="AReq">The request object (see <c>AutoCmdKeys</c>).</param>
/// <param name="ATarget">Receives the name (or class) of the control the keys go to.</param>
/// <param name="ACount">Receives the number of strokes.</param>
/// <returns>The running sequence.</returns>
/// <remarks>
///   Raises <c>EAutoError</c> - Code <c>BadKeys</c> (nothing to send, too many strokes, or a bad
///   chord); <c>Busy</c> (another sequence is still being delivered); <c>NotTypable</c> (not a
///   windowed control, or not visible+enabled); <c>Blocked</c> (a modal window is open over the form).
/// </remarks>
function StartKeySequence( AReq: TJSONObject; out ATarget: string; out ACount: Integer ): IKeySequence;
begin

  var oForm         := AutoResolveForm( AReq );
  var oComp         := AutoResolveComp( AReq, oForm );

  var aStrokes      := TextToStrokes( AReq.GetValue<string>( 'text', '' ) ) + ParseKeyChords( AReq.GetValue<string>( 'keys', '' ) );
  if Length( aStrokes ) = 0 then
    raise EAutoError.CreateCode( 'BadKeys', 'nothing to send: give text and/or keys' );
  if Length( aStrokes ) > KEYS_MAX then
    raise EAutoError.CreateCode( 'BadKeys', Format( '%d keystrokes is more than the %d one request may carry', [ Length( aStrokes ), KEYS_MAX ] ) );

  if GKeysRunning <> nil then
    raise EAutoError.CreateCode( 'Busy', 'an earlier keys sequence is still being delivered' );

  // No name: the keys go where a user's would - the form's focused control.
  var oCtl: TWinControl;
  if ( oComp = oForm ) and Assigned( oForm.ActiveControl ) then
    oCtl            := oForm.ActiveControl
  else if oComp is TWinControl then
    oCtl            := TWinControl( oComp )
  else
    raise EAutoError.CreateCode( 'NotTypable', Format( '%s (%s) is not a windowed control, so it cannot take keyboard input',
      [ oComp.Name, oComp.ClassName ] ) );

  if not IsWindowEnabled( oForm.Handle ) then
    raise EAutoError.CreateCode( 'Blocked', oForm.Name + ' is disabled - a modal window is open over it; answer it with dialogs first' );

  // Faithful to a real keyboard: a user cannot type into a hidden or disabled control.
  if not oCtl.CanFocus then
    raise EAutoError.CreateCode( 'NotTypable', oCtl.Name + ' is not visible+enabled' );

  // Focus it as a user's click would - firing the previous control's OnExit and this one's
  // OnEnter - so Tab / Enter navigation starts from it.
  if AReq.GetValue<Boolean>( 'focus', True ) and ( oCtl <> oForm ) and ( oForm.ActiveControl <> oCtl ) then
    oCtl.SetFocus;

  var oSeq          := TKeySequence.Create( aStrokes, oCtl.Handle );
  Result            := oSeq;
  GKeysRunning      := Result;
  ATarget           := if oCtl.Name <> '' then oCtl.Name else oCtl.ClassName;
  ACount            := Length( aStrokes );
  oSeq.Start;

end;

/// <summary>
///   <c>keys</c> command (runs on the worker thread): types <c>text</c>, then sends the <c>keys</c>
///   chords, to a control through the app's own message loop, and waits until they have been
///   delivered. The app does not need to be in the foreground and no global input is synthesised.
/// </summary>
/// <param name="AReq">
///   The request object (<c>form?</c>, <c>name?</c> - omit for the form's focused control,
///   <c>text?</c>, <c>keys?</c>, <c>focus?</c> - default true, <c>timeoutMs?</c> - default
///   <c>KEYS_TIMEOUT_DEFAULT</c>, clamped <c>KEYS_TIMEOUT_MIN</c>..<c>KEYS_TIMEOUT_MAX</c>).
/// </param>
/// <returns>
///   <c>{ target, strokes, strokesSent, completed, modalOpen, stoppedReason? }</c>. <c>stoppedReason</c>
///   is <c>modal</c> (a stroke opened a modal window; the rest were not sent), <c>targetGone</c> or
///   <c>timeout</c>.
/// </returns>
/// <remarks>
///   Typed text fires <c>OnKeyDown</c>, <c>OnKeyPress</c> and <c>OnKeyUp</c> like real typing; a
///   character no key on the current layout produces without Ctrl/Alt is posted as a bare
///   <c>WM_CHAR</c> (<c>OnKeyPress</c> only). An Alt chord that opens a menu enters the menu's own
///   modal loop and is best-effort. Error codes: see <c>StartKeySequence</c>.
/// </remarks>
function AutoCmdKeys( AReq: TJSONObject ): TJSONValue;
begin

  var iTimeout      := AReq.GetValue<Integer>( 'timeoutMs', KEYS_TIMEOUT_DEFAULT );
  if iTimeout < KEYS_TIMEOUT_MIN then iTimeout := KEYS_TIMEOUT_MIN;
  if iTimeout > KEYS_TIMEOUT_MAX then iTimeout := KEYS_TIMEOUT_MAX;

  var oSeq: IKeySequence := nil;
  var sTarget       := '';
  var iCount        := 0;
  TThread.Synchronize( nil,
    procedure
    begin
      if GDisableIdleTimers then
        DisableIdleTimers; // keep the app alive while an agent drives it
      oSeq          := StartKeySequence( AReq, sTarget, iCount );
    end );

  var bFinished     := oSeq.Wait( Cardinal( iTimeout ) );
  if not bFinished then
    oSeq.Abort; // the next step releases the modifiers and stops

  var sReason       := if bFinished then oSeq.StopReason else 'timeout';

  Result            := TJSONObject.Create;
  var o             := TJSONObject( Result );
  o.AddPair( 'target', sTarget );
  o.AddPair( 'strokes', TJSONNumber.Create( iCount ) );
  o.AddPair( 'strokesSent', TJSONNumber.Create( oSeq.StrokesSent ) );
  o.AddPair( 'completed', TJSONBool.Create( sReason = '' ) );
  o.AddPair( 'modalOpen', TJSONBool.Create( bFinished and oSeq.ModalOpen ) );
  if sReason <> '' then
    o.AddPair( 'stoppedReason', sReason );

end;

{ ── M-E: screenshot (Win32 GDI, off the VCL thread) ──────────────────────── }

/// <summary>user32 import: sets the calling thread's DPI-awareness context (for native-resolution capture). Not declared in this RTL's <c>Winapi.Windows</c>.</summary>
/// <param name="ADpiContext">The DPI-awareness context handle (e.g. <c>-4</c> = PER_MONITOR_AWARE_V2).</param>
/// <returns>The previous context (pass it back to restore).</returns>
// `delayed` is flagged W1002 (platform-specific) by the compiler; the delayed
// load is deliberate — the API is absent on older Windows and is resolved only
// when first called. This unit is Windows-only by design, so silence the noise
// locally and restore the directive immediately after the declaration.
{$WARN SYMBOL_PLATFORM OFF}
function SetThreadDpiAwarenessContext( ADpiContext: THandle ): THandle; stdcall; external 'user32.dll' delayed;
{$WARN SYMBOL_PLATFORM DEFAULT}

/// <summary>Saves a bitmap as a PNG, first scaling it down proportionally when it is wider than <paramref name="AMaxWidth"/>.</summary>
/// <param name="ABmp">The bitmap; left unchanged.</param>
/// <param name="APath">Destination PNG path (parent directories are created).</param>
/// <param name="AMaxWidth">The widest the saved image may be; <c>0</c> or less for no limit.</param>
/// <param name="AWidth">Receives the saved image's width.</param>
/// <param name="AHeight">Receives the saved image's height.</param>
/// <remarks>Scaling uses <c>HALFTONE</c> stretching, which averages pixels rather than dropping them, so text shrinks legibly further than a plain stretch allows. Pure GDI, safe off the main thread.</remarks>
procedure SavePng( ABmp: TBitmap; const APath: string; AMaxWidth: Integer; out AWidth, AHeight: Integer );
begin

  AWidth            := ABmp.Width;
  AHeight           := ABmp.Height;

  var oScaled: TBitmap := nil;
  try
    var oSave       := ABmp;
    if ( AMaxWidth > 0 ) and ( ABmp.Width > AMaxWidth ) then
    begin
      AWidth        := AMaxWidth;
      AHeight       := Max( 1, Round( ABmp.Height * AMaxWidth / ABmp.Width ) );
      oScaled       := TBitmap.Create;
      oScaled.PixelFormat := pf24bit;
      oScaled.SetSize( AWidth, AHeight );
      SetStretchBltMode( oScaled.Canvas.Handle, HALFTONE );
      SetBrushOrgEx( oScaled.Canvas.Handle, 0, 0, nil );
      StretchBlt( oScaled.Canvas.Handle, 0, 0, AWidth, AHeight, ABmp.Canvas.Handle, 0, 0, ABmp.Width, ABmp.Height, SRCCOPY );
      oSave         := oScaled;
    end;

    ForceDirectories( ExtractFilePath( APath ) );

    var oPng        := TPngImage.Create;
    try
      oPng.Assign( oSave );
      oPng.SaveToFile( APath );
    finally
      oPng.Free;
    end;
  finally
    oScaled.Free;
  end;

end;

/// <summary>BitBlts a virtual-desktop rectangle (a monitor, a window, or the whole desktop) into a PNG file. Pure GDI — safe off the main thread; <c>GetDC(0)</c> spans the entire virtual desktop, so any monitor's coordinates capture correctly.</summary>
/// <param name="ARect">The screen rectangle in virtual-desktop coordinates.</param>
/// <param name="APath">Destination PNG path (parent directories are created).</param>
/// <param name="AMaxWidth">The widest the saved image may be; <c>0</c> for no limit.</param>
/// <param name="AWidth">Receives the saved image's width.</param>
/// <param name="AHeight">Receives the saved image's height.</param>
/// <returns><c>True</c> on success; <c>False</c> for an empty rectangle.</returns>
function CaptureRect( const ARect: TRect; const APath: string; AMaxWidth: Integer; out AWidth, AHeight: Integer ): Boolean;
begin

  Result            := False;
  AWidth            := 0;
  AHeight           := 0;

  var iW            := ARect.Right - ARect.Left;
  var iH            := ARect.Bottom - ARect.Top;
  if ( iW <= 0 ) or ( iH <= 0 ) then Exit;

  var hdcScreen     := GetDC( 0 );
  try
    var oBmp        := TBitmap.Create;
    try
      oBmp.PixelFormat := pf24bit;
      oBmp.SetSize( iW, iH );
      BitBlt( oBmp.Canvas.Handle, 0, 0, iW, iH, hdcScreen, ARect.Left, ARect.Top, SRCCOPY );
      SavePng( oBmp, APath, AMaxWidth, AWidth, AHeight );
      Result        := True;
    finally
      oBmp.Free;
    end;
  finally
    ReleaseDC( 0, hdcScreen );
  end;

end;

/// <summary>user32 import: asks a window to render itself into a device context. Imported here because this RTL declares it only in <c>Winapi.WinSpool</c>, a printing unit this one has no other use for.</summary>
/// <param name="AWnd">The window.</param>
/// <param name="ADC">The device context to render into.</param>
/// <param name="AFlags"><c>PW_RENDERFULLCONTENT_FLAG</c>, or 0 for the classic rendering.</param>
/// <returns>True on success.</returns>
function PrintWindowApi( AWnd: HWND; ADC: HDC; AFlags: UINT ): BOOL; stdcall; external user32 name 'PrintWindow';

const
  /// <summary><c>PrintWindow</c> flag (Windows 8.1+): render through DWM, so themed and DirectX content comes out as it looks.</summary>
  PW_RENDERFULLCONTENT_FLAG = 2;

/// <summary>Returns the user's real Desktop directory.</summary>
/// <returns>The Desktop path from the known-folder API, falling back to <c>%USERPROFILE%\Desktop</c> only if that call fails.</returns>
/// <remarks>see the call site — <c>%USERPROFILE%\Desktop</c> is wrong wherever the Desktop is redirected, and silently so.</remarks>
function DesktopFolder: string;
begin

  var pPath: PWideChar := nil;
  if Succeeded( SHGetKnownFolderPath( FOLDERID_Desktop, 0, 0, pPath ) ) and ( pPath <> nil ) then
    try
      Exit( string( pPath ) );
    finally
      CoTaskMemFree( pPath );
    end;

  Result            := TPath.Combine( GetEnvironmentVariable( 'USERPROFILE' ), 'Desktop' );

end;

/// <summary>Chooses the file a <c>screenshot</c> is written to: the request's <c>path</c>, or a new name on the Desktop.</summary>
/// <param name="AReq">The request; its optional <c>path</c> is the PNG to write, replacing any file already there.</param>
/// <param name="AAppName">The app name, which starts a Desktop file's name.</param>
/// <returns>The full path of the PNG to write.</returns>
/// <remarks>
///   A <c>path</c> lets an unattended suite keep its images beside its results, where the Desktop default
///   would leave one there per run (0.14).  It must be a local drive path ( <c>X:\...</c> ), end in
///   <c>.png</c> and name a folder that exists: a relative name would resolve against the APP's current
///   directory, not the caller's; a UNC or device path would have the app connect somewhere in its own name;
///   and the folder is not created, so a mistyped one fails here instead of scattering images.
/// </remarks>
/// <exception cref="EAutoError">Code <c>BadPath</c>: <c>path</c> is not a local drive path, not a <c>.png</c>, or its folder does not exist.</exception>
function ScreenshotPath( AReq: TJSONObject; const AAppName: string ): string;
begin

  Result            := AReq.GetValue<string>( 'path', '' );
  if Result = '' then
    Exit( Format( '%s\%s-%u.png', [ DesktopFolder, AAppName, GetTickCount64 ] ) );

  //  a local drive path, "X:\...", and nothing else: "C:x.png" is relative to the app's directory on C:,
  //  and a UNC or device path ( "\\host\share", "\\?\", "\\.\" ) would make the app open a connection or
  //  a device in its own name
  if ( Length( Result ) < 4 ) or not CharInSet( Result[ 1 ], [ 'A'..'Z', 'a'..'z' ] ) or ( Result[ 2 ] <> ':' ) or
    ( Result[ 3 ] <> '\' ) then
    raise EAutoError.CreateCode( 'BadPath', Format( 'path "%s" is not an absolute local path ( X:\... )', [ Result ] ) );
  if not SameText( ExtractFileExt( Result ), '.png' ) then
    raise EAutoError.CreateCode( 'BadPath', Format( 'path "%s" does not end in .png', [ Result ] ) );
  if not TDirectory.Exists( ExtractFileDir( Result ) ) then
    raise EAutoError.CreateCode( 'BadPath', Format( 'the folder of "%s" does not exist', [ Result ] ) );

end;

/// <summary>Picks this process's most relevant window to capture: an active modal dialog (owned + enabled) if one is up, else the largest visible top-level form. The hidden <c>TApplication</c> window is ignored. Background-thread safe (pure Win32).</summary>
/// <returns>The chosen window handle, or <c>0</c> if none.</returns>
function FindAppWindow: HWND;
begin

  // Result is assigned unconditionally below (hDlg or hBest, hBest defaults to
  // 0), so no redundant pre-initialisation is needed.
  var tops          := TList<HWND>.Create;
  try
    EnumWindows( @EnumTopProc, LPARAM( Pointer( tops ) ) );

    var hDlg: HWND  := 0;
    var hBest: HWND := 0;
    var iBestArea   := -1;

    for var hw in tops do
    begin
      if SameText( WndClass( hw ), 'TApplication' ) then Continue; // hidden VCL app window

      if ( GetWindow( hw, GW_OWNER ) <> 0 ) and IsWindowEnabled( hw ) then
        hDlg        := hw; // an active modal dialog

      var rc: TRect;
      if GetWindowRect( hw, rc ) then
      begin
        var iArea   := ( rc.Right - rc.Left ) * ( rc.Bottom - rc.Top );
        if iArea > iBestArea then
        begin
          iBestArea := iArea;
          hBest     := hw;
        end;
      end;
    end;

    Result          := if hDlg <> 0 then hDlg else hBest;
  finally
    tops.Free;
  end;

end;

type
  /// <summary>What the main thread works out about a render target, so the worker thread can render it without touching the VCL.</summary>
  TRenderPlan = record
    /// <summary>The target's top-level window, which <c>PrintWindow</c> renders whole.</summary>
    Root: HWND;
    /// <summary>The root window's size, in the host's own (logical, for a DPI-unaware host) pixels.</summary>
    RootSize: TSize;
    /// <summary>The target's rectangle inside the root window's rendering.</summary>
    Crop: TRect;
    /// <summary>The target's name (or its class, when unnamed), for the reply.</summary>
    Target: string;
    /// <summary><c>form</c> or <c>control</c>.</summary>
    Area: string;
  end;

function PlanRenderOf( ACtl: TControl; const AArea, ATarget: string ): TRenderPlan; forward;

/// <summary>
///   Main-thread half of render mode: resolves the target and works out where it sits inside its
///   top-level window. Coordinates come from the host's main thread, so they are in the host's own
///   DPI space - the same space <c>PrintWindow</c> renders the window in.
/// </summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name?</c>).</param>
/// <returns>The plan.</returns>
/// <remarks>Raises <c>EAutoError</c> - the addressing codes; <c>NotVisual</c> (not a control); <c>NotShowing</c> (hidden, or on a hidden parent - nothing to render).</remarks>
function PlanRender( AReq: TJSONObject ): TRenderPlan;
begin

  var oForm         := AutoResolveForm( AReq );
  var oComp         := AutoResolveComp( AReq, oForm );

  if oComp is not TControl then
    raise EAutoError.CreateCode( 'NotVisual', Format( '%s (%s) is not a control, so it has nothing to render', [ oComp.Name, oComp.ClassName ] ) );

  Result            := PlanRenderOf( TControl( oComp ), if oComp = oForm then 'form' else 'control',
    if oComp.Name <> '' then oComp.Name else AReq.GetValue<string>( 'name', oComp.ClassName ) );

end;

/// <summary>
///   The main-thread half of rendering one control, however it was found: checks it is showing and works out where
///   it sits inside its top-level window.  See <see cref="PlanRender"/>.
/// </summary>
/// <param name="ACtl">The control.</param>
/// <param name="AArea"><c>form</c> or <c>control</c>, for the reply.</param>
/// <param name="ATarget">What to call it in the reply.</param>
/// <returns>The plan.</returns>
/// <exception cref="EAutoError"><c>NotShowing</c> when it is hidden, or on a hidden parent.</exception>
function PlanRenderOf( ACtl: TControl; const AArea, ATarget: string ): TRenderPlan;
begin

  var oCtl          := ACtl;
  var bShowing      := if oCtl is TWinControl then TWinControl( oCtl ).Showing
    else oCtl.Visible and ( oCtl.Parent <> nil ) and oCtl.Parent.Showing;
  if not bShowing then
    raise EAutoError.CreateCode( 'NotShowing', oCtl.Name + ' is not showing, so it has nothing to render' );

  // The target's outer rectangle on screen: a windowed control's own window rectangle (a form's
  // frame included), or a graphic control's bounds mapped through its parent's client area.
  var rcTarget: TRect;
  var hAnchor: HWND;
  if oCtl is TWinControl then
  begin
    hAnchor         := TWinControl( oCtl ).Handle;
    GetWindowRect( hAnchor, rcTarget );
  end
  else
  begin
    hAnchor         := oCtl.Parent.Handle;
    var ptOrigin    := oCtl.Parent.ClientToScreen( oCtl.BoundsRect.TopLeft );
    rcTarget        := Rect( ptOrigin.X, ptOrigin.Y, ptOrigin.X + oCtl.Width, ptOrigin.Y + oCtl.Height );
  end;

  Result.Root       := GetAncestor( hAnchor, GA_ROOT );
  var rcRoot: TRect;
  GetWindowRect( Result.Root, rcRoot );
  Result.RootSize   := TSize.Create( rcRoot.Width, rcRoot.Height );
  Result.Crop       := rcTarget;
  Result.Crop.Offset( -rcRoot.Left, -rcRoot.Top );
  // A control scrolled partly out of its window: keep the part the window can render.
  Result.Crop.Intersect( Rect( 0, 0, rcRoot.Width, rcRoot.Height ) );

  Result.Area       := AArea;
  Result.Target     := ATarget;

end;


function RenderPlanned( const APlanner: TFunc<TRenderPlan>; const AResolveAgain: TFunc<TControl>; AMaxWidth: Integer;
  const APath: string ): TJSONObject; forward;

/// <summary>
///   <c>screenshot</c> command, render mode: with a <c>"name"</c> (or a <c>"form"</c> and no
///   <c>"area"</c>), renders the target's top-level window as it paints itself and crops the target
///   out - legible at full detail, and correct even when the window is covered or off-screen, where
///   a screen capture shows whatever is in front.
/// </summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name?</c>, <c>maxWidth?</c>).</param>
/// <param name="AAppName">The app name, used in the PNG filename.</param>
/// <returns><c>{ path, width, height, area, target, renderer, sourceWidth?, sourceHeight? }</c>; <c>area</c> is <c>control</c> or <c>form</c>; <c>renderer</c> is <c>dwm</c> or <c>paintTo</c>.</returns>
/// <remarks>
///   Only the planning runs on the main thread; <c>PrintWindow</c> runs here, on the worker thread.
///   That is not a detail: measured 2026-10-13, DWM's full-content <c>PrintWindow</c> called FROM the
///   window's own thread returns FALSE (the window must repaint itself for DWM, and its thread is
///   busy running the caller), and the classic <c>PrintWindow</c> from there paints nothing. From
///   another thread it renders the whole window, children included. It refuses child windows, so
///   the whole top-level window is rendered and the target cropped from it. Should it still refuse,
///   the VCL's <c>PaintTo</c> is the fallback (<c>renderer:"paintTo"</c>) - it renders one control
///   well but not reliably a whole form's children. Because planning synchronises, this mode waits
///   while a native dialog blocks the main thread. Raises <c>EAutoError</c> - <c>PlanRender</c>'s
///   codes, and <c>CaptureFailed</c>.
/// </remarks>
function AutoCmdRender( AReq: TJSONObject; const AAppName: string ): TJSONValue;
begin

  Result            := RenderPlanned(
    function: TRenderPlan
    begin
      Result        := PlanRender( AReq );
    end,
    function: TControl
    begin
      Result        := TControl( AutoResolveComp( AReq, AutoResolveForm( AReq ) ) );
    end,
    AReq.GetValue<Integer>( 'maxWidth', 0 ), ScreenshotPath( AReq, AAppName ) );

end;

/// <summary>
///   Renders a planned target to a PNG: <c>PrintWindow</c> of its top-level window on THIS (worker) thread, cropped to
///   the target, with the VCL's <c>PaintTo</c> on the main thread as the fallback.  Shared by <c>screenshot</c>'s
///   render mode and <see cref="TAutomationServer.RenderControl"/>; why the render must run off the main thread is in
///   <see cref="AutoCmdRender"/>.
/// </summary>
/// <param name="APlanner">Called on the main thread to plan the render.</param>
/// <param name="AResolveAgain">Called on the main thread, for the fallback only, to find the control afresh.</param>
/// <param name="AMaxWidth">Scale down to at most this width; 0 for none.</param>
/// <param name="APath">The PNG to write.</param>
/// <returns><c>{ path, width, height, area, target, renderer, sourceWidth?, sourceHeight? }</c>.</returns>
/// <exception cref="EAutoError"><c>NotShowing</c> when the target lies outside its window; whatever the planner raises.</exception>
function RenderPlanned( const APlanner: TFunc<TRenderPlan>; const AResolveAgain: TFunc<TControl>; AMaxWidth: Integer;
  const APath: string ): TJSONObject;
begin

  var iMaxWidth     := AMaxWidth;
  var sPath         := APath;

  var rPlan: TRenderPlan;
  TThread.Synchronize( nil,
    procedure
    begin
      rPlan         := APlanner();
    end );

  if rPlan.Crop.IsEmpty then
    raise EAutoError.CreateCode( 'NotShowing', rPlan.Target + ' lies outside its window, so there is nothing to render' );

  var sRenderer     := 'dwm';
  var oShot         := TBitmap.Create;
  try
    oShot.PixelFormat := pf24bit;
    oShot.SetSize( rPlan.Crop.Width, rPlan.Crop.Height );

    var oRoot       := TBitmap.Create;
    try
      // 32-bit: DWM's full-content PrintWindow reports success into a 24-bit DIB and draws nothing.
      oRoot.PixelFormat := pf32bit;
      oRoot.SetSize( Max( 1, rPlan.RootSize.cx ), Max( 1, rPlan.RootSize.cy ) );

      // Locked: off the main thread the VCL may otherwise reclaim a bitmap canvas's DC from under
      // us (its idle-time FreeMemoryContexts), and a DC taken away mid-call fails the render.
      oRoot.Canvas.Lock;
      oShot.Canvas.Lock;
      var bRendered: Boolean;
      try
        bRendered   := PrintWindowApi( rPlan.Root, oRoot.Canvas.Handle, PW_RENDERFULLCONTENT_FLAG );
        if bRendered then
          BitBlt( oShot.Canvas.Handle, 0, 0, rPlan.Crop.Width, rPlan.Crop.Height, oRoot.Canvas.Handle, rPlan.Crop.Left,
            rPlan.Crop.Top, SRCCOPY );
      finally
        oShot.Canvas.Unlock;
        oRoot.Canvas.Unlock;
      end;

      if not bRendered then
      begin
        // The fallback renders the target itself, on the main thread.
        sRenderer   := 'paintTo';
        TThread.Synchronize( nil,
          procedure
          begin
            var oComp := AResolveAgain();
            if oComp is TWinControl then
              TWinControl( oComp ).PaintTo( oShot.Canvas.Handle, 0, 0 )
            else
            begin
              var oCtl := TControl( oComp );
              var oParentShot := TBitmap.Create;
              try
                oParentShot.PixelFormat := pf24bit;
                oParentShot.SetSize( Max( 1, oCtl.Parent.ClientWidth ), Max( 1, oCtl.Parent.ClientHeight ) );
                oCtl.Parent.PaintTo( oParentShot.Canvas.Handle, 0, 0 );
                BitBlt( oShot.Canvas.Handle, 0, 0, oCtl.Width, oCtl.Height, oParentShot.Canvas.Handle, oCtl.Left, oCtl.Top, SRCCOPY );
              finally
                oParentShot.Free;
              end;
            end;
          end );
      end;
    finally
      oRoot.Free;
    end;

    var iW, iH: Integer;
    SavePng( oShot, sPath, iMaxWidth, iW, iH );

    Result          := TJSONObject.Create;
    var o           := TJSONObject( Result );
    o.AddPair( 'path', sPath );
    o.AddPair( 'width', TJSONNumber.Create( iW ) );
    o.AddPair( 'height', TJSONNumber.Create( iH ) );
    o.AddPair( 'area', rPlan.Area );
    o.AddPair( 'target', rPlan.Target );
    o.AddPair( 'renderer', sRenderer );
    if ( iW <> oShot.Width ) or ( iH <> oShot.Height ) then
    begin
      o.AddPair( 'sourceWidth', TJSONNumber.Create( oShot.Width ) );
      o.AddPair( 'sourceHeight', TJSONNumber.Create( oShot.Height ) );
    end;
  finally
    oShot.Free;
  end;

end;

/// <summary>
///   <c>screenshot</c> command (Win32/GDI, runs OFF the VCL thread). By default
///   captures the whole <b>monitor</b> the app's active window sits on (a modal
///   dialog if one is open, else the main form); <c>"area":"window"</c> captures
///   just that window's rectangle and <c>"area":"virtual"</c> the entire desktop.
///   The capture thread is set per-monitor DPI-aware so it grabs native resolution.
///   With a <c>"name"</c>, or a <c>"form"</c> and no <c>"area"</c>, it renders that
///   control or form instead (see <c>AutoCmdRender</c>). <c>"maxWidth"</c> scales any
///   of them down proportionally. Writes a PNG to <c>"path"</c>, or else to the user's Desktop.
/// </summary>
/// <param name="AReq">The request object (<c>area?</c>, <c>form?</c>, <c>name?</c>, <c>maxWidth?</c>, <c>path?</c>).</param>
/// <param name="AAppName">The app name, used in the PNG filename.</param>
/// <returns><c>{ path, width, height, area }</c>, plus <c>target</c> in render mode and <c>sourceWidth</c> / <c>sourceHeight</c> when scaled.</returns>
/// <remarks>
///   The screen-capture modes copy screen PIXELS: a window covered by another, or off-screen,
///   captures as whatever is in front of it. Render mode does not have that limit.
///   Raises <c>EAutoError</c> —Code <c>CaptureFailed</c> on a GDI failure.
/// </remarks>
function AutoCmdScreenshot( AReq: TJSONObject; const AAppName: string ): TJSONValue;
var
  rc                : TRect;
  mi                : TMonitorInfo;
begin

  if ( AReq.GetValue<string>( 'name', '' ) <> '' ) or
    ( ( AReq.GetValue<string>( 'form', '' ) <> '' ) and ( AReq.GetValue<string>( 'area', '' ) = '' ) ) then
    Exit( AutoCmdRender( AReq, AAppName ) );

  var iMaxWidth     := AReq.GetValue<Integer>( 'maxWidth', 0 );

  // Make THIS (capture) thread per-monitor DPI-aware so GetMonitorInfo / GetDC /
  // BitBlt work in PHYSICAL pixels and capture the monitor at its native
  // resolution — even though the app's UI thread is DPI-unaware (on a 4K @150%
  // display an unaware capture is virtualised down to 2560x1440). -4 = V2.
  var hPrevDpi      := SetThreadDpiAwarenessContext( THandle( -4 ) );
  try
    var sArea       := LowerCase( AReq.GetValue<string>( 'area', '' ) );
    var hWin        := FindAppWindow;
    var sMode: string;

    if sArea = 'virtual' then
    begin
      rc.Left       := GetSystemMetrics( SM_XVIRTUALSCREEN );
      rc.Top        := GetSystemMetrics( SM_YVIRTUALSCREEN );
      rc.Right      := rc.Left + GetSystemMetrics( SM_CXVIRTUALSCREEN );
      rc.Bottom     := rc.Top + GetSystemMetrics( SM_CYVIRTUALSCREEN );
      sMode         := 'virtual';
    end
    else if ( sArea = 'window' ) and ( hWin <> 0 ) and GetWindowRect( hWin, rc ) then
      sMode         := 'window'
    else
    begin
      // Default: the monitor the app's active window is on.
      mi.cbSize     := SizeOf( mi );
      if ( hWin <> 0 ) and GetMonitorInfo( MonitorFromWindow( hWin, MONITOR_DEFAULTTONEAREST ), @mi ) then
        rc          := mi.rcMonitor
      else
      begin
        rc.Left     := 0; rc.Top := 0;
        rc.Right    := GetSystemMetrics( SM_CXSCREEN );
        rc.Bottom   := GetSystemMetrics( SM_CYSCREEN );
      end;
      sMode         := 'monitor';
    end;

    // Saved to the user's Desktop for easy viewing.
    //
    //  resolved through the KNOWN FOLDER, not built from %USERPROFILE%. The Desktop is
    //  routinely redirected (OneDrive does it by default), and the old path did not merely
    //  miss - CaptureRect calls ForceDirectories, so it would CREATE a second, empty
    //  %USERPROFILE%\Desktop and drop the PNG into a folder the user never looks at, while
    //  reporting success. GetTickCount64 because the 32-bit counter wraps every 49 days and
    //  the tick is the only thing keeping the filenames apart.
    var sPath       := ScreenshotPath( AReq, AAppName );

    var iW, iH: Integer;
    if not CaptureRect( rc, sPath, iMaxWidth, iW, iH ) then
      raise EAutoError.CreateCode( 'CaptureFailed', 'screen capture failed' );

    Result          := TJSONObject.Create;
    TJSONObject( Result ).AddPair( 'path', sPath );
    TJSONObject( Result ).AddPair( 'width', TJSONNumber.Create( iW ) );
    TJSONObject( Result ).AddPair( 'height', TJSONNumber.Create( iH ) );
    TJSONObject( Result ).AddPair( 'area', sMode );
    if iW <> rc.Right - rc.Left then
    begin
      TJSONObject( Result ).AddPair( 'sourceWidth', TJSONNumber.Create( rc.Right - rc.Left ) );
      TJSONObject( Result ).AddPair( 'sourceHeight', TJSONNumber.Create( rc.Bottom - rc.Top ) );
    end;
  finally
    if hPrevDpi <> 0 then SetThreadDpiAwarenessContext( hPrevDpi );
  end;

end;

function TServerImpl.ExecuteCommand( AReq: TJSONObject ): TJSONObject;
begin

  Result            := TJSONObject.Create;

  //  TryGetValue, not GetValue. GetValue<T> routes to TJSONValue.AsType<T>, which raises
  //  when the field is present but of the wrong type - and these two reads sit OUTSIDE the
  //  try below, so the raise escaped with this object already allocated. A wrongly typed id or
  //  cmd is a bad request, not a reason to abandon the connection: default them and let the
  //  dispatcher answer UnknownCmd.
  var iId           := 0;
  AReq.TryGetValue<Integer>( 'id', iId );

  var sCmd          := '';
  AReq.TryGetValue<string>( 'cmd', sCmd );

  Result.AddPair( 'id', TJSONNumber.Create( iId ) );

  var rRegistered: TRegisteredCommand;
  try
    if SameText( sCmd, 'ping' ) or SameText( sCmd, 'info' ) then
    begin

      //  Added to Result first, so an exception while filling it cannot leak the object.
      var oRes      := TJSONObject.Create;
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oRes );

      oRes.AddPair( 'app', FAppName );
      oRes.AddPair( 'pid', TJSONNumber.Create( GetCurrentProcessId ) );
      oRes.AddPair( 'version', GetExeFileVersion );
      oRes.AddPair( 'exe', ParamStr( 0 ) );
      //  The HOST's version is not necessarily this package's. Report both, so a caller can tell
      //  which gllAutomationServer build is loaded - see GetPackageFileVersion.
      oRes.AddPair( 'package', GetPackageFileVersion );
      if Assigned( Application.MainForm ) then
        oRes.AddPair( 'mainForm', Application.MainForm.Name )
      else
        oRes.AddPair( 'mainForm', TJSONNull.Create );
      oRes.AddPair( 'server', SERVER_VERSION );
    end
    else if SameText( sCmd, 'close' ) then
    begin
      //  (0.14) closes the app through its own close path - MainForm.Close, so OnCloseQuery and
      //  OnClose run, or Application.Terminate with no main form. Only flagged here: DoExecute
      //  queues the close after it has written this reply, so the reply cannot be lost to the
      //  app's exit. A console host has no TApplication window for a client to post WM_CLOSE to.
      //  Refused in the IDE ( bds.exe ), which ide_quit closes; not by ModuleIsPackage, which is
      //  also True in an ordinary exe built with runtime packages.
      if SameText( ExtractFileName( ParamStr( 0 ) ), 'bds.exe' ) then
        raise EAutoError.CreateCode( 'HostedInIde', 'close is refused inside the IDE ( use ide_quit )' );
      var oRes      := TJSONObject.Create;
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oRes );
      oRes.AddPair( 'closing', TJSONBool.Create( True ) );
      if Assigned( Application.MainForm ) then
        oRes.AddPair( 'mainForm', Application.MainForm.Name )
      else
        oRes.AddPair( 'mainForm', TJSONNull.Create );
      TInterlocked.Exchange( FCloseRequested, 1 );
    end
    else if SameText( sCmd, 'tree' ) then
    begin
      var oOut      := AutoCmdTree( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'get' ) then
    begin
      var oOut      := AutoCmdGet( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'set' ) then
    begin
      var oOut      := AutoCmdSet( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'click' ) then
    begin
      var oOut      := AutoCmdClick( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'click_at' ) then
    begin
      var oOut      := AutoCmdClickAt( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'drop_files' ) then
    begin
      var oOut      := AutoCmdDropFiles( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'action' ) then
    begin
      var oOut      := AutoCmdAction( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'dialogs' ) then
    begin
      var oOut      := AutoCmdDialogs( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'field_get' ) then
    begin
      var oOut      := AutoCmdFieldGet( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'field_set' ) then
    begin
      var oOut      := AutoCmdFieldSet( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'dataset_op' ) then
    begin
      var oOut      := AutoCmdDatasetOp( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'dataset' ) then
    begin
      var oOut      := AutoCmdDataset( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'keys' ) then
    begin
      var oOut      := AutoCmdKeys( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if SameText( sCmd, 'screenshot' ) then
    begin
      var oOut      := AutoCmdScreenshot( AReq, FAppName );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else if FindRegisteredCommand( sCmd, rRegistered ) then
    begin
      //  a command added through TAutomationServer.RegisterCommand. HandleLine has already
      //  put us on the thread it asked for.
      var oOut      := rRegistered.Handler( AReq );
      Result.AddPair( 'ok', TJSONBool.Create( True ) );
      Result.AddPair( 'result', oOut );
    end
    else
    begin
      Result.AddPair( 'ok', TJSONBool.Create( False ) );
      var oErr      := TJSONObject.Create;
      oErr.AddPair( 'code', 'UnknownCmd' );
      oErr.AddPair( 'message', 'Unknown command: ' + sCmd );
      Result.AddPair( 'error', oErr );
    end;
  except
    on E: EAutoError do
    begin
      var pOk       := Result.RemovePair( 'ok' );
      if pOk <> nil then pOk.Free;
      Result.AddPair( 'ok', TJSONBool.Create( False ) );
      var oErr      := TJSONObject.Create;
      oErr.AddPair( 'code', E.Code );
      oErr.AddPair( 'message', E.Message );
      // Clone: the payload belongs to the exception, which is freed on leaving this handler.
      if Assigned( E.Data ) then
        oErr.AddPair( 'data', E.Data.Clone as TJSONValue );
      Result.AddPair( 'error', oErr );
    end;
    on E: Exception do
    begin
      var pOk       := Result.RemovePair( 'ok' );
      if pOk <> nil then pOk.Free;
      Result.AddPair( 'ok', TJSONBool.Create( False ) );
      var oErr      := TJSONObject.Create;
      oErr.AddPair( 'code', 'Internal' );
      oErr.AddPair( 'message', E.Message );
      Result.AddPair( 'error', oErr );
    end;
  end;

end;

{ ── TAutomationServer (facade) ──────────────────────────────────────────── }

class procedure TAutomationServer.Start( const AAppName: string; ADisableIdleTimers: Boolean );
begin

  if Assigned( GImpl ) then Exit;

  GDisableIdleTimers := ADisableIdleTimers;
  //  The click marker must belong to the main thread, whose queue it marks; off it, dialogs judges clicks as before 0.13.
  if ( GClickMark = nil ) and ( TThread.CurrentThread.ThreadID = MainThreadID ) then
    GClickMark      := TClickMarkWindow.Create;
  GImpl             := TServerImpl.Create( AAppName );

end;

class function TAutomationServer.ResolveForm( ARequest: TJSONObject ): TForm;
begin

  Result            := AutoResolveForm( ARequest );

end;

class function TAutomationServer.ResolveComponent( ARequest: TJSONObject; AForm: TForm ): TComponent;
begin

  Result            := AutoResolveComp( ARequest, AForm );

end;

class function TAutomationServer.RenderControl( const AResolve: TFunc<TControl>; AMaxWidth: Integer;
  const AFileStem: string ): TJSONObject;
begin

  Result            := RenderPlanned(
    function: TRenderPlan
    begin
      var oCtl      := AResolve();
      Result        := PlanRenderOf( oCtl, if oCtl is TCustomForm then 'form' else 'control',
        if oCtl.Name <> '' then oCtl.Name else oCtl.ClassName );
    end,
    AResolve, AMaxWidth, Format( '%s\%s-%u.png', [ DesktopFolder, AFileStem, GetTickCount64 ] ) );

end;

class procedure TAutomationServer.Stop;
begin

  //  The server first: freeing it waits for every connection, so no dialogs command is still waiting on the marker.
  FreeAndNil( GImpl );
  FreeAndNil( GClickMark );

end;

class function TAutomationServer.IsRunning: Boolean;
begin

  Result            := Assigned( GImpl );

end;

class function TAutomationServer.Port: Word;
begin

  Result            := if Assigned( GImpl ) then GImpl.Port else 0;

end;

class procedure TAutomationServer.RegisterCommand( const AName: string; const AHandler: TAutomationCommand;
  AThread: TAutomationCommandThread );
begin

  if Trim( AName ) = '' then
    raise EArgumentException.Create( 'RegisterCommand needs a command name' );
  if not Assigned( AHandler ) then
    raise EArgumentException.CreateFmt( 'RegisterCommand( %s ) needs a handler', [ AName ] );

  var rCommand: TRegisteredCommand;
  rCommand.Handler  := AHandler;
  rCommand.Thread   := AThread;

  var oTable        := CommandTable;
  System.TMonitor.Enter( oTable );
  try
    //  Refused, not replaced: with AddOrSetValue a second package silently took the name over, and the first package's
    //  UnregisterCommand then removed the second's command.
    if oTable.ContainsKey( LowerCase( Trim( AName ) ) ) then
      raise EArgumentException.CreateFmt( 'RegisterCommand( %s ): that name is registered already; ' +
        'UnregisterCommand it first', [ AName ] );
    oTable.Add( LowerCase( Trim( AName ) ), rCommand );
  finally
    System.TMonitor.Exit( oTable );
  end;

end;

class procedure TAutomationServer.UnregisterCommand( const AName: string );
begin

  if GCommands = nil then Exit;

  System.TMonitor.Enter( GCommands );
  try
    GCommands.Remove( LowerCase( Trim( AName ) ) );
  finally
    System.TMonitor.Exit( GCommands );
  end;

end;

initialization
  CommandTable;   // created now when this runs first; RegisterCommand creates it otherwise

finalization
  FreeAndNil( GImpl );   // first: its destructor waits for every connection, so no worker still reads the table
  FreeAndNil( GClickMark );
  GCommandsFinalized := True;
  FreeAndNil( GCommands );
  GKeysRunning      := nil;
  FreeAndNil( GKeyWindow );

end.

