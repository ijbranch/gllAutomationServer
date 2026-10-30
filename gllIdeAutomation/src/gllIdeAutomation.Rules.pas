(* GITLAK Software
  ***************************************************************************

    (C) 2026 Ian Branch (GITLAK Software). All rights reserved.

    Portions derived from GExperts' GxInspect by Thomas Mueller (dummzeuch),
    svn r6031: EventShape is ported from EventShape in ide\GxInspect_Ide.pas;
    FileIdMatches follows the matching rules of FindModuleFor and FindFormView
    in the same unit (by path, by file name, then by name without extension).

    This code and all associated intellectual property, including proprietary
    algorithms and confidential information, are the exclusive property of Ian
    Branch (GITLAK Software), save the portions named above, which remain
    subject to GExperts' own licence.

    Any reproduction, distribution, or use, in whole or in part, by any other
    party is strictly prohibited without the express written permission of the
    Author.

    Complete development history is retained & maintained in my Private GitHub
    Repository.

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
  gllIdeAutomation - the rules of the IDE commands that need no IDE

  Reading and checking request arguments, matching file names, actions and component names, and the
  small decisions the commands take on what the IDE reports. Kept apart from
  gllIdeAutomation.IdeCommands, which needs ToolsAPI and a running IDE, so the test suite can compile and
  prove these on their own.
*)
/// <summary>
///   The rules of the IDE automation commands that need no running IDE: argument readers, name matching
///   and the decisions taken on what the IDE reports. Pure functions, tested by the gllAutomationServer suite.
/// </summary>
unit gllIdeAutomation.Rules;

{$IF CompilerVersion < 37.0}
  {$MESSAGE FATAL 'gllIdeAutomation requires Delphi 13 Florence or later.'}
{$IFEND}

interface

uses
  System.JSON, System.TypInfo;

const
  /// <summary>Upper bound on any <c>wait</c> argument; a mistyped one must not hold a connection for an hour.</summary>
  MAX_WAIT_MS         = 120000;

/// <summary>
///   Reads an optional argument, keeping <paramref name="ADefault"/> when it is absent.
///   <c>TJSONValue.TryGetValue</c> cannot be used for this on its own: it sets its out parameter to
///   <c>Default( T )</c> when the key is missing, so a default assigned beforehand is silently replaced
///   by False, 0 or ''. That once made every new breakpoint come out disabled.
/// </summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ADefault">The value when the argument is absent.</param>
/// <returns>The argument, or <paramref name="ADefault"/>.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when the argument is present but not a string.</exception>
function OptString( AReq: TJSONObject; const AKey, ADefault: string ): string;

/// <summary>Reads an optional integer argument; see <see cref="OptString"/> for why this is not a bare TryGetValue.</summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ADefault">The value when the argument is absent.</param>
/// <returns>The argument, or <paramref name="ADefault"/>.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when the argument is present but not a number.</exception>
function OptInteger( AReq: TJSONObject; const AKey: string; ADefault: Integer ): Integer;

/// <summary>Reads an optional Boolean argument; see <see cref="OptString"/> for why this is not a bare TryGetValue.</summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ADefault">The value when the argument is absent.</param>
/// <returns>The argument, or <paramref name="ADefault"/>.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when the argument is present but not true or false.</exception>
function OptBoolean( AReq: TJSONObject; const AKey: string; ADefault: Boolean ): Boolean;

/// <summary>Reads a required string argument.</summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ACommand">The command, for the message.</param>
/// <returns>The value, never empty.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when the argument is missing, empty or not a string.</exception>
function NeedString( AReq: TJSONObject; const AKey, ACommand: string ): string;

/// <summary>Reads a required integer argument.</summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ACommand">The command, for the message.</param>
/// <returns>The value.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when the argument is missing or not a number.</exception>
function NeedInteger( AReq: TJSONObject; const AKey, ACommand: string ): Integer;

/// <summary>Reads the optional <c>wait</c> argument, clamped to 0..<c>MAX_WAIT_MS</c>.</summary>
/// <param name="AReq">The request.</param>
/// <param name="ADefault">The value when the argument is absent.</param>
/// <returns>The wait in milliseconds.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when <c>wait</c> is not a number.</exception>
function WaitArgument( AReq: TJSONObject; ADefault: Integer ): Integer;

/// <summary>Limits a value to a range.</summary>
/// <param name="AValue">The value.</param>
/// <param name="ALow">The smallest allowed.</param>
/// <param name="AHigh">The largest allowed.</param>
/// <returns><paramref name="AValue"/>, or the bound it passed.</returns>
function ClampInt( AValue, ALow, AHigh: Integer ): Integer;

/// <summary>Reads an address written as decimal, or as hex with <c>$</c> or <c>0x</c> in front.</summary>
/// <param name="AText">The text, surrounding space allowed.</param>
/// <param name="AValue">Receives the address.</param>
/// <returns>True when the text is an address.</returns>
function ParseAddressText( const AText: string; out AValue: UInt64 ): Boolean;

/// <summary>Reads an address argument given as a JSON number, or as text <see cref="ParseAddressText"/> reads.</summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ACommand">The command, for the message.</param>
/// <returns>The address.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when it is missing or unreadable.</exception>
function AddressArgument( AReq: TJSONObject; const AKey, ACommand: string ): UInt64;

/// <summary>Whether a file argument names the module the IDE has in front: absent, empty or <c>.</c>.</summary>
/// <param name="AFileId">The argument.</param>
/// <returns>True for the current module.</returns>
function IsCurrentFileId( const AFileId: string ): Boolean;

/// <summary>
///   Whether a file the IDE has open answers to a file argument. With a path the whole path is compared; without
///   one the file name alone, so a script need not know where the IDE put the file; with
///   <paramref name="AByBase"/> the names are compared without their extensions as well, which is how a form is
///   found whichever of its unit and its <c>.dfm</c> is open (GxInspect). Case is ignored throughout.
/// </summary>
/// <param name="ACandidate">The open file, with its path. Empty never matches.</param>
/// <param name="AWanted">The argument.</param>
/// <param name="AByBase">True to compare the names without extensions.</param>
/// <returns>True when they match.</returns>
function FileIdMatches( const ACandidate, AWanted: string; AByBase: Boolean ): Boolean;

/// <summary>Whether a file is a VCL form file, which is what a form shown as text is open as.</summary>
/// <param name="AFileName">The file.</param>
/// <returns>True for a <c>.dfm</c>.</returns>
function IsFormFileName( const AFileName: string ): Boolean;

/// <summary>A caption as a person reads it: without its accelerator ampersands (a doubled one stays as one).</summary>
/// <param name="ACaption">The caption.</param>
/// <returns>The plain caption.</returns>
function PlainCaption( const ACaption: string ): string;

/// <summary>
///   Whether an action is listed under a filter: the filter is found, without regard to case, in the action's
///   name, its plain caption or its category. An empty filter lists everything.
/// </summary>
/// <param name="AName">The action's component name.</param>
/// <param name="ACaption">Its caption, ampersands and all.</param>
/// <param name="ACategory">Its category.</param>
/// <param name="AFilter">The filter.</param>
/// <returns>True when it is listed.</returns>
function ActionMatchesFilter( const AName, ACaption, ACategory, AFilter: string ): Boolean;

/// <summary>Reads the <c>mode</c> of <c>ide_close_module</c>.</summary>
/// <param name="AReq">The request.</param>
/// <returns><c>refuse</c> (the default), <c>save</c> or <c>discard</c>.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> for anything else.</exception>
function CloseModeArgument( AReq: TJSONObject ): string;

/// <summary>
///   Reads a list of names, given as a JSON array of strings or as one string separated by commas. Each name is
///   trimmed; an empty one, or one given twice (case ignored), is refused rather than guessed at.
/// </summary>
/// <param name="AReq">The request.</param>
/// <param name="AKey">The argument's name.</param>
/// <param name="ACommand">The command, for the message.</param>
/// <returns>The names, at least one, in the order given.</returns>
/// <exception cref="EAutoError"><c>BadRequest</c> when the list is missing, empty, holds a non-string, an empty name or a repeat.</exception>
function NameListArgument( AReq: TJSONObject; const AKey, ACommand: string ): TArray<string>;

/// <summary>
///   Whether a call stack is the debugger's own break-in thread: after Pause the current thread is the one Windows
///   creates to break into the process, stopped in <c>ntdll.DbgBreakPoint</c> CALLED FROM <c>ntdll.DbgUiRemoteBreakin</c>,
///   and stepping it lets the process run on (GxInspect).  <c>DbgBreakPoint</c> alone does not decide it: a thread of the
///   program that calls <c>DebugBreak</c> stops there too, and is the program's own.
/// </summary>
/// <param name="AHeaders">The top frames' headers, top first, as the Call Stack pane shows them; three are enough.</param>
/// <returns>True when <c>DbgUiRemoteBreakin</c> is among the top three frames.</returns>
function IsBreakInStack( const AHeaders: TArray<string> ): Boolean;

/// <summary>
///   Whether a file argument is a RELATIVE path: one with a folder that is not rooted at a drive or a share.  Such a path
///   would be resolved against the IDE's current directory, which nobody chose, so it is refused.
/// </summary>
/// <param name="AFileId">The argument.</param>
/// <returns>True for a relative path; False for a bare file name or a full path.</returns>
function IsRelativeFileId( const AFileId: string ): Boolean;

/// <summary>
///   Picks the one open item a file argument names, from candidates that each carry one or more file names (a module's
///   own and its editors').  The exact match is tried first (by path, or by file name alone for a bare name), then, with
///   <paramref name="ATryBase"/>, the names without their extensions.  Several candidates matching in the deciding pass
///   is refused rather than guessed at: with <c>Unit1.pas</c> open from two projects, a bare name must not close the
///   wrong one.
/// </summary>
/// <param name="ACandidates">The candidates' file names; an empty entry is a candidate that cannot match.</param>
/// <param name="AWanted">The argument.</param>
/// <param name="ATryBase">True to try the names without extensions when nothing matches exactly.</param>
/// <returns>The index of the one candidate that matches, or -1 when none does.</returns>
/// <exception cref="EAutoError">
///   <c>Ambiguous</c> when several match, their first file names in <c>error.data</c> - give the path; <c>BadRequest</c>
///   for a relative path.
/// </exception>
function FindFileMatch( const ACandidates: TArray<TArray<string>>; const AWanted: string; ATryBase: Boolean ): Integer;

/// <summary>
///   Whether closing the IDE has to be refused because it is debugging something: the IDE would stop and ask
///   whether to end the session, and nobody would answer. Allowed only when the caller said to end it.
/// </summary>
/// <param name="AProcessCount">How many processes the debugger has.</param>
/// <param name="ATerminate">True when the caller asked for them to be ended first.</param>
/// <returns>True when the close must be refused.</returns>
function DebugSessionBlocksQuit( AProcessCount: Integer; ATerminate: Boolean ): Boolean;

/// <summary>
///   The parameters of a method type as its type information has them: type names only, each with <c>var</c>,
///   <c>out</c> or <c>const</c> in front where it has that, e.g. <c>TObject; var Int64; var string</c>, so a handler
///   can be checked against the shape it is about to be called with. Ported from GxInspect's <c>EventShape</c>.
/// </summary>
/// <param name="ATypeInfo">The method type's type information.</param>
/// <returns>The parameter list; <c>function</c> for a method type that is not a procedure; '' for a non-method type.</returns>
function EventShape( ATypeInfo: PTypeInfo ): string;

implementation

uses
  System.SysUtils, System.StrUtils, System.Math,
  gllAutomationServer;

function OptString( AReq: TJSONObject; const AKey, ADefault: string ): string;
begin

  if AReq.GetValue( AKey ) = nil then Exit( ADefault );
  if not ( AReq.GetValue( AKey ) is TJSONString ) then
    raise EAutoError.CreateCode( 'BadRequest', Format( '"%s" must be a string', [ AKey ] ) );
  Result := TJSONString( AReq.GetValue( AKey ) ).Value;

end;

function OptInteger( AReq: TJSONObject; const AKey: string; ADefault: Integer ): Integer;
begin

  if AReq.GetValue( AKey ) = nil then Exit( ADefault );
  if not ( AReq.GetValue( AKey ) is TJSONNumber ) then
    raise EAutoError.CreateCode( 'BadRequest', Format( '"%s" must be a number', [ AKey ] ) );
  Result := TJSONNumber( AReq.GetValue( AKey ) ).AsInt;

end;

function OptBoolean( AReq: TJSONObject; const AKey: string; ADefault: Boolean ): Boolean;
begin

  if AReq.GetValue( AKey ) = nil then Exit( ADefault );
  if not ( AReq.GetValue( AKey ) is TJSONBool ) then
    raise EAutoError.CreateCode( 'BadRequest', Format( '"%s" must be true or false', [ AKey ] ) );
  Result := TJSONBool( AReq.GetValue( AKey ) ).AsBoolean;

end;

function NeedString( AReq: TJSONObject; const AKey, ACommand: string ): string;
begin

  Result := '';
  if AReq.GetValue( AKey ) is TJSONString then
    Result := TJSONString( AReq.GetValue( AKey ) ).Value;
  if Trim( Result ) = '' then
    raise EAutoError.CreateCode( 'BadRequest', Format( '%s needs "%s"', [ ACommand, AKey ] ) );

end;

function NeedInteger( AReq: TJSONObject; const AKey, ACommand: string ): Integer;
begin

  if not ( AReq.GetValue( AKey ) is TJSONNumber ) then
    raise EAutoError.CreateCode( 'BadRequest', Format( '%s needs "%s", a number', [ ACommand, AKey ] ) );
  Result := TJSONNumber( AReq.GetValue( AKey ) ).AsInt;

end;

function WaitArgument( AReq: TJSONObject; ADefault: Integer ): Integer;
begin

  Result := ClampInt( OptInteger( AReq, 'wait', ADefault ), 0, MAX_WAIT_MS );

end;

function ClampInt( AValue, ALow, AHigh: Integer ): Integer;
begin

  Result := AValue;
  if Result < ALow then Result := ALow;
  if Result > AHigh then Result := AHigh;

end;

function ParseAddressText( const AText: string; out AValue: UInt64 ): Boolean;
begin

  var sText := Trim( AText );
  if sText.StartsWith( '0x', True ) then
    sText := '$' + Copy( sText, 3, MaxInt );
  Result := ( sText <> '' ) and ( sText <> '$' ) and TryStrToUInt64( sText, AValue );

end;

function AddressArgument( AReq: TJSONObject; const AKey, ACommand: string ): UInt64;
begin

  var oValue := AReq.GetValue( AKey );
  if oValue is TJSONNumber then
    Exit( UInt64( TJSONNumber( oValue ).AsInt64 ) );

  if not ( ( oValue is TJSONString ) and ParseAddressText( TJSONString( oValue ).Value, Result ) ) then
    raise EAutoError.CreateCode( 'BadRequest', Format( '%s needs "%s": a number, or hex as $1234 or 0x1234', [ ACommand, AKey ] ) );

end;

function IsCurrentFileId( const AFileId: string ): Boolean;
begin

  Result := ( Trim( AFileId ) = '' ) or ( Trim( AFileId ) = '.' );

end;

function FileIdMatches( const ACandidate, AWanted: string; AByBase: Boolean ): Boolean;
begin

  if ( ACandidate = '' ) or ( AWanted = '' ) then Exit( False );

  if AByBase then
    Result := SameText( ChangeFileExt( ExtractFileName( ACandidate ), '' ), ChangeFileExt( ExtractFileName( AWanted ), '' ) )
  else if ExtractFilePath( AWanted ) = '' then
    Result := SameText( ExtractFileName( ACandidate ), AWanted )
  else
    Result := SameText( ExpandFileName( ACandidate ), ExpandFileName( AWanted ) );

end;

function IsFormFileName( const AFileName: string ): Boolean;
begin

  Result := SameText( ExtractFileExt( AFileName ), '.dfm' );

end;

function PlainCaption( const ACaption: string ): string;
begin

  Result := ReplaceStr( ReplaceStr( ReplaceStr( ACaption, '&&', #0 ), '&', '' ), #0, '&' );

end;

function ActionMatchesFilter( const AName, ACaption, ACategory, AFilter: string ): Boolean;
begin

  var sFilter := Trim( AFilter );
  if sFilter = '' then Exit( True );
  Result := ContainsText( AName, sFilter ) or ContainsText( PlainCaption( ACaption ), sFilter ) or ContainsText( ACategory, sFilter );

end;

function CloseModeArgument( AReq: TJSONObject ): string;
begin

  Result := LowerCase( Trim( OptString( AReq, 'mode', 'refuse' ) ) );
  if ( Result <> 'refuse' ) and ( Result <> 'save' ) and ( Result <> 'discard' ) then
    raise EAutoError.CreateCode( 'BadRequest', 'ide_close_module mode is refuse, save or discard' );

end;

function NameListArgument( AReq: TJSONObject; const AKey, ACommand: string ): TArray<string>;
begin

  var oValue := AReq.GetValue( AKey );
  var aRaw: TArray<string> := [];
  if oValue is TJSONArray then
  begin
    for var oItem in TJSONArray( oValue ) do
    begin
      if oItem is not TJSONString then
        raise EAutoError.CreateCode( 'BadRequest', Format( '"%s" holds names, as strings', [ AKey ] ) );
      aRaw := aRaw + [ TJSONString( oItem ).Value ];
    end;
  end
  else if oValue is TJSONString then
    aRaw := TJSONString( oValue ).Value.Split( [ ',' ] )
  else
    raise EAutoError.CreateCode( 'BadRequest', Format( '%s needs "%s": an array of names, or names separated by commas',
      [ ACommand, AKey ] ) );

  Result := [];
  for var sRaw in aRaw do
  begin
    var sName := Trim( sRaw );
    if sName = '' then
      raise EAutoError.CreateCode( 'BadRequest', Format( '"%s" holds an empty name', [ AKey ] ) );
    for var sSeen in Result do
      if SameText( sSeen, sName ) then
        raise EAutoError.CreateCode( 'BadRequest', Format( '"%s" names %s twice', [ AKey, sName ] ) );
    Result := Result + [ sName ];
  end;
  if Length( Result ) = 0 then
    raise EAutoError.CreateCode( 'BadRequest', Format( '%s needs at least one name in "%s"', [ ACommand, AKey ] ) );

end;

function IsBreakInStack( const AHeaders: TArray<string> ): Boolean;
begin

  Result := False;
  for var iFrame := 0 to Min( High( AHeaders ), 2 ) do
    if ContainsText( AHeaders[ iFrame ], 'DbgUiRemoteBreakin' ) then
      Exit( True );

end;

function IsRelativeFileId( const AFileId: string ): Boolean;
begin

  var sId := Trim( AFileId );
  if ExtractFilePath( sId ) = '' then Exit( False );
  var bDrive := ( Length( sId ) >= 3 ) and ( sId[ 2 ] = ':' ) and CharInSet( sId[ 3 ], [ '\', '/' ] );
  var bShare := sId.StartsWith( '\\' ) or sId.StartsWith( '//' );
  Result := not ( bDrive or bShare );

end;

function FindFileMatch( const ACandidates: TArray<TArray<string>>; const AWanted: string; ATryBase: Boolean ): Integer;
begin

  if IsRelativeFileId( AWanted ) then
    raise EAutoError.CreateCode( 'BadRequest', Format( '%s is a relative path; give the full path, or the file name alone',
      [ AWanted ] ) );

  Result := -1;
  for var bByBase in [ False, True ] do
  begin
    if bByBase and not ATryBase then Break;
    var aFound: TArray<Integer> := [];
    for var iCandidate := 0 to High( ACandidates ) do
      for var sName in ACandidates[ iCandidate ] do
        if FileIdMatches( sName, AWanted, bByBase ) then
        begin
          aFound := aFound + [ iCandidate ];
          Break;
        end;
    if Length( aFound ) = 1 then
      Exit( aFound[ 0 ] );
    if Length( aFound ) > 1 then
    begin
      var oData := TJSONArray.Create;
      for var iFound in aFound do
        oData.Add( ACandidates[ iFound ][ 0 ] );
      raise EAutoError.CreateCodeData( 'Ambiguous', Format( '%d open files answer to %s; give the full path', [ Length( aFound ),
        AWanted ] ), oData );
    end;
  end;

end;

function DebugSessionBlocksQuit( AProcessCount: Integer; ATerminate: Boolean ): Boolean;
begin

  Result := ( AProcessCount > 0 ) and not ATerminate;

end;

function EventShape( ATypeInfo: PTypeInfo ): string;
begin

  if ( ATypeInfo = nil ) or ( ATypeInfo.Kind <> tkMethod ) then Exit( '' );

  var pData := GetTypeData( ATypeInfo );
  if pData.MethodKind <> mkProcedure then Exit( 'function' );

  Result := '';
  var pWalk := PByte( @pData.ParamList );
  for var iParam := 0 to pData.ParamCount - 1 do
  begin
    var eFlags := TParamFlags( pWalk^ );
    Inc( pWalk );
    Inc( pWalk, PByte( pWalk )^ + 1 );   // the parameter's name, which does not matter
    if iParam > 0 then
      Result := Result + '; ';
    if pfVar in eFlags then
      Result := Result + 'var '
    else if pfOut in eFlags then
      Result := Result + 'out '
    else if pfConst in eFlags then
      Result := Result + 'const ';
    Result := Result + string( PShortString( pWalk )^ );
    Inc( pWalk, PByte( pWalk )^ + 1 );
  end;

end;

end.
