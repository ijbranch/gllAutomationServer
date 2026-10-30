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
///   Tests of <c>gllAutomationServer.Client</c>, driving a real second process: this test exe, started
///   with <c>/CLIENTTARGET</c>, is the app ( <c>RunClientTargetIfAsked</c> ).
/// </summary>
unit TestGllAutomationClient;

interface

uses
  DUnitX.TestFramework,
  gllAutomationServer.Client;

type
  /// <summary>The client against a launched app: launch, commands, errors, dialogs, screenshots, close, and the trust checks.</summary>
  [TestFixture]
  TTestGllAutomationClient = class
  private
    /// <summary>The launched target, fresh for each test.</summary>
    FApp: TAutomationApp;
    /// <summary>A scratch folder for planted discovery files and screenshots, removed after each test.</summary>
    FScratch: string;
    /// <summary>The name this test's target registers under, unique per test so another run of the suite cannot be mistaken for it.</summary>
    FName: string;
    /// <summary>Launches a target registered as <c>AName</c>.</summary>
    /// <param name="AName">The name it registers under.</param>
    /// <returns>The app, which the caller owns.</returns>
    function LaunchTarget( const AName: string ): TAutomationApp;
  public
    /// <summary>Launches the target and makes the scratch folder.</summary>
    [Setup]
    procedure Setup;
    /// <summary>Closes the target and removes the scratch folder.</summary>
    [TearDown]
    procedure TearDown;
    /// <summary>
    ///   Proves <c>Launch</c> returns the endpoint of the process it started, not another advertised app:
    ///   the name the target registered and a live PID that owns the advertised port.
    /// </summary>
    [Test]
    procedure Launch_FindsTheLaunchedProcess;
    /// <summary>Proves the three basic commands reach the other process: a property written, a handler run, its effect read back.</summary>
    [Test]
    procedure SetClickGet_DriveTheApp;
    /// <summary>Proves <c>SetProp</c> reports an unchanged value as unchanged, so a test can tell an OnChange cannot have fired.</summary>
    [Test]
    procedure SetProp_ReportsWhetherTheValueChanged;
    /// <summary>Proves a server error arrives as <c>EAutomationCommandError</c> carrying the server's own code, here <c>NoComp</c>.</summary>
    [Test]
    procedure CommandError_CarriesTheServerCode;
    /// <summary>
    ///   Proves a click whose handler raised fails the call: the server catches the exception and reports it in
    ///   a successful reply, which a client that read only <c>ok</c> would take as a pass.
    /// </summary>
    [Test]
    procedure Click_HandlerRaised_Raises;
    /// <summary>Proves a modal dialog can be seen, read ( its <c>TLabel</c> through the active form ) and answered, and the app then carries on.</summary>
    [Test]
    procedure ModalDialog_ReadAndAnswered;
    /// <summary>Proves <c>Screenshot</c> writes the PNG where the test asked, not to the Desktop.</summary>
    [Test]
    procedure Screenshot_WritesTheGivenPath;
    /// <summary>
    ///   Proves a screenshot path that is not a local drive path is refused with <c>BadPath</c>: a relative or
    ///   drive-relative one would resolve against the app's folder, not the caller's, and a UNC one would make
    ///   the app open a connection in its own name.
    /// </summary>
    /// <param name="APath">The path refused.</param>
    [Test]
    [TestCase( 'Relative', '.\button.png' )]
    [TestCase( 'DriveRelative', 'C:button.png' )]
    [TestCase( 'Unc', '\\localhost\c$\button.png' )]
    [TestCase( 'Device', '\\?\C:\button.png' )]
    procedure Screenshot_NotALocalPath_IsRefused( const APath: string );
    /// <summary>Proves <c>Attach</c> refuses to guess between two running apps of one name, as it does for an empty target.</summary>
    [Test]
    procedure Attach_TwoOfOneName_Refuses;
    /// <summary>Proves <c>WaitForProp</c> returns False on time-out instead of raising, and True once the value is there.</summary>
    [Test]
    procedure WaitForProp_TimesOutAndSucceeds;
    /// <summary>Proves <c>Close</c> shuts the app through its own close path ( not a kill ) and leaves no advertisement behind.</summary>
    [Test]
    procedure Close_ExitsCleanly;
    /// <summary>Proves <c>Attach</c> finds a running app by its name and by its PID, and refuses a name nobody registered.</summary>
    [Test]
    procedure Attach_ByNameAndPid;
    /// <summary>Proves <c>Launch</c> reports an app that exits before advertising, with its exit code, instead of waiting out the time.</summary>
    [Test]
    procedure Launch_AppExitsEarly_Raises;
    /// <summary>Proves <c>Launch</c> gives up on an app that never advertises, and terminates it rather than leaving it running.</summary>
    [Test]
    procedure Launch_NeverAdvertises_RaisesAndTerminates;
    /// <summary>
    ///   Proves the trust checks: a planted advertisement naming a live PID that does not own the port is
    ///   ignored, one naming an exited process is deleted, a file whose fields have the wrong types or that is
    ///   not UTF-8 is skipped instead of failing the whole lookup, and a trust check that says no excludes a
    ///   real app.
    /// </summary>
    [Test]
    procedure ReadEndpoints_TrustChecks;
  end;

/// <summary>
///   Runs this exe as the test's target app when it was started with <c>/CLIENTTARGET</c> ( a form with an
///   edit, a label and three buttons, served by gllAutomationServer under the name <c>/CLIENTNAME:x</c> gives ),
///   <c>/CLIENTEXIT</c> ( exits with code 3 at once ) or <c>/CLIENTIDLE</c> ( waits a minute without a
///   server ).  Called first thing by the runner.
/// </summary>
/// <returns>True when this process was one of those, has run, and must now exit; False to run the suite.</returns>
function RunClientTargetIfAsked: Boolean;

implementation

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.IOUtils, System.JSON,
  Vcl.Forms, Vcl.StdCtrls, Vcl.Dialogs,
  GllDUnitX.Station,
  gllAutomationServer;

const
  /// <summary>The name the target registers under.</summary>
  TARGET_APP  = 'ClientTarget';
  /// <summary>The target's form.</summary>
  TARGET_FORM = 'frmClientTarget';

type
  /// <summary>The target app's form, built in code so the suite needs no .dfm.</summary>
  TClientTargetForm = class( TForm )
  private
    /// <summary>Writes "Hello " and the edit's text to the label.</summary>
    /// <param name="Sender">The button.</param>
    procedure GoClick( Sender: TObject );
    /// <summary>Shows a message box, then notes in the label that it closed.</summary>
    /// <param name="Sender">The button.</param>
    procedure ModalClick( Sender: TObject );
    /// <summary>Raises, as a faulty handler would.</summary>
    /// <param name="Sender">The button.</param>
    /// <exception cref="EAbort">Always.</exception>
    procedure RaiseClick( Sender: TObject );
  public
    /// <summary>Builds the controls.</summary>
    /// <param name="AOwner">The owner.</param>
    constructor Create( AOwner: TComponent ); override;
  end;

constructor TClientTargetForm.Create( AOwner: TComponent );

  function AddButton( const AName, ACaption: string; ALeft: Integer; AClick: TNotifyEvent ): TButton;
  begin
    Result          := TButton.Create( Self );
    Result.Name     := AName;
    Result.Parent   := Self;
    Result.SetBounds( ALeft, 75, 90, 28 );
    Result.Caption  := ACaption;
    Result.OnClick  := AClick;
  end;

begin

  inherited CreateNew( AOwner );
  Name              := TARGET_FORM;
  Caption           := 'Client target';
  SetBounds( 100, 100, 420, 180 );

  var oEdit         := TEdit.Create( Self );
  oEdit.Name        := 'edtName';
  oEdit.Parent      := Self;
  oEdit.SetBounds( 10, 10, 200, 24 );
  oEdit.Text        := '';

  var oLabel        := TLabel.Create( Self );
  oLabel.Name       := 'lblOut';
  oLabel.Parent     := Self;
  oLabel.SetBounds( 10, 45, 300, 20 );
  oLabel.Caption    := '-';

  AddButton( 'btnGo', 'Go', 10, GoClick );
  AddButton( 'btnModal', 'Modal', 110, ModalClick );
  AddButton( 'btnRaise', 'Raise', 210, RaiseClick );

end;

procedure TClientTargetForm.GoClick( Sender: TObject );
begin

  TLabel( FindComponent( 'lblOut' ) ).Caption := 'Hello ' + TEdit( FindComponent( 'edtName' ) ).Text;

end;

procedure TClientTargetForm.ModalClick( Sender: TObject );
begin

  ShowMessage( 'modal here' );
  TLabel( FindComponent( 'lblOut' ) ).Caption := 'modal closed';

end;

procedure TClientTargetForm.RaiseClick( Sender: TObject );
begin

  raise EAbort.Create( 'the handler failed' );

end;

function RunClientTargetIfAsked: Boolean;
begin

  Result            := True;
  if FindCmdLineSwitch( 'CLIENTEXIT' ) then
    Halt( 3 );
  if FindCmdLineSwitch( 'CLIENTIDLE' ) then
  begin
    Sleep( 60000 );
    Exit;
  end;
  if not FindCmdLineSwitch( 'CLIENTTARGET' ) then
    Exit( False );

  var sName         := '';
  if not FindCmdLineSwitch( 'CLIENTNAME', sName, True, [ clstValueAppended ] ) or ( sName = '' ) then
    sName           := TARGET_APP;
  Application.Initialize;
  var oForm: TClientTargetForm;
  Application.CreateForm( TClientTargetForm, oForm );
  TAutomationServer.Start( sName );
  Application.Run;
  TAutomationServer.Stop;

end;

{ TTestGllAutomationClient }

procedure TTestGllAutomationClient.Setup;
begin

  FScratch          := TPath.Combine( TPath.GetTempPath, 'gllAutomationClientTests-' + TGUID.NewGuid.ToString );
  TDirectory.CreateDirectory( FScratch );
  FName             := TARGET_APP + '-' + TGUID.NewGuid.ToString.Substring( 1, 8 );
  FApp              := LaunchTarget( FName );

end;

function TTestGllAutomationClient.LaunchTarget( const AName: string ): TAutomationApp;
begin

  Result            := TAutomationApp.Launch( ParamStr( 0 ), '/CLIENTTARGET /CLIENTNAME:' + AName );

end;

procedure TTestGllAutomationClient.TearDown;
begin

  FreeAndNil( FApp );
  if TDirectory.Exists( FScratch ) then
    TDirectory.Delete( FScratch, True );

end;

procedure TTestGllAutomationClient.Launch_FindsTheLaunchedProcess;
begin

  Assert.AreEqual( FName, FApp.Endpoint.App );
  Assert.IsTrue( TAutomationDiscovery.IsPidAlive( FApp.Endpoint.Pid ), 'the launched process is not running' );
  Assert.AreNotEqual( GetCurrentProcessId, FApp.Endpoint.Pid, 'the endpoint is this test process, not the launched one' );
  Assert.IsTrue( TAutomationDiscovery.PidOwnsLocalPort( FApp.Endpoint.Pid, FApp.Endpoint.Port ), 'the PID does not own the port' );

end;

procedure TTestGllAutomationClient.SetClickGet_DriveTheApp;
begin

  FApp.SetProp( TARGET_FORM, 'edtName', 'Text', 'Ian' );
  FApp.Click( TARGET_FORM, 'btnGo' );
  Assert.AreEqual( 'Hello Ian', FApp.GetProp( TARGET_FORM, 'lblOut', 'Caption' ) );

end;

procedure TTestGllAutomationClient.SetProp_ReportsWhetherTheValueChanged;
begin

  Assert.IsTrue( FApp.SetProp( TARGET_FORM, 'edtName', 'Text', 'first' ), 'a new value was reported unchanged' );
  Assert.IsFalse( FApp.SetProp( TARGET_FORM, 'edtName', 'Text', 'first' ), 'the same value was reported changed' );

end;

procedure TTestGllAutomationClient.CommandError_CarriesTheServerCode;
begin

  var sCode         := '';
  try
    FApp.GetProp( TARGET_FORM, 'btnMissing', 'Caption' );
  except
    on E: EAutomationCommandError do
      sCode         := E.Code;
  end;
  Assert.AreEqual( 'NoComp', sCode );

end;

procedure TTestGllAutomationClient.Click_HandlerRaised_Raises;
begin

  var sCode         := '';
  var sMessage      := '';
  try
    FApp.Click( TARGET_FORM, 'btnRaise' );
  except
    on E: EAutomationCommandError do
    begin
      sCode         := E.Code;
      sMessage      := E.Message;
    end;
  end;
  Assert.AreEqual( 'HandlerRaised', sCode );
  Assert.Contains( sMessage, 'the handler failed' );

end;

procedure TTestGllAutomationClient.ModalDialog_ReadAndAnswered;
begin

  RequireInteractiveStation( 'a visible modal dialog for dialogs to list' );

  FApp.ClickAsync( TARGET_FORM, 'btnModal' );
  Assert.IsTrue( FApp.WaitForProp( 'active', 'Message', 'Caption', 'modal here', 5000 ), 'the message box text was not read' );

  var oDialogs      := FApp.ModalDialogs;
  try
    Assert.AreEqual( 1, oDialogs.GetValue<TJSONArray>( 'windows' ).Count, 'one modal window should be waiting' );
  finally
    oDialogs.Free;
  end;

  Assert.AreEqual( 'gone', FApp.ClickDialogButton( 'OK' ) );
  Assert.IsTrue( FApp.WaitForProp( TARGET_FORM, 'lblOut', 'Caption', 'modal closed', 5000 ), 'the handler did not carry on after the dialog' );

end;

procedure TTestGllAutomationClient.Screenshot_WritesTheGivenPath;
begin

  RequireInteractiveStation( 'a painted window to render' );

  var sPath         := TPath.Combine( FScratch, 'button.png' );
  Assert.AreEqual( sPath, FApp.Screenshot( TARGET_FORM, 'btnGo', sPath ) );
  Assert.IsTrue( TFile.Exists( sPath ), 'no PNG at the requested path' );
  Assert.IsTrue( TFile.GetSize( sPath ) > 200, 'the PNG is too small to hold a rendered button' );

end;

procedure TTestGllAutomationClient.Screenshot_NotALocalPath_IsRefused( const APath: string );
begin

  var sCode         := '';
  try
    //  each names a folder that exists ( ".", C:'s current one, C:\ ), so only the local-path rule refuses it
    FApp.Screenshot( TARGET_FORM, 'btnGo', APath );
  except
    on E: EAutomationCommandError do
      sCode         := E.Code;
  end;
  Assert.AreEqual( 'BadPath', sCode );

end;

procedure TTestGllAutomationClient.WaitForProp_TimesOutAndSucceeds;
begin

  Assert.IsFalse( FApp.WaitForProp( TARGET_FORM, 'lblOut', 'Caption', 'never', 300 ), 'a value that never appears was reported' );
  FApp.SetProp( TARGET_FORM, 'lblOut', 'Caption', 'now' );
  Assert.IsTrue( FApp.WaitForProp( TARGET_FORM, 'lblOut', 'Caption', 'now', 2000 ), 'a value that is there was not seen' );

end;

procedure TTestGllAutomationClient.Close_ExitsCleanly;
begin

  var iPid          := FApp.Endpoint.Pid;
  Assert.IsTrue( FApp.Close, 'the app had to be terminated' );
  Assert.IsFalse( TAutomationDiscovery.IsPidAlive( iPid ), 'the app is still running' );
  Assert.IsFalse( TFile.Exists( TPath.Combine( AUTOMATION_DISCOVERY_DIR, Format( '%d.json', [ iPid ] ) ) ),
    'the advertisement was left behind' );

end;

procedure TTestGllAutomationClient.Attach_ByNameAndPid;
begin

  var oByName       := TAutomationApp.Attach( FName );
  try
    Assert.AreEqual( FApp.Endpoint.Pid, oByName.Endpoint.Pid );
  finally
    oByName.Free;
  end;
  Assert.IsTrue( TAutomationDiscovery.IsPidAlive( FApp.Endpoint.Pid ), 'freeing an attached app closed it' );

  var oByPid        := TAutomationApp.Attach( FApp.Endpoint.Pid.ToString );
  try
    Assert.AreEqual( FName, oByPid.Endpoint.App );
  finally
    oByPid.Free;
  end;

  Assert.WillRaise(
    procedure
    begin
      TAutomationApp.Attach( 'NoSuchApp' ).Free;
    end, EAutomationClientError );

end;

procedure TTestGllAutomationClient.Launch_AppExitsEarly_Raises;
begin

  var sMessage      := '';
  try
    TAutomationApp.Launch( ParamStr( 0 ), '/CLIENTEXIT', 10000 ).Free;
  except
    on E: EAutomationClientError do
      sMessage      := E.Message;
  end;
  Assert.Contains( sMessage, 'exited with code 3' );

end;

procedure TTestGllAutomationClient.Launch_NeverAdvertises_RaisesAndTerminates;
begin

  var sMessage      := '';
  try
    TAutomationApp.Launch( ParamStr( 0 ), '/CLIENTIDLE', 500 ).Free;
  except
    on E: EAutomationClientError do
      sMessage      := E.Message;
  end;
  Assert.Contains( sMessage, 'did not advertise itself' );

  //  the message names the PID it started; that process, and only that one, must be gone
  var iStart        := Pos( '( pid ', sMessage );
  Assert.IsTrue( iStart > 0, 'the message does not name the PID: ' + sMessage );
  var sPid          := Copy( sMessage, iStart + Length( '( pid ' ), MaxInt );
  sPid              := Copy( sPid, 1, Pos( ' ', sPid ) - 1 );
  var iPid: Cardinal := StrToUInt( sPid );
  Assert.IsFalse( TAutomationDiscovery.IsPidAlive( iPid ), 'the app that never advertised is still running' );

end;

procedure TTestGllAutomationClient.Attach_TwoOfOneName_Refuses;
begin

  var oTwin         := LaunchTarget( FName );
  try
    var sMessage    := '';
    try
      TAutomationApp.Attach( FName ).Free;
    except
      on E: EAutomationClientError do
        sMessage    := E.Message;
    end;
    Assert.Contains( sMessage, 'give a PID' );
  finally
    oTwin.Free;
  end;

end;

procedure TTestGllAutomationClient.ReadEndpoints_TrustChecks;
begin

  var oCopy         := LaunchTarget( FName + '-copy' );
  try
    //  the live copy's own advertisement, which must survive everything else in the folder
    TFile.Copy( TPath.Combine( AUTOMATION_DISCOVERY_DIR, Format( '%d.json', [ oCopy.Endpoint.Pid ] ) ),
      TPath.Combine( FScratch, 'real.json' ) );
    //  a live PID ( this process ) that owns no listening port at 1
    TFile.WriteAllText( TPath.Combine( FScratch, 'planted.json' ),
      Format( '{"app":"Planted","pid":%d,"port":1,"token":"x"}', [ GetCurrentProcessId ] ) );
    //  fields of the wrong type, which GetValue<T> would raise on
    TFile.WriteAllText( TPath.Combine( FScratch, 'typed.json' ), '{"app":1,"pid":"x","port":"y","token":2}' );
    TFile.WriteAllText( TPath.Combine( FScratch, 'huge.json' ), '{"app":"Huge","pid":1e30,"port":1.5,"token":"x"}' );
    //  not UTF-8: $C3 must be followed by a continuation byte, and ( is not one
    TFile.WriteAllBytes( TPath.Combine( FScratch, 'bytes.json' ), TBytes.Create( $7B, $22, $C3, $28, $22, $7D ) );
    //  an exited process: the launched target's PID once it is closed
    var iGone       := FApp.Endpoint.Pid;
    FApp.Close;
    TFile.WriteAllText( TPath.Combine( FScratch, 'gone.json' ),
      Format( '{"app":"Gone","pid":%d,"port":%d,"token":"x"}', [ iGone, oCopy.Endpoint.Port ] ) );

    var aEnds       := TAutomationDiscovery.ReadEndpoints( FScratch );
    Assert.AreEqual( 1, Integer( Length( aEnds ) ), 'a planted, malformed or stale advertisement was trusted, or the real one lost' );
    Assert.AreEqual( oCopy.Endpoint.Pid, aEnds[ 0 ].Pid );
    Assert.IsTrue( TFile.Exists( TPath.Combine( FScratch, 'planted.json' ) ), 'a live process''s file was deleted' );
    Assert.IsFalse( TFile.Exists( TPath.Combine( FScratch, 'gone.json' ) ), 'an exited process''s file was kept' );

    //  a trust check that says no excludes the real one
    var aNone       := TAutomationDiscovery.ReadEndpoints( FScratch,
      function( APid: Cardinal; const AApp: string ): Boolean
      begin
        Result      := APid <> oCopy.Endpoint.Pid;
      end );
    Assert.AreEqual( 0, Integer( Length( aNone ) ), 'the trust check was ignored' );
  finally
    oCopy.Free;
  end;

end;

initialization
  TDUnitX.RegisterTestFixture( TTestGllAutomationClient );

end.
