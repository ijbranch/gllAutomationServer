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

program gllAutomationServerTests;

{$APPTYPE CONSOLE}

{$STRONGLINKTYPES ON}

uses
  System.SysUtils,
  Vcl.Forms,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.Xml.NUnit,
  DUnitX.TestFramework,
  TestGllAutomationServer in 'TestGllAutomationServer.pas';

var
  Runner: ITestRunner;
  Results: IRunResults;
  Logger: ITestLogger;
  NUnitLogger: ITestLogger;
begin
  try
    // The keys tests post messages to Application.Handle; make sure the VCL application exists.
    Application.Initialize;
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
