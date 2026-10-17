import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';
import 'package:http/http.dart' as http;

import 'support.dart';

NativeOwnerSnapshot nativeOwner({
  String id = 'synthetic_connection',
  String? profile = 'synthetic_profile',
  String endpoint = 'https://chat.synthetic.invalid',
  String routes = '/gateway',
  String apiKey = 'synthetic_gateway_key',
  String dashboard = 'synthetic_dashboard_password',
  String label = 'Synthetic connection',
}) => NativeOwnerSnapshot(
  connectionId: id,
  profileId: profile,
  contextFingerprint: nativeContextFingerprint([endpoint, routes, apiKey, dashboard]),
  displayLabel: label,
);

NativeAssociationSettings nativeSettings({
  String url = 'https://synthetic.invalid/tenant',
  String bearer = 'synthetic_surfaces_bearer',
  String device = 'explicit_synthetic_device',
  bool strict = true,
  bool seal = true,
}) => NativeAssociationSettings(
  baseUri: Uri.parse(url),
  bearer: bearer,
  deviceId: device,
  strictNetworkBlock: strict,
  sealNetwork: seal,
);

Map<String, dynamic> associationJson(NativeOwnerSnapshot owner, {NativeAssociationSettings? settings}) {
  final value = settings ?? nativeSettings();
  return {
    'version': 1,
    'connectionId': owner.connectionId,
    'profileId': owner.profileId,
    'contextFingerprint': owner.contextFingerprint,
    'generation': 'synthetic_persisted_generation',
    'baseUri': value.baseUri.toString(),
    'bearer': value.bearer,
    'deviceId': value.deviceId,
    'strictNetworkBlock': value.strictNetworkBlock,
    'sealNetwork': value.sealNetwork,
  };
}

/// Entirely synthetic callback fixture; never a secure-storage plugin or real identity.
class NativeHarness {
  NativeHarness({NativeOwnerSnapshot? snapshot, this.root}) : owner = snapshot ?? nativeOwner() {
    committedOwner = owner;
    target.select(owner);
  }

  final NativeOwnerSnapshot owner;
  final Directory? root;
  final target = NativeActiveTarget();
  final mutations = NativeMutationTracker();
  final Map<String, String> storage = {};
  final List<String> reads = [];
  final List<(String, String)> writes = [];
  final List<NativeAssociationController> controllers = [];
  final List<FakeClient> clients = [];
  final server = SyntheticServer();
  NativeOwnerSnapshot? committedOwner;
  Future<String?> Function(String)? read;
  Future<void> Function(String, String)? write;
  Future<NativeOwnerSnapshot?> Function()? committed;
  Future<Directory> Function()? support;
  Future<ApproverKey?> Function()? key;

  /// Creates the approver key for a connection code; null leaves the controller without that ability.
  Future<ApproverKey> Function()? createKey;
  int keyCreations = 0;
  http.Client Function(SurfacesConnection)? client;
  Future<void> Function()? chat;
  int committedReads = 0;
  int supportReads = 0;
  int keyReads = 0;
  int chatCalls = 0;

  void seed({NativeOwnerSnapshot? forOwner, NativeAssociationSettings? settings}) {
    final snapshot = forOwner ?? owner;
    storage[nativeAssociationStorageKey(snapshot.connectionId)] = jsonEncode(
      associationJson(snapshot, settings: settings),
    );
  }

  NativeAssociationController make({
    NativeOwnerSnapshot? snapshot,
    NativeTargetLease? lease,
    Future<void> Function()? openChat,
    HostFileActions? fileActions,
    SendToHermes? sendToHermes,
  }) {
    final controller = NativeAssociationController(
      fileActions: fileActions,
      sendToHermes: sendToHermes,
      owner: snapshot ?? owner,
      lease: lease ?? target.current!,
      mutations: mutations,
      readAssociation: (key) async {
        reads.add(key);
        return read == null ? storage[key] : await read!(key);
      },
      writeAssociation: (key, value) async {
        writes.add((key, value));
        if (write == null) {
          storage[key] = value;
        } else {
          await write!(key, value);
        }
      },
      loadCommittedOwner: () async {
        committedReads++;
        return committed == null ? committedOwner : await committed!();
      },
      supportDirectory: () async {
        supportReads++;
        return support == null ? root ?? Directory('unused_synthetic_support') : await support!();
      },
      loadExistingKey: () async {
        keyReads++;
        return key == null ? null : await key!();
      },
      createKey: createKey == null
          ? null
          : () {
              keyCreations++;
              return createKey!();
            },
      createClient: (connection) {
        if (client != null) return client!(connection);
        final result = FakeClient(connection, server.respond);
        clients.add(result);
        return result;
      },
      openExistingChat:
          openChat ??
          () async {
            chatCalls++;
            if (chat != null) await chat!();
          },
    );
    controllers.add(controller);
    return controller;
  }

  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    target.dispose();
    mutations.dispose();
  }
}

Future<void> flushNative() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
