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
      throw DashboardHttpException(response.statusCode);
    }
    final text = response.body.trim();
    if (text.isEmpty) return const {};
    final decoded = jsonDecode(text);
    return decoded is Map<String, dynamic> ? decoded : {'data': decoded};
  }

  static String _id(String jobId) => Uri.encodeComponent(jobId);

  @override
  Future<List<Map<String, dynamic>>> getCronJobs() async {
    final jobs = (await _call('GET', 'jobs'))['jobs'];
    return (jobs as List? ?? []).whereType<Map<String, dynamic>>().toList();
  }

  @override
  Future<List<Session>> getCronJobRuns(String jobId, {int limit = 20}) async =>
      const [];

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
