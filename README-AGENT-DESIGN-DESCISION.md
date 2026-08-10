## Gesamturteil

Der PoC ist ein brauchbarer technischer Spike für `launchd` und XPC, aber noch keine produktionsfähige Architektur. Für eine direkte Developer-ID-Distribution ist das Konzept tragfähig. Für die Mac-App-Store-Version ist der geplante Ablauf „Deployment-Server → App lädt Agent → App installiert Agent“ ein Blocker.

### Wesentliche Befunde

1. **App-Store-App darf den externen Agent nicht herunterladen oder installieren.**

   Apple verlangt, dass Store-Apps selbständig bleiben und keine zusätzlichen ausführbaren Komponenten herunterladen oder installieren. Das gilt auch dann, wenn der Agent signiert und notarisiert ist. Die App darf höchstens eine Webseite oder separate Installer-App öffnen. Sie kann anschließend mit einem bereits installierten Agent kommunizieren. Siehe [App Review Guidelines 2.4.5 und 2.5.2](https://developer.apple.com/app-store/review/guidelines/).

   Konsequenz:

   - Developer-ID-Version: automatisierte Agent-Installation und Updates grundsätzlich möglich.
   - App-Store-Version: Download und Installation müssen außerhalb der Store-App stattfinden.
   - Eine App-Store-Freigabe bleibt eine Review-Entscheidung; ein für Kernfunktionen zwingend notwendiger externer Agent erhöht das Risiko.

2. **Der XPC-Dienst akzeptiert gegenwärtig jeden lokalen Client.**

   In [MCPStudioLaunchAgentService.swift](/Users/eofmc/EoF/mcpstudio/MCPStudio_LaunchAgent/Sources/MCPStudioLaunchAgent/MCPStudioLaunchAgentService.swift:54) wird derzeit jede Verbindung angenommen. Sobald `performTask` später Programme ausführen kann, könnte jeder Prozess des Benutzers den Agent als Confused Deputy missbrauchen.

   Vor Produktivbetrieb müssen beide Seiten ihre Signaturen prüfen:

   - Agent akzeptiert nur `org.eof.tools.MCPStudio`, Team `83NQU389JN`.
   - MCP Studio akzeptiert nur den festgelegten Agent-Identifier desselben Teams.
   - `setCodeSigningRequirement(_:)` muss vor `resume()` gesetzt werden. Apple empfiehlt genau diesen Mechanismus für XPC-Clients und -Server: [NSXPCConnection](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement%28_%3A%29), [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements).

3. **Der Mach-Service benötigt das App-Group-Präfix.**

   Der ursprüngliche PoC verwendete einen generischen Service-Namen ohne App-Group-Präfix. Die Identifier-Integration verwendet nun in [Identity.swift](/Users/eofmc/EoF/mcpstudio/MCPStudio_LaunchAgent/Sources/MCPStudioLaunchAgent/Identity.swift:3) und der [launchd-plist](/Users/eofmc/EoF/mcpstudio/MCPStudio_LaunchAgent/LaunchAgents/org.eof.tools.MCPStudio.LaunchAgent.plist.template:17) den kanonischen Namen:

   MCP Studio hat bereits die App Group `group.org.eof.apps`. Der kanonische Service-Name lautet:

   ```text
   group.org.eof.apps.mcpstudio.agent
   ```

   Damit ist XPC ausdrücklich auch zwischen einer sandboxed App und einem nicht-sandboxed Prozess vorgesehen. Entscheidend sind App-Group-basierter Dienstname und Signaturprüfung. Siehe [App Groups Entitlement](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.application-groups).

4. **Die gegenwärtige Distribution ist nur für Entwicklung geeignet.**

   `install.sh` baut `.build/debug/MCPStudioLaunchAgent`. Das lokale Entwicklungs-Binary ist:

   - ad-hoc signiert,
   - ohne Team Identifier,
   - ohne stabilen Signing Identifier,
   - nur `arm64`,
   - nicht notarisiert.

   Für den Deployment-Server braucht es ein Developer-ID-signiertes, gehärtetes und notarisiertes Release-Artefakt mit stabiler Produktidentität. Der Server sollte zusätzlich eine signierte Manifestdatei mit Version, Protokollversion, Mindest-App-Version, SHA-256 und Rollback-Regeln liefern.

5. **Die moderne Produktstruktur sollte `SMAppService` verwenden.**

   Statt Binary und plist lose nach `~/Library` zu kopieren, sollte eine separate, signierte „EoF MCP Studio Launch Agent“-App Eigentümer des Agenten sein:

   ```text
   EoF MCP Studio Launch Agent.app
   ├── Contents/Library/LaunchAgents/<label>.plist
   └── Contents/Resources/MCPStudioLaunchAgent
   ```

   Die plist verwendet `BundleProgram`; Registrierung und Status laufen über `SMAppService.agent(plistName:)`. Diese Struktur schützt Binary und plist gemeinsam durch die Bundle-Signatur und macht den Anbieter in „Systemeinstellungen → Anmeldeobjekte“ sichtbar. Apple zeigt diese Architektur in [Updating your app package installer](https://developer.apple.com/documentation/ServiceManagement/updating-your-app-package-installer-to-use-the-new-service-management-api).

6. **Der Agent läuft unnötig permanent.**

   [RunAtLoad und KeepAlive](/Users/eofmc/EoF/mcpstudio/MCPStudio_LaunchAgent/LaunchAgents/org.eof.tools.MCPStudio.LaunchAgent.plist.template:23) sind zusammen redundant. `MachServices` ermöglicht bedarfsgesteuerten Start. Empfehlenswert:

   - `RunAtLoad` entfernen,
   - `KeepAlive=true` entfernen, sofern keine dauerhafte Hintergrundarbeit nötig ist,
   - `ProcessType=Adaptive` statt `Interactive`,
   - `/tmp`-Logdateien entfernen und ausschließlich Unified Logging verwenden.

7. **Das XPC-Protokoll braucht eine echte Sicherheits- und Kompatibilitätsschicht.**

   `performTask(String)` sollte nicht zum generischen Shell- oder Kommando-Endpunkt ausgebaut werden. Besser:

   - typisierte und erlaubnisgeprüfte Operationen,
   - keine Shell; direkte `Process`-/`posix_spawn`-Aufrufe,
   - Allowlist der ausführbaren Programme,
   - begrenzte Argumente und Umgebungsvariablen,
   - Zeit-, Speicher- und Output-Limits,
   - Abbruch-API,
   - Versions-/Capabilities-Handshake,
   - kompatible Protokollversionen für unabhängige App- und Agent-Updates.

### Empfohlene Zielarchitektur

1. `EoF MCP Studio` im App Store: sandboxed, App Group, XPC-Client, keine Agent-Installation.
2. Separate Developer-ID-/notarisierte `EoF MCP Studio Launch Agent.app`: wird bewusst durch den Benutzer installiert und registriert den LaunchAgent über `SMAppService`.
3. Deployment-Server: verteilt und aktualisiert ausschließlich dieses externe Produkt.
4. Beide Prozesse authentisieren sich gegenseitig über Signing Requirements.
5. XPC verwendet `group.org.eof.apps.mcpstudio.agent`.
6. Die direkte MCP-Studio-Version darf denselben Agent Manager automatisiert installieren; die Store-Version öffnet nur dessen Download-/Installationsseite.

Zusätzlich ist das eingecheckte MCP-Studio-Target aktuell mit `ENABLE_APP_SANDBOX = NO` konfiguriert ([project.pbxproj](/Users/eofmc/EoF/mcpstudio/MCPStudio/MCPStudio.xcodeproj/project.pbxproj:1165)). Für eine tatsächliche App-Store-Konfiguration muss das getrennt korrigiert werden. Das Define `APPSTORE` stimmt außerdem nicht mit den `APPSTORE_DISTRIBUTION`-Abfragen in [UpdateManager.swift](/Users/eofmc/EoF/mcpstudio/MCPStudio/MCPStudio/Core/UpdateManager.swift:13) überein.

Der PoC kompiliert erfolgreich und die plist ist syntaktisch gültig. Ein echter End-to-End-Test mit `launchctl`, sandboxed MCP-Studio-Client, Signaturprüfung und negativem Fremdclient-Test fehlt jedoch noch. Ich habe keine Dateien verändert.

>>>>>>>>>>>>>>>>>>>>>>>>
Der Dienst ist keine zwingende Komponente. Lediglich optional, wenn der User möchte die Privilegien zur Tool-Ausführung zu erhöhen. Dei AppStore App kann lediglich die Problematik de­tek­tie­ren und einen Dialog anzeigen und einen Link auf die EoF MCP Studio Web Site anbieten.
<<<<<<<<<<<<<<<<<<<<<<<<

Damit ist die Grundarchitektur App-Store-tauglich deutlich sauberer. Der kritische Punkt aus dem Review entfällt: Die Store-App lädt oder installiert keinen ausführbaren Code, sondern weist nur auf die optionale Zusatzkomponente hin.

Der vorgesehene Ablauf sollte so definiert werden:

1. Die App-Store-App bleibt vollständig sandboxed und ohne Agent sinnvoll nutzbar.
2. Sie erkennt, dass eine Tool-Ausführung an der Sandbox scheitert oder der optionale XPC-Agent nicht verfügbar ist.
3. Sie zeigt einen erklärenden Dialog.
4. Der Benutzer kann die EoF-MCP-Studio-Webseite im Browser öffnen.
5. Dort lädt und installiert er die separat Developer-ID-signierte und notarisierte Agent-Distribution.
6. Nach Installation erkennt die App den Agent über XPC und bietet die erweiterten Tool-Funktionen an.

Wichtig ist die Formulierung: Der LaunchAgent erhöht keine Unix- oder Root-Privilegien. Er läuft weiterhin mit derselben Benutzeridentität, aber außerhalb der App Sandbox. Treffender wären Bezeichnungen wie:

- „Erweiterte lokale Tool-Ausführung“
- „Tool-Ausführung außerhalb der App Sandbox“
- „Optionale EoF MCP Studio Launch Agent-Komponente“

Die Erkennung sollte zweistufig erfolgen:

- primär über einen XPC-Capability-Handshake mit dem Agent,
- sekundär beim konkreten Sandboxfehler, etwa dem bereits erkannten `xcrun: error: cannot be used within an App Sandbox`.

Dabei sollte der Dialog zwischen drei Zuständen unterscheiden:

- Agent nicht installiert,
- Agent installiert, aber in den Anmeldeobjekten deaktiviert,
- Agent vorhanden, aber inkompatible Protokollversion.

Der Deployment-Server darf die Agent-Distribution bereitstellen und aktualisieren. Bei der App-Store-Ausgabe darf MCP Studio jedoch nur auf die Webseite verlinken; Download, Installation und Agent-Update bleiben außerhalb der Store-App. Die direkt vertriebene MCP-Studio-Ausgabe kann denselben Agent optional komfortabler verwalten.

Die übrigen Reviewpunkte bleiben bestehen: App-Group-basierter Mach-Service, gegenseitige Signaturprüfung, signierte/notarisierte Agent-App mit `SMAppService`, versioniertes XPC-Protokoll sowie typisierte und begrenzte Tool-Aufrufe. Unter diesen Bedingungen ist die Zwei-Produkt-Architektur für den beschriebenen optionalen Anwendungsfall plausibel.
