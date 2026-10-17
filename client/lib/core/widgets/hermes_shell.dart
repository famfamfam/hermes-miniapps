/// The Hermes Android navigation shell.
///
/// Replaces drawer-hidden navigation with the validated top-level structure
/// Home / Projects / Activity / More, so every capability is one tap away.
/// A connection with no panel behind it gets the shorter set Chats / Apps /
/// Tasks / More (see [HermesDestination.lean]).
/// Adapts to a bottom bar on phones and a side rail on tablets/foldables.
library;

import 'package:flutter/material.dart';

import 'package:hermes_android/core/l10n/l10n.dart';

import '../theme/hermes_theme.dart';

/// A top-level destination of the Hermes app.
enum HermesDestination {
  /// Attention-first dashboard: what needs you, what is running.
  home,

  /// Every conversation, with recent, unassigned, archived, and search views.
  chats,

  /// Server-owned Projects and their chats, files, assets, and activity.
  projects,

  /// Global operational timeline: running, blocked, completed, failed.
  activity,

  /// Everything else: files, assets, search, cron, skills, settings.
  more,

  /// Mini-apps published by the Hermes server.
  apps,

  /// Scheduled tasks (cron) and where their results go.
  tasks;

  /// The destinations of a connection that has a panel and projects.
  static const List<HermesDestination> full = [
    home,
    chats,
    projects,
    activity,
    more,
  ];

  /// The destinations of a connection that only offers the Gateway API.
  static const List<HermesDestination> lean = [chats, apps, tasks, more];

  String label(AppLocalizations l10n) {
    return switch (this) {
      HermesDestination.home => l10n.nav_home,
      HermesDestination.chats => l10n.chats,
      HermesDestination.projects => l10n.nav_projects,
      HermesDestination.activity => l10n.nav_activity,
      HermesDestination.more => l10n.nav_more,
      HermesDestination.apps => l10n.tab_apps,
      HermesDestination.tasks => l10n.tab_tasks,
    };
  }

  IconData get icon {
    switch (this) {
      case HermesDestination.home:
        return Icons.home_outlined;
      case HermesDestination.chats:
        return Icons.chat_bubble_outline;
      case HermesDestination.projects:
        return Icons.folder_outlined;
      case HermesDestination.activity:
        return Icons.bolt_outlined;
      case HermesDestination.more:
        return Icons.more_horiz;
      case HermesDestination.apps:
        return Icons.apps_outlined;
      case HermesDestination.tasks:
        return Icons.schedule_outlined;
    }
  }

  IconData get selectedIcon {
    switch (this) {
      case HermesDestination.home:
        return Icons.home_rounded;
      case HermesDestination.chats:
        return Icons.chat_bubble_rounded;
      case HermesDestination.projects:
        return Icons.folder_rounded;
      case HermesDestination.activity:
        return Icons.bolt_rounded;
      case HermesDestination.more:
        return Icons.more_horiz_rounded;
      case HermesDestination.apps:
        return Icons.apps_rounded;
      case HermesDestination.tasks:
        return Icons.schedule_rounded;
    }
  }
}

/// Builds the pane for one destination.
typedef HermesPaneBuilder =
    Widget Function(BuildContext context, HermesDestination destination);

/// Exposes whether the pane it wraps is the visible destination.
///
/// Panes live in an [IndexedStack] and stay mounted when another tab is
/// selected, so widgets that poll (e.g. the session-list refresh) need this
/// to stop while hidden. Standalone hosts without a shell see `true`.
class HermesPaneVisibility extends InheritedWidget {
  const HermesPaneVisibility({
    required this.active,
    required super.child,
    super.key,
  });

  /// Whether this pane is the selected destination.
  final bool active;

  /// True when the calling pane is the selected destination.
  static bool of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<HermesPaneVisibility>()
          ?.active ??
      true;

  @override
  bool updateShouldNotify(HermesPaneVisibility oldWidget) =>
      oldWidget.active != active;
}

/// The adaptive navigation shell.
///
/// [badges] drives attention counts (for example pending approvals on
/// Activity); a zero or negative count renders nothing so the bar stays calm
/// when there is nothing to report.
class HermesShell extends StatefulWidget {
  /// Below this width the shell uses a bottom bar; at or above it, a rail.
  static const double railBreakpoint = 720;

  static const int maxBadgeCount = 99;

  final HermesPaneBuilder builder;

  /// The tabs, in order. A destination the host does not list is neither
  /// shown nor built.
  final List<HermesDestination> destinations;
  final HermesDestination initialDestination;
  final Map<HermesDestination, int> badges;
  final ValueChanged<HermesDestination>? onDestinationChanged;

  /// The shell's floating action button.
  ///
  /// Owned here rather than by a host Scaffold: the shell draws the bottom
  /// bar, so a FAB placed above it would float over the last destination and
  /// swallow its taps.
  final Widget? floatingActionButton;

  const HermesShell({
    required this.builder,
    this.destinations = HermesDestination.full,
    this.initialDestination = HermesDestination.home,
    this.badges = const {},
    this.onDestinationChanged,
    this.floatingActionButton,
    super.key,
  }) : assert(destinations.length >= 2),
       assert(
         destinations.length <= 5,
         'a bottom bar holds at most five destinations',
       );

  @override
  State<HermesShell> createState() => HermesShellState();
}

class HermesShellState extends State<HermesShell> {
  late HermesDestination _current = _fallback(widget.initialDestination);
  late final Set<HermesDestination> _visitedDestinations = {_current};

  HermesDestination _fallback(HermesDestination wanted) =>
      widget.destinations.contains(wanted) ? wanted : widget.destinations.first;

  int get _currentIndex => widget.destinations.indexOf(_current);

  @override
  void didUpdateWidget(HermesShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The set of tabs changed under the person (for example the connection
    // was edited): stay where we are if that tab survives, else go to the first.
    if (!widget.destinations.contains(_current)) {
      _current = widget.destinations.first;
      _visitedDestinations.add(_current);
    }
  }

  /// Selects through the same path as a bar/rail tap, so a host (the Apps
  /// callback) can reveal Chats without a second source of truth.
  void selectDestination(HermesDestination destination) {
    if (widget.destinations.contains(destination)) _select(destination);
  }

  void _select(HermesDestination destination) {
    // Re-tapping the active destination is a no-op rather than a rebuild or a
    // duplicate notification: callers use the callback for analytics/state.
    if (destination == _current) return;
    setState(() {
      _current = destination;
      _visitedDestinations.add(destination);
    });
    widget.onDestinationChanged?.call(destination);
  }

  Widget? _badge(HermesDestination destination) {
    final count = widget.badges[destination] ?? 0;
    if (count <= 0) return null;
    final text = count > HermesShell.maxBadgeCount
        ? '${HermesShell.maxBadgeCount}+'
        : '$count';
    return Badge(label: Text(text));
  }

  Widget _icon(HermesDestination destination, {required bool selected}) {
    final icon = Icon(selected ? destination.selectedIcon : destination.icon);
    final badge = _badge(destination);
    if (badge == null) return icon;
    return Badge(label: (badge as Badge).label, child: icon);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final useRail =
        MediaQuery.sizeOf(context).width >= HermesShell.railBreakpoint;

    // Keep every visited destination mounted so local UI state (search text,
    // selected filters, scroll position) survives switching away and back.
    // Unvisited panes stay as inert placeholders: building all destinations
    // eagerly would start their network reads before the user opens them.
    final pane = IndexedStack(
      index: _currentIndex,
      children: [
        for (final destination in widget.destinations)
          if (_visitedDestinations.contains(destination))
            KeyedSubtree(
              key: ValueKey(destination),
              child: HermesPaneVisibility(
                active: destination == _current,
                child: widget.builder(context, destination),
              ),
            )
          else
            const SizedBox.shrink(),
      ],
    );

    if (useRail) {
      return Scaffold(
        backgroundColor: tokens.surface,
        floatingActionButton: widget.floatingActionButton,
        body: Row(
          children: [
            NavigationRail(
              backgroundColor: tokens.surface,
              selectedIndex: _currentIndex,
              onDestinationSelected: (index) =>
                  _select(widget.destinations[index]),
              labelType: NavigationRailLabelType.all,
              indicatorColor: tokens.accent.withValues(alpha: 0.18),
              destinations: [
                for (final destination in widget.destinations)
                  NavigationRailDestination(
                    icon: _icon(destination, selected: false),
                    selectedIcon: _icon(destination, selected: true),
                    label: Text(destination.label(context.l10n)),
                  ),
              ],
            ),
            VerticalDivider(width: 1, color: tokens.border),
            Expanded(child: pane),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: tokens.surface,
      body: pane,
      floatingActionButton: widget.floatingActionButton,
      // Label sizes are the worst-case bases: the NavigationBar clamps its
      // label text scaling at 1.3x internally (Flutter keeps the visual
      // hierarchy), so 9sp fits every shipped label on a 320dp phone even at
      // the clamp, and 10sp covers 360dp and wider. The app's 1.15x/1.30x
      // text-size preference still scales the labels within that clamp.
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          labelTextStyle: WidgetStateProperty.resolveWith((states) {
            final base = Theme.of(
              context,
            ).navigationBarTheme.labelTextStyle?.resolve(states);
            return (base ?? const TextStyle()).copyWith(
              fontSize: MediaQuery.sizeOf(context).width < 360 ? 9 : 10,
            );
          }),
        ),
        child: NavigationBar(
          backgroundColor: tokens.raised,
          indicatorColor: tokens.accent.withValues(alpha: 0.18),
          selectedIndex: _currentIndex,
          onDestinationSelected: (index) =>
              _select(widget.destinations[index]),
          destinations: [
            for (final destination in widget.destinations)
              NavigationDestination(
                icon: _icon(destination, selected: false),
                selectedIcon: _icon(destination, selected: true),
                label: destination.label(context.l10n),
              ),
          ],
        ),
      ),
    );
  }
}
