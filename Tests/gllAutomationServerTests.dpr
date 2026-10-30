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

program gllAutomationServerTests;

{$APPTYPE CONSOLE}

{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  Vcl.Forms,
  Vcl.Themes,
  Vcl.Styles,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  TestGllAutomationServer in 'TestGllAutomationServer.pas',
  gllIdeAutomation.Rules in '..\gllIdeAutomation\src\gllIdeAutomation.Rules.pas',
  TestGllIdeAutomationRules in 'TestGllIdeAutomationRules.pas',
  TestGllAutomationClient in 'TestGllAutomationClient.pas';

// The project resource carries the embedded VCL style; without it the runner stops with exit code 251.
{$R *.res}

var
  Runner: ITestRunner;
  Results: IRunResults;
  Logger: ITestLogger;
  NUnitLogger: ITestLogger;
begin
  // Started by the client tests as their target app: run as that, not as the suite.
  if RunClientTargetIfAsked then
    Exit;
  try
    // The keys tests post messages to Application.Handle; make sure the VCL application exists.
    Application.Initialize;
    // A suite that puts a form or control on screen runs under the estate's VCL style (Ian, 2026-10-23), so the tests
    // meet the UI as it presents in use.  The .dproj embeds Aqua Light Slate; the lines below activate it.
    // TrySetStyle runs without its error dialog, which would hang an unattended run on a modal; a style that is
    // not linked stops the run with 251 (the runner-failed exit code) rather than letting it run unstyled.
    if not TStyleManager.TrySetStyle( 'Aqua Light Slate', False ) then
    begin
      System.Writeln( 'Aqua Light Slate VCL style is not linked into this runner - UI tests must run styled' );
      Halt( 251 );
    end;
    TStyleManager.UseParentPaintBuffers := True;
    // Check command line options, will exit if invalid
    TDUnitX.CheckCommandLine;
    // Create the test runner
    Runner := TDUnitX.CreateRunner;
    // Tell the runner to use RTTI to find Fixtures
    Runner.UseRTTI := True;
    // String assertions compare case-sensitively; a test that wants case-insensitivity says so explicitly.
    Assert.IgnoreCaseDefault := False;
    // When true, Assertions must be made during tests
    Runner.FailsOnNoAsserts := True;

    // Console logger with verbose output
    Logger := TDUnitXConsoleLogger.Create( True );
    Runner.AddLogger( Logger );
    // Generate an NUnit-compatible XML report
    NUnitLogger := TDUnitXXMLNUnitFileLogger.Create( TDUnitX.Options.XMLOutputFile );
    Runner.AddLogger( NUnitLogger );

    // Run tests
    Results := Runner.Execute;
    if ( not Results.AllPassed ) then
      System.ExitCode := 1;

    {$IFNDEF CI}
    // Pause so the console window stays open when run interactively.
    if TDUnitX.Options.ExitBehavior = TDUnitXExitBehavior.Pause then
    begin
      System.Write( 'Done.. press <Enter> key to quit.' );
      System.Readln;
    end;
    {$ENDIF}
  except
    on E: Exception do
    begin
      System.Writeln( E.ClassName, ': ', E.Message );
      // A runner failure is a failed run, not a green one.
      System.ExitCode := 1;
    end;
  end;
end.
