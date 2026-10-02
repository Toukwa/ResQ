import 'package:flutter/material.dart';

/// Which kind of change a live event represents, so a sidebar can mark the
/// tab where it happened. Returns null for events no tab cares about.
enum TabActivity {
  incidents,
  media,
  management;

  static TabActivity? of(String event, dynamic data) => switch (event) {
        'refreshIncidentQueueEvent' || 'newNotification' => incidents,
        'refreshMediaGalleryEvent' => media,
        // Untyped refreshes are side effects of dispatches; only real fleet/account changes count
        'refreshManagementData' when data is Map && data['type'] != null => management,
        _ => null,
      };

  /// The "Tab Activity Dots" setting; shells rebuild when it changes.
  static final enabled = ValueNotifier<bool>(true);

  static const events = ['refreshIncidentQueueEvent', 'newNotification', 'refreshMediaGalleryEvent', 'refreshManagementData'];
}

/// A sidebar icon with a small red dot on its upper right when [show] is true.
class ActivityDot extends StatelessWidget {
  final Widget child;
  final bool show;
  const ActivityDot({super.key, required this.child, required this.show});

  @override
  Widget build(BuildContext context) => Stack(
        clipBehavior: Clip.none,
        children: [
          child,
          if (show)
            Positioned(
              top: -2,
              right: -3,
              child: Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444),
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
              ),
            ),
        ],
      );
}
