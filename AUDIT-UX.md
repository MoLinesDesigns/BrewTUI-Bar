# Auditoría de comportamiento — BrewTUI-Bar

Revisión con el criterio de "qué le pasa realmente al usuario", no de corrección técnica.
Cada hallazgo cita `fichero:línea` sobre el **working tree actual** (hay cambios sin commitear).

**Cobertura**: leídos `AppDelegate`, `AppState`, `InstallProgress(+View)`, `PopoverView`,
`OutdatedListView`, `SettingsView`, el cask del tap y el `package.json` del CLI.
**No cubierto**: `SchedulerService`, `NewPackagesView`, `ServiceDiagnosticsView`,
`BrewChecker`/`BrewProcess`, `LicenseChecker`/`LicenseRevalidator`, los monitores cross-process
y el catálogo `.xcstrings` completo.

---

## 1. El rename sin commitear rompió comandos de terminal que antes funcionaban

El comando real del CLI es **`brewtui-bar`**, todo en minúsculas — confirmado en el `bin` del
paquete npm (`/Volumes/SSD/Projects/BrewTUI-Bar/package.json:6-8`) y en la dependencia del cask
(`Casks/brewtui-bar.rb:10` → `depends_on formula: "brewtui-bar"`).

El diff sin commitear aplicó `brewtui-bar` → `BrewTUI-Bar` de forma indiscriminada, incluyendo
cadenas que son comandos ejecutables:

| Ubicación | Antes (HEAD) | Ahora (sin commitear) | Efecto |
|---|---|---|---|
| `AppDelegate.swift:228,237` | `npm install -g brewtui-bar` | `brew install --cask BrewTUI-Bar` | **Instala la app, no el CLI** |
| `AppDelegate.swift:247,257` | `brewtui-bar install-brewtui-bar --force` | `BrewTUI-Bar install-BrewTUI-Bar --force` | **Subcomando inexistente** |
| `PopoverView.swift:542` | `brewtui-bar activate <key>` | `BrewTUI-Bar activate <key>` | Frágil (ver abajo) |
| `PopoverView.swift:741` | `exec brewtui-bar` | `exec BrewTUI-Bar` | Frágil |
| `PopoverView.swift:765` | `brew upgrade --cask brewtui-bar` | `brew upgrade --cask BrewTUI-Bar` | Frágil |
| `SettingsView.swift:276` | `exec brewtui-bar revalidate` | `exec BrewTUI-Bar revalidate` | Frágil |

Dos categorías distintas:

- **Roto siempre**: `install-BrewTUI-Bar` es un *argumento*, no un nombre de fichero. El CLI lo
  compara como cadena, así que el filesystem no lo rescata. El usuario copia el comando que le
  ofrece la alerta de version mismatch y no funciona.
- **Roto solo a veces**: `exec BrewTUI-Bar` y el token de cask dependen de que el volumen sea
  case-insensitive (el default de macOS, pero no universal). Funcionan en la mayoría de
  máquinas y fallan en las que formatearon en APFS case-sensitive, que es el peor tipo de bug:
  irreproducible para quien lo desarrolla.

El caso de `brew install --cask BrewTUI-Bar` es incorrecto **con independencia de las
mayúsculas**: ese cask es la app (`Casks/brewtui-bar.rb:13` → `app "BrewTUI-Bar.app"`). Se le
dice al usuario que instale la aplicación que ya tiene abierta para resolver la ausencia del
CLI. Ejecuta, brew responde que ya está instalado, relanza y ve la misma alerta.

**Nota**: la colisión *narrativa* de nombres ("BrewTUI-Bar requires BrewTUI-Bar to be
installed") ya existía en HEAD — no la introdujo este cambio. Lo que sí introdujo es la rotura
de los comandos. La sección "Naming" de `CLAUDE.md` quedó además con cuatro viñetas que debían
nombrar entidades distintas y hoy dicen todas lo mismo, así que el documento ya no permite
reconstruir qué nombre iba en cada sitio.

---

## 2. La cuenta atrás de 3 s sobrevive a la vista que la controla

`OutdatedListView.swift:9-10` guarda las cuentas atrás en `@State`:

```swift
@State private var countdownRemaining: [OutdatedPackage.ID: Int] = [:]
@State private var countdownTasks: [OutdatedPackage.ID: Task<Void, Never>] = [:]
```

`AppDelegate.togglePopover` **recrea el `NSHostingController` en cada apertura**
(`AppDelegate.swift:402-409`), lo que destruye ese `@State`. Y no hay `onDisappear` que cancele
las tasks — es deliberado y está documentado en `PopoverView.swift:112-114`.

Secuencia real:

1. Pulsas ↑ en un paquete. Arranca la cuenta atrás de 3 s (`OutdatedListView.swift:160-177`).
2. Haces clic fuera antes de que expire. El popover es `.transient` más un monitor global
   (`AppDelegate.swift:291, 453`), así que se cierra. El `@State` se destruye.
3. **La `Task` sigue viva** y al agotar el bucle ejecuta `await appState.upgrade(package: name)`.

Consecuencias:

- El upgrade arranca aunque el usuario cerró el popover, y el botón de cancelar que existía
  durante esos 3 s ya no está en ninguna parte. **La ventana de arrepentimiento desaparece
  antes de tiempo.**
- Si reabres el popover en ese hueco, la fila muestra el ↑ normal (el nuevo `@State` está
  vacío) mientras por debajo hay un upgrade a punto de dispararse. Volver a pulsarlo arranca
  una **segunda** cuenta atrás para el mismo paquete: dos peticiones idénticas entran en la
  cola de `AppState` (`AppState.swift:311-320`), que no deduplica por nombre.

La cuenta atrás es un mecanismo de confirmación; vivir en el `@State` de una vista que se
destruye sola la convierte en una confirmación que el usuario no puede retirar. Debería vivir
en `AppState`, junto a la cola que ya gestiona los upgrades.

---

## 3. Las alertas de arranque salen antes de que exista el icono en la barra

Orden dentro de `launchTask` (`AppDelegate.swift:49-111`):

1. `checkBrewTUIBarInstalled()` → posible alerta (línea 51)
2. `showVersionMismatch(...)` → alerta modal (línea 61)
3. `showLicenseExpired()` → alerta modal (línea 89)
4. **`setupStatusItem()` (línea 111)** ← el icono aparece aquí

Las tres usan `runModal()` sin `NSApp.activate(...)`. Al ser `LSUIElement` no hay icono en el
Dock, y el ítem de la barra tampoco existe todavía: si la alerta queda detrás de la ventana
activa, el usuario no tiene **ninguna** superficie desde la que llegar a ella y la app parece no
haber arrancado, bloqueada en un modal invisible.

**Arreglo**: `NSApp.activate(ignoringOtherApps: true)` antes de cada `runModal()`, y crear el
status item antes de las dos alertas no bloqueantes (mismatch y licencia).

---

## 4. El modal de instalación no caduca nunca (el caso que reportaste)

`AppState.installProgress` sólo se limpia por acción explícita del usuario
(`AppState.swift:344-347`) y el sheet se presenta siempre que sea no-nil
(`PopoverView.swift:129`).

Como el popover se cierra al primer clic fuera, el camino normal es:

1. Lanzas un upgrade; aparece el modal.
2. Clic fuera; el popover se cierra. El upgrade sigue (correcto y deliberado).
3. Termina. El badge de la barra ya se actualizó.
4. Horas después abres el popover: **reaparece el modal con "Done"** de aquella operación,
   tapando la vista y bloqueando todo hasta que pulses el botón.

El estado terminal no expira. Es además incoherente con el otro canal de la app:
`lastActionMessage` se autodestruye a los 30 s (`AppState.swift:201-206`).

**Arreglo sugerido**: al terminar con éxito y sin cola pendiente, cerrar solo y dejar el
resultado en el banner de `lastActionMessage`, que existe justo para eso. Mantener el modal
pegajoso únicamente cuando `finalError != nil`, que es cuando el usuario sí tiene algo que leer.

---

## 5. Un upgrade fallido borra la lista de paquetes

`PopoverView.swift:73-81` elige el cuerpo así:

```swift
} else if let error = appState.error {
    errorView(error)          // ocupa toda la vista
} else if appState.outdatedPackages.isEmpty {
```

y `AppState.swift:496` escribe en ese mismo `error` cuando falla un upgrade. En fallo no se
refresca (`AppState.swift:530-532`), precisamente para no borrar el mensaje.

Efecto: si falla **un** paquete, al cerrar el modal el popover ya no muestra los otros N
pendientes sino una pantalla de error a página completa. La lista sólo vuelve pulsando "Retry",
que lanza un refresh completo. El fallo de una acción puntual secuestra la vista de estado;
encaja mejor como banner o como estado de la fila afectada.

---

## 6. "Copy Install Command" cierra la app igual

`AppDelegate.swift:233-240`:

```swift
let response = alert.runModal()
if response == .alertFirstButtonReturn { /* copia al portapapeles */ }
NSApp.terminate(nil)
```

Los botones son "Copy Install Command" y "Quit", pero `terminate` corre en ambas ramas. El
usuario copia y la app desaparece sin avisar. O se etiqueta "Copiar y salir", o se ofrece
"Reintentar" tras copiar.

---

## 7. No se puede avisar de paquetes desactualizados sin animación

`shouldAnimateOutdatedIndicator()` (`AppDelegate.swift:304-306`) es
`outdatedCount > 0 && badgePreferences.showOutdated`, y ese es el **único** canal para los
paquetes desactualizados: `updateBadge()` (línea 358-384) sólo añade badges de texto para CVE y
sync.

El toggle de Settings se llama "Blink icon on updates" (`SettingsView.swift:169`), pero apagarlo
no quita solo el parpadeo: elimina cualquier indicación de que hay actualizaciones — incluida la
descripción de accesibilidad (`AppDelegate.swift:346-348`). El usuario elige entre un icono que
parpadea cada 0,55 s indefinidamente o no enterarse.

Además el `Timer` (línea 312) no consulta
`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`. Las vistas SwiftUI sí respetan
`accessibilityReduceMotion` (`InstallProgressView.swift:16, 73, 127, 196`), así que el icono
—la superficie más persistente y la única que el usuario no puede cerrar— es la que lo ignora.

**Arreglo**: separar "avisar" de "animar" (un punto estático o un contador de texto como los de
CVE), y respetar Reduce Motion.

---

## 8. El banner de acciones del CLI expira aunque nadie lo haya visto

`AppState.swift:194-208`: al recibir una acción del CLI se compone el mensaje y se programa su
borrado 30 s después. El temporizador arranca al **recibir**, no al mostrarse.

Como el popover está cerrado casi siempre, lo normal es que el banner nazca y muera sin que el
usuario lo vea. Es el defecto simétrico del punto 4: un canal se descarta demasiado pronto y el
otro no se descarta nunca.

---

## 9. Dos filas contiguas en Settings con etiquetas indistinguibles

`SettingsView.swift:238-241`:

```swift
LabeledContent(String(localized: "BrewTUI-Bar version"), value: bundleVersion)
LabeledContent(String(localized: "BrewTUI-Bar CLI"), value: cli)
```

Una encima de otra, sin nada que indique cuál es la app y cuál el CLI. Es la colisión de nombres
del punto 1 en su forma más visible: justo el sitio donde el usuario mira cuando la app le acaba
de decir que las dos versiones están desincronizadas.

Relacionado: "View logs" (línea 248) abre Console.app sin filtro y el propio comentario admite
que se confía en que el usuario busque "BrewTUI-Bar" — término que ahora no discrimina nada. El
subsystem real es `com.molinesdesigns.brewtuibar`.

---

## 10. La cola de upgrades reemplaza el modal sin transición

`AppState.swift:328-340`: el worker saca la siguiente petición y `runUpgradeStream` hace
`installProgress = InstallProgress(...)` (línea 474), sustituyendo el contenido en el sitio.

Está documentado como deliberado, pero el usuario ve "Done" del paquete A y acto seguido el
mismo modal muestra a B en curso, sin haber confirmado el resultado de A. El badge "+N queued"
(`InstallProgressView.swift:83`) lo insinúa, pero el resultado de cada operación se pierde salvo
que estés mirando en ese instante.

---

## Pendiente de verificar en la app en marcha

Dos cosas que el código sugiere pero que no puedo afirmar sin ejecutarlas:

- **Esc sobre el modal terminado**. El botón Cancel lleva `.keyboardShortcut(.cancelAction)`
  pero sólo existe mientras `!progress.isFinished` (`InstallProgressView.swift:245-254`); al
  terminar desaparece el único `.cancelAction`. Puede que SwiftUI cierre igual vía el binding de
  presentación (cuyo setter permite el cierre con `isFinished`), o puede que Esc deje de hacer
  nada. Merece una comprobación manual.
- **Estado terminal contradictorio al cancelar**. Lo verificado es que ni `finishSuccess` ni
  `finishFailure` (`InstallProgress.swift:123-137`) comprueban si ya había un estado terminal.
  De ahí se *infiere* que un `.success` que llegue después de `cancelInstallProgress`
  (`AppState.swift:355-366`) dejaría la cabecera en "Finished with errors" con motivo
  "Cancelled" sobre paquetes que sí se actualizaron. No he observado la carrera.

---

## Prioridad sugerida

| # | Hallazgo | Severidad |
|---|---|---|
| 1 | Comandos rotos por el rename sin commitear | **Alta** — bloquea recuperación en el primer arranque |
| 2 | Cuenta atrás que sobrevive a su vista | **Alta** — dispara upgrades sin poder cancelarlos |
| 3 | Alertas invisibles antes del status item | **Alta** — la app parece no arrancar |
| 4 | Modal de instalación que no caduca | Media-alta — el caso reportado |
| 5 | Fallo de upgrade borra la lista | Media |
| 7 | Avisar sin animar es imposible + Reduce Motion | Media — accesibilidad |
| 6 | "Copy Install Command" cierra la app | Media |
| 9 | Etiquetas indistinguibles en Settings | Baja-media |
| 8 | Banner que expira sin verse | Baja |
| 10 | Encadenado de modales en cola | Baja |
