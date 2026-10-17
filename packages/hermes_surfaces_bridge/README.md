# hermes_surfaces_bridge

Native integration of persistent Apps into an existing Flutter Hermes client. It reuses `hermes_surfaces`; it is **not** a chat client, conversation store, provider SDK or replacement `MaterialApp`.

## Host contract

Implement `HostBridge` and pass it to `AppsModule(bridge: bridge)` inside the application's existing navigator. Use `embedded: true` when the native shell already provides an app bar.

- `activeConnection`: a native `ValueListenable<SurfacesConnection?>`. Replace the immutable snapshot on connection/profile/credential changes. `null` leaves Apps unconfigured and does not prevent opening chat.
- `ServerConfig`: the explicit **Surfaces** endpoint and dedicated phone-service bearer, plus native connection/profile/credential-generation identifiers. Do not substitute a Gateway API key or dashboard cookie. Reverse-proxy base paths are preserved; userinfo, query, fragment and redirects are rejected.
- `applicationSupportDirectory()`: the native storage root. Apps caches live under `surfaces/<opaque versioned scope>`; the host's device ID and approver identity remain outside it.
- `loadApproverKey()`: load an existing identity only, e.g. `ApproverKey.loadExisting(root)`. Missing/failed identity disables decisions, not read-only catalogue/preview access. First-install setup and pairing are explicit native-host actions, never module startup work. Refresh retries a previously missing/failed identity.
- `createSurfacesClient(connection)`: return a **fresh Apps-owned** native HTTP client on every call. Apps closes it. Never return the chat/dashboard/shared client.
- `openChat()`: open the existing upstream chat through its own session/controller/navigation. No LLM request is made by Apps navigation.

The module clears visible state, closes its transports, cancels polling and rejects stale completions synchronously on a binding change. An already-open native Surface route invalidates its renderer permanently, including an A → B → A switch. Cached data from legacy or other-owner directories is not silently adopted or deleted.

## Optional seams

`HostFactory(connection, scopeRoot, preview)` transfers ownership of its returned host/API to Apps. The supplied connection/root already select the published or separate preview namespace; use them and do not return shared resources. Both default and injected APIs are gated before requests and after asynchronous results.

`SurfacePageBuilder` replaces only the renderer; the enclosing native route still guards binding changes. `SurfacePageRequest.preview` receives the actual displayed `InstalledApp`, never the catalogue's listing identity, for approval/rejection.

`appBarActions` and `onDiag(appId, entry)` are optional native-host seams. The module itself does not persist settings, clear snapshots, generate/pair keys or write diagnostic files. Its JS bridge remains `hello`, `hostState`, `query`; no writes, Runs, files or provider calls are added.

## Languages

User-visible text comes from `SurfacesStrings` (package `hermes_surfaces`): English is the source and the fallback, Russian is complete. The language is taken from the host's `Localizations` locale, so the host needs no delegates of ours; an unknown locale shows English. To add a language, add one `catalog` entry with every `SurfacesText` key (a test fails on a missing key or an unfilled placeholder). Logic-layer errors carry a key and an English message; the UI shows the localized text for the key.

## Explicit connection check

The setup dialog has a "Check connection" action. Only when the user taps it, it makes one read-only health request with the typed URL and bearer through a fresh Apps-owned client from `createClient`, closes the client and shows one of three sanitised results. It saves nothing and binds nothing, and the result is discarded if the target changed meanwhile.
## Optional native association facility

A host that has no Surfaces configuration store of its own can reuse `NativeAssociationController`, an implementation of the **unchanged** `HostBridge`, and `showNativeAssociationDialog`. Nothing here depends on a concrete connection model or secure-storage plugin; the host supplies immutable projections and callbacks. It never pairs, creates identity, writes root settings/device ID/seed, migrates a legacy cache or reads a Gateway/dashboard credential into Surfaces.

```dart
final target = NativeActiveTarget();            // one per app, shared by EVERY entry path
final mutations = NativeMutationTracker();      // one per app, shared by manager instances
final observer = NativeTargetRouteObserver(target); // installed once in MaterialApp.navigatorObservers

final controller = NativeAssociationController(
  owner: ownerOfTheChatWidget,    // NativeOwnerSnapshot of the snapshot the Chat/Workspace ACTUALLY holds
  lease: leaseFromTarget,         // lease issued for exactly that snapshot
  mutations: mutations,
  readAssociation: (key) => secureStorage.read(key),            // separate namespace, opaque key
  writeAssociation: (key, value) => secureStorage.write(key, value),
  loadCommittedOwner: () async => projectionOfFreshlyCommittedNativeState(), // null when absent
  supportDirectory: nativeSupportDirectory,
  loadExistingKey: () => ApproverKey.loadExisting(root),        // existing identity ONLY
  createClient: (connection) => http.Client(),                  // fresh Apps-owned client
  openExistingChat: openExistingChat,
);
AppsModule(bridge: controller, embedded: true);
```

Most hosts should not wire the route lifecycle by hand. `NativeAppsBinding` owns it, and `NativeAppsPane` renders it:

```dart
final binding = NativeAppsBinding(
  observer: observer,
  createController: (owner, lease, openChat) => NativeAssociationController(
    owner: owner, lease: lease, mutations: mutations, /* callbacks as above */
    openExistingChat: openChat,          // the binding's guarded Chat callback, unchanged
  ),
  selectChats: selectChatsDestination,   // host: reveal its existing Chats destination
  openBrowser: openSessionBrowser,       // host: open its existing session browser
  legacySettingsDirectory: supportDirectory, // optional; read only after dialog consent
);
// State.didChangeDependencies and didUpdateWidget: binding.attach(context, ownerOfWidgetSnapshot);
// State.dispose: binding.dispose();
// build: NativeAppsPane(binding: binding)
```

### Public contract

| API | Purpose |
|---|---|
| `NativeOwnerSnapshot(connectionId, profileId, contextFingerprint, displayLabel)` | Immutable projection. `sameContext` compares connection ID, exact nullable profile (null and empty differ) and fingerprint; the label is display-only. |
| `nativeContextFingerprint(context)` | Hashes an ordered JSON-compatible endpoint/routes/credential context in memory. Preserves null, empty and field boundaries; the input is never stored or logged. |
| `nativeAssociationStorageKey(connectionId)` | Opaque key in the facility's own namespace. Do not reuse the host's credential schema or backup allowlist. |
| `NativeActiveTarget` | `select(owner)` always revokes the previous lease synchronously (A → B → A never revives A). `selectIfChanged(owner)` keeps only the CURRENT exact same-snapshot lease (nested Chat). `clear()`, `current`, `epoch`, `isCurrent(lease)`. |
| `NativeTargetLease` | `isCurrent` is the cheap late-navigation guard. Revocation is permanent. |
| `NativeTargetRouteObserver` | `observe(route, owner, onSelected)` registers a captured Workspace route once and returns an unregister callback. Revealing a covered route (Back) issues a NEW lease through `onSelected`, which the host must use to dispose the old controller and create a new one for the SAME immutable snapshot. `onSelected` may run synchronously during `didChangeDependencies`; assign state there, do not do async work. Cross-owner and direct entry paths must still call `select`/`clear` themselves before their first await/push. |
| `NativeMutationTracker` | `begin()` returns a `NativeMutationOperation`; `finish(success:)` is balanced and idempotent; `run(body)` wraps a body that throws on failure. BEGIN notifies synchronously, before the first credential-bearing write. Only when nothing is pending does a controller reload, from freshly committed state and never from the last operation's proposed values. `FAILED` is not `COMMITTED`. A read-only/no-op initialize must not begin an operation. |
| `NativeAssociationController` | Implements `HostBridge`; `status` (sanitised message or null); `reload()`; `beginConfiguration()` / `readConfiguration()` / `saveConfiguration()` / `endConfiguration()` / `isConfigurationCurrent()`; `dispose()`. |
| `showNativeAssociationDialog(context, controller:, legacyPrefill:, suggestedUrl:)` | Explicit dialog for the controller's owner only. `suggestedUrl` (optional) adds a "Use the chat server address" button under the address field while the field is empty or different; a tap only copies the text into that field. |
| `NativeAppsBinding(observer, createController, selectChats, openBrowser, legacySettingsDirectory?, suggestedSurfacesUrl?)` | Per-host-State lifecycle. `attach(context, owner)` is idempotent (re-registers only when the captured route or the snapshot context changes; a label-only change does not). Owns observe/unregister, disposes the old controller and creates a new one for every NEW lease, `configure(context)` and the guarded Chat callback. |
| `NativeAppsPane(binding:)` | Controller status plus a configuration action above `AppsModule(embedded: true)`. Unavailable text when no controller exists; Chat stays reachable through the host. |
| `readLegacyExampleSettings(directory)` | Read-only parser of the example's own `settings.json` into `NativeAssociationSettings?` (null when absent; a fixed-message `FormatException` when unreadable). Only the dialog's consent path may call it. |

The Chat callback first checks that the host is mounted, its captured route is still active and its lease is still current, then `popUntil`s the CAPTURED route (never the first route of the Navigator), awaits `selectChats()`, re-checks, then awaits `openBrowser()`. A stale or disposed callback does nothing.

### Guarantees

- **Record**: one versioned record per connection ID in the host-provided secure namespace: exact nullable profile, owner fingerprint, separate Surfaces URL/bearer/device ID/network flags and an opaque association generation that is regenerated on every save. Missing, corrupt, wrong-version, mismatched or invalid-URL records and any storage/readback failure leave Apps unconfigured with a sanitised status; chat stays available. There is no fallback to unverified in-memory credentials.
- **Activation** requires, at the same time: the current target lease, the immutable snapshot the host really uses, a fresh committed owner equal to that snapshot (read before and after the association read) and a valid record. A committed owner that differs from the snapshot the chat still holds keeps Apps disabled until the host really reselects/reopens.
- **Races**: `activeConnection` becomes `null` synchronously before any association load/save or native mutation. Every await re-checks the lease, the controller epoch, the native tracker and disposal. Saves are serialised per connection ID across live controllers, authorised again (lease + committed owner) before the queued write starts, verified by exact readback, and never activate from their own completion; a begun secure write cannot be cancelled, so only a later fresh exact-context read may bind it.
- **Failed save**: that controller stays unbound until an explicit `reload()` or reopen, so a failure is never silently replaced by older state. Other controllers read the durable record afresh once every pending save has settled.
- **Configuration**: `beginConfiguration()` unbinds Apps and returns a token. `readConfiguration()` returns the durable record without binding it and keeps the token. Invalid input keeps the token for correction. `endConfiguration()` (the dialog calls it in `finally`) reloads a still-current token, so cancelling cannot strand a valid host. A target change, native mutation, `reload()` or disposal kills the token permanently, and a stale dialog clears and disables its fields.
- **Proposed address**: `NativeAppsBinding.suggestedSurfacesUrl(owner)` is an optional host hook asked once when the dialog opens (a throwing hook means no suggestion). Behind one reverse proxy a host can return the chat server's sibling address. Tapping the button writes only the address field's text: no save, no request, no bearer, no Device ID, no legacy read, and it clears an earlier check verdict. The hook must never return a credential; the button label does not echo the address.
- **Dialog**: legacy access is an optional `legacyPrefill` callback that runs only after a separate explicit confirmation, never on open, cancel or save; its result is discarded if the target changed meanwhile. Saving needs a second native confirmation naming the connection and profile. The bearer is masked, device ID is explicit input (never generated), errors are sanitised and text controllers are disposed.
- **Frame safety**: `activeConnection.value` and `status.value` change synchronously, but listener notification is deferred to the post-frame callback while the framework is building or unmounting a frame. A selection performed by a route's `didChangeDependencies`, or a controller disposed from `State.dispose`, therefore cannot trigger a `setState` while the tree is locked. Every guard uses the synchronous value, never the notification.
- **Resources**: the existing key is loaded with the supplied callback only; a failure or missing key never blocks the read-only catalogue. A client from `createClient` must be fresh; a reused/shared client is rejected and never closed, a client for a binding that became stale is closed.

### Not covered

The facility cannot see native writes that bypass the host's `NativeMutationTracker`, nor navigation that does not call `select`/`clear`/`observe`; those hooks are the host's responsibility and are where the cheap `epoch`/`isCurrent` guards belong. `NativeTargetRouteObserver` reacts only to `didPop`/`didPush`/`didReplace`/`didRemove` of the exact registered route in a Navigator it is installed on: a route in a nested Navigator without the observer, or a shell destination change that reveals a mounted route without any route event, is not seen, so such a switch to a DIFFERENT owner must call `select`. A switch within the same owner keeps the (still current) lease on purpose.

## Verification and limits

Synthetic tests exercise catalogue/install/offline, Chat/Back callbacks, preview decisions, identity retry, invalid endpoint handling, client ownership, polling and stale results/routes, plus the association facility (record validation, lease/epoch/overlap races, save serialisation, dialog consent and disposal, route observer). They use only fake callbacks and an in-memory store. They do **not** prove a real upstream chat, a real secure-storage plugin, platform WebView network isolation, a phone migration or a live approval cycle. Those remain separate runtime/device acceptance gates.

Run `flutter test` and `flutter analyze` in this package using a compatible SDK. On a Windows environment that prohibits execution-policy bypass, do not invoke a launcher that uses it: a verified SDK's bundled `dart.exe` can invoke its stock `bin/cache/flutter_tools.snapshot` directly for pub/analyze/test, with `FLUTTER_ROOT` set to that SDK. This does not change a launcher or policy. Android Gradle may still invoke `flutter.bat`; direct Dart tests do not prove that the APK build path obeys that restriction.
