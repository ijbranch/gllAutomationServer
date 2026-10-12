(* GITLAK Software
  ***************************************************************************

    (C) 2026 Ian Branch (GITLAK Software). All rights reserved.

    This code and all associated intellectual property, including proprietary
    algorithms and confidential information, are the exclusive property of Ian
    Branch (GITLAK Software).

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

  ***************************************************************************
*)

/// <summary>
///   End-to-end tests for gllAutomationServer: the server is started in this process, and each
///   request goes over loopback TCP with the token from the discovery file, exactly as an external
///   agent sends it. Moved from GITLAKLibUnitTests with the unit on 2026-10-13, and extended there
///   with the 0.10 / 0.11 behaviour (keys, reachable and synthetic component names, dotted properties).
/// </summary>
/// <remarks>
///   A main-thread command is marshalled with <c>TThread.Synchronize</c>, and this test runner's main
///   thread is the one sending the request. So the request is sent from a background thread while the
///   main thread pumps <c>CheckSynchronize</c> and the message queue; blocking on the socket instead
///   would deadlock. The message queue matters for <c>keys</c>, whose strokes are posted messages.
/// </remarks>
unit TestGllAutomationServer;

interface

uses
  DUnitX.TestFramework,
  System.JSON,
  Vcl.Forms, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Imaging.pngimage;

type
  /// <summary>End-to-end tests of the automation server's commands.</summary>
  [TestFixture]
  TTestGllAutomationServer = class
  private
    /// <summary>The session token read from this process's discovery file.</summary>
    FToken: string;
    /// <summary>The form the addressing, property and keys tests drive; created in Setup.</summary>
    FForm: TForm;
    /// <summary>An edit owned by the application, not the form, and only parented into it - a docked add-in frame's control.</summary>
    FDocked: TEdit;
    /// <summary>The memo on the test form.</summary>
    FMemo: TMemo;
    /// <summary>The plain edit the keys tests type into.</summary>
    FEdit: TEdit;
    /// <summary>A non-windowed control for the screenshot tests.</summary>
    FLabel: TLabel;
    /// <summary>
    ///   Takes a screenshot that must succeed, loads the PNG, deletes the file, and returns the reply.
    /// </summary>
    /// <param name="AArgs">The request members as a JSON object text.</param>
    /// <param name="APng">Receives the loaded image; the caller frees it.</param>
    /// <returns>The reply object; the caller frees it.</returns>
    function Shoot( const AArgs: string; out APng: TPngImage ): TJSONObject;
    /// <summary>
    ///   Sends one request and returns the parsed reply, pumping <c>CheckSynchronize</c> and the message
    ///   queue while it waits so that a main-thread command - and a keys sequence - can run.
    /// </summary>
    /// <param name="ACmd">The command.</param>
    /// <param name="AArgs">Extra request members as a JSON object text, or empty.</param>
    /// <returns>The reply object; the caller frees it.</returns>
    function Send( const ACmd: string; const AArgs: string = '' ): TJSONObject;
    /// <summary>Sends one raw request line, exactly as given, and returns the raw reply line.</summary>
    /// <param name="ALine">The request line, without its terminator.</param>
    /// <returns>The reply line; the test fails if the connection gives none.</returns>
    function SendLine( const ALine: string ): string;
    /// <summary>Sends a request that must fail, and returns its <c>error.code</c>.</summary>
    /// <param name="ACmd">The command.</param>
    /// <param name="AArgs">Extra request members as a JSON object text.</param>
    /// <returns>The error code.</returns>
    function SendFail( const ACmd, AArgs: string ): string;
    /// <summary>Builds the test form: two panels that each OWN an edit named edtTown, two unnamed buttons, a memo, a plain edit, and a host panel with the docked edit parented in.</summary>
    procedure BuildForm;
  public
    /// <summary>Registers the test commands, builds the test form, starts the server and reads the token.</summary>
    [Setup]
    procedure Setup;
    /// <summary>Stops the server, removes the test commands and frees the test form.</summary>
    [TearDown]
    procedure TearDown;
    /// <summary>
    ///   The default thread is the main VCL thread, which every built-in VCL command relies on; a handler
    ///   that touches a form must never run anywhere else. Proves the request's arguments reach it too.
    /// </summary>
    [Test] procedure MainThreadCommand_RunsOnMainThread_WithItsArguments;
    /// <summary>
    ///   actWorkerThread keeps a handler OFF the main thread. That is its whole purpose: a handler that
    ///   waits on the main thread would otherwise block the very thing it waits for.
    /// </summary>
    [Test] procedure WorkerThreadCommand_RunsOffMainThread;
    /// <summary>An EAutoError raised by a handler comes back as ok:false with its own code and message.</summary>
    [Test] procedure CommandRaisingEAutoError_ReportsItsCode;
    /// <summary>
    ///   Built-in commands are matched first, so registering one of their names cannot change what it
    ///   does - otherwise a plug-in could silently redefine ping for every agent. Also pins the protocol
    ///   version ping reports, which the 0.10 bump left asserting 0.9 until this suite moved here.
    /// </summary>
    [Test] procedure RegisteredName_CannotShadowBuiltIn;
    /// <summary>UnregisterCommand really removes the command: afterwards it is an UnknownCmd.</summary>
    [Test] procedure UnregisteredCommand_IsUnknown;
    /// <summary>Names are matched without regard to case, like the built-in commands.</summary>
    [Test] procedure CommandName_IsCaseInsensitive;
    /// <summary>An empty name or a nil handler is a programming error and is refused at registration.</summary>
    [Test] procedure RegisterCommand_RefusesEmptyNameOrNilHandler;
    /// <summary>
    ///   A wrongly typed envelope field ( "id":"abc" ) still gets a reply, with the id treated as absent.
    ///   This PINS the contract: the IDE's former copy once dropped the connection here.
    /// </summary>
    [Test] procedure WrongTypedId_StillGetsAReply;
    /// <summary>
    ///   A failure found before dispatch ( a bad token ) still carries the request's id, so a caller that
    ///   matches replies by id can attribute it. It used to be omitted.
    /// </summary>
    [Test] procedure BadToken_ReplyCarriesTheId;
    /// <summary>
    ///   An over-long request is refused with RequestTooLong. Indy's default split it silently in two,
    ///   and dispatched the second half as if it were a request of its own.
    /// </summary>
    [Test] procedure OverlongRequest_IsRefused;
    /// <summary>
    ///   A name two frames' controls share is refused as Ambiguous - picking one silently would drive the
    ///   wrong control - and the error lists the path that reaches each; each path then resolves to its own.
    /// </summary>
    [Test] procedure SharedName_IsAmbiguous_AndEachPathResolves;
    /// <summary>
    ///   A control the form does not own, only parents (a docked add-in frame's), is reachable by its plain
    ///   name. Before 0.11 FindComponent could not see it at all.
    /// </summary>
    [Test] procedure DockedControl_IsReachableByName;
    /// <summary>
    ///   An unnamed component is reported by tree under a synthetic @TClass#N name, numbered per class in
    ///   ownership order, and that name resolves back to the same component; one past the end is NoComp.
    /// </summary>
    [Test] procedure UnnamedComponent_HasSyntheticName_ThatResolves;
    /// <summary>A dotted property path reaches into an object property: set Font.Size, read it back, and the control's font really changed.</summary>
    [Test] procedure DottedProperty_WritesThroughToTheObject;
    /// <summary>
    ///   A TStrings property reads as its text, as does an unpublished Text on a control (TMemo). Before 0.11
    ///   Lines returned the object's address as a number, which read like a value and was not one.
    /// </summary>
    [Test] procedure StringsAndControlText_ReadAsText;
    /// <summary>A path ending on a non-strings object is refused as NotScalar, with that object's properties in error.data so the caller can pick one.</summary>
    [Test] procedure ObjectProperty_IsNotScalar_AndListsItsProperties;
    /// <summary>
    ///   keys types through the message loop: Shift-produced characters arrive in the right case, a named
    ///   key after the text acts on it (Backspace removes the last character), and the reply comes only
    ///   once every stroke is delivered, so a read straight afterwards sees all of it.
    /// </summary>
    [Test] procedure Keys_TypeTextIntoAnEdit;
    /// <summary>A chord that names no real key is refused before anything is sent, so a typo cannot half-type a sequence.</summary>
    [Test] procedure Keys_BadChord_IsRefusedBeforeSending;
    /// <summary>
    ///   A named windowed control is RENDERED, not copied off the screen: the test form sits at -3000,
    ///   where a screen capture shows only whatever is there, yet the PNG is the memo's own size and its
    ///   own magenta background.
    /// </summary>
    [Test] procedure Screenshot_OfAControl_RendersItself_EvenOffScreen;
    /// <summary>A non-windowed control (a TLabel) has no window to render, so it is cropped out of its parent's rendering - at its own size, in its own yellow.</summary>
    [Test] procedure Screenshot_OfANonWindowedControl_IsCroppedFromItsParent;
    /// <summary>maxWidth scales the image down proportionally, and the reply gives the source size so the caller knows it was scaled.</summary>
    [Test] procedure Screenshot_MaxWidth_ScalesProportionally;
    /// <summary>
    ///   A whole-form render includes its child windows: the memo's fuchsia is found where the memo sits
    ///   in the form's window. The VCL's PaintTo, the fallback, drew only the first child of a form, so
    ///   this is what tells the DWM path (frame and every child) from a degraded one.
    /// </summary>
    [Test] procedure Screenshot_OfAForm_IncludesItsChildren;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Types, System.IOUtils, System.Diagnostics, System.Generics.Collections,
  Winapi.Windows,
  Vcl.Graphics,
  IdTCPClient, IdGlobal,
  gllAutomationServer;

const
  /// <summary>Where the server advertises itself; must match gllAutomationServer's DISCOVERY_DIR.</summary>
  DISCOVERY_DIR   = 'C:\ProgramData\GITLAK\Automation';
  /// <summary>How long one request may take before the test gives up on it.</summary>
  REQUEST_TIMEOUT = 10000;
  /// <summary>Name the test process registers under.</summary>
  APP_NAME        = 'gllAutomationServerTests';
  /// <summary>The wire-protocol version ping must report.</summary>
  PROTOCOL_VERSION = '0.12';
  /// <summary>Name of the test form, which the requests address.</summary>
  FORM_NAME       = 'AutoTestForm';

  /// <summary>A command whose handler runs on the main thread.</summary>
  CMD_MAIN        = 'test_registered_main';
  /// <summary>A command whose handler runs on the worker thread.</summary>
  CMD_WORKER      = 'test_registered_worker';
  /// <summary>A command whose handler raises EAutoError.</summary>
  CMD_FAIL        = 'test_registered_fail';
  /// <summary>Registered under a built-in name, to prove it cannot take over.</summary>
  CMD_SHADOW      = 'ping';
  /// <summary>Marker the shadowing handler would return if it ever ran.</summary>
  SHADOW_MARKER   = 'shadowed';

/// <summary>Whether the calling thread is the main thread.</summary>
/// <returns>True on the main thread.</returns>
function OnMainThread: Boolean;
begin

  Result := TThread.CurrentThread.ThreadID = MainThreadID;

end;

{ TTestGllAutomationServer }

procedure TTestGllAutomationServer.BuildForm;
begin

  FForm := TForm.CreateNew( nil );
  FForm.Name := FORM_NAME;
  FForm.SetBounds( -3000, -3000, 400, 400 ); // off-screen, but showing: keys needs a focusable control

  for var sFrame in [ 'fraA', 'fraB' ] do
  begin
    var oPanel := TPanel.Create( FForm );
    oPanel.Name := sFrame;
    oPanel.Parent := FForm;
    var oEdit := TEdit.Create( oPanel ); // owned by the panel, as a frame owns its controls
    oEdit.Name := 'edtTown';
    oEdit.Parent := oPanel;
    oEdit.Text := 'town of ' + sFrame;
  end;

  for var i := 1 to 2 do
  begin
    var oButton := TButton.Create( FForm );
    oButton.Parent := FForm;
    oButton.Caption := 'Anon' + IntToStr( i );
  end;

  FMemo := TMemo.Create( FForm );
  FMemo.Name := 'Memo1';
  FMemo.Parent := FForm;
  FMemo.Lines.Text := 'line one' + sLineBreak + 'line two';
  FMemo.SetBounds( 200, 10, 150, 90 );
  FMemo.Color := clFuchsia; // a colour nothing behind an off-screen form would happen to show

  FLabel := TLabel.Create( FForm );
  FLabel.Name := 'lblInfo';
  FLabel.Parent := FForm;
  FLabel.AutoSize := False;
  FLabel.Transparent := False;
  FLabel.Color := clYellow;
  FLabel.SetBounds( 200, 120, 80, 30 );
  FLabel.Caption := '';

  FEdit := TEdit.Create( FForm );
  FEdit.Name := 'edtType';
  FEdit.Parent := FForm;
  FEdit.Text := '';

  var oHost := TPanel.Create( FForm );
  oHost.Name := 'pnlHost';
  oHost.Parent := FForm;
  FDocked := TEdit.Create( nil ); // owned by nothing on the form: only parented in
  FDocked.Name := 'edtDocked';
  FDocked.Parent := oHost;
  FDocked.Text := 'docked';

  FForm.Show;

end;

procedure TTestGllAutomationServer.Setup;
begin

  TAutomationServer.RegisterCommand( CMD_MAIN,
    function( ARequest: TJSONObject ): TJSONValue
    begin
      var oRes := TJSONObject.Create;
      oRes.AddPair( 'onMainThread', TJSONBool.Create( OnMainThread ) );
      oRes.AddPair( 'echo', ARequest.GetValue<string>( 'text', '' ) );
      Result := oRes;
    end );

  TAutomationServer.RegisterCommand( CMD_WORKER,
    function( ARequest: TJSONObject ): TJSONValue
    begin
      var oRes := TJSONObject.Create;
      oRes.AddPair( 'onMainThread', TJSONBool.Create( OnMainThread ) );
      Result := oRes;
    end, actWorkerThread );

  TAutomationServer.RegisterCommand( CMD_FAIL,
    function( ARequest: TJSONObject ): TJSONValue
    begin
      raise EAutoError.CreateCode( 'TestFailure', 'the handler refused' );
    end );

  TAutomationServer.RegisterCommand( CMD_SHADOW,
    function( ARequest: TJSONObject ): TJSONValue
    begin
      Result := TJSONString.Create( SHADOW_MARKER );
    end );

  BuildForm;

  TAutomationServer.Start( APP_NAME, False );

  var sFile := TPath.Combine( DISCOVERY_DIR, Format( '%d.json', [ GetCurrentProcessId ] ) );
  var oDisc := TJSONObject.ParseJSONValue( TFile.ReadAllText( sFile, TEncoding.UTF8 ) ) as TJSONObject;
  try
    FToken := oDisc.GetValue<string>( 'token' );
  finally
    oDisc.Free;
  end;

end;

procedure TTestGllAutomationServer.TearDown;
begin

  TAutomationServer.Stop;
  for var sName in [ CMD_MAIN, CMD_WORKER, CMD_FAIL, CMD_SHADOW ] do
    TAutomationServer.UnregisterCommand( sName );
  FreeAndNil( FDocked );
  FreeAndNil( FForm ); // owns FLabel and FMemo

end;

function TTestGllAutomationServer.Send( const ACmd, AArgs: string ): TJSONObject;
begin

  var oReq: TJSONObject;
  if AArgs = '' then
    oReq := TJSONObject.Create
  else
    oReq := TJSONObject.ParseJSONValue( AArgs ) as TJSONObject;
  oReq.AddPair( 'token', FToken );
  oReq.AddPair( 'id', TJSONNumber.Create( 7 ) );
  oReq.AddPair( 'cmd', ACmd );
  var sLine := oReq.ToJSON;
  oReq.Free;

  var sReply := SendLine( sLine );
  Result := TJSONObject.ParseJSONValue( sReply ) as TJSONObject;
  if Result = nil then
    Assert.Fail( 'reply is not a JSON object: ' + sReply );

end;

function TTestGllAutomationServer.SendFail( const ACmd, AArgs: string ): string;
begin

  var oReply := Send( ACmd, AArgs );
  try
    Assert.IsFalse( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Result := oReply.GetValue<string>( 'error.code' );
  finally
    oReply.Free;
  end;

end;

function TTestGllAutomationServer.SendLine( const ALine: string ): string;
begin

  var iPort := TAutomationServer.Port;
  var sReply := '';
  var sFailure := '';
  var bDone := False;

  var oThread := TThread.CreateAnonymousThread(
    procedure
    begin
      var oClient := TIdTCPClient.Create( nil );
      try
        try
          oClient.Host := '127.0.0.1';
          oClient.Port := iPort;
          oClient.ConnectTimeout := REQUEST_TIMEOUT;
          oClient.ReadTimeout := REQUEST_TIMEOUT;
          oClient.Connect;
          oClient.IOHandler.WriteLn( ALine, IndyTextEncoding_UTF8 );
          sReply := oClient.IOHandler.ReadLn( IndyTextEncoding_UTF8 );
          oClient.Disconnect;
        except
          //  Reported to the test, not swallowed: Send turns it into an assertion failure.
          on E: Exception do
            sFailure := E.ClassName + ': ' + E.Message;
        end;
      finally
        oClient.Free;
        bDone := True;
      end;
    end );
  oThread.FreeOnTerminate := False;
  try
    oThread.Start;
    var rWatch := TStopwatch.StartNew;
    while not bDone and ( rWatch.ElapsedMilliseconds < REQUEST_TIMEOUT + 2000 ) do
    begin
      CheckSynchronize( 10 );
      Application.ProcessMessages; // keys strokes and their step markers are posted messages
    end;
    oThread.WaitFor;
  finally
    oThread.Free;
  end;

  if sFailure <> '' then
    Assert.Fail( 'request failed: ' + sFailure );
  Result := sReply;

end;

procedure TTestGllAutomationServer.MainThreadCommand_RunsOnMainThread_WithItsArguments;
begin

  var oReply := Send( CMD_MAIN, '{"text":"hello"}' );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 7, oReply.GetValue<Integer>( 'id' ) );
    Assert.IsTrue( oReply.GetValue<Boolean>( 'result.onMainThread' ), 'a main-thread command ran off the main thread' );
    Assert.AreEqual( 'hello', oReply.GetValue<string>( 'result.echo' ), False );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.WorkerThreadCommand_RunsOffMainThread;
begin

  var oReply := Send( CMD_WORKER );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.IsFalse( oReply.GetValue<Boolean>( 'result.onMainThread' ), 'a worker-thread command ran on the main thread' );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.CommandRaisingEAutoError_ReportsItsCode;
begin

  var oReply := Send( CMD_FAIL );
  try
    Assert.IsFalse( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'TestFailure', oReply.GetValue<string>( 'error.code' ), False );
    Assert.AreEqual( 'the handler refused', oReply.GetValue<string>( 'error.message' ), False );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.RegisteredName_CannotShadowBuiltIn;
begin

  var oReply := Send( CMD_SHADOW );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.IsTrue( oReply.GetValue( 'result' ) is TJSONObject, 'ping answered with the registered handler''s result' );
    Assert.AreEqual( PROTOCOL_VERSION, oReply.GetValue<string>( 'result.server' ), False );
    Assert.AreEqual( APP_NAME, oReply.GetValue<string>( 'result.app' ), False );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.UnregisteredCommand_IsUnknown;
begin

  TAutomationServer.UnregisterCommand( CMD_MAIN );
  var oReply := Send( CMD_MAIN );
  try
    Assert.IsFalse( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'UnknownCmd', oReply.GetValue<string>( 'error.code' ), False );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.CommandName_IsCaseInsensitive;
begin

  var oReply := Send( UpperCase( CMD_MAIN ), '{"text":"case"}' );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'case', oReply.GetValue<string>( 'result.echo' ), False );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.RegisterCommand_RefusesEmptyNameOrNilHandler;
begin

  Assert.WillRaise(
    procedure
    begin
      TAutomationServer.RegisterCommand( '  ',
        function( ARequest: TJSONObject ): TJSONValue
        begin
          Result := TJSONNull.Create;
        end );
    end, EArgumentException );

  Assert.WillRaise(
    procedure
    begin
      TAutomationServer.RegisterCommand( 'test_nil_handler', nil );
    end, EArgumentException );

end;

procedure TTestGllAutomationServer.WrongTypedId_StillGetsAReply;
begin

  var oReply := TJSONObject.ParseJSONValue(
    SendLine( Format( '{"token":"%s","id":"abc","cmd":"ping"}', [ FToken ] ) ) ) as TJSONObject;
  try
    Assert.IsNotNull( oReply, 'no JSON reply to a wrongly typed id' );
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 0, oReply.GetValue<Integer>( 'id' ), 'a non-numeric id is treated as absent' );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.BadToken_ReplyCarriesTheId;
begin

  var oReply := TJSONObject.ParseJSONValue( SendLine( '{"token":"wrong","id":9,"cmd":"ping"}' ) ) as TJSONObject;
  try
    Assert.IsFalse( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'Unauthorised', oReply.GetValue<string>( 'error.code' ), False );
    Assert.AreEqual( 9, oReply.GetValue<Integer>( 'id' ), 'the pre-dispatch failure lost the request id' );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.OverlongRequest_IsRefused;
begin

  //  Just over the server's 1 MB request limit.
  var sLine := Format( '{"token":"%s","id":3,"cmd":"ping","pad":"%s"}', [ FToken, StringOfChar( 'x', 1024 * 1024 + 16 ) ] );
  var oReply := TJSONObject.ParseJSONValue( SendLine( sLine ) ) as TJSONObject;
  try
    Assert.IsNotNull( oReply, 'no JSON reply to an over-long request' );
    Assert.IsFalse( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'RequestTooLong', oReply.GetValue<string>( 'error.code' ), False );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.SharedName_IsAmbiguous_AndEachPathResolves;
begin

  var oReply := Send( 'get', Format( '{"form":"%s","name":"edtTown","prop":"Text"}', [ FORM_NAME ] ) );
  try
    Assert.IsFalse( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'Ambiguous', oReply.GetValue<string>( 'error.code' ), False );
    var oCands := oReply.GetValue<TJSONArray>( 'error.data.candidates' );
    Assert.AreEqual( 2, oCands.Count, oReply.ToJSON );
    Assert.AreEqual( 'fraA.edtTown', oCands.Items[ 0 ].Value, False );
    Assert.AreEqual( 'fraB.edtTown', oCands.Items[ 1 ].Value, False );
  finally
    oReply.Free;
  end;

  for var sFrame in [ 'fraA', 'fraB' ] do
  begin
    var oPath := Send( 'get', Format( '{"form":"%s","name":"%s.edtTown","prop":"Text"}', [ FORM_NAME, sFrame ] ) );
    try
      Assert.IsTrue( oPath.GetValue<Boolean>( 'ok' ), oPath.ToJSON );
      Assert.AreEqual( 'town of ' + sFrame, oPath.GetValue<string>( 'result.value' ), False );
    finally
      oPath.Free;
    end;
  end;

end;

procedure TTestGllAutomationServer.DockedControl_IsReachableByName;
begin

  var oReply := Send( 'get', Format( '{"form":"%s","name":"edtDocked","prop":"Text"}', [ FORM_NAME ] ) );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'docked', oReply.GetValue<string>( 'result.value' ), False );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.UnnamedComponent_HasSyntheticName_ThatResolves;
begin

  var oTree := Send( 'tree', Format( '{"form":"%s"}', [ FORM_NAME ] ) );
  try
    Assert.IsTrue( oTree.GetValue<Boolean>( 'ok' ), oTree.ToJSON );
    var bFound := False;
    for var oItem in oTree.GetValue<TJSONArray>( 'result.components' ) do
      if TJSONObject( oItem ).GetValue<string>( 'name' ) = '@TButton#2' then
      begin
        Assert.AreEqual( 'Anon2', TJSONObject( oItem ).GetValue<string>( 'props.Caption' ), False );
        bFound := True;
      end;
    Assert.IsTrue( bFound, 'tree did not report @TButton#2: ' + oTree.ToJSON );
  finally
    oTree.Free;
  end;

  var oReply := Send( 'get', Format( '{"form":"%s","name":"@TButton#2","prop":"Caption"}', [ FORM_NAME ] ) );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'Anon2', oReply.GetValue<string>( 'result.value' ), False );
  finally
    oReply.Free;
  end;

  Assert.AreEqual( 'NoComp', SendFail( 'get', Format( '{"form":"%s","name":"@TButton#3","prop":"Caption"}', [ FORM_NAME ] ) ), False );

end;

procedure TTestGllAutomationServer.DottedProperty_WritesThroughToTheObject;
begin

  FMemo.Font.Size := 9;
  var oReply := Send( 'set', Format( '{"form":"%s","name":"Memo1","prop":"Font.Size","value":14}', [ FORM_NAME ] ) );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 14, oReply.GetValue<Integer>( 'result.value' ) );
    Assert.AreEqual( 9, oReply.GetValue<Integer>( 'result.previous' ) );
  finally
    oReply.Free;
  end;
  Assert.AreEqual( 14, FMemo.Font.Size, 'the reply said 14 but the control''s font did not change' );

end;

procedure TTestGllAutomationServer.StringsAndControlText_ReadAsText;
begin

  // A memo's TStrings is TMemoStrings, whose Text is the control's own text: no trailing line break.
  var sExpected := 'line one' + sLineBreak + 'line two';
  for var sProp in [ 'Lines', 'Lines.Text' ] do
  begin
    var oReply := Send( 'get', Format( '{"form":"%s","name":"Memo1","prop":"%s"}', [ FORM_NAME, sProp ] ) );
    try
      Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
      Assert.AreEqual( sExpected, oReply.GetValue<string>( 'result.value' ), False, sProp );
    finally
      oReply.Free;
    end;
  end;

  var oCount := Send( 'get', Format( '{"form":"%s","name":"Memo1","prop":"Lines.Count"}', [ FORM_NAME ] ) );
  try
    Assert.AreEqual( 2, oCount.GetValue<Integer>( 'result.value' ), oCount.ToJSON );
  finally
    oCount.Free;
  end;

  // TMemo does not publish Text: the window-text fallback reads it (no trailing line break there).
  var oText := Send( 'get', Format( '{"form":"%s","name":"Memo1","prop":"Text"}', [ FORM_NAME ] ) );
  try
    Assert.IsTrue( oText.GetValue<Boolean>( 'ok' ), oText.ToJSON );
    Assert.AreEqual( 'line one' + sLineBreak + 'line two', oText.GetValue<string>( 'result.value' ), False );
  finally
    oText.Free;
  end;

end;

procedure TTestGllAutomationServer.ObjectProperty_IsNotScalar_AndListsItsProperties;
begin

  var oReply := Send( 'get', Format( '{"form":"%s","name":"Memo1","prop":"Font"}', [ FORM_NAME ] ) );
  try
    Assert.IsFalse( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'NotScalar', oReply.GetValue<string>( 'error.code' ), False );
    var bHasSize := False;
    for var oProp in oReply.GetValue<TJSONArray>( 'error.data.properties' ) do
      bHasSize := bHasSize or ( TJSONObject( oProp ).GetValue<string>( 'name' ) = 'Size' );
    Assert.IsTrue( bHasSize, 'the NotScalar data did not list the font''s Size: ' + oReply.ToJSON );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Keys_TypeTextIntoAnEdit;
begin

  var oReply := Send( 'keys', Format( '{"form":"%s","name":"edtType","text":"aB?x","keys":"Backspace"}', [ FORM_NAME ] ) );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.IsTrue( oReply.GetValue<Boolean>( 'result.completed' ), oReply.ToJSON );
    Assert.AreEqual( 5, oReply.GetValue<Integer>( 'result.strokesSent' ) );
  finally
    oReply.Free;
  end;
  // Read straight off the control: the reply came only after delivery, so no wait is needed.
  Assert.AreEqual( 'aB?', FEdit.Text, False );

end;

procedure TTestGllAutomationServer.Keys_BadChord_IsRefusedBeforeSending;
begin

  FEdit.Text := 'untouched';
  Assert.AreEqual( 'BadKeys', SendFail( 'keys', Format( '{"form":"%s","name":"edtType","text":"zz","keys":"Ctrl+Nope"}', [ FORM_NAME ] ) ), False );
  Assert.AreEqual( 'untouched', FEdit.Text, False, 'a refused sequence still typed its text' );

end;

/// <summary>
///   Ignores the calling test when this process runs in Session 0, the services' session. It has no
///   interactive desktop, so DWM has nothing to compose and PrintWindow renders blank white - measured
///   2026-10-13: 22/22 run from a desktop session, the three render tests white under GITLAKMCP's
///   test_run, which launches from its service. The ignore says so, rather than failing for the
///   environment or passing without having looked.
/// </summary>
procedure RequireInteractiveSession;
begin

  var iSession: DWORD;
  if ProcessIdToSessionId( GetCurrentProcessId, iSession ) and ( iSession = 0 ) then
    Assert.Ignore( 'Session 0 (launched from a service) has no interactive desktop to render; run the suite from a desktop session' );

end;

function TTestGllAutomationServer.Shoot( const AArgs: string; out APng: TPngImage ): TJSONObject;
begin

  RequireInteractiveSession;
  Result := Send( 'screenshot', AArgs );
  Assert.IsTrue( Result.GetValue<Boolean>( 'ok' ), Result.ToJSON );
  var sPath := Result.GetValue<string>( 'result.path' );
  APng := TPngImage.Create;
  try
    APng.LoadFromFile( sPath );
  finally
    System.SysUtils.DeleteFile( sPath ); // a test must not leave PNGs on the Desktop
  end;

end;

/// <summary>Whether a pixel is within a small tolerance of a colour (PNG round trips are exact, but halftone or theming may nudge an edge).</summary>
/// <param name="APixel">The pixel read.</param>
/// <param name="AColor">The expected colour.</param>
/// <returns>True when every channel is within 8.</returns>
function NearColor( APixel, AColor: TColor ): Boolean;
begin

  var p := ColorToRGB( APixel );
  var c := ColorToRGB( AColor );
  Result := ( Abs( GetRValue( p ) - GetRValue( c ) ) <= 8 ) and ( Abs( GetGValue( p ) - GetGValue( c ) ) <= 8 ) and
    ( Abs( GetBValue( p ) - GetBValue( c ) ) <= 8 );

end;

procedure TTestGllAutomationServer.Screenshot_OfAControl_RendersItself_EvenOffScreen;
begin

  var oPng: TPngImage;
  var oReply := Shoot( Format( '{"form":"%s","name":"Memo1"}', [ FORM_NAME ] ), oPng );
  try
    Assert.AreEqual( 'control', oReply.GetValue<string>( 'result.area' ), False );
    Assert.AreEqual( FMemo.Width, oPng.Width, 'width' );
    Assert.AreEqual( FMemo.Height, oPng.Height, 'height' );
    // Bottom-right, inside the border, below any text: the memo's own background.
    var cPixel := oPng.Pixels[ oPng.Width - 8, oPng.Height - 8 ];
    Assert.IsTrue( NearColor( cPixel, clFuchsia ), Format( 'expected the memo''s fuchsia, got $%.6x: %s', [ ColorToRGB( cPixel ), oReply.ToJSON ] ) );
  finally
    oPng.Free;
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Screenshot_OfANonWindowedControl_IsCroppedFromItsParent;
begin

  var oPng: TPngImage;
  var oReply := Shoot( Format( '{"form":"%s","name":"lblInfo"}', [ FORM_NAME ] ), oPng );
  try
    Assert.AreEqual( FLabel.Width, oPng.Width, 'width' );
    Assert.AreEqual( FLabel.Height, oPng.Height, 'height' );
    for var pt in [ Point( 1, 1 ), Point( oPng.Width - 2, oPng.Height - 2 ) ] do
    begin
      var cPixel := oPng.Pixels[ pt.X, pt.Y ];
      Assert.IsTrue( NearColor( cPixel, clYellow ), Format( 'expected the label''s yellow at (%d,%d), got $%.6x', [ pt.X, pt.Y, ColorToRGB( cPixel ) ] ) );
    end;
  finally
    oPng.Free;
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Screenshot_MaxWidth_ScalesProportionally;
begin

  var oPng: TPngImage;
  var oReply := Shoot( Format( '{"form":"%s","name":"Memo1","maxWidth":75}', [ FORM_NAME ] ), oPng );
  try
    Assert.AreEqual( 75, oPng.Width, 'width' );
    Assert.AreEqual( Round( FMemo.Height * 75 / FMemo.Width ), oPng.Height, 'height' );
    Assert.AreEqual( FMemo.Width, oReply.GetValue<Integer>( 'result.sourceWidth' ), 'sourceWidth' );
    Assert.AreEqual( 75, oReply.GetValue<Integer>( 'result.width' ), 'reply width' );
  finally
    oPng.Free;
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Screenshot_OfAForm_IncludesItsChildren;
begin

  var oPng: TPngImage;
  var oReply := Shoot( Format( '{"form":"%s"}', [ FORM_NAME ] ), oPng );
  try
    Assert.AreEqual( 'form', oReply.GetValue<string>( 'result.area' ), False );
    var rcForm, rcMemo: TRect;
    GetWindowRect( FForm.Handle, rcForm );
    GetWindowRect( FMemo.Handle, rcMemo );
    Assert.AreEqual( rcForm.Width, oPng.Width, 'width: the form window, frame included' );
    // Inside the memo's bottom-right corner, in the form window's coordinates.
    var cPixel := oPng.Pixels[ rcMemo.Right - rcForm.Left - 8, rcMemo.Bottom - rcForm.Top - 8 ];
    Assert.IsTrue( NearColor( cPixel, clFuchsia ), Format( 'expected the memo''s fuchsia inside the form, got $%.6x: %s',
      [ ColorToRGB( cPixel ), oReply.ToJSON ] ) );
  finally
    oPng.Free;
    oReply.Free;
  end;

end;

initialization
  TDUnitX.RegisterTestFixture( TTestGllAutomationServer );

end.
