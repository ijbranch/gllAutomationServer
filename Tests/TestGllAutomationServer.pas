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
  System.JSON, System.Classes, System.Types,
  Vcl.Forms, Vcl.Controls, Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Imaging.pngimage;

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
    /// <param name="ADelayMs">How long the sending thread waits before connecting, so the main thread can enter a modal loop or a busy spell first.</param>
    /// <returns>The reply line; the test fails if the connection gives none.</returns>
    function SendLine( const ALine: string; ADelayMs: Integer = 0 ): string;
    /// <summary>As <see cref="Send"/>, the request leaving only after <paramref name="ADelayMs"/>.</summary>
    /// <param name="ACmd">The command.</param>
    /// <param name="AArgs">Extra request members as a JSON object text, or empty.</param>
    /// <param name="ADelayMs">The delay before the request is sent.</param>
    /// <returns>The reply object; the caller frees it.</returns>
    function SendDelayed( const ACmd, AArgs: string; ADelayMs: Integer ): TJSONObject;
    /// <summary>Sends a request that must fail, and returns its <c>error.code</c>.</summary>
    /// <param name="ACmd">The command.</param>
    /// <param name="AArgs">Extra request members as a JSON object text.</param>
    /// <returns>The error code.</returns>
    function SendFail( const ACmd, AArgs: string ): string;
  private
    /// <summary>The first window the dialogs tests click in: a Count button and a Same button.</summary>
    FDlgA: TForm;
    /// <summary>The second dialogs window, with a Same button of its own, so that caption is ambiguous.</summary>
    FDlgB: TForm;
    /// <summary>A dialogs window that is DISABLED, as one with a modal on top is; its Blocked button is enabled in its own right.</summary>
    FDlgC: TForm;
    /// <summary>How often the Count button's OnClick ran.</summary>
    FCountClicks: Integer;
    /// <summary>How often FDlgA's Same button's OnClick ran.</summary>
    FSameAClicks: Integer;
    /// <summary>How often FDlgB's Same button's OnClick ran.</summary>
    FSameBClicks: Integer;
    /// <summary>How often the Blocked button's OnClick ran.</summary>
    FBlockedClicks: Integer;
    /// <summary>The panel the click_at tests click on.</summary>
    FClickPanel: TPanel;
    /// <summary>Where the last mouse-down on the panel landed, in its client coordinates.</summary>
    FMousePoint: TPoint;
    /// <summary>The shift state of the last mouse-down on the panel.</summary>
    FMouseShift: TShiftState;
    /// <summary>How often the panel's OnClick ran.</summary>
    FPanelClicks: Integer;
    /// <summary>The control the drop_files tests drop on; it accepts WM_DROPFILES.</summary>
    FDropZone: TWinControl;
    /// <summary>How often each of FDlgA's two Twin buttons ran, by index.</summary>
    FTwinClicks: array[ 0..1 ] of Integer;
    /// <summary>FDlgA's two Twin buttons, which share a caption in one window.</summary>
    FTwins: array[ 0..1 ] of TButton;
    /// <summary>How often the styled (non-BM_CLICK) button ran.</summary>
    FStyledClicks: Integer;
    /// <summary>A form shown modally by the backward-compatibility test; its OK button has ModalResult mrOk.</summary>
    FModal: TForm;
    /// <summary>What FModal's ShowModal returned.</summary>
    FModalResult: Integer;
    /// <summary>A window owned by FModalOwner, which is disabled, so it is modal as Windows shows modality.</summary>
    FDlgD: TForm;
    /// <summary>The disabled owner of FDlgD.</summary>
    FModalOwner: TForm;
    /// <summary>How often FDlgD's Same button ran.</summary>
    FSameDClicks: Integer;
    /// <summary>Counts a click of a Twin button; its Tag says which.</summary>
    /// <param name="Sender">The button.</param>
    procedure TwinClick( Sender: TObject );
    /// <summary>Counts a click of the styled button.</summary>
    /// <param name="Sender">The button.</param>
    procedure StyledClick( Sender: TObject );
    /// <summary>A handler that takes 2.5 s and then hides its window, as a slow OK does.</summary>
    /// <param name="Sender">The button.</param>
    procedure SlowClick( Sender: TObject );
    /// <summary>Opens a modal form on top of FDlgA that closes itself after 2.5 s.</summary>
    /// <param name="Sender">The button.</param>
    procedure NestClick( Sender: TObject );
    /// <summary>Closes the nested modal form its timer belongs to.</summary>
    /// <param name="Sender">The timer.</param>
    procedure NestTimer( Sender: TObject );
    /// <summary>Counts a click of FDlgD's Same button.</summary>
    /// <param name="Sender">The button.</param>
    procedure SameDClick( Sender: TObject );
    /// <summary>Counts a click of the Count button.</summary>
    /// <param name="Sender">The button.</param>
    procedure CountClick( Sender: TObject );
    /// <summary>Counts a click of FDlgA's Same button.</summary>
    /// <param name="Sender">The button.</param>
    procedure SameAClick( Sender: TObject );
    /// <summary>Counts a click of FDlgB's Same button.</summary>
    /// <param name="Sender">The button.</param>
    procedure SameBClick( Sender: TObject );
    /// <summary>Counts a click of the Blocked button.</summary>
    /// <param name="Sender">The button.</param>
    procedure BlockedClick( Sender: TObject );
    /// <summary>Records where a mouse-down on the click panel landed, and with which keys.</summary>
    /// <param name="Sender">The panel.</param>
    /// <param name="Button">The mouse button.</param>
    /// <param name="Shift">The keys and buttons held.</param>
    /// <param name="X">The point's horizontal position, in the panel's client coordinates.</param>
    /// <param name="Y">The point's vertical position, in the panel's client coordinates.</param>
    procedure PanelMouseDown( Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer );
    /// <summary>Counts a click of the click panel.</summary>
    /// <param name="Sender">The panel.</param>
    procedure PanelClick( Sender: TObject );
    /// <summary>
    ///   Shows the three dialogs windows, off-screen and non-modal, FDlgC disabled.  Only the dialogs tests build
    ///   them, so no other test meets their buttons.
    /// </summary>
    procedure BuildDialogs;
    /// <summary>Lets the main thread handle what is queued for the given time: a posted click or drop arrives after its reply.</summary>
    /// <param name="AMs">How long to pump, in milliseconds.</param>
    procedure Pump( AMs: Integer );
    /// <summary>A string as a JSON string literal, quotes and escapes included, for building a request.</summary>
    /// <param name="AText">The text.</param>
    /// <returns>The literal.</returns>
    function JsonText( const AText: string ): string;
    /// <summary>Builds the test form: two panels that each OWN an edit named edtTown, two unnamed buttons, a memo, a plain edit, and a host panel with the docked edit parented in.</summary>
    procedure BuildForm;
  public
    /// <summary>Registers the test commands, builds the test form, starts the server and reads the token.</summary>
    /// <exception cref="EAutoError">
    ///   Never from Setup itself: the <c>raise</c> in its body belongs to the <c>test_registered_fail</c> handler it
    ///   registers, which raises when a test sends that command.
    /// </exception>
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
    ///   where a screen capture shows only whatever is there, yet the PNG is the memo's own size, its
    ///   background is the active style's edit colour with the memo's text drawn on it (the text tells a
    ///   real render from a blank one), and its left border is the one the style draws, not the unstyled
    ///   sunken edge (the border tells a styled render from an unstyled one, since white and black are
    ///   the same either way).
    /// </summary>
    [Test] procedure Screenshot_OfAControl_RendersItself_EvenOffScreen;
    /// <summary>A non-windowed control (a TLabel) has no window to render, so it is cropped out of its parent's rendering - at its own size, in its own yellow.</summary>
    [Test] procedure Screenshot_OfANonWindowedControl_IsCroppedFromItsParent;
    /// <summary>maxWidth scales the image down proportionally, and the reply gives the source size so the caller knows it was scaled.</summary>
    [Test] procedure Screenshot_MaxWidth_ScalesProportionally;
    /// <summary>
    ///   A whole-form render includes its child windows: the memo's styled edit colour, with its text on
    ///   it and the style's border round it, is found where the memo sits in the form's window, and that
    ///   colour differs from the styled form behind it. The VCL's PaintTo, the fallback, drew only the
    ///   first child of a form, so this is what tells the DWM path (frame and every child) from a degraded one.
    /// </summary>
    [Test] procedure Screenshot_OfAForm_IncludesItsChildren;
    /// <summary>
    ///   A dialog button is clicked ONCE.  The click used to be sent as BM_CLICK and then, because the button's window
    ///   still existed straight afterwards (it always does: a modal form is torn down only when its loop unwinds), sent
    ///   again as a mouse click, so a button that does not close its window ran its handler twice.  The reply now says
    ///   what became of the click: this window stays up and enabled, so <c>unchanged</c>.
    /// </summary>
    [Test] procedure Dialogs_Click_IsDeliveredOnce;
    /// <summary>A caption that matches buttons in two windows is refused as AmbiguousButton, and neither is clicked; it used to click the first found.</summary>
    [Test] procedure Dialogs_AmbiguousCaption_IsRefused;
    /// <summary><c>hwnd</c> narrows the search to one window, which settles an ambiguous caption: only that window's button runs.</summary>
    [Test] procedure Dialogs_Hwnd_NarrowsTheSearch;
    /// <summary>
    ///   A button that is enabled in its own right but sits in a DISABLED window (what a window with a modal on top
    ///   is) is refused as NotClickable and not clicked.  Only the button itself used to be checked, so BM_CLICK ran a
    ///   handler a user could not have reached.
    /// </summary>
    [Test] procedure Dialogs_ButtonInDisabledWindow_IsNotClicked;
    /// <summary>The listing gives every button its handle and whether it could be clicked, judged up the window chain, and every window whether it is modal.</summary>
    [Test] procedure Dialogs_List_SaysWhichButtonsCanBeClicked;
    /// <summary>click_at delivers a real mouse click at a point in the control's client coordinates, with the shift keys asked for and no others.</summary>
    [Test] procedure ClickAt_ClicksAtThePoint_WithTheKeysAskedFor;
    /// <summary>A point outside the control's client area is refused as OutsideControl, and nothing is clicked.</summary>
    [Test] procedure ClickAt_OutsideTheControl_IsRefused;
    /// <summary>drop_files hands the control WM_DROPFILES carrying every file, in order, and the drop point in its client coordinates.</summary>
    [Test] procedure DropFiles_DeliversTheFilesAndThePoint;
    /// <summary>A control with no window up its chain that accepts files is refused as NoDropTarget: Explorer could not drop on it either.</summary>
    [Test] procedure DropFiles_WithNoDropTarget_IsRefused;
    /// <summary>A file that does not exist is refused as NoFile before anything is dropped: Explorer drops only files that exist.</summary>
    [Test] procedure DropFiles_MissingFile_IsRefused;
    /// <summary>
    ///   TAutomationServer.RenderControl, called from a registered worker-thread command, renders the control its
    ///   resolver returns, at that control's size: what the IDE's designer screenshot relies on to reach a form the
    ///   built-in addressing cannot name.
    /// </summary>
    [Test] procedure RenderControl_RendersWhatTheResolverFinds;
    /// <summary>
    ///   Two buttons of one caption in ONE window could never be clicked: the caption was ambiguous and <c>hwnd</c> names
    ///   only the window.  <c>buttonHwnd</c>, which the listing reports, clicks exactly that button and no other.
    /// </summary>
    [Test] procedure Dialogs_ButtonHwnd_ClicksOneOfTwoTwins;
    /// <summary>
    ///   The outcome is judged once the click has been HANDLED, not from when it was posted: an OK whose handler takes
    ///   2.5 s before it closes the window answers <c>gone</c>.  Judged from the post, it answered <c>unchanged</c> while
    ///   the handler was still running, and a caller that retried clicked twice.
    /// </summary>
    [Test] procedure Dialogs_SlowHandler_IsJudgedAfterItRan;
    /// <summary>A click whose handler has not run within <c>wait</c> answers <c>pending</c>, never <c>unchanged</c>, and says the click is still queued.</summary>
    [Test] procedure Dialogs_HandlerNotRunYet_IsPending;
    /// <summary>
    ///   When several windows have a clickable button of the caption, the one in a MODAL window is clicked: a message
    ///   box disables only its owner, so an OK on another open window is clickable too, and refusing would break a
    ///   script the old code served.  Only several modal matches are refused.
    /// </summary>
    [Test] procedure Dialogs_SeveralMatches_ThePromptWins;
    /// <summary>The main backward-compatibility case: OK on a VCL ShowModal dialog closes it, and the reply says <c>gone</c> and <c>dismissed:true</c>.</summary>
    [Test] procedure Dialogs_ShowModalOk_IsGone;
    /// <summary>A click that opens a modal on top of its window answers <c>covered</c>.</summary>
    [Test] procedure Dialogs_ClickOpeningAModal_IsCovered;
    /// <summary>
    ///   A custom-drawn button that keeps "button" in its class name but is not built on the system Button class is
    ///   clicked through the mouse messages, once, and the reply says <c>method:"mouse"</c>; a TButton says
    ///   <c>bmClick</c>, so sending one down the mouse path is seen.
    /// </summary>
    [Test] procedure Dialogs_StyledButton_TakesTheMousePath;
    /// <summary><c>modalOnly</c> lists only windows waiting for an answer, so the plain non-modal test windows are left out.</summary>
    [Test] procedure Dialogs_ModalOnly_LeavesOutPlainWindows;
    /// <summary>A window's static texts are listed, a VCL TStaticText included: it is built on the system Static class under a class name of its own.</summary>
    [Test] procedure Dialogs_List_ReadsStaticTexts;
    /// <summary><c>mainThreadBusy</c> is true while the main thread is not answering, false when it is.</summary>
    [Test] procedure Dialogs_MainThreadBusy_SaysSo;
    /// <summary>An <c>hwnd</c> that is no window, a child window, or another process's window is NoWindow; one that is not a number is BadRequest.</summary>
    [Test] procedure Dialogs_BadHwnd_IsRefused;
    /// <summary>A path with non-ASCII characters arrives intact: the drop block is UTF-16.</summary>
    [Test] procedure DropFiles_NonAsciiPath_ArrivesIntact;
    /// <summary>
    ///   A second registration of a name already registered is refused, and the first still answers.  It used to replace
    ///   the first silently, and the first provider's UnregisterCommand then removed the second's command.
    /// </summary>
    [Test] procedure RegisterCommand_RefusesASecondProvider;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.Diagnostics, System.Generics.Collections,
  Winapi.Windows, Winapi.Messages, Winapi.ShellAPI,
  Vcl.Graphics, Vcl.Themes,
  IdTCPClient, IdGlobal,
  GllDUnitX.Station,
  gllAutomationServer, gllAutomationServer.Client;

const
  /// <summary>Where the server advertises itself: the one definition, in the client unit.</summary>
  DISCOVERY_DIR   = AUTOMATION_DISCOVERY_DIR;
  /// <summary>How long one request may take before the test gives up on it.</summary>
  REQUEST_TIMEOUT = 10000;
  /// <summary>Name the test process registers under.</summary>
  APP_NAME        = 'gllAutomationServerTests';
  /// <summary>The wire-protocol version ping must report.</summary>
  PROTOCOL_VERSION = '0.14';
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

type
  /// <summary>A control that accepts dropped files and records the last drop, as an application's drop target does.</summary>
  TDropZone = class( TCustomControl )
  protected
    /// <summary>Registers the window for WM_DROPFILES, which is what makes the shell, and drop_files, deliver to it.</summary>
    procedure CreateWnd; override;
    /// <summary>Reads the dropped files and the drop point, then releases the drop handle.</summary>
    /// <param name="AMsg">The message.</param>
    procedure WMDropFiles( var AMsg: TWMDropFiles ); message WM_DROPFILES;
  public
    /// <summary>The files of the last drop, in order.</summary>
    Files: TArray<string>;
    /// <summary>The point of the last drop, in client coordinates.</summary>
    DropPoint: TPoint;
  end;

type
  /// <summary>A custom-drawn button, like Ethea's TStyledButton: "button" in its class name, not built on the system Button class, so BM_CLICK does nothing to it.</summary>
  TFakeStyledButton = class( TCustomControl )
  protected
    /// <summary>Draws a frame and the caption, so it is visible as a button would be.</summary>
    procedure Paint; override;
  end;

procedure TFakeStyledButton.Paint;
begin

  Canvas.Rectangle( ClientRect );
  Canvas.TextOut( 4, 4, Caption );

end;

procedure TDropZone.CreateWnd;
begin

  inherited;
  DragAcceptFiles( Handle, True );

end;

procedure TDropZone.WMDropFiles( var AMsg: TWMDropFiles );
begin

  try
    var iCount := DragQueryFile( AMsg.Drop, $FFFFFFFF, nil, 0 );
    SetLength( Files, iCount );
    for var iFile := 0 to Integer( iCount ) - 1 do
    begin
      var sName := '';
      SetLength( sName, DragQueryFile( AMsg.Drop, iFile, nil, 0 ) );
      DragQueryFile( AMsg.Drop, iFile, PChar( sName ), Length( sName ) + 1 );
      Files[ iFile ] := sName;
    end;
    DragQueryPoint( AMsg.Drop, DropPoint );
  finally
    DragFinish( AMsg.Drop );
  end;
  AMsg.Result := 0;

end;

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
  // No Color: the suite runs under the Aqua Light Slate style, which paints the memo's client in its own edit
  // colour.  The screenshot tests assert that styled colour, and the memo's text, rather than a colour of ours.

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

  FClickPanel := TPanel.Create( FForm );
  FClickPanel.Name := 'pnlClick';
  FClickPanel.Parent := FForm;
  FClickPanel.SetBounds( 10, 300, 120, 60 );
  FClickPanel.OnMouseDown := PanelMouseDown;
  FClickPanel.OnClick := PanelClick;

  FDropZone := TDropZone.Create( FForm );
  FDropZone.Name := 'dropZone';
  FDropZone.Parent := FForm;
  FDropZone.SetBounds( 200, 300, 100, 60 );

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

  // DUnitX keeps one fixture instance for every test, so what a test counts starts again here.
  FCountClicks := 0;
  FSameAClicks := 0;
  FSameBClicks := 0;
  FBlockedClicks := 0;
  FPanelClicks := 0;
  FTwinClicks[ 0 ] := 0;
  FTwinClicks[ 1 ] := 0;
  FStyledClicks := 0;
  FSameDClicks := 0;
  FModalResult := 0;
  FMousePoint := Point( -1, -1 );
  FMouseShift := [];

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
  FreeAndNil( FDlgA );
  FreeAndNil( FDlgB );
  FreeAndNil( FDlgC );
  FreeAndNil( FDlgD );
  FreeAndNil( FModalOwner );
  FreeAndNil( FModal );
  FreeAndNil( FForm ); // owns FLabel, FMemo, FClickPanel and FDropZone

end;

function TTestGllAutomationServer.Send( const ACmd, AArgs: string ): TJSONObject;
begin

  Result := SendDelayed( ACmd, AArgs, 0 );

end;

function TTestGllAutomationServer.SendDelayed( const ACmd, AArgs: string; ADelayMs: Integer ): TJSONObject;
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

  var sReply := SendLine( sLine, ADelayMs );
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

function TTestGllAutomationServer.SendLine( const ALine: string; ADelayMs: Integer ): string;
begin

  var iPort := TAutomationServer.Port;
  var sReply := '';
  var sFailure := '';
  var bDone := False;

  var oThread := TThread.CreateAnonymousThread(
    procedure
    begin
      if ADelayMs > 0 then
        Sleep( ADelayMs );
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

function TTestGllAutomationServer.Shoot( const AArgs: string; out APng: TPngImage ): TJSONObject;
begin

  { On a non-interactive window station ( GITLAKMCP's test_run starts suites from its service ) no window is
    painted, so PrintWindow renders blank white - measured 2026-10-13: 22/22 from a desktop session, the render
    tests white under test_run.  The shared guard ignores the test there instead of failing for the environment. }
  RequireInteractiveStation( 'a painted window for PrintWindow to capture' );
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

/// <summary>
///   The colour the active VCL style paints an edit's client in, after asserting that the suite's style is the
///   active one: the premise of every memo colour check below.
/// </summary>
/// <returns>The active style's <c>scEdit</c> colour.</returns>
function StyledEditColour: TColor;
begin

  Assert.AreEqual( 'Aqua Light Slate', TStyleManager.ActiveStyle.Name, False, 'the runner activates the suite''s VCL style' );
  Result := TStyleManager.ActiveStyle.GetStyleColor( scEdit );

end;

/// <summary>
///   Counts the pixels in a rectangle of a PNG that stand well clear of a background colour - ink, such as text,
///   drawn on it.  A blank render has none.
/// </summary>
/// <param name="APng">The image read.</param>
/// <param name="ARect">The area to scan, in the image's coordinates.</param>
/// <param name="ABackground">The background the ink is measured against.</param>
/// <returns>The number of pixels whose summed channel distance from the background exceeds 192.</returns>
function InkPixels( APng: TPngImage; const ARect: TRect; ABackground: TColor ): Integer;
begin

  Result := 0;
  var c := ColorToRGB( ABackground );
  for var iY := ARect.Top to ARect.Bottom - 1 do
    for var iX := ARect.Left to ARect.Right - 1 do
    begin
      var p := ColorToRGB( APng.Pixels[ iX, iY ] );
      if ( Abs( GetRValue( p ) - GetRValue( c ) ) + Abs( GetGValue( p ) - GetGValue( c ) ) +
        Abs( GetBValue( p ) - GetBValue( c ) ) ) > 192 then
        Inc( Result );
    end;

end;

/// <summary>
///   The colour the active style paints at one pixel of an edit border (<c>teEditBorderNoScrollNormal</c>, an
///   unfocused memo with no scroll bars) drawn over a control of the given size: what its style hook draws.
/// </summary>
/// <param name="AWidth">The control's width.</param>
/// <param name="AHeight">The control's height.</param>
/// <param name="AX">The column read.</param>
/// <param name="AY">The row read.</param>
/// <returns>The colour of that pixel of the border.</returns>
function StyledEditBorderPixel( AWidth, AHeight, AX, AY: Integer ): TColor;
begin

  var oStyle := TStyleManager.ActiveStyle;
  var oBitmap := TBitmap.Create;
  try
    oBitmap.PixelFormat := pf32bit;
    oBitmap.SetSize( AWidth, AHeight );
    oBitmap.Canvas.Brush.Color := clFuchsia; // anything the border does not draw stays visibly not a border
    oBitmap.Canvas.FillRect( Rect( 0, 0, AWidth, AHeight ) );
    oStyle.DrawElement( oBitmap.Canvas.Handle, oStyle.GetElementDetails( teEditBorderNoScrollNormal ), Rect( 0, 0, AWidth, AHeight ) );
    Result := oBitmap.Canvas.Pixels[ AX, AY ];
  finally
    oBitmap.Free;
  end;

end;

/// <summary>
///   Asserts that the memo's left border, in a render, is the border the ACTIVE style draws and not the unstyled
///   sunken edge (<c>clBtnShadow</c> from the system, <c>$A0A0A0</c> here).  The style's edit colour and the text are
///   the same with and without the style (white, black), so this is the check only a styled render passes: the
///   style hook paints the border.  Mutation-proved 2026-10-23: with the memo's <c>StyleElements</c> emptied, the
///   render shows <c>$A0A0A0</c> and both screenshot tests fail here.
/// </summary>
/// <param name="APng">The render.</param>
/// <param name="ALeft">The memo's left edge in the render.</param>
/// <param name="ATop">The memo's top edge in the render.</param>
/// <param name="AWidth">The memo's width.</param>
/// <param name="AHeight">The memo's height.</param>
/// <param name="AContext">Appended to a failure message.</param>
/// <exception cref="ETestFailure">The styled and system borders cannot be told apart, or the render shows the wrong one.</exception>
procedure AssertStyledEditBorder( APng: TPngImage; ALeft, ATop, AWidth, AHeight: Integer; const AContext: string );
begin

  var cStyled := StyledEditBorderPixel( AWidth, AHeight, 0, AHeight div 2 );
  var cUnstyled := ColorToRGB( clBtnShadow ); // Vcl.Graphics.ColorToRGB asks GetSysColor, never the style
  Assert.IsFalse( NearColor( cStyled, cUnstyled ), Format( 'precondition: the styled edit border ($%.6x) differs from the unstyled edge ($%.6x)',
    [ ColorToRGB( cStyled ), cUnstyled ] ) );
  var cPixel := APng.Pixels[ ALeft, ATop + AHeight div 2 ];
  Assert.IsTrue( NearColor( cPixel, cStyled ), Format( 'expected the memo''s styled left border $%.6x, got $%.6x (unstyled it is $%.6x): %s',
    [ ColorToRGB( cStyled ), ColorToRGB( cPixel ), cUnstyled, AContext ] ) );

end;

procedure TTestGllAutomationServer.Screenshot_OfAControl_RendersItself_EvenOffScreen;
begin

  var oPng: TPngImage;
  var oReply := Shoot( Format( '{"form":"%s","name":"Memo1"}', [ FORM_NAME ] ), oPng );
  try
    Assert.AreEqual( 'control', oReply.GetValue<string>( 'result.area' ), False );
    Assert.AreEqual( FMemo.Width, oPng.Width, 'width' );
    Assert.AreEqual( FMemo.Height, oPng.Height, 'height' );
    // Bottom-right, inside the border, below any text: the memo's own background, in the style's edit colour.
    var cEdit := StyledEditColour;
    var cPixel := oPng.Pixels[ oPng.Width - 8, oPng.Height - 8 ];
    Assert.IsTrue( NearColor( cPixel, cEdit ), Format( 'expected the memo''s styled edit colour $%.6x, got $%.6x: %s',
      [ ColorToRGB( cEdit ), ColorToRGB( cPixel ), oReply.ToJSON ] ) );
    // The style's edit colour is white, which a blank render is too, so the text on it is the proof of a real render.
    Assert.IsTrue( InkPixels( oPng, Rect( 4, 2, oPng.Width - 20, oPng.Height div 2 ), cEdit ) > 0,
      'expected the memo''s text in the render, found none: ' + oReply.ToJSON );
    // White and black look the same unstyled: the border is what only the styled render shows.
    AssertStyledEditBorder( oPng, 0, 0, FMemo.Width, FMemo.Height, oReply.ToJSON );
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
    Assert.AreEqual<Int64>( Round( FMemo.Height * 75 / FMemo.Width ), oPng.Height, 'height' );
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
    var cEdit := StyledEditColour;
    var cPixel := oPng.Pixels[ rcMemo.Right - rcForm.Left - 8, rcMemo.Bottom - rcForm.Top - 8 ];
    Assert.IsTrue( NearColor( cPixel, cEdit ), Format( 'expected the memo''s styled edit colour $%.6x inside the form, got $%.6x: %s',
      [ ColorToRGB( cEdit ), ColorToRGB( cPixel ), oReply.ToJSON ] ) );
    // Bare form just left of the memo (the panels and buttons stop at x = 185): it must NOT be the edit colour, or
    // finding that colour at the memo's place would not show that the memo was drawn.
    var ptBare := FForm.ClientToScreen( Point( 195, 50 ) );
    var cBare := oPng.Pixels[ ptBare.X - rcForm.Left, ptBare.Y - rcForm.Top ];
    Assert.IsFalse( NearColor( cBare, cEdit ), Format( 'the styled form behind the memo is the edit colour too ($%.6x)', [ ColorToRGB( cBare ) ] ) );
    Assert.IsTrue( InkPixels( oPng, Rect( rcMemo.Left - rcForm.Left + 4, rcMemo.Top - rcForm.Top + 2, rcMemo.Right - rcForm.Left - 20,
      rcMemo.Top - rcForm.Top + rcMemo.Height div 2 ), cEdit ) > 0, 'expected the memo''s text inside the form, found none: ' + oReply.ToJSON );
    AssertStyledEditBorder( oPng, rcMemo.Left - rcForm.Left, rcMemo.Top - rcForm.Top, rcMemo.Width, rcMemo.Height, oReply.ToJSON );
  finally
    oPng.Free;
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.CountClick( Sender: TObject );
begin

  Inc( FCountClicks );

end;

procedure TTestGllAutomationServer.SameAClick( Sender: TObject );
begin

  Inc( FSameAClicks );

end;

procedure TTestGllAutomationServer.SameBClick( Sender: TObject );
begin

  Inc( FSameBClicks );

end;

procedure TTestGllAutomationServer.BlockedClick( Sender: TObject );
begin

  Inc( FBlockedClicks );

end;

procedure TTestGllAutomationServer.PanelMouseDown( Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer );
begin

  FMousePoint := Point( X, Y );
  FMouseShift := Shift;

end;

procedure TTestGllAutomationServer.PanelClick( Sender: TObject );
begin

  Inc( FPanelClicks );

end;

procedure TTestGllAutomationServer.TwinClick( Sender: TObject );
begin

  Inc( FTwinClicks[ TComponent( Sender ).Tag ] );

end;

procedure TTestGllAutomationServer.StyledClick( Sender: TObject );
begin

  Inc( FStyledClicks );

end;

procedure TTestGllAutomationServer.SlowClick( Sender: TObject );
begin

  Sleep( 2500 );
  FDlgA.Hide;

end;

procedure TTestGllAutomationServer.NestClick( Sender: TObject );
begin

  var oNested := TForm.CreateNew( nil );
  try
    oNested.Caption := 'Nested';
    oNested.SetBounds( -2400, -2900, 200, 100 );
    var oTimer := TTimer.Create( oNested );
    oTimer.Interval := 2500;
    oTimer.OnTimer := NestTimer;
    oNested.ShowModal;
  finally
    oNested.Free;
  end;

end;

procedure TTestGllAutomationServer.NestTimer( Sender: TObject );
begin

  TTimer( Sender ).Enabled := False;
  TForm( TComponent( Sender ).Owner ).ModalResult := mrCancel;

end;

procedure TTestGllAutomationServer.SameDClick( Sender: TObject );
begin

  Inc( FSameDClicks );

end;

procedure TTestGllAutomationServer.BuildDialogs;

  function NewWindow( const AName: string; ALeft: Integer ): TForm;
  begin

    Result := TForm.CreateNew( nil );
    Result.Name := AName;
    Result.Caption := AName;
    Result.SetBounds( ALeft, -3000, 300, 200 );

  end;

  procedure AddButton( AForm: TForm; const ACaption: string; ATop: Integer; const AOnClick: TNotifyEvent );
  begin

    var oButton := TButton.Create( AForm );
    oButton.Parent := AForm;
    oButton.Caption := ACaption;
    oButton.SetBounds( 10, ATop, 90, 25 );
    oButton.OnClick := AOnClick;

  end;

begin

  FDlgA := NewWindow( 'DlgA', -2500 );
  FDlgA.SetBounds( -2500, -3000, 300, 300 );
  AddButton( FDlgA, '&Count', 10, CountClick );
  AddButton( FDlgA, 'Same', 50, SameAClick );
  for var iTwin := 0 to 1 do
  begin
    FTwins[ iTwin ] := TButton.Create( FDlgA );
    FTwins[ iTwin ].Parent := FDlgA;
    FTwins[ iTwin ].Caption := 'Twin';
    FTwins[ iTwin ].Tag := iTwin;
    FTwins[ iTwin ].SetBounds( 110, 10 + 40 * iTwin, 90, 25 );
    FTwins[ iTwin ].OnClick := TwinClick;
  end;
  AddButton( FDlgA, 'Slow', 90, SlowClick );
  AddButton( FDlgA, 'Nest', 130, NestClick );
  var oStyled := TFakeStyledButton.Create( FDlgA );
  oStyled.Parent := FDlgA;
  oStyled.SetBounds( 110, 90, 90, 25 );
  oStyled.Caption := 'Styled';
  oStyled.OnClick := StyledClick;
  var oText := TStaticText.Create( FDlgA );
  oText.Parent := FDlgA;
  oText.SetBounds( 10, 170, 200, 20 );
  oText.Caption := 'Hello there';
  FDlgA.Show;

  FDlgB := NewWindow( 'DlgB', -2100 );
  AddButton( FDlgB, 'Same', 10, SameBClick );
  FDlgB.Show;

  FDlgC := NewWindow( 'DlgC', -1700 );
  AddButton( FDlgC, 'Blocked', 10, BlockedClick );
  FDlgC.Show;
  EnableWindow( FDlgC.Handle, False );

end;

procedure TTestGllAutomationServer.Pump( AMs: Integer );
begin

  var rWatch := TStopwatch.StartNew;
  while rWatch.ElapsedMilliseconds < AMs do
  begin
    CheckSynchronize( 5 );
    Application.ProcessMessages;
  end;

end;

function TTestGllAutomationServer.JsonText( const AText: string ): string;
begin

  var oText := TJSONString.Create( AText );
  try
    Result := oText.ToJSON;
  finally
    oText.Free;
  end;

end;

procedure TTestGllAutomationServer.Dialogs_Click_IsDeliveredOnce;
begin

  BuildDialogs;
  var oReply := Send( 'dialogs', '{"button":"Count"}' );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Pump( 300 );
    Assert.AreEqual( 1, FCountClicks, 'the Count button''s handler ran this often for one click: ' + oReply.ToJSON );
    Assert.AreEqual( 'unchanged', oReply.GetValue<string>( 'result.outcome', '' ), oReply.ToJSON );
    Assert.IsFalse( oReply.GetValue<Boolean>( 'result.dismissed' ), oReply.ToJSON );
    Assert.AreEqual( 'bmClick', oReply.GetValue<string>( 'result.method', '' ), 'a TButton takes BM_CLICK: ' + oReply.ToJSON );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Dialogs_AmbiguousCaption_IsRefused;
begin

  BuildDialogs;
  Assert.AreEqual( 'AmbiguousButton', SendFail( 'dialogs', '{"button":"Same"}' ) );
  Pump( 300 );
  Assert.AreEqual( 0, FSameAClicks + FSameBClicks, 'a Same button was clicked although the caption is ambiguous' );

end;

procedure TTestGllAutomationServer.Dialogs_Hwnd_NarrowsTheSearch;
begin

  BuildDialogs;
  var oReply := Send( 'dialogs', Format( '{"button":"Same","hwnd":%d}', [ IntPtr( FDlgB.Handle ) ] ) );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Pump( 300 );
    Assert.AreEqual( 1, FSameBClicks, 'DlgB''s Same button: ' + oReply.ToJSON );
    Assert.AreEqual( 0, FSameAClicks, 'DlgA''s Same button was clicked although hwnd named DlgB' );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Dialogs_ButtonInDisabledWindow_IsNotClicked;
begin

  BuildDialogs;
  Assert.AreEqual( 'NotClickable', SendFail( 'dialogs', '{"button":"Blocked"}' ) );
  Pump( 300 );
  Assert.AreEqual( 0, FBlockedClicks, 'the button in the disabled window was clicked' );

end;

procedure TTestGllAutomationServer.Dialogs_List_SaysWhichButtonsCanBeClicked;
begin

  BuildDialogs;
  var oReply := Send( 'dialogs' );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    var bFoundA := False;
    var bFoundC := False;
    for var oWindow in oReply.GetValue<TJSONArray>( 'result.windows' ) do
    begin
      var iWindow := oWindow.GetValue<Int64>( 'hwnd' );
      Assert.IsNotNull( oWindow.FindValue( 'modal' ), 'a window without "modal": ' + oWindow.ToJSON );
      for var oButton in oWindow.GetValue<TJSONArray>( 'buttons' ) do
      begin
        Assert.IsTrue( oButton.GetValue<Int64>( 'hwnd', 0 ) <> 0, 'a button without its handle: ' + oButton.ToJSON );
        if iWindow = IntPtr( FDlgC.Handle ) then
        begin
          bFoundC := True;
          Assert.IsFalse( oButton.GetValue<Boolean>( 'clickable', True ), 'the button in the disabled window: ' + oButton.ToJSON );
          Assert.IsTrue( oButton.GetValue<Boolean>( 'enabled' ), 'the button itself is enabled: ' + oButton.ToJSON );
        end
        else if iWindow = IntPtr( FDlgA.Handle ) then
        begin
          bFoundA := True;
          Assert.IsTrue( oButton.GetValue<Boolean>( 'clickable', False ), 'a button in an enabled window: ' + oButton.ToJSON );
        end;
      end;
    end;
    Assert.IsTrue( bFoundA and bFoundC, 'DlgA or DlgC is missing from the list: ' + oReply.ToJSON );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.ClickAt_ClicksAtThePoint_WithTheKeysAskedFor;
begin

  var oReply := Send( 'click_at', Format( '{"form":"%s","name":"pnlClick","x":15,"y":20,"shift":"Shift"}', [ FORM_NAME ] ) );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Pump( 300 );
    Assert.AreEqual( 1, FPanelClicks, 'the panel''s OnClick: ' + oReply.ToJSON );
    Assert.AreEqual( 15, FMousePoint.X, 'x' );
    Assert.AreEqual( 20, FMousePoint.Y, 'y' );
    Assert.IsTrue( ssShift in FMouseShift, 'Shift was asked for' );
    Assert.IsFalse( ssCtrl in FMouseShift, 'Ctrl was not asked for' );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.ClickAt_OutsideTheControl_IsRefused;
begin

  Assert.AreEqual( 'OutsideControl', SendFail( 'click_at', Format( '{"form":"%s","name":"pnlClick","x":500,"y":20}', [ FORM_NAME ] ) ) );
  Pump( 200 );
  Assert.AreEqual( 0, FPanelClicks, 'a click outside the panel reached it' );

end;

procedure TTestGllAutomationServer.DropFiles_DeliversTheFilesAndThePoint;
begin

  var sFirst := TPath.Combine( TPath.GetTempPath, 'gllAutoDrop one.txt' );
  var sSecond := TPath.Combine( TPath.GetTempPath, 'gllAutoDrop-two.txt' );
  TFile.WriteAllText( sFirst, '1' );
  TFile.WriteAllText( sSecond, '2' );
  try
    var oReply := Send( 'drop_files', Format( '{"form":"%s","name":"dropZone","files":[%s,%s],"x":5,"y":6}',
      [ FORM_NAME, JsonText( sFirst ), JsonText( sSecond ) ] ) );
    try
      Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
      Pump( 300 );
      var oZone := TDropZone( FDropZone );
      Assert.AreEqual( 2, Length( oZone.Files ), 'files dropped: ' + oReply.ToJSON );
      Assert.AreEqual( sFirst, oZone.Files[ 0 ] );
      Assert.AreEqual( sSecond, oZone.Files[ 1 ] );
      Assert.AreEqual( 5, oZone.DropPoint.X, 'x' );
      Assert.AreEqual( 6, oZone.DropPoint.Y, 'y' );
    finally
      oReply.Free;
    end;
  finally
    TFile.Delete( sFirst );
    TFile.Delete( sSecond );
  end;

end;

procedure TTestGllAutomationServer.DropFiles_WithNoDropTarget_IsRefused;
begin

  var sFile := TPath.Combine( TPath.GetTempPath, 'gllAutoDrop-none.txt' );
  TFile.WriteAllText( sFile, '1' );
  try
    Assert.AreEqual( 'NoDropTarget', SendFail( 'drop_files', Format( '{"form":"%s","name":"edtType","files":[%s]}',
      [ FORM_NAME, JsonText( sFile ) ] ) ) );
  finally
    TFile.Delete( sFile );
  end;

end;

procedure TTestGllAutomationServer.DropFiles_MissingFile_IsRefused;
begin

  var sFile := TPath.Combine( TPath.GetTempPath, Format( 'gllAutoDrop-missing-%u.txt', [ GetTickCount64 ] ) );
  Assert.AreEqual( 'NoFile', SendFail( 'drop_files', Format( '{"form":"%s","name":"dropZone","files":[%s]}',
    [ FORM_NAME, JsonText( sFile ) ] ) ) );
  Pump( 200 );
  Assert.AreEqual( 0, Integer( Length( TDropZone( FDropZone ).Files ) ), 'something was dropped' );

end;

procedure TTestGllAutomationServer.RenderControl_RendersWhatTheResolverFinds;
begin

  var oMemo := FMemo;
  TAutomationServer.RegisterCommand( 'test_render',
    function( ARequest: TJSONObject ): TJSONValue
    begin
      Result := TAutomationServer.RenderControl(
        function: TControl
        begin
          Result := oMemo;
        end, 0, APP_NAME );
    end, actWorkerThread );
  try
    var oReply := Send( 'test_render' );
    try
      Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
      var sPath := oReply.GetValue<string>( 'result.path' );
      try
        Assert.AreEqual( 'Memo1', oReply.GetValue<string>( 'result.target' ), oReply.ToJSON );
        Assert.AreEqual( 'control', oReply.GetValue<string>( 'result.area' ), oReply.ToJSON );
        var rcMemo: TRect;
        GetWindowRect( FMemo.Handle, rcMemo );
        Assert.AreEqual( rcMemo.Width, oReply.GetValue<Integer>( 'result.width' ), 'width: ' + oReply.ToJSON );
        Assert.AreEqual( rcMemo.Height, oReply.GetValue<Integer>( 'result.height' ), 'height: ' + oReply.ToJSON );
        Assert.IsTrue( TFile.Exists( sPath ), 'no PNG at ' + sPath );
      finally
        if TFile.Exists( sPath ) then
          TFile.Delete( sPath );
      end;
    finally
      oReply.Free;
    end;
  finally
    TAutomationServer.UnregisterCommand( 'test_render' );
  end;

end;

procedure TTestGllAutomationServer.Dialogs_ButtonHwnd_ClicksOneOfTwoTwins;
begin

  BuildDialogs;
  Assert.AreEqual( 'AmbiguousButton', SendFail( 'dialogs', Format( '{"button":"Twin","hwnd":%d}', [ IntPtr( FDlgA.Handle ) ] ) ),
    'two Twins in one window: hwnd cannot settle it' );
  var oReply := Send( 'dialogs', Format( '{"buttonHwnd":%d}', [ IntPtr( FTwins[ 1 ].Handle ) ] ) );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Pump( 300 );
    Assert.AreEqual( 1, FTwinClicks[ 1 ], 'the Twin named: ' + oReply.ToJSON );
    Assert.AreEqual( 0, FTwinClicks[ 0 ], 'the other Twin was clicked' );
    Assert.AreEqual<Int64>( IntPtr( FTwins[ 1 ].Handle ), oReply.GetValue<Int64>( 'result.buttonHwnd' ) );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Dialogs_SlowHandler_IsJudgedAfterItRan;
begin

  BuildDialogs;
  var oReply := Send( 'dialogs', '{"button":"Slow"}' );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'gone', oReply.GetValue<string>( 'result.outcome', '' ), oReply.ToJSON );
    Assert.IsTrue( oReply.GetValue<Boolean>( 'result.dismissed' ), oReply.ToJSON );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Dialogs_HandlerNotRunYet_IsPending;
begin

  BuildDialogs;
  var oReply := Send( 'dialogs', '{"button":"Slow","wait":200}' );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'pending', oReply.GetValue<string>( 'result.outcome', '' ), oReply.ToJSON );
    Assert.IsFalse( oReply.GetValue<Boolean>( 'result.dismissed' ), oReply.ToJSON );
  finally
    oReply.Free;
  end;
  Pump( 3200 );

end;

procedure TTestGllAutomationServer.Dialogs_SeveralMatches_ThePromptWins;
begin

  BuildDialogs;
  FModalOwner := TForm.CreateNew( nil );
  FModalOwner.Name := 'DlgOwner';
  FModalOwner.SetBounds( -1300, -3000, 200, 100 );
  FModalOwner.Show;
  FDlgD := TForm.CreateNew( nil );
  FDlgD.Name := 'DlgD';
  FDlgD.Caption := 'DlgD';
  FDlgD.PopupMode := pmExplicit;
  FDlgD.PopupParent := FModalOwner;
  FDlgD.SetBounds( -1000, -3000, 200, 100 );
  var oSame := TButton.Create( FDlgD );
  oSame.Parent := FDlgD;
  oSame.Caption := 'Same';
  oSame.OnClick := SameDClick;
  FDlgD.Show;
  EnableWindow( FModalOwner.Handle, False );

  var oReply := Send( 'dialogs', '{"button":"Same"}' );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Pump( 300 );
    Assert.AreEqual( 1, FSameDClicks, 'the Same in the modal window: ' + oReply.ToJSON );
    Assert.AreEqual( 0, FSameAClicks + FSameBClicks, 'a Same in a plain window was clicked' );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Dialogs_ShowModalOk_IsGone;
begin

  FModal := TForm.CreateNew( nil );
  FModal.Name := 'DlgModal';
  FModal.Caption := 'DlgModal';
  FModal.SetBounds( -2000, -2500, 250, 120 );
  var oOk := TButton.Create( FModal );
  oOk.Parent := FModal;
  oOk.Caption := 'ModalOK';
  oOk.ModalResult := mrOk;
  TThread.ForceQueue( nil,
    procedure
    begin
      FModalResult := FModal.ShowModal;
    end );

  var oReply := SendDelayed( 'dialogs', '{"button":"ModalOK"}', 500 );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'gone', oReply.GetValue<string>( 'result.outcome', '' ), oReply.ToJSON );
    Assert.IsTrue( oReply.GetValue<Boolean>( 'result.dismissed' ), oReply.ToJSON );
    Assert.AreEqual( Integer( mrOk ), FModalResult, 'ShowModal''s result' );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Dialogs_ClickOpeningAModal_IsCovered;
begin

  BuildDialogs;
  var oReply := Send( 'dialogs', '{"button":"Nest"}' );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'covered', oReply.GetValue<string>( 'result.outcome', '' ), oReply.ToJSON );
  finally
    oReply.Free;
  end;
  Pump( 3000 );

end;

procedure TTestGllAutomationServer.Dialogs_StyledButton_TakesTheMousePath;
begin

  BuildDialogs;
  var oReply := Send( 'dialogs', '{"button":"Styled"}' );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    Assert.AreEqual( 'mouse', oReply.GetValue<string>( 'result.method', '' ), oReply.ToJSON );
    Pump( 300 );
    Assert.AreEqual( 1, FStyledClicks, 'the styled button''s handler: ' + oReply.ToJSON );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Dialogs_ModalOnly_LeavesOutPlainWindows;
begin

  BuildDialogs;
  var oReply := Send( 'dialogs', '{"modalOnly":true}' );
  try
    Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
    for var oWindow in oReply.GetValue<TJSONArray>( 'result.windows' ) do
    begin
      var iWindow := oWindow.GetValue<Int64>( 'hwnd' );
      Assert.IsFalse( ( iWindow = IntPtr( FDlgA.Handle ) ) or ( iWindow = IntPtr( FDlgB.Handle ) ) or
        ( iWindow = IntPtr( FDlgC.Handle ) ), 'a plain window was listed as modal: ' + oWindow.ToJSON );
      Assert.IsTrue( oWindow.GetValue<Boolean>( 'modal' ), oWindow.ToJSON );
    end;
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Dialogs_List_ReadsStaticTexts;
begin

  BuildDialogs;
  var oReply := Send( 'dialogs' );
  try
    var bFound := False;
    for var oWindow in oReply.GetValue<TJSONArray>( 'result.windows' ) do
      if oWindow.GetValue<Int64>( 'hwnd' ) = IntPtr( FDlgA.Handle ) then
        for var oText in oWindow.GetValue<TJSONArray>( 'texts' ) do
          if oText.Value = 'Hello there' then
            bFound := True;
    Assert.IsTrue( bFound, 'DlgA''s TStaticText is not in its texts: ' + oReply.ToJSON );
  finally
    oReply.Free;
  end;

end;

procedure TTestGllAutomationServer.Dialogs_MainThreadBusy_SaysSo;
begin

  var oIdle := Send( 'dialogs' );
  try
    Assert.IsFalse( oIdle.GetValue<Boolean>( 'result.mainThreadBusy' ), 'an idle main thread: ' + oIdle.ToJSON );
  finally
    oIdle.Free;
  end;

  TThread.ForceQueue( nil,
    procedure
    begin
      Sleep( 1500 );
    end );
  var oBusy := SendDelayed( 'dialogs', '', 300 );
  try
    Assert.IsTrue( oBusy.GetValue<Boolean>( 'result.mainThreadBusy' ), 'a main thread asleep for 1.5 s: ' + oBusy.ToJSON );
  finally
    oBusy.Free;
  end;

end;

procedure TTestGllAutomationServer.Dialogs_BadHwnd_IsRefused;
begin

  BuildDialogs;
  Assert.AreEqual( 'NoWindow', SendFail( 'dialogs', '{"hwnd":1}' ), 'no such window' );
  Assert.AreEqual( 'NoWindow', SendFail( 'dialogs', Format( '{"hwnd":%d}', [ IntPtr( FTwins[ 0 ].Handle ) ] ) ), 'a child window' );
  Assert.AreEqual( 'NoWindow', SendFail( 'dialogs', Format( '{"hwnd":%d}', [ IntPtr( GetDesktopWindow ) ] ) ), 'another process''s' );
  Assert.AreEqual( 'BadRequest', SendFail( 'dialogs', '{"hwnd":"DlgA"}' ), 'not a number' );
  Assert.AreEqual( 'NoWindow', SendFail( 'dialogs', '{"buttonHwnd":1}' ), 'no such button' );
  Assert.AreEqual( 'NoWindow', SendFail( 'dialogs', Format( '{"buttonHwnd":%d}', [ IntPtr( FDlgA.Handle ) ] ) ), 'not a button' );
  Pump( 200 );
  Assert.AreEqual( 0, FTwinClicks[ 0 ] + FTwinClicks[ 1 ] + FCountClicks, 'something was clicked' );

end;

procedure TTestGllAutomationServer.DropFiles_NonAsciiPath_ArrivesIntact;
begin

  var sFile := TPath.Combine( TPath.GetTempPath, 'gllAutoDrop-ünïcödé-日本.txt' );
  TFile.WriteAllText( sFile, '1' );
  try
    var oReply := Send( 'drop_files', Format( '{"form":"%s","name":"dropZone","files":[%s]}', [ FORM_NAME, JsonText( sFile ) ] ) );
    try
      Assert.IsTrue( oReply.GetValue<Boolean>( 'ok' ), oReply.ToJSON );
      Pump( 300 );
      var oZone := TDropZone( FDropZone );
      Assert.AreEqual( 1, Integer( Length( oZone.Files ) ), oReply.ToJSON );
      Assert.AreEqual( sFile, oZone.Files[ 0 ], False );
    finally
      oReply.Free;
    end;
  finally
    TFile.Delete( sFile );
  end;

end;

procedure TTestGllAutomationServer.RegisterCommand_RefusesASecondProvider;
begin

  Assert.WillRaise(
    procedure
    begin
      TAutomationServer.RegisterCommand( CMD_MAIN,
        function( ARequest: TJSONObject ): TJSONValue
        begin
          Result := TJSONString.Create( SHADOW_MARKER );
        end );
    end, EArgumentException, 'a second registration of a registered name' );

  var oReply := Send( CMD_MAIN, '{"text":"first"}' );
  try
    Assert.AreEqual( 'first', oReply.GetValue<string>( 'result.echo', '' ), False, 'the first provider must still answer: ' + oReply.ToJSON );
  finally
    oReply.Free;
  end;

end;

initialization
  TDUnitX.RegisterTestFixture( TTestGllAutomationServer );

end.
