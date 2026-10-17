import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'android_file_actions.dart';
import 'connection_manager.dart';

export 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';

/// One selection signal for every native entry path (Workspace, Chat, profile).
final nativeAppsTarget = NativeActiveTarget();
final nativeAppsRoutes = NativeTargetRouteObserver(nativeAppsTarget);

/// Dedicated Surfaces namespace: not saved_connections, not connection
/// credentials, and not included in backup export.
const _surfacesStorage = FlutterSecureStorage(
  aOptions: AndroidOptions(
    resetOnError: false,
    storageNamespace: 'hermes_android_surfaces_v1',
  ),
);

/// Projects the immutable snapshot a Workspace/Chat actually uses. Raw values
/// only feed an in-memory hash; nothing here is stored or logged.
NativeOwnerSnapshot nativeAppsOwner(SavedConnection connection) {
  return NativeOwnerSnapshot(
    connectionId: connection.id,
    profileId: connection.gatewayProfile,
    contextFingerprint: nativeContextFingerprint([
      connection.baseUrl,
      connection.gatewayPrefix,
      connection.desktopGatewayUrl,
      connection.dashboardPortOverride,
      connection.dashboardPrefix,
      connection.dashboardProxied,
      connection.gatewayProfile,
      connection.dashboardUsername,
      connection.apiKey,
      connection.dashboardPassword,
    ]),
    displayLabel: connection.label,
  );
}

/// Behind one reverse proxy chat is `<base>/<secret>/gw` and Surfaces
/// `<base>/<secret>/ms`. Only an address to OFFER in the setup dialog; it never
/// carries the API key or any dashboard credential.
String? nativeSurfacesSuggestion(SavedConnection c) {
  final chat = SavedConnection.joinBaseUrl(c.baseUrl, c.gatewayPrefix ?? '');
  if (!chat.endsWith('/gw')) return null;
  return '${chat.substring(0, chat.length - 3)}/ms';
}

/// The Workspace's Apps lifecycle. Everything host-specific lives here; the
/// binding owns route observation, lease renewal and the guarded Chat callback.
NativeAppsBinding createNativeAppsBinding({
  required SavedConnection Function() connection,
  required Future<void> Function() selectChats,
  required Future<void> Function() openBrowser,

  /// Opens a new chat and sends [text] in it as the user's message (after the user confirmed it inside the page's
  /// screen). Null leaves mini-apps without "send to Hermes".
  Future<bool> Function(String text)? startChatWithText,
  HostFileActions? fileActions,
}) {
  late final NativeAppsBinding binding;
  binding = NativeAppsBinding(
    observer: nativeAppsRoutes,
    selectChats: selectChats,
    openBrowser: openBrowser,
    startChatWithText: startChatWithText,
    legacySettingsDirectory: getApplicationSupportDirectory,
    suggestedSurfacesUrl: (_) => nativeSurfacesSuggestion(connection()),
    createController: (owner, lease, openChat) => NativeAssociationController(
      fileActions: fileActions ?? AndroidHostFileActions(),
      sendToHermes: startChatWithText == null
          ? null
          : (text) => binding.startChat(lease, text),
      owner: owner,
      lease: lease,
      mutations: ConnectionManager.nativeMutations,
      readAssociation: (key) => _surfacesStorage.read(key: key),
      writeAssociation: (key, value) =>
          _surfacesStorage.write(key: key, value: value),
      // Fresh committed state, never the widget's own snapshot.
      loadCommittedOwner: () async {
        final preferences = await SharedPreferences.getInstance();
        await preferences.reload();
        final saved = await ConnectionManager(
          preferences,
        ).loadConnectionsWithSecrets();
        final committed = saved.where((c) => c.id == owner.connectionId);
        return committed.isEmpty ? null : nativeAppsOwner(committed.first);
      },
      supportDirectory: getApplicationSupportDirectory,
      loadExistingKey: () async =>
          ApproverKey.loadExisting(await getApplicationSupportDirectory()),
      // Only after the user confirms "connect to <host>" with a code: returns the existing key unchanged.
      createKey: () async =>
          ApproverKey.loadOrCreate(await getApplicationSupportDirectory()),
      createClient: (_) => http.Client(),
      openExistingChat: openChat,
    ),
  );
  return binding;
}
