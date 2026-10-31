import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/features/assistant/assistant_settings.dart';
import 'package:plana_app/features/assistant/custom_endpoint.dart';
import 'package:plana_app/features/assistant/custom_endpoint_api.dart';
import 'package:plana_app/features/assistant/direct_agent.dart';
import 'package:plana_app/features/assistant/widgets/endpoint_sheet.dart';

CustomEndpoint endpoint(AgentApiFormat format) => CustomEndpoint(
  id: 'local',
  name: 'Local',
  format: format,
  baseUrl: 'http://test.invalid',
  apiKey: 'fixture-api-secret',
  model: 'test-model',
  headers: const {
    'X-Private': 'fixture-header-secret',
    'Authorization': 'Override fixture-token',
  },
);

void main() {
  for (final format in AgentApiFormat.values) {
    test(
      '$format model list and chat carry custom headers without duplicate auth',
      () async {
        final e = endpoint(format);
        final captured = <http.BaseRequest>[];
        final client = MockClient((req) async {
          captured.add(req);
          if (req.method == 'GET') {
            return http.Response(
              jsonEncode(
                format == AgentApiFormat.google
                    ? {
                        'models': [
                          {'name': 'models/local'},
                        ],
                      }
                    : {
                        'data': [
                          {'id': 'local'},
                        ],
                      },
              ),
              200,
            );
          }
          final body = switch (format) {
            AgentApiFormat.openai => {
              'choices': [
                {
                  'message': {'content': 'ok'},
                },
              ],
            },
            AgentApiFormat.google => {
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'ok'},
                    ],
                  },
                },
              ],
            },
            AgentApiFormat.anthropic => {
              'content': [
                {'type': 'text', 'text': 'ok'},
              ],
            },
          };
          return http.Response(jsonEncode(body), 200);
        });
        expect(await fetchModelList(e, client: client), ['local']);
        final out = StringBuffer();
        await directModelStream(
          client,
          e,
          system: '',
          msgs: const [(role: 'user', content: 'hello', images: [])],
          think: ThinkLevel.auto,
          timeout: const Duration(seconds: 2),
          out: out,
          stream: false,
        ).drain<void>();
        expect(out.toString(), 'ok');
        expect(captured, hasLength(2));
        for (final request in captured) {
          expect(request.headers['x-private'], 'fixture-header-secret');
          expect(request.headers['authorization'], 'Override fixture-token');
          expect(
            request.headers.keys.where(
              (h) => h.toLowerCase() == 'authorization',
            ),
            hasLength(1),
          );
        }
      },
    );
  }

  for (final streamed in [false, true]) {
    test(
      'reflected credentials are hidden in ${streamed ? 'stream' : 'HTTP'} errors',
      () async {
        final e = endpoint(AgentApiFormat.anthropic);
        final client = MockClient(
          (_) async => http.Response(
            streamed
                ? 'data: ${jsonEncode({
                    'type': 'error',
                    'error': {'message': 'fixture-api-secret fixture-header-secret Override fixture-token'},
                  })}\n\n'
                : jsonEncode({
                    'error': {
                      'message':
                          'fixture-api-secret fixture-header-secret Override fixture-token',
                    },
                  }),
            streamed ? 200 : 400,
            headers: {
              'content-type': streamed
                  ? 'text/event-stream'
                  : 'application/json',
            },
          ),
        );
        Object? error;
        try {
          await directModelStream(
            client,
            e,
            system: '',
            msgs: const [(role: 'user', content: 'hello', images: [])],
            think: ThinkLevel.auto,
            timeout: const Duration(seconds: 2),
            out: StringBuffer(),
            stream: streamed,
          ).drain<void>();
        } catch (e) {
          error = e;
        }
        expect(error, isNotNull);
        expect('$error', contains('[已隐藏]'));
        for (final secret in [
          'fixture-api-secret',
          'fixture-header-secret',
          'fixture-token',
        ]) {
          expect('$error', isNot(contains(secret)));
        }
      },
    );
  }

  test(
    'headers roundtrip, case-insensitive replacement and old endpoint migration',
    () {
      final e = endpoint(
        AgentApiFormat.openai,
      ).copyWith(headers: {'x-token': 'old', 'X-Token': 'last'});
      expect(CustomEndpoint.fromJson(e.toJson())!.headers, e.headers);
      expect(e.withHeaders({'X-TOKEN': 'default', 'Content-Type': 'json'}), {
        'Content-Type': 'json',
        'X-Token': 'last',
      });
      expect(
        CustomEndpoint.fromJson({
          'id': 'old',
          'apiKey': 'old',
          'model': 'old',
        })!.headers,
        isEmpty,
      );
      expect(parseHeaderLines('X-First: good\nBad Name: no').bad, 2);
      expect(parseHeaderLines('X-Token: first\r\nx-token: last').headers, {
        'x-token': 'last',
      });
    },
  );

  testWidgets(
    'invalid header identifies line and leaves endpoint editor open',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showEndpointSheet(
                    context,
                    source: endpoint(AgentApiFormat.openai),
                  ),
                  child: const Text('edit'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '请求头',
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, 'X-Valid: ok\nnot a header');
      await tester.ensureVisible(find.text('保存'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请求头第 2 行'), findsOneWidget);
      expect(field, findsOneWidget);
      expect(
        tester.widget<TextField>(field).controller!.text,
        contains('not a header'),
      );
    },
  );
}
