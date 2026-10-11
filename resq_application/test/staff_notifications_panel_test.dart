import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/shared/staff_notifications_panel.dart';

void main() {
  Future<void> show(WidgetTester tester, List<Map<String, dynamic>> items, {int unread = 0, void Function(Map)? onTap}) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StaffNotificationsPanel(
            notifications: items,
            unreadCount: unread,
            onMarkAllRead: () {},
            onTap: onTap ?? (_) {},
            timeAgo: (t) => '${DateTime.now().difference(t).inMinutes}m',
          ),
        ),
      ));

  testWidgets('Admin data (text times, notificationType) and Super Admin data both show', (tester) async {
    Map? tapped;
    await show(tester, [
      {'id': 1, 'title': 'Unit Dispatched', 'message': 'BFP 004 sent to #2.', 'notificationType': 'DISPATCH',
       'isRead': false, 'timestamp': DateTime.now().subtract(const Duration(minutes: 5)).toUtc().toIso8601String()},
      {'id': 2, 'title': 'New Emergency: Fire', 'message': 'Report #3.', 'type': 'EMERGENCY',
       'isRead': true, 'timestamp': DateTime.now().subtract(const Duration(minutes: 30))},
    ], unread: 1, onTap: (n) => tapped = n);
    expect(find.text('1 new'), findsOneWidget);
    expect(find.text('5m'), findsOneWidget); // text time read correctly
    expect(find.byIcon(Icons.local_shipping_rounded), findsOneWidget); // dispatch icon
    expect(find.byIcon(Icons.campaign_rounded), findsOneWidget); // emergency icon
    await tester.tap(find.text('Unit Dispatched'));
    expect(tapped?['id'], 1);
  });

  testWidgets('Empty list', (tester) async {
    await show(tester, []);
    expect(find.text('No notifications yet'), findsOneWidget);
  });
}
