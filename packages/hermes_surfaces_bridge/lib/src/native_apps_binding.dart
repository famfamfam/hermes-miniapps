import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart' show DiagEntry, SurfacesStrings, SurfacesText;

import 'apps_module.dart';
import 'host_bridge.dart';
import 'native_association_controller.dart';
import 'native_association_dialog.dart';
import 'native_association_signals.dart';
import 'native_legacy_settings.dart';
import 'native_target_routes.dart';

/// Builds the controller for one registered lease. [openChat] is the binding's guarded Chat
/// callback: pass it unchanged as `openExistingChat`. [owner] is the immutable snapshot the host
/// attached (the one the Workspace/Chat actually holds), never a fresher committed one.
typedef NativeControllerFactory =
    NativeAssociationController Function(
      NativeOwnerSnapshot owner,
      NativeTargetLease lease,
      Future<void> Function() openChat,
    );

/// Generic Workspace lifecycle for [NativeAssociationController]: one binding per host State.
///
/// Call [attach] from `didChangeDependencies` and `didUpdateWidget` (idempotent), [dispose] from
/// `State.dispose`. The binding owns the route registration, replaces and disposes the controller
/// whenever the observer issues a NEW lease (first show, Back to a covered route, new snapshot),
/// and provides the guarded Chat callback. A revoked lease is never revived. Without a captured
/// route, a created controller or a current lease the binding does nothing and Chat stays reachable
/// through the host's own navigation.
class NativeAppsBinding extends ChangeNotifier with FrameSafeNotifier {
  NativeAppsBinding({
    required this.observer,
    required this.createController,
    required this.selectChats,
    required this.openBrowser,
    this.legacySettingsDirectory,
    this.suggestedSurfacesUrl,
    this.startChatWithText,
  });

  final NativeTargetRouteObserver observer;

  /// Host: open a NEW chat and send [text] in it as the user's message. Null when the host cannot. Called only
  /// through [startChat], i.e. back at the captured Workspace route and for a lease that is still current.
  final Future<bool> Function(String text)? startChatWithText;
  final NativeControllerFactory createController;

  /// Host: reveal its existing Chats destination (no new chat controller).
  final Future<void> Function() selectChats;

  /// Host: open its existing session browser after Chats was selected.
  final Future<void> Function() openBrowser;

  /// Optional location of the example's legacy `settings.json`; read only after dialog consent.
  final Future<Directory> Function()? legacySettingsDirectory;

  /// Optional host hook: the Surfaces address to OFFER for [owner] (for instance the chat server's
  /// sibling behind one reverse proxy), or null. It is asked once when the setup dialog opens and
  /// must never return a credential. The dialog only copies it into the address field on a tap; a
  /// throwing hook simply means no suggestion.
  final String? Function(NativeOwnerSnapshot owner)? suggestedSurfacesUrl;

  NativeAssociationController? _controller;
  BuildContext? _context;
  Route<dynamic>? _route;
  NativeOwnerSnapshot? _owner;
  VoidCallback? _unregister;
  bool _disposed = false;

  /// Null until the observer has issued a lease, and after detaching.
  NativeAssociationController? get controller => _controller;

  /// Idempotent. Re-registers only when the captured route or the snapshot context changes
  /// (a display-label-only change does not).
  void attach(BuildContext context, NativeOwnerSnapshot owner) {
    if (_disposed) return;
    final route = ModalRoute.of(context);
    if (route != null && identical(route, _route) && owner.sameContext(_owner)) {
      _context = context;
      return;
    }
    _detach();
    _context = context;
    if (route == null) {
      notifyListeners();
      return;
    }
    _route = route;
    _owner = owner;
    _unregister = observer.observe(route, owner, _selected);
  }

  void _selected(NativeTargetLease lease) {
    final route = _route;
    final owner = _owner;
    if (_disposed || route == null || owner == null) return;
    final previous = _controller;
    _controller = null;
    previous?.dispose();
    try {
      _controller = createController(owner, lease, () => _openChat(route, lease));
    } catch (_) {
      _controller = null; // Fail closed; Chat stays available through the host.
    }
    notifyListeners();
  }

  /// The guarded way for a page to start a chat with Hermes: back to the CAPTURED Workspace route (as [_openChat]),
  /// Chats selected, then the host opens a new chat and sends [text]. False when any of that was not possible.
  Future<bool> startChat(NativeTargetLease lease, String text) async {
    final route = _route;
    final start = startChatWithText;
    if (start == null || route == null) return false;
    bool stale() {
      final context = _context;
      return _disposed || context == null || !context.mounted || !route.isActive || !lease.isCurrent;
    }

    if (stale()) return false;
    Navigator.of(_context!).popUntil((candidate) => identical(candidate, route));
    await selectChats();
    if (stale()) return false;
    return start(text);
  }

  Future<void> _openChat(Route<dynamic> route, NativeTargetLease lease) async {
    bool stale() {
      final context = _context;
      return _disposed || context == null || !context.mounted || !route.isActive || !lease.isCurrent;
    }

    if (stale()) return;
    // Back to the CAPTURED Workspace route only, never to the first route of the Navigator.
    Navigator.of(_context!).popUntil((candidate) => identical(candidate, route));
    await selectChats();
    if (stale()) return;
    await openBrowser();
  }

  /// Show the explicit native configuration dialog for the current controller, if any.
  ///
  /// [startWithPaste] opens it already on the "paste connection code" step (see [showNativeAssociationDialog]).
  Future<bool?> configure(BuildContext context, {bool startWithPaste = false}) async {
    final controller = _controller;
    if (controller == null) return null;
    final directory = legacySettingsDirectory;
    String? suggested;
    try {
      suggested = suggestedSurfacesUrl?.call(controller.owner);
    } catch (_) {
      suggested = null; // A host hook must not be able to break the setup.
    }
    return showNativeAssociationDialog(
      context,
      controller: controller,
      legacyPrefill: directory == null ? null : () async => readLegacyExampleSettings(await directory()),
      suggestedUrl: suggested,
      startWithPaste: startWithPaste,
    );
  }

  void _detach() {
    final controller = _controller;
    _controller = null;
    controller?.dispose(); // First: unbinds Apps and drops its target/tracker listeners.
    final unregister = _unregister;
    _unregister = null;
    unregister?.call();
    _route = null;
    _owner = null;
    if (controller != null) notifyListeners(); // The pane drops the disposed controller.
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    closeNotifications();
    _detach();
    _context = null;
    super.dispose();
  }
}

/// Embedded Apps catalogue for [binding]. The module owns the whole header (Chat, refresh,
/// "Set up Surfaces"); this pane only forwards the controller's sanitised, presentation-only
/// signals: why nothing is bound, whether this owner was never configured, and the explicit
/// configuration action (the existing dialog; legacy settings are still read only after consent).
class NativeAppsPane extends StatelessWidget {
  const NativeAppsPane({
    super.key,
    required this.binding,
    this.hostFactory,
    this.previewHostFactory,
    this.surfacePageBuilder,
    this.onDiag,
    this.autoSync = true,
    this.showChat = true,
    this.active = true,
  });

  final NativeAppsBinding binding;

  /// See [AppsModule.active]: false while a tab host keeps the pane mounted but hidden.
  final bool active;

  /// See [AppsModule.showChat]: a tab host has Chat one tap away and drops the header button.
  final bool showChat;
  final HostFactory? hostFactory;
  final HostFactory? previewHostFactory;
  final SurfacePageBuilder? surfacePageBuilder;
  final void Function(String appId, DiagEntry entry)? onDiag;

  /// See [AppsModule.autoSync]; a host can turn background downloads off (for example on a metered link).
  final bool autoSync;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: binding,
      builder: (context, _) {
        final controller = binding.controller;
        if (controller == null) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(SurfacesStrings.of(context)(SurfacesText.paneUnavailable), textAlign: TextAlign.center),
            ),
          );
        }
        // The module itself still listens to the binding; these only refresh its presentation hints.
        return ListenableBuilder(
          listenable: Listenable.merge([controller.notice, controller.activeConnection]),
          builder: (context, _) {
            final notice = controller.notice.value;
            return AppsModule(
              key: ObjectKey(controller),
              bridge: controller,
              embedded: true,
              hostFactory: hostFactory,
              previewHostFactory: previewHostFactory,
              surfacePageBuilder: surfacePageBuilder,
              onDiag: onDiag,
              autoSync: autoSync,
              showChat: showChat,
              active: active,
              onConfigure: () => binding.configure(context),
              onPasteCode: () => binding.configure(context, startWithPaste: true),
              hostNotice: notice == null || notice == NativeAssociationNotice.unconfigured ? null : notice.text,
              hostBusy: notice == null && controller.activeConnection.value == null,
            );
          },
        );
      },
    );
  }
}
