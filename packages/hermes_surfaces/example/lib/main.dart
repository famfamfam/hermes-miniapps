import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';
import 'package:hermes_surfaces_bridge/hermes_surfaces_bridge.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

void main() => runApp(const ExampleApp());

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Hermes Surfaces S0',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
    home: const Home(),
  );
}

/// Connection settings persisted next to the installed packages.
class Settings {
  Settings({
    required this.url,
    required this.token,
    required this.deviceId,
    this.strictNetworkBlock = true,
    this.sealNetwork = true,
  });
  String url;
  String token;
  String deviceId;

  /// WebView's own blockNetworkLoads switch (diagnostics only).
  bool strictNetworkBlock;

  /// Loopback-proxy network seal (the layer that stops preconnect). Diagnostics only.
  bool sealNetwork;

  Map<String, dynamic> toJson() => {
    'url': url,
    'token': token,
    'deviceId': deviceId,
    'strictNetworkBlock': strictNetworkBlock,
    'sealNetwork': sealNetwork,
  };

  static Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/settings.json');
  }

  static Future<Settings> load() async {
    final f = await _file();
    if (await f.exists()) {
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return Settings(
        url: j['url'] as String,
        token: j['token'] as String,
        deviceId: j['deviceId'] as String,
        strictNetworkBlock: (j['strictNetworkBlock'] as bool?) ?? true,
        sealNetwork: (j['sealNetwork'] as bool?) ?? true,
      );
    }
    final rnd = Random.secure();
    final id = List.generate(8, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    // Loopback is for the USB pilot. Enter the bearer in native settings; never bake a live token into an APK.
    return Settings(
      url: const String.fromEnvironment('MS_URL', defaultValue: 'http://127.0.0.1:8787'),
      token: '',
      deviceId: id,
    );
  }

  Future<void> save() async => (await _file()).writeAsString(jsonEncode(toJson()), flush: true);

  ServerConfig toConfig() => ServerConfig(baseUri: Uri.parse(url), token: token, deviceId: deviceId);
}

/// Appends diagnostics to `<external files dir>/diag.log`, which `adb pull` can read without root
/// (`/sdcard/Android/data/<package>/files/diag.log`). Best effort: a write failure is ignored.
class DiagFile {
  static File? _file;
  static Future<void> _chain = Future<void>.value();

  static void append(String appId, DiagEntry e) {
    final line = '${e.at.toIso8601String()} [$appId] [${e.kind}] ${e.text}\n';
    _chain = _chain.then((_) async {
      try {
        _file ??= File('${(await getExternalStorageDirectory())!.path}/diag.log');
        await _file!.writeAsString(line, mode: FileMode.append, flush: true);
      } catch (_) {}
    });
  }
}

class Home extends StatefulWidget {
  const Home({super.key, this.hostBuilder, this.previewHostBuilder});

  final Future<SurfacesHost> Function(Settings settings)? hostBuilder;
  final Future<SurfacesHost> Function(ServerConfig config)? previewHostBuilder;

  @override
  State<Home> createState() => _HomeState();
}

class _ExampleBridge implements HostBridge {
  _ExampleBridge(this._openChat);
  final Future<void> Function() _openChat;

  @override
  final ValueNotifier<SurfacesConnection?> activeConnection = ValueNotifier(null);

  void configure(Settings settings) {
    final config = settings.toConfig();
    config.scope; // Validate before exposing credentials to a transport.
    activeConnection.value = settings.token.isEmpty
        ? null
        : SurfacesConnection(
            config: config,
            strictNetworkBlock: settings.strictNetworkBlock,
            sealNetwork: settings.sealNetwork,
          );
  }

  @override
  Future<Directory> applicationSupportDirectory() => getApplicationSupportDirectory();

  @override
  Future<ApproverKey?> loadApproverKey() async => ApproverKey.loadExisting(await applicationSupportDirectory());

  @override
  http.Client createSurfacesClient(SurfacesConnection connection) => http.Client();

  @override
  Future<void> openChat() => _openChat();

  @override
  HostFileActions? get fileActions => null;

  @override
  SendToHermes? get sendToHermes => null;
}

class _HomeState extends State<Home> {
  late final _ExampleBridge _bridge;
  Settings? _settings;
  String? _error;
  bool _pairing = false;
  int _moduleGeneration = 0;

  @override
  void initState() {
    super.initState();
    _bridge = _ExampleBridge(() async => _toast('В этом тестовом примере нет чатового клиента'));
    unawaited(_init());
  }

  @override
  void dispose() {
    _bridge.activeConnection.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final settings = await Settings.load();
      if (!mounted) return;
      _bridge.configure(settings);
      setState(() {
        _settings = settings;
        _error = null;
      });
      if (settings.token.isEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_editSettings());
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось прочитать настройки. Сохранённые данные не изменены.');
    }
  }

  Future<SurfacesHost> _buildHost(SurfacesConnection connection, Directory root, bool preview) async {
    final config = connection.config;
    if (preview) {
      return SurfacesHost(
        api: PreviewApi(config, client: _bridge.createSurfacesClient(connection)),
        bundles: BundleStore(root),
        snapshots: SnapshotCache(root),
      );
    }
    return widget.hostBuilder!(
      Settings(
        url: config.baseUri.toString(),
        token: config.token,
        deviceId: config.deviceId,
        strictNetworkBlock: connection.strictNetworkBlock,
        sealNetwork: connection.sealNetwork,
      ),
    );
  }

  Future<SurfacesHost> _buildPreviewHost(SurfacesConnection connection, Directory root, bool preview) =>
      widget.previewHostBuilder!(connection.config);

  void _toast(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _editSettings() async {
    final settings = _settings;
    if (settings == null) return;
    final next = await showDialog<Settings>(
      context: context,
      builder: (_) => _SettingsDialog(settings: settings),
    );
    if (next == null || !mounted) return;
    try {
      await next.save();
      if (!mounted) return;
      _bridge.configure(next);
      setState(() => _settings = next);
    } catch (_) {
      _toast('Не удалось сохранить настройки');
    }
  }

  bool _isCurrent(SurfacesConnection connection) => mounted && identical(_bridge.activeConnection.value, connection);

  // Identity creation and TOFU pairing are explicit example-host actions, never module startup logic.
  Future<void> _pair() async {
    final connection = _bridge.activeConnection.value;
    if (connection == null || _pairing) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Назначить этот телефон устройством подтверждения?'),
        content: const Text(
          'Только если сервер ещё не привязан. Существующий ключ сохранится; '
          'повреждённый ключ или чужая привязка не будут заменены.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Назначить')),
        ],
      ),
    );
    if (yes != true || !_isCurrent(connection)) return;
    setState(() => _pairing = true);
    final api = SurfacesApi(connection.config, client: _bridge.createSurfacesClient(connection));
    try {
      final health = await api.health();
      if (!_isCurrent(connection)) return;
      if (health['reviews'] != true) {
        _toast('Сервер не поддерживает подтверждение публикаций');
        return;
      }
      if (health['approverPaired'] == true) {
        _toast('На сервере уже назначено устройство. Перепривязка не выполнялась.');
        return;
      }
      final dir = await _bridge.applicationSupportDirectory();
      if (!_isCurrent(connection)) return;
      final key = await ApproverKey.loadExisting(dir) ?? await ApproverKey.loadOrCreate(dir);
      if (!_isCurrent(connection)) return;
      final paired = await ReviewClient(api, key).pair();
      if (!_isCurrent(connection)) return;
      _toast(paired ? 'Телефон назначен устройством подтверждения' : 'На сервере уже назначено другое устройство');
      if (paired) setState(() => _moduleGeneration++);
    } on ApprovalFailure catch (e) {
      if (_isCurrent(connection)) _toast(e.message);
    } catch (_) {
      if (_isCurrent(connection)) _toast('Не удалось назначить устройство подтверждения');
    } finally {
      api.close();
      if (mounted) setState(() => _pairing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_settings == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Hermes · Apps (S0)')),
        body: Center(child: _error == null ? const CircularProgressIndicator() : Text(_error!)),
      );
    }
    return AppsModule(
      key: ValueKey(_moduleGeneration),
      bridge: _bridge,
      title: 'Hermes · Apps (S0)',
      hostFactory: widget.hostBuilder == null ? null : _buildHost,
      previewHostFactory: widget.previewHostBuilder == null ? null : _buildPreviewHost,
      onDiag: DiagFile.append,
      appBarActions: [
        PopupMenuButton<String>(
          enabled: !_pairing,
          onSelected: (value) => unawaited(value == 'settings' ? _editSettings() : _pair()),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'settings', child: Text('Сервер и токен')),
            PopupMenuItem(value: 'pair', child: Text('Устройство подтверждения')),
          ],
        ),
      ],
    );
  }
}

class _SettingsDialog extends StatefulWidget {
  const _SettingsDialog({required this.settings});
  final Settings settings;

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final _url = TextEditingController(text: widget.settings.url);
  late final _token = TextEditingController(text: widget.settings.token);
  late bool _strict;
  late bool _seal;
  String? _error;

  @override
  void initState() {
    super.initState();
    _strict = widget.settings.strictNetworkBlock;
    _seal = widget.settings.sealNetwork;
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  void _save() {
    final next = Settings(
      url: _url.text.trim(),
      token: _token.text.trim(),
      deviceId: widget.settings.deviceId,
      strictNetworkBlock: _strict,
      sealNetwork: _seal,
    );
    try {
      next.toConfig().scope;
    } catch (_) {
      setState(() => _error = 'Нужен адрес HTTP(S) без userinfo, query и fragment');
      return;
    }
    Navigator.pop(context, next);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Сервер Hermes'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _url,
            decoration: const InputDecoration(labelText: 'Адрес'),
            keyboardType: TextInputType.url,
          ),
          TextField(
            controller: _token,
            decoration: const InputDecoration(labelText: 'Токен'),
            obscureText: true,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Блокировать сеть WebView'),
            subtitle: const Text('Диагностика: выключить, только если страница пустая'),
            value: _strict,
            onChanged: (value) => setState(() => _strict = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Сетевая печать (прокси-сток)'),
            subtitle: const Text('Выключать только для замера других слоёв'),
            value: _seal,
            onChanged: (value) => setState(() => _seal = value),
          ),
          if (_error != null) Text(_error!),
        ],
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Отмена')),
      FilledButton(onPressed: _save, child: const Text('Сохранить')),
    ],
  );
}
