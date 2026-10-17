import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';

import 'native_association_support.dart';

/// Mimics a native Workspace: observe its captured route once; unregister on dispose.
class _Workspace extends StatefulWidget {
  const _Workspace({required this.observer, required this.owner, required this.leases, required this.label});
  final NativeTargetRouteObserver observer;
  final NativeOwnerSnapshot owner;
  final List<NativeTargetLease> leases;
  final String label;
  @override
  State<_Workspace> createState() => _WorkspaceState();
}

class _WorkspaceState extends State<_Workspace> {
  VoidCallback? _unregister;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _unregister ??= widget.observer.observe(ModalRoute.of(context)!, widget.owner, widget.leases.add);
  }

  @override
  void dispose() {
    _unregister?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(body: Text(widget.label));
}

void main() {
  late NativeActiveTarget target;
  late NativeTargetRouteObserver observer;
  final a = nativeOwner(id: 'A');
  final b = nativeOwner(id: 'B');
  final aLeases = <NativeTargetLease>[];
  final bLeases = <NativeTargetLease>[];
  final navigator = GlobalKey<NavigatorState>();

  setUp(() {
    target = NativeActiveTarget();
    observer = NativeTargetRouteObserver(target);
    aLeases.clear();
    bLeases.clear();
  });
  tearDown(() => target.dispose());

  Future<void> mountA(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      navigatorObservers: [observer],
      home: _Workspace(observer: observer, owner: a, leases: aLeases, label: 'workspace A'),
    ),
  );

  Future<void> push(WidgetTester tester, Widget page) async {
    navigator.currentState!.push(MaterialPageRoute<void>(builder: (_) => page));
    await tester.pumpAndSettle();
  }

  testWidgets('first visible Workspace selects once; same-owner child routes retain the lease', (tester) async {
    await mountA(tester);
    final first = aLeases.single;
    expect(first.isCurrent, isTrue);
    expect(target.current, same(first));
    final epoch = target.epoch;
    await push(tester, const Scaffold(body: Text('same-owner Chat/Surface/config child')));
    expect(target.epoch, epoch);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(aLeases, [first]);
    expect(first.isCurrent, isTrue);
  });

  testWidgets('Back to a covered Workspace issues a NEW lease and never revives the revoked one', (tester) async {
    await mountA(tester);
    final oldA = aLeases.single;
    await push(tester, _Workspace(observer: observer, owner: b, leases: bLeases, label: 'workspace B'));
    expect(oldA.isCurrent, isFalse); // Offstage/covered A is invalidated synchronously by B.
    expect(bLeases.single.isCurrent, isTrue);
    expect(target.current, same(bLeases.single));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(aLeases.length, 2);
    final newA = aLeases.last;
    expect(newA, isNot(same(oldA)));
    expect(oldA.isCurrent, isFalse);
    expect(newA.isCurrent, isTrue);
    expect(bLeases.single.isCurrent, isFalse);
    expect(target.current, same(newA));
  });

  testWidgets('same-frame A -> B -> A selections never resurrect a route lease', (tester) async {
    await mountA(tester);
    final oldA = aLeases.single;
    final selectedB = target.select(b);
    final selectedA = target.select(a);
    expect(oldA.isCurrent, isFalse);
    expect(selectedB.isCurrent, isFalse);
    expect(selectedA.isCurrent, isTrue);
    // The route is still on top, but its registration holds the revoked lease: pushing and
    // popping any registered route re-validates it with a NEW lease only on a real reveal.
    await push(tester, _Workspace(observer: observer, owner: b, leases: bLeases, label: 'workspace B'));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(aLeases.last.isCurrent, isTrue);
    expect(aLeases.last, isNot(same(oldA)));
  });

  testWidgets('explicit select before push is reused by the first observed registration only', (tester) async {
    await mountA(tester);
    final explicit = target.select(b);
    final epoch = target.epoch;
    await push(tester, _Workspace(observer: observer, owner: b, leases: bLeases, label: 'workspace B'));
    expect(bLeases.single, same(explicit));
    expect(target.epoch, epoch);
    // A duplicate registration for the same owner cannot share an already claimed lease.
    await push(tester, _Workspace(observer: observer, owner: b, leases: bLeases, label: 'duplicate B'));
    expect(bLeases.length, 2);
    expect(bLeases.last, isNot(same(explicit)));
    expect(explicit.isCurrent, isFalse);
  });

  testWidgets('unregistering the visible Workspace clears; unregistering a covered one leaves target alone', (
    tester,
  ) async {
    await mountA(tester);
    await push(tester, _Workspace(observer: observer, owner: b, leases: bLeases, label: 'workspace B'));
    final selectedB = bLeases.single;
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    // B was revealed away; its dispose must not clear A's NEW lease.
    expect(aLeases.last.isCurrent, isTrue);
    expect(selectedB.isCurrent, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(target.current, isNull);
  });

  testWidgets('a registration for a route that is not on top never steals the selection', (tester) async {
    await mountA(tester);
    final visible = aLeases.single;
    final stranger = observer.observe(MaterialPageRoute<void>(builder: (_) => const SizedBox.shrink()), b, bLeases.add);
    expect(bLeases, isEmpty);
    expect(visible.isCurrent, isTrue);
    stranger();
    expect(visible.isCurrent, isTrue);
  });
}
