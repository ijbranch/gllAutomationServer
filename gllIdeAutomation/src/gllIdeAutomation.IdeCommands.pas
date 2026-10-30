(* GITLAK Software
  ***************************************************************************

    (C) 2016-2026 Ian Branch (GITLAK Software). All rights reserved.

    Portions derived from GExperts' GxInspect by Thomas Mueller (dummzeuch),
    svn r6031, all from ide\GxInspect_Ide.pas: TCpuDisassembler and
    debug_disasm (from TGxCpuDisassembler and CmdDisasm); the form-view swap
    behind ide_view_as_text / ide_view_as_form (from DescribeFormView,
    FindFormView and SwapFormView); FindFormEditor's two-pass matching (from
    FindFormEditorFor and FindFormView); and OpenFileKeepingForeground (from
    OpenFileInIde).  Each is adapted to this unit's commands and style.

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
  gllIdeAutomation - in-IDE automation server

  The commands here are the ones only the IDE needs - the ToolsAPI set, and tree_text for the
  debugger panes - kept out of the shared gllAutomationServer package so that stays VCL-only and
  the same for every host. They register themselves through TAutomationServer.RegisterCommand.

  PROVENANCE: the command set was chosen after reading GxInspect (GExperts' inspection server,
  ^/GxInspect/trunk), whose README documents what each of these IDE operations really does when
  measured. Until 2026-10-30 only that behaviour was taken and every line was written here against
  ToolsAPI.pas. On 2026-10-30 (Ian: port or reimplement, whichever is better per feature) the
  self-contained routines named in the header were ported from svn r6031 and adapted; the rest of
  that day's commands (modules, projects, actions, the designer's selection, the breakpoint
  properties) were reimplemented. The findings that shaped a command are cited at the command.
*)
/// <summary>
///   ToolsAPI commands for the in-IDE automation server: closing the IDE without it stopping to
///   ask, walking and clicking the main menu, executing actions, opening, saving and closing modules,
///   choosing the active project, driving the form designer, and driving the IDE's own debugger.
/// </summary>
unit gllIdeAutomation.IdeCommands;

{$IF CompilerVersion < 37.0}
  {$MESSAGE FATAL 'gllIdeAutomation requires Delphi 13 Florence or later.'}
{$IFEND}

interface

/// <summary>
///   Registers every command in this unit with the automation server and installs the debugger
///   notifier the waiting commands rely on. Call once, on the main thread, after the server started.
/// </summary>
procedure RegisterIdeCommands;

/// <summary>Removes the commands and the debugger notifier again. Safe to call when never registered.</summary>
procedure UnregisterIdeCommands;

implementation

uses
  System.SysUtils, System.Classes, System.JSON, System.TypInfo, System.SyncObjs, System.Diagnostics,
  System.Generics.Collections, System.Math, System.Rtti,
  Winapi.Windows,
  Vcl.Forms, Vcl.Menus, Vcl.Controls, Vcl.ActnList,
  ToolsAPI,
  gllAutomationServer, gllIdeAutomation.TreeText, gllIdeAutomation.Rules;

const
  /// <summary>How long <c>ide_quit</c> and <c>ide_menu_click</c> wait before acting, so their answer is on the wire first.</summary>
  DEFER_MS            = 150;
  /// <summary>Default wait, in milliseconds, of a step or run-to for the process to stop again.</summary>
  STEP_WAIT_MS        = 10000;
  /// <summary>Polling step while waiting for the debugger to report a stop.</summary>
  WAIT_POLL_MS        = 20;
  /// <summary>Default number of call-stack frames returned.</summary>
  STACK_DEFAULT_MAX   = 100;
  /// <summary>Default number of bytes <c>debug_memory</c> reads.</summary>
  MEMORY_DEFAULT      = 64;
  /// <summary>Upper bound on the bytes <c>debug_memory</c> reads in one request.</summary>
  MEMORY_MAX          = 4096;
  /// <summary>Size, in characters, of the buffer the evaluator writes its result into.</summary>
  EVAL_BUFFER_CHARS   = 65536;
  /// <summary>Deepest menu branch <c>ide_menu</c> will expand.</summary>
  MENU_MAX_DEPTH      = 6;

  /// <summary>Process states in which the debugger has the process stopped and will answer about it.</summary>
  STOPPED_STATES      = [ psStopped, psFault, psResFault, psException ];
  /// <summary>Process states that end a wait: stopped, or gone.</summary>
  WAIT_END_STATES     = STOPPED_STATES + [ psTerminated, psNoProcess ];

  /// <summary>Every command this unit registers, so that unregistering cannot miss one.</summary>
  COMMAND_NAMES: array[ 0..37 ] of string = (
    'tree_text', 'ide_modified', 'ide_quit', 'ide_menu', 'ide_menu_click',
    'ide_open_file', 'ide_modules', 'ide_close_module', 'ide_save', 'ide_projects', 'ide_set_project',
    'ide_actions', 'ide_action',
    'ide_designer_show', 'ide_designer_screenshot', 'ide_designer_selection', 'ide_designer_select',
    'ide_designer_deselect', 'ide_view_as_text', 'ide_view_as_form',
    'debug_state', 'debug_attach', 'debug_detach', 'debug_pause', 'debug_run', 'debug_step',
    'debug_run_to', 'debug_terminate', 'debug_threads', 'debug_set_thread', 'debug_stack',
    'debug_registers', 'debug_memory', 'debug_disasm', 'debug_eval', 'debug_breakpoints', 'debug_breakpoint_set',
    'debug_breakpoint_delete' );

type
  /// <summary>
  ///   Counts the debugger's stops, so that a command on a worker thread can wait for the next one.
  ///   The IDE calls it on the main thread; the count is read from worker threads.
  /// </summary>
  TStopWatcher = class( TNotifierObject, IOTADebuggerNotifier, IOTADebuggerNotifier90 )
  public
    /// <summary>Not used.</summary>
    /// <param name="Process">The new process.</param>
    procedure ProcessCreated( const Process: IOTAProcess );
    /// <summary>Counts as a stop: a waiter must not sit out its timeout for a process that has gone.</summary>
    /// <param name="Process">The process that ended.</param>
    procedure ProcessDestroyed( const Process: IOTAProcess );
    /// <summary>Not used.</summary>
    /// <param name="Breakpoint">The breakpoint.</param>
    procedure BreakpointAdded( const Breakpoint: IOTABreakpoint );
    /// <summary>Not used.</summary>
    /// <param name="Breakpoint">The breakpoint.</param>
    procedure BreakpointDeleted( const Breakpoint: IOTABreakpoint );
    /// <summary>Not used.</summary>
    /// <param name="Breakpoint">The breakpoint.</param>
    procedure BreakpointChanged( const Breakpoint: IOTABreakpoint );
    /// <summary>Not used.</summary>
    /// <param name="Process">The now-current process.</param>
    procedure CurrentProcessChanged( const Process: IOTAProcess );
    /// <summary>Counts a stop whenever the new state is one that ends a wait.</summary>
    /// <param name="Process">The process whose state changed.</param>
    procedure ProcessStateChanged( const Process: IOTAProcess );
    /// <summary>Lets every launch go ahead.</summary>
    /// <param name="Project">The project being launched.</param>
    /// <returns>Always True.</returns>
    function  BeforeProgramLaunch( const Project: IOTAProject ): Boolean;
    /// <summary>Not used.</summary>
    procedure ProcessMemoryChanged;
  end;

  /// <summary>One entry of the list of what the IDE holds unsaved.</summary>
  TModifiedEntry = record
    /// <summary>The file, or the project file when <c>Kind</c> is <c>options</c>.</summary>
    FileName : string;
    /// <summary><c>buffer</c> for an edited file, <c>options</c> for changed project options.</summary>
    Kind     : string;
    /// <summary>True when the file does not exist on disk yet, so saving it would open Save As.</summary>
    Untitled : Boolean;
    /// <summary>The module holding it.</summary>
    Module   : IOTAModule;
    /// <summary>The module's own file name, captured up front: a closed module must not be asked for it.</summary>
    ModuleFileName : string;
  end;

var
  /// <summary>Number of stops seen so far; only ever incremented. See <see cref="TStopWatcher"/>.</summary>
  GStopGeneration   : Integer = 0;
  /// <summary>Index the debugger returned for our notifier, or -1 while none is installed.</summary>
  GNotifierIndex    : Integer = -1;

{ ── TStopWatcher ────────────────────────────────────────────────────────── }

procedure TStopWatcher.ProcessCreated( const Process: IOTAProcess );
begin
end;

procedure TStopWatcher.ProcessDestroyed( const Process: IOTAProcess );
begin

  TInterlocked.Increment( GStopGeneration );

end;

procedure TStopWatcher.BreakpointAdded( const Breakpoint: IOTABreakpoint );
begin
end;

procedure TStopWatcher.BreakpointDeleted( const Breakpoint: IOTABreakpoint );
begin
end;

procedure TStopWatcher.BreakpointChanged( const Breakpoint: IOTABreakpoint );
begin
end;

procedure TStopWatcher.CurrentProcessChanged( const Process: IOTAProcess );
begin
end;

procedure TStopWatcher.ProcessStateChanged( const Process: IOTAProcess );
begin

  if Assigned( Process ) and ( Process.ProcessState in WAIT_END_STATES ) then
    TInterlocked.Increment( GStopGeneration );

end;

function TStopWatcher.BeforeProgramLaunch( const Project: IOTAProject ): Boolean;
begin

  Result := True;

end;

procedure TStopWatcher.ProcessMemoryChanged;
begin
end;

{ ── Helpers ─────────────────────────────────────────────────────────────── }

/// <summary>Reads the stop count from any thread.</summary>
/// <returns>The current value of <see cref="GStopGeneration"/>.</returns>
function StopGeneration: Integer;
begin

  Result := TInterlocked.CompareExchange( GStopGeneration, 0, 0 );

end;

/// <summary>
///   Runs <paramref name="AProc"/> on the main thread after a short delay, so that the answer to the
///   command that scheduled it has been written before it runs. A menu command that opens a modal
///   dialog would otherwise hold the answer until somebody closed the dialog.
/// </summary>
/// <param name="AProc">What to run.</param>
procedure DeferToMainThread( const AProc: TThreadProcedure );
begin

  TThread.CreateAnonymousThread(
    procedure
    begin
      Sleep( DEFER_MS );
      TThread.Queue( nil, AProc );
    end ).Start;

end;

/// <summary>Formats an address or register as 16 hex digits.</summary>
/// <param name="AValue">The value.</param>
/// <returns>For example <c>00000000004A1F30</c>.</returns>
function Hex64( AValue: UInt64 ): string;
begin

  Result := IntToHex( AValue, 16 );

end;

/// <summary>The name of an enumeration value without its lower-case prefix, e.g. <c>psStopped</c> gives <c>stopped</c>.</summary>
/// <param name="ATypeInfo">The enumeration's type information.</param>
/// <param name="AValue">The ordinal value.</param>
/// <returns>The name with its prefix removed and its first letter lower-cased.</returns>
function EnumText( ATypeInfo: PTypeInfo; AValue: Integer ): string;
begin

  Result := GetEnumName( ATypeInfo, AValue );
  var iStart := 1;
  while ( iStart <= Length( Result ) ) and CharInSet( Result[ iStart ], [ 'a'..'z' ] ) do
    Inc( iStart );
  if iStart <= Length( Result ) then
  begin
    Result := Copy( Result, iStart, MaxInt );
    Result[ 1 ] := LowerCase( Result[ 1 ] )[ 1 ];
  end;

end;

/// <summary>The IDE's module services.</summary>
/// <returns>The service.</returns>
/// <exception cref="EAutoError"><c>NoService</c> when the IDE does not offer it.</exception>
function ModuleServices: IOTAModuleServices;
begin

  if not Supports( BorlandIDEServices, IOTAModuleServices, Result ) then
    raise EAutoError.CreateCode( 'NoService', 'The IDE offers no module services' );

end;

/// <summary>The IDE's debugger services.</summary>
/// <returns>The service.</returns>
/// <exception cref="EAutoError"><c>NoService</c> when the IDE does not offer it.</exception>
function DebuggerServices: IOTADebuggerServices;
begin

  if not Supports( BorlandIDEServices, IOTADebuggerServices, Result ) then
    raise EAutoError.CreateCode( 'NoService', 'The IDE offers no debugger services' );

end;

{ ── ide_modified / ide_quit ─────────────────────────────────────────────── }

/// <summary>
///   Everything the IDE would stop and ask about on closing: every edited file, and every project
///   whose options changed. A project group that has never been saved is left out - the IDE
///   invents one round a single project, never saves it and never asks about it (GxInspect,
///   measured over four closes).
/// </summary>
/// <returns>The list, possibly empty.</returns>
function CollectModified: TArray<TModifiedEntry>;
begin

  var oList := TList<TModifiedEntry>.Create;
  try
    var oServices := ModuleServices;
    for var iModule := 0 to oServices.ModuleCount - 1 do
    begin
      var oModule := oServices.Modules[ iModule ];
      if Supports( oModule, IOTAProjectGroup ) and not FileExists( oModule.FileName ) then
        Continue;

      for var iFile := 0 to oModule.ModuleFileCount - 1 do
      begin
        var oEditor := oModule.ModuleFileEditors[ iFile ];
        if Assigned( oEditor ) and oEditor.Modified then
        begin
          var rEntry: TModifiedEntry;
          rEntry.FileName := oEditor.FileName;
          rEntry.Kind     := 'buffer';
          rEntry.Untitled := not FileExists( oEditor.FileName );
          rEntry.Module   := oModule;
          rEntry.ModuleFileName := oModule.FileName;
          oList.Add( rEntry );
        end;
      end;

      var oProject: IOTAProject;
      if Supports( oModule, IOTAProject, oProject ) and Assigned( oProject.ProjectOptions ) and
        oProject.ProjectOptions.ModifiedState then
      begin
        var rEntry: TModifiedEntry;
        rEntry.FileName := oProject.FileName;
        rEntry.Kind     := 'options';
        rEntry.Untitled := not FileExists( oProject.FileName );
        rEntry.Module   := oModule;
        rEntry.ModuleFileName := oModule.FileName;
        oList.Add( rEntry );
      end;
    end;

    Result := oList.ToArray;
  finally
    oList.Free;
  end;

end;

/// <summary>Renders the modified list as JSON.</summary>
/// <param name="AEntries">The entries.</param>
/// <returns>An array of <c>{ file, kind, untitled }</c>.</returns>
function ModifiedToJSON( const AEntries: TArray<TModifiedEntry> ): TJSONArray;
begin

  Result := TJSONArray.Create;
  for var rEntry in AEntries do
  begin
    var oItem := TJSONObject.Create;
    Result.AddElement( oItem );
    oItem.AddPair( 'file', rEntry.FileName );
    oItem.AddPair( 'kind', rEntry.Kind );
    oItem.AddPair( 'untitled', TJSONBool.Create( rEntry.Untitled ) );
  end;

end;

/// <summary><c>ide_modified</c>: what the IDE holds unsaved, without closing anything.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ count, modified:[ { file, kind, untitled } ] }</c>.</returns>
function CmdIdeModified( AReq: TJSONObject ): TJSONValue;
begin

  var aEntries := CollectModified;
  var oRes := TJSONObject.Create;
  oRes.AddPair( 'count', TJSONNumber.Create( Length( aEntries ) ) );
  oRes.AddPair( 'modified', ModifiedToJSON( aEntries ) );
  Result := oRes;

end;

/// <summary>
///   <c>ide_quit</c>: closes the IDE without leaving it waiting on a question nobody can answer.
///   The IDE's "save changes?" prompt is modal - in Delphi 13 a VCL <c>TMessageForm</c> captioned
///   "Confirm" (measured; GxInspect saw a plain API message box in older IDEs) - so a script that
///   reaches it waits for a human. So the default looks first and refuses instead.
/// </summary>
/// <remarks>
///   This is the main-thread half; <see cref="CmdIdeQuit"/> runs on the worker, ends any debug session first and
///   waits for it, then synchronises this.  Prefer <c>discard</c> to <c>save</c> in scripts. The IDE modifies files
///   merely by opening them - a project is upgraded to the running IDE's version, and a form loses or gains
///   properties such as <c>OldCreateOrder</c> - so saving what it holds writes churn nobody asked for (GxInspect).
/// </remarks>
/// <param name="sMode">
///   <c>refuse</c> (close only when nothing is unsaved), <c>save</c> (save everything first), <c>discard</c>
///   (force-close every modified module, losing the changes) or <c>ask</c> (close and let the IDE ask whatever it likes).
/// </param>
/// <returns><c>{ closing:true, mode, saved|discarded:[...] }</c>; the IDE closes shortly after the answer.</returns>
/// <exception cref="EAutoError">
///   <c>Modified</c> in refuse mode when anything is unsaved, with the list in <c>error.data</c>;
///   <c>Untitled</c> in save mode when a file has never been saved, since saving it opens Save As;
///   <c>SaveFailed</c> / <c>CloseFailed</c> when the IDE declined.
/// </exception>
function QuitOnMainThread( const sMode: string ): TJSONObject;
begin

  var aEntries := CollectModified;
  var oRes := TJSONObject.Create;
  try
    oRes.AddPair( 'mode', sMode );

    if sMode = 'refuse' then
    begin
      if Length( aEntries ) > 0 then
        raise EAutoError.CreateCodeData( 'Modified',
          Format( '%d unsaved item(s); closing would stop and ask. Use mode save, discard or ask', [ Length( aEntries ) ] ),
          ModifiedToJSON( aEntries ) );
    end
    else if sMode = 'save' then
    begin
      var oUntitled := TJSONArray.Create;
      try
        for var rEntry in aEntries do
          if rEntry.Untitled then
            oUntitled.Add( rEntry.FileName );
      except
        oUntitled.Free;
        raise;
      end;
      if oUntitled.Count > 0 then
        raise EAutoError.CreateCodeData( 'Untitled', 'These have never been saved, and saving them would open Save As',
          oUntitled );
      oUntitled.Free;

      //  One save per module: a form's .pas and .dfm are two entries of the same module.
      var oDone := TStringList.Create;
      try
        oDone.CaseSensitive := False;
        var oSaved := TJSONArray.Create;
        oRes.AddPair( 'saved', oSaved );
        for var rEntry in aEntries do
        begin
          if oDone.IndexOf( rEntry.ModuleFileName ) >= 0 then
            Continue;
          oDone.Add( rEntry.ModuleFileName );
          if not rEntry.Module.Save( False, True ) then
            raise EAutoError.CreateCode( 'SaveFailed', 'The IDE did not save ' + rEntry.ModuleFileName );
          oSaved.Add( rEntry.ModuleFileName );
        end;
      finally
        oDone.Free;
      end;
    end
    else if sMode = 'discard' then
    begin
      //  One close per module, and the module is found afresh each time: closing a project closes
      //  its units too, and an interface to a closed module must not be used again.
      var oDone := TStringList.Create;
      try
        oDone.CaseSensitive := False;
        var oDiscarded := TJSONArray.Create;
        oRes.AddPair( 'discarded', oDiscarded );
        for var rEntry in aEntries do
        begin
          if oDone.IndexOf( rEntry.ModuleFileName ) >= 0 then
            Continue;
          oDone.Add( rEntry.ModuleFileName );
          var oModule := ModuleServices.FindModule( rEntry.ModuleFileName );
          if oModule = nil then
            Continue;
          if not oModule.CloseModule( True ) then
            raise EAutoError.CreateCode( 'CloseFailed', 'The IDE did not close ' + rEntry.ModuleFileName );
          oDiscarded.Add( rEntry.ModuleFileName );
        end;
      finally
        oDone.Free;
      end;
    end
    else if sMode <> 'ask' then
      raise EAutoError.CreateCode( 'BadRequest', 'ide_quit mode is refuse, save, discard or ask' );

    DeferToMainThread(
      procedure
      begin
        if Assigned( Application.MainForm ) then
          Application.MainForm.Close;
      end );

    oRes.AddPair( 'closing', TJSONBool.Create( True ) );
    Result := oRes;
  except
    oRes.Free;
    raise;
  end;

end;

/// <summary>
///   <c>ide_quit</c> (worker thread): closes the IDE without leaving it waiting on a question nobody can answer.  A
///   debug session would make it ask whether to end the session, so that is refused unless the caller said to end it -
///   and then it is ended FIRST, and waited for, before anything is closed: <c>Terminate</c> does not wait, and the
///   debugger handles the process's exit on the main thread, which is why this runs on the worker.
/// </summary>
/// <param name="AReq">The request: <c>mode?</c> (refuse, save, discard or ask; see <see cref="QuitOnMainThread"/>), <c>terminate?</c>.</param>
/// <returns>As <see cref="QuitOnMainThread"/>, plus <c>terminated</c> when processes were ended.</returns>
/// <exception cref="EAutoError">
///   <c>BadRequest</c> for an unknown mode (checked before anything else); <c>Debugging</c> while a process is being
///   debugged, in any mode but <c>ask</c>, without <c>terminate:true</c>; <c>TerminateFailed</c> when the processes were
///   still there after <c>QUIT_TERMINATE_WAIT_MS</c>; and <see cref="QuitOnMainThread"/>'s codes.
/// </exception>
function CmdIdeQuit( AReq: TJSONObject ): TJSONValue;
const
  QUIT_TERMINATE_WAIT_MS = 15000;
begin

  var sMode := LowerCase( Trim( OptString( AReq, 'mode', 'refuse' ) ) );
  if ( sMode <> 'refuse' ) and ( sMode <> 'save' ) and ( sMode <> 'discard' ) and ( sMode <> 'ask' ) then
    raise EAutoError.CreateCode( 'BadRequest', 'ide_quit mode is refuse, save, discard or ask' );
  var bTerminate := OptBoolean( AReq, 'terminate', False );

  var iProcesses := 0;
  TThread.Synchronize( nil,
    procedure
    begin
      iProcesses := DebuggerServices.ProcessCount;
    end );

  if ( sMode <> 'ask' ) and DebugSessionBlocksQuit( iProcesses, bTerminate ) then
    raise EAutoError.CreateCode( 'Debugging', Format( 'The IDE is debugging %d process(es), and closing would stop and ask ' +
      'whether to end the session; pass "terminate":true to end them first, or debug_terminate', [ iProcesses ] ) );

  if bTerminate and ( iProcesses > 0 ) then
  begin
    TThread.Synchronize( nil,
      procedure
      begin
        var oDebugger := DebuggerServices;
        for var iProcess := oDebugger.ProcessCount - 1 downto 0 do
          oDebugger.Processes[ iProcess ].Terminate;
      end );
    var iLeft := iProcesses;
    var rWatch := TStopwatch.StartNew;
    while ( iLeft > 0 ) and ( rWatch.ElapsedMilliseconds < QUIT_TERMINATE_WAIT_MS ) do
    begin
      Sleep( 100 );
      TThread.Synchronize( nil,
        procedure
        begin
          iLeft := DebuggerServices.ProcessCount;
        end );
    end;
    if iLeft > 0 then
      raise EAutoError.CreateCode( 'TerminateFailed', Format( '%d process(es) were still being debugged %d s after being ' +
        'ended; nothing was closed', [ iLeft, QUIT_TERMINATE_WAIT_MS div 1000 ] ) );
  end;

  var oRes: TJSONObject := nil;
  TThread.Synchronize( nil,
    procedure
    begin
      oRes := QuitOnMainThread( sMode );
    end );
  if bTerminate and ( iProcesses > 0 ) then
    oRes.AddPair( 'terminated', TJSONNumber.Create( iProcesses ) );
  Result := oRes;

end;

{ ── ide_menu / ide_menu_click ───────────────────────────────────────────── }

/// <summary>The IDE's main menu.</summary>
/// <returns>The menu.</returns>
/// <exception cref="EAutoError"><c>NoService</c> when the IDE offers no main menu.</exception>
function IdeMainMenu: TMainMenu;
begin

  var oServices: INTAServices;
  if not Supports( BorlandIDEServices, INTAServices, oServices ) or ( oServices.MainMenu = nil ) then
    raise EAutoError.CreateCode( 'NoService', 'The IDE offers no main menu' );
  Result := oServices.MainMenu;

end;

/// <summary>
///   Brings a submenu up to date the way opening it would: it is clicked when it already has items
///   (the IDE fills some submenus only then - View, Desktops for one), and every item is updated from
///   its action. Without the update XE3 reported File, Open From Version Control as hidden when it
///   was not (GxInspect).
/// </summary>
/// <param name="AItem">The submenu.</param>
procedure FillSubmenu( AItem: TMenuItem );
begin

  if AItem.Count > 0 then
    AItem.Click;
  for var iChild := 0 to AItem.Count - 1 do
    AItem.Items[ iChild ].InitiateAction;

end;

/// <summary>Describes one menu item, and its children to the given depth.</summary>
/// <param name="AItem">The item.</param>
/// <param name="ADepth">How many levels of children to include; 0 for none.</param>
/// <returns><c>{ name, caption, action?, enabled, visible, checked, separator, count, items? }</c>.</returns>
function MenuItemToJSON( AItem: TMenuItem; ADepth: Integer ): TJSONObject;
begin

  Result := TJSONObject.Create;
  Result.AddPair( 'name', AItem.Name );
  Result.AddPair( 'caption', AItem.Caption );
  if Assigned( AItem.Action ) and ( AItem.Action.Name <> '' ) then
    Result.AddPair( 'action', AItem.Action.Name );
  Result.AddPair( 'enabled', TJSONBool.Create( AItem.Enabled ) );
  Result.AddPair( 'visible', TJSONBool.Create( AItem.Visible ) );
  Result.AddPair( 'checked', TJSONBool.Create( AItem.Checked ) );
  Result.AddPair( 'separator', TJSONBool.Create( AItem.IsLine ) );
  Result.AddPair( 'count', TJSONNumber.Create( AItem.Count ) );

  if ( ADepth > 0 ) and ( AItem.Count > 0 ) then
  try
    FillSubmenu( AItem );
    var oItems := TJSONArray.Create;
    Result.AddPair( 'items', oItems );
    for var iChild := 0 to AItem.Count - 1 do
      oItems.AddElement( MenuItemToJSON( AItem.Items[ iChild ], ADepth - 1 ) );
  except
    //  Filling a submenu clicks it, which runs the IDE's code and may raise; nothing half-built is left behind.
    FreeAndNil( Result );
    raise;
  end;

end;

/// <summary>The caption as a person reads it: without the accelerator ampersand.</summary>
/// <param name="AItem">The item.</param>
/// <returns>The stripped caption.</returns>
function PlainCaption( AItem: TMenuItem ): string;
begin

  Result := StripHotkey( AItem.Caption );

end;

/// <summary>
///   Finds one step of a menu path among a parent's items. A step is a component name or a caption;
///   a caption is compared without its ampersand and without case, and matches by its beginning when
///   nothing matches it whole - which names an item whose caption changes (a port number, say).
///   Names are the dependable choice in a localised IDE.
/// </summary>
/// <param name="AParent">The parent item.</param>
/// <param name="AStep">The step.</param>
/// <returns>The matching item.</returns>
/// <exception cref="EAutoError">
///   <c>NoMenuItem</c> when nothing matches, and <c>AmbiguousMenuItem</c> when a prefix matches several;
///   either carries the candidates in <c>error.data</c>.
/// </exception>
function FindMenuStep( AParent: TMenuItem; const AStep: string ): TMenuItem;
begin

  for var iChild := 0 to AParent.Count - 1 do
    if SameText( AParent.Items[ iChild ].Name, AStep ) then
      Exit( AParent.Items[ iChild ] );

  for var iChild := 0 to AParent.Count - 1 do
    if SameText( PlainCaption( AParent.Items[ iChild ] ), AStep ) then
      Exit( AParent.Items[ iChild ] );

  Result := nil;
  var oMatches := TJSONArray.Create;
  try
    for var iChild := 0 to AParent.Count - 1 do
    begin
      var oChild := AParent.Items[ iChild ];
      if ( not oChild.IsLine ) and PlainCaption( oChild ).ToLower.StartsWith( AStep.ToLower ) then
      begin
        Result := oChild;
        oMatches.Add( Format( '%s "%s"', [ oChild.Name, PlainCaption( oChild ) ] ) );
      end;
    end;

    if oMatches.Count = 1 then
    begin
      FreeAndNil( oMatches );
      Exit;
    end;

    if oMatches.Count > 1 then
    begin
      var oData := oMatches;
      oMatches := nil;
      raise EAutoError.CreateCodeData( 'AmbiguousMenuItem', Format( '"%s" matches %d items', [ AStep, oData.Count ] ), oData );
    end;

    for var iChild := 0 to AParent.Count - 1 do
      if not AParent.Items[ iChild ].IsLine then
        oMatches.Add( Format( '%s "%s"', [ AParent.Items[ iChild ].Name, PlainCaption( AParent.Items[ iChild ] ) ] ) );
    var oData := oMatches;
    oMatches := nil;
    raise EAutoError.CreateCodeData( 'NoMenuItem', Format( 'Nothing under "%s" is called "%s"',
      [ PlainCaption( AParent ), AStep ] ), oData );
  finally
    oMatches.Free;
  end;

end;

/// <summary>
///   Resolves a path of steps separated by <c>|</c>, from the menu bar down, filling each submenu
///   before looking inside it.
/// </summary>
/// <param name="APath">The path, e.g. <c>Tools|Options</c>.</param>
/// <param name="AChain">Receives every item on the way, the target last.</param>
/// <returns>The target item.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> for an empty path, otherwise as <see cref="FindMenuStep"/>.</exception>
function ResolveMenuPath( const APath: string; out AChain: TArray<TMenuItem> ): TMenuItem;
begin

  var aSteps := APath.Split( [ '|' ] );
  if Length( aSteps ) = 0 then
    raise EAutoError.CreateCode( 'BadRequest', 'An empty menu path' );

  Result := IdeMainMenu.Items;
  AChain := [];
  for var sStep in aSteps do
  begin
    if Trim( sStep ) = '' then
      raise EAutoError.CreateCode( 'BadRequest', 'A menu path step is empty: ' + APath );
    if Length( AChain ) > 0 then
      FillSubmenu( Result );
    Result := FindMenuStep( Result, Trim( sStep ) );
    AChain := AChain + [ Result ];
  end;

end;

/// <summary><c>ide_menu</c>: the menu bar, or the branch a path names.</summary>
/// <param name="AReq">The request: <c>path?</c> and <c>depth?</c> (default 1, at most <c>MENU_MAX_DEPTH</c>).</param>
/// <returns>Without a path <c>{ items:[...] }</c> for the menu bar; with one the item and its branch.</returns>
function CmdIdeMenu( AReq: TJSONObject ): TJSONValue;
begin

  var iDepth := OptInteger( AReq, 'depth', 1 );
  if iDepth < 0 then iDepth := 0;
  if iDepth > MENU_MAX_DEPTH then iDepth := MENU_MAX_DEPTH;

  var sPath := OptString( AReq, 'path', '' );

  if Trim( sPath ) = '' then
  begin
    var oBar := IdeMainMenu.Items;
    var oRes := TJSONObject.Create;
    try
      var oItems := TJSONArray.Create;
      oRes.AddPair( 'items', oItems );
      //  Filling a submenu clicks it, which runs the IDE's own code and may raise.
      for var iItem := 0 to oBar.Count - 1 do
        oItems.AddElement( MenuItemToJSON( oBar.Items[ iItem ], iDepth - 1 ) );
    except
      oRes.Free;
      raise;
    end;
    Exit( oRes );
  end;

  var aChain: TArray<TMenuItem>;
  Result := MenuItemToJSON( ResolveMenuPath( sPath, aChain ), iDepth );

end;

/// <summary>
///   <c>ide_menu_click</c>: clicks a main-menu item, including the ones no action sits behind - a
///   plugin's entries, the user's tools, Reopen and Desktops. The click happens just after the
///   answer, because a command that opens a dialog would otherwise hold the answer up until
///   somebody closed it; ask <c>dialogs</c> next.
/// </summary>
/// <param name="AReq">The request: <c>path</c>.</param>
/// <returns><c>{ clickScheduled:true, item }</c>.</returns>
/// <exception cref="EAutoError">
///   <c>NotClickable</c> for a separator, a submenu, or an item that is disabled or hidden or sits in one
///   that is - <c>TMenuItem.Click</c> on those does nothing and says nothing about it (GxInspect).
/// </exception>
function CmdIdeMenuClick( AReq: TJSONObject ): TJSONValue;
begin

  var sPath := NeedString( AReq, 'path', 'ide_menu_click' );
  var aChain: TArray<TMenuItem>;
  var oItem := ResolveMenuPath( sPath, aChain );

  if oItem.IsLine then
    raise EAutoError.CreateCode( 'NotClickable', sPath + ' is a separator' );
  if oItem.Count > 0 then
    raise EAutoError.CreateCode( 'NotClickable', sPath + ' is a submenu; name an item inside it' );

  oItem.InitiateAction;
  for var oStep in aChain do
    if not ( oStep.Enabled and oStep.Visible ) then
      raise EAutoError.CreateCode( 'NotClickable', Format( '"%s" is %s', [ PlainCaption( oStep ),
        if oStep.Enabled then 'hidden' else 'disabled' ] ) );

  var sName := oItem.Name;
  DeferToMainThread(
    procedure
    begin
      //  Found again rather than captured: in the gap the IDE may have rebuilt the menu, and a
      //  freed TMenuItem must not be clicked.
      var aAgain: TArray<TMenuItem>;
      try
        var oAgain := ResolveMenuPath( sPath, aAgain );
        if oAgain.Name = sName then
          oAgain.Click;
      except
        on EAutoError do ;   // the item went away in the gap: there is nobody left to tell
      end;
    end );

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'clickScheduled', TJSONBool.Create( True ) );
  oRes.AddPair( 'item', MenuItemToJSON( oItem, 0 ) );
  Result := oRes;

end;

{ ── Debugger helpers ────────────────────────────────────────────────────── }

/// <summary>
///   The process the debugger commands act on: the debugger's current one, which follows the ACTIVE
///   PROJECT. With a process stopped under one project and another made active, the process is still
///   there but no longer current, and every command here refuses (GxInspect, measured in 10.2).
/// </summary>
/// <returns>The process.</returns>
/// <exception cref="EAutoError"><c>NoProcess</c> when nothing is being debugged, or none is current.</exception>
function RequireProcess: IOTAProcess;
begin

  var oDebugger := DebuggerServices;
  Result := oDebugger.CurrentProcess;
  if Assigned( Result ) then Exit;

  if oDebugger.ProcessCount > 0 then
    raise EAutoError.CreateCode( 'NoProcess', Format( 'The active project has no process being debugged, but the IDE is ' +
      'debugging %d; the current process follows the active project, so make the one that was run active again',
      [ oDebugger.ProcessCount ] ) );
  raise EAutoError.CreateCode( 'NoProcess', 'The IDE is not debugging anything' );

end;

/// <summary>The current process, which must be stopped.</summary>
/// <returns>The process.</returns>
/// <exception cref="EAutoError"><c>NotStopped</c> when it is running.</exception>
function RequireStoppedProcess: IOTAProcess;
begin

  Result := RequireProcess;
  if Result.ProcessState not in STOPPED_STATES then
    raise EAutoError.CreateCode( 'NotStopped', Format( 'The process is %s; pause it first',
      [ EnumText( TypeInfo( TOTAProcessState ), Ord( Result.ProcessState ) ) ] ) );

end;

/// <summary>A thread of a process by its OS thread id, or the current thread when the request names none.</summary>
/// <param name="AProcess">The process.</param>
/// <param name="AReq">The request: <c>thread?</c>, an OS thread id.</param>
/// <returns>The thread.</returns>
/// <exception cref="EAutoError"><c>NoThread</c> when there is no such thread.</exception>
function ResolveThread( const AProcess: IOTAProcess; AReq: TJSONObject ): IOTAThread;
begin

  var iThreadId := OptInteger( AReq, 'thread', 0 );
  if iThreadId = 0 then
  begin
    Result := AProcess.CurrentThread;
    if Result = nil then
      raise EAutoError.CreateCode( 'NoThread', 'The process has no current thread' );
    Exit;
  end;

  for var iThread := 0 to AProcess.ThreadCount - 1 do
  begin
    Result := AProcess.Threads[ iThread ];
    if Integer( Result.OSThreadID ) = iThreadId then Exit;
  end;
  raise EAutoError.CreateCode( 'NoThread', Format( 'The process has no thread %d', [ iThreadId ] ) );

end;

/// <summary>Describes a thread: its id, state, and where it is when stopped.</summary>
/// <param name="AThread">The thread.</param>
/// <param name="ACurrent">True when it is the process's current thread.</param>
/// <returns><c>{ thread, name, state, current, file, line }</c>.</returns>
function ThreadToJSON( const AThread: IOTAThread; ACurrent: Boolean ): TJSONObject;
begin

  Result := TJSONObject.Create;
  Result.AddPair( 'thread', TJSONNumber.Create( Int64( AThread.OSThreadID ) ) );
  Result.AddPair( 'name', AThread.ThreadName );
  Result.AddPair( 'state', EnumText( TypeInfo( TOTAThreadState ), Ord( AThread.State ) ) );
  Result.AddPair( 'current', TJSONBool.Create( ACurrent ) );
  if AThread.State = tsStopped then
  begin
    Result.AddPair( 'file', AThread.CurrentFile );
    Result.AddPair( 'line', TJSONNumber.Create( Int64( AThread.CurrentLine ) ) );
  end;

end;

/// <summary>Describes the current process and, when it is stopped, where its current thread is.</summary>
/// <returns><c>{ state, pid, exe, location? }</c>, or <c>{ state:"noProcess" }</c>.</returns>
function DescribeCurrentProcess: TJSONObject;
begin

  Result := TJSONObject.Create;
  var oProcess := DebuggerServices.CurrentProcess;
  if oProcess = nil then
  begin
    Result.AddPair( 'state', 'noProcess' );
    Exit;
  end;

  Result.AddPair( 'state', EnumText( TypeInfo( TOTAProcessState ), Ord( oProcess.ProcessState ) ) );
  Result.AddPair( 'pid', TJSONNumber.Create( Int64( oProcess.OSProcessId ) ) );
  Result.AddPair( 'exe', oProcess.ExeName );
  if ( oProcess.ProcessState in STOPPED_STATES ) and Assigned( oProcess.CurrentThread ) then
    Result.AddPair( 'location', ThreadToJSON( oProcess.CurrentThread, True ) );

end;

type
  /// <summary>Where an enumeration callback hands back the window it found.</summary>
  PWindowHandle = ^HWND;

/// <summary><c>EnumThreadWindows</c> callback: stops at the first visible, enabled Win32 dialog (<c>#32770</c>) and hands it back.</summary>
/// <param name="AWnd">The window.</param>
/// <param name="AParam">Points to the <c>HWND</c> that receives it.</param>
/// <returns>False once one is found, to end the enumeration.</returns>
function EnumPromptProc( AWnd: HWND; AParam: LPARAM ): BOOL; stdcall;
begin

  Result := True;
  if not ( IsWindowVisible( AWnd ) and IsWindowEnabled( AWnd ) ) then Exit;
  var aClass: array[ 0..63 ] of Char;
  aClass[ 0 ] := #0;
  GetClassName( AWnd, aClass, Length( aClass ) );
  if string( aClass ) = '#32770' then
  begin
    PWindowHandle( AParam )^ := AWnd;
    Result := False;
  end;

end;

/// <summary>
///   The caption of the modal prompt the IDE is showing, if any: a VCL form shown modally (the debugger's
///   exception notification, "Confirm") or a Win32 dialog of the main thread. Called on the main thread.
/// </summary>
/// <returns>The caption, '' when nothing is asking; <c>(untitled)</c> for a prompt with no caption.</returns>
function ModalPromptCaption: string;
begin

  for var iForm := 0 to Screen.FormCount - 1 do
  begin
    var oForm := Screen.Forms[ iForm ];
    if oForm.Visible and ( fsModal in oForm.FormState ) then
      Exit( if oForm.Caption <> '' then oForm.Caption else '(untitled)' );
  end;

  var hPrompt: HWND := 0;
  EnumThreadWindows( MainThreadID, @EnumPromptProc, LPARAM( @hPrompt ) );
  if hPrompt = 0 then Exit( '' );
  var aText: array[ 0..255 ] of Char;
  aText[ 0 ] := #0;
  GetWindowText( hPrompt, aText, Length( aText ) );
  Result := if string( aText ) <> '' then string( aText ) else '(untitled)';

end;

/// <summary>
///   Refuses to set the process going while the IDE is asking something. The debugger's exception notification
///   leaves the process reading as stopped, yet a step or run issued meanwhile does nothing visible: the command
///   waited out its timeout and answered <c>stopped:false</c>, and the process ran on once the box was answered
///   (GxInspect, measured).
/// </summary>
/// <param name="AWhat">What was asked for, for the message.</param>
/// <exception cref="EAutoError"><c>IdeAsking</c> while a modal prompt is up; <c>error.data</c> is its caption.</exception>
procedure RefuseWhileIdeAsks( const AWhat: string );
begin

  var sCaption := ModalPromptCaption;
  if sCaption <> '' then
    raise EAutoError.CreateCodeData( 'IdeAsking', Format( 'The IDE is asking something ("%s"), and a %s does nothing until it ' +
      'is answered; answer it with dialogs first', [ sCaption, AWhat ] ), TJSONString.Create( sCaption ) );

end;

/// <summary>
///   Refuses to step the debugger's break-in thread. After a pause the current thread is the one Windows creates to
///   break into the process (<c>ntdll.DbgUiRemoteBreakin</c>), which exists for that alone: stepping it lets the
///   process run on, and the step answers <c>stopped:false</c> (GxInspect).
/// </summary>
/// <param name="AProcess">The stopped process.</param>
/// <exception cref="EAutoError"><c>BreakInThread</c> when its current thread is the break-in thread.</exception>
procedure RefuseBreakInThread( const AProcess: IOTAProcess );
begin

  var oThread := AProcess.CurrentThread;
  if oThread = nil then Exit;

  //  The top three frames: the break-in thread stops in DbgBreakPoint, called from DbgUiRemoteBreakin.  DbgBreakPoint
  //  alone is not enough - a program thread calling DebugBreak stops there too.
  var aTop: TArray<string> := [];
  if oThread.StartCallStackAccess = csAccessible then
  try
    for var iFrame := 1 to Min( oThread.CallCount, 3 ) do
      aTop := aTop + [ oThread.CallHeaders[ iFrame ] ];
  finally
    oThread.EndCallStackAccess;
  end
  else
    oThread.EndCallStackAccess;

  if IsBreakInStack( aTop ) then
    raise EAutoError.CreateCode( 'BreakInThread', Format( 'The current thread %d is the debugger''s break-in thread (%s), and ' +
      'stepping it lets the process run on; make one of the program''s threads current with debug_set_thread (debug_threads ' +
      'lists them)', [ oThread.OSThreadID, string.Join( ' < ', aTop ) ] ) );

end;

/// <summary>
///   Sets the current process running in the given mode and, on this worker thread, waits for the
///   debugger to report the next stop. Run from a worker because the IDE processes debug events on its
///   main thread: waiting there would stop the very thing being waited for.
/// </summary>
/// <param name="AReq">The request: <c>wait?</c>, in milliseconds.</param>
/// <param name="ARunMode">How to run; ignored when <paramref name="AStart"/> is given.</param>
/// <param name="ADefaultWaitMs">The wait when the request gives none; 0 answers at once.</param>
/// <param name="AStart">
///   Called on the main thread IN PLACE OF <c>IOTAProcess.Run</c>, for a start the process interface does
///   not do properly (run to cursor); nil to run in <paramref name="ARunMode"/>.
/// </param>
/// <param name="ARefuseBreakIn">True for a step, which must not step the debugger's break-in thread.</param>
/// <returns><c>{ stopped, waitedMs, state, pid?, exe?, location? }</c>; <c>stopped</c> false means the wait ran out.</returns>
/// <exception cref="EAutoError">
///   <c>NoProcess</c> / <c>NotStopped</c>; <c>IdeAsking</c> while the IDE shows a modal prompt; <c>BreakInThread</c> (a step
///   only); or whatever <paramref name="AStart"/> raises.
/// </exception>
function RunAndWait( AReq: TJSONObject; ARunMode: TOTARunMode; ADefaultWaitMs: Integer; const AStart: TProc;
  ARefuseBreakIn: Boolean ): TJSONValue;
begin

  var iWait := WaitArgument( AReq, ADefaultWaitMs );
  var iGeneration := 0;

  TThread.Synchronize( nil,
    procedure
    begin
      var oProcess := RequireStoppedProcess;
      RefuseWhileIdeAsks( 'run or step' );
      if ARefuseBreakIn then
        RefuseBreakInThread( oProcess );
      iGeneration := StopGeneration;
      if Assigned( AStart ) then
        AStart
      else
        oProcess.Run( ARunMode );
    end );

  var bStopped := False;
  var rWatch := TStopwatch.StartNew;
  while rWatch.ElapsedMilliseconds < iWait do
  begin
    if StopGeneration <> iGeneration then
    begin
      bStopped := True;
      Break;
    end;
    Sleep( WAIT_POLL_MS );
  end;

  var oRes: TJSONObject := nil;
  TThread.Synchronize( nil,
    procedure
    begin
      oRes := DescribeCurrentProcess;
    end );
  oRes.AddPair( 'stopped', TJSONBool.Create( bStopped ) );
  oRes.AddPair( 'waitedMs', TJSONNumber.Create( rWatch.ElapsedMilliseconds ) );
  Result := oRes;

end;

/// <summary>
///   Finds a source file the IDE knows by a full path or by its name alone, as the request gave it.
///   A bare name is looked up among the files open in the IDE.
/// </summary>
/// <param name="AFile">The file as given.</param>
/// <returns>The full path when one is found; otherwise <paramref name="AFile"/> unchanged.</returns>
function ResolveSourceFile( const AFile: string ): string;
begin

  Result := AFile;
  if FileExists( AFile ) then Exit;

  var oServices := ModuleServices;
  for var iModule := 0 to oServices.ModuleCount - 1 do
  begin
    var oModule := oServices.Modules[ iModule ];
    for var iFile := 0 to oModule.ModuleFileCount - 1 do
    begin
      var oEditor := oModule.ModuleFileEditors[ iFile ];
      if Assigned( oEditor ) and SameText( ExtractFileName( oEditor.FileName ), ExtractFileName( AFile ) ) then
        Exit( oEditor.FileName );
    end;
  end;

end;

{ ── debug_* commands ────────────────────────────────────────────────────── }

/// <summary><c>debug_state</c>: every process the IDE is debugging, which is current, and where it stopped.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ activeProject, processes:[ { pid, exe, state, current } ], current }</c>.</returns>
function CmdDebugState( AReq: TJSONObject ): TJSONValue;
begin

  var oDebugger := DebuggerServices;
  var oRes := TJSONObject.Create;
  try
    var oProject := GetActiveProject;
    if Assigned( oProject ) then
      oRes.AddPair( 'activeProject', oProject.FileName )
    else
      oRes.AddPair( 'activeProject', TJSONNull.Create );

    var oCurrent := oDebugger.CurrentProcess;
    var oProcesses := TJSONArray.Create;
    oRes.AddPair( 'processes', oProcesses );
    for var iProcess := 0 to oDebugger.ProcessCount - 1 do
    begin
      var oProcess := oDebugger.Processes[ iProcess ];
      var oItem := TJSONObject.Create;
      oProcesses.AddElement( oItem );
      oItem.AddPair( 'pid', TJSONNumber.Create( Int64( oProcess.OSProcessId ) ) );
      oItem.AddPair( 'exe', oProcess.ExeName );
      oItem.AddPair( 'state', EnumText( TypeInfo( TOTAProcessState ), Ord( oProcess.ProcessState ) ) );
      oItem.AddPair( 'current', TJSONBool.Create( Assigned( oCurrent ) and ( oCurrent.OSProcessId = oProcess.OSProcessId ) ) );
    end;

    oRes.AddPair( 'current', DescribeCurrentProcess );
    Result := oRes;
  except
    oRes.Free;
    raise;
  end;

end;

/// <summary>
///   <c>debug_attach</c>: attaches the IDE's debugger to a running process. Answered before the
///   attach has happened - ask <c>debug_state</c> whether it took. Reset in the IDE detaches rather
///   than kills the process; <c>debug_terminate</c> is what ends it.
/// </summary>
/// <param name="AReq">The request: <c>pid</c>, <c>pause?</c> (stop it the moment it is attached - what you want for something wedged).</param>
/// <returns><c>{ requested:true, pid, pause }</c>.</returns>
/// <exception cref="EAutoError">
///   <c>NoProject</c> when no project is open: the debugger takes the platform from the active project,
///   and without one the attach silently does nothing (GxInspect).
/// </exception>
function CmdDebugAttach( AReq: TJSONObject ): TJSONValue;
begin

  var iPid := NeedInteger( AReq, 'pid', 'debug_attach' );
  var bPause := OptBoolean( AReq, 'pause', False );

  if GetActiveProject = nil then
    raise EAutoError.CreateCode( 'NoProject', 'Open a project first: the debugger takes the platform to debug from it, ' +
      'and without one attaching silently does nothing' );

  DebuggerServices.AttachProcess( iPid, bPause, True );

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'requested', TJSONBool.Create( True ) );
  oRes.AddPair( 'pid', TJSONNumber.Create( Int64( iPid ) ) );
  oRes.AddPair( 'pause', TJSONBool.Create( bPause ) );
  Result := oRes;

end;

/// <summary><c>debug_detach</c>: detaches from the current process, which keeps running.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ detached:true, pid }</c>.</returns>
function CmdDebugDetach( AReq: TJSONObject ): TJSONValue;
begin

  var oProcess := RequireProcess;
  var iPid := oProcess.OSProcessId;
  oProcess.Detach;

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'detached', TJSONBool.Create( True ) );
  oRes.AddPair( 'pid', TJSONNumber.Create( Int64( iPid ) ) );
  Result := oRes;

end;

/// <summary>
///   <c>debug_pause</c>: asks the current process to stop. Answered before it has; <c>debug_state</c>
///   confirms it. A paused process cannot answer its own automation server - talk to the IDE.
/// </summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ requested:true, pid }</c>.</returns>
function CmdDebugPause( AReq: TJSONObject ): TJSONValue;
begin

  var oProcess := RequireProcess;
  oProcess.Pause;

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'requested', TJSONBool.Create( True ) );
  oRes.AddPair( 'pid', TJSONNumber.Create( Int64( oProcess.OSProcessId ) ) );
  Result := oRes;

end;

/// <summary><c>debug_run</c>: lets a stopped process run; with <c>wait</c>, answers once it stops again (a breakpoint, say).</summary>
/// <param name="AReq">The request: <c>wait?</c> in milliseconds, default 0.</param>
/// <returns>As <see cref="RunAndWait"/>.</returns>
function CmdDebugRun( AReq: TJSONObject ): TJSONValue;
begin

  Result := RunAndWait( AReq, ormRun, 0, nil, False );

end;

/// <summary><c>debug_step</c>: one step, answered once the process has stopped again, saying where.</summary>
/// <param name="AReq">
///   The request: <c>mode?</c> = <c>over</c> (default), <c>into</c>, <c>out</c> (run until the function
///   returns), <c>toSource</c>, <c>instInto</c> or <c>instOver</c>; and <c>wait?</c>.
/// </param>
/// <returns>As <see cref="RunAndWait"/>.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> for an unknown mode.</exception>
function CmdDebugStep( AReq: TJSONObject ): TJSONValue;
begin

  var sMode := OptString( AReq, 'mode', 'over' );

  var eMode: TOTARunMode;
  if SameText( sMode, 'over' ) then eMode := ormStmtStepOver
  else if SameText( sMode, 'into' ) then eMode := ormStmtStepInto
  else if SameText( sMode, 'out' ) then eMode := ormRunUntilReturn
  else if SameText( sMode, 'toSource' ) then eMode := ormStmtStepToSource
  else if SameText( sMode, 'instInto' ) then eMode := ormInstStepInto
  else if SameText( sMode, 'instOver' ) then eMode := ormInstStepOver
  else
    raise EAutoError.CreateCode( 'BadRequest', 'debug_step mode is over, into, out, toSource, instInto or instOver' );

  Result := RunAndWait( AReq, eMode, STEP_WAIT_MS, nil, True );

end;

/// <summary>
///   <c>debug_run_to</c>: runs to a source line, the way Run to Cursor does: the file is opened, the
///   cursor placed on the line, and the editor view's own Run to Cursor invoked.
/// </summary>
/// <param name="AReq">The request: <c>file</c> (a path, or a name open in the IDE), <c>line</c>, <c>wait?</c>.</param>
/// <returns>As <see cref="RunAndWait"/>.</returns>
/// <exception cref="EAutoError">
///   <c>NoFile</c> when the IDE cannot open the file, <c>NoEditor</c> when it shows no view of it or the view
///   offers no Run to Cursor.
/// </exception>
/// <remarks>
///   NOT <c>IOTAProcess.Run( ormRunToCursor )</c>: in Delphi 13 that runs straight past the line the cursor
///   was just put on - measured here, and by GxInspect before.
/// </remarks>
function CmdDebugRunTo( AReq: TJSONObject ): TJSONValue;
begin

  var sFile := NeedString( AReq, 'file', 'debug_run_to' );
  var iLine := NeedInteger( AReq, 'line', 'debug_run_to' );

  Result := RunAndWait( AReq, ormRun, STEP_WAIT_MS,
    procedure
    begin
      var sPath := ResolveSourceFile( sFile );
      var oActions: IOTAActionServices;
      if not Supports( BorlandIDEServices, IOTAActionServices, oActions ) or not oActions.OpenFile( sPath ) then
        raise EAutoError.CreateCode( 'NoFile', 'The IDE could not open ' + sPath );

      var oEditors: IOTAEditorServices;
      if not Supports( BorlandIDEServices, IOTAEditorServices, oEditors ) or ( oEditors.TopView = nil ) or
        not SameFileName( oEditors.TopView.Buffer.FileName, sPath ) then
        raise EAutoError.CreateCode( 'NoEditor', 'The IDE shows no editor view of ' + sPath );

      var oEditActions: IOTAEditActions;
      if not Supports( oEditors.TopView, IOTAEditActions, oEditActions ) then
        raise EAutoError.CreateCode( 'NoEditor', 'The editor view of ' + sPath + ' offers no Run to Cursor' );

      var rPos: TOTAEditPos;
      rPos.Col  := 1;
      rPos.Line := iLine;
      oEditors.TopView.CursorPos := rPos;
      oEditors.TopView.MoveViewToCursor;
      oEditors.TopView.Paint;
      oEditActions.RunToCursor;
    end, False );

end;

/// <summary><c>debug_terminate</c>: ends the current process - the one command here that does.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ terminated:true, pid }</c>.</returns>
function CmdDebugTerminate( AReq: TJSONObject ): TJSONValue;
begin

  var oProcess := RequireProcess;
  var iPid := oProcess.OSProcessId;
  oProcess.Terminate;

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'terminated', TJSONBool.Create( True ) );
  oRes.AddPair( 'pid', TJSONNumber.Create( Int64( iPid ) ) );
  Result := oRes;

end;

/// <summary><c>debug_threads</c>: the current process's threads.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ pid, threads:[ { thread, name, state, current, file?, line? } ] }</c>.</returns>
function CmdDebugThreads( AReq: TJSONObject ): TJSONValue;
begin

  var oProcess := RequireProcess;
  var iCurrent: LongWord := 0;
  if Assigned( oProcess.CurrentThread ) then
    iCurrent := oProcess.CurrentThread.OSThreadID;

  var oRes := TJSONObject.Create;
  try
    oRes.AddPair( 'pid', TJSONNumber.Create( Int64( oProcess.OSProcessId ) ) );
    var oThreads := TJSONArray.Create;
    oRes.AddPair( 'threads', oThreads );
    for var iThread := 0 to oProcess.ThreadCount - 1 do
    begin
      var oThread := oProcess.Threads[ iThread ];
      oThreads.AddElement( ThreadToJSON( oThread, oThread.OSThreadID = iCurrent ) );
    end;
  except
    oRes.Free;
    raise;
  end;
  Result := oRes;

end;

/// <summary><c>debug_set_thread</c>: makes a thread current, which is the one stack, registers and eval use by default.</summary>
/// <param name="AReq">The request: <c>thread</c>, an OS thread id.</param>
/// <returns>The thread as <see cref="ThreadToJSON"/> describes it.</returns>
function CmdDebugSetThread( AReq: TJSONObject ): TJSONValue;
begin

  NeedInteger( AReq, 'thread', 'debug_set_thread' );
  var oProcess := RequireProcess;
  var oThread := ResolveThread( oProcess, AReq );
  oProcess.CurrentThread := oThread;
  Result := ThreadToJSON( oThread, True );

end;

/// <summary><c>debug_stack</c>: a thread's call stack, as the Call Stack pane shows it.</summary>
/// <param name="AReq">The request: <c>thread?</c> (default the current one), <c>max?</c> frames (default 100).</param>
/// <returns><c>{ thread, count, frames:[ { index, header, file, line } ] }</c>.</returns>
/// <exception cref="EAutoError">
///   <c>StackBusy</c> when the debugger has the stack temporarily unavailable (ask again shortly);
///   <c>StackInaccessible</c> when it cannot be read at all.
/// </exception>
function CmdDebugStack( AReq: TJSONObject ): TJSONValue;
begin

  var oThread := ResolveThread( RequireStoppedProcess, AReq );
  var iMax := OptInteger( AReq, 'max', STACK_DEFAULT_MAX );
  if iMax < 1 then iMax := 1;
  //  The debugger's headers carry every field of every object parameter (over 20 KB for one form Self, 2026-10-30):
  //  the routine's name by default, the whole header only on request.
  var bParams := OptBoolean( AReq, 'params', False );

  case oThread.StartCallStackAccess of
    csWait:
      begin
        oThread.EndCallStackAccess;
        raise EAutoError.CreateCode( 'StackBusy', 'The call stack is temporarily unavailable; ask again shortly' );
      end;
    csInaccessible:
      begin
        oThread.EndCallStackAccess;
        raise EAutoError.CreateCode( 'StackInaccessible', 'The debugger cannot read this thread''s call stack' );
      end;
  end;

  var oRes := TJSONObject.Create;
  try
    try
      var iCount := oThread.CallCount;
      oRes.AddPair( 'thread', TJSONNumber.Create( Int64( oThread.OSThreadID ) ) );
      oRes.AddPair( 'count', TJSONNumber.Create( iCount ) );
      var oFrames := TJSONArray.Create;
      oRes.AddPair( 'frames', oFrames );
      //  Call headers are ONE-based.
      for var iFrame := 1 to iCount do
      begin
        if iFrame > iMax then Break;
        var sFile := '';
        var iLine := 0;
        oThread.GetCallPos( iFrame, sFile, iLine );
        var oFrame := TJSONObject.Create;
        oFrames.AddElement( oFrame );
        oFrame.AddPair( 'index', TJSONNumber.Create( iFrame ) );
        if bParams then
          oFrame.AddPair( 'header', oThread.CallHeaders[ iFrame ] )
        else
          oFrame.AddPair( 'header', BriefCallHeader( oThread.CallHeaders[ iFrame ] ) );
        oFrame.AddPair( 'file', sFile );
        oFrame.AddPair( 'line', TJSONNumber.Create( iLine ) );
      end;
    finally
      oThread.EndCallStackAccess;
    end;
  except
    //  A frame the debugger cannot read raises; the half-built answer must not be left behind.
    oRes.Free;
    raise;
  end;
  Result := oRes;

end;

/// <summary>
///   Whether the debugged process is 64-bit, asked of WINDOWS. <c>IOTAProcess.GetProcessType</c> cannot
///   be trusted for this: in the 64-bit Delphi 13 IDE it answers <c>optOSX64</c> for a Win64 program
///   (GxInspect, measured).
/// </summary>
/// <param name="AProcess">The process.</param>
/// <returns>True for a 64-bit process.</returns>
/// <exception cref="EAutoError"><c>NoAccess</c> when Windows will not say.</exception>
function ProcessIs64Bit( const AProcess: IOTAProcess ): Boolean;
const
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
begin

  var hProcess := OpenProcess( PROCESS_QUERY_LIMITED_INFORMATION, False, AProcess.OSProcessId );
  if hProcess = 0 then
    raise EAutoError.CreateCode( 'NoAccess', Format( 'Process %d cannot be opened: %s',
      [ AProcess.OSProcessId, SysErrorMessage( GetLastError ) ] ) );

  var bTargetWow: BOOL := False;
  try
    if not IsWow64Process( hProcess, bTargetWow ) then
      raise EAutoError.CreateCode( 'NoAccess', 'Windows will not say whether the process is 64-bit: ' +
        SysErrorMessage( GetLastError ) );
  finally
    CloseHandle( hProcess );
  end;

{$IFDEF CPUX64}
  Result := not bTargetWow;
{$ELSE}
  var bSelfWow: BOOL := False;
  IsWow64Process( GetCurrentProcess, bSelfWow );
  Result := bSelfWow and not bTargetWow;
{$ENDIF}

end;

/// <summary>
///   Refuses a 32-bit process in the 64-bit IDE, which attaches to one but sees only the WOW64 layer:
///   a call stack in <c>wow64cpu</c>, a context that is not the 32-bit one, and no readable memory
///   (GxInspect, measured). The 32-bit IDE handles both kinds.
/// </summary>
/// <param name="AProcess">The process.</param>
/// <param name="AWhat">What was asked for, for the message.</param>
/// <returns>True when the process is 64-bit.</returns>
/// <exception cref="EAutoError"><c>Unsupported</c> for a 32-bit process in the 64-bit IDE.</exception>
function RequireReadableBitness( const AProcess: IOTAProcess; const AWhat: string ): Boolean;
begin

  Result := ProcessIs64Bit( AProcess );
{$IFDEF CPUX64}
  if not Result then
    raise EAutoError.CreateCode( 'Unsupported', Format( 'The 64-bit IDE sees only the WOW64 layer of a 32-bit process, ' +
      'so it has no %s to give; use the 32-bit IDE', [ AWhat ] ) );
{$ENDIF}

end;

/// <summary><c>debug_registers</c>: a stopped thread's general-purpose registers.</summary>
/// <param name="AReq">The request: <c>thread?</c>.</param>
/// <returns><c>{ thread, bits, registers:{ name:hex } }</c>.</returns>
/// <exception cref="EAutoError">
///   <c>Unsupported</c> for a 32-bit process in the 64-bit IDE; <c>NotStopped</c> for a thread that is not
///   stopped, which has no context the debugger could give.
/// </exception>
/// <remarks>
///   Segment and debug registers and MXCSR are deliberately left out: in the 64-bit Delphi 13 IDE the
///   context record's fields for them held rubbish - all six segment registers the low word of RAX
///   (GxInspect, measured).
/// </remarks>
function CmdDebugRegisters( AReq: TJSONObject ): TJSONValue;
begin

  var oProcess := RequireStoppedProcess;
  var oThread := ResolveThread( oProcess, AReq );
  if oThread.State <> tsStopped then
    raise EAutoError.CreateCode( 'NotStopped', Format( 'Thread %d is %s, not stopped',
      [ oThread.OSThreadID, EnumText( TypeInfo( TOTAThreadState ), Ord( oThread.State ) ) ] ) );

  var b64 := RequireReadableBitness( oProcess, 'registers' );
  var rContext := oThread.OTAThreadContextEx;

  var oRes := TJSONObject.Create;
  try
    oRes.AddPair( 'thread', TJSONNumber.Create( Int64( oThread.OSThreadID ) ) );
    var oRegs := TJSONObject.Create;
    oRes.AddPair( 'registers', oRegs );
    if b64 then
    begin
      oRes.AddPair( 'bits', TJSONNumber.Create( 64 ) );
      oRegs.AddPair( 'rax', Hex64( rContext.win64.Rax ) );
      oRegs.AddPair( 'rbx', Hex64( rContext.win64.Rbx ) );
      oRegs.AddPair( 'rcx', Hex64( rContext.win64.Rcx ) );
      oRegs.AddPair( 'rdx', Hex64( rContext.win64.Rdx ) );
      oRegs.AddPair( 'rsi', Hex64( rContext.win64.Rsi ) );
      oRegs.AddPair( 'rdi', Hex64( rContext.win64.Rdi ) );
      oRegs.AddPair( 'rbp', Hex64( rContext.win64.Rbp ) );
      oRegs.AddPair( 'rsp', Hex64( rContext.win64.Rsp ) );
      oRegs.AddPair( 'r8',  Hex64( rContext.win64.R8 ) );
      oRegs.AddPair( 'r9',  Hex64( rContext.win64.R9 ) );
      oRegs.AddPair( 'r10', Hex64( rContext.win64.R10 ) );
      oRegs.AddPair( 'r11', Hex64( rContext.win64.R11 ) );
      oRegs.AddPair( 'r12', Hex64( rContext.win64.R12 ) );
      oRegs.AddPair( 'r13', Hex64( rContext.win64.R13 ) );
      oRegs.AddPair( 'r14', Hex64( rContext.win64.R14 ) );
      oRegs.AddPair( 'r15', Hex64( rContext.win64.R15 ) );
      oRegs.AddPair( 'rip', Hex64( rContext.win64.Rip ) );
      oRegs.AddPair( 'eflags', IntToHex( rContext.win64.EFlags, 8 ) );
    end
    else
    begin
{$IFDEF CPUX86}
      oRes.AddPair( 'bits', TJSONNumber.Create( 32 ) );
      oRegs.AddPair( 'eax', IntToHex( rContext.win32.Eax, 8 ) );
      oRegs.AddPair( 'ebx', IntToHex( rContext.win32.Ebx, 8 ) );
      oRegs.AddPair( 'ecx', IntToHex( rContext.win32.Ecx, 8 ) );
      oRegs.AddPair( 'edx', IntToHex( rContext.win32.Edx, 8 ) );
      oRegs.AddPair( 'esi', IntToHex( rContext.win32.Esi, 8 ) );
      oRegs.AddPair( 'edi', IntToHex( rContext.win32.Edi, 8 ) );
      oRegs.AddPair( 'ebp', IntToHex( rContext.win32.Ebp, 8 ) );
      oRegs.AddPair( 'esp', IntToHex( rContext.win32.Esp, 8 ) );
      oRegs.AddPair( 'eip', IntToHex( rContext.win32.Eip, 8 ) );
      oRegs.AddPair( 'eflags', IntToHex( rContext.win32.EFlags, 8 ) );
{$ENDIF}
    end;
    Result := oRes;
  except
    oRes.Free;
    raise;
  end;

end;

/// <summary>
///   <c>debug_memory</c>: bytes of the stopped process's memory, read a page at a time, so a range that
///   runs into unreadable memory still returns everything up to there and says where it stopped.
/// </summary>
/// <param name="AReq">The request: <c>address</c>, <c>count?</c> (default 64, at most 4096).</param>
/// <returns>
///   <c>{ address, requested, read, hex, stoppedAt?, reason? }</c> - <c>hex</c> is the bytes as
///   space-separated pairs; <c>stoppedAt</c> and <c>reason</c> appear when the read ended early.
/// </returns>
/// <exception cref="EAutoError">
///   <c>Unreadable</c> when not even the first byte could be read; <c>Unsupported</c> for a 32-bit process
///   in the 64-bit IDE.
/// </exception>
/// <remarks>
///   The IDE RAISES for an unreadable page rather than answering that it read nothing, and in the 64-bit
///   Delphi 13 IDE the message is "Debugger Kernel BORDBK370.DLL or BORDBK370N.DLL is missing or could not
///   be loaded" - measured here at an unmapped address. Nothing is missing; the address is not readable.
/// </remarks>
function CmdDebugMemory( AReq: TJSONObject ): TJSONValue;
const
  PAGE_BYTES = 4096;
begin

  var oProcess := RequireStoppedProcess;
  RequireReadableBitness( oProcess, 'memory' );
  var iAddress := AddressArgument( AReq, 'address', 'debug_memory' );
  var iCount := OptInteger( AReq, 'count', MEMORY_DEFAULT );
  if iCount < 1 then iCount := 1;
  if iCount > MEMORY_MAX then iCount := MEMORY_MAX;

  var naBuffer: TBytes;
  SetLength( naBuffer, iCount );
  var iDone := 0;
  var sReason := '';
  while iDone < iCount do
  begin
    var iChunk := PAGE_BYTES - Integer( ( iAddress + UInt64( iDone ) ) mod PAGE_BYTES );
    if iChunk > iCount - iDone then
      iChunk := iCount - iDone;

    var iGot := 0;
    try
      iGot := oProcess.ReadProcessMemory( TOTAAddress( iAddress + UInt64( iDone ) ), iChunk, naBuffer[ iDone ] );
    except
      //  Deliberately broad: the IDE reports an unreadable page by raising, with a class of its own
      //  choosing and a misleading message (see remarks). The failure is REPORTED in the answer, not hidden.
      on E: Exception do
        sReason := Format( '%s: %s', [ E.ClassName, E.Message ] );
    end;
    if iGot <= 0 then
    begin
      if sReason = '' then sReason := 'The debugger read nothing';
      Break;
    end;
    Inc( iDone, iGot );
    if iGot < iChunk then
    begin
      sReason := 'The debugger read part of a page';
      Break;
    end;
  end;

  if iDone = 0 then
    raise EAutoError.CreateCode( 'Unreadable', Format( 'Nothing could be read at %s. The IDE said: %s ' +
      '- which it says for ANY unreadable address; nothing is missing', [ Hex64( iAddress ), sReason ] ) );

  var oBuilder := TStringBuilder.Create( iDone * 3 );
  try
    for var iByte := 0 to iDone - 1 do
    begin
      if iByte > 0 then oBuilder.Append( ' ' );
      oBuilder.Append( IntToHex( naBuffer[ iByte ], 2 ) );
    end;

    var oRes := TJSONObject.Create;
    oRes.AddPair( 'address', Hex64( iAddress ) );
    oRes.AddPair( 'requested', TJSONNumber.Create( iCount ) );
    oRes.AddPair( 'read', TJSONNumber.Create( iDone ) );
    oRes.AddPair( 'hex', oBuilder.ToString );
    if iDone < iCount then
    begin
      oRes.AddPair( 'stoppedAt', Hex64( iAddress + UInt64( iDone ) ) );
      oRes.AddPair( 'reason', sReason );
    end;
    Result := oRes;
  finally
    oBuilder.Free;
  end;

end;

/// <summary>
///   <c>debug_eval</c>: evaluates an expression the way the IDE's evaluator does - which is the
///   point: what the IDE calls a value is not what an external debugger calls it.
/// </summary>
/// <param name="AReq">The request: <c>expr</c>, <c>thread?</c>, <c>sideEffects?</c> (allow calls into the process; default false).</param>
/// <returns><c>{ expr, result, canModify, address, size }</c>.</returns>
/// <exception cref="EAutoError">
///   <c>EvalError</c> with the evaluator's message; <c>EvalDeferred</c> when it had to call into the
///   process and has no result yet; <c>EvalBusy</c> when the evaluator is busy.
/// </exception>
function CmdDebugEval( AReq: TJSONObject ): TJSONValue;
begin

  var sExpr := NeedString( AReq, 'expr', 'debug_eval' );
  var bSideEffects := OptBoolean( AReq, 'sideEffects', False );
  var oThread := ResolveThread( RequireStoppedProcess, AReq );

  var aBuffer: TArray<Char>;
  SetLength( aBuffer, EVAL_BUFFER_CHARS );
  aBuffer[ 0 ] := #0;
  var bCanModify := False;
  var iAddress: TOTAAddress := 0;
  var iSize: LongWord := 0;
  var iValue: LongWord := 0;

  var eResult := oThread.Evaluate( sExpr, PChar( aBuffer ), Length( aBuffer ), bCanModify, bSideEffects, nil,
    iAddress, iSize, iValue );
  var sText := string( PChar( aBuffer ) );

  case eResult of
    erError:    raise EAutoError.CreateCode( 'EvalError', sText );
    erDeferred: raise EAutoError.CreateCode( 'EvalDeferred', 'The evaluator had to call into the process and has no result yet' );
    erBusy:     raise EAutoError.CreateCode( 'EvalBusy', 'The evaluator is busy; ask again shortly' );
  end;

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'expr', sExpr );
  oRes.AddPair( 'result', sText );
  oRes.AddPair( 'canModify', TJSONBool.Create( bCanModify ) );
  oRes.AddPair( 'address', Hex64( iAddress ) );
  oRes.AddPair( 'size', TJSONNumber.Create( Int64( iSize ) ) );
  Result := oRes;

end;

/// <summary>
///   Describes a source breakpoint: where it is, whether it is on, and whatever else is set on it - its condition,
///   pass count and group, what it does when hit, and the debugger's exception choices.
/// </summary>
/// <param name="ABreakpoint">The breakpoint.</param>
/// <param name="ADebugging">True while a process is being debugged, the only time the debugger can say whether the line has code.</param>
/// <returns>
///   <c>{ file, line, enabled, condition, passCount, curPassCount, group, doBreak, logMessage, evalExpression, logResult,
///   enableGroup, disableGroup, handleExceptions, ignoreExceptions, stackFramesToLog, threadCondition, validHere? }</c>.
/// </returns>
function BreakpointToJSON( const ABreakpoint: IOTABreakpoint; ADebugging: Boolean ): TJSONObject;
begin

  Result := TJSONObject.Create;
  try
    Result.AddPair( 'file', ABreakpoint.FileName );
    Result.AddPair( 'line', TJSONNumber.Create( ABreakpoint.LineNumber ) );
    Result.AddPair( 'enabled', TJSONBool.Create( ABreakpoint.Enabled ) );
    Result.AddPair( 'condition', ABreakpoint.Expression );
    Result.AddPair( 'passCount', TJSONNumber.Create( ABreakpoint.PassCount ) );
    Result.AddPair( 'curPassCount', TJSONNumber.Create( ABreakpoint.CurPassCount ) );
    Result.AddPair( 'group', ABreakpoint.GroupName );
    Result.AddPair( 'doBreak', TJSONBool.Create( ABreakpoint.DoBreak ) );
    Result.AddPair( 'logMessage', ABreakpoint.LogMessage );
    Result.AddPair( 'evalExpression', ABreakpoint.EvalExpression );
    Result.AddPair( 'logResult', TJSONBool.Create( ABreakpoint.LogResult ) );
    Result.AddPair( 'enableGroup', ABreakpoint.EnableGroup );
    Result.AddPair( 'disableGroup', ABreakpoint.DisableGroup );
    Result.AddPair( 'handleExceptions', TJSONBool.Create( ABreakpoint.DoHandleExceptions ) );
    Result.AddPair( 'ignoreExceptions', TJSONBool.Create( ABreakpoint.DoIgnoreExceptions ) );
    Result.AddPair( 'stackFramesToLog', TJSONNumber.Create( ABreakpoint.StackFramesToLog ) );
    Result.AddPair( 'threadCondition', ABreakpoint.ThreadCondition );
    if ADebugging then
      Result.AddPair( 'validHere', TJSONBool.Create( ABreakpoint.ValidInCurrentProcess ) );
  except
    FreeAndNil( Result );
    raise;
  end;

end;

/// <summary>Finds a source breakpoint by file (a path, or a name alone) and line.</summary>
/// <param name="AFile">The file.</param>
/// <param name="ALine">The line.</param>
/// <returns>The breakpoint, or nil.</returns>
function FindSourceBreakpoint( const AFile: string; ALine: Integer ): IOTASourceBreakpoint;
begin

  var oDebugger := DebuggerServices;
  var bBareName := ExtractFilePath( AFile ) = '';
  for var iBreakpoint := 0 to oDebugger.SourceBkptCount - 1 do
  begin
    Result := oDebugger.SourceBkpts[ iBreakpoint ];
    if Result.LineNumber <> ALine then Continue;
    if bBareName and SameText( ExtractFileName( Result.FileName ), AFile ) then Exit;
    if ( not bBareName ) and SameFileName( Result.FileName, AFile ) then Exit;
  end;
  Result := nil;

end;

/// <summary><c>debug_breakpoints</c>: every source breakpoint.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ breakpoints:[ { file, line, enabled, condition, passCount } ] }</c>.</returns>
function CmdDebugBreakpoints( AReq: TJSONObject ): TJSONValue;
begin

  var oDebugger := DebuggerServices;
  var bDebugging := oDebugger.ProcessCount > 0;
  var oRes := TJSONObject.Create;
  try
    var oList := TJSONArray.Create;
    oRes.AddPair( 'breakpoints', oList );
    for var iBreakpoint := 0 to oDebugger.SourceBkptCount - 1 do
      oList.AddElement( BreakpointToJSON( oDebugger.SourceBkpts[ iBreakpoint ], bDebugging ) );
  except
    oRes.Free;
    raise;
  end;
  Result := oRes;

end;

/// <summary>
///   <c>debug_breakpoint_set</c>: sets a source breakpoint, or updates the one already on that line. Every argument is
///   read and checked BEFORE anything is created, so a bad one cannot leave a half-set breakpoint behind; an argument
///   left out leaves that property as it is.
/// </summary>
/// <param name="AReq">
///   The request: <c>file</c>, <c>line</c>, <c>enabled?</c> (default true), <c>condition?</c>, <c>passCount?</c>,
///   <c>group?</c>, <c>doBreak?</c>, <c>logMessage?</c>, <c>evalExpression?</c>, <c>logResult?</c>, <c>enableGroup?</c>,
///   <c>disableGroup?</c>, <c>handleExceptions?</c>, <c>ignoreExceptions?</c>, <c>stackFramesToLog?</c>,
///   <c>threadCondition?</c> - the ToolsAPI's own properties under the names <c>debug_breakpoints</c> reports.
/// </param>
/// <returns>The breakpoint as <see cref="BreakpointToJSON"/> describes it, with a <c>note</c> while its line cannot be checked.</returns>
/// <exception cref="EAutoError">
///   <c>BadRequest</c> for an argument of the wrong type, or a negative pass count or frame count; <c>BreakpointFailed</c>
///   when the debugger declined to create it.
/// </exception>
/// <remarks>
///   A breakpoint on a line with no code is accepted, and the debugger rejects it only once the process runs (GxInspect),
///   so a script would wait for a stop that cannot come. While a process is being debugged <c>validHere</c> says whether
///   the line has code; otherwise the answer says it is not yet known.
/// </remarks>
function CmdDebugBreakpointSet( AReq: TJSONObject ): TJSONValue;
begin

  var sFile := ResolveSourceFile( NeedString( AReq, 'file', 'debug_breakpoint_set' ) );
  var iLine := NeedInteger( AReq, 'line', 'debug_breakpoint_set' );

  var bEnabled := OptBoolean( AReq, 'enabled', True );
  var sCondition := OptString( AReq, 'condition', '' );
  var iPassCount := OptInteger( AReq, 'passCount', 0 );
  var sGroup := OptString( AReq, 'group', '' );
  var bDoBreak := OptBoolean( AReq, 'doBreak', True );
  var sLogMessage := OptString( AReq, 'logMessage', '' );
  var sEvalExpression := OptString( AReq, 'evalExpression', '' );
  var bLogResult := OptBoolean( AReq, 'logResult', False );
  var sEnableGroup := OptString( AReq, 'enableGroup', '' );
  var sDisableGroup := OptString( AReq, 'disableGroup', '' );
  var bHandleExceptions := OptBoolean( AReq, 'handleExceptions', False );
  var bIgnoreExceptions := OptBoolean( AReq, 'ignoreExceptions', False );
  var iStackFrames := OptInteger( AReq, 'stackFramesToLog', 0 );
  var sThreadCondition := OptString( AReq, 'threadCondition', '' );
  if ( iPassCount < 0 ) or ( iStackFrames < 0 ) then
    raise EAutoError.CreateCode( 'BadRequest', '"passCount" and "stackFramesToLog" are 0 for none, or more' );

  var oDebugger := DebuggerServices;
  var oBreakpoint: IOTABreakpoint := FindSourceBreakpoint( sFile, iLine );
  var bCreated := oBreakpoint = nil;
  if bCreated then
    oBreakpoint := oDebugger.NewSourceBreakpoint( sFile, iLine, nil );
  if oBreakpoint = nil then
    raise EAutoError.CreateCode( 'BreakpointFailed', Format( 'The debugger set no breakpoint at %s line %d', [ sFile, iLine ] ) );

  if AReq.GetValue( 'condition' ) <> nil then oBreakpoint.Expression := sCondition;
  if AReq.GetValue( 'passCount' ) <> nil then oBreakpoint.PassCount := iPassCount;
  if AReq.GetValue( 'group' ) <> nil then oBreakpoint.GroupName := sGroup;
  if AReq.GetValue( 'doBreak' ) <> nil then oBreakpoint.DoBreak := bDoBreak;
  if AReq.GetValue( 'logMessage' ) <> nil then oBreakpoint.LogMessage := sLogMessage;
  if AReq.GetValue( 'evalExpression' ) <> nil then oBreakpoint.EvalExpression := sEvalExpression;
  if AReq.GetValue( 'logResult' ) <> nil then oBreakpoint.LogResult := bLogResult;
  if AReq.GetValue( 'enableGroup' ) <> nil then oBreakpoint.EnableGroup := sEnableGroup;
  if AReq.GetValue( 'disableGroup' ) <> nil then oBreakpoint.DisableGroup := sDisableGroup;
  if AReq.GetValue( 'handleExceptions' ) <> nil then oBreakpoint.DoHandleExceptions := bHandleExceptions;
  if AReq.GetValue( 'ignoreExceptions' ) <> nil then oBreakpoint.DoIgnoreExceptions := bIgnoreExceptions;
  if AReq.GetValue( 'stackFramesToLog' ) <> nil then oBreakpoint.StackFramesToLog := iStackFrames;
  if AReq.GetValue( 'threadCondition' ) <> nil then oBreakpoint.ThreadCondition := sThreadCondition;
  //  Only when asked, or on a new breakpoint: changing the condition of a breakpoint switched off must not switch it on.
  if bCreated or ( AReq.GetValue( 'enabled' ) <> nil ) then
    oBreakpoint.Enabled := bEnabled;

  var bDebugging := oDebugger.ProcessCount > 0;
  var oRes := BreakpointToJSON( oBreakpoint, bDebugging );
  if not bDebugging then
    oRes.AddPair( 'note', 'Whether this line has code to stop on is known only once the process runs; the debugger ' +
      'rejects a breakpoint on a line without code then' )
  else if not oBreakpoint.ValidInCurrentProcess then
    oRes.AddPair( 'note', 'The debugger reports no code on this line in the process being debugged, so it will not stop here' );
  Result := oRes;

end;

/// <summary><c>debug_breakpoint_delete</c>: removes the source breakpoint on a line.</summary>
/// <param name="AReq">The request: <c>file</c>, <c>line</c>.</param>
/// <returns><c>{ deleted:true, file, line }</c>.</returns>
/// <exception cref="EAutoError"><c>NoBreakpoint</c> when there is none on that line.</exception>
function CmdDebugBreakpointDelete( AReq: TJSONObject ): TJSONValue;
begin

  var sFile := NeedString( AReq, 'file', 'debug_breakpoint_delete' );
  var iLine := NeedInteger( AReq, 'line', 'debug_breakpoint_delete' );

  var oBreakpoint := FindSourceBreakpoint( sFile, iLine );
  if oBreakpoint = nil then
    raise EAutoError.CreateCode( 'NoBreakpoint', Format( 'No breakpoint at %s line %d', [ sFile, iLine ] ) );

  var sFound := oBreakpoint.FileName;
  DebuggerServices.RemoveBreakpoint( oBreakpoint );

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'deleted', TJSONBool.Create( True ) );
  oRes.AddPair( 'file', sFound );
  oRes.AddPair( 'line', TJSONNumber.Create( iLine ) );
  Result := oRes;

end;

{ ── Modules, files and projects ────────────────────────────────────────── }

/// <summary>What kind of module the IDE has open. A project group answers to <c>IOTAProject</c> as well, so it is asked about first.</summary>
/// <param name="AModule">The module.</param>
/// <returns><c>projectGroup</c>, <c>project</c> or <c>module</c>.</returns>
function ModuleKind( const AModule: IOTAModule ): string;
begin

  if Supports( AModule, IOTAProjectGroup ) then
    Result := 'projectGroup'
  else if Supports( AModule, IOTAProject ) then
    Result := 'project'
  else
    Result := 'module';

end;

/// <summary>What an editor of a module is: the source, the form, or something else.</summary>
/// <param name="AEditor">The editor.</param>
/// <returns><c>source</c>, <c>form</c> or <c>other</c>.</returns>
function EditorKind( const AEditor: IOTAEditor ): string;
begin

  if Supports( AEditor, IOTASourceEditor ) then
    Result := 'source'
  else if Supports( AEditor, IOTAFormEditor ) then
    Result := 'form'
  else
    Result := 'other';

end;

/// <summary>Whether closing a module would stop and ask about unsaved work: an edited file, or changed project options.</summary>
/// <param name="AModule">The module.</param>
/// <returns>True when something of it is unsaved.</returns>
function ModuleIsModified( const AModule: IOTAModule ): Boolean;
begin

  for var iFile := 0 to AModule.ModuleFileCount - 1 do
  begin
    var oEditor := AModule.ModuleFileEditors[ iFile ];
    if Assigned( oEditor ) and oEditor.Modified then
      Exit( True );
  end;

  var oProject: IOTAProject;
  Result := Supports( AModule, IOTAProject, oProject ) and Assigned( oProject.ProjectOptions ) and
    oProject.ProjectOptions.ModifiedState;

end;

/// <summary>A module's own file and its editors' files, which is what a file argument may name it by.</summary>
/// <param name="AModule">The module; nil gives no names.</param>
/// <returns>The file names, the module's own first.</returns>
function ModuleFileNames( const AModule: IOTAModule ): TArray<string>;
begin

  Result := [];
  if AModule = nil then Exit;
  Result := [ AModule.FileName ];
  for var iFile := 0 to AModule.ModuleFileCount - 1 do
  begin
    var oEditor := AModule.ModuleFileEditors[ iFile ];
    if Assigned( oEditor ) then
      Result := Result + [ oEditor.FileName ];
  end;

end;

/// <summary>
///   The open module a file argument names: <c>.</c> or nothing for the one in front, otherwise the ONE whose own file or
///   one of whose editors' files matches, by path or by name alone (see <see cref="FindFileMatch"/>).
/// </summary>
/// <param name="AFileId">The argument.</param>
/// <returns>The module.</returns>
/// <exception cref="EAutoError">
///   <c>NoModule</c> when nothing open matches; <c>Ambiguous</c> when a bare name matches several (with <c>Unit1.pas</c> open
///   from two projects, the first used to be taken); <c>BadRequest</c> for a relative path.
/// </exception>
function FindModule( const AFileId: string ): IOTAModule;
begin

  var oServices := ModuleServices;
  if IsCurrentFileId( AFileId ) then
  begin
    Result := oServices.CurrentModule;
    if Result = nil then
      raise EAutoError.CreateCode( 'NoModule', 'Nothing is open' );
    Exit;
  end;

  var aModules: TArray<IOTAModule> := [];
  var aNames: TArray<TArray<string>> := [];
  for var iModule := 0 to oServices.ModuleCount - 1 do
  begin
    aModules := aModules + [ oServices.Modules[ iModule ] ];
    aNames := aNames + [ ModuleFileNames( oServices.Modules[ iModule ] ) ];
  end;
  var iFound := FindFileMatch( aNames, Trim( AFileId ), False );
  if iFound < 0 then
    raise EAutoError.CreateCode( 'NoModule', Format( 'Nothing open is called %s; ide_modules lists what is', [ AFileId ] ) );
  Result := aModules[ iFound ];

end;

/// <summary>
///   Opens a file in the IDE without leaving the IDE in front of whatever had the focus: <c>OpenFile</c> brings the
///   IDE forward, which a script driving another window does not want (GxInspect).
/// </summary>
/// <param name="AFile">The file.</param>
/// <returns>What <c>IOTAActionServices.OpenFile</c> answered.</returns>
/// <exception cref="EAutoError"><c>NoService</c> when the IDE offers no action services.</exception>
function OpenFileKeepingForeground( const AFile: string ): Boolean;
begin

  var oActions: IOTAActionServices;
  if not Supports( BorlandIDEServices, IOTAActionServices, oActions ) then
    raise EAutoError.CreateCode( 'NoService', 'The IDE offers no action services' );
  var hForeground := GetForegroundWindow;
  Result := oActions.OpenFile( AFile );
  if hForeground <> 0 then
    SetForegroundWindow( hForeground );

end;

/// <summary>
///   <c>ide_open_file</c>: opens a file in the IDE's editor, or brings it forward when it is open already.
/// </summary>
/// <param name="AReq">The request: <c>file</c>, a full path (forward slashes and surrounding quotes are accepted).</param>
/// <returns><c>{ opened, current, modified }</c>: the file, the module now in front, and whether it is already marked modified.</returns>
/// <exception cref="EAutoError">
///   <c>NoFile</c> when it does not exist; <c>FormOpenAsText</c> when it is a unit whose <c>.dfm</c> is open as text - the
///   IDE then raises <c>EModuleAbort</c> and opens the unit anyway, so the answer would say failure for something that
///   happened (GxInspect); <c>OpenFailed</c> when the IDE declined or raised.
/// </exception>
/// <remarks>
///   Opening is enough to mark a file modified: a project is upgraded on load and a form gains or loses defaults such as
///   <c>OldCreateOrder</c>. <c>modified</c> says so, and <c>ide_quit</c> with <c>discard</c> is how to leave without
///   writing that back.
/// </remarks>
function CmdIdeOpenFile( AReq: TJSONObject ): TJSONValue;
begin

  var sFile := Trim( NeedString( AReq, 'file', 'ide_open_file' ) );
  if ( Length( sFile ) >= 2 ) and sFile.StartsWith( '"' ) and sFile.EndsWith( '"' ) then
    sFile := Copy( sFile, 2, Length( sFile ) - 2 );
  sFile := StringReplace( sFile, '/', '\', [ rfReplaceAll ] );
  //  A full path only: anything else would be resolved against the IDE's current folder, which nobody chose.
  if ( ExtractFilePath( sFile ) = '' ) or IsRelativeFileId( sFile ) then
    raise EAutoError.CreateCode( 'BadRequest', sFile + ' is not a full path' );
  sFile := ExpandFileName( sFile );
  if not FileExists( sFile ) then
    raise EAutoError.CreateCode( 'NoFile', sFile + ' does not exist' );

  if not IsFormFileName( sFile ) then
  begin
    var oServices := ModuleServices;
    for var iModule := 0 to oServices.ModuleCount - 1 do
    begin
      var oModule := oServices.Modules[ iModule ];
      if Assigned( oModule ) and IsFormFileName( oModule.FileName ) and
        SameFileName( ChangeFileExt( oModule.FileName, '' ), ChangeFileExt( sFile, '' ) ) then
        raise EAutoError.CreateCode( 'FormOpenAsText', Format( 'The form of %s is open as text (%s); ide_view_as_form it, ' +
          'or ide_close_module it, first', [ sFile, oModule.FileName ] ) );
    end;
  end;

  var bOpened: Boolean;
  try
    bOpened := OpenFileKeepingForeground( sFile );
  except
    //  Reported, not swallowed: the IDE refuses some opens by raising (EModuleAbort among them), and its message is
    //  the only account of why.
    on E: Exception do
      raise EAutoError.CreateCode( 'OpenFailed', Format( 'The IDE did not open %s: %s: %s', [ sFile, E.ClassName, E.Message ] ) );
  end;
  if not bOpened then
    raise EAutoError.CreateCode( 'OpenFailed', 'The IDE did not open ' + sFile );

  var oRes := TJSONObject.Create;
  try
    oRes.AddPair( 'opened', sFile );
    var oCurrent := ModuleServices.CurrentModule;
    if Assigned( oCurrent ) then
    begin
      oRes.AddPair( 'current', oCurrent.FileName );
      oRes.AddPair( 'modified', TJSONBool.Create( ModuleIsModified( oCurrent ) ) );
    end
    else
      oRes.AddPair( 'current', TJSONNull.Create );
  except
    oRes.Free;
    raise;
  end;
  Result := oRes;

end;

/// <summary><c>ide_modules</c>: everything the IDE has open, with the editors of each and whether it is unsaved.</summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns>
///   <c>{ current, count, modules:[ { file, kind, modified, current, editors:[ { file, kind, modified } ] } ] }</c>. The
///   editors are listed because their files are not always the module's: a form's <c>.dfm</c> has an editor of its own.
/// </returns>
function CmdIdeModules( AReq: TJSONObject ): TJSONValue;
begin

  var oServices := ModuleServices;
  var oCurrent := oServices.CurrentModule;
  var oRes := TJSONObject.Create;
  try
    if Assigned( oCurrent ) then
      oRes.AddPair( 'current', oCurrent.FileName )
    else
      oRes.AddPair( 'current', TJSONNull.Create );

    var oModules := TJSONArray.Create;
    oRes.AddPair( 'modules', oModules );
    for var iModule := 0 to oServices.ModuleCount - 1 do
    begin
      var oModule := oServices.Modules[ iModule ];
      if oModule = nil then Continue;
      var oItem := TJSONObject.Create;
      oModules.AddElement( oItem );
      oItem.AddPair( 'file', oModule.FileName );
      oItem.AddPair( 'kind', ModuleKind( oModule ) );
      oItem.AddPair( 'modified', TJSONBool.Create( ModuleIsModified( oModule ) ) );
      oItem.AddPair( 'current', TJSONBool.Create( Assigned( oCurrent ) and SameFileName( oCurrent.FileName, oModule.FileName ) ) );
      var oEditors := TJSONArray.Create;
      oItem.AddPair( 'editors', oEditors );
      for var iFile := 0 to oModule.ModuleFileCount - 1 do
      begin
        var oEditor := oModule.ModuleFileEditors[ iFile ];
        if oEditor = nil then Continue;
        var oEdit := TJSONObject.Create;
        oEditors.AddElement( oEdit );
        oEdit.AddPair( 'file', oEditor.FileName );
        oEdit.AddPair( 'kind', EditorKind( oEditor ) );
        oEdit.AddPair( 'modified', TJSONBool.Create( oEditor.Modified ) );
      end;
    end;
    oRes.AddPair( 'count', TJSONNumber.Create( oModules.Count ) );
  except
    oRes.Free;
    raise;
  end;
  Result := oRes;

end;

/// <summary>Refuses to save a module that has never been saved: saving it would open Save As, which nobody would answer.</summary>
/// <param name="AModule">The module.</param>
/// <exception cref="EAutoError"><c>Untitled</c> when its file does not exist on disk.</exception>
procedure RefuseUntitled( const AModule: IOTAModule );
begin

  if ( AModule.FileName = '' ) or not FileExists( AModule.FileName ) then
    raise EAutoError.CreateCode( 'Untitled', AModule.FileName + ' has never been saved, and saving it would open Save As; ' +
      'use discard' );

end;

/// <summary>
///   The open modules that close together with a module: for a project its open units, for a project group the open
///   projects and their open units, for anything else none.  Found by file name each time: a module must not be held
///   across a close.
/// </summary>
/// <param name="AModule">The module being closed.</param>
/// <returns>The file names of the open modules that close with it, itself not included.</returns>
function FilesClosedWith( const AModule: IOTAModule ): TArray<string>;

  procedure AddProject( const AProject: IOTAProject; var AFiles: TArray<string> );
  begin

    for var iUnit := 0 to AProject.GetModuleCount - 1 do
    begin
      var oInfo := AProject.GetModule( iUnit );
      if ( oInfo = nil ) or ( oInfo.FileName = '' ) then Continue;
      var oOpen := ModuleServices.FindModule( oInfo.FileName );
      if Assigned( oOpen ) and not SameFileName( oOpen.FileName, AProject.FileName ) then
        AFiles := AFiles + [ oOpen.FileName ];
    end;

  end;

begin

  Result := [];
  var oGroup: IOTAProjectGroup;
  var oProject: IOTAProject;
  if Supports( AModule, IOTAProjectGroup, oGroup ) then
  begin
    for var iProject := 0 to oGroup.ProjectCount - 1 do
      if Assigned( oGroup.Projects[ iProject ] ) then
      begin
        Result := Result + [ oGroup.Projects[ iProject ].FileName ];
        AddProject( oGroup.Projects[ iProject ], Result );
      end;
  end
  else if Supports( AModule, IOTAProject, oProject ) then
    AddProject( oProject, Result );

end;

/// <summary>
///   <c>ide_close_module</c>: closes one module, refusing one with unsaved changes unless told what to do with them -
///   the IDE's "save changes?" box would otherwise wait for a person (the rule <c>ide_quit</c> follows too).  A project
///   or project group closes its open units with it, so their unsaved changes count as its own, and its debug session
///   would make the IDE ask whether to end it.
/// </summary>
/// <param name="AReq">The request: <c>file</c> (a path, a name, or <c>.</c>), <c>mode?</c> = <c>refuse</c> (default), <c>save</c> or <c>discard</c>.</param>
/// <returns><c>{ closed, mode, saved?, discarded? }</c>; <c>saved</c> / <c>discarded</c> list the modules that were.</returns>
/// <exception cref="EAutoError">
///   <c>NoModule</c> / <c>Ambiguous</c>; <c>Modified</c> in refuse mode with something unsaved, listed in <c>error.data</c>;
///   <c>Untitled</c> in save mode for a module never saved; <c>Debugging</c> for a project or group while anything is being
///   debugged; <c>SaveFailed</c> / <c>CloseFailed</c> when the IDE declined; <c>BadRequest</c> for an unknown mode.
/// </exception>
function CmdIdeCloseModule( AReq: TJSONObject ): TJSONValue;
begin

  var sMode := CloseModeArgument( AReq );
  var oModule := FindModule( NeedString( AReq, 'file', 'ide_close_module' ) );
  var sFile := oModule.FileName;
  var aWith := FilesClosedWith( oModule );

  var bProject := Supports( oModule, IOTAProject );
  var oDebugger: IOTADebuggerServices;
  if bProject and Supports( BorlandIDEServices, IOTADebuggerServices, oDebugger ) and ( oDebugger.ProcessCount > 0 ) then
    raise EAutoError.CreateCode( 'Debugging', Format( 'The IDE is debugging %d process(es), and closing %s would stop and ask ' +
      'whether to end the session; debug_terminate first', [ oDebugger.ProcessCount, sFile ] ) );

  //  Everything that would be asked about: the module itself and what closes with it.
  var aModified: TArray<string> := [];
  for var sName in [ sFile ] + aWith do
  begin
    var oOpen := ModuleServices.FindModule( sName );
    if Assigned( oOpen ) and ModuleIsModified( oOpen ) then
      aModified := aModified + [ sName ];
  end;

  if ( sMode = 'refuse' ) and ( Length( aModified ) > 0 ) then
  begin
    var oData := TJSONArray.Create;
    for var sName in aModified do
      oData.Add( sName );
    raise EAutoError.CreateCodeData( 'Modified', Format( '%d unsaved module(s) would close with %s, and closing would stop ' +
      'and ask; use mode save or discard', [ Length( aModified ), sFile ] ), oData );
  end;

  var oRes := TJSONObject.Create;
  try
    oRes.AddPair( 'mode', sMode );
    if sMode = 'save' then
    begin
      for var sName in aModified do
        RefuseUntitled( ModuleServices.FindModule( sName ) );
      var oSaved := TJSONArray.Create;
      oRes.AddPair( 'saved', oSaved );
      for var sName in aModified do
      begin
        var oOpen := ModuleServices.FindModule( sName );
        if Assigned( oOpen ) and not oOpen.Save( False, True ) then
          raise EAutoError.CreateCode( 'SaveFailed', 'The IDE did not save ' + sName );
        oSaved.Add( sName );
      end;
    end
    else if sMode = 'discard' then
    begin
      //  The units first, each forced shut on its own, so the project's close has nothing left to ask about.
      var oDiscarded := TJSONArray.Create;
      oRes.AddPair( 'discarded', oDiscarded );
      for var sName in aModified do
      begin
        if SameFileName( sName, sFile ) then Continue;
        var oOpen := ModuleServices.FindModule( sName );
        if Assigned( oOpen ) and not oOpen.CloseModule( True ) then
          raise EAutoError.CreateCode( 'CloseFailed', 'The IDE did not close ' + sName );
        oDiscarded.Add( sName );
      end;
      if ModuleIsModified( oModule ) then
        oDiscarded.Add( sFile );
    end;

    if not oModule.CloseModule( sMode = 'discard' ) then
      raise EAutoError.CreateCode( 'CloseFailed', 'The IDE did not close ' + sFile );
    oRes.AddPair( 'closed', sFile );
  except
    oRes.Free;
    raise;
  end;
  Result := oRes;

end;

/// <summary><c>ide_save</c>: saves one module - for a form, its unit and its <c>.dfm</c> together.</summary>
/// <param name="AReq">The request: <c>file?</c> (a path, a name, or <c>.</c> - the default - for the module in front).</param>
/// <returns><c>{ saved, wasModified }</c>.</returns>
/// <exception cref="EAutoError"><c>NoModule</c>; <c>Untitled</c> for a module never saved; <c>SaveFailed</c> when the IDE declined.</exception>
function CmdIdeSave( AReq: TJSONObject ): TJSONValue;
begin

  var oModule := FindModule( OptString( AReq, 'file', '.' ) );
  RefuseUntitled( oModule );
  var bWasModified := ModuleIsModified( oModule );
  if not oModule.Save( False, True ) then
    raise EAutoError.CreateCode( 'SaveFailed', 'The IDE did not save ' + oModule.FileName );

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'saved', oModule.FileName );
  oRes.AddPair( 'wasModified', TJSONBool.Create( bWasModified ) );
  Result := oRes;

end;

/// <summary>The open project group. The IDE keeps one even round a single project, so this answers wherever a project is open.</summary>
/// <returns>The group.</returns>
/// <exception cref="EAutoError"><c>NoProject</c> when none is open.</exception>
function RequireProjectGroup: IOTAProjectGroup;
begin

  Result := ModuleServices.MainProjectGroup;
  if Result = nil then
    raise EAutoError.CreateCode( 'NoProject', 'No project is open' );

end;

/// <summary>
///   <c>ide_projects</c>: the projects of the open group and which is active - the one Compile, Run and the debugger act
///   on. Ask this rather than reading the main window's caption, which lagged a switch (GxInspect).
/// </summary>
/// <param name="AReq">The request (no arguments).</param>
/// <returns><c>{ group, active, count, projects:[ { file, active } ] }</c>.</returns>
/// <exception cref="EAutoError"><c>NoProject</c> when nothing is open.</exception>
function CmdIdeProjects( AReq: TJSONObject ): TJSONValue;
begin

  var oGroup := RequireProjectGroup;
  var oActive := oGroup.ActiveProject;
  var oRes := TJSONObject.Create;
  try
    oRes.AddPair( 'group', oGroup.FileName );
    if Assigned( oActive ) then
      oRes.AddPair( 'active', oActive.FileName )
    else
      oRes.AddPair( 'active', TJSONNull.Create );
    var oProjects := TJSONArray.Create;
    oRes.AddPair( 'projects', oProjects );
    for var iProject := 0 to oGroup.ProjectCount - 1 do
    begin
      var oProject := oGroup.Projects[ iProject ];
      if oProject = nil then Continue;
      var oItem := TJSONObject.Create;
      oProjects.AddElement( oItem );
      oItem.AddPair( 'file', oProject.FileName );
      oItem.AddPair( 'active', TJSONBool.Create( Assigned( oActive ) and SameFileName( oActive.FileName, oProject.FileName ) ) );
    end;
    oRes.AddPair( 'count', TJSONNumber.Create( oProjects.Count ) );
  except
    oRes.Free;
    raise;
  end;
  Result := oRes;

end;

/// <summary>
///   <c>ide_set_project</c>: makes one project of the group the active one. Matched by path, by file name, then by name
///   without extension.
/// </summary>
/// <param name="AReq">The request: <c>project</c>.</param>
/// <returns><c>{ active, previous, note? }</c>.</returns>
/// <exception cref="EAutoError"><c>NoProject</c> when no project of the group matches; the group's projects are in <c>error.data</c>.</exception>
/// <remarks>
///   Switching while the debugger has a process stopped cuts the debugger commands off from it - the current process
///   follows the active project - until the project that was run is active again; the answer says so (GxInspect).
/// </remarks>
function CmdIdeSetProject( AReq: TJSONObject ): TJSONValue;
begin

  var sWanted := NeedString( AReq, 'project', 'ide_set_project' );
  var oGroup := RequireProjectGroup;

  var aProjects: TArray<IOTAProject> := [];
  var aNames: TArray<TArray<string>> := [];
  for var iProject := 0 to oGroup.ProjectCount - 1 do
  begin
    aProjects := aProjects + [ oGroup.Projects[ iProject ] ];
    if Assigned( oGroup.Projects[ iProject ] ) then
      aNames := aNames + [ TArray<string>.Create( oGroup.Projects[ iProject ].FileName ) ]
    else
      aNames := aNames + [ TArray<string>.Create() ];
  end;
  var iFound := FindFileMatch( aNames, Trim( sWanted ), True );
  var oFound: IOTAProject := nil;
  if iFound >= 0 then
    oFound := aProjects[ iFound ];

  if oFound = nil then
  begin
    var oData := TJSONArray.Create;
    for var iProject := 0 to oGroup.ProjectCount - 1 do
      if Assigned( oGroup.Projects[ iProject ] ) then
        oData.Add( oGroup.Projects[ iProject ].FileName );
    raise EAutoError.CreateCodeData( 'NoProject', Format( 'The project group has no project %s', [ sWanted ] ), oData );
  end;

  var sPrevious := '';
  if Assigned( oGroup.ActiveProject ) then
    sPrevious := oGroup.ActiveProject.FileName;
  oGroup.ActiveProject := oFound;

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'active', oFound.FileName );
  oRes.AddPair( 'previous', sPrevious );
  var oDebugger: IOTADebuggerServices;
  if Supports( BorlandIDEServices, IOTADebuggerServices, oDebugger ) and ( oDebugger.ProcessCount > 0 ) and
    not SameFileName( sPrevious, oFound.FileName ) then
    oRes.AddPair( 'note', 'The debugger''s current process follows the active project: until the project that was run is ' +
      'active again, the debug_* commands answer NoProcess' );
  Result := oRes;

end;

{ ── ide_actions / ide_action ───────────────────────────────────────────── }

/// <summary>The IDE's action list, which is what its menus and tool bars are built on.</summary>
/// <returns>The list.</returns>
/// <exception cref="EAutoError"><c>NoService</c> when the IDE offers none.</exception>
function IdeActionList: TCustomActionList;
begin

  var oServices: INTAServices;
  if not Supports( BorlandIDEServices, INTAServices, oServices ) or ( oServices.ActionList = nil ) then
    raise EAutoError.CreateCode( 'NoService', 'The IDE offers no action list' );
  Result := oServices.ActionList;

end;

/// <summary>Describes an action: what to name it by, then what it looks like.</summary>
/// <param name="AAction">The action.</param>
/// <returns><c>{ name, caption, category, enabled, visible, checked, shortcut }</c>; all but <c>name</c> only for a <c>TCustomAction</c>.</returns>
function ActionToJSON( AAction: TBasicAction ): TJSONObject;
begin

  Result := TJSONObject.Create;
  Result.AddPair( 'name', AAction.Name );
  if AAction is TCustomAction then
  begin
    var oAction := TCustomAction( AAction );
    Result.AddPair( 'caption', oAction.Caption );
    Result.AddPair( 'category', oAction.Category );
    Result.AddPair( 'enabled', TJSONBool.Create( oAction.Enabled ) );
    Result.AddPair( 'visible', TJSONBool.Create( oAction.Visible ) );
    Result.AddPair( 'checked', TJSONBool.Create( oAction.Checked ) );
    Result.AddPair( 'shortcut', ShortCutToText( oAction.ShortCut ) );
  end;

end;

/// <summary>
///   <c>ide_actions</c>: the IDE's actions, filtered by name, caption or category. <c>enabled</c> is only as fresh as the
///   IDE's last idle pass - asked straight after a project was opened every Run action still said disabled (GxInspect) -
///   which is why <c>ide_action</c> brings an action up to date before it decides.
/// </summary>
/// <param name="AReq">The request: <c>filter?</c>, <c>max?</c> (default 500, at most 5000).</param>
/// <returns><c>{ matched, listed, actions:[ ... ] }</c>; <c>listed</c> is less than <c>matched</c> when <c>max</c> cut it short.</returns>
/// <exception cref="EAutoError"><c>NoService</c> when the IDE offers no action list.</exception>
function CmdIdeActions( AReq: TJSONObject ): TJSONValue;
begin

  var sFilter := OptString( AReq, 'filter', '' );
  var iMax := ClampInt( OptInteger( AReq, 'max', 500 ), 1, 5000 );
  var oList := IdeActionList;

  var oRes := TJSONObject.Create;
  try
    var oActions := TJSONArray.Create;
    oRes.AddPair( 'actions', oActions );
    var iMatched := 0;
    for var iAction := 0 to oList.ActionCount - 1 do
    begin
      var oAction := oList.Actions[ iAction ];
      if oAction = nil then Continue;
      var sCaption := '';
      var sCategory := '';
      if oAction is TCustomAction then
      begin
        sCaption := TCustomAction( oAction ).Caption;
        sCategory := TCustomAction( oAction ).Category;
      end;
      if not ActionMatchesFilter( oAction.Name, sCaption, sCategory, sFilter ) then Continue;
      Inc( iMatched );
      if oActions.Count < iMax then
        oActions.AddElement( ActionToJSON( oAction ) );
    end;
    oRes.AddPair( 'matched', TJSONNumber.Create( iMatched ) );
    oRes.AddPair( 'listed', TJSONNumber.Create( oActions.Count ) );
  except
    oRes.Free;
    raise;
  end;
  Result := oRes;

end;

/// <summary>
///   An IDE action by its component name: in the IDE's action list first, then among the components of its data modules
///   and forms - the commands the IDE keeps in its own data modules (<c>DebugCommands</c>, with <c>ecToggleBreakpoint</c>)
///   are not in <c>INTAServices</c>' list (GxInspect).
/// </summary>
/// <param name="AName">The name.</param>
/// <returns>The action, or nil.</returns>
function FindIdeAction( const AName: string ): TBasicAction;
begin

  var oList := IdeActionList;
  for var iAction := 0 to oList.ActionCount - 1 do
    if Assigned( oList.Actions[ iAction ] ) and SameText( oList.Actions[ iAction ].Name, AName ) then
      Exit( oList.Actions[ iAction ] );

  for var iModule := 0 to Screen.DataModuleCount - 1 do
  begin
    var oFound := Screen.DataModules[ iModule ].FindComponent( AName );
    if oFound is TBasicAction then
      Exit( TBasicAction( oFound ) );
  end;
  for var iForm := 0 to Screen.FormCount - 1 do
  begin
    var oFound := Screen.Forms[ iForm ].FindComponent( AName );
    if oFound is TBasicAction then
      Exit( TBasicAction( oFound ) );
  end;
  Result := nil;

end;

/// <summary>
///   <c>ide_action</c>: executes one IDE action by name - the way to reach a menu command that has no command of its own
///   here, Run (<c>RunRunCommand</c>) for one. It is brought up to date first and refused when disabled, since a disabled
///   action is one whose preconditions are not met. It runs just after the answer, as <c>ide_menu_click</c> does, so an
///   action that opens a dialog does not hold the answer up; ask <c>dialogs</c> next, and allow for time.
/// </summary>
/// <param name="AReq">The request: <c>name</c>.</param>
/// <returns><c>{ executeScheduled:true, action }</c>, the action as <c>ide_actions</c> describes it.</returns>
/// <exception cref="EAutoError"><c>NoAction</c> when there is no action of that name; <c>ActionDisabled</c> when it is disabled.</exception>
function CmdIdeAction( AReq: TJSONObject ): TJSONValue;
begin

  var sName := NeedString( AReq, 'name', 'ide_action' );
  var oAction := FindIdeAction( sName );
  if oAction = nil then
    raise EAutoError.CreateCode( 'NoAction', Format( 'The IDE has no action %s; ide_actions lists them', [ sName ] ) );

  oAction.Update;
  if ( oAction is TCustomAction ) and not TCustomAction( oAction ).Enabled then
    raise EAutoError.CreateCode( 'ActionDisabled', oAction.Name + ' is disabled just now' );

  DeferToMainThread(
    procedure
    begin
      //  Found again rather than captured: in the gap the IDE may have freed it (a project closed, a plug-in unloaded).
      try
        var oAgain := FindIdeAction( sName );
        if Assigned( oAgain ) then
        begin
          oAgain.Update;
          if not ( oAgain is TCustomAction ) or TCustomAction( oAgain ).Enabled then
            oAgain.Execute;
        end;
      except
        on EAutoError do ;   // the action list went away in the gap: there is nobody left to tell
      end;
    end );

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'executeScheduled', TJSONBool.Create( True ) );
  oRes.AddPair( 'action', ActionToJSON( oAction ) );
  Result := oRes;

end;

{ ── Form designer ──────────────────────────────────────────────────────── }

/// <summary>The form editor of a module, if it has one.</summary>
/// <param name="AModule">The module.</param>
/// <returns>The form editor, or nil.</returns>
function FormEditorOf( const AModule: IOTAModule ): IOTAFormEditor;
begin

  Result := nil;
  if AModule = nil then Exit;
  for var iFile := 0 to AModule.ModuleFileCount - 1 do
    if Supports( AModule.ModuleFileEditors[ iFile ], IOTAFormEditor, Result ) then
      Exit;
  Result := nil;

end;

/// <summary>Refuses a module that has no form editor, saying whether its form is open as text instead.</summary>
/// <param name="AModule">The module.</param>
/// <exception cref="EAutoError"><c>NoForm</c>, always.</exception>
procedure RaiseNoForm( const AModule: IOTAModule );
begin

  if IsFormFileName( AModule.FileName ) then
    raise EAutoError.CreateCode( 'NoForm', AModule.FileName + ' is shown as text; ide_view_as_form it first' );
  raise EAutoError.CreateCode( 'NoForm', AModule.FileName + ' has no form' );

end;

/// <summary>
///   The form editor a file argument names: the unit's name or the <c>.dfm</c>'s, either with a path, or <c>.</c> for the
///   module in front. The exact name is tried first and the name without extension only when nothing answered to it, so
///   a folder holding <c>Foo.pas</c> and an unrelated <c>Foo.dfm</c> cannot be matched by accident (GxInspect).
/// </summary>
/// <param name="AFileId">The argument.</param>
/// <param name="AModule">Receives the module.</param>
/// <returns>The form editor.</returns>
/// <exception cref="EAutoError"><c>NoModule</c> when nothing open matches; <c>NoForm</c> when it has no form, or the form is shown as text.</exception>
function FindFormEditor( const AFileId: string; out AModule: IOTAModule ): IOTAFormEditor;
begin

  if IsCurrentFileId( AFileId ) then
  begin
    AModule := FindModule( AFileId );
    Result := FormEditorOf( AModule );
    if Result = nil then
      RaiseNoForm( AModule );
    Exit;
  end;

  //  Only modules with a form are candidates; the others stay in the list with no names, so indexes line up.
  var oServices := ModuleServices;
  var aModules: TArray<IOTAModule> := [];
  var aNames: TArray<TArray<string>> := [];
  for var iModule := 0 to oServices.ModuleCount - 1 do
  begin
    var oModule := oServices.Modules[ iModule ];
    var oForm := FormEditorOf( oModule );
    aModules := aModules + [ oModule ];
    if Assigned( oForm ) then
      aNames := aNames + [ TArray<string>.Create( oForm.FileName, oModule.FileName ) ]
    else
      aNames := aNames + [ TArray<string>.Create() ];
  end;
  var iFound := FindFileMatch( aNames, Trim( AFileId ), True );
  if iFound >= 0 then
  begin
    AModule := aModules[ iFound ];
    Exit( FormEditorOf( AModule ) );
  end;

  AModule := FindModule( AFileId );
  RaiseNoForm( AModule );
  Result := nil;

end;

/// <summary>
///   The form a form editor designs. The designer's root is the form itself for an ordinary form, and for a data module a
///   component the hosting form owns.
/// </summary>
/// <param name="AFormEditor">The form editor.</param>
/// <returns>The form.</returns>
/// <exception cref="EAutoError"><c>NoDesigner</c> when the form is not loaded in the designer.</exception>
function DesignFormOf( const AFormEditor: IOTAFormEditor ): TCustomForm;
begin

  var oNative: INTAFormEditor;
  if not Supports( AFormEditor, INTAFormEditor, oNative ) or ( oNative.FormDesigner = nil ) then
    raise EAutoError.CreateCode( 'NoDesigner', AFormEditor.FileName + ' is not loaded in the designer; ide_designer_show it' );

  var oRoot := oNative.FormDesigner.Root;
  if oRoot is TCustomForm then
    Exit( TCustomForm( oRoot ) );
  if Assigned( oRoot ) and ( oRoot.Owner is TCustomForm ) then
    Exit( TCustomForm( oRoot.Owner ) );
  raise EAutoError.CreateCode( 'NoDesigner', AFormEditor.FileName + ' has no designed form' );

end;

/// <summary>
///   The component behind what the designer hands out: the handle is the object itself for the VCL designer. The
///   interface is backed by a <c>TComponent</c> and not reference counted, so it is used here and never kept.
/// </summary>
/// <param name="AComponent">The designer's component.</param>
/// <returns>The component, or nil when it is not one.</returns>
function NativeComponentOf( const AComponent: IOTAComponent ): TComponent;
begin

  Result := nil;
  if AComponent = nil then Exit;
  var pHandle := AComponent.GetComponentHandle;
  if ( pHandle <> nil ) and ( TObject( pHandle ) is TComponent ) then
    Result := TComponent( pHandle );

end;

/// <summary>What the designer has selected. Nothing selected and the form selected are one state to it: the count is then 0.</summary>
/// <param name="AFormEditor">The form editor.</param>
/// <param name="AModule">Its module, for the answer.</param>
/// <returns><c>{ file, form, count, selected:[ { name, class } ] }</c>.</returns>
function SelectionToJSON( const AFormEditor: IOTAFormEditor; const AModule: IOTAModule ): TJSONObject;
begin

  Result := TJSONObject.Create;
  try
    Result.AddPair( 'file', AModule.FileName );
    Result.AddPair( 'form', AFormEditor.FileName );
    var oSelected := TJSONArray.Create;
    Result.AddPair( 'selected', oSelected );
    for var iSel := 0 to AFormEditor.GetSelCount - 1 do
    begin
      var oComp := NativeComponentOf( AFormEditor.GetSelComponent( iSel ) );
      var oItem := TJSONObject.Create;
      oSelected.AddElement( oItem );
      if Assigned( oComp ) then
      begin
        oItem.AddPair( 'name', oComp.Name );
        oItem.AddPair( 'class', oComp.ClassName );
      end
      else
        oItem.AddPair( 'name', TJSONNull.Create );
    end;
    Result.AddPair( 'count', TJSONNumber.Create( oSelected.Count ) );
  except
    FreeAndNil( Result );
    raise;
  end;

end;

/// <summary>
///   <c>ide_designer_show</c>: brings a form up in the designer. A file that is not open is opened first, when it exists.
/// </summary>
/// <param name="AReq">The request: <c>file?</c> - the unit or its <c>.dfm</c>, a path or a name, or <c>.</c> (the default) for the module in front.</param>
/// <returns><c>{ file, form, root, class }</c>: the module, its form file, and the designed root component.</returns>
/// <exception cref="EAutoError">
///   <c>NoModule</c> when it is not open and cannot be opened; <c>NoForm</c> when it has no form, or the form is shown as
///   text; <c>OpenFailed</c> as for <c>ide_open_file</c>.
/// </exception>
function CmdIdeDesignerShow( AReq: TJSONObject ): TJSONValue;
begin

  var sFile := OptString( AReq, 'file', '.' );
  var oModule: IOTAModule;
  var oEditor: IOTAFormEditor;
  try
    oEditor := FindFormEditor( sFile, oModule );
  except
    on E: EAutoError do
    begin
      if ( E.Code <> 'NoModule' ) or IsCurrentFileId( sFile ) or not FileExists( sFile ) then
        raise;
      if not OpenFileKeepingForeground( ExpandFileName( sFile ) ) then
        raise EAutoError.CreateCode( 'OpenFailed', 'The IDE did not open ' + sFile );
      oEditor := FindFormEditor( sFile, oModule );
    end;
  end;

  oEditor.Show;

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'file', oModule.FileName );
  oRes.AddPair( 'form', oEditor.FileName );
  var oRoot := NativeComponentOf( oEditor.GetRootComponent );
  if Assigned( oRoot ) then
  begin
    oRes.AddPair( 'root', oRoot.Name );
    oRes.AddPair( 'class', oRoot.ClassName );
  end;
  Result := oRes;

end;

/// <summary>
///   <c>ide_designer_screenshot</c>: renders the form in the designer to a PNG on the Desktop, as <c>screenshot</c> renders a
///   control - legible, and right even when the designer is covered. Runs on the worker thread (the render must, see the
///   server's <c>RenderControl</c>); the form is found on the main thread.
/// </summary>
/// <param name="AReq">The request: <c>file?</c> (as for <c>ide_designer_show</c>), <c>maxWidth?</c>.</param>
/// <returns><c>{ path, width, height, area, target, renderer, file, sourceWidth?, sourceHeight? }</c>.</returns>
/// <exception cref="EAutoError">
///   <c>NoModule</c> / <c>NoForm</c> / <c>NoDesigner</c> as for the other designer commands; <c>NotShowing</c> when the
///   designer is not on screen - <c>ide_designer_show</c> it first.
/// </exception>
function CmdIdeDesignerScreenshot( AReq: TJSONObject ): TJSONValue;
begin

  var sFile := OptString( AReq, 'file', '.' );
  var iMaxWidth := OptInteger( AReq, 'maxWidth', 0 );
  var sModule := '';
  var oRes := TAutomationServer.RenderControl(
    function: TControl
    begin
      var oModule: IOTAModule;
      var oForm := DesignFormOf( FindFormEditor( sFile, oModule ) );
      sModule := oModule.FileName;
      if not oForm.Showing then
        raise EAutoError.CreateCode( 'NotShowing', oModule.FileName + ' is not on screen in the designer; ide_designer_show it first' );
      Result := oForm;
    end, iMaxWidth, 'DelphiIDE-designer' );
  oRes.AddPair( 'file', sModule );
  Result := oRes;

end;

/// <summary><c>ide_designer_selection</c>: what the form designer has selected.</summary>
/// <param name="AReq">The request: <c>file?</c> (as for <c>ide_designer_show</c>).</param>
/// <returns>As <see cref="SelectionToJSON"/>.</returns>
/// <exception cref="EAutoError"><c>NoModule</c> / <c>NoForm</c>.</exception>
function CmdIdeDesignerSelection( AReq: TJSONObject ): TJSONValue;
begin

  var oModule: IOTAModule;
  var oEditor := FindFormEditor( OptString( AReq, 'file', '.' ), oModule );
  Result := SelectionToJSON( oEditor, oModule );

end;

/// <summary>
///   <c>ide_designer_select</c>: selects components in the form designer, replacing the selection. Every name is found
///   BEFORE anything is selected, so one wrong name cannot leave half a selection behind. Non-visual components are
///   selected as readily as controls.
/// </summary>
/// <param name="AReq">The request: <c>file?</c>, <c>names</c> - an array of component names, or one string separated by commas.</param>
/// <returns>The new selection, as <see cref="SelectionToJSON"/>.</returns>
/// <exception cref="EAutoError">
///   <c>BadRequest</c> for a missing, empty or repeated name; <c>NoComp</c> when a name is not on the form, every missing one
///   in <c>error.data</c>; <c>NoModule</c> / <c>NoForm</c>.
/// </exception>
function CmdIdeDesignerSelect( AReq: TJSONObject ): TJSONValue;
begin

  var aNames := NameListArgument( AReq, 'names', 'ide_designer_select' );
  var oModule: IOTAModule;
  var oEditor := FindFormEditor( OptString( AReq, 'file', '.' ), oModule );

  var aFound: TArray<IOTAComponent>;
  SetLength( aFound, Length( aNames ) );
  var oMissing := TJSONArray.Create;
  try
    for var iName := 0 to High( aNames ) do
    begin
      aFound[ iName ] := oEditor.FindComponent( aNames[ iName ] );
      if aFound[ iName ] = nil then
        oMissing.Add( aNames[ iName ] );
    end;
    if oMissing.Count > 0 then
    begin
      var oData := oMissing;
      oMissing := nil;
      raise EAutoError.CreateCodeData( 'NoComp', Format( '%d of the names are not on %s; nothing was selected',
        [ oData.Count, oEditor.FileName ] ), oData );
    end;
  finally
    oMissing.Free;
  end;

  //  The first replaces whatever was selected, the rest are added to it.
  for var iName := 0 to High( aFound ) do
    aFound[ iName ].Select( iName > 0 );
  aFound := nil;
  oEditor.Show;

  Result := SelectionToJSON( oEditor, oModule );

end;

/// <summary>
///   <c>ide_designer_deselect</c>: selects the form itself, which is what the designer means by nothing selected - there
///   is no state with neither the form nor a component selected (GxInspect).
/// </summary>
/// <param name="AReq">The request: <c>file?</c>.</param>
/// <returns>The selection afterwards, as <see cref="SelectionToJSON"/>; its <c>count</c> is 0.</returns>
/// <exception cref="EAutoError"><c>NoModule</c> / <c>NoForm</c>.</exception>
function CmdIdeDesignerDeselect( AReq: TJSONObject ): TJSONValue;
begin

  var oModule: IOTAModule;
  var oEditor := FindFormEditor( OptString( AReq, 'file', '.' ), oModule );
  var oRoot := oEditor.GetRootComponent;
  if oRoot = nil then
    raise EAutoError.CreateCode( 'NoForm', oEditor.FileName + ' has no root component' );
  oRoot.Select( False );
  oRoot := nil;
  Result := SelectionToJSON( oEditor, oModule );

end;

{ ── ide_view_as_text / ide_view_as_form ────────────────────────────────── }

type
  /// <summary>
  ///   How a form is open. View as Text and View as Form are not two views of one module: showing a form as text closes
  ///   the unit and opens the <c>.dfm</c> as a module of its own, and going back closes that and opens the unit again
  ///   (GxInspect).
  /// </summary>
  TFormView = record
    /// <summary>True when the form is shown as the text of its <c>.dfm</c>.</summary>
    IsText   : Boolean;
    /// <summary>The module that is open: the unit in the designer view, the <c>.dfm</c> in the text view.</summary>
    Module   : IOTAModule;
    /// <summary>The form file, the <c>.dfm</c>, in either view.</summary>
    FormFile : string;
    /// <summary>The unit, empty while the form is shown as text.</summary>
    UnitFile : string;
  end;

/// <summary>Whether an open module is one of the two sides of a form, and which.</summary>
/// <param name="AModule">The module.</param>
/// <param name="AView">Receives what it is; says nothing when this returns False.</param>
/// <returns>True when it is a form, in either view.</returns>
function DescribeFormView( const AModule: IOTAModule; out AView: TFormView ): Boolean;
begin

  var oForm := FormEditorOf( AModule );
  if Assigned( oForm ) then
  begin
    AView.IsText := False;
    AView.Module := AModule;
    AView.FormFile := oForm.FileName;
    AView.UnitFile := AModule.FileName;
    Exit( True );
  end;

  Result := False;
  if ( AModule = nil ) or not IsFormFileName( AModule.FileName ) then Exit;
  for var iFile := 0 to AModule.ModuleFileCount - 1 do
    if Supports( AModule.ModuleFileEditors[ iFile ], IOTASourceEditor ) then
    begin
      AView.IsText := True;
      AView.Module := AModule;
      AView.FormFile := AModule.FileName;
      AView.UnitFile := '';
      Exit( True );
    end;

end;

/// <summary>
///   The form a file argument names, in whichever view it is open: the unit's name or the <c>.dfm</c>'s, with or without a
///   path, or <c>.</c>. Both are matched without their extension too, because only one of them is open at a time and a
///   script should not have to say which; the exact name is tried first (GxInspect).
/// </summary>
/// <param name="AFileId">The argument.</param>
/// <returns>The form's view.</returns>
/// <exception cref="EAutoError"><c>NoModule</c> when nothing open matches; <c>NoForm</c> when what matches is not a form.</exception>
function FindFormView( const AFileId: string ): TFormView;
begin

  if IsCurrentFileId( AFileId ) then
  begin
    var oCurrent := FindModule( AFileId );
    if not DescribeFormView( oCurrent, Result ) then
      raise EAutoError.CreateCode( 'NoForm', oCurrent.FileName + ' is not a form' );
    Exit;
  end;

  var oServices := ModuleServices;
  var aViews: TArray<TFormView> := [];
  var aNames: TArray<TArray<string>> := [];
  for var iModule := 0 to oServices.ModuleCount - 1 do
  begin
    var rView: TFormView;
    if DescribeFormView( oServices.Modules[ iModule ], rView ) then
    begin
      aViews := aViews + [ rView ];
      aNames := aNames + [ TArray<string>.Create( rView.FormFile, rView.UnitFile ) ];
    end;
  end;
  var iFound := FindFileMatch( aNames, Trim( AFileId ), True );
  if iFound >= 0 then
    Exit( aViews[ iFound ] );

  raise EAutoError.CreateCode( 'NoForm', FindModule( AFileId ).FileName + ' has no form' );

end;

/// <summary>
///   Swaps a form between the designer and its text - the IDE's own Alt+F12. There is no call that sets either state, only
///   one that swaps, and it acts on what the IDE has in front, so the form is brought forward first (GxInspect).
/// </summary>
/// <param name="AView">The form's view.</param>
/// <exception cref="EAutoError"><c>NoEditor</c> when there is no editor or edit view to swap with.</exception>
procedure SwapFormView( const AView: TFormView );
begin

  var oToShow: IOTAEditor := nil;
  var oSource: IOTASourceEditor := nil;
  for var iFile := 0 to AView.Module.ModuleFileCount - 1 do
  begin
    var oEditor := AView.Module.ModuleFileEditors[ iFile ];
    if oEditor = nil then Continue;
    if SameFileName( oEditor.FileName, AView.FormFile ) then
      oToShow := oEditor;
    var oAny: IOTASourceEditor;
    if ( oSource = nil ) and Supports( oEditor, IOTASourceEditor, oAny ) then
      oSource := oAny;
  end;
  if oToShow = nil then
    raise EAutoError.CreateCode( 'NoEditor', 'The IDE has no editor for ' + AView.FormFile );
  oToShow.Show;

  var oView: IOTAEditView := nil;
  if Assigned( oSource ) and ( oSource.EditViewCount > 0 ) then
    oView := oSource.EditViews[ 0 ];
  var oEditors: IOTAEditorServices;
  if ( oView = nil ) and Supports( BorlandIDEServices, IOTAEditorServices, oEditors ) then
    oView := oEditors.TopView;
  var oActions: IOTAEditActions;
  if ( oView = nil ) or not Supports( oView, IOTAEditActions, oActions ) then
    raise EAutoError.CreateCode( 'NoEditor', 'The IDE has no edit view to swap ' + AView.FormFile + ' with' );
  oActions.SwapSourceFormView;

end;

/// <summary>The common part of <c>ide_view_as_text</c> and <c>ide_view_as_form</c>: get to the view wanted, or say why not.</summary>
/// <param name="AReq">The request: <c>file?</c>.</param>
/// <param name="AWantText">True for the text view.</param>
/// <returns><c>{ file, view, switched, note? }</c>.</returns>
/// <exception cref="EAutoError">As <see cref="FindFormView"/> and <see cref="SwapFormView"/>.</exception>
/// <remarks>
///   The answer says the view was switched without looking: the IDE finishes the switch after this handler returns, and
///   it is done by the time the next command runs. Unsaved changes are carried across, so they are not asked about.
/// </remarks>
function SetFormView( AReq: TJSONObject; AWantText: Boolean ): TJSONValue;
begin

  var rView := FindFormView( OptString( AReq, 'file', '.' ) );
  var bSwitch := rView.IsText <> AWantText;
  if bSwitch then
    SwapFormView( rView );

  var oRes := TJSONObject.Create;
  oRes.AddPair( 'file', rView.FormFile );
  oRes.AddPair( 'view', if AWantText then 'text' else 'form' );
  oRes.AddPair( 'switched', TJSONBool.Create( bSwitch ) );
  if bSwitch and AWantText then
    oRes.AddPair( 'note', 'The unit is closed while its form is shown as text: name the .dfm, not the unit, until it is ' +
      'shown as a form again' )
  else if bSwitch then
    oRes.AddPair( 'note', 'Text the IDE cannot read puts up a modal "Error creating form" box and closes the module, losing ' +
      'the text; ask dialogs' );
  Result := oRes;

end;

/// <summary><c>ide_view_as_text</c>: shows a form as the text of its <c>.dfm</c>.</summary>
/// <param name="AReq">The request: <c>file?</c> - the unit or the <c>.dfm</c>, or <c>.</c>.</param>
/// <returns>As <see cref="SetFormView"/>.</returns>
function CmdIdeViewAsText( AReq: TJSONObject ): TJSONValue;
begin

  Result := SetFormView( AReq, True );

end;

/// <summary><c>ide_view_as_form</c>: shows a form in the designer again.</summary>
/// <param name="AReq">The request: <c>file?</c> - the unit or the <c>.dfm</c>, or <c>.</c>.</param>
/// <returns>As <see cref="SetFormView"/>.</returns>
function CmdIdeViewAsForm( AReq: TJSONObject ): TJSONValue;
begin

  Result := SetFormView( AReq, False );

end;

{ ── debug_disasm ───────────────────────────────────────────────────────── }

type
  /// <summary>An address of the CPU window's events: Int64 since XE2, in either IDE bitness.</summary>
  TCpuAddress = Int64;

  /// <summary>
  ///   The IDE's <c>TCPUSourcePos</c>: file index, line number and one more Integer, 12 bytes in Delphi 13's type
  ///   information. A record of that size is passed by reference whether <c>var</c>, <c>const</c> or by value, so only the
  ///   memory behind it has to be large enough; the padding makes sure it is should the IDE's grow (GxInspect).
  /// </summary>
  TCpuSourcePos = record
    /// <summary>Which of the IDE's source files.</summary>
    FileIndex : Integer;
    /// <summary>The line in it.</summary>
    LineNum   : Integer;
    /// <summary>Not used here.</summary>
    Param     : Integer;
    /// <summary>Room for a larger record.</summary>
    Reserved  : array[ 0..12 ] of Integer;
  end;

  /// <summary><c>TDisassemblerView.OnDisassemble</c>: disassembles one instruction; the text starts with its address.</summary>
  TCpuDisassembleEvent = procedure( Sender: TObject; var Address: TCpuAddress; var Text: string; var InstSize: Integer ) of object;
  /// <summary><c>TDisassemblerView.OnGetLabel</c>: the label at an address, if it has one.</summary>
  TCpuGetLabelEvent = procedure( Sender: TObject; Address: TCpuAddress; var LabelText: string; var IsLabel: Boolean ) of object;
  /// <summary><c>TDisassemblerView.OnFindSourceLine</c>: the source line an address belongs to, and where that line's code starts.</summary>
  TCpuFindSourceLineEvent = procedure( Sender: TObject; Address: TCpuAddress; var FirstStat: TCpuAddress; var LineSize: Integer;
    var SourcePos: TCpuSourcePos ) of object;
  /// <summary><c>TDisassemblerView.OnGetSourceText</c>: the text of a source line.</summary>
  TCpuGetSourceTextEvent = procedure( Sender: TObject; const SourcePos: TCpuSourcePos; var Text: string ) of object;
  /// <summary><c>TDisassemblerView.OnGetFileName</c>: the file of a source line.</summary>
  TCpuGetFileNameEvent = procedure( Sender: TObject; SourcePos: TCpuSourcePos; var FileName: string ) of object;

  /// <summary>
  ///   Disassembles the debugged process by calling the handlers the IDE has wired to the events of a
  ///   <c>TDisassemblerView</c>, the hand-drawn control of the CPU window's code pane, which holds no text; the ToolsAPI has
  ///   nothing for disassembly. They work for any address, whatever the view shows and whether it is visible. Each
  ///   handler's declaration is read from its event's type information and compared before it is called. Ported from
  ///   GxInspect's <c>TGxCpuDisassembler</c>.
  /// </summary>
  TCpuDisassembler = class
  private
    /// <summary>The CPU window's code pane.</summary>
    FView           : TControl;
    /// <summary>Its <c>OnDisassemble</c> handler.</summary>
    FDisassemble    : TCpuDisassembleEvent;
    /// <summary>Its <c>OnGetLabel</c> handler, when <see cref="FHasLabels"/>.</summary>
    FGetLabel       : TCpuGetLabelEvent;
    /// <summary>Its <c>OnFindSourceLine</c> handler, when <see cref="FHasSource"/>.</summary>
    FFindSourceLine : TCpuFindSourceLineEvent;
    /// <summary>Its <c>OnGetSourceText</c> handler, when <see cref="FHasSource"/>.</summary>
    FGetSourceText  : TCpuGetSourceTextEvent;
    /// <summary>Its <c>OnGetFileName</c> handler, when <see cref="FHasSource"/>.</summary>
    FGetFileName    : TCpuGetFileNameEvent;
    /// <summary>True when labels can be asked for.</summary>
    FHasLabels      : Boolean;
    /// <summary>True when source lines can be asked for.</summary>
    FHasSource      : Boolean;
    /// <summary>What is left out because the view has no handler for it.</summary>
    FNotes          : TArray<string>;
  public
    /// <summary>Finds a CPU window's code pane and reads its handlers.</summary>
    /// <exception cref="EAutoError">
    ///   <c>NoCpuWindow</c> when there is none - it must have been opened once (<c>ide_action DebugCPUCommand</c>);
    ///   <c>SignatureMismatch</c> when its <c>OnDisassemble</c> is not the shape it is called with.
    /// </exception>
    procedure Init;
    /// <summary>Disassembles one instruction, with its label and the source line it starts, if any.</summary>
    /// <param name="AAddress">Where the instruction starts.</param>
    /// <param name="AFirst">True for the first one listed, which gets its source line even when the line starts earlier.</param>
    /// <param name="AInstSize">Receives its size; 0 for memory that cannot be disassembled.</param>
    /// <returns><c>{ text, label?, source?:{ file, line, text } }</c>; the caller adds the rest.</returns>
    function Row( AAddress: Int64; AFirst: Boolean; out AInstSize: Integer ): TJSONObject;
    /// <summary>What is left out because the view has no handler for it.</summary>
    property Notes: TArray<string> read FNotes;
  end;

/// <summary>Whether an object's class, or one it descends from, has the given name - for an IDE class this unit cannot name.</summary>
/// <param name="AObject">The object.</param>
/// <param name="AClassName">The class name.</param>
/// <returns>True when it inherits from a class of that name.</returns>
function InheritsFromClassName( AObject: TObject; const AClassName: string ): Boolean;
begin

  var oClass := AObject.ClassType;
  while Assigned( oClass ) do
  begin
    if SameText( oClass.ClassName, AClassName ) then
      Exit( True );
    oClass := oClass.ClassParent;
  end;
  Result := False;

end;

/// <summary>Reads the handler of one of the view's events, after checking that the event has the declaration it will be called with.</summary>
/// <param name="AView">The view.</param>
/// <param name="AEvent">The event, e.g. <c>OnDisassemble</c>.</param>
/// <param name="AShape">The declaration expected, as <see cref="EventShape"/> gives it.</param>
/// <param name="AMethod">Receives the handler.</param>
/// <param name="AWhy">Receives why it cannot be called.</param>
/// <returns>True when there is a handler of that declaration.</returns>
function TryGetCpuHandler( AView: TObject; const AEvent, AShape: string; out AMethod: TMethod; out AWhy: string ): Boolean;
begin

  Result := False;
  AMethod.Code := nil;
  AMethod.Data := nil;
  var pProp := GetPropInfo( AView, AEvent );
  if ( pProp = nil ) or ( pProp.PropType^.Kind <> tkMethod ) then
  begin
    AWhy := AView.ClassName + ' has no ' + AEvent;
    Exit;
  end;
  var sShape := EventShape( pProp.PropType^ );
  if not SameText( sShape, AShape ) then
  begin
    AWhy := Format( '%s.%s takes ( %s ), not ( %s ) as expected, so it is not called', [ AView.ClassName, AEvent, sShape, AShape ] );
    Exit;
  end;
  AMethod := GetMethodProp( AView, pProp );
  if not Assigned( AMethod.Code ) then
  begin
    AWhy := AView.ClassName + '.' + AEvent + ' has no handler';
    Exit;
  end;
  Result := True;

end;

/// <summary>
///   Whether the IDE's <c>TCPUSourcePos</c>, as an event of the view declares it, can be passed as our padded record.
///   Our record goes by reference only because it is larger than 8 bytes, and the IDE's must be too: a record of 8 bytes
///   or fewer travels in a register in Win64, so a by-value parameter of one would be read as a pointer.  And ours must
///   be at least as large, so the handler never reads past it.  The name alone cannot tell; its size, from RTTI, can.
/// </summary>
/// <param name="AView">The view.</param>
/// <param name="AEvent">The event whose parameters include a <c>TCPUSourcePos</c>.</param>
/// <param name="AWhy">Receives why it does not fit.</param>
/// <returns>True when the IDE's record is over 8 bytes and no larger than <c>TCpuSourcePos</c>.</returns>
function CpuSourcePosFits( AView: TObject; const AEvent: string; out AWhy: string ): Boolean;
begin

  Result := False;
  AWhy := Format( '%s.%s has no type information for TCPUSourcePos', [ AView.ClassName, AEvent ] );
  var pProp := GetPropInfo( AView, AEvent );
  if pProp = nil then Exit;
  var oContext := TRttiContext.Create;
  try
    var oType := oContext.GetType( pProp.PropType^ );
    if oType is not TRttiMethodType then Exit;
    for var oParam in TRttiMethodType( oType ).GetParameters do
      if Assigned( oParam.ParamType ) and SameText( oParam.ParamType.Name, 'TCPUSourcePos' ) then
      begin
        var iSize := oParam.ParamType.TypeSize;
        Result := ( iSize > 8 ) and ( iSize <= SizeOf( TCpuSourcePos ) );
        if not Result then
          AWhy := Format( 'the IDE''s TCPUSourcePos is %d bytes, which this unit cannot pass safely (it needs 9 to %d)',
            [ iSize, SizeOf( TCpuSourcePos ) ] );
        Exit;
      end;
  finally
    oContext.Free;
  end;

end;

/// <summary>Finds a <c>TDisassemblerView</c> with an <c>OnDisassemble</c> handler, hidden or not, among a control and its children.</summary>
/// <param name="ACtl">Where to start.</param>
/// <returns>The view, or nil.</returns>
function FindCpuView( ACtl: TControl ): TControl;
begin

  if InheritsFromClassName( ACtl, 'TDisassemblerView' ) then
  begin
    var pProp := GetPropInfo( ACtl, 'OnDisassemble' );
    if Assigned( pProp ) and ( pProp.PropType^.Kind = tkMethod ) and Assigned( GetMethodProp( ACtl, pProp ).Code ) then
      Exit( ACtl );
  end;

  if ACtl is TWinControl then
    for var iChild := 0 to TWinControl( ACtl ).ControlCount - 1 do
    begin
      Result := FindCpuView( TWinControl( ACtl ).Controls[ iChild ] );
      if Assigned( Result ) then Exit;
    end;
  Result := nil;

end;

procedure TCpuDisassembler.Init;
const
  SHAPE_DISASSEMBLE = 'TObject; var Int64; var string; var Integer';
begin

  FView := nil;
  for var iForm := 0 to Screen.FormCount - 1 do
  begin
    FView := FindCpuView( Screen.Forms[ iForm ] );
    if Assigned( FView ) then Break;
  end;
  if FView = nil then
    raise EAutoError.CreateCode( 'NoCpuWindow', 'There is no CPU window to disassemble with; open it once, with ide_action ' +
      'DebugCPUCommand (the IDE opens it by itself when the process stops where there is no source)' );

  var rMethod: TMethod;
  var sWhy := '';
  if not TryGetCpuHandler( FView, 'OnDisassemble', SHAPE_DISASSEMBLE, rMethod, sWhy ) then
    raise EAutoError.CreateCode( 'SignatureMismatch', sWhy );
  FDisassemble := TCpuDisassembleEvent( rMethod );

  FNotes := [];
  FHasLabels := TryGetCpuHandler( FView, 'OnGetLabel', 'TObject; Int64; var string; var Boolean', rMethod, sWhy );
  if FHasLabels then
    FGetLabel := TCpuGetLabelEvent( rMethod )
  else
    FNotes := FNotes + [ 'without labels: ' + sWhy ];

  FHasSource := TryGetCpuHandler( FView, 'OnFindSourceLine', 'TObject; Int64; var Int64; var Integer; var TCPUSourcePos',
    rMethod, sWhy );
  if FHasSource then
  begin
    FFindSourceLine := TCpuFindSourceLineEvent( rMethod );
    FHasSource := TryGetCpuHandler( FView, 'OnGetSourceText', 'TObject; const TCPUSourcePos; var string', rMethod, sWhy );
    if FHasSource then
    begin
      FGetSourceText := TCpuGetSourceTextEvent( rMethod );
      FHasSource := TryGetCpuHandler( FView, 'OnGetFileName', 'TObject; TCPUSourcePos; var string', rMethod, sWhy );
      if FHasSource then
        FGetFileName := TCpuGetFileNameEvent( rMethod );
    end;
  end;
  //  Each event that takes the record, its declared size checked: the name matching is not enough.
  for var sEvent in [ 'OnFindSourceLine', 'OnGetSourceText', 'OnGetFileName' ] do
    if FHasSource and not CpuSourcePosFits( FView, sEvent, sWhy ) then
      FHasSource := False;
  if not FHasSource then
    FNotes := FNotes + [ 'without source lines: ' + sWhy ];

end;

function TCpuDisassembler.Row( AAddress: Int64; AFirst: Boolean; out AInstSize: Integer ): TJSONObject;
begin

  Result := TJSONObject.Create;
  try
    if FHasLabels then
    begin
      var sLabel := '';
      var bIsLabel := False;
      FGetLabel( FView, AAddress, sLabel, bIsLabel );
      if bIsLabel and ( sLabel <> '' ) then
        Result.AddPair( 'label', sLabel );
    end;

    if FHasSource then
    begin
      var rPos: TCpuSourcePos;
      FillChar( rPos, SizeOf( rPos ), 0 );
      var iFirstStat: TCpuAddress := 0;
      var iLineSize := 0;
      FFindSourceLine( FView, AAddress, iFirstStat, iLineSize, rPos );
      //  A line is given with its first instruction, and with the first one listed, so that a listing starting in the
      //  middle of a line still says which one it is.
      if ( iLineSize > 0 ) and ( ( iFirstStat = AAddress ) or AFirst ) then
      begin
        var sFile := '';
        var sText := '';
        FGetFileName( FView, rPos, sFile );
        FGetSourceText( FView, rPos, sText );
        var oSource := TJSONObject.Create;
        Result.AddPair( 'source', oSource );
        oSource.AddPair( 'file', sFile );
        oSource.AddPair( 'line', TJSONNumber.Create( rPos.LineNum ) );
        oSource.AddPair( 'text', Trim( sText ) );
      end;
    end;

    var iAddress: TCpuAddress := AAddress;
    var sText := '';
    AInstSize := 0;
    FDisassemble( FView, iAddress, sText, AInstSize );
    Result.AddPair( 'text', TrimRight( sText ) );
  except
    FreeAndNil( Result );
    raise;
  end;

end;

/// <summary>
///   <c>debug_disasm</c>: disassembles the stopped process the way the CPU window shows it - address, bytes and mnemonic in
///   the IDE's own notation - with labels and source lines, from the current thread's instruction pointer or a given
///   address.
/// </summary>
/// <param name="AReq">The request: <c>address?</c> (a number, <c>$hex</c> or <c>0xhex</c>; default the instruction pointer), <c>count?</c> (default 20, at most 1000), <c>thread?</c>.</param>
/// <returns>
///   <c>{ address, thread, bits, count, instructions:[ { address, size, text, current, label?, source? } ], notes, stoppedAt?, reason? }</c>;
///   <c>current</c> marks the instruction the thread is at.
/// </returns>
/// <exception cref="EAutoError">
///   <c>NoProcess</c> / <c>NotStopped</c>; <c>Unsupported</c> for a 32-bit process in the 64-bit IDE; <c>NoAddress</c> when
///   no address is given and the instruction pointer cannot be read; <c>BadRequest</c> for an address beyond a 32-bit
///   process's space; <c>NoCpuWindow</c> / <c>SignatureMismatch</c> from the disassembler; <c>Undisassemblable</c> when not
///   even one instruction could be disassembled.
/// </exception>
/// <remarks>
///   An address in the middle of an instruction is disassembled from there all the same, so the first lines are then
///   rubbish; memory the IDE cannot disassemble (<c>????</c> in the CPU window) ends the listing, a few bytes early
///   (GxInspect, measured).
/// </remarks>
function CmdDebugDisasm( AReq: TJSONObject ): TJSONValue;
const
  DISASM_DEFAULT = 20;
  DISASM_MAX     = 1000;
begin

  var oProcess := RequireStoppedProcess;
  var b64 := RequireReadableBitness( oProcess, 'disassembly' );
  var oThread := ResolveThread( oProcess, AReq );
  if oThread.State <> tsStopped then
    raise EAutoError.CreateCode( 'NotStopped', Format( 'Thread %d is %s, not stopped',
      [ oThread.OSThreadID, EnumText( TypeInfo( TOTAThreadState ), Ord( oThread.State ) ) ] ) );
  var iCount := ClampInt( OptInteger( AReq, 'count', DISASM_DEFAULT ), 1, DISASM_MAX );

  var bHasIp := False;
  var iIp: Int64 := 0;
  try
    var rContext := oThread.OTAThreadContextEx;
{$IFDEF CPUX86}
    iIp := if b64 then Int64( rContext.win64.Rip ) else Int64( rContext.win32.Eip );
{$ELSE}
    iIp := Int64( rContext.win64.Rip );   // the 64-bit IDE refused a 32-bit process above
{$ENDIF}
    bHasIp := True;
  except
    //  Deliberately broad, and not hidden: a thread without a readable context only loses the default address and the
    //  marker (bHasIp stays False), and a request that needed the default is refused below with NoAddress.
    on Exception do ;
  end;

  var iAddress: Int64;
  if AReq.GetValue( 'address' ) <> nil then
    iAddress := Int64( AddressArgument( AReq, 'address', 'debug_disasm' ) )
  else if bHasIp then
    iAddress := iIp
  else
    raise EAutoError.CreateCode( 'NoAddress', Format( 'The instruction pointer of thread %d cannot be read; give an address',
      [ oThread.OSThreadID ] ) );
  if ( not b64 ) and ( UInt64( iAddress ) > $FFFFFFFF ) then
    raise EAutoError.CreateCode( 'BadRequest', 'That address is beyond the address space of a 32-bit process' );

  var oDisassembler := TCpuDisassembler.Create;
  var oRes := TJSONObject.Create;
  try
    oDisassembler.Init;
    oRes.AddPair( 'address', Hex64( UInt64( iAddress ) ) );
    oRes.AddPair( 'thread', TJSONNumber.Create( Int64( oThread.OSThreadID ) ) );
    oRes.AddPair( 'bits', TJSONNumber.Create( if b64 then 64 else 32 ) );
    var oList := TJSONArray.Create;
    oRes.AddPair( 'instructions', oList );

    var iAt := iAddress;
    var sReason := '';
    while oList.Count < iCount do
    begin
      var iSize := 0;
      var oRow: TJSONObject := nil;
      try
        oRow := oDisassembler.Row( iAt, oList.Count = 0, iSize );
      except
        //  Deliberately broad, and REPORTED in the answer: the IDE's handlers raise classes of their own for memory they
        //  cannot read.
        on E: Exception do
          sReason := Format( '%s: %s', [ E.ClassName, E.Message ] );
      end;
      if ( oRow = nil ) or ( iSize <= 0 ) then
      begin
        oRow.Free;
        if sReason = '' then
          sReason := 'The IDE could not disassemble the memory there';
        Break;
      end;
      oList.AddElement( oRow );
      oRow.AddPair( 'address', Hex64( UInt64( iAt ) ) );
      oRow.AddPair( 'size', TJSONNumber.Create( iSize ) );
      oRow.AddPair( 'current', TJSONBool.Create( bHasIp and ( iAt = iIp ) ) );
      Inc( iAt, iSize );
    end;

    if oList.Count = 0 then
      raise EAutoError.CreateCode( 'Undisassemblable', Format( 'Nothing could be disassembled at %s: %s',
        [ Hex64( UInt64( iAddress ) ), sReason ] ) );

    oRes.AddPair( 'count', TJSONNumber.Create( oList.Count ) );
    var oNotes := TJSONArray.Create;
    oRes.AddPair( 'notes', oNotes );
    for var sNote in oDisassembler.Notes do
      oNotes.Add( sNote );
    if oList.Count < iCount then
    begin
      oRes.AddPair( 'stoppedAt', Hex64( UInt64( iAt ) ) );
      oRes.AddPair( 'reason', sReason );
    end;
    Result := oRes;
  except
    oRes.Free;
    oDisassembler.Free;
    raise;
  end;
  oDisassembler.Free;

end;

{ ── tree_text ───────────────────────────────────────────────────────────── }

/// <summary>
///   <c>tree_text</c> command: every displayed row of a virtual tree - the IDE's Local Variables,
///   Watch and Call Stack panes, whose text <c>get</c> cannot reach because a virtual tree publishes
///   none. A built-in of the server until 2026-10-13, when the server became one shared package; it
///   addresses its form and control through the server's own resolvers, so nothing changed for callers.
/// </summary>
/// <param name="AReq">The request object (<c>form?</c>, <c>name</c>, <c>max?</c> - the row limit).</param>
/// <returns><c>{ name, class, columns, rows:[ { level, cells } ], rowsRead, rootCount, complete, notes }</c>.</returns>
/// <exception cref="EAutoError">
///   <c>NoForm</c> / <c>NoComp</c> when the target is not found; <c>BadRequest</c> when <c>name</c> is missing or
///   names a non-control; otherwise the reader's own refusal code - <c>NotVirtualTree</c>, <c>NoWindow</c>,
///   <c>NotOnScreen</c>, <c>NoGetText</c> or <c>SignatureMismatch</c>.
/// </exception>
function CmdTreeText( AReq: TJSONObject ): TJSONValue;
begin

  if AReq.GetValue<string>( 'name', '' ) = '' then
    raise EAutoError.CreateCode( 'BadRequest', 'tree_text needs "name": the tree control on the form' );

  var oForm := TAutomationServer.ResolveForm( AReq );
  var oComp := TAutomationServer.ResolveComponent( AReq, oForm );
  if oComp is not TControl then
    raise EAutoError.CreateCode( 'BadRequest', Format( '%s is a %s, not a control', [ oComp.Name, oComp.ClassName ] ) );

  //  TryGetValue alone is wrong here. It sets its out parameter to Default( T ) when the key is
  //  MISSING, so a request without "max" used to read ONE row (0, clamped up to 1) rather than the
  //  default. The MCP tool always sends "max", which is why it went unnoticed.
  var iMax: Integer;
  if not AReq.TryGetValue<Integer>( 'max', iMax ) then
    iMax := TREE_TEXT_DEFAULT_MAX_ROWS;

  var rRead: TTreeTextResult;
  try
    rRead := ReadTreeText( TControl( oComp ), iMax );
  except
    on E: ETreeTextRefused do
      raise EAutoError.CreateCode( E.Code, E.Message );
  end;

  var oRes := TJSONObject.Create;
  try
    oRes.AddPair( 'name', oComp.Name );
    oRes.AddPair( 'class', oComp.ClassName );

    var oColumns := TJSONArray.Create;
    oRes.AddPair( 'columns', oColumns );
    for var sColumn in rRead.Columns do
      oColumns.Add( sColumn );

    var oRows := TJSONArray.Create;
    oRes.AddPair( 'rows', oRows );
    for var rRow in rRead.Rows do
    begin
      var oRow := TJSONObject.Create;
      oRows.AddElement( oRow );
      oRow.AddPair( 'level', TJSONNumber.Create( rRow.Level ) );
      var oCells := TJSONArray.Create;
      oRow.AddPair( 'cells', oCells );
      for var sCell in rRow.Cells do
        oCells.Add( sCell );
    end;

    oRes.AddPair( 'rowsRead', TJSONNumber.Create( Length( rRead.Rows ) ) );
    oRes.AddPair( 'rootCount', TJSONNumber.Create( rRead.RootCount ) );
    oRes.AddPair( 'complete', TJSONBool.Create( rRead.Complete ) );

    var oNotes := TJSONArray.Create;
    oRes.AddPair( 'notes', oNotes );
    for var sNote in rRead.Notes do
      oNotes.Add( sNote );

    Result := oRes;
  except
    oRes.Free;
    raise;
  end;

end;

{ ── Registration ────────────────────────────────────────────────────────── }

procedure RegisterIdeCommands;
begin

  TAutomationServer.RegisterCommand( 'tree_text', CmdTreeText );
  TAutomationServer.RegisterCommand( 'ide_modified', CmdIdeModified );
  TAutomationServer.RegisterCommand( 'ide_quit', CmdIdeQuit, actWorkerThread );
  TAutomationServer.RegisterCommand( 'ide_menu', CmdIdeMenu );
  TAutomationServer.RegisterCommand( 'ide_menu_click', CmdIdeMenuClick );
  TAutomationServer.RegisterCommand( 'ide_open_file', CmdIdeOpenFile );
  TAutomationServer.RegisterCommand( 'ide_modules', CmdIdeModules );
  TAutomationServer.RegisterCommand( 'ide_close_module', CmdIdeCloseModule );
  TAutomationServer.RegisterCommand( 'ide_save', CmdIdeSave );
  TAutomationServer.RegisterCommand( 'ide_projects', CmdIdeProjects );
  TAutomationServer.RegisterCommand( 'ide_set_project', CmdIdeSetProject );
  TAutomationServer.RegisterCommand( 'ide_actions', CmdIdeActions );
  TAutomationServer.RegisterCommand( 'ide_action', CmdIdeAction );
  TAutomationServer.RegisterCommand( 'ide_designer_show', CmdIdeDesignerShow );
  TAutomationServer.RegisterCommand( 'ide_designer_screenshot', CmdIdeDesignerScreenshot, actWorkerThread );
  TAutomationServer.RegisterCommand( 'ide_designer_selection', CmdIdeDesignerSelection );
  TAutomationServer.RegisterCommand( 'ide_designer_select', CmdIdeDesignerSelect );
  TAutomationServer.RegisterCommand( 'ide_designer_deselect', CmdIdeDesignerDeselect );
  TAutomationServer.RegisterCommand( 'ide_view_as_text', CmdIdeViewAsText );
  TAutomationServer.RegisterCommand( 'ide_view_as_form', CmdIdeViewAsForm );

  TAutomationServer.RegisterCommand( 'debug_state', CmdDebugState );
  TAutomationServer.RegisterCommand( 'debug_attach', CmdDebugAttach );
  TAutomationServer.RegisterCommand( 'debug_detach', CmdDebugDetach );
  TAutomationServer.RegisterCommand( 'debug_pause', CmdDebugPause );
  TAutomationServer.RegisterCommand( 'debug_run', CmdDebugRun, actWorkerThread );
  TAutomationServer.RegisterCommand( 'debug_step', CmdDebugStep, actWorkerThread );
  TAutomationServer.RegisterCommand( 'debug_run_to', CmdDebugRunTo, actWorkerThread );
  TAutomationServer.RegisterCommand( 'debug_terminate', CmdDebugTerminate );
  TAutomationServer.RegisterCommand( 'debug_threads', CmdDebugThreads );
  TAutomationServer.RegisterCommand( 'debug_set_thread', CmdDebugSetThread );
  TAutomationServer.RegisterCommand( 'debug_stack', CmdDebugStack );
  TAutomationServer.RegisterCommand( 'debug_registers', CmdDebugRegisters );
  TAutomationServer.RegisterCommand( 'debug_memory', CmdDebugMemory );
  TAutomationServer.RegisterCommand( 'debug_disasm', CmdDebugDisasm );
  TAutomationServer.RegisterCommand( 'debug_eval', CmdDebugEval );
  TAutomationServer.RegisterCommand( 'debug_breakpoints', CmdDebugBreakpoints );
  TAutomationServer.RegisterCommand( 'debug_breakpoint_set', CmdDebugBreakpointSet );
  TAutomationServer.RegisterCommand( 'debug_breakpoint_delete', CmdDebugBreakpointDelete );

  var oDebugger: IOTADebuggerServices;
  if ( GNotifierIndex < 0 ) and Supports( BorlandIDEServices, IOTADebuggerServices, oDebugger ) then
    GNotifierIndex := oDebugger.AddNotifier( TStopWatcher.Create );

end;

procedure UnregisterIdeCommands;
begin

  for var sName in COMMAND_NAMES do
    TAutomationServer.UnregisterCommand( sName );

  var oDebugger: IOTADebuggerServices;
  if ( GNotifierIndex >= 0 ) and Assigned( BorlandIDEServices ) and
    Supports( BorlandIDEServices, IOTADebuggerServices, oDebugger ) then
    oDebugger.RemoveNotifier( GNotifierIndex );
  GNotifierIndex := -1;

end;

end.
