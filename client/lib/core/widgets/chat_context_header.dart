import 'package:flutter/material.dart';

import '../theme/hermes_theme.dart';

import 'package:hermes_android/core/l10n/l10n.dart';

/// Transport state shown in the sticky chat context header.
enum ChatConnectionStatus {
  connecting('connecting'),
  connected('connected'),
  reconnecting('reconnecting'),
  offline('offline');

  final String label;
  const ChatConnectionStatus(this.label);
}

/// Sticky context row under the chat title.
///
/// Shows only what is worth a glance while messages scroll, and nothing when
/// there is nothing to say (the caller then leaves the row out, see
/// [hasContent]):
///
/// - the Project, on a connection that has Projects (an unfiled chat there
///   reads "Unassigned");
/// - the reasoning effort, once someone chose one — "default" is not news;
/// - the connection, only once it has dropped (a transcript still loading is not
///   news, and a bar that appears and vanishes on every open shifts the page).
///
/// The model is not here: the composer already carries it as the button that
/// changes it. The row is horizontally scrollable instead of wrapping into the
/// chat, so large text and narrow phones never clip or grow the AppBar.
class ChatContextHeader extends StatelessWidget {
  final String? projectName;

  /// Whether this connection has Projects at all. Without any, a chat with no
  /// Project is the only kind there is and needs no label.
  final bool showProject;
  final String reasoningEffort;
  final String connectionLabel;
  final ChatConnectionStatus connectionStatus;

  const ChatContextHeader({
    required this.reasoningEffort,
    required this.connectionLabel,
    required this.connectionStatus,
    this.projectName,
    this.showProject = true,
    super.key,
  });

  /// Whether the row has anything to show for these facts.
  static bool hasContent({
    required String? projectName,
    required bool showProject,
    required String reasoningEffort,
    required ChatConnectionStatus connectionStatus,
  }) =>
      _showsProject(projectName, showProject) ||
      _showsReasoning(reasoningEffort) ||
      _showsConnection(connectionStatus);

  static bool _showsConnection(ChatConnectionStatus status) =>
      status == ChatConnectionStatus.reconnecting ||
      status == ChatConnectionStatus.offline;

  static bool _showsProject(String? projectName, bool showProject) =>
      showProject || (projectName?.trim().isNotEmpty ?? false);

  /// "default" (and nothing at all) means the profile decides: not worth a chip.
  static bool _showsReasoning(String value) {
    final normalized = value.trim().toLowerCase();
    return normalized.isNotEmpty && normalized != 'default';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final project = projectName?.trim();
    final chips = <Widget>[
      if (_showsProject(projectName, showProject))
        _ContextChip(
          icon: Icons.folder_outlined,
          label: project == null || project.isEmpty
              ? context.l10n.unassigned
              : project,
        ),
      if (_showsReasoning(reasoningEffort))
        _ContextChip(
          icon: Icons.psychology_outlined,
          label: _reasoningLabel(context, reasoningEffort),
        ),
      if (_showsConnection(connectionStatus))
        Semantics(
          label: context.l10n.connection_status_label(
            connectionLabel,
            connectionStatus.label,
          ),
          container: true,
          child: ExcludeSemantics(
            child: _ContextChip(
              icon: Icons.circle,
              iconColor: _connectionColor(context),
              label: connectionLabel,
            ),
          ),
        ),
    ];

    return Material(
      color: tokens.raised,
      child: SizedBox(
        height: 48,
        width: double.infinity,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: HermesSpacing.md,
            vertical: HermesSpacing.xs,
          ),
          child: Row(
            children: [
              for (var i = 0; i < chips.length; i++) ...[
                if (i > 0) const SizedBox(width: HermesSpacing.sm),
                chips[i],
              ],
            ],
          ),
        ),
      ),
    );
  }

  Color _connectionColor(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return switch (connectionStatus) {
      ChatConnectionStatus.connected => tokens.success,
      ChatConnectionStatus.connecting ||
      ChatConnectionStatus.reconnecting => tokens.warning,
      ChatConnectionStatus.offline => tokens.danger,
    };
  }

  String _reasoningLabel(BuildContext context, String value) {
    final normalized = value.trim().toLowerCase();
    return switch (normalized) {
      'none' => context.l10n.reasoning_off,
      'minimal' => context.l10n.reasoning_minimal,
      'low' => context.l10n.reasoning_low,
      'medium' => context.l10n.reasoning_medium,
      'high' => context.l10n.reasoning_high,
      'xhigh' => context.l10n.extra_high,
      'max' => context.l10n.reasoning_max,
      'ultra' => context.l10n.reasoning_ultra,
      _ => value,
    };
  }
}

class _ContextChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? iconColor;

  const _ContextChip({required this.icon, required this.label, this.iconColor});

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(
        horizontal: HermesSpacing.sm,
        vertical: HermesSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: tokens.surface,
        borderRadius: BorderRadius.circular(HermesRadius.sm),
        border: Border.all(color: tokens.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: iconColor ?? tokens.muted),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.typography.label.copyWith(color: tokens.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}
