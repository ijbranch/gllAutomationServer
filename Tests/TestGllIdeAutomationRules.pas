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

/// <summary>
///   Tests of gllIdeAutomation.Rules: the parts of the IDE commands that need no running IDE - argument readers,
///   name matching and the decisions taken on what the IDE reports. What needs the IDE itself is on the live-test
///   checklist instead.
/// </summary>
unit TestGllIdeAutomationRules;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils, System.JSON;

type
  /// <summary>Tests of the IDE commands' pure rules.</summary>
  [TestFixture]
  TTestGllIdeAutomationRules = class
  private
    /// <summary>Parses a request for a test.</summary>
    /// <param name="AJson">The request as JSON object text.</param>
    /// <returns>The request; the caller frees it.</returns>
    function Req( const AJson: string ): TJSONObject;
    /// <summary>Runs a call that must fail with EAutoError, and returns its code.</summary>
    /// <param name="ACall">The call.</param>
    /// <returns>The error code.</returns>
    function CodeOf( const ACall: TProc ): string;
  public
    /// <summary>
    ///   An absent optional argument keeps the default given - True included.  A bare TryGetValue sets its out
    ///   parameter to Default( T ) when the key is missing, which once made every new breakpoint come out disabled.
    /// </summary>
    [Test] procedure OptArguments_KeepTheirDefault_WhenAbsent;
    /// <summary>A present optional argument of the wrong JSON type is BadRequest, never silently converted or defaulted.</summary>
    [Test] procedure OptArguments_OfTheWrongType_AreBadRequest;
    /// <summary>
    ///   A call-stack header loses its parameter dump and keeps the routine's name, exactly; a header without a
    ///   parameter list is kept whole.  The debugger's dump measured over 20 KB for one form <c>Self</c>
    ///   (2026-10-30), which buried <c>debug_stack</c>'s answer.
    /// </summary>
    [Test] procedure BriefCallHeader_KeepsTheRoutineNameOnly;
    /// <summary>A required string that is missing, blank or not a string is BadRequest; a required number that is a string is too.</summary>
    [Test] procedure NeedArguments_RefuseMissingBlankOrMistyped;
    /// <summary><c>wait</c> is clamped to 0..120000, so a mistyped one cannot hold a connection for an hour.</summary>
    [Test] procedure WaitArgument_IsClamped;
    /// <summary>Addresses read as decimal, <c>$hex</c> or <c>0xhex</c>, with space around; a bare prefix or rubbish is refused.</summary>
    [Test] procedure ParseAddressText_ReadsTheThreeForms;
    /// <summary>
    ///   A file argument with a path matches that path only; a bare name matches the file name in any folder; with
    ///   AByBase the extensions are ignored, which is how a form is found from its unit or its .dfm.  Case is ignored.
    /// </summary>
    [Test] procedure FileIdMatches_ByPathByNameAndByBase;
    /// <summary>Nothing, blank and <c>.</c> all name the module in front, and nothing else does.</summary>
    [Test] procedure IsCurrentFileId_IsDotOrNothing;
    /// <summary>Only a .dfm is a form file: the estate is VCL only.</summary>
    [Test] procedure IsFormFileName_IsDfmOnly;
    /// <summary>An accelerator ampersand is dropped and a doubled one stays as one ampersand.</summary>
    [Test] procedure PlainCaption_DropsAccelerators;
    /// <summary>
    ///   An action is found by any part of its name, its caption read without the ampersand, or its category, without
    ///   regard to case; an empty filter lists everything.
    /// </summary>
    [Test] procedure ActionMatchesFilter_NameCaptionOrCategory;
    /// <summary>ide_close_module's mode defaults to refuse, accepts save and discard in any case, and refuses anything else.</summary>
    [Test] procedure CloseModeArgument_DefaultsToRefuse;
    /// <summary>Names come as an array or one string separated by commas, trimmed and in order.</summary>
    [Test] procedure NameListArgument_ArrayOrCommas;
    /// <summary>An empty name, a repeated name (case ignored), a non-string or no names at all is BadRequest rather than guessed at.</summary>
    [Test] procedure NameListArgument_RefusesWhatItCannotTrust;
    /// <summary>The debugger's break-in thread is recognised by DbgUiRemoteBreakin among its top frames, whatever their prefix and case.</summary>
    [Test] procedure IsBreakInStack_KnowsTheBreakInThread;
    /// <summary>
    ///   A program thread stopped in DebugBreak() sits in DbgBreakPoint too, but is the program's own, and must not be
    ///   refused as the break-in thread: the old rule matched DbgBreakPoint on the top frame and refused it.
    /// </summary>
    [Test] procedure IsBreakInStack_DebugBreakIsTheProgramsOwn;
    /// <summary>A path with a folder that is not rooted at a drive or a share is relative; a bare name and a full or UNC path are not.</summary>
    [Test] procedure IsRelativeFileId_KnowsRelativePaths;
    /// <summary>
    ///   The one candidate a file argument names is found by any of its file names; a bare name matching two candidates
    ///   is Ambiguous, listing them, where the first used to be taken - and the full path then settles it.
    /// </summary>
    [Test] procedure FindFileMatch_RefusesAnAmbiguousBareName;
    /// <summary>The name without its extension is tried only when nothing matches exactly, and only when asked; nothing matching is -1; a relative path is BadRequest.</summary>
    [Test] procedure FindFileMatch_ExactFirstThenByBase;
    /// <summary>Closing is blocked while anything is being debugged, unless the caller asked for it to be ended.</summary>
    [Test] procedure DebugSessionBlocksQuit_UnlessTerminating;
    /// <summary>
    ///   EventShape gives a method type's parameters as the disassembler's handlers are checked against: var, out and
    ///   const kept, names dropped; a function type gives 'function' and a non-method type ''.
    /// </summary>
    [Test] procedure EventShape_DescribesTheParameters;
  end;

implementation

uses
  System.TypInfo,
  gllAutomationServer, gllIdeAutomation.Rules;

{$TYPEINFO ON}
type
  /// <summary>The shape of the CPU window's OnDisassemble, for the EventShape test.</summary>
  TShapeDisassemble = procedure( Sender: TObject; var Address: Int64; var Text: string; var InstSize: Integer ) of object;
  /// <summary>A shape with const and out parameters, for the EventShape test.</summary>
  TShapeConstOut = procedure( Sender: TObject; const Name: string; out Count: Integer ) of object;
  /// <summary>A function-shaped method type, which EventShape reports as such.</summary>
  TShapeFunction = function( Sender: TObject ): Boolean of object;
{$TYPEINFO OFF}

function TTestGllIdeAutomationRules.Req( const AJson: string ): TJSONObject;
begin

  Result := TJSONObject.ParseJSONValue( AJson ) as TJSONObject;
  Assert.IsNotNull( Result, 'not a JSON object: ' + AJson );

end;

function TTestGllIdeAutomationRules.CodeOf( const ACall: TProc ): string;
begin

  Result := '';
  try
    ACall;
  except
    on E: EAutoError do
      Result := E.Code;
  end;
  Assert.AreNotEqual( '', Result, 'expected an EAutoError, none was raised' );

end;

procedure TTestGllIdeAutomationRules.OptArguments_KeepTheirDefault_WhenAbsent;
begin

  var oReq := Req( '{}' );
  try
    Assert.IsTrue( OptBoolean( oReq, 'enabled', True ), 'a True default came back False' );
    Assert.AreEqual( 7, OptInteger( oReq, 'count', 7 ) );
    Assert.AreEqual( 'refuse', OptString( oReq, 'mode', 'refuse' ) );
  finally
    oReq.Free;
  end;

  oReq := Req( '{"enabled":false,"count":3,"mode":"save"}' );
  try
    Assert.IsFalse( OptBoolean( oReq, 'enabled', True ) );
    Assert.AreEqual( 3, OptInteger( oReq, 'count', 7 ) );
    Assert.AreEqual( 'save', OptString( oReq, 'mode', 'refuse' ) );
  finally
    oReq.Free;
  end;

end;

procedure TTestGllIdeAutomationRules.OptArguments_OfTheWrongType_AreBadRequest;
begin

  var oReq := Req( '{"enabled":"yes","count":"3","mode":5}' );
  try
    Assert.AreEqual( 'BadRequest', CodeOf( procedure begin OptBoolean( oReq, 'enabled', True ); end ) );
    Assert.AreEqual( 'BadRequest', CodeOf( procedure begin OptInteger( oReq, 'count', 0 ); end ) );
    Assert.AreEqual( 'BadRequest', CodeOf( procedure begin OptString( oReq, 'mode', '' ); end ) );
  finally
    oReq.Free;
  end;

end;

procedure TTestGllIdeAutomationRules.NeedArguments_RefuseMissingBlankOrMistyped;
begin

  var oReq := Req( '{"blank":"  ","number":5,"text":"x","line":"12","file":"Unit1.pas"}' );
  try
    Assert.AreEqual( 'BadRequest', CodeOf( procedure begin NeedString( oReq, 'missing', 'cmd' ); end ) );
    Assert.AreEqual( 'BadRequest', CodeOf( procedure begin NeedString( oReq, 'blank', 'cmd' ); end ) );
    Assert.AreEqual( 'BadRequest', CodeOf( procedure begin NeedString( oReq, 'number', 'cmd' ); end ) );
    Assert.AreEqual( 'BadRequest', CodeOf( procedure begin NeedInteger( oReq, 'line', 'cmd' ); end ) );
    Assert.AreEqual( 'Unit1.pas', NeedString( oReq, 'file', 'cmd' ) );
    Assert.AreEqual( 5, NeedInteger( oReq, 'number', 'cmd' ) );
  finally
    oReq.Free;
  end;

end;

procedure TTestGllIdeAutomationRules.BriefCallHeader_KeepsTheRoutineNameOnly;
begin

  //  The shapes the Delphi 13 debugger gave in the live run of 2026-10-30.
  Assert.AreEqual( 'TForm1.FormCreate', BriefCallHeader( 'TForm1.FormCreate(($00000282F3BB6DE0,''Form1'',0,nil),??)' ),
    False, 'a method with an object parameter keeps its name only' );
  Assert.AreEqual( ':00007FF7F9EB8D5A TCustomForm.DoCreate', BriefCallHeader( ':00007FF7F9EB8D5A TCustomForm.DoCreate(($00007FF7F9EB87B5))' ),
    False, 'the address prefix of a frame without source stays' );
  Assert.AreEqual( ':00007FFDA7A13123 DebugBreak', BriefCallHeader( ':00007FFDA7A13123 DebugBreak' ), False,
    'a header without a parameter list is kept whole' );
  Assert.AreEqual( 'Run', BriefCallHeader( '  Run()  ' ), False, 'blanks around it are trimmed' );
  Assert.AreEqual( '(no debug info)', BriefCallHeader( '(no debug info)' ), False,
    'a header that starts with a parenthesis has no name to keep, so it is kept whole, never emptied' );

end;

procedure TTestGllIdeAutomationRules.WaitArgument_IsClamped;
begin

  for var rCase in [ TArray<Integer>.Create( -5, 0 ), TArray<Integer>.Create( 500, 500 ),
    TArray<Integer>.Create( 999999, MAX_WAIT_MS ) ] do
  begin
    var oReq := Req( Format( '{"wait":%d}', [ rCase[ 0 ] ] ) );
    try
      Assert.AreEqual( rCase[ 1 ], WaitArgument( oReq, 10 ), 'wait ' + IntToStr( rCase[ 0 ] ) );
    finally
      oReq.Free;
    end;
  end;

  var oNone := Req( '{}' );
  try
    Assert.AreEqual( 10, WaitArgument( oNone, 10 ), 'absent: the default' );
  finally
    oNone.Free;
  end;

end;

procedure TTestGllIdeAutomationRules.ParseAddressText_ReadsTheThreeForms;
begin

  var iValue: UInt64;
  Assert.IsTrue( ParseAddressText( '42', iValue ) );
  Assert.AreEqual<UInt64>( 42, iValue );
  Assert.IsTrue( ParseAddressText( ' $1F ', iValue ) );
  Assert.AreEqual<UInt64>( 31, iValue );
  Assert.IsTrue( ParseAddressText( '0x7FF67F67EF70', iValue ) );
  Assert.AreEqual<UInt64>( $7FF67F67EF70, iValue );
  Assert.IsTrue( ParseAddressText( '0XfF', iValue ), 'the prefix in either case' );
  Assert.AreEqual<UInt64>( 255, iValue );
  Assert.IsFalse( ParseAddressText( '', iValue ), 'empty' );
  Assert.IsFalse( ParseAddressText( '0x', iValue ), 'a bare 0x' );
  Assert.IsFalse( ParseAddressText( '$', iValue ), 'a bare $' );
  Assert.IsFalse( ParseAddressText( 'main', iValue ), 'rubbish' );

end;

procedure TTestGllIdeAutomationRules.FileIdMatches_ByPathByNameAndByBase;
begin

  Assert.IsTrue( FileIdMatches( 'D:\Work\Unit1.pas', 'unit1.PAS', False ), 'a bare name, case ignored' );
  Assert.IsTrue( FileIdMatches( 'D:\Work\Unit1.pas', 'd:\work\UNIT1.pas', False ), 'the full path, case ignored' );
  Assert.IsFalse( FileIdMatches( 'D:\Work\Unit1.pas', 'D:\Other\Unit1.pas', False ), 'a path names that folder only' );
  Assert.IsFalse( FileIdMatches( 'D:\Work\Unit1.pas', 'Unit1.dfm', False ), 'without AByBase the extension counts' );
  Assert.IsTrue( FileIdMatches( 'D:\Work\Unit1.dfm', 'Unit1.pas', True ), 'by base, the .dfm answers to the unit' );
  Assert.IsFalse( FileIdMatches( 'D:\Work\Unit12.dfm', 'Unit1.pas', True ), 'by base is still the whole name' );
  Assert.IsFalse( FileIdMatches( '', 'Unit1.pas', False ), 'an empty candidate never matches' );

end;

procedure TTestGllIdeAutomationRules.IsCurrentFileId_IsDotOrNothing;
begin

  Assert.IsTrue( IsCurrentFileId( '' ) );
  Assert.IsTrue( IsCurrentFileId( ' . ' ) );
  Assert.IsFalse( IsCurrentFileId( '.pas' ) );
  Assert.IsFalse( IsCurrentFileId( 'Unit1.pas' ) );

end;

procedure TTestGllIdeAutomationRules.IsFormFileName_IsDfmOnly;
begin

  Assert.IsTrue( IsFormFileName( 'D:\Work\Unit1.DFM' ) );
  Assert.IsFalse( IsFormFileName( 'D:\Work\Unit1.pas' ) );
  Assert.IsFalse( IsFormFileName( 'D:\Work\Unit1.dfm.bak' ) );

end;

procedure TTestGllIdeAutomationRules.PlainCaption_DropsAccelerators;
begin

  Assert.AreEqual( 'Run', PlainCaption( '&Run' ) );
  Assert.AreEqual( 'Save & Exit', PlainCaption( 'Save && E&xit' ) );
  Assert.AreEqual( 'Plain', PlainCaption( 'Plain' ) );

end;

procedure TTestGllIdeAutomationRules.ActionMatchesFilter_NameCaptionOrCategory;
begin

  Assert.IsTrue( ActionMatchesFilter( 'RunRunCommand', '&Run', 'Run', '' ), 'an empty filter lists everything' );
  Assert.IsTrue( ActionMatchesFilter( 'RunRunCommand', '&Run', 'Run', 'runcomm' ), 'part of the name, case ignored' );
  Assert.IsTrue( ActionMatchesFilter( 'FileSaveAsCommand', 'Save &As...', 'File', 'save as' ), 'the caption without its ampersand' );
  Assert.IsTrue( ActionMatchesFilter( 'DebugCPUCommand', 'CPU', 'Debug Windows', 'windows' ), 'the category' );
  Assert.IsFalse( ActionMatchesFilter( 'RunRunCommand', '&Run', 'Run', 'compile' ), 'nothing matches' );

end;

procedure TTestGllIdeAutomationRules.CloseModeArgument_DefaultsToRefuse;
begin

  for var sCase in [ '{}=refuse', '{"mode":"SAVE"}=save', '{"mode":" discard "}=discard' ] do
  begin
    var aParts := sCase.Split( [ '=' ] );
    var oReq := Req( aParts[ 0 ] );
    try
      //  Case-sensitive: the mode is reported lower-cased, and AreEqual on strings would otherwise ignore case.
      Assert.AreEqual( aParts[ 1 ], CloseModeArgument( oReq ), False, aParts[ 0 ] );
    finally
      oReq.Free;
    end;
  end;

  var oBad := Req( '{"mode":"ask"}' );
  try
    Assert.AreEqual( 'BadRequest', CodeOf( procedure begin CloseModeArgument( oBad ); end ) );
  finally
    oBad.Free;
  end;

end;

procedure TTestGllIdeAutomationRules.NameListArgument_ArrayOrCommas;
begin

  var oReq := Req( '{"a":["Button1"," Edit1 ","Timer1"],"b":"Button1, Edit1"}' );
  try
    var aNames := NameListArgument( oReq, 'a', 'cmd' );
    Assert.AreEqual( 3, Integer( Length( aNames ) ) );
    Assert.AreEqual( 'Button1', aNames[ 0 ] );
    Assert.AreEqual( 'Edit1', aNames[ 1 ], 'trimmed' );
    Assert.AreEqual( 'Timer1', aNames[ 2 ] );
    aNames := NameListArgument( oReq, 'b', 'cmd' );
    Assert.AreEqual( 2, Integer( Length( aNames ) ) );
    Assert.AreEqual( 'Edit1', aNames[ 1 ] );
  finally
    oReq.Free;
  end;

end;

procedure TTestGllIdeAutomationRules.NameListArgument_RefusesWhatItCannotTrust;
begin

  var oReq := Req( '{"empty":"Button1,,Edit1","twice":["Button1","BUTTON1"],"number":[1],"none":[],"blank":" "}' );
  try
    for var sKey in [ 'empty', 'twice', 'number', 'none', 'blank', 'missing' ] do
      Assert.AreEqual( 'BadRequest', CodeOf( procedure begin NameListArgument( oReq, sKey, 'cmd' ); end ), sKey );
  finally
    oReq.Free;
  end;

end;

procedure TTestGllIdeAutomationRules.IsBreakInStack_KnowsTheBreakInThread;
begin

  Assert.IsTrue( IsBreakInStack( [ 'ntdll.DbgBreakPoint', 'ntdll.DbgUiRemoteBreakin', 'KERNEL32.BaseThreadInitThunk' ] ),
    'the break-in thread as Windows creates it' );
  Assert.IsTrue( IsBreakInStack( [ ':00007FFB1234 ntdll.dbguiremotebreakin + $2E' ] ), 'with an address and offset, any case' );
  Assert.IsFalse( IsBreakInStack( [ 'Unit1.TForm1.Button1Click(Self=$2A3B)', 'Vcl.Controls.TControl.Click' ] ) );
  Assert.IsFalse( IsBreakInStack( [] ), 'no frames' );

end;

procedure TTestGllIdeAutomationRules.IsBreakInStack_DebugBreakIsTheProgramsOwn;
begin

  Assert.IsFalse( IsBreakInStack( [ 'ntdll.DbgBreakPoint', 'KERNELBASE.DebugBreak', 'Unit1.TForm1.Go(Self=$2A3B)' ] ),
    'a program thread stopped in DebugBreak' );

end;

procedure TTestGllIdeAutomationRules.IsRelativeFileId_KnowsRelativePaths;
begin

  Assert.IsTrue( IsRelativeFileId( 'src\Unit1.pas' ) );
  Assert.IsTrue( IsRelativeFileId( '..\Unit1.pas' ) );
  Assert.IsTrue( IsRelativeFileId( 'D:Unit\Unit1.pas' ), 'a drive without a root is relative to that drive''s current folder' );
  Assert.IsFalse( IsRelativeFileId( 'Unit1.pas' ), 'a bare name' );
  Assert.IsFalse( IsRelativeFileId( 'D:\Work\Unit1.pas' ) );
  Assert.IsFalse( IsRelativeFileId( 'D:/Work/Unit1.pas' ) );
  Assert.IsFalse( IsRelativeFileId( '\\server\share\Unit1.pas' ) );

end;

procedure TTestGllIdeAutomationRules.FindFileMatch_RefusesAnAmbiguousBareName;
begin

  var aCandidates: TArray<TArray<string>> := [
    [ 'D:\ProjA\Unit1.pas', 'D:\ProjA\Unit1.dfm' ],
    [ 'D:\ProjB\Unit2.pas' ],
    [ 'D:\ProjB\Unit1.pas' ] ];
  Assert.AreEqual( 'Ambiguous', CodeOf( procedure begin FindFileMatch( aCandidates, 'Unit1.pas', False ); end ) );
  Assert.AreEqual( 2, FindFileMatch( aCandidates, 'D:\ProjB\Unit1.pas', False ), 'the full path settles it' );
  Assert.AreEqual( 0, FindFileMatch( aCandidates, 'Unit1.dfm', False ), 'by another of its file names' );
  Assert.AreEqual( 1, FindFileMatch( aCandidates, 'unit2.PAS', False ), 'one match, case ignored' );

  var oData: TJSONValue := nil;
  try
    FindFileMatch( aCandidates, 'Unit1.pas', False );
  except
    on E: EAutoError do
      oData := E.Data.Clone as TJSONValue;
  end;
  try
    Assert.IsNotNull( oData, 'the candidates in error.data' );
    Assert.AreEqual( '["D:\\ProjA\\Unit1.pas","D:\\ProjB\\Unit1.pas"]', oData.ToJSON );
  finally
    oData.Free;
  end;

end;

procedure TTestGllIdeAutomationRules.FindFileMatch_ExactFirstThenByBase;
begin

  var aCandidates: TArray<TArray<string>> := [ [ 'D:\Work\Foo.dfm' ], [ 'D:\Work\Bar.pas' ], [] ];
  Assert.AreEqual( -1, FindFileMatch( aCandidates, 'Foo.pas', False ), 'by base only when asked' );
  Assert.AreEqual( 0, FindFileMatch( aCandidates, 'Foo.pas', True ), 'by base: the .dfm answers to the unit' );
  Assert.AreEqual( 1, FindFileMatch( aCandidates, 'Bar.pas', True ), 'exact' );
  Assert.AreEqual( -1, FindFileMatch( aCandidates, 'Baz.pas', True ), 'nothing' );
  Assert.AreEqual( 'BadRequest', CodeOf( procedure begin FindFileMatch( aCandidates, 'Work\Bar.pas', True ); end ), 'relative' );

end;

procedure TTestGllIdeAutomationRules.DebugSessionBlocksQuit_UnlessTerminating;
begin

  Assert.IsFalse( DebugSessionBlocksQuit( 0, False ), 'nothing debugged' );
  Assert.IsTrue( DebugSessionBlocksQuit( 1, False ), 'one process, not told to end it' );
  Assert.IsFalse( DebugSessionBlocksQuit( 2, True ), 'told to end them' );

end;

procedure TTestGllIdeAutomationRules.EventShape_DescribesTheParameters;
begin

  Assert.AreEqual( 'TObject; var Int64; var string; var Integer', EventShape( TypeInfo( TShapeDisassemble ) ) );
  Assert.AreEqual( 'TObject; const string; out Integer', EventShape( TypeInfo( TShapeConstOut ) ) );
  Assert.AreEqual( 'function', EventShape( TypeInfo( TShapeFunction ) ) );
  Assert.AreEqual( '', EventShape( TypeInfo( Integer ) ) );

end;

initialization
  TDUnitX.RegisterTestFixture( TTestGllIdeAutomationRules );

end.
