import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_surfaces/hermes_surfaces.dart';

const origin = 'https://utilities.abcd1234.surfaces.invalid';

String msg(Object rpc, {Object id = 1}) => jsonEncode({'id': id, 'rpc': rpc});

BridgeRequest ok(BridgeGate g, String m) => g.accept(m, sourceOrigin: origin, isMainFrame: true);

void expectRejected(BridgeGate g, String? m, String code, {String? from, bool main = true}) {
  expect(
    () => g.accept(m, sourceOrigin: from ?? origin, isMainFrame: main),
    throwsA(isA<BridgeRejected>().having((e) => e.code, 'code', code)),
  );
}

void main() {
  late BridgeGate gate;
  setUp(() => gate = BridgeGate(expectedOrigin: origin));

  test('accepts hello, hostState and a typed query', () {
    expect(ok(gate, msg({'op': 'hello'})).op, 'hello');
    expect(ok(gate, msg({'op': 'hostState'}, id: 2)).op, 'hostState');
    final q = ok(gate, msg({'op': 'query', 'calls': [
      {'name': 'bills', 'args': {'status': 'unpaid', 'n': 3, 'flag': true, 'none': null}},
      {'name': 'month_total'},
    ]}, id: 3));
    expect(q.calls.length, 2);
    expect(q.calls.first['args'], {'status': 'unpaid', 'n': 3, 'flag': true, 'none': null});
  });

  group('who is calling', () {
    test('foreign origin', () => expectRejected(gate, msg({'op': 'hello'}), 'forbidden_origin', from: 'https://evil.example'));
    test('null origin', () => expect(
        () => gate.accept(msg({'op': 'hello'}), sourceOrigin: null, isMainFrame: true), throwsA(isA<BridgeRejected>())));
    test('sibling app origin', () =>
        expectRejected(gate, msg({'op': 'hello'}), 'forbidden_origin', from: 'https://other.abcd1234.surfaces.invalid'));
    test('prefix lookalike', () => expectRejected(gate, msg({'op': 'hello'}), 'forbidden_origin', from: '$origin.evil.com'));
    test('http instead of https', () => expectRejected(
        gate, msg({'op': 'hello'}), 'forbidden_origin', from: origin.replaceFirst('https', 'http')));
    test('subframe, even with the right origin', () => expectRejected(gate, msg({'op': 'hello'}), 'forbidden_frame', main: false));
  });

  group('malformed messages', () {
    test('null', () => expectRejected(gate, null, 'bad_message'));
    test('not json', () => expectRejected(gate, '{{{', 'bad_message'));
    test('array', () => expectRejected(gate, '[1]', 'bad_message'));
    test('no rpc', () => expectRejected(gate, jsonEncode({'id': 1}), 'bad_message'));
    test('string id', () => expectRejected(gate, jsonEncode({'id': '1', 'rpc': {'op': 'hello'}}), 'bad_message'));
    test('negative id', () => expectRejected(gate, msg({'op': 'hello'}, id: -1), 'bad_message'));
    test('huge id', () => expectRejected(gate, msg({'op': 'hello'}, id: 1 << 40), 'bad_message'));
    test('oversized', () => expectRejected(gate, msg({'op': 'hello', 'pad': 'x' * 9000}), 'too_large'));
  });

  group('operations', () {
    for (final op in ['runAgent', 'openUrl', 'share', 'readFile', 'eval', 'HELLO', 'hello; drop', '', 'a']) {
      test('unknown op ${jsonEncode(op)}', () => expectRejected(gate, msg({'op': op}), 'unknown_op'));
    }
    test('op not a string', () => expectRejected(gate, msg({'op': 5}), 'unknown_op'));
  });

  group('query arguments', () {
    BridgeGate g() => BridgeGate(expectedOrigin: origin);
    void bad(String name, Object calls) => test(name, () => expectRejected(g(), msg({'op': 'query', 'calls': calls}), 'bad_args'));

    bad('no calls', []);
    bad('calls not a list', 'x');
    bad('too many calls', List.generate(17, (_) => {'name': 'bills'}));
    bad('call not an object', ['bills']);
    bad('extra call field (sql)', [{'name': 'bills', 'sql': 'DROP TABLE x'}]);
    bad('bad query name', [{'name': 'Bills; DROP'}]);
    bad('missing name', [{}]);
    bad('args not an object', [{'name': 'bills', 'args': [1]}]);
    bad('bad arg name', [{'name': 'bills', 'args': {'Bad-Name': 1}}]);
    bad('nested object arg', [{'name': 'bills', 'args': {'a': {'x': 1}}}]);
    bad('list arg', [{'name': 'bills', 'args': {'a': [1]}}]);
    bad('overlong string arg', [{'name': 'bills', 'args': {'a': 'x' * 2001}}]);
    bad('too many args', [{'name': 'bills', 'args': {for (var i = 0; i < 17; i++) 'a$i': 1}}]);
  });

  group('refusals name the request so the page fails at once', () {
    int? idOf(void Function() act) {
      try {
        act();
      } on BridgeRejected catch (e) {
        return e.id;
      }
      fail('expected a rejection');
    }

    test('unknown op', () => expect(idOf(() => gate.accept(msg({'op': 'runAgent'}, id: 41), sourceOrigin: origin, isMainFrame: true)), 41));
    test('bad args', () {
      final m = msg({'op': 'query', 'calls': []}, id: 42);
      expect(idOf(() => gate.accept(m, sourceOrigin: origin, isMainFrame: true)), 42);
    });
    test('bad query name', () {
      final m = msg({'op': 'query', 'calls': [{'name': 'X'}]}, id: 43);
      expect(idOf(() => gate.accept(m, sourceOrigin: origin, isMainFrame: true)), 43);
    });
    test('pending limit', () {
      for (var i = 0; i < maxPendingRpc; i++) {
        ok(gate, msg({'op': 'hello'}, id: i));
      }
      expect(idOf(() => gate.accept(msg({'op': 'hello'}, id: 77), sourceOrigin: origin, isMainFrame: true)), 77);
    });
    test('oversized message, id read from its head', () {
      final big = jsonEncode({'id': 55, 'rpc': {'op': 'hello', 'pad': 'x' * 9000}});
      expect(idOf(() => gate.accept(big, sourceOrigin: origin, isMainFrame: true)), 55);
    });
    test('oversized message without a readable head has no id', () {
      expect(idOf(() => gate.accept('x' * 9000, sourceOrigin: origin, isMainFrame: true)), isNull);
    });
    test('wrong origin, subframe and invalid JSON stay anonymous', () {
      expect(idOf(() => gate.accept(msg({'op': 'hello'}, id: 5), sourceOrigin: 'https://evil', isMainFrame: true)), isNull);
      expect(idOf(() => gate.accept(msg({'op': 'hello'}, id: 5), sourceOrigin: origin, isMainFrame: false)), isNull);
      expect(idOf(() => gate.accept('{{', sourceOrigin: origin, isMainFrame: true)), isNull);
    });
  });

  group('file operations', () {
    const id = 'f_0123456789abcdef';
    const other = 'f_fedcba9876543210';
    BridgeGate g() => BridgeGate(expectedOrigin: origin);
    BridgeRequest accepted(Object rpc) => ok(g(), msg(rpc));
    void bad(String name, Object rpc) => test(name, () => expectRejected(g(), msg(rpc), 'bad_args'));

    test('well-formed requests are accepted, with exactly the checked fields', () {
      expect(accepted({'op': 'pickFile'}).args, {'accept': <String>[]});
      expect(accepted({'op': 'pickFile', 'accept': ['image/*', 'application/pdf', '.png']}).args['accept'],
          ['image/*', 'application/pdf', '.png']);
      // The media types of office documents are long: a spreadsheet picker must not be refused for its own name.
      const sheet = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';
      const slides = 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      expect(accepted({'op': 'pickFile', 'accept': [sheet, 'application/vnd.ms-excel', '.xlsx']}).args['accept'],
          [sheet, 'application/vnd.ms-excel', '.xlsx']);
      expect(accepted({'op': 'pickFile', 'accept': [slides]}).args['accept'], [slides]);
      expect(accepted({'op': 'pickFile', 'accept': ['a' * maxAcceptEntryChars]}).args['accept'], ['a' * maxAcceptEntryChars]);
      expect(accepted({'op': 'listFiles'}).args, isEmpty);
      expect(accepted({'op': 'deleteFile', 'fileId': id}).args, {'fileId': id});
      expect(accepted({'op': 'saveFile', 'fileId': id}).args, {'fileId': id});
      expect(
          accepted({'op': 'saveFile', 'name': 'receipt_file', 'args': {'id': 42, 'x': null}}).args,
          {'name': 'receipt_file', 'args': {'id': 42, 'x': null}});
      expect(accepted({'op': 'saveFile', 'name': 'receipt_file'}).args, {'name': 'receipt_file', 'args': <String, dynamic>{}});
      expect(accepted({'op': 'askHermes', 'prompt': 'Разбери квитанцию', 'fileIds': [id, other]}).args,
          {'prompt': 'Разбери квитанцию', 'fileIds': [id, other]});
      expect(accepted({'op': 'askHermes', 'prompt': 'hi'}).args, {'prompt': 'hi', 'fileIds': <String>[]});
    });

    test('they count against the pending limit like every other request', () {
      final gate = g();
      for (var i = 0; i < maxPendingRpc; i++) {
        ok(gate, msg({'op': 'listFiles'}, id: i));
      }
      expectRejected(gate, msg({'op': 'listFiles'}, id: 99), 'too_many_requests');
      gate.release();
      ok(gate, msg({'op': 'listFiles'}, id: 100));
    });

    bad('pickFile: accept not a list', {'op': 'pickFile', 'accept': 'image/*'});
    bad('pickFile: too many entries', {'op': 'pickFile', 'accept': List.generate(9, (i) => 'image/png')});
    bad('pickFile: an entry that is not a media type', {'op': 'pickFile', 'accept': ['image/*; rm -rf']});
    bad('pickFile: an entry that is not a string', {'op': 'pickFile', 'accept': [1]});
    bad('pickFile: an entry over the length limit', {'op': 'pickFile', 'accept': ['a' * (maxAcceptEntryChars + 1)]});
    bad('pickFile: an empty entry', {'op': 'pickFile', 'accept': ['']});
    bad('pickFile: an extra field (a path)', {'op': 'pickFile', 'path': '/sdcard/x'});
    bad('listFiles: an extra field', {'op': 'listFiles', 'appId': 'other_app'});
    bad('deleteFile: no id', {'op': 'deleteFile'});
    bad('deleteFile: an id the server never issues', {'op': 'deleteFile', 'fileId': '../../registry.db'});
    bad('deleteFile: wrong case', {'op': 'deleteFile', 'fileId': 'F_0123456789abcdef'});
    bad('saveFile: neither id nor name', {'op': 'saveFile'});
    bad('saveFile: both id and name', {'op': 'saveFile', 'fileId': id, 'name': 'receipt_file'});
    bad('saveFile: args with an id', {'op': 'saveFile', 'fileId': id, 'args': {'a': 1}});
    bad('saveFile: a path as the name', {'op': 'saveFile', 'name': '/etc/passwd'});
    bad('saveFile: an address as the name', {'op': 'saveFile', 'name': 'https://evil.example/x'});
    bad('saveFile: nested args', {'op': 'saveFile', 'name': 'receipt_file', 'args': {'a': {'b': 1}}});
    bad('saveFile: a url field', {'op': 'saveFile', 'name': 'receipt_file', 'url': 'https://evil.example'});
    bad('askHermes: no prompt', {'op': 'askHermes'});
    bad('askHermes: a blank prompt', {'op': 'askHermes', 'prompt': '   '});
    bad('askHermes: a prompt that is not text', {'op': 'askHermes', 'prompt': 5});
    bad('askHermes: a prompt over the limit', {'op': 'askHermes', 'prompt': 'x' * (maxPromptChars + 1)});
    bad('askHermes: too many files', {'op': 'askHermes', 'prompt': 'hi', 'fileIds': List.generate(9, (i) => 'f_${i.toString().padLeft(16, '0')}')});
    bad('askHermes: a file listed twice', {'op': 'askHermes', 'prompt': 'hi', 'fileIds': [id, id]});
    bad('askHermes: a bad file id', {'op': 'askHermes', 'prompt': 'hi', 'fileIds': ['nope']});
    bad('askHermes: an extra field (a session)', {'op': 'askHermes', 'prompt': 'hi', 'sessionId': 's'});

    test('the longest prompt still fits the message limit, even in a two-byte language', () {
      final m = msg({'op': 'askHermes', 'prompt': 'ж' * maxPromptChars, 'fileIds': List.generate(8, (i) => 'f_${i.toString().padLeft(16, '0')}')});
      expect(utf8.encode(m).length, lessThan(maxMessageBytes));
      expect(ok(g(), m).op, 'askHermes');
    });

    test('a refusal names the request', () {
      try {
        g().accept(msg({'op': 'deleteFile', 'fileId': 'x'}, id: 61), sourceOrigin: origin, isMainFrame: true);
        fail('expected a rejection');
      } on BridgeRejected catch (e) {
        expect(e.id, 61);
      }
    });

    test('only the listed operations are file operations', () {
      expect(fileOps, {'pickFile', 'listFiles', 'deleteFile', 'saveFile', 'askHermes'});
    });
  });

  group('mutate (a button that writes)', () {
    BridgeGate g() => BridgeGate(expectedOrigin: origin);
    BridgeRequest accepted(Object rpc) => ok(g(), msg(rpc));
    void bad(String name, Object rpc) => test(name, () => expectRejected(g(), msg(rpc), 'bad_args'));

    test('a name and typed scalar arguments are accepted, and nothing else is passed on', () {
      expect(accepted({'op': 'mutate', 'name': 'mark_paid', 'args': {'id': 42}}).args, {'name': 'mark_paid', 'args': {'id': 42}});
      expect(accepted({'op': 'mutate', 'name': 'add_bill', 'args': {'supplier': 'Газ', 'amount': 5000, 'note': null, 'paid': false}}).args,
          {'name': 'add_bill', 'args': {'supplier': 'Газ', 'amount': 5000, 'note': null, 'paid': false}});
      expect(accepted({'op': 'mutate', 'name': 'wipe_old'}).args, {'name': 'wipe_old', 'args': <String, dynamic>{}});
    });

    bad('no name', {'op': 'mutate'});
    bad('a name that is not a mutation name', {'op': 'mutate', 'name': 'Mark Paid'});
    bad('a name that is sql', {'op': 'mutate', 'name': 'x; DROP TABLE bills'});
    bad('a name that is not text', {'op': 'mutate', 'name': 7});
    bad('sql in the request', {'op': 'mutate', 'name': 'mark_paid', 'sql': 'DELETE FROM bills'});
    bad('an idempotency key from the page', {'op': 'mutate', 'name': 'mark_paid', 'idempotencyKey': 'k' * 20});
    bad('a revision from the page', {'op': 'mutate', 'name': 'mark_paid', 'revision': 1});
    bad('an app from the page', {'op': 'mutate', 'name': 'mark_paid', 'appId': 'other_app'});
    bad('nested arguments', {'op': 'mutate', 'name': 'mark_paid', 'args': {'id': {'x': 1}}});
    bad('a list argument', {'op': 'mutate', 'name': 'mark_paid', 'args': {'id': [1]}});
    bad('an argument name that is not one', {'op': 'mutate', 'name': 'mark_paid', 'args': {'Id-1': 1}});
    bad('an overlong string', {'op': 'mutate', 'name': 'add_bill', 'args': {'note': 'x' * (maxStringArg + 1)}});
    bad('too many arguments', {'op': 'mutate', 'name': 'add_bill', 'args': {for (var i = 0; i < 17; i++) 'a$i': 1}});

    test('the largest legal request still fits the message limit, even in a two-byte language', () {
      final m = msg({'op': 'mutate', 'name': 'm' * 40, 'args': {for (var i = 0; i < 16; i++) 'a${i.toString().padLeft(2, '0')}': 'ж' * 240}});
      expect(utf8.encode(m).length, lessThan(maxMessageBytes));
      expect(ok(g(), m).op, 'mutate');
    });

    test('it counts against the pending limit like every other request', () {
      final gate = g();
      for (var i = 0; i < maxPendingRpc; i++) {
        ok(gate, msg({'op': 'mutate', 'name': 'mark_paid', 'args': {'id': i}}, id: i));
      }
      expectRejected(gate, msg({'op': 'mutate', 'name': 'mark_paid'}, id: 99), 'too_many_requests');
    });

    test('a refusal names the request', () {
      try {
        g().accept(msg({'op': 'mutate', 'name': 'X'}, id: 71), sourceOrigin: origin, isMainFrame: true);
        fail('expected a rejection');
      } on BridgeRejected catch (e) {
        expect(e.id, 71);
      }
    });

    test('it is the only write operation', () => expect(writeOps, {'mutate'}));
  });

  test('pending requests are capped and released', () {
    for (var i = 0; i < maxPendingRpc; i++) {
      ok(gate, msg({'op': 'hello'}, id: i));
    }
    expectRejected(gate, msg({'op': 'hello'}, id: 99), 'too_many_requests');
    gate.release();
    ok(gate, msg({'op': 'hello'}, id: 100));
  });

  test('rejected messages do not consume a pending slot', () {
    for (var i = 0; i < 50; i++) {
      expect(() => gate.accept('x', sourceOrigin: 'https://evil', isMainFrame: true), throwsA(isA<BridgeRejected>()));
    }
    expect(gate.pending, 0);
  });

  test('reply envelopes carry the id and no internals', () {
    expect(jsonDecode(BridgeGate.ok(7, {'a': 1})), {'id': 7, 'ok': true, 'value': {'a': 1}});
    expect(jsonDecode(BridgeGate.error(7, 'bad_args', 'm')), {'id': 7, 'ok': false, 'error': {'code': 'bad_args', 'message': 'm'}});
  });
}
