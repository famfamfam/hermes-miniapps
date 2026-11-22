import 'dart:convert';

import 'package:http/http.dart' as http;

import 'connection_manager.dart';

/// Cron jobs served by the Gateway API itself (`/api/jobs`), for connections with no dashboard.
///
/// Same surface as the dashboard client's cron methods, so the Cron screen needs no second code path.
/// The gateway has no per-job run listing: runs stay empty.
class GatewayJobsClient extends DashboardClient {
  GatewayJobsClient(SavedConnection connection, {http.Client? httpClient})
    : _base = SavedConnection.joinBaseUrl(
        connection.baseUrl,
        connection.gatewayPrefix ?? '',
      ),
      _key = connection.apiKey,
      _own = httpClient ?? http.Client(),
      super(
        host: connection.host,
        port: connection.port,
        useHttps: connection.useHttps,
        pathPrefix: connection.gatewayPrefix ?? '',
        proxied: true,
      );

  final String _base;
  final String _key;
  final http.Client _own;

  Future<Map<String, dynamic>> _call(
    String method,
    String path, [
    Map<String, dynamic>? body,
  ]) async {
    final request = http.Request(method, Uri.parse('$_base/api/$path'))
      ..headers['Authorization'] = 'Bearer $_key'
      ..headers['Content-Type'] = 'application/json';
    if (body != null) request.body = jsonEncode(body);
    final response = await http.Response.fromStream(
      await _own.send(request).timeout(ApiClient.requestTimeout),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw DashboardHttpException(response.statusCode, _reason(response.body));
    }
    final text = response.body.trim();
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : {'data': decoded};
  }

  static String _id(String jobId) => Uri.encodeComponent(jobId);

  /// The `{"error": "..."}` text of a refusal, so the person sees why.
  static String? _reason(String body) {
    try {
      final decoded = jsonDecode(body);
      final error = decoded is Map ? decoded['error'] : null;
      return error is String && error.isNotEmpty ? error : null;
    } catch (_) {
      return null;
    }
  }

  /// The gateway's PATCH takes only name, schedule, prompt, deliver, skills,
  /// repeat and enabled: `no_agent` gets a 400 or is dropped.
  @override
  bool get canSetScriptOnly => false;

  @override
  Future<List<Map<String, dynamic>>> getCronJobs() async {
    final jobs = (await _call('GET', 'jobs'))['jobs'];
    return (jobs as List? ?? []).whereType<Map<String, dynamic>>().toList();
  }

  @override
  Future<List<Session>> getCronJobRuns(String jobId, {int limit = 20}) async {
    // Every run is an ordinary session row (`cron_{job id}_{timestamp}`) that
    // the session list serves most-recent-first, so the run drill-down works
    // without the dashboard's dedicated runs endpoint.
    final prefix = 'cron_${jobId}_';
    final runs = <Session>[];
    var offset = 0;
    while (runs.length < limit && offset < 1000) {
      final data = await _call('GET', 'sessions?limit=200&offset=$offset');
      final list = data['data'] as List? ?? const [];
      final page = list
          .whereType<Map<String, dynamic>>()
          .map(Session.fromJson)
          .toList();
      for (final session in page) {
        if (session.id.startsWith(prefix)) {
          runs.add(session);
          if (runs.length >= limit) break;
        }
      }
      if (data['has_more'] != true || page.isEmpty) break;
      offset += page.length;
    }
    return runs;
  }

  @override
  Future<Map<String, dynamic>> createJob({
    required String prompt,
    required String schedule,
    String name = '',
    String deliver = 'local',
  }) => _call('POST', 'jobs', {
    'prompt': prompt,
    'schedule': schedule,
    'name': name,
    'deliver': deliver,
  });

  @override
  Future<Map<String, dynamic>> updateJob(
    String jobId,
    Map<String, dynamic> updates, {
    Duration timeout = ApiClient.requestTimeout,
  }) => _call('PATCH', 'jobs/${_id(jobId)}', updates);

  @override
  Future<Map<String, dynamic>> setJobPaused(
    String jobId, {
    required bool paused,
  }) => _call('POST', 'jobs/${_id(jobId)}/${paused ? 'pause' : 'resume'}');

  @override
  Future<Map<String, dynamic>> triggerJob(String jobId) =>
      _call('POST', 'jobs/${_id(jobId)}/run');

  @override
  Future<void> deleteJob(String jobId) async {
    await _call('DELETE', 'jobs/${_id(jobId)}');
  }

  @override
  void close() {
    _own.close();
    super.close();
  }
}
