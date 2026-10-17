import 'package:flutter/widgets.dart';

import 'native_association_signals.dart';

/// Optional native navigation seam. Register immutable Workspace owners once; when Back
/// actually reveals one, issue a NEW lease if its old lease was revoked. The controller
/// still performs fresh committed-owner/association checks before enabling Apps.
///
/// Unknown child routes (Surface/configuration/same-owner Chat) retain the current lease.
/// All cross-owner/direct entry paths must ALSO explicitly select/clear the shared target
/// before their first await/push; an observer cannot infer their native credential context.
class NativeTargetRouteObserver extends NavigatorObserver {
  NativeTargetRouteObserver(this.target);
  final NativeActiveTarget target;
  final Map<Route<dynamic>, _ObservedOwner> _owners = {};

  /// Call once for a captured ModalRoute in didChangeDependencies; unregister on dispose.
  /// Only an actually current route may acquire the current selection during registration.
  VoidCallback observe(
    Route<dynamic> route,
    NativeOwnerSnapshot owner,
    void Function(NativeTargetLease lease) onSelected,
  ) {
    final registration = _ObservedOwner(owner, onSelected);
    _owners[route] = registration;
    if (route.isCurrent) _select(registration, initial: true);
    return () {
      if (!identical(_owners[route], registration)) return;
      _owners.remove(route);
      if (registration.lease?.isCurrent == true) target.clear();
    };
  }

  void _select(_ObservedOwner registration, {bool initial = false}) {
    if (registration.lease?.isCurrent == true) return;
    final current = target.current;
    final claimed =
        current != null &&
        _owners.values.any((other) => !identical(other, registration) && identical(other.lease, current));
    final lease = initial && current != null && !claimed && registration.owner.sameContext(current.owner)
        ? current
        : target.select(registration.owner);
    registration.lease = lease;
    registration.onSelected(lease);
  }

  void _revealed(Route<dynamic>? route) {
    final registration = _owners[route];
    if (registration != null) _select(registration);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _revealed(previousRoute);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _revealed(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _revealed(newRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute?.isCurrent == true) _revealed(previousRoute);
  }
}

class _ObservedOwner {
  _ObservedOwner(this.owner, this.onSelected);
  final NativeOwnerSnapshot owner;
  final void Function(NativeTargetLease) onSelected;
  NativeTargetLease? lease;
}
