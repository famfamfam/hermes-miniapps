import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart' show digestBytes;

/// Internal, not exported. State changes are always visible synchronously; only the
/// LISTENER notification moves to the post-frame callback while the framework is building or
/// unmounting a frame, where a listener's setState would assert. Frame callbacks never yield to
/// microtasks, so no asynchronous completion can interleave with a deferred notification.
mixin FrameSafeNotifier on ChangeNotifier {
  bool _scheduled = false;
  bool _closed = false;

  @override
  void notifyListeners() {
    if (_closed) return;
    final binding = SchedulerBinding.instance;
    if (binding.schedulerPhase != SchedulerPhase.persistentCallbacks) {
      super.notifyListeners();
      return;
    }
    if (_scheduled) return;
    _scheduled = true;
    binding.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_closed) super.notifyListeners();
    });
  }

  /// Immediate notification for the one caller that knows its listeners defer their own work.
  void notifyNow() {
    if (!_closed) super.notifyListeners();
  }

  void closeNotifications() => _closed = true;
}

/// Internal, not exported: a ValueNotifier whose `value` is current even while notification is deferred.
class FrameSafeValue<T> extends ChangeNotifier with FrameSafeNotifier implements ValueListenable<T> {
  FrameSafeValue(this._value);
  T _value;

  @override
  T get value => _value;

  set value(T next) {
    if (identical(_value, next) || _value == next) return;
    _value = next;
    notifyListeners();
  }

  @override
  void dispose() {
    closeNotifications();
    super.dispose();
  }
}

/// Project the actual immutable native chat/workspace snapshot, not proposed settings.
@immutable
class NativeOwnerSnapshot {
  const NativeOwnerSnapshot({
    required this.connectionId,
    required this.profileId,
    required this.contextFingerprint,
    required this.displayLabel,
  });

  final String connectionId;
  final String? profileId;

  /// Opaque fingerprint of endpoint/routes AND the native credential context.
  /// Never pass raw credentials here. [nativeContextFingerprint] hashes them in memory.
  final String contextFingerprint;
  final String displayLabel;

  bool sameContext(NativeOwnerSnapshot? other) =>
      other != null &&
      connectionId == other.connectionId &&
      profileId == other.profileId &&
      contextFingerprint == other.contextFingerprint;
}

/// Hash an ordered, JSON-compatible native context (including exact nulls/empty values).
/// Include all endpoint, route and credential fields; do not log or persist the input.
String nativeContextFingerprint(Object? context) =>
    digestBytes(utf8.encode(jsonEncode(['hermes-native-context-v1', context])));

/// Separate secure-storage namespace; no owner identifier or credential in the key.
String nativeAssociationStorageKey(String connectionId) =>
    'hermes_surfaces_association_v1_${digestBytes(utf8.encode(jsonEncode(['hermes-native-association-v1', connectionId]))).substring(7)}';

/// A route's authorization to use one native target. Revocation is permanent.
@immutable
class NativeTargetLease {
  const NativeTargetLease._(this._target, this.owner, this.epoch);
  final NativeActiveTarget _target;
  final NativeOwnerSnapshot owner;
  final int epoch;
  bool get isCurrent => _target.isCurrent(this);
  void addListener(VoidCallback listener) => _target.addListener(listener);
  void removeListener(VoidCallback listener) => _target.removeListener(listener);
}

/// Share one signal across ALL native entry paths, including offstage/direct Chat routes.
class NativeActiveTarget extends ChangeNotifier {
  NativeTargetLease? _current;
  int _epoch = 0;
  bool _disposed = false;

  NativeTargetLease? get current => _current;
  int get epoch => _epoch;

  bool isCurrent(NativeTargetLease lease) => !_disposed && identical(_current, lease) && lease.epoch == _epoch;

  /// Always revokes the previous lease synchronously, even for A -> A or A -> B -> A.
  NativeTargetLease select(NativeOwnerSnapshot owner) {
    if (_disposed) throw StateError('Native target is disposed');
    _epoch++;
    final lease = NativeTargetLease._(this, owner, _epoch);
    _current = lease;
    notifyListeners();
    return lease;
  }

  /// Same-snapshot nested Chat navigation may retain its existing Workspace lease.
  NativeTargetLease selectIfChanged(NativeOwnerSnapshot owner) {
    final lease = _current;
    return lease != null && lease.isCurrent && owner.sameContext(lease.owner) ? lease : select(owner);
  }

  void clear() {
    if (_disposed) return;
    _epoch++;
    _current = null;
    notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    clear();
    _disposed = true;
    super.dispose();
  }
}

/// Outcome of a COMPLETE native transaction, after metadata commit or rollback attempt.
enum NativeMutationOutcome { success, failure }

class NativeMutationOperation {
  NativeMutationOperation._(this._tracker, this.id);
  final NativeMutationTracker _tracker;
  final int id;
  NativeMutationOutcome? _outcome;
  NativeMutationOutcome? get outcome => _outcome;
  bool get pending => _outcome == null;

  /// Balanced and idempotent. `finally` alone does not imply a successful commit.
  void finish({required bool success}) => _tracker._finish(this, success);
}

/// Share ONE instance across ConnectionManager instances. No credentials or payloads.
/// BEGIN notifies synchronously BEFORE the first native write/await. No-op reads must
/// not begin an operation. All pending transactions must settle before reconciliation.
class NativeMutationTracker extends ChangeNotifier {
  final Set<NativeMutationOperation> _pending = {};
  int _nextId = 0;
  int _epoch = 0;
  NativeMutationOperation? _lastSettled;

  int get epoch => _epoch;
  int get pendingCount => _pending.length;
  bool get isPending => _pending.isNotEmpty;
  List<NativeMutationOperation> get pendingOperations => List.unmodifiable(_pending);
  NativeMutationOperation? get lastSettled => _lastSettled;
  NativeMutationOutcome? get lastOutcome => _lastSettled?.outcome;

  NativeMutationOperation begin() {
    final operation = NativeMutationOperation._(this, ++_nextId);
    _pending.add(operation);
    _epoch++;
    notifyListeners();
    return operation;
  }

  void _finish(NativeMutationOperation operation, bool success) {
    if (!_pending.remove(operation)) return;
    operation._outcome = success ? NativeMutationOutcome.success : NativeMutationOutcome.failure;
    _lastSettled = operation;
    _epoch++;
    notifyListeners();
  }

  /// Optional wrapper when the native method already throws on transaction failure.
  Future<T> run<T>(Future<T> Function() transaction) async {
    final operation = begin();
    var success = false;
    try {
      final result = await transaction();
      success = true;
      return result;
    } finally {
      operation.finish(success: success);
    }
  }
}
