import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'api.dart';
import 'bundle_store.dart';
import 'strings.dart' show SurfacesText;

/// The phone's approver identity: an Ed25519 key that never leaves the device.
///
/// The server stores only the public half. An approval is a signature over a message that names
/// the app, the build, the draft revision, the bundle digest and a one-time nonce
/// (`plugin/mobile_surfaces_core/approval.py`), so nothing on the server can produce one and a
/// signature for one build cannot publish another.
class ApproverKey {
  ApproverKey._(this._keyPair, this.publicKeyBase64);

  final SimpleKeyPair _keyPair;
  final String publicKeyBase64;

  static final Ed25519 _algo = Ed25519();

  /// Deterministic: the same seed always gives the same key (used by tests and by the persisted file).
  static Future<ApproverKey> fromSeed(Uint8List seed) async {
    if (seed.length != 32) throw ArgumentError('seed must be 32 bytes');
    final pair = await _algo.newKeyPairFromSeed(seed);
    final pub = await pair.extractPublicKey();
    return ApproverKey._(pair, base64Encode(pub.bytes));
  }

  /// Loads only an existing identity. An upgraded host must not silently replace a missing key.
  static Future<ApproverKey?> loadExisting(Directory dir) async {
    final file = File('${dir.path}/approver_ed25519.key');
    if (!await file.exists()) return null;
    try {
      final bytes = base64Decode((await file.readAsString()).trim());
      if (bytes.length != 32) throw const FormatException();
      return await fromSeed(Uint8List.fromList(bytes));
    } on FormatException {
      throw ApprovalFailure(
        'The saved approval key is damaged. Pairing was not redone.',
        key: SurfacesText.approvalKeyCorrupt,
      );
    } on FileSystemException {
      throw ApprovalFailure('Could not read the saved approval key.', key: SurfacesText.approvalKeyUnreadable);
    }
  }

  /// Loads the key stored in [dir], creating it on first use. The file lives in the app's private
  /// storage; the server and any process on it cannot read it.
  static Future<ApproverKey> loadOrCreate(Directory dir) async {
    final file = File('${dir.path}/approver_ed25519.key');
    if (await file.exists()) {
      final bytes = base64Decode((await file.readAsString()).trim());
      return fromSeed(Uint8List.fromList(bytes));
    }
    final seed = Uint8List.fromList(await _algo.newKeyPair().then((p) => p.extractPrivateKeyBytes()));
    await dir.create(recursive: true);
    await file.writeAsString(base64Encode(seed), flush: true);
    return fromSeed(seed);
  }

  Future<String> sign(String message) async {
    final sig = await _algo.sign(utf8.encode(message), keyPair: _keyPair);
    return base64Encode(sig.bytes);
  }
}

/// Exactly what the server verifies. Fixed order, one field per line, no trailing newline.
String canonicalApprovalMessage({
  required String appId,
  required String buildId,
  required int draftRev,
  required String bundleId,
  required int baseRevision,
  required String nonce,
}) =>
    [
      'ms-approve-v1',
      'app:$appId',
      'build:$buildId',
      'draftRev:$draftRev',
      'bundle:$bundleId',
      'base:$baseRevision',
      'nonce:$nonce',
    ].join('\n');

/// What the phone signs to delete a published app (`canonical_delete_message` on the server). It has its
/// own first line, so a signature made for a publication can never be taken for a deletion.
String canonicalDeleteMessage({
  required String appId,
  required int revision,
  required String bundleId,
  required String nonce,
}) =>
    [
      'ms-delete-v1',
      'app:$appId',
      'revision:$revision',
      'bundle:$bundleId',
      'nonce:$nonce',
    ].join('\n');

/// A build the author submitted and the user has not yet decided on.
class PreviewSummary {
  PreviewSummary({
    required this.appId,
    required this.title,
    required this.draftRev,
    required this.buildId,
    required this.baseRevision,
    required this.isNew,
  });

  final String appId;
  final String title;
  final int draftRev;
  final String buildId;
  final int baseRevision;
  final bool isNew;

  static PreviewSummary? tryParse(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final appId = raw['appId'], title = raw['title'], rev = raw['draftRev'], build = raw['buildId'];
    final base = raw['baseRevision'], isNew = raw['isNew'];
    if (appId is! String || !isValidAppId(appId)) return null;
    if (title is! String || rev is! int || build is! String || base is! int || isNew is! bool) return null;
    return PreviewSummary(appId: appId, title: title, draftRev: rev, buildId: build, baseRevision: base, isNew: isNew);
  }
}

class ApprovalFailure implements Exception {
  ApprovalFailure(this.message, {this.key});

  /// English diagnostic text; interfaces show the localized text for [key] when there is one.
  final String message;
  final SurfacesText? key;
  @override
  String toString() => message;
}

/// Pairing, listing and deciding previews. UI-free so it can be tested.
class ReviewClient {
  ReviewClient(this.api, this.key);

  final SurfacesApi api;
  final ApproverKey key;

  /// Registers this phone as the approver if the server has none. Returns whether it is paired
  /// with *this* key afterwards (a server paired with another device answers 409).
  Future<bool> pair() async {
    try {
      await api.pair(deviceId: api.config.deviceId, publicKeyBase64: key.publicKeyBase64);
      return true;
    } on ApiException catch (e) {
      if (e.status == 409) return false;
      rethrow;
    }
  }

  Future<List<PreviewSummary>> previews() async => api.previews();

  /// Publishes what the user was looking at, if and only if every challenge field and the message
  /// name that installed preview. A menu's listing entry is never an authority for approval.
  Future<int> approve(InstalledApp shown) async {
    final preview = shown.preview;
    if (preview == null) {
      throw ApprovalFailure(
        'There is no build data to approve. Open the preview again.',
        key: SurfacesText.approvalNoBuildApprove,
      );
    }
    final ch = await api.challenge(shown.appId);
    ApprovalFailure damaged() => ApprovalFailure('the server reply is damaged', key: SurfacesText.approvalReplyDamaged);
    String text(String k) => ch[k] is String ? ch[k] as String : throw damaged();
    int number(String k) => ch[k] is int ? ch[k] as int : throw damaged();

    final expected = canonicalApprovalMessage(
      appId: shown.appId,
      buildId: preview.buildId,
      draftRev: shown.revision,
      bundleId: shown.bundleId,
      baseRevision: preview.baseRevision,
      nonce: text('nonce'),
    );
    if (text('message') != expected ||
        text('appId') != shown.appId ||
        text('buildId') != preview.buildId ||
        number('draftRev') != shown.revision ||
        text('bundleId') != shown.bundleId ||
        number('baseRevision') != preview.baseRevision) {
      throw ApprovalFailure(
        'The build on the server changed after you viewed it. Open the preview again.',
        key: SurfacesText.approvalBuildChanged,
      );
    }
    final signature = await key.sign(expected);
    final out = await api.approve(shown.appId, buildId: preview.buildId, nonce: text('nonce'), signature: signature);
    return (out['revision'] as int?) ?? 0;
  }

  Future<void> reject(InstalledApp shown) async {
    final preview = shown.preview;
    if (preview == null) {
      throw ApprovalFailure(
        'There is no build data to reject. Open the preview again.',
        key: SurfacesText.approvalNoBuildReject,
      );
    }
    await api.reject(shown.appId, buildId: preview.buildId);
  }

  /// Deletes the app whose [revision] the user saw in the list, if and only if the challenge names exactly
  /// that app and revision; the bundle comes from the challenge and is covered by the signature.
  Future<void> deleteApp(String appId, {required int revision}) async {
    final ch = await api.deleteChallenge(appId);
    ApprovalFailure damaged() => ApprovalFailure('the server reply is damaged', key: SurfacesText.approvalReplyDamaged);
    String text(String k) => ch[k] is String ? ch[k] as String : throw damaged();
    int number(String k) => ch[k] is int ? ch[k] as int : throw damaged();

    final expected = canonicalDeleteMessage(
      appId: appId,
      revision: revision,
      bundleId: text('bundleId'),
      nonce: text('nonce'),
    );
    if (text('message') != expected || text('appId') != appId || number('revision') != revision) {
      throw ApprovalFailure(
        'The app changed on the server after you opened the list. Refresh the list and try again.',
        key: SurfacesText.approvalDeleteChanged,
      );
    }
    await api.deleteApp(appId, nonce: text('nonce'), signature: await key.sign(expected));
  }
}
