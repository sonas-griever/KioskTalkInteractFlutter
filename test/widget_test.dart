import 'package:flutter_test/flutter_test.dart';
import 'package:kiosk_talk/main.dart';
import 'package:kiosk_talk/talk_controller.dart';

void main() {
  testWidgets('登入頁顯示掌櫃帳號入口', (tester) async {
    await tester.pumpWidget(TalkApp(talk: TalkController()));
    expect(find.text('櫃台通話'), findsOneWidget);
    expect(find.text('登入'), findsOneWidget);
  });
}
