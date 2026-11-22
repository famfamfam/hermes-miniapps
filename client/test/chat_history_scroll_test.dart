import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hermes_android/core/models/attachment_draft.dart';
import 'package:hermes_android/core/screens/chat_screen.dart';
import 'package:hermes_android/core/services/attachment_draft_service.dart';
import 'package:hermes_android/core/services/connection_manager.dart';
import 'package:hermes_android/core/services/ws_client.dart';
import 'package:hermes_android/core/utils/chat_history_scroll.dart';
import 'package:hermes_android/core/widgets/chat_end_affordance.dart';
import 'package:hermes_android/l10n/app_localizations.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'verbose_mode': false});
  });

  group('REST history', () {
    test('stays chronological and appends the current prompt exactly once', () {
      final history = buildRestChatHistory([
        {'role': 'user', 'content': 'oldest question'},
        {'role': 'assistant', 'content': 'middle answer'},
      ]);

      final requestMessages = GatewayChatClient.buildChatCompletionMessages(
        message: 'current question',
        history: history,
      );

      expect(requestMessages, [
        {'role': 'user', 'content': 'oldest question'},
        {'role': 'assistant', 'content': 'middle answer'},
        {'role': 'user', 'content': 'current question'},
      ]);
      expect(
        requestMessages.where(
          (message) => message['content'] == 'current question',
        ),
        hasLength(1),
      );
    });
  });

  group('scroll coordinator', () {
    test('normal opening exposes only one end alignment', () {
      final coordinator = ChatScrollCoordinator();

      final first = coordinator.consumeInitialEndAlignment();
      final second = coordinator.consumeInitialEndAlignment();

      expect(first, isA<ChatScrollTarget>());
      expect(second, isNull);
      expect(coordinator.initialEndAlignmentConsumed, isTrue);
    });

    for (final transport in const ['REST', 'Remote']) {
      test(
        '$transport completion follows only when streaming started at end',
        () {
          final following = ChatScrollCoordinator();
          following.beginStreaming(isNearEnd: true);
          expect(following.streamingContentChanged(), isNotNull);
          expect(following.endStreaming(), isNotNull);

          final readingHistory = ChatScrollCoordinator();
          readingHistory.beginStreaming(isNearEnd: false);
          expect(readingHistory.streamingContentChanged(), isNull);
          expect(readingHistory.endStreaming(), isNull);
        },
      );
    }

    test('direct user scrolling disables and can resume sticky follow', () {
      final coordinator = ChatScrollCoordinator();
      coordinator.beginStreaming(isNearEnd: true);

      coordinator.updateFromUserScroll(isNearEnd: false);
      expect(coordinator.streamingContentChanged(), isNull);

      coordinator.updateFromUserScroll(isNearEnd: true);
      expect(coordinator.streamingContentChanged(), isNotNull);
    });
  });

  group('end affordance controller', () {
    test('visibility uses distance while unread clears only at actual end', () {
      final controller = ChatEndAffordanceController(
        showThreshold: 200,
        endTolerance: 1,
      );

      controller.updatePosition(pixels: 400, maxScrollExtent: 1000);
      expect(controller.isVisible, isTrue);
      expect(controller.isAtEnd, isFalse);
      expect(controller.registerMaterializedMessage(willFollow: false), isTrue);
      expect(controller.newMessageCount, 1);

      controller.updatePosition(pixels: 850, maxScrollExtent: 1000);
      expect(controller.isVisible, isFalse);
      expect(controller.newMessageCount, 1);

      controller.updatePosition(pixels: 998, maxScrollExtent: 1000);
      expect(controller.isAtEnd, isFalse);
      expect(controller.newMessageCount, 1);

      controller.updatePosition(pixels: 999.5, maxScrollExtent: 1000);
      expect(controller.isAtEnd, isTrue);
      expect(controller.newMessageCount, 0);
    });

    test('followed messages never create transient unread state', () {
      final controller = ChatEndAffordanceController();
      controller.updatePosition(pixels: 500, maxScrollExtent: 1000);

      expect(controller.registerMaterializedMessage(willFollow: true), isFalse);
      expect(controller.newMessageCount, 0);
    });
  });

  group('ChatScreen integration', () {
    testWidgets(
      'composer stays overflow-free at font scale 200% on compact screens',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        for (final width in [320.0, 360.0]) {
          tester.view.physicalSize = Size(width, 640);
          await _pumpChat(
            tester,
            client: _ControlledChatHttpClient(const []),
            connectionId: 'compact-$width',
            sessionId: 'compact-$width',
            textScale: 2,
          );

          for (final label in const [
            'Add attachment',
            'Message',
            'Start voice input',
            'Send message',
          ]) {
            expect(find.bySemanticsLabel(label), findsOneWidget);
          }
          // Spoken replies moved from the composer row into the chat menu.
          expect(find.bySemanticsLabel('Spoken replies'), findsNothing);
          // Attach, text and microphone share one rounded bar; send sits
          // next to it. Every control keeps a 48dp-high touch target.
          expect(find.byKey(const Key('chat-composer-bar')), findsOneWidget);
          expect(
            tester.getSize(find.byTooltip('Attach image or file')),
            const Size(44, 48),
          );
          for (final tooltip in const ['Speak to Hermes', 'Send']) {
            expect(tester.getSize(find.byTooltip(tooltip)), const Size(48, 48));
          }
          expect(
            find.descendant(
              of: find.byKey(const Key('chat-composer-bar')),
              matching: find.byTooltip('Speak to Hermes'),
            ),
            findsOneWidget,
          );
          final messageField = tester.widget<TextField>(
            find.descendant(
              of: find.bySemanticsLabel('Message'),
              matching: find.byType(TextField),
            ),
          );
          expect(messageField.minLines, 1);
          expect(messageField.maxLines, 6);
          expect(messageField.decoration?.hintText, 'Message Hermes…');
          expect(tester.takeException(), isNull);
        }
      },
    );

    testWidgets(
      'opens a materialized long history at end after stable layout',
      (tester) async {
        final historyGate = Completer<void>();
        final client = _ControlledChatHttpClient(
          _longHistory(),
          historyGate: historyGate,
        );

        await _pumpChat(
          tester,
          client: client,
          connectionId: 'delayed-opening',
          sessionId: 'delayed-opening',
          settle: false,
        );
        await tester.pump();
        expect(find.byType(ListView), findsNothing);

        historyGate.complete();
        await tester.pumpAndSettle();

        final controller = _chatListController(tester);
        expect(controller.position.maxScrollExtent, greaterThan(0));
        expect(controller.position.pixels, controller.position.maxScrollExtent);
        expect(find.bySemanticsLabel('Go to end'), findsNothing);
      },
    );

    testWidgets('screenshot projection keeps the sent photos visible', (
      tester,
    ) async {
      final client = _ControlledChatHttpClient(const []);
      final service = _SlowRemovalDraftService();
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ChatScreen(
            connection: SavedConnection(
              id: 'projection',
              label: 'Fixture',
              host: 'fixture.example',
              port: 8642,
              apiKey: 'synthetic-test-key',
            ),
            session: Session(
              id: 'projection',
              title: 'Fixture chat',
              model: 'fixture-model',
              source: 'test',
              messageCount: 0,
              isActive: true,
              preview: '',
              startedAt: 1,
            ),
            testApiClient: ApiClient(
              baseUrl: 'http://fixture.example',
              apiKey: 'synthetic-test-key',
              httpClient: client,
            ),
            testAttachmentDraftService: service,
            testInitialAttachmentDrafts: [
              AttachmentDraft(
                id: 'shot',
                cachedPath: 'C:/synthetic/shot.png',
                name: 'shot.png',
                byteLength: 4,
                mediaType: 'image/png',
                kind: AttachmentDraftKind.image,
                sanitized: true,
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'see this');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await client.postStarted.future;
      client.emitToken('Working');
      await tester.pump();
      expect(find.text('Working', findRichText: true), findsOneWidget);
      expect(find.bySemanticsLabel('Attachment drafts'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      client.finish([
        {'role': 'user', 'content': 'see this\n[screenshot]'},
        {'role': 'assistant', 'content': 'done'},
      ]);
      await tester.pumpAndSettle();
      expect(find.text('see this'), findsOneWidget);
      expect(find.text('[screenshot]'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('lost image recovery blocks selection and send', (tester) async {
      const picker = MethodChannel('plugins.flutter.io/image_picker');
      final retrieveStarted = Completer<void>();
      final retrieveResult = Completer<void>();
      var galleryCalls = 0;
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(picker, (call) async {
        if (call.method == 'retrieve') {
          retrieveStarted.complete();
          await retrieveResult.future;
          return null;
        }
        expect(call.method, 'pickMultiImage');
        galleryCalls++;
        return <String>[];
      });
      addTearDown(() {
        if (!retrieveResult.isCompleted) retrieveResult.complete();
        messenger.setMockMethodCallHandler(picker, null);
      });
      final client = _ControlledChatHttpClient(const []);
      await _pumpChat(
        tester,
        client: client,
        connectionId: 'recovery-pending',
        sessionId: 'recovery-pending',
        settle: false,
      );
      await tester.pump();
      expect(retrieveStarted.isCompleted, isTrue);
      await tester.enterText(find.byType(TextField), 'pending recovery');
      await tester.pump();
      expect(
        tester.widget<IconButton>(find.byTooltip('Attach image or file')).onPressed,
        isNull,
      );
      expect(tester.widget<IconButton>(find.byTooltip('Send')).onPressed, isNull);
      await tester.tap(find.byTooltip('Attach image or file'));
      await tester.tap(find.byTooltip('Send'));
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(find.text('Choose images'), findsNothing);
      expect(galleryCalls, 0);
      expect(client.postStarted.isCompleted, isFalse);

      retrieveResult.complete();
      await tester.pumpAndSettle();
      expect(
        tester.widget<IconButton>(find.byTooltip('Attach image or file')).onPressed,
        isNotNull,
      );
      expect(tester.widget<IconButton>(find.byTooltip('Send')).onPressed, isNotNull);
      await tester.tap(find.byTooltip('Attach image or file'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose images'));
      await tester.pumpAndSettle();
      expect(galleryCalls, 1);
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(client.postStarted.isCompleted, isTrue);
      client.finish([
        {'role': 'user', 'content': 'pending recovery'},
      ]);
      await tester.pumpAndSettle();
    });

    for (final scenario in ['unchanged', 'edited', 'recovered']) {
      testWidgets('initial send waits for recovery: $scenario', (tester) async {
        const picker = MethodChannel('plugins.flutter.io/image_picker');
        final retrieveResult = Completer<Map<String, Object>?>();
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(picker, (call) async {
          expect(call.method, 'retrieve');
          return retrieveResult.future;
        });
        addTearDown(() {
          if (!retrieveResult.isCompleted) retrieveResult.complete(null);
          messenger.setMockMethodCallHandler(picker, null);
        });
        final client = _ControlledChatHttpClient(const []);
        final service = _RecoveredImageDraftService();
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: ChatScreen(
              connection: SavedConnection(
                id: 'initial-$scenario',
                label: 'Fixture',
                host: 'fixture.example',
                port: 8642,
                apiKey: 'synthetic-test-key',
              ),
              session: Session(
                id: 'initial-$scenario',
                title: 'Fixture chat',
                model: 'fixture-model',
                source: 'test',
                messageCount: 0,
                isActive: true,
                preview: '',
                startedAt: 1,
              ),
              testApiClient: ApiClient(
                baseUrl: 'http://fixture.example',
                apiKey: 'synthetic-test-key',
                httpClient: client,
              ),
              testAttachmentDraftService: service,
              initialComposerText: 'confirmed text',
              sendInitialText: true,
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(client.postStarted.isCompleted, isFalse);
        if (scenario == 'edited') {
          await tester.enterText(find.byType(TextField), 'edited text');
        }
        retrieveResult.complete(
          scenario == 'recovered'
              ? {
                  'path': 'C:/synthetic/photo.png',
                  'pathList': ['C:/synthetic/photo.png'],
                  'type': 'image',
                }
              : null,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        await tester.pump();
        if (scenario == 'unchanged') {
          expect(client.postStarted.isCompleted, isTrue);
          final request = jsonDecode(client.lastRequestBody!) as Map<String, dynamic>;
          expect(request['messages'], [
            {'role': 'user', 'content': 'confirmed text'},
          ]);
          client.finish(const []);
          await tester.pumpAndSettle();
        } else {
          expect(client.postStarted.isCompleted, isFalse);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            scenario == 'edited' ? 'edited text' : 'confirmed text',
          );
          if (scenario == 'recovered') {
            expect(find.bySemanticsLabel('Attachment drafts'), findsOneWidget);
          }
        }
      });
    }

    testWidgets('gallery selection blocks send until it completes', (
      tester,
    ) async {
      const picker = MethodChannel('plugins.flutter.io/image_picker');
      final pickerStarted = Completer<void>();
      final pickerResult = Completer<List<String>>();
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(picker, (call) async {
        if (call.method == 'retrieve') return null;
        expect(call.method, 'pickMultiImage');
        pickerStarted.complete();
        return pickerResult.future;
      });
      addTearDown(() {
        if (!pickerResult.isCompleted) pickerResult.complete([]);
        messenger.setMockMethodCallHandler(picker, null);
      });
      final client = _ControlledChatHttpClient(const []);
      await _pumpChat(
        tester,
        client: client,
        connectionId: 'gallery-pending',
        sessionId: 'gallery-pending',
      );

      await tester.tap(find.bySemanticsLabel('Add attachment'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose images'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(pickerStarted.isCompleted, isTrue);
      await tester.enterText(find.byType(TextField), 'pending selection');
      await tester.pump();
      expect(tester.widget<IconButton>(find.byTooltip('Send')).onPressed, isNull);
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(client.postStarted.isCompleted, isFalse);

      pickerResult.complete([]);
      await tester.pumpAndSettle();
      expect(
        tester.widget<IconButton>(find.byTooltip('Send')).onPressed,
        isNotNull,
      );
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await client.postStarted.future;
      final request =
          jsonDecode(client.lastRequestBody!) as Map<String, dynamic>;
      expect(request['messages'], [
        {'role': 'user', 'content': 'pending selection'},
      ]);
      client.finish([
        {'role': 'user', 'content': 'pending selection'},
      ]);
      await tester.pumpAndSettle();
    });

    testWidgets('send locks drafts and Stop does not bring them back', (
      tester,
    ) async {
      final client = _ControlledChatHttpClient(const []);
      final readGate = Completer<void>();
      final service = _SlowRemovalDraftService(readGate: readGate);
      addTearDown(() {
        if (!readGate.isCompleted) readGate.complete();
        if (!service.releaseRemoval.isCompleted) {
          service.releaseRemoval.complete();
        }
      });
      await _pumpChat(
        tester,
        client: client,
        connectionId: 'slow-removal',
        sessionId: 'slow-removal',
        attachmentDraftService: service,
        initialDrafts: [_fixtureDraft('sent-file')],
      );
      final remove = find.byTooltip('Remove attachment');
      expect(tester.widget<IconButton>(remove).onPressed, isNotNull);
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      expect(client.postStarted.isCompleted, isFalse);
      expect(tester.widget<IconButton>(remove).onPressed, isNull);
      expect(
        tester.widget<IconButton>(find.byTooltip('Attach image or file')).onPressed,
        isNull,
      );

      readGate.complete();
      await tester.pump();
      expect(client.postStarted.isCompleted, isTrue);
      expect(find.bySemanticsLabel('Attachment drafts'), findsNothing);
      await tester.tap(find.byTooltip('Stop response'));
      await tester.pump();
      expect(service.removedIds, ['sent-file']);
      expect(service.removalFinished, isFalse);
      expect(find.bySemanticsLabel('Attachment drafts'), findsNothing);
      service.releaseRemoval.complete();
      await tester.pumpAndSettle();
      expect(service.removalFinished, isTrue);
      expect(find.bySemanticsLabel('Attachment drafts'), findsNothing);
    });

    testWidgets('REST rejection restores editable files and text', (
      tester,
    ) async {
      final client = _ControlledChatHttpClient(const [], postStatusCode: 413);
      final service = _SlowRemovalDraftService()..releaseRemoval.complete();
      await _pumpChat(
        tester,
        client: client,
        connectionId: 'rejected-file',
        sessionId: 'rejected-file',
        attachmentDraftService: service,
        initialDrafts: [_fixtureDraft('rejected-file')],
      );
      await tester.enterText(find.byType(TextField), 'Try this');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(client.postStarted.isCompleted, isTrue);
      expect(find.bySemanticsLabel('Attachment drafts'), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byTooltip('Remove attachment')).onPressed,
        isNotNull,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Try this',
      );
      expect(service.removedIds, isEmpty);
    });

    testWidgets('reopening ignores an old position and returns to end', (
      tester,
    ) async {
      final messages = _longHistory();
      await _pumpChat(
        tester,
        client: _ControlledChatHttpClient(messages),
        connectionId: 'no-restore',
        sessionId: 'no-restore',
      );
      final firstController = _chatListController(tester);
      firstController.jumpTo(320);
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      await _pumpChat(
        tester,
        client: _ControlledChatHttpClient(messages),
        connectionId: 'no-restore',
        sessionId: 'no-restore',
      );
      final reopenedController = _chatListController(tester);

      expect(
        reopenedController.position.pixels,
        reopenedController.position.maxScrollExtent,
      );
      expect(reopenedController.position.pixels, isNot(closeTo(320, 0.01)));
    });

    testWidgets('sends chronological REST history through the real screen', (
      tester,
    ) async {
      final initialMessages = [
        {'role': 'user', 'content': 'oldest question'},
        {'role': 'assistant', 'content': 'middle answer'},
      ];
      final client = _ControlledChatHttpClient(initialMessages);

      await _pumpChat(
        tester,
        client: client,
        connectionId: 'integration-history',
        sessionId: 'history-session',
      );
      await tester.enterText(find.byType(TextField), 'current question');
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      await client.postStarted.future;

      final request =
          jsonDecode(client.lastRequestBody!) as Map<String, dynamic>;
      expect(request['messages'], [
        {'role': 'user', 'content': 'oldest question'},
        {'role': 'assistant', 'content': 'middle answer'},
        {'role': 'user', 'content': 'current question'},
      ]);

      client.finish([
        ...initialMessages,
        {'role': 'user', 'content': 'current question'},
        {'role': 'assistant', 'content': 'final answer'},
      ]);
      await tester.pumpAndSettle();
    });

    testWidgets(
      'REST follows at end but preserves history through refresh and completion',
      (tester) async {
        final initialMessages = _longHistory();
        final client = _ControlledChatHttpClient(initialMessages);

        await _pumpChat(
          tester,
          client: client,
          connectionId: 'rest-scroll',
          sessionId: 'rest-scroll',
        );
        final controller = _chatListController(tester);
        expect(controller.position.pixels, controller.position.maxScrollExtent);

        controller.jumpTo(80);
        await tester.pump();
        await tester.tap(find.byTooltip('Chat actions'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Refresh'));
        await tester.pumpAndSettle();
        expect(controller.position.pixels, closeTo(80, 0.01));

        await tester.enterText(find.byType(TextField), 'stay in history');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await client.postStarted.future;

        client.emitToken('first materialized delta');
        await tester.pump();
        await tester.pump();
        final historyPosition = controller.position.pixels;
        expect(_indicatorText(tester), '1 new');
        expect(_goToEndSemantics(tester).value, '1 new message');

        client.emitToken(' and a second delta of the same message');
        await tester.pump();
        await tester.pump();
        expect(controller.position.pixels, closeTo(historyPosition, 0.01));
        expect(_indicatorText(tester), '1 new');

        client.finish([
          ...initialMessages,
          {'role': 'user', 'content': 'stay in history'},
          {
            'role': 'assistant',
            'content':
                'first materialized delta and a second delta of the same message',
          },
        ]);
        await tester.pumpAndSettle();
        expect(controller.position.pixels, closeTo(historyPosition, 0.01));
        expect(_indicatorText(tester), '1 new');

        await tester.tap(find.bySemanticsLabel('Go to end'));
        await tester.pumpAndSettle();
        expect(controller.position.pixels, controller.position.maxScrollExtent);
        expect(find.bySemanticsLabel('Go to end'), findsNothing);
      },
    );

    testWidgets(
      'REST streaming at end follows content growth before completion',
      (tester) async {
        final initialMessages = _longHistory();
        final client = _ControlledChatHttpClient(initialMessages);
        await _pumpChat(
          tester,
          client: client,
          connectionId: 'rest-follow',
          sessionId: 'rest-follow',
        );
        final controller = _chatListController(tester);

        await tester.enterText(find.byType(TextField), 'follow this');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await client.postStarted.future;
        client.emitToken(List.filled(60, 'growing response').join('\n'));
        await tester.pump();
        await tester.pump();

        expect(controller.position.pixels, controller.position.maxScrollExtent);
        expect(find.bySemanticsLabel('Go to end'), findsNothing);

        client.finish([
          ...initialMessages,
          {'role': 'user', 'content': 'follow this'},
          {'role': 'assistant', 'content': 'done'},
        ]);
        await tester.pumpAndSettle();
        expect(controller.position.pixels, controller.position.maxScrollExtent);
      },
    );

    testWidgets(
      'Remote completion preserves history and counts each new message once',
      (tester) async {
        final remote = _ControlledRemotePrompt();
        await _pumpChat(
          tester,
          client: _ControlledChatHttpClient(_longHistory()),
          connectionId: 'remote-history',
          sessionId: 'remote-history',
          remoteSubmit: remote.submit,
        );
        final controller = _chatListController(tester);
        controller.jumpTo(80);
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'remote response');
        await tester.tap(find.byTooltip('Send'));
        await tester.pump();
        await remote.started.future;

        remote.emit('message.delta', {'text': 'first'});
        await tester.pump();
        await tester.pump();
        final historyPosition = controller.position.pixels;
        expect(_indicatorText(tester), '1 new');

        remote.emit('message.delta', {'text': ' second delta'});
        await tester.pump();
        await tester.pump();
        expect(_indicatorText(tester), '1 new');
        expect(controller.position.pixels, closeTo(historyPosition, 0.01));

        remote.emit('message.interim', {
          'text': ' interim',
          'already_streamed': false,
        });
        remote.emit('message.delta', {'text': 'second message'});
        await tester.pump();
        await tester.pump();
        expect(_indicatorText(tester), '2 new');
        expect(_goToEndSemantics(tester).value, '2 new messages');

        remote.emit('message.complete', {'rendered': 'second message final'});
        remote.finish();
        await tester.pumpAndSettle();
        expect(controller.position.pixels, closeTo(historyPosition, 0.01));
        expect(_indicatorText(tester), '2 new');

        await _dragToEnd(tester, controller);
        expect(controller.position.pixels, controller.position.maxScrollExtent);
        expect(find.bySemanticsLabel('Go to end'), findsNothing);
      },
    );

    testWidgets(
      'end action stays above compact composer, IME, and attachment panel',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(360, 720);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);

        await _pumpChat(
          tester,
          client: _ControlledChatHttpClient(_longHistory()),
          connectionId: 'compact-end-action',
          sessionId: 'compact-end-action',
          viewInsets: const EdgeInsets.only(bottom: 220),
          initialDrafts: [_fixtureDraft('one'), _fixtureDraft('two')],
        );
        final controller = _chatListController(tester);
        controller.jumpTo(0);
        await tester.pumpAndSettle();

        final button = find.byKey(ChatEndAffordance.buttonKey);
        final inputBar = find.byKey(const Key('chat-input-bar'));
        expect(button, findsOneWidget);
        expect(find.bySemanticsLabel('Attachment drafts'), findsOneWidget);
        expect(
          tester.getRect(button).bottom,
          lessThanOrEqualTo(tester.getRect(inputBar).top),
        );
        expect(tester.getRect(button).bottom, lessThanOrEqualTo(500));
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'server file picker inserts an @file reference in the composer',
      (tester) async {
        await _pumpChat(
          tester,
          client: _ControlledChatHttpClient(const []),
          connectionId: 'server-file',
          sessionId: 'server-file',
          serverFilePicker: () async => '/srv/project/README.md',
        );

        await tester.tap(find.bySemanticsLabel('Add attachment'));
        await tester.pumpAndSettle();
        expect(find.text('Browse server files'), findsOneWidget);

        await tester.tap(find.text('Browse server files'));
        await tester.pumpAndSettle();

        final composer = tester.widget<TextField>(find.byType(TextField));
        expect(composer.controller!.text, '@file /srv/project/README.md ');
      },
    );
  });
}

Future<void> _pumpChat(
  WidgetTester tester, {
  required _ControlledChatHttpClient client,
  required String connectionId,
  required String sessionId,
  double textScale = 1,
  EdgeInsets viewInsets = EdgeInsets.zero,
  TestRemotePromptSubmit? remoteSubmit,
  Future<String?> Function()? serverFilePicker,
  AttachmentDraftService? attachmentDraftService,
  List<AttachmentDraft> initialDrafts = const [],
  bool settle = true,
}) async {
  final apiClient = ApiClient(
    baseUrl: 'http://fixture.example',
    apiKey: 'synthetic-test-key',
    httpClient: client,
  );
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          viewInsets: viewInsets,
        ),
        child: child!,
      ),
      home: ChatScreen(
        connection: SavedConnection(
          id: connectionId,
          label: 'Fixture',
          host: 'fixture.example',
          port: 8642,
          apiKey: 'synthetic-test-key',
        ),
        session: Session(
          id: sessionId,
          title: 'Fixture chat',
          model: 'fixture-model',
          source: 'test',
          messageCount: client.serverMessages.length,
          isActive: true,
          preview: '',
          startedAt: 1,
        ),
        testApiClient: apiClient,
        testRemotePromptSubmit: remoteSubmit,
        testServerFilePicker: serverFilePicker,
        testAttachmentDraftService: attachmentDraftService,
        testInitialAttachmentDrafts: initialDrafts,
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

ScrollController _chatListController(WidgetTester tester) {
  return tester.widget<ListView>(find.byType(ListView).first).controller!;
}

String? _indicatorText(WidgetTester tester) {
  return tester.widget<Text>(find.byKey(ChatEndAffordance.countKey)).data;
}

SemanticsNode _goToEndSemantics(WidgetTester tester) {
  return tester.getSemantics(find.bySemanticsLabel('Go to end'));
}

Future<void> _dragToEnd(
  WidgetTester tester,
  ScrollController controller,
) async {
  for (
    var attempt = 0;
    attempt < 12 &&
        controller.position.pixels < controller.position.maxScrollExtent - 1;
    attempt++
  ) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -600));
    await tester.pumpAndSettle();
  }
}

AttachmentDraft _fixtureDraft(String id) {
  return AttachmentDraft(
    id: id,
    cachedPath: 'C:/synthetic/$id.txt',
    name: '$id.txt',
    byteLength: 4,
    mediaType: 'text/plain',
    kind: AttachmentDraftKind.genericFile,
  );
}

List<Map<String, dynamic>> _longHistory() {
  return [
    for (var index = 0; index < 24; index++)
      {
        'role': index.isEven ? 'user' : 'assistant',
        'content':
            'message $index\n${List.filled(5, 'history line').join('\n')}',
      },
  ];
}

class _RecoveredImageDraftService extends AttachmentDraftService {
  @override
  Future<AttachmentDraft> prepareImage({
    required String sourcePath,
    required String displayName,
    required Iterable<AttachmentDraft> existingDrafts,
    required AttachmentDraftMode mode,
  }) async => AttachmentDraft(
    id: 'recovered-image',
    cachedPath: sourcePath,
    name: displayName,
    byteLength: 4,
    mediaType: 'image/png',
    kind: AttachmentDraftKind.image,
    sanitized: true,
  );
}

class _SlowRemovalDraftService extends AttachmentDraftService {
  final Completer<void>? readGate;
  final releaseRemoval = Completer<void>();
  final removedIds = <String>[];
  bool removalFinished = false;

  _SlowRemovalDraftService({this.readGate});

  @override
  Future<String> readDataUrl(AttachmentDraft draft) async {
    await readGate?.future;
    if (!draft.isImage) return 'data:text/plain;base64,dGVzdA==';
    // 1x1 transparent PNG so the bubble's Image.memory decode succeeds.
    return 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
  }

  @override
  Future<void> removeAll(Iterable<AttachmentDraft> drafts) async {
    removedIds.addAll(drafts.map((draft) => draft.id));
    await releaseRemoval.future;
    removalFinished = true;
  }
}

class _ControlledRemotePrompt {
  Completer<void> started = Completer<void>();
  Completer<void>? _completion;
  StreamCallback? _onEvent;

  Future<void> submit({
    required String sessionId,
    required String text,
    required StreamCallback onEvent,
    required void Function() onSent,
  }) async {
    onSent();
    _onEvent = onEvent;
    _completion = Completer<void>();
    if (!started.isCompleted) started.complete();
    await _completion!.future;
  }

  void emit(String type, Map<String, dynamic> data) {
    _onEvent!(StreamEvent(type: type, data: data));
  }

  void finish() {
    _completion!.complete();
  }
}

class _ControlledChatHttpClient extends http.BaseClient {
  List<Map<String, dynamic>> serverMessages;
  final Completer<void> postStarted = Completer<void>();
  final Completer<void>? historyGate;
  final int postStatusCode;
  StreamController<List<int>>? _completionStream;
  String? lastRequestBody;

  _ControlledChatHttpClient(
    List<Map<String, dynamic>> messages, {
    this.historyGate,
    this.postStatusCode = 200,
  }) : serverMessages = List<Map<String, dynamic>>.from(messages);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request.method == 'GET' && request.url.path.endsWith('/messages')) {
      await historyGate?.future;
      return _jsonResponse({'data': serverMessages});
    }
    if (request.method == 'POST' &&
        request.url.path.endsWith('/v1/chat/completions')) {
      lastRequestBody = (request as http.Request).body;
      if (!postStarted.isCompleted) postStarted.complete();
      if (postStatusCode != 200) {
        return _jsonResponse({
          'error': {'message': 'Rejected'},
        }, statusCode: postStatusCode);
      }
      _completionStream = StreamController<List<int>>();
      return http.StreamedResponse(
        _completionStream!.stream,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    }
    return _jsonResponse({'error': 'unexpected request'}, statusCode: 404);
  }

  void emitToken(String token) {
    _completionStream!.add(
      utf8.encode(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': token},
            },
          ],
        })}\n\n',
      ),
    );
  }

  void finish(List<Map<String, dynamic>> finalMessages) {
    serverMessages = List<Map<String, dynamic>>.from(finalMessages);
    _completionStream!
      ..add(utf8.encode('data: [DONE]\n\n'))
      ..close();
  }

  http.StreamedResponse _jsonResponse(Object body, {int statusCode = 200}) {
    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      statusCode,
      headers: {'content-type': 'application/json'},
    );
  }
}
