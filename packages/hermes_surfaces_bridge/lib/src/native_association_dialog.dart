import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart' show ConnectionString, SurfacesStrings, SurfacesText;

import 'native_association_controller.dart';

/// Explicit native configuration for the selected immutable owner only.
/// Legacy access is OPTIONAL and occurs only after a separate affirmative confirmation.
/// Opening/cancelling/saving normally never calls [legacyPrefill]. No identity/device ID
/// generation, pairing, root settings writes or legacy cache adoption is performed here.
///
/// [suggestedUrl] is an optional address the host proposes (e.g. the chat server's sibling). It only
/// offers a button that copies it into the address field; the bearer and Device ID stay typed input.
///
/// [startWithPaste] begins with the "paste connection code" step as soon as the dialog has read its
/// state: the Apps card's main button uses it, so one tap goes straight from the clipboard to the question
/// "connect to this host?". The clipboard is read only then, or when the user presses the paste button.
Future<bool?> showNativeAssociationDialog(
  BuildContext context, {
  required NativeAssociationController controller,
  Future<NativeAssociationSettings?> Function()? legacyPrefill,
  String? suggestedUrl,
  bool startWithPaste = false,
}) async {
  final configuration = controller.beginConfiguration();
  try {
    return await showDialog<bool>(
      context: context,
      builder: (_) => NativeAssociationDialog(
        controller: controller,
        configuration: configuration,
        legacyPrefill: legacyPrefill,
        suggestedUrl: suggestedUrl,
        startWithPaste: startWithPaste,
      ),
    );
  } finally {
    controller.endConfiguration(configuration);
  }
}

/// Prefer [showNativeAssociationDialog], which also owns cancellation/reload lifecycle.
class NativeAssociationDialog extends StatefulWidget {
  const NativeAssociationDialog({
    super.key,
    required this.controller,
    required this.configuration,
    this.legacyPrefill,
    this.suggestedUrl,
    this.startWithPaste = false,
  });

  final NativeAssociationController controller;
  final NativeAssociationConfiguration configuration;
  final Future<NativeAssociationSettings?> Function()? legacyPrefill;

  /// Start with the paste step once the state is read (see [showNativeAssociationDialog]).
  final bool startWithPaste;

  /// Host-proposed Surfaces address; null or blank hides the button. Never saved or requested by itself.
  final String? suggestedUrl;

  /// True for an address that only works from this device or its own network: a tunnel to the PC
  /// (`127.0.0.1`) or a LAN address. Such an address is useless once the phone is away from that network.
  static bool isLocalAddress(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host.isEmpty) return false;
    if (host == 'localhost' || host.endsWith('.local') || host == '::1' || host == '[::1]') return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = parts.map(int.tryParse).toList();
    if (octets.any((part) => part == null || part < 0 || part > 255)) return false;
    final (a, b) = (octets[0]!, octets[1]!);
    // 100.64.0.0/10 (Tailscale, carrier NAT) is deliberately not here: such an address is reachable from
    // anywhere on the user's own VPN, so a saved one is not replaced behind the user's back.
    return a == 127 || a == 10 || (a == 192 && b == 168) || (a == 172 && b >= 16 && b <= 31) || (a == 169 && b == 254);
  }

  @override
  State<NativeAssociationDialog> createState() => _NativeAssociationDialogState();
}

class _NativeAssociationDialogState extends State<NativeAssociationDialog> {
  final _url = TextEditingController();
  final _bearer = TextEditingController();
  final _device = TextEditingController();
  bool _strict = true;
  bool _seal = true;
  bool _busy = true;
  bool _stale = false;
  bool _showBearer = false;
  bool _checking = false;
  NativeConnectionCheck? _checked;

  /// The one message under the form, as a key of the shared string layer (localized when drawn).
  SurfacesText? _error;

  /// The viewer's language; async completions below have no BuildContext of their own.
  SurfacesStrings _t = SurfacesStrings.forLanguage(null);

  bool get _current => mounted && widget.controller.isConfigurationCurrent(widget.configuration);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    unawaited(_read());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _t = SurfacesStrings.of(context);
  }

  void _changed() {
    if (!mounted || _stale || widget.controller.isConfigurationCurrent(widget.configuration)) {
      return;
    }
    // An A -> B -> A target switch permanently discards both native AND legacy prefill.
    // `_stale` is synchronous, so every callback is already refused. The visual cleanup is
    // deferred out of frame callbacks: a host may dispose its controller while the tree is locked.
    _stale = true;
    void discard() {
      if (!mounted) return;
      _url.clear();
      _bearer.clear();
      _device.clear();
      setState(() {
        _showBearer = false;
        _checked = null;
        _swapped = false;
        _error = SurfacesText.dialogStale;
      });
    }

    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) => discard());
    } else {
      discard();
    }
  }

  /// Whether the field was filled with the host's proposal instead of a local address that was read.
  bool _swapped = false;

  void _prefill(NativeAssociationSettings settings) {
    var address = settings.baseUri.toString();
    final proposal = widget.suggestedUrl?.trim();
    final proposed = proposal == null || proposal.isEmpty ? null : Uri.tryParse(proposal);
    _swapped = false;
    if (proposed != null &&
        !NativeAssociationDialog.isLocalAddress(proposed) &&
        NativeAssociationDialog.isLocalAddress(settings.baseUri)) {
      address = proposal!;
      _swapped = true;
    }
    _url.text = address;
    _bearer.text = settings.bearer;
    _device.text = settings.deviceId;
    _strict = settings.strictNetworkBlock;
    _seal = settings.sealNetwork;
    _checked = null;
  }

  Future<void> _read() async {
    final settings = await widget.controller.readConfiguration(widget.configuration);
    if (!_current) {
      _changed();
      if (mounted) setState(() => _busy = false);
      return;
    }
    setState(() {
      if (settings != null) _prefill(settings);
      _busy = false;
      // "Not set up yet" is the very thing this form fixes; every other reason is worth showing.
      final notice = widget.controller.notice.value;
      _error = notice == NativeAssociationNotice.unconfigured ? null : notice?.text;
    });
    if (widget.startWithPaste) unawaited(_pasteCode());
  }

  /// The user-triggered step of the chat flow: read the clipboard (only now), ask "connect to this host?",
  /// then spend the code. The host is shown, never the path, which holds a secret prefix.
  Future<void> _pasteCode() async {
    if (!_current || _busy) return;
    final text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    if (!_current) return;
    final code = ConnectionString.tryParse(text);
    if (code == null) {
      setState(() => _error = SurfacesText.codeNotFound);
      return;
    }
    if (!await _confirm(
      _t(SurfacesText.codeConfirmTitle, {'host': code.host}),
      _t(SurfacesText.codeConfirmBody),
      _t(SurfacesText.codeConfirmAction),
    )) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final device = _device.text.trim();
    final result = await widget.controller.connectWithCode(
      widget.configuration,
      code,
      deviceId: device.isEmpty ? null : device,
      strictNetworkBlock: _strict,
      sealNetwork: _seal,
    );
    if (!mounted) return;
    if ((result == NativeClaimResult.connected || result == NativeClaimResult.connectedNotApprover) && _current) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(
            _t(result == NativeClaimResult.connected ? SurfacesText.codeConnected : SurfacesText.codeNotApprover),
          ),
        ),
      );
      Navigator.of(context).pop(true);
      return;
    }
    _changed();
    setState(() {
      _busy = false;
      if (_stale) return;
      _error = switch (result) {
        NativeClaimResult.invalidCode => SurfacesText.codeExpired,
        NativeClaimResult.locked => SurfacesText.codeLocked,
        NativeClaimResult.unsupported => SurfacesText.codeUnsupported,
        NativeClaimResult.unreachable => SurfacesText.noConnection,
        NativeClaimResult.stale => SurfacesText.dialogStaleShort,
        _ => SurfacesText.codeFailed,
      };
    });
  }

  String get _ownerLabel {
    final owner = widget.configuration.owner;
    final id = owner.profileId;
    final profile = id == null ? _t(SurfacesText.profileNone) : _t(SurfacesText.profileQuoted, {'profile': id});
    return _t(SurfacesText.ownerLabel, {'label': owner.displayLabel, 'profile': profile});
  }

  Future<bool> _confirm(String title, String message, String action) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(SurfacesStrings.of(context)(SurfacesText.cancel)),
          ),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: Text(action)),
        ],
      ),
    );
    return accepted == true && _current;
  }

  Future<void> _legacy() async {
    if (!_current || _busy || widget.legacyPrefill == null) return;
    if (!await _confirm(
      _t(SurfacesText.legacyConfirmTitle),
      _t(SurfacesText.legacyConfirmBody, {'owner': _ownerLabel}),
      _t(SurfacesText.legacyConfirmAction),
    )) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final settings = await widget.legacyPrefill!();
      if (!_current) return;
      setState(() {
        if (settings != null) _prefill(settings);
        _error = settings == null ? SurfacesText.legacyNone : null;
      });
    } catch (_) {
      if (_current) {
        setState(() => _error = SurfacesText.legacyFailed);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The typed values, or null after showing the same field message for Save and for the check.
  NativeAssociationSettings? _typed() {
    if (!NativeAssociationSettings.isValidDeviceId(_device.text.trim())) {
      setState(() => _error = SurfacesText.deviceIdInvalid);
      return null;
    }
    try {
      return NativeAssociationSettings(
        baseUri: Uri.parse(_url.text.trim()),
        bearer: _bearer.text.trim(), // a pasted token often carries a space or a newline at either end
        deviceId: _device.text.trim(),
        strictNetworkBlock: _strict,
        sealNetwork: _seal,
      );
    } catch (_) {
      setState(() => _error = SurfacesText.addressInvalid);
      return null;
    }
  }

  void _edited() {
    if (_checked != null || _swapped) {
      setState(() {
        _checked = null;
        _swapped = false;
      });
    }
  }

  /// Text only: no save, no request, no bearer, no Device ID and no legacy read. The user still
  /// types the Surfaces bearer and Device ID and confirms the save as before.
  void _useSuggested(String address) {
    if (!_current || _busy) return;
    _url.text = address;
    _edited();
  }

  /// Under the address field while it is empty or differs from the host's proposal.
  Widget _suggestion(bool enabled) {
    final address = widget.suggestedUrl?.trim();
    if (address == null || address.isEmpty) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: _url,
      builder: (context, _) {
        if (_url.text.trim() == address) return const SizedBox.shrink();
        return Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            key: const ValueKey('surfaces-use-chat-address'),
            onPressed: enabled ? () => _useSuggested(address) : null,
            child: Text(_t(SurfacesText.useChatAddress)),
          ),
        );
      },
    );
  }

  /// Explicit user action only: one read-only health request; saves and binds nothing.
  Future<void> _checkConnection() async {
    if (!_current || _busy || _checking) return;
    final settings = _typed();
    if (settings == null) return;
    String typedNow() => '${_url.text.trim()}\n${_bearer.text.trim()}\n${_device.text.trim()}';
    final asked = typedNow();
    setState(() {
      _checking = true;
      _checked = null;
      _error = null;
    });
    final result = await widget.controller.checkConnection(widget.configuration, settings);
    if (!mounted) return;
    _changed();
    setState(() {
      _checking = false;
      if (_stale) return; // The discard above already replaced everything with its notice.
      if (result == NativeConnectionCheck.stale) {
        _error = SurfacesText.dialogStaleShort;
      } else if (typedNow() == asked) {
        _checked = result;
      } // else: the fields changed while it was asking; that verdict belongs to values no longer shown.
    });
  }

  Future<void> _save() async {
    if (!_current || _busy) return;
    final settings = _typed();
    if (settings == null) return;
    if (!await _confirm(
      _t(SurfacesText.saveConfirmTitle),
      _t(SurfacesText.saveConfirmBody, {'owner': _ownerLabel}),
      _t(SurfacesText.saveConfirmAction),
    )) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final result = await widget.controller.saveConfiguration(widget.configuration, settings);
    if (!mounted) return;
    if (result == NativeAssociationSaveResult.saved && _current) {
      Navigator.of(context).pop(true);
      return;
    }
    _changed();
    setState(() {
      _busy = false;
      if (!_stale) {
        _error = result == NativeAssociationSaveResult.stale
            ? SurfacesText.dialogStaleShort
            : widget.controller.notice.value?.text ?? SurfacesText.saveVerifyFailed;
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _url.dispose();
    _bearer.dispose();
    _device.dispose();
    super.dispose();
  }

  Widget _section(BuildContext context, String title, [String? caption]) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(header: true, child: Text(title, style: theme.textTheme.titleSmall)),
          if (caption != null)
            Text(caption, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }

  /// The sanitised outcome of the explicit check: a fixed label and hint, never URL, token or body.
  Widget _checkOutcome(BuildContext context) {
    final theme = Theme.of(context);
    if (_checking) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2.5)),
            const SizedBox(width: 12),
            Text(_t(SurfacesText.checking), style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }
    final checked = _checked;
    if (checked == null) return const SizedBox.shrink();
    final (IconData icon, SurfacesText title, SurfacesText hint, bool ok) = switch (checked) {
      NativeConnectionCheck.reachable => (
        Icons.check_circle_outline,
        SurfacesText.checkReachable,
        SurfacesText.checkReachableHint,
        true,
      ),
      NativeConnectionCheck.unauthorized => (
        Icons.lock_outline,
        SurfacesText.checkUnauthorized,
        SurfacesText.checkUnauthorizedHint,
        false,
      ),
      NativeConnectionCheck.invalid => (
        Icons.error_outline,
        SurfacesText.checkInvalid,
        SurfacesText.checkInvalidHint,
        false,
      ),
      _ => (Icons.cloud_off_outlined, SurfacesText.checkUnreachable, SurfacesText.checkUnreachableHint, false),
    };
    final color = ok ? theme.colorScheme.primary : theme.colorScheme.error;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_t(title), style: theme.textTheme.titleSmall?.copyWith(color: color)),
                  Text(_t(hint), style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = !_busy && !_stale;
    return AlertDialog(
      title: Text(_t(SurfacesText.configureSurfaces)),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_ownerLabel),
              const SizedBox(height: 12),
              Text(_t(SurfacesText.dialogIntro)),
              if (_busy) const LinearProgressIndicator(),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const ValueKey('surfaces-paste-code'),
                onPressed: enabled ? _pasteCode : null,
                icon: const Icon(Icons.content_paste_go),
                label: Text(_t(SurfacesText.pasteCode)),
              ),
              const SizedBox(height: 8),
              Text(
                _t(SurfacesText.pasteCodeHint),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(child: Divider()),
                  Flexible(
                    flex: 6,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        _t(SurfacesText.codeOrManual),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
              _section(context, _t(SurfacesText.sectionConnection)),
              TextField(
                key: const ValueKey('surfaces-url'),
                controller: _url,
                enabled: enabled,
                autocorrect: false,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.next,
                onChanged: (_) => _edited(),
                decoration: InputDecoration(
                  labelText: _t(SurfacesText.urlLabel),
                  helperText: _t(SurfacesText.urlHelper),
                  helperMaxLines: 3,
                ),
              ),
              _suggestion(enabled),
              if (_swapped)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _t(SurfacesText.addressSwapped),
                    key: const ValueKey('surfaces-address-swapped'),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('surfaces-bearer'),
                controller: _bearer,
                enabled: enabled,
                obscureText: !_showBearer,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                textInputAction: TextInputAction.next,
                onChanged: (_) => _edited(),
                decoration: InputDecoration(
                  labelText: _t(SurfacesText.bearerLabel),
                  helperText: _t(SurfacesText.bearerHelper),
                  helperMaxLines: 3,
                  suffixIcon: IconButton(
                    tooltip: _t(_showBearer ? SurfacesText.hideToken : SurfacesText.showToken),
                    icon: Icon(_showBearer ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => setState(() => _showBearer = !_showBearer),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                key: const ValueKey('surfaces-device'),
                controller: _device,
                enabled: enabled,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onChanged: (_) => _edited(),
                decoration: InputDecoration(
                  labelText: _t(SurfacesText.deviceLabel),
                  helperText: _t(SurfacesText.deviceHelper),
                  helperMaxLines: 3,
                ),
              ),
              if (widget.legacyPrefill != null)
                TextButton(onPressed: enabled ? _legacy : null, child: Text(_t(SurfacesText.legacyLink))),
              _section(context, _t(SurfacesText.sectionSecurity), _t(SurfacesText.sectionSecurityCaption)),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_t(SurfacesText.strictTitle)),
                subtitle: Text(_t(SurfacesText.strictSubtitle)),
                value: _strict,
                onChanged: enabled ? (value) => setState(() => _strict = value) : null,
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_t(SurfacesText.sealTitle)),
                subtitle: Text(_t(SurfacesText.sealSubtitle)),
                value: _seal,
                onChanged: enabled ? (value) => setState(() => _seal = value) : null,
              ),
              _section(context, _t(SurfacesText.sectionCheck), _t(SurfacesText.sectionCheckCaption)),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: OutlinedButton.icon(
                  style: const ButtonStyle(minimumSize: WidgetStatePropertyAll(Size(64, 48))),
                  onPressed: enabled && !_checking ? _checkConnection : null,
                  icon: const Icon(Icons.network_check),
                  label: Text(_t(SurfacesText.checkConnection)),
                ),
              ),
              _checkOutcome(context),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(_t(_error!), style: TextStyle(color: theme.colorScheme.error)),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: Text(_t(SurfacesText.close))),
        FilledButton(onPressed: enabled ? _save : null, child: Text(_t(SurfacesText.save))),
      ],
    );
  }
}
