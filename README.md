# EoF MCP Studio Launch Agent

Referenz-Implementierung eines **LaunchAgent in der User-Session** (launchd `gui`-Domain) –
das Gegenstück zum zuvor diskutierten System-Daemon.

## Agent (User-Session) vs. Daemon (System-Kontext)

| | LaunchAgent (`gui/<uid>`) | LaunchDaemon (`system`) |
|---|---|---|
| Identität | eingeloggter Benutzer | root |
| Lebensdauer | nur solange der User eingeloggt ist | unabhängig von Logins |
| Aqua/UI-Zugriff | ja | nein |
| Keychain/Defaults | des Benutzers | System |
| Installation | `~/Library/LaunchAgents`, **kein root nötig** | `/Library/LaunchDaemons`, root nötig |
| App-Store-tauglich | eingeschränkt (s. unten) | nein |

Konsequenz: Alles, was Benutzerkontext braucht (User-Keychain, Session, GUI-Nähe),
gehört in einen Agent – nicht in einen Daemon.

## Aufbau

```
Package.swift                          SwiftPM-Package (Executable)
Sources/MCPStudioLaunchAgent/
  main.swift                           Entry Point, SIGTERM-Handling, XPC-Listener
  Identity.swift                       EoF-Produkt- und IPC-Identifikatoren
  MCPStudioLaunchAgentService.swift    XPC-Protokoll, Service, Listener-Delegate
LaunchAgents/
  org.eof.tools.MCPStudio.LaunchAgent.plist.template
scripts/
  install.sh                           Build + Installation in gui/<uid>
  uninstall.sh                         bootout + Aufräumen
```

Der Agent stellt den XPC-Mach-Service `group.org.eof.apps.mcpstudio.agent` bereit.
launchd registriert den Namen über den `MachServices`-Key im plist im per-user
Mach-Bootstrap; der Agent vendet ihn via `NSXPCListener(machServiceName:)`.

Die Produktidentität folgt dem bestehenden EoF-MCP-Studio-Projekt:

- Host-App: `org.eof.tools.MCPStudio`
- LaunchAgent/Bundle: `org.eof.tools.MCPStudio.LaunchAgent`
- App Group: `group.org.eof.apps`
- Display Name: `EoF MCP Studio Launch Agent`

## Build

```sh
swift build
```

Alternativ steht das native Xcode-Projekt `MCPStudioLaunchAgent.xcodeproj` mit
dem gemeinsam sichtbaren Scheme `MCPStudioLaunchAgent` zur Verfügung. Es enthält
das Command-Line-Tool-Target und das zugehörige XCTest-Target und verwendet die
Team-, Deployment- und Swift-Konventionen des EoF-MCP-Studio-Projekts.

```sh
xcodebuild -list -project MCPStudioLaunchAgent.xcodeproj
xcodebuild \
  -project MCPStudioLaunchAgent.xcodeproj \
  -scheme MCPStudioLaunchAgent \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

Das Xcode-Target bettet die kanonische Bundle-ID und den Display Name als
Info-plist-Sektion in das ausführbare Mach-O ein. Für lokale Builds nutzt Xcode
automatische Signierung mit dem Team `83NQU389JN`; die spätere
Developer-ID-Signierung und Notarisierung bleiben Teil des Distributionsschritts.

## Installation (aktueller Benutzer, ohne sudo)

```sh
scripts/install.sh
```

Das Skript baut das Binary, kopiert es nach
`~/Library/Application Support/org.eof.tools.MCPStudio.LaunchAgent/`, rendert das plist
nach `~/Library/LaunchAgents/` und registriert den Job per
`launchctl bootstrap gui/<uid>`.

## Verifikation

```sh
# Job-Status (pid, state, last exit)
launchctl print "gui/$(id -u)/org.eof.tools.MCPStudio.LaunchAgent"

# Live-Logs des Agenten
log stream --predicate 'subsystem == "org.eof.tools.MCPStudio.LaunchAgent"' --info --debug
```

XPC-Client-Seite (in der Host-App):

```swift
let connection = NSXPCConnection(
    machServiceName: "group.org.eof.apps.mcpstudio.agent",
    options: [] // non-privileged: Service liegt in der gui-Domain
)
connection.remoteObjectInterface = NSXPCInterface(with: MCPStudioLaunchAgentProtocol.self)
connection.resume()
let proxy = connection.remoteObjectProxyWithErrorHandler { error in
    // Fehlerbehandlung
} as? MCPStudioLaunchAgentProtocol
proxy?.ping { reply in print(reply) }
```

Das `@objc`-Protokoll muss auf beiden Seiten identisch deklariert werden
(klassisches XPC-Muster ohne gemeinsames Framework).

## Deinstallation

```sh
scripts/uninstall.sh
```

## App-Store-Hinweis

Ein **extern** installierter Agent in `~/Library/LaunchAgents` ist für eine
Sandboxed-App-Store-App nicht erreichbar:

- Die Sandbox darf nicht nach `~/Library/LaunchAgents` schreiben.
- Der Mach-Lookup auf fremde Services erfordert die Temporary Exception
  `com.apple.security.temporary-exception.mach-lookup.global-name` –
  im App Store praktisch nicht genehmigungsfähig.

Der App-Store-konforme Weg ab macOS 13 ist `SMAppService.agent(plistName:)` mit
einem **im App-Bundle gebündelten** Agenten (`Contents/Library/LaunchAgents`),
Registrierung über die API statt über das Dateisystem. Kommunikation dann über
App-Group-basierte Mach-Services. Diese Variante hier (`scripts/install.sh`) ist
für Distribution **außerhalb** des App Store gedacht (Developer-ID-signiert,
eigener Installer) – analog zur Zwei-Produkt-Strategie beim Daemon, nur ohne root.
