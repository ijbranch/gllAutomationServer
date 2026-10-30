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
///   The client side of gllAutomationServer: finds a running automation-enabled app, proves it is the
///   process it claims to be, and sends it commands.  <c>TAutomationDiscovery</c> is the transport and
///   the trust checks; <c>TAutomationApp</c> wraps them for a DUnitX suite that launches an app with
///   <c>/AUTOMATION</c>, drives it and closes it, with no AI in the loop.
/// </summary>
/// <remarks>
///   <para>Never call it from the main thread of the app being driven: every command but <c>dialogs</c>,
///   <c>screenshot</c>, <c>keys</c> and the commands a host registered for the worker thread runs on that
///   thread, so the reply would wait for itself.  A separate test process is the intended caller.</para>
///   <para>A suite that drives a GUI belongs in GITLAKMCP's <c>[TestRunner] DesktopTargets</c>: on the
///   service's own window station no window is visible, so modal dialogs are never listed and screenshots
///   come out blank (measured 2026-10-31).</para>
/// </remarks>
unit gllAutomationServer.Client;

interface

uses
  Winapi.Windows, System.SysUtils, System.Classes, System.JSON;

const
  /// <summary>Where every automation-enabled app advertises itself, one <c>&lt;pid&gt;.json</c> per process.</summary>
  AUTOMATION_DISCOVERY_DIR = 'C:\ProgramData\GITLAK\Automation';
  /// <summary>How long a command may take before its reply is given up on, in milliseconds.</summary>
  AUTOMATION_READ_TIMEOUT_MS = 10000;
  /// <summary>How long <c>TAutomationApp.Launch</c> waits for the app to advertise itself, in milliseconds.</summary>
  AUTOMATION_LAUNCH_TIMEOUT_MS = 15000;
  /// <summary>How long <c>TAutomationApp.Close</c> waits for the app to exit before it terminates it, in milliseconds.</summary>
  AUTOMATION_CLOSE_TIMEOUT_MS = 10000;

type
  /// <summary>One running app's advertisement, as read from its discovery file.</summary>
  TAutomationEndpoint = record
    /// <summary>The name the app registered under ( <c>TAutomationServer.Start</c>'s first argument ).</summary>
    App: string;
    /// <summary>The app's process ID.</summary>
    Pid: Cardinal;
    /// <summary>The loopback port its server listens on.</summary>
    Port: Word;
    /// <summary>The token every request must carry.</summary>
    Token: string;
  end;

  /// <summary>Decides whether a live, port-owning advertisement may be sent the token.</summary>
  /// <param name="APid">The advertised process.</param>
  /// <param name="AApp">The advertised app name.</param>
  /// <returns>True to trust it.</returns>
  TAutomationTrustCheck = reference to function( APid: Cardinal; const AApp: string ): Boolean;

  /// <summary>A request that could not be delivered or answered: no app, a refused connection, a timeout.</summary>
  EAutomationClientError = class( Exception );

  /// <summary>The server answered with an error; <c>Code</c> is its stable error code ( <c>NoComp</c>, <c>NoProp</c>, ... ).</summary>
  EAutomationCommandError = class( EAutomationClientError )
  private
    /// <summary>Backs <c>Code</c>.</summary>
    FCode: string;
    /// <summary>Backs <c>Data</c>.</summary>
    FData: string;
  public
    /// <summary>Creates the error from the server's reply.</summary>
    /// <param name="ACode">The server's error code.</param>
    /// <param name="AMessage">The server's message.</param>
    /// <param name="AData">The reply's <c>error.data</c> as JSON text, or '' when it had none.</param>
    constructor CreateReply( const ACode, AMessage, AData: string );
    /// <summary>The server's error code.</summary>
    property Code: string read FCode;
    /// <summary>The reply's <c>error.data</c> as JSON text ( for <c>NoProp</c>, the object's properties ), or ''.</summary>
    property Data: string read FData;
  end;

  /// <summary>The transport and the trust checks, shared by every client of the server.</summary>
  TAutomationDiscovery = class sealed
  public
    /// <summary>True when the process is still running, or exists but may not be opened by this one.</summary>
    /// <param name="APid">The process ID.</param>
    /// <returns>True while the process has not exited; True also when access to it is denied, the safe direction for a caller that deletes what this reports dead.</returns>
    class function IsPidAlive( APid: Cardinal ): Boolean; static;
    /// <summary>
    ///   True when a LISTENING IPv4 socket on <c>127.0.0.1:APort</c> belongs to exactly <c>APid</c> and no
    ///   other process listens on that port on loopback or any address.  A discovery file is honoured only
    ///   when it does, so a planted file cannot steer the token to another listener.
    /// </summary>
    /// <param name="APid">The advertised process.</param>
    /// <param name="APort">The advertised port.</param>
    /// <returns>True when the process owns the port.</returns>
    class function PidOwnsLocalPort( APid: Cardinal; APort: Word ): Boolean; static;
    /// <summary>True when the process runs as the same user as this one; one that cannot be read is not.</summary>
    /// <param name="APid">The process ID.</param>
    /// <returns>True when the token user SIDs match.</returns>
    class function PidIsSameUser( APid: Cardinal ): Boolean; static;
    /// <summary>
    ///   Reads every advertisement in <c>ADir</c>: deletes those of exited processes, and returns the live ones
    ///   whose process owns the advertised port and passes <c>AIsTrusted</c>.
    /// </summary>
    /// <param name="ADir">The discovery folder.</param>
    /// <param name="AIsTrusted">The trust check; nil means the same-user check ( <c>PidIsSameUser</c> ).</param>
    /// <returns>The trusted endpoints, in no particular order; empty when there are none or the folder is missing.</returns>
    /// <remarks>An unreadable or malformed file is skipped, and a live process's file is never deleted.</remarks>
    class function ReadEndpoints( const ADir: string = AUTOMATION_DISCOVERY_DIR;
      const AIsTrusted: TAutomationTrustCheck = nil ): TArray<TAutomationEndpoint>; static;
    /// <summary>
    ///   Sends one request on a fresh connection and reads its reply line.  The token and an id are added to
    ///   <c>ARequest</c>, and the port's owner is checked again just before the token goes out.
    /// </summary>
    /// <param name="AEndpoint">The target.</param>
    /// <param name="ARequest">The request, which the caller owns; <c>token</c> and <c>id</c> are added to it.</param>
    /// <param name="AResponse">The reply line, or the reason there is none.</param>
    /// <param name="AReadTimeoutMs">How long to wait for the reply.</param>
    /// <returns>True when a reply was read.</returns>
    class function Send( const AEndpoint: TAutomationEndpoint; ARequest: TJSONObject; out AResponse: string;
      AReadTimeoutMs: Integer = AUTOMATION_READ_TIMEOUT_MS ): Boolean; static;
  end;

  /// <summary>
  ///   One automation-enabled app, driven from a test: <c>Launch</c> or <c>Attach</c>, then the command
  ///   methods, then <c>Close</c> ( or <c>Free</c> ).  A failed command raises <c>EAutomationCommandError</c>
  ///   carrying the server's code; a failed delivery raises <c>EAutomationClientError</c>.
  /// </summary>
  /// <remarks>
  ///   <c>AForm</c> takes what the server takes: a form's name, <c>main</c> or <c>active</c> ( the form in
  ///   front, a modal one included: <c>GetProp( 'active', 'Message', 'Caption' )</c> reads a
  ///   <c>ShowMessage</c> text ).  An empty <c>AForm</c> leaves it to the server ( the active form ).
  /// </remarks>
  TAutomationApp = class
  private
    /// <summary>The target.</summary>
    FEndpoint: TAutomationEndpoint;
    /// <summary>The process handle, when this object launched the app; 0 when it attached.</summary>
    FProcess: THandle;
    /// <summary>The discovery folder the app was found in, so <c>Close</c> can remove a file left by a terminated app.</summary>
    FDiscoveryDir: string;
    /// <summary>Wraps the arguments of a component command into a request.</summary>
    /// <param name="ACmd">The command.</param>
    /// <param name="AForm">The form, or '' for the server's default.</param>
    /// <param name="AName">The component, or '' for none.</param>
    /// <returns>A new request the caller owns.</returns>
    function Request( const ACmd, AForm, AName: string ): TJSONObject;
    /// <summary>Sends a request and returns the reply's <c>result</c> as a string field.</summary>
    /// <param name="ARequest">The request; freed here.</param>
    /// <param name="AField">The <c>result</c> field wanted.</param>
    /// <returns>That field's value as text; '' when it is absent or null.</returns>
    /// <exception cref="EAutomationClientError">No reply.</exception>
    /// <exception cref="EAutomationCommandError">The server reported an error.</exception>
    function CallField( ARequest: TJSONObject; const AField: string ): string;
  public
    /// <summary>Wraps a known endpoint; prefer <c>Launch</c> or <c>Attach</c>.</summary>
    /// <param name="AEndpoint">The target.</param>
    /// <param name="AProcess">Its process handle, which this object then owns, or 0.</param>
    /// <param name="ADiscoveryDir">The discovery folder it was read from.</param>
    constructor Create( const AEndpoint: TAutomationEndpoint; AProcess: THandle; const ADiscoveryDir: string );
    /// <summary>Closes an app this object launched ( <c>Close</c> ), then releases it.</summary>
    destructor Destroy; override;
    /// <summary>
    ///   Starts <c>AExe</c> with <c>/AUTOMATION</c> ( and <c>AArgs</c> ), shown normally, and waits for it to
    ///   advertise a trusted endpoint.  The window takes the focus, so run such a suite on the hidden desktop
    ///   ( <c>test_run</c> ), not in a session someone is typing in.
    /// </summary>
    /// <param name="AExe">The application's full path.</param>
    /// <param name="AArgs">Further command-line arguments, already quoted as needed.</param>
    /// <param name="ATimeoutMs">How long to wait for the advertisement.</param>
    /// <param name="ADiscoveryDir">The discovery folder.</param>
    /// <returns>The app, which the caller owns; freeing it closes the app.</returns>
    /// <exception cref="EAutomationClientError">The exe could not be started, exited, or did not advertise itself in time ( it is then terminated ).</exception>
    class function Launch( const AExe: string; const AArgs: string = ''; ATimeoutMs: Integer = AUTOMATION_LAUNCH_TIMEOUT_MS;
      const ADiscoveryDir: string = AUTOMATION_DISCOVERY_DIR ): TAutomationApp; static;
    /// <summary>Attaches to a running app by its registered name or its process ID.</summary>
    /// <param name="ATarget">The app name or PID; '' when exactly one app is running.</param>
    /// <param name="ADiscoveryDir">The discovery folder.</param>
    /// <returns>The app, which the caller owns; freeing it leaves the app running.</returns>
    /// <exception cref="EAutomationClientError">No trusted app matches, or '' or a name was given and several match.</exception>
    class function Attach( const ATarget: string = ''; const ADiscoveryDir: string = AUTOMATION_DISCOVERY_DIR ): TAutomationApp; static;
    /// <summary>
    ///   Closes an app this object launched through its normal close path ( the server's <c>close</c>
    ///   command, which runs <c>MainForm.Close</c>; when the server refuses it, as one older than 0.14 does,
    ///   <c>WM_CLOSE</c> to its <c>TApplication</c> window ), waits for it to exit, and terminates it if it has
    ///   not ( a "save changes?" prompt, say ).  A <c>close</c> that gets no reply is not repeated by
    ///   <c>WM_CLOSE</c>, since it may still be queued.  Removes the discovery file only of an app it had to
    ///   terminate; one that closed itself removed its own.  Does nothing for an attached app or one already
    ///   closed.
    /// </summary>
    /// <param name="ATimeoutMs">How long to wait for a clean exit.</param>
    /// <returns>True when the app exited by itself ( or was not ours to close ); False when it had to be terminated.</returns>
    /// <remarks>A negative <c>ATimeoutMs</c> is taken as 0, not as an infinite wait.</remarks>
    function Close( ATimeoutMs: Integer = AUTOMATION_CLOSE_TIMEOUT_MS ): Boolean;
    /// <summary>Sends any command and returns its <c>result</c>.</summary>
    /// <param name="ARequest">The request with its <c>cmd</c> and fields; this method frees it.</param>
    /// <param name="AReadTimeoutMs">How long to wait for the reply.</param>
    /// <returns>The reply's <c>result</c>, which the caller owns; an empty object when it had none.</returns>
    /// <exception cref="EAutomationClientError">No reply, or one that is not a JSON object.</exception>
    /// <exception cref="EAutomationCommandError">The server reported an error.</exception>
    function Call( ARequest: TJSONObject; AReadTimeoutMs: Integer = AUTOMATION_READ_TIMEOUT_MS ): TJSONObject;
    /// <summary>Reads a property ( a dotted path such as <c>Font.Size</c> reaches through object properties ).</summary>
    /// <param name="AForm">The form.</param>
    /// <param name="AName">The component, or '' for the form itself.</param>
    /// <param name="AProp">The property.</param>
    /// <returns>Its value as text ( a Boolean as <c>true</c> / <c>false</c> ).</returns>
    /// <exception cref="EAutomationCommandError">For instance <c>NoComp</c>, or <c>NoProp</c> with the properties in <c>Data</c>.</exception>
    function GetProp( const AForm, AName, AProp: string ): string;
    /// <summary>Writes a property from text, which the server converts to the property's type.</summary>
    /// <param name="AForm">The form.</param>
    /// <param name="AName">The component, or '' for the form itself.</param>
    /// <param name="AProp">The property.</param>
    /// <param name="AValue">The new value.</param>
    /// <returns>False when it already held the value, so an <c>OnChange</c> almost certainly did not fire; True when it changed, or when the server could not read the old value to tell.</returns>
    /// <exception cref="EAutomationCommandError">For instance <c>NoProp</c> or <c>ReadOnlyProp</c>.</exception>
    function SetProp( const AForm, AName, AProp, AValue: string ): Boolean;
    /// <summary>Fires a component's <c>OnClick</c> and waits for the handler to return.</summary>
    /// <param name="AForm">The form.</param>
    /// <param name="AName">The component.</param>
    /// <param name="ACount">How many clicks, 1 to 1000.</param>
    /// <exception cref="EAutomationCommandError">The click failed, or the handler raised ( code <c>HandlerRaised</c>, the exception in the message ).</exception>
    /// <remarks>The handler's exception is caught by the server, so it never reaches EurekaLog; <c>ClickAsync</c> does not catch it.</remarks>
    procedure Click( const AForm, AName: string; ACount: Integer = 1 );
    /// <summary>Posts a click to a button and returns BEFORE it runs, so a handler that opens a modal dialog cannot block the call.</summary>
    /// <param name="AForm">The form.</param>
    /// <param name="AName">The button ( a button-class control, visible and enabled ).</param>
    /// <exception cref="EAutomationCommandError">For instance <c>NotButton</c>.</exception>
    procedure ClickAsync( const AForm, AName: string );
    /// <summary>Executes a named action, or the action assigned to a named control.</summary>
    /// <param name="AForm">The form.</param>
    /// <param name="AName">The action or control.</param>
    /// <exception cref="EAutomationCommandError">For instance <c>ActionDisabled</c>.</exception>
    procedure ExecuteAction( const AForm, AName: string );
    /// <summary>Types text, then sends key chords ( <c>Ctrl+S</c>, <c>Tab</c>, <c>Enter</c>, ... ), through the app's own message loop.</summary>
    /// <param name="AForm">The form.</param>
    /// <param name="AName">The control, or '' for the form's focused control.</param>
    /// <param name="AText">Text to type, or ''.</param>
    /// <param name="AKeys">Chords to send after it, comma-separated, or ''.</param>
    /// <exception cref="EAutomationCommandError">The keys could not be delivered.</exception>
    procedure SendKeys( const AForm, AName, AText: string; const AKeys: string = '' );
    /// <summary>Lists the modal windows waiting to be answered.</summary>
    /// <returns>The server's <c>dialogs</c> result ( <c>windows</c>, <c>mainThreadBusy</c> ), which the caller owns.</returns>
    /// <exception cref="EAutomationCommandError">The listing failed.</exception>
    function ModalDialogs: TJSONObject;
    /// <summary>Clicks the one clickable button of that caption in an open dialog, a modal one first.</summary>
    /// <param name="ACaption">The caption; <c>&amp;</c> and case are ignored.</param>
    /// <returns>The outcome: <c>gone</c>, <c>covered</c>, <c>unchanged</c> or <c>pending</c>.</returns>
    /// <exception cref="EAutomationCommandError">For instance <c>NoButton</c> or <c>AmbiguousButton</c>.</exception>
    function ClickDialogButton( const ACaption: string ): string;
    /// <summary>Reads a field of a dataset ( or of a data source's dataset ).</summary>
    /// <param name="AForm">The form.</param>
    /// <param name="ADataSet">The <c>TDataSet</c> or <c>TDataSource</c>.</param>
    /// <param name="AField">The field.</param>
    /// <returns>Its value as text; '' when it is null.</returns>
    /// <exception cref="EAutomationCommandError">For instance <c>NotDataSet</c>.</exception>
    function FieldGet( const AForm, ADataSet, AField: string ): string;
    /// <summary>Writes a field, putting a browsing dataset into edit mode first; nothing is posted.</summary>
    /// <param name="AForm">The form.</param>
    /// <param name="ADataSet">The <c>TDataSet</c> or <c>TDataSource</c>.</param>
    /// <param name="AField">The field.</param>
    /// <param name="AValue">The new value.</param>
    /// <exception cref="EAutomationCommandError">The write failed.</exception>
    procedure FieldSet( const AForm, ADataSet, AField, AValue: string );
    /// <summary>Runs a dataset operation: <c>insert</c>, <c>append</c>, <c>edit</c>, <c>post</c>, <c>cancel</c>, <c>refresh</c>, <c>first</c>, <c>last</c>, <c>next</c> or <c>prior</c>.</summary>
    /// <param name="AForm">The form.</param>
    /// <param name="ADataSet">The <c>TDataSet</c> or <c>TDataSource</c>.</param>
    /// <param name="AOp">The operation.</param>
    /// <exception cref="EAutomationCommandError">For instance <c>BadOp</c>.</exception>
    procedure DatasetOp( const AForm, ADataSet, AOp: string );
    /// <summary>Polls a property until it reads <c>AExpected</c> or the time runs out.</summary>
    /// <param name="AForm">The form.</param>
    /// <param name="AName">The component.</param>
    /// <param name="AProp">The property.</param>
    /// <param name="AExpected">The value waited for, compared exactly.</param>
    /// <param name="ATimeoutMs">How long to wait.</param>
    /// <returns>True when it was seen; False on time-out.</returns>
    /// <remarks>
    ///   <c>NoForm</c> and <c>NoComp</c> while polling ( the form not open yet ) count as "not yet"; each poll
    ///   waits no longer than the time left, so a reply that does not come in time is a delivery failure.
    /// </remarks>
    /// <exception cref="EAutomationClientError">The app stopped answering before the time ran out ( a poll cut short by the time-out itself returns False ).</exception>
    /// <exception cref="EAutomationCommandError">Any other server error, such as <c>NoProp</c>.</exception>
    function WaitForProp( const AForm, AName, AProp, AExpected: string; ATimeoutMs: Integer = 10000 ): Boolean;
    /// <summary>Renders a control, or a form, to a PNG.</summary>
    /// <param name="AForm">The form.</param>
    /// <param name="AName">The control, or '' for the whole form.</param>
    /// <param name="APath">The PNG to write: absolute, in a folder that exists; it replaces any file there.</param>
    /// <returns>The path written.</returns>
    /// <exception cref="EAutomationCommandError">For instance <c>BadPath</c> or <c>CaptureFailed</c>.</exception>
    function Screenshot( const AForm, AName, APath: string ): string;
    /// <summary>The target's advertisement.</summary>
    property Endpoint: TAutomationEndpoint read FEndpoint;
  end;

implementation

uses
  Winapi.Messages, System.IOUtils, System.Diagnostics, System.Math,
  IdTCPClient, IdGlobal, IdException;

const
  /// <summary><c>GetExtendedTcpTable</c>'s address family for IPv4.</summary>
  AF_INET_IPV4              = 2;
  /// <summary><c>GetExtendedTcpTable</c>'s table class: every TCP endpoint, with its owning PID.</summary>
  TCP_TABLE_OWNER_PID_ALL   = 5;
  /// <summary>The <c>MIB_TCP_STATE</c> of a listening socket.</summary>
  MIB_TCP_STATE_LISTEN      = 2;
  /// <summary><c>OpenProcess</c> access enough to read the exit code, image name and token of another user's process; Winapi.Windows does not declare it.</summary>
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
  /// <summary>127.0.0.1 as a little-endian <c>in_addr</c>.</summary>
  LOOPBACK_ADDR             = $0100007F;
  /// <summary>The longest reply line accepted, so a misbehaving peer cannot make the read buffer grow without bound.</summary>
  MAX_REPLY_BYTES           = 4 * 1024 * 1024;
  /// <summary>How long a connection attempt may take, in milliseconds.</summary>
  CONNECT_TIMEOUT_MS        = 3000;
  /// <summary>Pause between two looks at the discovery folder, or two polls of a property, in milliseconds.</summary>
  POLL_INTERVAL_MS          = 100;

type
  /// <summary>One row of <c>MIB_TCPTABLE_OWNER_PID</c>.</summary>
  TMibTcpRowOwnerPid = record
    dwState      : DWORD;
    dwLocalAddr  : DWORD;
    dwLocalPort  : DWORD;
    dwRemoteAddr : DWORD;
    dwRemotePort : DWORD;
    dwOwningPid  : DWORD;
  end;
  /// <summary>Pointer to a <c>TMibTcpRowOwnerPid</c>.</summary>
  PMibTcpRowOwnerPid = ^TMibTcpRowOwnerPid;

  /// <summary><c>MIB_TCPTABLE_OWNER_PID</c>: a count, then that many rows.</summary>
  TMibTcpTableOwnerPid = record
    dwNumEntries : DWORD;
    table        : array[ 0..0 ] of TMibTcpRowOwnerPid;
  end;
  /// <summary>Pointer to a <c>TMibTcpTableOwnerPid</c>.</summary>
  PMibTcpTableOwnerPid = ^TMibTcpTableOwnerPid;

function GetExtendedTcpTable( pTcpTable: Pointer; var pdwSize: DWORD; bOrder: BOOL; ulAf: ULONG; TableClass: Integer;
  Reserved: ULONG ): DWORD; stdcall; external 'iphlpapi.dll';

function ConvertSidToStringSidW( Sid: PSID; var StringSid: PWideChar ): BOOL; stdcall; external advapi32;

/// <summary>Reads a process's token user SID as text.</summary>
/// <param name="AProcess">An open process handle with query access.</param>
/// <param name="ASid">The SID, or '' when it could not be read.</param>
/// <returns>True when it was read.</returns>
function TokenUserSid( AProcess: THandle; out ASid: string ): Boolean;
begin

  Result            := False;
  ASid              := '';
  var hToken: THandle := 0;
  if not OpenProcessToken( AProcess, TOKEN_QUERY, hToken ) then
    Exit;
  try
    var dwLen: DWORD := 0;
    GetTokenInformation( hToken, TokenUser, nil, 0, dwLen ); // sizing call; expected to fail
    if dwLen = 0 then
      Exit;
    var pInfo: PTokenUser;
    GetMem( pInfo, dwLen );
    try
      if not GetTokenInformation( hToken, TokenUser, pInfo, dwLen, dwLen ) then
        Exit;
      var pStr: PWideChar := nil;
      if not ConvertSidToStringSidW( pInfo^.User.Sid, pStr ) then
        Exit;
      try
        ASid        := string( pStr );
        Result      := ASid <> '';
      finally
        LocalFree( HLOCAL( pStr ) );
      end;
    finally
      FreeMem( pInfo );
    end;
  finally
    CloseHandle( hToken );
  end;

end;

/// <summary>A JSON value as plain text: a string without its quotes, null as ''.</summary>
/// <param name="AValue">The value, or nil.</param>
/// <returns>The text.</returns>
function ValueText( AValue: TJSONValue ): string;
begin

  if ( AValue = nil ) or ( AValue is TJSONNull ) then
    Exit( '' );
  if AValue is TJSONString then
    Exit( TJSONString( AValue ).Value );
  Result            := AValue.ToJSON;

end;

/// <summary>Reads the <c>error</c> of a failed reply into an exception.</summary>
/// <param name="AReply">The parsed reply.</param>
/// <returns>A new exception for the caller to raise.</returns>
function ReplyError( AReply: TJSONObject ): EAutomationCommandError;
begin

  var sCode         := 'Unknown';
  var sMessage      := 'the server reported an error without details';
  var sData         := '';
  var oError        := AReply.GetValue( 'error' );
  if oError is TJSONObject then
  begin
    //  ValueText, not GetValue<string>: a field of another type must not turn into an EJSONException
    var sGot        := ValueText( TJSONObject( oError ).GetValue( 'code' ) );
    if sGot <> '' then
      sCode         := sGot;
    sGot            := ValueText( TJSONObject( oError ).GetValue( 'message' ) );
    if sGot <> '' then
      sMessage      := sGot;
    var oData       := TJSONObject( oError ).GetValue( 'data' );
    if oData <> nil then
      sData         := oData.ToJSON;
  end;
  Result            := EAutomationCommandError.CreateReply( sCode, sMessage, sData );

end;

{ EAutomationCommandError }

constructor EAutomationCommandError.CreateReply( const ACode, AMessage, AData: string );
begin

  inherited CreateFmt( '%s: %s', [ ACode, AMessage ] );
  FCode             := ACode;
  FData             := AData;

end;

{ TAutomationDiscovery }

class function TAutomationDiscovery.IsPidAlive( APid: Cardinal ): Boolean;
begin

  //  the server's own rule ( ProcessIsAlive ): a process we may not open is there, and counts as alive,
  //  since a caller deletes what this reports dead; and a signalled object has exited whatever its exit code
  var hProcess      := OpenProcess( SYNCHRONIZE, False, APid );
  if hProcess = 0 then
    Exit( GetLastError = ERROR_ACCESS_DENIED );
  try
    Result          := WaitForSingleObject( hProcess, 0 ) = WAIT_TIMEOUT;
  finally
    CloseHandle( hProcess );
  end;

end;

class function TAutomationDiscovery.PidOwnsLocalPort( APid: Cardinal; APort: Word ): Boolean;
begin

  Result            := False;
  if ( APid = 0 ) or ( APort = 0 ) then
    Exit;

  //  two calls with a bounded retry: the table can grow between the size probe and the fill
  var pTable: PMibTcpTableOwnerPid;
  var iAttempt      := 0;
  repeat
    Inc( iAttempt );
    var dwSize: DWORD := 0;
    GetExtendedTcpTable( nil, dwSize, False, AF_INET_IPV4, TCP_TABLE_OWNER_PID_ALL, 0 );
    if dwSize = 0 then
      Exit;
    GetMem( pTable, dwSize );
    var dwRet       := GetExtendedTcpTable( pTable, dwSize, False, AF_INET_IPV4, TCP_TABLE_OWNER_PID_ALL, 0 );
    if dwRet = NO_ERROR then
      Break;
    FreeMem( pTable );
    if ( dwRet <> ERROR_INSUFFICIENT_BUFFER ) or ( iAttempt = 5 ) then
      Exit; // retries exhausted: treat as untrusted
  until False;

  try
    var bOwned      := False;
    for var iRow := 0 to Integer( pTable^.dwNumEntries ) - 1 do
    begin
      var pRow      := PMibTcpRowOwnerPid( NativeUInt( @pTable^.table[ 0 ] ) + NativeUInt( iRow ) * SizeOf( TMibTcpRowOwnerPid ) );
      var iPort     := ( ( pRow^.dwLocalPort and $FF ) shl 8 ) or ( ( pRow^.dwLocalPort shr 8 ) and $FF );
      if ( iPort <> APort ) or ( pRow^.dwState <> MIB_TCP_STATE_LISTEN ) then
        Continue;
      //  the server binds 127.0.0.1 exactly; any OTHER listener on that port ( a wildcard one included )
      //  could be the one a connection reaches, so its presence makes the port untrusted
      if ( pRow^.dwOwningPid = APid ) and ( pRow^.dwLocalAddr = LOOPBACK_ADDR ) then
        bOwned      := True
      else if ( pRow^.dwLocalAddr = LOOPBACK_ADDR ) or ( pRow^.dwLocalAddr = 0 ) then
        Exit( False );
    end;
    Result          := bOwned;
  finally
    FreeMem( pTable );
  end;

end;

class function TAutomationDiscovery.PidIsSameUser( APid: Cardinal ): Boolean;
begin

  Result            := False;
  var sMine         := '';
  if not TokenUserSid( GetCurrentProcess, sMine ) then
    Exit;
  var hProcess      := OpenProcess( PROCESS_QUERY_LIMITED_INFORMATION, False, APid );
  if hProcess = 0 then
    Exit;
  try
    var sTheirs     := '';
    Result          := TokenUserSid( hProcess, sTheirs ) and SameText( sMine, sTheirs );
  finally
    CloseHandle( hProcess );
  end;

end;

class function TAutomationDiscovery.ReadEndpoints( const ADir: string;
  const AIsTrusted: TAutomationTrustCheck ): TArray<TAutomationEndpoint>;
begin

  Result            := [];
  if not TDirectory.Exists( ADir ) then
    Exit;

  var aFiles: TArray<string>;
  try
    aFiles          := TDirectory.GetFiles( ADir, '*.json' );
  except
    //  an access-denied folder or a race with a deletion: report what can be read, which is nothing
    on EInOutError do
      Exit;
    on EOSError do
      Exit;
  end;

  for var sFile in aFiles do
  begin
    var sText       := '';
    try
      sText         := TFile.ReadAllText( sFile, TEncoding.UTF8 );
    except
      //  the file is being written or was just removed: skip it this time
      on EInOutError do
        Continue;
      on EOSError do
        Continue;
    end;

    var oValue      := TJSONObject.ParseJSONValue( sText );
    if oValue is not TJSONObject then
    begin
      oValue.Free; // a partial or non-object file
      Continue;
    end;
    try
      var rEnd: TAutomationEndpoint;
      var oFile     := TJSONObject( oValue );
      var iPid: Int64 := 0;
      var iPort: Int64 := 0;
      //  a field of the wrong type makes GetValue<T> raise, so one malformed file would fail every lookup;
      //  read through the value classes instead, and skip a file that is not an advertisement
      var oPid      := oFile.GetValue( 'pid' );
      var oPort     := oFile.GetValue( 'port' );
      //  TryStrToInt64 on the number's text: AsInt64 raises on 1e30 or 1.5
      if not ( oPid is TJSONNumber ) or not TryStrToInt64( TJSONNumber( oPid ).Value, iPid ) then
        iPid        := 0;
      if not ( oPort is TJSONNumber ) or not TryStrToInt64( TJSONNumber( oPort ).Value, iPort ) then
        iPort       := 0;
      if ( iPid <= 0 ) or ( iPid > High( Cardinal ) ) or ( iPort <= 0 ) or ( iPort > High( Word ) ) then
        Continue; // not an advertisement this client can use
      rEnd.App      := ValueText( oFile.GetValue( 'app' ) );
      rEnd.Pid      := Cardinal( iPid );
      rEnd.Port     := Word( iPort );
      rEnd.Token    := ValueText( oFile.GetValue( 'token' ) );

      if not IsPidAlive( rEnd.Pid ) then
      begin
        try
          TFile.Delete( sFile ); // left by a process that was killed
        except
          on EInOutError do ; // another reader swept it first
          on EOSError do ;
        end;
      end
      else if PidOwnsLocalPort( rEnd.Pid, rEnd.Port ) and
        ( ( Assigned( AIsTrusted ) and AIsTrusted( rEnd.Pid, rEnd.App ) ) or
          ( not Assigned( AIsTrusted ) and PidIsSameUser( rEnd.Pid ) ) ) then
        Result      := Result + [ rEnd ];
    finally
      oValue.Free;
    end;
  end;

end;

class function TAutomationDiscovery.Send( const AEndpoint: TAutomationEndpoint; ARequest: TJSONObject;
  out AResponse: string; AReadTimeoutMs: Integer ): Boolean;
begin

  Result            := False;
  AResponse         := '';

  //  the app may have exited since its file was read and another process taken the port
  if not PidOwnsLocalPort( AEndpoint.Pid, AEndpoint.Port ) then
  begin
    AResponse       := Format( 'port %d is no longer owned by PID %d ( the app exited or the port was taken )',
      [ AEndpoint.Port, AEndpoint.Pid ] );
    Exit;
  end;

  ARequest.RemovePair( 'token' ).Free;
  ARequest.RemovePair( 'id' ).Free;
  ARequest.AddPair( 'token', AEndpoint.Token );
  ARequest.AddPair( 'id', TJSONNumber.Create( 1 ) );

  var oClient       := TIdTCPClient.Create( nil );
  try
    oClient.Host    := '127.0.0.1';
    oClient.Port    := AEndpoint.Port;
    oClient.ConnectTimeout := CONNECT_TIMEOUT_MS;
    oClient.ReadTimeout := AReadTimeoutMs;
    try
      oClient.Connect;
      try
        oClient.IOHandler.MaxLineLength := MAX_REPLY_BYTES;
        oClient.IOHandler.WriteLn( ARequest.ToJSON, IndyTextEncoding_UTF8 );
        AResponse   := oClient.IOHandler.ReadLn( IndyTextEncoding_UTF8 );
        //  Indy's ReadLn returns '' on a read time-out rather than raising
        Result      := not oClient.IOHandler.ReadLnTimedout;
        if not Result then
          AResponse := Format( 'no reply within %d ms', [ AReadTimeoutMs ] );
      finally
        oClient.Disconnect;
      end;
    except
      //  the connection failed, timed out or dropped ( Indy's own root, socket errors included ): a transport
      //  failure, reported to the caller as text. Anything else is a fault of ours and propagates.
      on E: EIdException do
        AResponse   := E.ClassName + ': ' + E.Message;
    end;
  finally
    oClient.Free;
  end;

end;

{ TAutomationApp }

constructor TAutomationApp.Create( const AEndpoint: TAutomationEndpoint; AProcess: THandle; const ADiscoveryDir: string );
begin

  inherited Create;
  FEndpoint         := AEndpoint;
  FProcess          := AProcess;
  FDiscoveryDir     := ADiscoveryDir;

end;

destructor TAutomationApp.Destroy;
begin

  Close;
  inherited;

end;

class function TAutomationApp.Launch( const AExe, AArgs: string; ATimeoutMs: Integer;
  const ADiscoveryDir: string ): TAutomationApp;
begin

  if not TFile.Exists( AExe ) then
    raise EAutomationClientError.CreateFmt( 'no such application: %s', [ AExe ] );

  var rStartup: TStartupInfo;
  FillChar( rStartup, SizeOf( rStartup ), 0 );
  rStartup.cb       := SizeOf( rStartup );
  //  shown normally, since a runner launches its suite hidden and a child would otherwise inherit that.
  //  SW_SHOWNOACTIVATE, tried 2026-10-31 so a suite run from a desktop session would not take the keyboard,
  //  hung the client fixture on the hidden desktop ( 14 tests, 33 s, became a 240 s time-out ): keep GUI
  //  suites on the hidden desktop instead, where a focused window takes nobody's keyboard
  rStartup.dwFlags  := STARTF_USESHOWWINDOW;
  rStartup.wShowWindow := SW_SHOWNORMAL;
  var sCommand      := Format( '"%s" /AUTOMATION %s', [ AExe, AArgs ] ).TrimRight;
  UniqueString( sCommand ); // CreateProcessW may write to the command line
  var rProcess: TProcessInformation;
  if not CreateProcess( nil, PChar( sCommand ), nil, nil, False, 0, nil, PChar( ExtractFileDir( AExe ) ), rStartup,
    rProcess ) then
    raise EAutomationClientError.CreateFmt( 'could not start %s: %s', [ AExe, SysErrorMessage( GetLastError ) ] );
  CloseHandle( rProcess.hThread );

  //  from here every way out but the one that hands the handle to the new object terminates the child and
  //  closes its handle, so a failed launch never leaves an unowned app running
  try
    var rWatch      := TStopwatch.StartNew;
    while rWatch.ElapsedMilliseconds < ATimeoutMs do
    begin
      for var rEnd in TAutomationDiscovery.ReadEndpoints( ADiscoveryDir ) do
        if rEnd.Pid = rProcess.dwProcessId then
          Exit( TAutomationApp.Create( rEnd, rProcess.hProcess, ADiscoveryDir ) );
      if WaitForSingleObject( rProcess.hProcess, POLL_INTERVAL_MS ) = WAIT_OBJECT_0 then
      begin
        var dwExit: DWORD := 0;
        GetExitCodeProcess( rProcess.hProcess, dwExit );
        raise EAutomationClientError.CreateFmt( '%s ( pid %d ) exited with code %d before it advertised itself',
          [ AExe, rProcess.dwProcessId, dwExit ] );
      end;
    end;
    raise EAutomationClientError.CreateFmt( '%s ( pid %d ) did not advertise itself within %d ms ( is gllAutomationServer ' +
      'started on /AUTOMATION? )', [ AExe, rProcess.dwProcessId, ATimeoutMs ] );
  except
    TerminateProcess( rProcess.hProcess, 1 ); // fails harmlessly on one that already exited
    WaitForSingleObject( rProcess.hProcess, 5000 );
    CloseHandle( rProcess.hProcess );
    raise;
  end;

end;

class function TAutomationApp.Attach( const ATarget, ADiscoveryDir: string ): TAutomationApp;
begin

  var aEnds         := TAutomationDiscovery.ReadEndpoints( ADiscoveryDir );
  if Length( aEnds ) = 0 then
    raise EAutomationClientError.Create( 'no automation-enabled app is running' );

  var sTarget       := Trim( ATarget );
  if sTarget = '' then
  begin
    if Length( aEnds ) > 1 then
      raise EAutomationClientError.CreateFmt( '%d apps are running: name one ( app name or PID )', [ Length( aEnds ) ] );
    Exit( TAutomationApp.Create( aEnds[ 0 ], 0, ADiscoveryDir ) );
  end;

  var iPid          := StrToInt64Def( sTarget, -1 );
  for var rEnd in aEnds do
    if rEnd.Pid = iPid then
      Exit( TAutomationApp.Create( rEnd, 0, ADiscoveryDir ) );

  //  by name: refuse to guess between several instances, as for an empty target
  var aNamed: TArray<TAutomationEndpoint> := [];
  for var rEnd in aEnds do
    if SameText( rEnd.App, sTarget ) then
      aNamed        := aNamed + [ rEnd ];
  if Length( aNamed ) = 1 then
    Exit( TAutomationApp.Create( aNamed[ 0 ], 0, ADiscoveryDir ) );
  if Length( aNamed ) > 1 then
    raise EAutomationClientError.CreateFmt( '%d apps named "%s" are running: give a PID', [ Length( aNamed ), sTarget ] );
  raise EAutomationClientError.CreateFmt( 'no running app matches "%s"', [ sTarget ] );

end;

type
  /// <summary>What <c>FindAppWindowProc</c> looks for, and what it found.</summary>
  TAppWindowSearch = record
    /// <summary>The process whose window is wanted.</summary>
    Pid: DWORD;
    /// <summary>Its <c>TApplication</c> window, or 0 while none is found.</summary>
    Found: HWND;
  end;
  /// <summary>Pointer to a <c>TAppWindowSearch</c>, as passed through <c>EnumWindows</c>.</summary>
  PAppWindowSearch = ^TAppWindowSearch;

/// <summary>EnumWindows callback: records the first top-level <c>TApplication</c> window of a process.</summary>
/// <param name="AWnd">The window.</param>
/// <param name="AParam">A <c>PAppWindowSearch</c>.</param>
/// <returns>False to stop once found.</returns>
function FindAppWindowProc( AWnd: HWND; AParam: LPARAM ): BOOL; stdcall;
begin

  Result            := True;
  var pSearch       := PAppWindowSearch( AParam );
  var dwPid: DWORD  := 0;
  GetWindowThreadProcessId( AWnd, dwPid );
  if dwPid <> pSearch^.Pid then
    Exit;
  var aClass: array[ 0..63 ] of Char;
  if ( GetClassName( AWnd, aClass, Length( aClass ) ) > 0 ) and ( string( aClass ) = 'TApplication' ) then
  begin
    pSearch^.Found  := AWnd;
    Result          := False;
  end;

end;

function TAutomationApp.Close( ATimeoutMs: Integer ): Boolean;
begin

  Result            := True;
  if FProcess = 0 then
    Exit;

  if WaitForSingleObject( FProcess, 0 ) = WAIT_TIMEOUT then
  begin
    //  the server's close command runs MainForm.Close: the app's own close path
    var bRefused    := False;
    try
      Call( Request( 'close', '', '' ) ).Free;
    except
      //  refused ( a server older than 0.14 answers UnknownCmd ): fall back to WM_CLOSE below
      on EAutomationCommandError do
        bRefused    := True;
      //  no reply: the app may be closing already, or its main thread is busy with the close still queued
      //  behind it. Posting WM_CLOSE as well could close it twice ( a second "save changes?" ), so just wait.
      on EAutomationClientError do ;
    end;
    if bRefused then
    begin
      //  a GUI app's TApplication window answers WM_CLOSE with MainForm.Close too; a console host has none
      var rSearch: TAppWindowSearch;
      rSearch.Pid   := FEndpoint.Pid;
      rSearch.Found := 0;
      EnumWindows( @FindAppWindowProc, LPARAM( @rSearch ) );
      if rSearch.Found <> 0 then
        PostMessage( rSearch.Found, WM_CLOSE, 0, 0 );
    end;
    if WaitForSingleObject( FProcess, Cardinal( Max( 0, ATimeoutMs ) ) ) <> WAIT_OBJECT_0 then
    begin
      Result        := False;
      TerminateProcess( FProcess, 1 );
      WaitForSingleObject( FProcess, 5000 );
    end;
  end;
  CloseHandle( FProcess );
  FProcess          := 0;

  //  a terminated app never removes its advertisement; one that closed itself did, through the server's Stop
  if not Result and ( FDiscoveryDir <> '' ) then
  begin
    var sFile       := TPath.Combine( FDiscoveryDir, Format( '%d.json', [ FEndpoint.Pid ] ) );
    if TFile.Exists( sFile ) then
      try
        TFile.Delete( sFile );
      except
        on EInOutError do ; // already swept by another reader
        on EOSError do ;
      end;
  end;

end;

function TAutomationApp.Request( const ACmd, AForm, AName: string ): TJSONObject;
begin

  Result            := TJSONObject.Create;
  Result.AddPair( 'cmd', ACmd );
  if AForm <> '' then
    Result.AddPair( 'form', AForm );
  if AName <> '' then
    Result.AddPair( 'name', AName );

end;

function TAutomationApp.Call( ARequest: TJSONObject; AReadTimeoutMs: Integer ): TJSONObject;
begin

  var sReply        := '';
  try
    if not TAutomationDiscovery.Send( FEndpoint, ARequest, sReply, AReadTimeoutMs ) then
      raise EAutomationClientError.CreateFmt( '%s ( pid %d ): %s', [ FEndpoint.App, FEndpoint.Pid, sReply ] );
  finally
    ARequest.Free;
  end;

  var oValue        := TJSONObject.ParseJSONValue( sReply );
  if oValue is not TJSONObject then
  begin
    oValue.Free;
    raise EAutomationClientError.CreateFmt( 'not a JSON object: %s', [ Copy( sReply, 1, 200 ) ] );
  end;
  try
    var oReply      := TJSONObject( oValue );
    if not ( oReply.GetValue( 'ok' ) is TJSONTrue ) then
      raise ReplyError( oReply );
    var oResult     := oReply.GetValue( 'result' );
    if oResult is TJSONObject then
      Result        := TJSONObject( oResult.Clone )
    else
      Result        := TJSONObject.Create;
  finally
    oValue.Free;
  end;

end;

function TAutomationApp.CallField( ARequest: TJSONObject; const AField: string ): string;
begin

  var oResult       := Call( ARequest );
  try
    Result          := ValueText( oResult.GetValue( AField ) );
  finally
    oResult.Free;
  end;

end;

function TAutomationApp.GetProp( const AForm, AName, AProp: string ): string;
begin

  var oReq          := Request( 'get', AForm, AName );
  oReq.AddPair( 'prop', AProp );
  Result            := CallField( oReq, 'value' );

end;

function TAutomationApp.SetProp( const AForm, AName, AProp, AValue: string ): Boolean;
begin

  var oReq          := Request( 'set', AForm, AName );
  oReq.AddPair( 'prop', AProp );
  oReq.AddPair( 'value', AValue );
  //  the server leaves 'changed' out when it could not read the old value: unknown counts as changed, so
  //  False keeps its one meaning, "it already held that value"
  Result            := not SameText( CallField( oReq, 'changed' ), 'false' );

end;

procedure TAutomationApp.Click( const AForm, AName: string; ACount: Integer );
begin

  var oReq          := Request( 'click', AForm, AName );
  if ACount <> 1 then
    oReq.AddPair( 'count', TJSONNumber.Create( ACount ) );
  var oResult       := Call( oReq );
  try
    //  the server catches a raising handler and reports it in the result, not as an error
    var sStopped    := ValueText( oResult.GetValue( 'stoppedReason' ) );
    if sStopped <> '' then
      raise EAutomationCommandError.CreateReply( 'HandlerRaised',
        Format( '%s: %s', [ sStopped, ValueText( oResult.GetValue( 'stoppedMessage' ) ) ] ), oResult.ToJSON );
  finally
    oResult.Free;
  end;

end;

procedure TAutomationApp.ClickAsync( const AForm, AName: string );
begin

  var oReq          := Request( 'click', AForm, AName );
  oReq.AddPair( 'mode', 'message' );
  Call( oReq ).Free;

end;

procedure TAutomationApp.ExecuteAction( const AForm, AName: string );
begin

  Call( Request( 'action', AForm, AName ) ).Free;

end;

procedure TAutomationApp.SendKeys( const AForm, AName, AText, AKeys: string );
begin

  var oReq          := Request( 'keys', AForm, AName );
  if AText <> '' then
    oReq.AddPair( 'text', AText );
  if AKeys <> '' then
    oReq.AddPair( 'keys', AKeys );
  if AName <> '' then
    oReq.AddPair( 'focus', TJSONBool.Create( True ) );
  Call( oReq ).Free;

end;

function TAutomationApp.ModalDialogs: TJSONObject;
begin

  var oReq          := Request( 'dialogs', '', '' );
  oReq.AddPair( 'modalOnly', TJSONBool.Create( True ) );
  Result            := Call( oReq );

end;

function TAutomationApp.ClickDialogButton( const ACaption: string ): string;
begin

  var oReq          := Request( 'dialogs', '', '' );
  oReq.AddPair( 'button', ACaption );
  Result            := CallField( oReq, 'outcome' );

end;

function TAutomationApp.FieldGet( const AForm, ADataSet, AField: string ): string;
begin

  var oReq          := Request( 'field_get', AForm, ADataSet );
  oReq.AddPair( 'field', AField );
  Result            := CallField( oReq, 'value' );

end;

procedure TAutomationApp.FieldSet( const AForm, ADataSet, AField, AValue: string );
begin

  var oReq          := Request( 'field_set', AForm, ADataSet );
  oReq.AddPair( 'field', AField );
  oReq.AddPair( 'value', AValue );
  Call( oReq ).Free;

end;

procedure TAutomationApp.DatasetOp( const AForm, ADataSet, AOp: string );
begin

  var oReq          := Request( 'dataset_op', AForm, ADataSet );
  oReq.AddPair( 'op', AOp );
  Call( oReq ).Free;

end;

function TAutomationApp.WaitForProp( const AForm, AName, AProp, AExpected: string; ATimeoutMs: Integer ): Boolean;
begin

  var rWatch        := TStopwatch.StartNew;
  repeat
    //  each poll waits no longer than what is left, so a busy app cannot stretch a short wait to the read time-out
    var iLeft       := Max( 1, Min( Int64( AUTOMATION_READ_TIMEOUT_MS ), Int64( ATimeoutMs ) - rWatch.ElapsedMilliseconds ) );
    var oReq        := Request( 'get', AForm, AName );
    oReq.AddPair( 'prop', AProp );
    try
      var oResult   := Call( oReq, Integer( iLeft ) );
      try
        if ValueText( oResult.GetValue( 'value' ) ) = AExpected then
          Exit( True );
      finally
        oResult.Free;
      end;
    except
      //  only "not there yet" is waited out: a form or component that may still appear. Any other error
      //  ( a bad property, a refused token ) will never become the value, and is raised at once.
      on E: EAutomationCommandError do
        if not ( SameText( E.Code, 'NoForm' ) or SameText( E.Code, 'NoComp' ) ) then
          raise;
      //  a poll cut short only because the time ran out is the time-out, not a failure
      on EAutomationClientError do
        if rWatch.ElapsedMilliseconds >= ATimeoutMs then
          Exit( False )
        else
          raise;
    end;
    Sleep( POLL_INTERVAL_MS );
  until rWatch.ElapsedMilliseconds >= ATimeoutMs;
  Result            := False;

end;

function TAutomationApp.Screenshot( const AForm, AName, APath: string ): string;
begin

  var oReq          := Request( 'screenshot', AForm, AName );
  oReq.AddPair( 'path', APath );
  Result            := CallField( oReq, 'path' );

end;

end.
