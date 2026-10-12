# gllAutomationServer — Users Guide

How to add the server to an application, start it, and drive it. For every command, field and
error code, see [Help.md](Help.md).

## 1. Add it to an application

1. Build the package (all four modes) and put `D:\gllAutomationServer\37.0\<Platform>\Release` on
   the IDE's library path for Win32 and Win64. Command-line MSBuild reads the library path from
   `%APPDATA%\Embarcadero\BDS\37.0\EnvOptions.proj`, which the IDE rewrites when you change it.
2. Add the unit to the `.dpr`'s uses clause — unconditionally, in every configuration:

   ```pascal
   uses
     ...,
     gllAutomationServer;
   ```

3. Start it on an explicit opt-in, after `Application.Initialize`:

   ```pascal
   if FindCmdLineSwitch( 'AUTOMATION' ) then
     TAutomationServer.Start( 'MyApp' );
   ```

   `'MyApp'` is the name a client finds it by. A host that must not have its idle timers touched
   (the Delphi IDE) passes `False` as a second argument.

Launched without the switch, the application behaves exactly as before: no listener, no file.

## 2. Find and reach a running instance

Each running server writes `C:\ProgramData\GITLAK\Automation\<pid>.json`:

```json
{ "app":"MyApp", "pid":12345, "port":8730, "token":"{…}", "started":"2026-10-13T06:00:00" }
```

Connect to `127.0.0.1:<port>`, send one JSON object per line with the `token`, and read one reply line.
With the `gitlak-mcp` tools this is all done for you: `app_list` finds instances, and every other
`app_*` tool takes a `target` (name or PID).

## 3. Drive it

Read what is on screen, then act on it:

| To | Use |
|---|---|
| See the forms and their components | `tree` (`app_tree`); `deep:true` adds frame and docked controls |
| Read or write a property | `get` / `set` — `Caption`, `Font.Size`, `Lines` |
| Click a button | `click` — `mode:"message"` if the click opens a modal |
| Run a menu or toolbar command | `action` |
| Type, or press a shortcut | `keys` — `text:"ACME"`, `keys:"Ctrl+S Tab"` |
| Answer a modal dialog | `dialogs` — `button:"OK"` |
| Read or edit data | `dataset`, `field_get`, `field_set`, `dataset_op` |
| See it | `screenshot` — `name` or `form` renders just that, correct even when covered; `maxWidth` scales |

### Naming a component

Use its `Name`. If it has none, `tree` shows a synthetic name like `@TButton#2`, and that works too.
If two frames each hold an `edtTown`, the plain name fails with `Ambiguous` and lists the paths that
reach each (`fraAddress.edtTown`); use one of those.

### Testing the user path, not just the data

`set` and `field_set` write the value directly, so the control's `OnExit` validation does not run. To
test what a user would trigger, type and leave the field:

```json
{ "cmd":"keys", "name":"edtQty", "text":"12", "keys":"Tab" }
```

### When a modal dialog opens

A `click` in the default mode waits for its handler, so a handler that opens a modal blocks the
call. Use `mode:"message"`, then answer the dialog with `dialogs`. `keys` stops on its own when a
keystroke opens a modal (`stoppedReason:"modal"`) and sends nothing behind it.

## 4. Add a command of your own

```pascal
TAutomationServer.RegisterCommand( 'myapp_jobs',
  function( ARequest: TJSONObject ): TJSONValue
  begin
    var oForm := TAutomationServer.ResolveForm( ARequest );
    Result := TJSONObject.Create.AddPair( 'form', oForm.Name );
  end );
```

Raise `EAutoError.CreateCode( 'MyCode', 'message' )` to fail with a code of your own. Use
`actWorkerThread` for a handler that has to wait for the main thread to do something.

## 5. Troubleshooting

- **`ping` reports an old `server` version.** The application linked an old DCU. Rebuild this package,
  then the application, and check nothing else on the library path holds a `gllAutomationServer.dcu`.
- **A command never returns.** A native dialog (a `TaskDialog`, a EurekaLog box) is blocking the main
  thread. `dialogs` and `screenshot` still work: use them to see and answer it.
- **A click "worked" but EurekaLog showed nothing.** `click` in `direct` mode catches the handler's
  exception itself. Use `mode:"message"` to send the exception down the application's real path.
