/// The More destination pane.
///
/// The fourth top-level destination of the validated navigation
/// (Home / Projects / Activity / More). Phase 0 of
/// the roadmap requires the shell to expose every
/// capability instead of hiding it in a drawer, and requires an embedded
/// Dashboard fallback entry so no capability is blocked while the native UX
/// catches up.
///
/// Two rules drive this file:
///
/// 1. **Never hide a capability.** A surface that is not built yet is listed
///    as `Coming next`, and a surface the server cannot serve is listed as
///    disabled *with a precise reason* — never removed from the list.
/// 2. **Explain, do not crash.** Availability is data, so tests can assert it
///    without pumping a widget, and the pane simply renders it.
library;

import 'package:flutter/material.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart'
    show SurfacesStrings, SurfacesText;

import '../theme/hermes_theme.dart';
import 'hermes_components.dart';

import 'package:hermes_android/core/l10n/l10n.dart';
/// Whether a More entry can be opened right now, and why not when it cannot.
enum MoreEntryAvailability {
  /// Usable now.
  available,

  /// Native surface not implemented yet; listed so it stays discoverable.
  comingSoon,

  /// The connected Hermes instance cannot serve it (for example: no
  /// reachable dashboard). Disabled with an explanation, never hidden.
  unavailable,
}

/// One row of the More pane.
@immutable
class MoreEntry {
  /// Stable identifier used for routing and tests. Never localized.
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
  final MoreEntryAvailability availability;

  /// Why the entry is disabled. Required for [MoreEntryAvailability.unavailable]
  /// so the UI can always tell the user what to fix.
  final String? unavailableReason;

  const MoreEntry({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    this.availability = MoreEntryAvailability.available,
    this.unavailableReason,
  }) : assert(
         availability != MoreEntryAvailability.unavailable ||
             unavailableReason != null,
         'A disabled entry must explain itself',
       );

  bool get isSelectable => availability == MoreEntryAvailability.available;
}

/// A titled group of [MoreEntry] rows.
@immutable
class MoreSection {
  final String title;
  final List<MoreEntry> entries;

  const MoreSection({required this.title, required this.entries});
}

/// Builds the More menu for the current connection.
///
/// [dashboardReachable] gates the surfaces served by the Hermes Dashboard.
/// Local device settings stay reachable regardless, so the user can always
/// repair a broken connection from inside the app.
///
/// [lean] is the menu of a connection that only offers the Gateway API (no
/// dashboard, no projects). There the entries that cannot work are left out
/// instead of being listed greyed-out, Apps and Tasks are tabs of their own,
/// and [MorePane.footnote] says in one line why the rest is not here.
List<MoreSection> buildMoreSections({
  required bool dashboardReachable,
  required AppLocalizations l10n,
  bool gatewayCron = false,
  bool lean = false,
}) {
  if (lean) {
    return [
      MoreSection(
        title: '',
        entries: [
          MoreEntry(
            id: 'settings',
            title: l10n.settings,
            subtitle: l10n.connection_appearance_and_device_preferences,
            icon: Icons.settings_outlined,
          ),
        ],
      ),
    ];
  }

  MoreEntryAvailability dashboardBacked() => dashboardReachable
      ? MoreEntryAvailability.available
      : MoreEntryAvailability.unavailable;
  String? dashboardReason() => dashboardReachable
      ? null
      : l10n.needs_a_reachable_hermes_dashboard_check_the_host_port_and;

  final apps = SurfacesStrings.forLanguage(l10n.localeName);

  return [
    MoreSection(
      title: l10n.workspace,
      entries: [
        MoreEntry(
          id: 'unassigned',
          title: l10n.unassigned_chats,
          subtitle: l10n.chats_that_are_not_assigned_to_a_project,
          icon: Icons.inbox_outlined,
        ),
        MoreEntry(
          id: 'archived-quick',
          title: l10n.archived_quick_chats,
          subtitle: l10n.review_or_promote_quick_chats_past_their_retention_period,
          icon: Icons.archive_outlined,
        ),
        MoreEntry(
          id: 'files',
          title: l10n.files,
          subtitle: l10n.browse_the_miniserver_folders_behind_your_projects,
          icon: Icons.folder_open_outlined,
          availability: dashboardBacked(),
          unavailableReason: dashboardReason(),
        ),
        MoreEntry(
          id: 'assets',
          title: l10n.assets,
          subtitle: l10n.artifacts_attachments_and_generated_media,
          icon: Icons.image_outlined,
          availability: MoreEntryAvailability.unavailable,
          unavailableReason:
              l10n.needs_a_server_authoritative_assets_index_in_the_hermes_gateway,
        ),
        MoreEntry(
          id: 'apps',
          title: apps(SurfacesText.appsPageTitle),
          subtitle: apps(SurfacesText.appsEntrySubtitle),
          icon: Icons.apps_outlined,
        ),
      ],
    ),
    MoreSection(
      title: l10n.organization,
      entries: [
        MoreEntry(
          id: 'pin-batch-undo',
          title: l10n.pin_batch_and_undo,
          subtitle: l10n.cross_device_ordering_and_reversible_bulk_organization,
          icon: Icons.push_pin_outlined,
          availability: MoreEntryAvailability.unavailable,
          unavailableReason:
              l10n.needs_durable_pin_ordering_batch_mutation_and_undo_contracts_in,
        ),
        MoreEntry(
          id: 'ai-filing',
          title: l10n.ai_assisted_filing,
          subtitle: l10n.suggest_projects_and_learn_from_your_corrections,
          icon: Icons.auto_fix_high_outlined,
          availability: MoreEntryAvailability.unavailable,
          unavailableReason:
              l10n.needs_a_correction_aware_filing_contract_in_the_hermes_gateway,
        ),
      ],
    ),
    MoreSection(
      title: l10n.automation,
      entries: [
        MoreEntry(
          id: 'cron',
          title: l10n.cron,
          subtitle: l10n.scheduled_jobs_and_their_last_runs,
          icon: Icons.schedule_outlined,
          availability: gatewayCron
              ? MoreEntryAvailability.available
              : dashboardBacked(),
          unavailableReason: gatewayCron ? null : dashboardReason(),
        ),
        MoreEntry(
          id: 'skills',
          title: l10n.skills_and_tools,
          subtitle: l10n.what_hermes_knows_how_to_do,
          icon: Icons.auto_awesome_outlined,
          availability: dashboardBacked(),
          unavailableReason: dashboardReason(),
        ),
        MoreEntry(
          id: 'memory',
          title: l10n.memory,
          subtitle: l10n.durable_facts_hermes_keeps_about_you,
          icon: Icons.psychology_outlined,
          availability: dashboardBacked(),
          unavailableReason: dashboardReason(),
        ),
      ],
    ),
    MoreSection(
      title: l10n.more_section_system,
      entries: [
        MoreEntry(
          id: 'settings',
          title: l10n.settings,
          subtitle: l10n.connection_appearance_and_device_preferences,
          icon: Icons.settings_outlined,
        ),
        MoreEntry(
          id: 'dashboard',
          title: l10n.open_the_hermes_dashboard,
          subtitle:
              l10n.everything_not_yet_native_in_the_authenticated_web_dashboard,
          icon: Icons.open_in_new,
          availability: dashboardBacked(),
          unavailableReason: dashboardReason(),
        ),
      ],
    ),
  ];
}

/// Renders the More menu.
class MorePane extends StatelessWidget {
  final List<MoreSection> sections;
  final ValueChanged<MoreEntry> onSelect;

  /// One calm line under the list, for what this connection cannot offer.
  final String? footnote;

  const MorePane({
    required this.sections,
    required this.onSelect,
    this.footnote,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: HermesSpacing.xl),
      children: [
        for (final section in sections) ...[
          if (section.title.isNotEmpty)
            SectionHeader(title: section.title)
          else
            const SizedBox(height: HermesSpacing.md),
          for (final entry in section.entries)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                HermesSpacing.lg,
                0,
                HermesSpacing.lg,
                HermesSpacing.md,
              ),
              child: _MoreEntryCard(entry: entry, onSelect: onSelect),
            ),
        ],
        if (footnote != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              HermesSpacing.lg,
              HermesSpacing.sm,
              HermesSpacing.lg,
              0,
            ),
            child: Text(
              footnote!,
              style: tokens.typography.label.copyWith(color: tokens.muted),
            ),
          ),
      ],
    );
  }
}

class _MoreEntryCard extends StatelessWidget {
  final MoreEntry entry;
  final ValueChanged<MoreEntry> onSelect;

  const _MoreEntryCard({required this.entry, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final dimmed = !entry.isSelectable;
    final titleColor = dimmed ? tokens.muted : tokens.onSurface;

    return Semantics(
      button: entry.isSelectable,
      enabled: entry.isSelectable,
      label: entry.title,
      child: HermesCard(
        onTap: entry.isSelectable ? () => onSelect(entry) : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: (dimmed ? tokens.muted : tokens.accent).withValues(
                  alpha: 0.14,
                ),
                borderRadius: BorderRadius.circular(HermesRadius.sm),
              ),
              child: Icon(
                entry.icon,
                size: 20,
                color: dimmed ? tokens.muted : tokens.accent,
              ),
            ),
            const SizedBox(width: HermesSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // A Wrap rather than a Row: at a large text scale the badge
                  // moves to its own line instead of overflowing the card.
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: HermesSpacing.sm,
                    runSpacing: HermesSpacing.xs,
                    children: [
                      Text(
                        entry.title,
                        style: tokens.typography.section.copyWith(
                          color: titleColor,
                        ),
                      ),
                      if (entry.availability ==
                          MoreEntryAvailability.comingSoon)
                        StatusChip(
                          status: HermesStatus.idle,
                          label: context.l10n.coming_next,
                        ),
                    ],
                  ),
                  const SizedBox(height: HermesSpacing.xs),
                  Text(
                    entry.subtitle,
                    style: tokens.typography.body.copyWith(color: tokens.muted),
                  ),
                  if (entry.availability ==
                      MoreEntryAvailability.unavailable) ...[
                    const SizedBox(height: HermesSpacing.xs),
                    Text(
                      entry.unavailableReason!,
                      style: tokens.typography.label.copyWith(
                        color: tokens.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
