// Scheduled tasks (Hermes cron jobs): list and manage them.
//
// Two backends behind one screen, chosen by the connection:
//   * the dashboard (`/api/cron/jobs...`), which also lists each job's runs;
//   * the Gateway API itself (`/api/jobs`), for connections with no dashboard.
//     It has no run history, so the run drill-down is not offered there.
//
// Where a task sends its result is the `deliver` field. A task created on
// the phone is sent to Telegram by default: that is where a result reaches
// the person, because the app has no push channel of its own.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hermes_android/core/l10n/l10n.dart';
import 'package:intl/intl.dart';

import '../theme/hermes_theme.dart';
import '../services/connection_manager.dart';
import '../services/gateway_jobs_client.dart';
import '../services/native_apps.dart';
import '../utils/relative_time.dart';
import '../widgets/hermes_components.dart';
import '../widgets/hermes_shell.dart';
import 'chat_screen.dart';

/// Builds the client a [CronScreen] talks to. Only tests pass one.
typedef CronClientFactory = DashboardClient Function(SavedConnection);

/// Where Hermes sends a task's result: the values the phone offers.
const String cronDeliverTelegram = 'telegram';
const String cronDeliverLocal = 'local';
const String cronDeliverOrigin = 'origin';

/// The `deliver` value of [job], or null when the job carries none.
String? cronDeliverOf(Map<String, dynamic> job) {
  final value = job['deliver'];
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// A short, human label for where [deliver] goes; null for "nothing to say".
String? cronDeliveryChipLabel(AppLocalizations l10n, String? deliver) {
  if (deliver == null) return null;
  if (deliver == cronDeliverLocal) return l10n.cron_chip_not_sent;
  if (deliver == cronDeliverOrigin) return l10n.cron_chip_origin;
  if (deliver == cronDeliverTelegram || deliver.startsWith('telegram:')) {
    return l10n.cron_chip_telegram;
  }
  return deliver;
}

class CronScreen extends StatefulWidget {
  final SavedConnection connection;

  /// Shown as a tab inside the workspace shell: no AppBar of its own.
  final bool embedded;

  @visibleForTesting
  final CronClientFactory? clientFactory;

  const CronScreen({
    required this.connection,
    this.embedded = false,
    this.clientFactory,
    super.key,
  });

  @override
  State<CronScreen> createState() => _CronScreenState();
}

class _CronScreenState extends State<CronScreen> {
  late DashboardClient _client;
  List<Map<String, dynamic>> _jobs = [];
  bool _loading = true;
  String? _error;

  /// Desktop-parity run drill-down: expanding a job loads its run sessions
  /// (`GET /api/cron/jobs/{id}/runs`) and each run opens as a resumable
  /// chat transcript. Dashboard connections only: the Gateway API keeps no
  /// run listing, and an always-empty "no runs yet" would mislead.
  final Set<String> _expandedJobs = {};
  final Map<String, List<Session>> _runsByJob = {};
  final Set<String> _runsLoading = {};
  final Map<String, String> _runsErrorByJob = {};

  bool get _hasRuns => _client is! GatewayJobsClient;

  /// Whether this pane was the visible tab at the last dependency change.
  bool _wasActive = true;

  @override
  void initState() {
    super.initState();
    _client = _createClient();
    _loadJobs();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A task can change on the server (Telegram, the agent) while this tab is
    // out of sight: read the list again, quietly, when the tab comes back.
    final active = HermesPaneVisibility.of(context);
    if (active && !_wasActive && !_loading) unawaited(_loadJobs(quiet: true));
    _wasActive = active;
  }

  DashboardClient _createClient() {
    final connection = widget.connection;
    final factory = widget.clientFactory;
    if (factory != null) return factory(connection);
    if (!connection.hasDashboard) return GatewayJobsClient(connection);
    return DashboardClient(
      host: connection.host,
      port: connection.dashboardPort,
      pathPrefix: connection.dashboardPrefix ?? '',
      proxied: connection.dashboardProxied,
      useHttps: connection.useHttps,
      username: connection.dashboardUsername,
      password: connection.dashboardPassword,
      gatewayProfile: connection.gatewayProfile,
    );
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  /// Reads the task list. [quiet] keeps the cards on screen meanwhile and
  /// leaves them alone if the read fails.
  Future<void> _loadJobs({bool quiet = false}) async {
    if (!quiet) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final items = await _client.getCronJobs();

      if (!mounted) return;
      setState(() {
        _jobs = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || quiet) return;
      // A connection that looks as if it had a dashboard (plain HTTP to the
      // gateway port) may have none: the Gateway API serves the jobs itself,
      // so try it before reporting the dashboard's failure.
      if (widget.clientFactory == null && _client is! GatewayJobsClient) {
        final gateway = GatewayJobsClient(widget.connection);
        try {
          final items = await gateway.getCronJobs();
          if (!mounted) {
            gateway.close();
            return;
          }
          _client.close();
          _client = gateway;
          setState(() {
            _jobs = items;
            _loading = false;
          });
          return;
        } catch (_) {
          gateway.close();
          if (!mounted) return;
        }
      }
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  bool _isPaused(Map<String, dynamic> job) {
    return job['paused_at'] != null ||
        job['state'] == 'paused' ||
        job['enabled'] == false;
  }

  String _scheduleDisplay(Map<String, dynamic> job) {
    final display = job['schedule_display'] as String?;
    if (display != null && display.isNotEmpty) return display;

    final schedule = job['schedule'];
    if (schedule is String) return schedule;
    if (schedule is Map) {
      return schedule['display'] as String? ??
          schedule['run_at'] as String? ??
          schedule.toString();
    }
    return '';
  }

  String _jobName(Map<String, dynamic> job) {
    final name = job['name'];
    if (name is String && name.isNotEmpty) return name;
    final id = job['id'];
    if (id is String && id.isNotEmpty) return id;
    return context.l10n.cron_untitled;
  }

  String _jobPrompt(Map<String, dynamic> job) {
    final prompt = job['prompt'] as String? ?? '';
    if (prompt.length > 120) return '${prompt.substring(0, 120)}…';
    return prompt;
  }

  /// A run time from the server (ISO 8601) in the phone's zone and language:
  /// just the time for today, date and time otherwise. Anything that is not a
  /// timestamp is shown as the server sent it.
  String _whenLabel(String raw) {
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return raw;
    try {
      final locale = Localizations.localeOf(context).toString();
      final local = parsed.toLocal();
      final now = DateTime.now();
      final sameDay =
          local.year == now.year &&
          local.month == now.month &&
          local.day == now.day;
      return sameDay
          ? DateFormat.Hm(locale).format(local)
          : DateFormat.MMMd(locale).add_Hm().format(local);
    } catch (_) {
      return raw;
    }
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    final tokens = HermesTokens.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? tokens.warning : null,
      ),
    );
  }

  Future<void> _togglePause(Map<String, dynamic> job) async {
    final jobId = job['id'] as String? ?? '';
    if (jobId.isEmpty) return;
    final paused = _isPaused(job);

    try {
      await _client.setJobPaused(jobId, paused: !paused);
      if (paused) {
        job.remove('paused_at');
        job['state'] = 'active';
        job['enabled'] = true;
      } else {
        job['paused_at'] = DateTime.now().toIso8601String();
        job['state'] = 'paused';
      }
      if (mounted) {
        setState(() {});
        _toast(paused ? context.l10n.job_resumed : context.l10n.job_paused);
      }
    } catch (e) {
      if (mounted) _toast(context.l10n.failed(e), error: true);
    }
  }

  Future<void> _deleteJob(Map<String, dynamic> job) async {
    final jobId = job['id'] as String? ?? '';
    if (jobId.isEmpty) return;
    final name = _jobName(job);
    final tokens = HermesTokens.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.delete_cron_job),
        content: Text(ctx.l10n.delete_2(name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: tokens.danger),
            child: Text(ctx.l10n.delete),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await _client.deleteJob(jobId);
      if (mounted) {
        setState(() => _jobs.removeWhere((j) => j['id'] == jobId));
        _toast(context.l10n.deleted(name));
      }
    } catch (e) {
      if (mounted) _toast(context.l10n.delete_failed(e), error: true);
    }
  }

  Future<void> _triggerJob(Map<String, dynamic> job) async {
    final jobId = job['id'] as String? ?? '';
    if (jobId.isEmpty) return;
    try {
      await _client.triggerJob(jobId);
      if (mounted) _toast(context.l10n.job_triggered);
    } catch (e) {
      if (mounted) _toast(context.l10n.failed(e), error: true);
    }
  }

  void _toggleRuns(String jobId) {
    if (jobId.isEmpty) return;
    setState(() {
      if (_expandedJobs.remove(jobId)) {
        _runsErrorByJob.remove(jobId);
      } else {
        _expandedJobs.add(jobId);
      }
    });
    if (_expandedJobs.contains(jobId)) unawaited(_loadRuns(jobId));
  }

  Future<void> _loadRuns(String jobId) async {
    if (_runsLoading.contains(jobId)) return;
    setState(() {
      _runsLoading.add(jobId);
      _runsErrorByJob.remove(jobId);
    });
    try {
      final runs = await _client.getCronJobRuns(jobId);
      if (!mounted) return;
      setState(() {
        _runsByJob[jobId] = runs;
        _runsLoading.remove(jobId);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _runsLoading.remove(jobId);
        _runsErrorByJob[jobId] = e.toString();
      });
    }
  }

  /// Opens one cron run's transcript. A run is an ordinary session row
  /// (`cron_{job_id}_{timestamp}`), so the regular ChatScreen resume path
  /// shows the full transcript — same as the desktop's run-pill click.
  void _openRun(Session run) {
    nativeAppsTarget.selectIfChanged(nativeAppsOwner(widget.connection));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatScreen(connection: widget.connection, session: run),
      ),
    );
  }

  Widget _buildRunsSection(String jobId) {
    final tokens = HermesTokens.of(context);
    if (_runsLoading.contains(jobId)) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: HermesSpacing.md),
        child: Center(
          child: SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    final error = _runsErrorByJob[jobId];
    if (error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: HermesSpacing.sm),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: tokens.warning),
            const SizedBox(width: HermesSpacing.sm),
            Expanded(
              child: Text(
                context.l10n.couldn_t_load_runs(error),
                style: tokens.typography.label.copyWith(color: tokens.warning),
              ),
            ),
            TextButton(
              onPressed: () => unawaited(_loadRuns(jobId)),
              child: Text(context.l10n.retry),
            ),
          ],
        ),
      );
    }
    final runs = _runsByJob[jobId] ?? const <Session>[];
    if (runs.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: HermesSpacing.sm),
        child: Text(
          context.l10n.no_runs_yet,
          style: tokens.typography.label.copyWith(color: tokens.muted),
        ),
      );
    }
    final now = DateTime.now();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final run in runs)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              run.isActive
                  ? Icons.play_circle_outline
                  : Icons.check_circle_outline,
              size: 18,
              color: run.isActive ? tokens.success : tokens.muted,
            ),
            title: Text(
              run.title.isEmpty ? context.l10n.cron_run : run.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: tokens.typography.body,
            ),
            subtitle: run.preview.isEmpty
                ? null
                : Text(
                    run.preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: tokens.typography.label.copyWith(
                      color: tokens.muted,
                    ),
                  ),
            trailing: Text(
              formatRelativeTime(now, run.lastActive, l10n: context.l10n),
              style: tokens.typography.label.copyWith(color: tokens.muted),
            ),
            onTap: () => _openRun(run),
          ),
      ],
    );
  }

  /// Opens the "new task" dialog. Public to the tests through the FAB.
  Future<void> _showAddJobDialog() async {
    final result = await _showJobDialog(
      title: context.l10n.add_cron_job,
      actionLabel: context.l10n.add,
      initialDeliver: cronDeliverTelegram,
    );
    if (result == null || !mounted) return;

    try {
      final created = await _client.createJob(
        name: result['name']?.toString() ?? '',
        prompt: result['prompt']?.toString() ?? '',
        schedule: result['schedule']?.toString() ?? '',
        deliver: result['deliver']?.toString() ?? cronDeliverTelegram,
      );
      if (result['no_agent'] == true) {
        final jobId =
            created['id']?.toString() ?? created['job_id']?.toString() ?? '';
        if (jobId.isNotEmpty) {
          await _client.updateJob(jobId, {'no_agent': true});
        }
      }
      if (!mounted) return;
      _toast(context.l10n.cron_job_added);
      await _loadJobs();
    } catch (e) {
      if (mounted) _toast(context.l10n.failed_to_add_job(e), error: true);
    }
  }

  Future<void> _showEditJobDialog(Map<String, dynamic> job) async {
    final initialName = _jobName(job);
    final initialPrompt = job['prompt'] as String? ?? '';
    final initialSchedule = _scheduleDisplay(job);
    final initialNoAgent = job['no_agent'] == true;
    final initialDeliver = cronDeliverOf(job);

    final result = await _showJobDialog(
      title: context.l10n.edit_cron_job,
      actionLabel: context.l10n.save,
      initialName: initialName,
      initialPrompt: initialPrompt,
      initialSchedule: initialSchedule,
      initialNoAgent: initialNoAgent,
      initialDeliver: initialDeliver ?? cronDeliverLocal,
    );
    if (result == null || !mounted) return;

    final jobId = job['id'] as String? ?? '';
    if (jobId.isEmpty) return;

    // Only what the person changed goes to the server: re-sending an
    // unchanged schedule would re-plan the task, and re-sending a delivery
    // the app does not know would overwrite it.
    final updates = <String, dynamic>{};
    if (result['name'] != initialName) updates['name'] = result['name'];
    if (result['prompt'] != initialPrompt) updates['prompt'] = result['prompt'];
    if (result['schedule'] != initialSchedule) {
      updates['schedule'] = result['schedule'];
    }
    if (result['no_agent'] != initialNoAgent) {
      updates['no_agent'] = result['no_agent'];
    }
    if (result['deliver'] != (initialDeliver ?? cronDeliverLocal)) {
      updates['deliver'] = result['deliver'];
    }
    if (updates.isEmpty) return;

    try {
      await _client.updateJob(jobId, updates);
      if (!mounted) return;
      _toast(context.l10n.cron_job_updated);
      await _loadJobs();
    } catch (e) {
      if (mounted) _toast(context.l10n.failed_to_update_job(e), error: true);
    }
  }

  Future<Map<String, dynamic>?> _showJobDialog({
    required String title,
    required String actionLabel,
    String initialName = '',
    String initialPrompt = '',
    String initialSchedule = '',
    bool initialNoAgent = false,
    String initialDeliver = cronDeliverTelegram,
  }) {
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _JobDialog(
        title: title,
        actionLabel: actionLabel,
        initialName: initialName,
        initialPrompt: initialPrompt,
        initialSchedule: initialSchedule,
        initialNoAgent: initialNoAgent,
        initialDeliver: initialDeliver,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    return Scaffold(
      backgroundColor: widget.embedded ? Colors.transparent : tokens.surface,
      appBar: widget.embedded
          ? null
          : AppBar(
              title: Text(context.l10n.cron_jobs),
              actions: [
                IconButton(
                  icon: const Icon(Icons.refresh),
                  onPressed: _loading ? null : _loadJobs,
                ),
              ],
            ),
      body: _buildBody(tokens),
      floatingActionButton: FloatingActionButton(
        tooltip: context.l10n.add_new_cron_job,
        onPressed: _loading ? null : _showAddJobDialog,
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildBody(HermesTokens tokens) {
    if (_loading) return const LoadingSkeleton();

    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          child: ErrorState(
            title: context.l10n.failed_to_load_cron_jobs,
            message: _error!,
            onRetry: _loadJobs,
          ),
        ),
      );
    }

    if (_jobs.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          child: EmptyState(
            icon: Icons.schedule,
            title: context.l10n.no_cron_jobs,
            message: context.l10n.cron_empty_hint,
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadJobs,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(
          HermesSpacing.lg,
          HermesSpacing.md,
          HermesSpacing.lg,
          // Room for the add button over the last card.
          88,
        ),
        itemCount: _jobs.length,
        separatorBuilder: (_, _) => const SizedBox(height: HermesSpacing.md),
        itemBuilder: (context, index) => _buildJobCard(_jobs[index], tokens),
      ),
    );
  }

  Widget _buildJobCard(Map<String, dynamic> job, HermesTokens tokens) {
    final l10n = context.l10n;
    final name = _jobName(job);
    final prompt = _jobPrompt(job);
    final schedule = _scheduleDisplay(job);
    final paused = _isPaused(job);
    final lastRun = job['last_run_at'] as String?;
    final nextRun = job['next_run_at'] as String?;
    final isNoAgent = job['no_agent'] == true;
    final jobId = job['id'] as String? ?? '';
    final expanded = _expandedJobs.contains(jobId);
    final delivery = cronDeliveryChipLabel(l10n, cronDeliverOf(job));
    final accent = paused ? tokens.muted : tokens.accent;

    return HermesCard(
      // On a dashboard, a tap expands the run drill-down (desktop parity:
      // cron output lives under the job). With only the Gateway API there
      // are no runs to show, so a tap edits the task instead.
      onTap: _hasRuns
          ? () => _toggleRuns(jobId)
          : () => _showEditJobDialog(job),
      padding: const EdgeInsets.fromLTRB(
        HermesSpacing.lg,
        HermesSpacing.md,
        HermesSpacing.xs,
        HermesSpacing.md,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(HermesRadius.sm),
                ),
                child: Icon(
                  paused ? Icons.pause : Icons.schedule,
                  size: 18,
                  color: accent,
                ),
              ),
              const SizedBox(width: HermesSpacing.md),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: tokens.typography.section.copyWith(
                          color: paused ? tokens.muted : tokens.onSurface,
                        ),
                      ),
                      if (prompt.isNotEmpty) ...[
                        const SizedBox(height: HermesSpacing.xs),
                        Text(
                          prompt,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.typography.body.copyWith(
                            color: tokens.muted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: tokens.muted),
                onSelected: (action) {
                  if (action == 'trigger') _triggerJob(job);
                  if (action == 'edit') _showEditJobDialog(job);
                  if (action == 'toggle') _togglePause(job);
                  if (action == 'delete') _deleteJob(job);
                },
                itemBuilder: (_) => [
                  _menuItem('trigger', Icons.play_arrow, l10n.trigger_now),
                  _menuItem('edit', Icons.edit_outlined, l10n.edit),
                  _menuItem(
                    'toggle',
                    paused ? Icons.play_arrow : Icons.pause,
                    paused ? l10n.cron_resume : l10n.cron_pause,
                  ),
                  _menuItem(
                    'delete',
                    Icons.delete_outline,
                    l10n.delete,
                    color: tokens.danger,
                  ),
                ],
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(
              top: HermesSpacing.sm,
              right: HermesSpacing.md,
            ),
            child: Wrap(
              spacing: HermesSpacing.sm,
              runSpacing: HermesSpacing.xs,
              children: [
                if (schedule.isNotEmpty)
                  _MetaChip(icon: Icons.repeat, text: schedule, mono: true),
                if (delivery != null)
                  _MetaChip(icon: Icons.send_outlined, text: delivery),
                if (isNoAgent) _MetaChip(text: l10n.cron_script_chip),
                if (paused)
                  StatusChip(
                    status: HermesStatus.idle,
                    label: l10n.cron_paused_chip,
                  ),
              ],
            ),
          ),
          if ((nextRun != null && nextRun.isNotEmpty) ||
              (lastRun != null && lastRun.isNotEmpty))
            Padding(
              padding: const EdgeInsets.only(
                top: HermesSpacing.sm,
                right: HermesSpacing.md,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (nextRun != null && nextRun.isNotEmpty)
                    Text(
                      l10n.next(_whenLabel(nextRun)),
                      style: tokens.typography.label.copyWith(
                        color: tokens.muted,
                      ),
                    ),
                  if (lastRun != null && lastRun.isNotEmpty)
                    Text(
                      l10n.last(_whenLabel(lastRun)),
                      style: tokens.typography.label.copyWith(
                        color: tokens.muted,
                      ),
                    ),
                ],
              ),
            ),
          if (_hasRuns && expanded) ...[
            const Divider(height: HermesSpacing.xl),
            Padding(
              padding: const EdgeInsets.only(right: HermesSpacing.md),
              child: _buildRunsSection(jobId),
            ),
          ],
        ],
      ),
    );
  }

  PopupMenuItem<String> _menuItem(
    String value,
    IconData icon,
    String label, {
    Color? color,
  }) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: HermesSpacing.sm),
          Text(label, style: color == null ? null : TextStyle(color: color)),
        ],
      ),
    );
  }
}

/// A small outlined fact about a task: its schedule, where it sends results.
class _MetaChip extends StatelessWidget {
  final IconData? icon;
  final String text;
  final bool mono;

  const _MetaChip({this.icon, required this.text, this.mono = false});

  @override
  Widget build(BuildContext context) {
    final tokens = HermesTokens.of(context);
    final style = (mono ? tokens.typography.mono : tokens.typography.label)
        .copyWith(color: tokens.muted, fontSize: 12);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: HermesSpacing.sm,
        vertical: HermesSpacing.xs,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(HermesRadius.sm),
        border: Border.all(color: tokens.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: tokens.muted),
            const SizedBox(width: HermesSpacing.xs),
          ],
          Flexible(child: Text(text, style: style)),
        ],
      ),
    );
  }
}

/// The add / edit form. A widget of its own so the text controllers live
/// exactly as long as the dialog, including its closing animation.
class _JobDialog extends StatefulWidget {
  final String title;
  final String actionLabel;
  final String initialName;
  final String initialPrompt;
  final String initialSchedule;
  final bool initialNoAgent;
  final String initialDeliver;

  const _JobDialog({
    required this.title,
    required this.actionLabel,
    required this.initialName,
    required this.initialPrompt,
    required this.initialSchedule,
    required this.initialNoAgent,
    required this.initialDeliver,
  });

  @override
  State<_JobDialog> createState() => _JobDialogState();
}

class _JobDialogState extends State<_JobDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initialName,
  );
  late final TextEditingController _prompt = TextEditingController(
    text: widget.initialPrompt,
  );
  late final TextEditingController _schedule = TextEditingController(
    text: widget.initialSchedule,
  );
  late bool _noAgent = widget.initialNoAgent;
  late String _deliver = widget.initialDeliver;

  @override
  void dispose() {
    _name.dispose();
    _prompt.dispose();
    _schedule.dispose();
    super.dispose();
  }

  /// The delivery choices. A value the app does not offer (a Telegram chat
  /// id, "origin") stays selectable, so editing a task made elsewhere never
  /// silently changes where it goes.
  List<DropdownMenuItem<String>> _deliverItems(AppLocalizations l10n) {
    final current = widget.initialDeliver;
    return [
      DropdownMenuItem(
        value: cronDeliverTelegram,
        child: Text(l10n.cron_deliver_telegram),
      ),
      DropdownMenuItem(
        value: cronDeliverLocal,
        child: Text(l10n.cron_deliver_none),
      ),
      if (current != cronDeliverTelegram && current != cronDeliverLocal)
        DropdownMenuItem(
          value: current,
          child: Text(
            current == cronDeliverOrigin
                ? l10n.cron_deliver_origin
                : l10n.cron_deliver_other(current),
          ),
        ),
    ];
  }

  void _submit() {
    final l10n = context.l10n;
    final name = _name.text.trim();
    final prompt = _prompt.text.trim();
    final schedule = _schedule.text.trim();

    if (name.isEmpty || prompt.isEmpty || schedule.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l10n.name_prompt_and_schedule_are_required)),
      );
      return;
    }

    Navigator.pop(context, {
      'name': name,
      'prompt': prompt,
      'schedule': schedule,
      'no_agent': _noAgent,
      'deliver': _deliver,
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              decoration: InputDecoration(
                labelText: l10n.name,
                hintText: l10n.e_g_daily_backup,
              ),
            ),
            const SizedBox(height: HermesSpacing.md),
            TextField(
              controller: _prompt,
              decoration: InputDecoration(
                labelText: l10n.prompt,
                hintText: l10n.what_should_the_agent_do,
              ),
              maxLines: 3,
            ),
            const SizedBox(height: HermesSpacing.md),
            TextField(
              controller: _schedule,
              decoration: InputDecoration(
                labelText: l10n.schedule,
                hintText: l10n.e_g_0_9_or_every_2h,
              ),
            ),
            const SizedBox(height: HermesSpacing.md),
            DropdownButtonFormField<String>(
              key: const Key('cron-deliver'),
              initialValue: _deliver,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: l10n.cron_deliver_label,
                helperText: _deliver == cronDeliverTelegram
                    ? l10n.cron_deliver_hint
                    : null,
                helperMaxLines: 2,
              ),
              items: _deliverItems(l10n),
              onChanged: (value) =>
                  setState(() => _deliver = value ?? _deliver),
            ),
            const SizedBox(height: HermesSpacing.sm),
            SwitchListTile(
              value: _noAgent,
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.script_only_no_agent),
              subtitle: Text(l10n.use_for_cron_jobs_backed_by_scripts),
              onChanged: (value) => setState(() => _noAgent = value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.cancel),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.actionLabel)),
      ],
    );
  }
}
