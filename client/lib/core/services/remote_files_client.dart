import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'connection_manager.dart';
import 'desktop_gateway_client.dart';

class RemoteDirectory {
  final String path;
  final String? branch;

  const RemoteDirectory({required this.path, this.branch});
}

class RemoteFileEntry {
  final String name;
  final String path;
  final bool isDirectory;

  const RemoteFileEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
  });

  factory RemoteFileEntry.fromJson(Map<String, dynamic> json) =>
      RemoteFileEntry(
        name: json['name'] as String? ?? '',
        path: json['path'] as String? ?? '',
        isDirectory: json['isDirectory'] == true,
      );
}

class RemoteTextPreview {
  final String path;
  final String text;
  final String language;
  final String mimeType;
  final int byteSize;
  final bool binary;
  final bool truncated;

  const RemoteTextPreview({
    required this.path,
    required this.text,
    required this.language,
    required this.mimeType,
    required this.byteSize,
    required this.binary,
    required this.truncated,
  });

  factory RemoteTextPreview.fromJson(Map<String, dynamic> json) =>
      RemoteTextPreview(
        path: json['path'] as String? ?? '',
        text: json['text'] as String? ?? '',
        language: json['language'] as String? ?? 'text',
        mimeType: json['mimeType'] as String? ?? 'text/plain',
        byteSize: (json['byteSize'] as num?)?.toInt() ?? 0,
        binary: json['binary'] == true,
        truncated: json['truncated'] == true,
      );
}

class RemoteFileDownload {
  final String filename;
  final Uint8List bytes;

  RemoteFileDownload({required this.filename, required List<int> bytes})
    : bytes = Uint8List.fromList(bytes);
}

abstract class RemoteFilesDataSource {
  Future<RemoteDirectory> defaultDirectory();
  Future<List<RemoteFileEntry>> listDirectory(String path);
  Future<RemoteTextPreview> readText(String path);
  Future<RemoteFileDownload> download(String path);
}

class RemoteFilesClient implements RemoteFilesDataSource {
  final DashboardClient dashboard;
  final String? profile;
  final String? sessionId;

  RemoteFilesClient({required this.dashboard, this.profile, this.sessionId});

  factory RemoteFilesClient.fromConnection(
    SavedConnection connection, {
    String? sessionId,
    http.Client? httpClient,
  }) {
    final baseUri = Uri.parse(
      DesktopGatewayClient.normalizedGatewayBaseUrl(connection),
    );
    return RemoteFilesClient(
      dashboard: DashboardClient(
        host: baseUri.host,
        port: baseUri.port,
        useHttps: baseUri.scheme == 'https',
        pathPrefix: baseUri.path == '/' ? '' : baseUri.path,
        proxied: connection.dashboardProxied,
        username: connection.dashboardUsername,
        password: connection.dashboardPassword,
        gatewayProfile: connection.gatewayProfile,
        httpClient: httpClient,
      ),
      profile: connection.gatewayProfile,
      sessionId: sessionId,
    );
  }

  Map<String, String> _scopedQuery(
    Map<String, String> parameters, {
    bool includeSession = false,
  }) => {
    ...parameters,
    if (profile?.isNotEmpty == true) 'profile': profile!,
    if (includeSession && sessionId?.isNotEmpty == true)
      'session_id': sessionId!,
  };

  @override
  Future<RemoteDirectory> defaultDirectory() async {
    final data = await dashboard.apiGet(
      'fs/default-cwd',
      queryParameters: _scopedQuery(const {}),
    );
    return RemoteDirectory(
      path: data['cwd'] as String? ?? '/',
      branch: data['branch'] as String?,
    );
  }

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    final data = await dashboard.apiGet(
      'fs/list',
      queryParameters: _scopedQuery({'path': path}),
    );
    final error = data['error'] as String?;
    if (error != null && error.isNotEmpty) {
      throw Exception('Could not read directory: $error');
    }
    final entries = (data['entries'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(RemoteFileEntry.fromJson)
        .toList();
    entries.sort(
      (left, right) => left.isDirectory == right.isDirectory
          ? left.name.toLowerCase().compareTo(right.name.toLowerCase())
          : left.isDirectory
          ? -1
          : 1,
    );
    return entries;
  }

  @override
  Future<RemoteTextPreview> readText(String path) async {
    final data = await dashboard.apiGet(
      'fs/read-text',
      queryParameters: _scopedQuery({'path': path}),
    );
    return RemoteTextPreview.fromJson(data);
  }

  @override
  Future<RemoteFileDownload> download(String path) async {
    final response = await dashboard.apiGetBytes(
      'fs/download',
      queryParameters: _scopedQuery({'path': path}, includeSession: true),
    );
    final disposition = response.headers['content-disposition'] ?? '';
    final match = RegExp(
      r'''filename\*?=(?:UTF-8''|["'])?([^"';]+)''',
      caseSensitive: false,
    ).firstMatch(disposition);
    return RemoteFileDownload(
      filename: match?.group(1)?.trim() ?? path.split('/').last,
      bytes: response.bodyBytes,
    );
  }

  void close() => dashboard.close();
}
