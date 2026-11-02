import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plana_app/core/theme/app_theme.dart';
import 'package:plana_app/features/update/update_sheet.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plana/update');
  Widget app() => ProviderScope(
    child: MaterialApp(
      theme: AppTheme.light(),
      home: const Scaffold(body: UpdateRow()),
    ),
  );
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets(
    'Windows successful check, failure and retry display the current result',
    (tester) async {
      var status = 200;
      var requests = 0;
      final client = MockClient((request) async {
        requests++;
        expect(
          request.url.path,
          '/repos/LingXia979/Plana-App-for-windows/releases',
        );
        return http.Response(status == 200 ? '[]' : '{}', status);
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        await tester.pumpWidget(app());
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
        expect(find.text('已是最新'), findsOneWidget);
        status = 404;
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
        expect(find.text('检查失败'), findsOneWidget);
        expect(find.text('已是最新'), findsNothing);
        expect(find.textContaining('HTTP 404'), findsOneWidget);
        status = 200;
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
        expect(find.text('已是最新'), findsOneWidget);
        expect(find.text('检查失败'), findsNothing);
        expect(requests, 3);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
    variant: TargetPlatformVariant({TargetPlatform.windows}),
  );

  testWidgets(
    'unavailable installed version displays no information instead of latest',
    (tester) async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => null,
      );
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('[]', 200);
      });
      addTearDown(client.close);
      await http.runWithClient(() async {
        await tester.pumpWidget(app());
        await tester.tap(find.text('检查更新'));
        await tester.pumpAndSettle();
        expect(find.text('暂无更新信息'), findsWidgets);
        expect(find.text('已是最新'), findsNothing);
        expect(find.text('已是最新版本'), findsNothing);
        expect(requests, 0);
        await tester.pumpWidget(const SizedBox.shrink());
      }, () => client);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}
