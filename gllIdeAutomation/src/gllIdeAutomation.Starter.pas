(* GITLAK Software
  ***************************************************************************

    (C) 2016-2026 Ian Branch (GITLAK Software). All rights reserved.

    This code and all associated intellectual property are the exclusive
    property of Ian Branch (GITLAK Software).

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

  ***************************************************************************
*)

///<summary>
/// Starts the automation server inside the Delphi IDE, so an external agent can drive the IDE
/// through its live VCL component model instead of synthesising keystrokes.
///
/// <para><b>Gating.</b> It starts only when the environment variable
/// <c>GITLAK_IDE_AUTOMATION</c> is set to 1, so an IDE launched without it is completely
/// unaffected. Deliberately NOT a command-line switch: <c>bds.exe</c> parses its own command
/// line and treats arguments it does not recognise as files to open.</para>
///
/// <para><b>To use it:</b> set the variable, then launch the IDE from the same shell:</para>
/// <code>
/// $env:GITLAK_IDE_AUTOMATION = '1'
/// Start-Process 'C:\Program Files (x86)\Embarcadero\Studio\37.0\bin64\bds.exe'
/// </code>
/// <para>The IDE then registers itself in the discovery directory as <c>DelphiIDE</c>, and
/// tools/Start-IDE.ps1 does all of the above for you.</para>
///
/// <para><b>What it is good for:</b> driving menus, actions, dialogs and controls through the
/// live VCL component model - coordinate-free, DPI-independent, and it cannot type into the
/// wrong window. <b>What it is not:</b> a way to read the Local Variables or Watch panes
/// directly. Those are VirtualStringTree and their cell text is not a published property; see
/// tools/read_pane.py for the clipboard route round that.</para> </summary>
unit gllIdeAutomation.Starter;

{$IF CompilerVersion < 37.0}
  {$MESSAGE FATAL 'gllIdeAutomation requires Delphi 13 Florence or later.'}
{$IFEND}

interface

implementation

uses
  Winapi.Windows, System.SysUtils, System.IOUtils,
  gllAutomationServer, gllIdeAutomation.IdeCommands;

const
  ///<summary> Environment variable that must be '1' before the server is started. </summary>
  ENV_GATE = 'GITLAK_IDE_AUTOMATION';
  ///<summary> Name the IDE is discovered under, i.e. what app_list reports. </summary>
  APP_NAME = 'DelphiIDE';

///<summary>
/// @returns True if the gate environment variable is set to 1 </summary>
function AutomationRequested: Boolean;
begin
  Result := Trim( GetEnvironmentVariable( ENV_GATE ) ) = '1';
end;

///<summary>
/// Appends one line to %LOCALAPPDATA%\GITLAK\gllIdeAutomation-startup.log: the package's start-up and shut-down
/// run inside the IDE with every exception swallowed, so this file is the only record of what they did.  Never
/// raises. </summary>
/// <param name="AText">What happened.</param>
procedure StartupLog( const AText: string );
begin
  try
    var sBase := GetEnvironmentVariable( 'LOCALAPPDATA' );
    if sBase = '' then Exit;   // never fall back to a folder on the IDE's current drive
    var sDir := IncludeTrailingPathDelimiter( sBase ) + 'GITLAK';
    ForceDirectories( sDir );
    //  One append that creates the file when missing: no exists-then-Rewrite race between two IDEs starting together.
    //  A line lost to a sharing clash with the other IDE is acceptable; an exception reaching the IDE is not.
    TFile.AppendAllText( sDir + '\gllIdeAutomation-startup.log', Format( '%s pid %d: %s', [
      FormatDateTime( 'yyyy-mm-dd hh:nn:ss.zzz', Now ), GetCurrentProcessId, AText ] ) + sLineBreak, TEncoding.UTF8 );
  except
    // logging must never cost the IDE anything
  end;
end;

initialization
  // Every failure mode here is swallowed deliberately. This package is loaded during IDE
  // startup, before any user work exists to be saved, and an exception escaping a design-time
  // package's initialisation is shown to the user as a package load failure - for a facility
  // they did not ask for and, ungated, are not even using. A port clash or a read-only
  // discovery directory must cost the automation server, never the IDE.
  try
    if ( AutomationRequested ) then
    begin
      StartupLog( 'initialization: gate set, starting the server' );
      // False: leave the IDE's own timers alone - an application can log itself out mid-test and
      // needs them disabled; the IDE's belong to its plug-ins and are not ours to stop.
      TAutomationServer.Start( APP_NAME, False );
      StartupLog( 'initialization: server started, registering the IDE commands' );
      RegisterIdeCommands;
      StartupLog( 'initialization: IDE commands registered' );
    end;
  except
    // Not shown to the user (see above), but not lost either: a failure here left a server that answered ping with
    // NO ide_* command registered and nothing anywhere saying why (2026-10-30).  A bare except, so that nothing at
    // all escapes - not even an object that is no Exception.
    var sWhat := if ExceptObject is Exception then
      Exception( ExceptObject ).ClassName + ': ' + Exception( ExceptObject ).Message else 'a non-Exception object';
    StartupLog( 'initialization FAILED, IDE commands not registered: ' + sWhat );
    OutputDebugString( PChar( 'gllIdeAutomation: start-up failed, IDE commands not registered: ' + sWhat ) );
  end;

finalization
  try
    //  Only when the gate started something: an IDE closed without automation writes nothing.
    if ( AutomationRequested ) then
      StartupLog( 'finalization: stopping the server and unregistering the IDE commands' );
    TAutomationServer.Stop;
    UnregisterIdeCommands;
    if ( AutomationRequested ) then
      StartupLog( 'finalization: done' );
  except
    // Likewise: a failure while the IDE is closing must not turn into a shutdown hang.
    var sWhat := if ExceptObject is Exception then
      Exception( ExceptObject ).ClassName + ': ' + Exception( ExceptObject ).Message else 'a non-Exception object';
    StartupLog( 'finalization FAILED: ' + sWhat );
  end;

end.
