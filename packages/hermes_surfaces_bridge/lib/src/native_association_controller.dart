import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:http/http.dart' as http;

import 'host_bridge.dart';
import 'native_association_signals.dart';

/// Dedicated Surfaces settings, NEVER Gateway/dashboard credentials.
@immutable
class NativeAssociationSettings {
  const NativeAssociationSettings({
    required this.baseUri,
    required this.bearer,
    required this.deviceId,
    this.strictNetworkBlock = true,
    this.sealNetwork = true,
  });

  final Uri baseUri;
  final String bearer;
  final String deviceId;
  final bool strictNetworkBlock;
  final bool sealNetwork;

  /// The Surfaces server pairs and authorizes only `[A-Za-z0-9_-]{1,64}` device ids, so anything else
  /// would save "successfully" and then fail every request (or the pairing) later.
  static bool isValidDeviceId(String value) => RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(value);

  SurfacesConnection _connection(NativeOwnerSnapshot owner, String generation) {
    if (bearer.trim().isEmpty || !isValidDeviceId(deviceId) || RegExp(r'[\x00-\x1f\x7f]').hasMatch(bearer)) {
      throw const FormatException('Invalid Surfaces settings');
    }
    final connection = SurfacesConnection(
      config: ServerConfig(
        baseUri: baseUri,
        token: bearer,
        deviceId: deviceId,
        connectionId: owner.connectionId,
        profileId: owner.profileId,
        credentialGeneration: generation,
      ),
      strictNetworkBlock: strictNetworkBlock,
      sealNetwork: sealNetwork,
    );
    // Reuse the core's HTTP(S), userinfo/query/fragment and scope validation.
    connection.scope;
    return connection;
  }
}

/// A configuration interaction belongs to one controller/selection/native epoch.
@immutable
class NativeAssociationConfiguration {
  const NativeAssociationConfiguration._(this._controller, this._epoch, this.owner);
  final NativeAssociationController _controller;
  final int _epoch;
  final NativeOwnerSnapshot owner;
}

enum NativeAssociationSaveResult { saved, stale, invalid, failed }

/// Outcome of [NativeAssociationController.connectWithCode], as a stable code the UI localizes.
enum NativeClaimResult {
  /// Connected, and this phone's key now confirms publications and deletions.
  connected,

  /// Connected, but another device already confirms them.
  connectedNotApprover,
  invalidCode,
  locked,
  unsupported,
  unreachable,
  stale,
  failed,
}

/// Why Apps is not bound (or what just went wrong), as a stable code: the UI localizes it with
/// [text]; the controller itself never formats user-facing language.
enum NativeAssociationNotice {
  /// A fresh read found no saved association for this owner: first-time setup.
  unconfigured(SurfacesText.noticeUnconfigured),
  targetChanged(SurfacesText.noticeTargetChanged),
  settingsChanging(SurfacesText.noticeSettingsChanging),
  contextMismatch(SurfacesText.noticeContextMismatch),
  readFailed(SurfacesText.noticeReadFailed),
  saveFailed(SurfacesText.noticeSaveFailed),
  invalidSettings(SurfacesText.noticeInvalidSettings),
  ownerUnavailable(SurfacesText.noticeOwnerUnavailable);

  const NativeAssociationNotice(this.text);
  final SurfacesText text;
}

/// Sanitised outcome of [NativeAssociationController.checkConnection]. Carries no URL, token or body.
enum NativeConnectionCheck { reachable, unauthorized, unreachable, invalid, stale }

/// Optional native association facility implementing the UNCHANGED HostBridge.
/// Owns no native chat state, credential schema, identity, pairing or settings files.
class NativeAssociationController extends ChangeNotifier with FrameSafeNotifier implements HostBridge {
  NativeAssociationController({
    required this.owner,
    required this.lease,
    required this.mutations,
    required Future<String?> Function(String key) readAssociation,
    required Future<void> Function(String key, String value) writeAssociation,
    required Future<NativeOwnerSnapshot?> Function() loadCommittedOwner,
    required Future<Directory> Function() supportDirectory,
    required Future<ApproverKey?> Function() loadExistingKey,
    required http.Client Function(SurfacesConnection connection) createClient,
    required Future<void> Function() openExistingChat,
    Future<ApproverKey> Function()? createKey,
    this.fileActions,
    this.sendToHermes,
  }) : _readAssociation = readAssociation,
       _writeAssociation = writeAssociation,
       _loadCommittedOwner = loadCommittedOwner,
       _supportDirectory = supportDirectory,
       _loadExistingKey = loadExistingKey,
       _createClient = createClient,
       _createKey = createKey,
       _openExistingChat = openExistingChat {
    lease.addListener(_targetChanged);
    mutations.addListener(_nativeChanged);
    _associationWrites.addListener(_associationChanged);
    unawaited(reload());
  }

  final NativeOwnerSnapshot owner;
  final NativeTargetLease lease;
  final NativeMutationTracker mutations;
  final Future<String?> Function(String) _readAssociation;
  final Future<void> Function(String, String) _writeAssociation;
  final Future<NativeOwnerSnapshot?> Function() _loadCommittedOwner;
  final Future<Directory> Function() _supportDirectory;
  final Future<ApproverKey?> Function() _loadExistingKey;
  final http.Client Function(SurfacesConnection) _createClient;
  final Future<void> Function() _openExistingChat;

  /// Handed over by the host (the chat client has the pickers and the chat); null when it has neither.
  @override
  final HostFileActions? fileActions;
  @override
  final SendToHermes? sendToHermes;

  /// Creates the approver key if there is none (an existing one is returned unchanged). Used only by
  /// [connectWithCode], after the user confirmed; every other path loads an existing identity only.
  final Future<ApproverKey> Function()? _createKey;
  // `value` is current synchronously; listeners are deferred only while a frame is built/unmounted.
  final _active = FrameSafeValue<SurfacesConnection?>(null);
  final _status = FrameSafeValue<String?>(null);
  final _notice = FrameSafeValue<NativeAssociationNotice?>(null);
  bool _targetRevoked = false;

  // Shared across live host instances, independently of the host's native manager tracker.
  static final _associationWrites = NativeMutationTracker();
  static final Map<String, Future<void>> _saveQueues = {};
  static final Expando<bool> _issuedClients = Expando<bool>();
  int _epoch = 0;
  int _configurationEpoch = 0;
  int _saveGeneration = 0;
  NativeAssociationConfiguration? _open;

  /// This controller's own failed save keeps Apps disabled until an explicit reload/reopen.
  /// Other controllers and revoked/stale saves never inherit it; they do a fresh exact read.
  bool _saveFailed = false;
  bool _disposed = false;

  @override
  ValueListenable<SurfacesConnection?> get activeConnection => _active;

  /// The stable, language-free reason for the current state, or null while everything is fine.
  /// User interfaces localize it (`SurfacesStrings` with [NativeAssociationNotice.text]).
  ValueListenable<NativeAssociationNotice?> get notice => _notice;

  /// English, sanitised diagnostic mirror of [notice] (never a credential, URL or response body).
  ValueListenable<String?> get status => _status;

  bool get _ownerCurrent => !_disposed && lease.isCurrent && owner.sameContext(lease.owner);
  bool get _canRead => _ownerCurrent && !mutations.isPending && !_associationWrites.isPending;
  bool _readCurrent(int epoch) => _canRead && epoch == _epoch;

  void _invalidate() {
    _epoch++;
    _active.value = null; // Synchronous: Apps closes bound clients/routes before any await/write.
    if (!_disposed) notifyListeners();
  }

  void _message(NativeAssociationNotice? value) {
    if (_disposed) return;
    _notice.value = value;
    _status.value = value == null ? null : SurfacesStrings.forLanguage('en')(value.text);
    notifyListeners();
  }

  void _targetChanged() {
    // Every target notification revokes the previous lease; later ones are not news here.
    if (_targetRevoked || lease.isCurrent) return;
    _targetRevoked = true;
    _configurationEpoch++;
    _saveGeneration++;
    _invalidate();
    _message(NativeAssociationNotice.targetChanged);
  }

  void _nativeChanged() {
    _configurationEpoch++;
    _saveGeneration++;
    _invalidate();
    _message(NativeAssociationNotice.settingsChanging);
    if (!mutations.isPending) unawaited(reload());
  }

  void _associationChanged() {
    // Concurrent explicit saves can queue, but NO host can publish while any is pending.
    // Do not cancel a save's own ticket when it announces its secure write.
    _invalidate();
    // Once EVERY pending save has settled, an unaffected controller does a fresh exact read.
    if (!_associationWrites.isPending && !_saveFailed) unawaited(_load());
  }

  /// Fresh committed -> secure record -> fresh committed reconciliation; no memory fallback.
  /// Also invalidates old configuration tokens and clears this controller's failed-save latch.
  Future<void> reload() {
    _configurationEpoch++;
    _saveGeneration++;
    _saveFailed = false;
    return _load();
  }

  /// [publish] false is the dialog read: it returns the durable record, binds nothing.
  Future<NativeAssociationSettings?> _load({bool publish = true}) async {
    _invalidate();
    final epoch = _epoch;
    if (!_canRead) return null;
    try {
      if (owner.connectionId.isEmpty || owner.contextFingerprint.isEmpty) {
        throw const FormatException('Invalid owner');
      }
      final committed = await _loadCommittedOwner();
      if (!_readCurrent(epoch)) return null;
      if (!owner.sameContext(committed)) {
        _message(NativeAssociationNotice.contextMismatch);
        return null;
      }
      final raw = await _readAssociation(nativeAssociationStorageKey(owner.connectionId));
      if (!_readCurrent(epoch)) return null;
      if (raw == null) {
        _message(NativeAssociationNotice.unconfigured);
        return null;
      }
      final record = _AssociationRecord.parse(raw, owner);
      final connection = record.settings._connection(owner, record.generation);
      final verifiedOwner = await _loadCommittedOwner();
      if (!_readCurrent(epoch)) return null;
      if (!owner.sameContext(verifiedOwner)) {
        _message(NativeAssociationNotice.contextMismatch);
        return null;
      }
      final open = _open;
      // While an explicit configuration is open, nothing binds; endConfiguration reloads.
      if (publish && !(open != null && isConfigurationCurrent(open))) _active.value = connection;
      _message(null);
      return record.settings;
    } catch (_) {
      if (_readCurrent(epoch)) {
        _message(NativeAssociationNotice.readFailed);
      }
      return null;
    }
  }

  /// Configuration lifecycle: [beginConfiguration] synchronously unbinds Apps and returns a
  /// token; [readConfiguration] returns the durable record WITHOUT binding it; each
  /// [saveConfiguration] needs a current token (it survives invalid input and routine loads);
  /// [endConfiguration] (cancel, finally, dispose) reloads a still-current token so a cancelled
  /// dialog cannot strand a valid host unbound. Target change, native mutation, reload() or
  /// disposal permanently invalidate the token. Never invokes legacy/root/identity callbacks.
  NativeAssociationConfiguration beginConfiguration() {
    _configurationEpoch++;
    _saveGeneration++;
    _saveFailed = false;
    _invalidate();
    return _open = NativeAssociationConfiguration._(this, _configurationEpoch, owner);
  }

  bool isConfigurationCurrent(NativeAssociationConfiguration configuration) =>
      identical(configuration._controller, this) &&
      configuration._epoch == _configurationEpoch &&
      _ownerCurrent &&
      !mutations.isPending;

  Future<NativeAssociationSettings?> readConfiguration(NativeAssociationConfiguration configuration) {
    if (!isConfigurationCurrent(configuration)) return Future.value();
    return _load(publish: false);
  }

  void endConfiguration(NativeAssociationConfiguration configuration) {
    if (identical(_open, configuration)) _open = null;
    // A stale interaction never reloads or reclaims a revoked native target.
    if (isConfigurationCurrent(configuration) && !_saveFailed) unawaited(reload());
  }

  Future<NativeAssociationSaveResult> saveConfiguration(
    NativeAssociationConfiguration configuration,
    NativeAssociationSettings settings,
  ) {
    if (!isConfigurationCurrent(configuration)) {
      return Future.value(NativeAssociationSaveResult.stale);
    }
    _invalidate();
    try {
      settings._connection(owner, 'validation-only');
    } catch (_) {
      _message(NativeAssociationNotice.invalidSettings);
      return Future.value(NativeAssociationSaveResult.invalid);
    }
    final saveGeneration = ++_saveGeneration;
    final nativeEpoch = mutations.epoch;
    _saveFailed = false;
    final operation = _associationWrites.begin();
    final key = nativeAssociationStorageKey(owner.connectionId);
    final preceding = _saveQueues[key] ?? Future<void>.value();
    final result = preceding.then((_) => _save(settings, key, saveGeneration, nativeEpoch, operation));
    final tail = result.then<void>((_) {});
    _saveQueues[key] = tail;
    unawaited(
      tail.whenComplete(() {
        if (identical(_saveQueues[key], tail)) _saveQueues.remove(key);
      }),
    );
    return result;
  }

  bool _saveCurrent(int generation, int nativeEpoch) =>
      _ownerCurrent && generation == _saveGeneration && nativeEpoch == mutations.epoch && !mutations.isPending;

  Future<NativeAssociationSaveResult> _save(
    NativeAssociationSettings settings,
    String key,
    int generation,
    int nativeEpoch,
    NativeMutationOperation operation,
  ) async {
    var success = false;
    try {
      // Queued writes must still be authorized BEFORE invoking secure storage.
      if (!_saveCurrent(generation, nativeEpoch)) {
        return NativeAssociationSaveResult.stale;
      }
      final committed = await _loadCommittedOwner();
      if (!_saveCurrent(generation, nativeEpoch)) {
        return NativeAssociationSaveResult.stale;
      }
      if (!owner.sameContext(committed)) {
        _message(NativeAssociationNotice.contextMismatch);
        return NativeAssociationSaveResult.stale;
      }
      final random = Random.secure();
      final associationGeneration = base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
      final record = _AssociationRecord(owner, settings, associationGeneration);
      final encoded = record.encode();
      await _writeAssociation(key, encoded);
      // A begun secure write is not cancellable; stale completion NEVER publishes it.
      if (!_saveCurrent(generation, nativeEpoch)) {
        return NativeAssociationSaveResult.stale;
      }
      final readback = await _readAssociation(key);
      if (!_saveCurrent(generation, nativeEpoch)) {
        return NativeAssociationSaveResult.stale;
      }
      if (readback != encoded) {
        throw const FormatException('Association readback failed');
      }
      _AssociationRecord.parse(readback!, owner);
      final verifiedOwner = await _loadCommittedOwner();
      if (!_saveCurrent(generation, nativeEpoch)) {
        return NativeAssociationSaveResult.stale;
      }
      if (!owner.sameContext(verifiedOwner)) {
        _message(NativeAssociationNotice.contextMismatch);
        return NativeAssociationSaveResult.stale;
      }
      success = true;
      _saveFailed = false;
      return NativeAssociationSaveResult.saved;
    } catch (_) {
      if (!_saveCurrent(generation, nativeEpoch)) return NativeAssociationSaveResult.stale;
      _saveFailed = true;
      _message(NativeAssociationNotice.saveFailed);
      return NativeAssociationSaveResult.failed;
    } finally {
      // FAILED != COMMITTED: the proposed values are never published from this completion.
      // Settlement of the LAST pending save only triggers fresh exact-context reads.
      operation.finish(success: success);
    }
  }

  /// Explicit, user-triggered dialog action: ONE read-only `health` request with the TYPED settings
  /// through a fresh client of the host's own `createClient` seam, closed afterwards. It saves nothing,
  /// binds nothing and never touches [status]; a target change, native mutation, reload or disposal
  /// during the request yields [NativeConnectionCheck.stale]. Only the enum leaves this method, never
  /// the URL, token or any response body.
  Future<NativeConnectionCheck> checkConnection(
    NativeAssociationConfiguration configuration,
    NativeAssociationSettings settings, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (!isConfigurationCurrent(configuration)) return NativeConnectionCheck.stale;
    final SurfacesConnection connection;
    try {
      connection = settings._connection(owner, 'connection-check');
    } catch (_) {
      return NativeConnectionCheck.invalid;
    }
    final http.Client client;
    try {
      client = _createClient(connection);
    } catch (_) {
      return NativeConnectionCheck.unreachable;
    }
    // A shared client is not ours to close: refuse it exactly like the Apps seam does.
    if (_issuedClients[client] == true) return NativeConnectionCheck.unreachable;
    _issuedClients[client] = true;
    final api = SurfacesApi(connection.config, client: client, timeout: timeout);
    try {
      if (!isConfigurationCurrent(configuration)) return NativeConnectionCheck.stale;
      await api.health();
      return isConfigurationCurrent(configuration) ? NativeConnectionCheck.reachable : NativeConnectionCheck.stale;
    } on ApiException catch (e) {
      if (!isConfigurationCurrent(configuration)) return NativeConnectionCheck.stale;
      return e.isUnauthorized ? NativeConnectionCheck.unauthorized : NativeConnectionCheck.unreachable;
    } catch (_) {
      return isConfigurationCurrent(configuration) ? NativeConnectionCheck.unreachable : NativeConnectionCheck.stale;
    } finally {
      try {
        api.close();
      } catch (_) {
        /* A close failure must not change the sanitised outcome. */
      }
    }
  }

  /// Explicit, user-confirmed action: spends a one-time connection code from the chat. The code is
  /// exchanged for this server's token while this phone's approver key is registered in the same step,
  /// and the result is saved like a hand-typed configuration (same record, same checks). Only a
  /// [NativeClaimResult] leaves this method, never the address, the code or the token. A code that was
  /// spent but could not be saved is gone: the user asks for a new one.
  Future<NativeClaimResult> connectWithCode(
    NativeAssociationConfiguration configuration,
    ConnectionString code, {
    String? deviceId,
    bool strictNetworkBlock = true,
    bool sealNetwork = true,
  }) async {
    if (!isConfigurationCurrent(configuration)) return NativeClaimResult.stale;
    final createKey = _createKey;
    if (createKey == null) return NativeClaimResult.failed;
    final id = deviceId != null && NativeAssociationSettings.isValidDeviceId(deviceId) ? deviceId : _newDeviceId();
    final ApproverKey key;
    try {
      key = await createKey();
    } catch (_) {
      return isConfigurationCurrent(configuration) ? NativeClaimResult.failed : NativeClaimResult.stale;
    }
    if (!isConfigurationCurrent(configuration)) return NativeClaimResult.stale;
    final http.Client client;
    try {
      client = _createClient(
        SurfacesConnection(
          // The placeholder token is never sent: the claim carries no bearer. The seam only needs a connection.
          config: ServerConfig(
            baseUri: code.baseUri,
            token: 'claim',
            deviceId: id,
            connectionId: owner.connectionId,
            profileId: owner.profileId,
          ),
          strictNetworkBlock: strictNetworkBlock,
          sealNetwork: sealNetwork,
        ),
      );
    } catch (_) {
      return NativeClaimResult.unreachable;
    }
    if (_issuedClients[client] == true) return NativeClaimResult.unreachable;
    _issuedClients[client] = true;
    final ClaimResult claimed;
    try {
      claimed = await claimConnectionCode(
        baseUri: code.baseUri,
        code: code.code,
        deviceId: id,
        publicKeyBase64: key.publicKeyBase64,
        client: client,
      );
    } on ApiException catch (e) {
      if (!isConfigurationCurrent(configuration)) return NativeClaimResult.stale;
      return switch (e.status) {
        400 => NativeClaimResult.invalidCode,
        429 => NativeClaimResult.locked,
        404 || 405 => NativeClaimResult.unsupported,
        _ => NativeClaimResult.failed,
      };
    } on OfflineException {
      return isConfigurationCurrent(configuration) ? NativeClaimResult.unreachable : NativeClaimResult.stale;
    } catch (_) {
      return isConfigurationCurrent(configuration) ? NativeClaimResult.failed : NativeClaimResult.stale;
    } finally {
      try {
        client.close();
      } catch (_) {
        /* A close failure must not change the outcome. */
      }
    }
    if (!isConfigurationCurrent(configuration)) return NativeClaimResult.stale;
    final saved = await saveConfiguration(
      configuration,
      NativeAssociationSettings(
        baseUri: code.baseUri,
        bearer: claimed.token,
        deviceId: id,
        strictNetworkBlock: strictNetworkBlock,
        sealNetwork: sealNetwork,
      ),
    );
    if (saved == NativeAssociationSaveResult.stale) return NativeClaimResult.stale;
    if (saved != NativeAssociationSaveResult.saved) return NativeClaimResult.failed;
    return claimed.approverPaired ? NativeClaimResult.connected : NativeClaimResult.connectedNotApprover;
  }

  /// `phone-` plus eight random characters: what the server's approver pairing and request log call this phone.
  static String _newDeviceId() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return 'phone-${List.generate(8, (_) => alphabet[random.nextInt(alphabet.length)]).join()}';
  }

  bool _bindingCurrent(int epoch, SurfacesConnection? binding) =>
      binding != null && _readCurrent(epoch) && identical(binding, _active.value);

  Future<void> _verifyBinding(int epoch, SurfacesConnection? binding) async {
    if (!_bindingCurrent(epoch, binding)) {
      throw StateError('Native Apps binding is stale');
    }
    final NativeOwnerSnapshot? committed;
    try {
      committed = await _loadCommittedOwner();
    } catch (_) {
      if (_bindingCurrent(epoch, binding)) {
        _configurationEpoch++;
        _saveGeneration++;
        _invalidate();
        _message(NativeAssociationNotice.ownerUnavailable);
      }
      throw StateError('Native Apps owner is unavailable');
    }
    if (!_bindingCurrent(epoch, binding)) {
      throw StateError('Native Apps binding is stale');
    }
    if (!owner.sameContext(committed)) {
      _configurationEpoch++;
      _saveGeneration++;
      _invalidate();
      _message(NativeAssociationNotice.contextMismatch);
      throw StateError('Native Apps owner changed');
    }
  }

  @override
  Future<Directory> applicationSupportDirectory() async {
    final epoch = _epoch;
    final binding = _active.value;
    try {
      if (!_bindingCurrent(epoch, binding)) {
        throw StateError('Native Apps binding is stale');
      }
      final root = await _supportDirectory();
      await _verifyBinding(epoch, binding);
      return root;
    } catch (_) {
      throw StateError('Native Apps support directory is unavailable');
    }
  }

  @override
  Future<ApproverKey?> loadApproverKey() async {
    final epoch = _epoch;
    final binding = _active.value;
    try {
      if (!_bindingCurrent(epoch, binding)) {
        throw StateError('Native Apps binding is stale');
      }
      final key = await _loadExistingKey(); // ONLY existing identity; null keeps reads available.
      await _verifyBinding(epoch, binding);
      return key;
    } catch (_) {
      throw StateError('Existing native approver identity is unavailable');
    }
  }

  @override
  http.Client createSurfacesClient(SurfacesConnection connection) {
    final epoch = _epoch;
    final binding = _active.value;
    bool current() =>
        _bindingCurrent(epoch, binding) &&
        (sameConnection(connection, binding) ||
            sameConnection(
              connection,
              SurfacesConnection(
                config: binding!.config.forPreview(),
                strictNetworkBlock: binding.strictNetworkBlock,
                sealNetwork: binding.sealNetwork,
              ),
            ));
    if (!current()) throw StateError('Native Apps binding is stale');
    final http.Client client;
    try {
      client = _createClient(connection);
    } catch (_) {
      throw StateError('Fresh native Apps client is unavailable');
    }
    if (_issuedClients[client] == true) {
      throw StateError('Native Apps clients must be fresh');
    }
    _issuedClients[client] = true;
    if (!current()) {
      try {
        client.close();
      } catch (_) {
        /* Do not let close failure revive a stale client. */
      }
      throw StateError('Native Apps binding is stale');
    }
    return client;
  }

  @override
  Future<void> openChat() async {
    // Chat remains available without any association/key, including committed mismatch.
    if (!_ownerCurrent) return;
    try {
      await _openExistingChat();
    } catch (_) {
      throw StateError('Existing native chat is unavailable');
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _configurationEpoch++;
    _saveGeneration++;
    _epoch++;
    _active.value = null;
    notifyNow(); // The dialog (not a child of the host) defers its own visual work.
    closeNotifications();
    lease.removeListener(_targetChanged);
    mutations.removeListener(_nativeChanged);
    _associationWrites.removeListener(_associationChanged);
    _active.dispose();
    _status.dispose();
    _notice.dispose();
    super.dispose();
  }
}

class _AssociationRecord {
  const _AssociationRecord(this.owner, this.settings, this.generation);
  final NativeOwnerSnapshot owner;
  final NativeAssociationSettings settings;
  final String generation;

  String encode() => jsonEncode({
    'version': 1,
    'connectionId': owner.connectionId,
    'profileId': owner.profileId,
    'contextFingerprint': owner.contextFingerprint,
    'generation': generation,
    'baseUri': settings.baseUri.toString(),
    'bearer': settings.bearer,
    'deviceId': settings.deviceId,
    'strictNetworkBlock': settings.strictNetworkBlock,
    'sealNetwork': settings.sealNetwork,
  });

  static _AssociationRecord parse(String raw, NativeOwnerSnapshot owner) {
    final json = jsonDecode(raw);
    if (json is! Map<String, dynamic> ||
        json['version'] is! int ||
        json['version'] != 1 ||
        json['connectionId'] != owner.connectionId ||
        !json.containsKey('profileId') ||
        json['profileId'] != owner.profileId ||
        json['contextFingerprint'] != owner.contextFingerprint ||
        json['generation'] is! String ||
        (json['generation'] as String).isEmpty ||
        json['baseUri'] is! String ||
        json['bearer'] is! String ||
        json['deviceId'] is! String ||
        json['strictNetworkBlock'] is! bool ||
        json['sealNetwork'] is! bool) {
      throw const FormatException('Invalid native Surfaces association');
    }
    return _AssociationRecord(
      owner,
      NativeAssociationSettings(
        baseUri: Uri.parse(json['baseUri'] as String),
        bearer: json['bearer'] as String,
        deviceId: json['deviceId'] as String,
        strictNetworkBlock: json['strictNetworkBlock'] as bool,
        sealNetwork: json['sealNetwork'] as bool,
      ),
      json['generation'] as String,
    );
  }
}
