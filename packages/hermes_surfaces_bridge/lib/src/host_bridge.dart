import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:http/http.dart' as http;

/// A snapshot of the native connection. Replace it rather than mutating settings.
@immutable
class SurfacesConnection {
  const SurfacesConnection({required this.config, this.strictNetworkBlock = true, this.sealNetwork = true});

  final ServerConfig config;
  final bool strictNetworkBlock;
  final bool sealNetwork;
  String get scope => config.scope;
}

/// Resources owned by the native application, not by Apps.
abstract class HostBridge {
  ValueListenable<SurfacesConnection?> get activeConnection;
  Future<Directory> applicationSupportDirectory();

  /// Load an existing identity only. Missing identity disables decisions; Apps never pairs,
  /// generates keys or writes identity files. Identity storage belongs outside the scope cache.
  Future<ApproverKey?> loadApproverKey();

  /// Return a FRESH Apps-owned client on every call, never the host's shared/chat client.
  /// Apps closes it on binding change or disposal. Preview calls carry config.forPreview().
  http.Client createSurfacesClient(SurfacesConnection connection);
  Future<void> openChat();

  /// Native file pickers and the save / open / share sheet. Null: this host cannot move files, and a page that asks
  /// is told so. (A default, so a bridge that `extends` this class keeps compiling; one that `implements` it
  /// states its answer.)
  HostFileActions? get fileActions => null;

  /// Opens a chat with Hermes and sends [text] as the user's own message (the page's request was already shown to
  /// the user and confirmed). Null: this host cannot. Returns false when the chat could not be started.
  SendToHermes? get sendToHermes => null;
}

/// Optional native/test seam. The connection and root already select the published or preview
/// namespace. The returned host's API transfers ownership to Apps and is closed by Apps.
/// Factories must not return shared APIs/clients; they must use the supplied connection/root.
typedef HostFactory = Future<SurfacesHost> Function(SurfacesConnection connection, Directory scopeRoot, bool preview);

/// Replaces only the page renderer (e.g. to avoid a platform WebView in widget tests).
/// The enclosing route still invalidates and disposes this page on a native binding change.
typedef SurfacePageBuilder = Widget Function(BuildContext context, SurfacePageRequest request);

/// Native page inputs. Preview decisions receive the displayed InstalledApp via PreviewActions;
/// the catalogue's PreviewSummary is deliberately not an approval authority.
@immutable
class SurfacePageRequest {
  const SurfacePageRequest({
    required this.connection,
    required this.host,
    required this.app,
    required this.title,
    required this.openChat,
    this.preview,
    this.onDiag,
    this.fileActions,
    this.sendToHermes,
  });

  final SurfacesConnection connection;
  final SurfacesHost host;
  final InstalledApp app;
  final String title;
  final PreviewActions? preview;
  final void Function(DiagEntry entry)? onDiag;

  /// Bound to this page's original session, like [openChat].
  final HostFileActions? fileActions;
  final SendToHermes? sendToHermes;

  /// Bound to this page's original session; a stale callback never enters the host chat.
  final Future<void> Function() openChat;
}

bool sameConnection(SurfacesConnection? a, SurfacesConnection? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  try {
    return a.scope == b.scope &&
        a.config.deviceId == b.config.deviceId &&
        a.strictNetworkBlock == b.strictNetworkBlock &&
        a.sealNetwork == b.sealNetwork;
  } on ArgumentError {
    return false;
  }
}
