// Approval requests that arrive on a plain streamed chat turn.
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_android/core/models/gateway_approval.dart';
import 'package:hermes_android/core/services/connection_manager.dart';

void main() {
  test('an approval.request frame is delivered through the progress callback', () {
    const frame =
        'event: approval.request\n'
        'data: {"event": "approval.request", "run_id": "chatcmpl-abc", '
        '"request_id": "r1", "command": "MCP tool \'app_create\' on UNTRUSTED server", '
        '"description": "Approve to run once.", "choices": ["once", "session", "always", "deny"]}';
    Map<String, dynamic>? seen;
    final token = GatewayChatClient.parseSseFrame(
      frame,
      onToolProgress: (progress) => seen = progress,
    );
    expect(token, isNull);
    expect(seen?['run_id'], 'chatcmpl-abc');
    expect(seen?['request_id'], 'r1');
    expect(seen?['event'], 'approval.request');
  });

  test('the dialog model keeps the offered choices and always has deny', () {
    final request = GatewayApprovalRequest.fromEventData({
      'command': 'MCP tool app_create',
      'description': 'Approve to run once.',
      'choices': ['once', 'always'],
    });
    expect(request.choices, contains(GatewayApprovalChoice.once));
    expect(request.choices, contains(GatewayApprovalChoice.deny));
  });

  test('ordinary token and tool progress frames are unchanged', () {
    final text = GatewayChatClient.parseSseFrame(
      'data: {"choices":[{"delta":{"content":"hi"}}]}',
    );
    expect(text, 'hi');
    Map<String, dynamic>? seen;
    final none = GatewayChatClient.parseSseFrame(
      'event: hermes.tool.progress\ndata: {"tool":"terminal","status":"running"}',
      onToolProgress: (progress) => seen = progress,
    );
    expect(none, isNull);
    expect(seen?['tool'], 'terminal');
  });

  test(
    'a payload without an event key still carries it, taken from the frame',
    () {
      const frame =
          'event: approval.request\n'
          'data: {"run_id": "chatcmpl-abc", "request_id": "r2", "command": "x", "choices": ["once", "deny"]}';
      Map<String, dynamic>? seen;
      GatewayChatClient.parseSseFrame(
        frame,
        onToolProgress: (progress) => seen = progress,
      );
      expect(seen?['event'], 'approval.request');
      expect(seen?['request_id'], 'r2');
    },
  );
}
