import 'dart:convert';

const int maxMessageBytes = 8 * 1024;
const int maxCallsPerQuery = 16;
const int maxPendingRpc = 8;
const int maxStringArg = 2000;
/// Bridge operations are camelCase (`hostState`); query names are server-defined snake_case.
final RegExp _opName = RegExp(r'^[a-z][A-Za-z0-9]{1,39}$');
final RegExp _queryName = RegExp(r'^[a-z][a-z0-9_]{1,39}$');
final RegExp _argName = RegExp(r'^[a-z][a-z0-9_]{0,39}$');

/// Message refused before any side effect. [code] is returned to the page; the page never
/// learns why beyond that.
class BridgeRejected implements Exception {
  BridgeRejected(this.code, this.detail, {this.id});
  final String code;
  final String detail;

  /// The request id, whenever it could be read. The page matches replies by id, so a refusal
  /// that names it fails the call at once instead of leaving it to time out.
  final int? id;
  @override
  String toString() => 'BridgeRejected($code): $detail';
}

class BridgeRequest {
  BridgeRequest(this.id, this.op, {this.calls = const [], this.args = const {}});
  final int id;
  final String op;
  final List<Map<String, dynamic>> calls;

  /// The checked arguments of a file operation (`pickFile`, `saveFile`, ...). Empty for the others.
  final Map<String, dynamic> args;
}

/// Operations that move files or hand text to Hermes. They have effects outside the page, so the host answers
/// them only with a native step the user performs (a picker, a sheet, a confirmation).
const Set<String> fileOps = {'pickFile', 'listFiles', 'deleteFile', 'saveFile', 'askHermes'};

const int maxPromptChars = 2400;
const int maxAskFiles = 8;
const int maxAcceptEntries = 8;
final RegExp _acceptEntry = RegExp(r'^[A-Za-z0-9./*+-]{1,60}$');
final RegExp _fileId = RegExp(r'^f_[0-9a-f]{16}$');

/// Gatekeeper for page -> host messages (ADR-006 §3). Authority never comes from the message:
/// appId, profile and revision are chosen by the host; this class only decides whether the
/// message is acceptable at all.
class BridgeGate {
  BridgeGate({required this.expectedOrigin});

  /// `https://<host>`, exactly as the WebView reports sourceOrigin (no trailing slash).
  final String expectedOrigin;

  int _pending = 0;
  int get pending => _pending;

  /// Parses and validates one message. Call [release] when the reply has been sent.
  BridgeRequest accept(String? message, {required String? sourceOrigin, required bool isMainFrame}) {
    if (!isMainFrame) throw BridgeRejected('forbidden_frame', 'message from a subframe');
    if (sourceOrigin != expectedOrigin) {
      throw BridgeRejected('forbidden_origin', 'origin ${sourceOrigin ?? '(null)'}');
    }
    if (message == null) throw BridgeRejected('bad_message', 'no payload');
    if (utf8.encode(message).length > maxMessageBytes) {
      // Too big to parse, but the SDK writes the id first, so it can usually be read from the head.
      throw BridgeRejected('too_large', 'message size', id: _peekId(message));
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(message);
    } catch (_) {
      throw BridgeRejected('bad_message', 'not json');
    }
    if (decoded is! Map<String, dynamic>) throw BridgeRejected('bad_message', 'not an object');
    final rawId = decoded['id'];
    if (rawId is! int || rawId < 0 || rawId > 0x7fffffff) throw BridgeRejected('bad_message', 'bad id');
    // From here on every refusal can name the request it belongs to.
    final id = rawId;
    if (_pending >= maxPendingRpc) throw BridgeRejected('too_many_requests', 'pending limit', id: id);
    final rpc = decoded['rpc'];
    if (rpc is! Map<String, dynamic>) throw BridgeRejected('bad_message', 'rpc missing', id: id);
    final op = rpc['op'];
    if (op is! String || !_opName.hasMatch(op)) throw BridgeRejected('unknown_op', 'bad op', id: id);

    switch (op) {
      case 'hello':
      case 'hostState':
        _pending++;
        return BridgeRequest(id, op);
      case 'query':
        final calls = _calls(rpc['calls'], id);
        _pending++;
        return BridgeRequest(id, op, calls: calls);
      case 'pickFile':
      case 'listFiles':
      case 'deleteFile':
      case 'saveFile':
      case 'askHermes':
        final args = _fileArgs(op, rpc, id);
        _pending++;
        return BridgeRequest(id, op, args: args);
      default:
        throw BridgeRejected('unknown_op', op, id: id);
    }
  }

  /// The fields of a file operation, and nothing but them: anything else in the message is a refusal.
  Map<String, dynamic> _fileArgs(String op, Map<String, dynamic> rpc, int id) {
    BridgeRejected bad(String detail) => BridgeRejected('bad_args', '$op: $detail', id: id);
    final allowed = switch (op) {
      'pickFile' => const {'op', 'accept'},
      'listFiles' => const {'op'},
      'deleteFile' => const {'op', 'fileId'},
      'saveFile' => const {'op', 'fileId', 'name', 'args'},
      _ => const {'op', 'prompt', 'fileIds'},
    };
    if (rpc.keys.any((k) => !allowed.contains(k))) throw bad('unexpected field');

    String fileId(Object? v) {
      if (v is! String || !_fileId.hasMatch(v)) throw bad('bad file id');
      return v;
    }

    switch (op) {
      case 'pickFile':
        final accept = rpc['accept'];
        if (accept == null) return {'accept': const <String>[]};
        if (accept is! List || accept.length > maxAcceptEntries) throw bad('accept must be a short list');
        for (final a in accept) {
          if (a is! String || !_acceptEntry.hasMatch(a)) throw bad('bad accept entry');
        }
        return {'accept': accept.cast<String>()};
      case 'listFiles':
        return const {};
      case 'deleteFile':
        return {'fileId': fileId(rpc['fileId'])};
      case 'saveFile':
        final hasId = rpc['fileId'] != null, hasName = rpc['name'] != null;
        if (hasId == hasName) throw bad('give either fileId or name');
        if (hasId) {
          if (rpc['args'] != null) throw bad('args belong to a name');
          return {'fileId': fileId(rpc['fileId'])};
        }
        final name = rpc['name'];
        if (name is! String || !_queryName.hasMatch(name)) throw bad('bad file source name');
        return {'name': name, 'args': _scalarArgs(rpc['args'], id, op)};
      default:
        final prompt = rpc['prompt'];
        if (prompt is! String || prompt.trim().isEmpty || prompt.length > maxPromptChars) {
          throw bad('prompt must be 1..$maxPromptChars characters');
        }
        final rawIds = rpc['fileIds'] ?? const <Object?>[];
        if (rawIds is! List || rawIds.length > maxAskFiles) throw bad('at most $maxAskFiles files');
        final ids = [for (final v in rawIds) fileId(v)];
        if (ids.toSet().length != ids.length) throw bad('a file is listed twice');
        return {'prompt': prompt, 'fileIds': ids};
    }
  }

  /// Typed scalar arguments, the same rule the named queries use.
  Map<String, dynamic> _scalarArgs(Object? args, int id, String op) {
    BridgeRejected bad(String detail) => BridgeRejected('bad_args', '$op: $detail', id: id);
    final clean = <String, dynamic>{};
    if (args == null) return clean;
    if (args is! Map<String, dynamic> || args.length > 16) throw bad('bad args');
    args.forEach((k, v) {
      if (!_argName.hasMatch(k)) throw bad('bad arg name');
      final ok = v == null || v is bool || v is num && v.isFinite || v is String && v.length <= maxStringArg;
      if (!ok) throw bad('arg $k must be a scalar');
      clean[k] = v;
    });
    return clean;
  }

  static final RegExp _headId = RegExp(r'^\s*\{\s*"id"\s*:\s*(\d{1,10})\b');

  static int? _peekId(String message) {
    final m = _headId.firstMatch(message.length > 64 ? message.substring(0, 64) : message);
    final v = m == null ? null : int.tryParse(m.group(1)!);
    return v != null && v <= 0x7fffffff ? v : null;
  }

  void release() {
    if (_pending > 0) _pending--;
  }

  List<Map<String, dynamic>> _calls(Object? raw, int id) {
    BridgeRejected bad(String detail) => BridgeRejected('bad_args', detail, id: id);
    if (raw is! List || raw.isEmpty || raw.length > maxCallsPerQuery) {
      throw bad('calls must be 1..$maxCallsPerQuery');
    }
    final out = <Map<String, dynamic>>[];
    for (final c in raw) {
      if (c is! Map<String, dynamic>) throw bad('call is not an object');
      if (c.keys.any((k) => k != 'name' && k != 'args')) throw bad('unexpected call field');
      final name = c['name'];
      if (name is! String || !_queryName.hasMatch(name)) throw bad('bad query name');
      final args = c['args'];
      final clean = <String, dynamic>{};
      if (args != null) {
        if (args is! Map<String, dynamic> || args.length > 16) throw bad('bad args');
        args.forEach((k, v) {
          if (!_argName.hasMatch(k)) throw bad('bad arg name');
          final ok = v == null || v is bool || v is num && v.isFinite || v is String && v.length <= maxStringArg;
          if (!ok) throw bad('arg $k must be a scalar');
          clean[k] = v;
        });
      }
      out.add({'name': name, if (clean.isNotEmpty) 'args': clean});
    }
    return out;
  }

  static String ok(int id, Object? value) => jsonEncode({'id': id, 'ok': true, 'value': value});

  static String error(int? id, String code, String message) => jsonEncode({
        'id': id,
        'ok': false,
        'error': {'code': code, 'message': message},
      });
}
