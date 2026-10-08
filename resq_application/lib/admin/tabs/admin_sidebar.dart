import 'package:flutter/material.dart';
import '../../services/theme_service.dart';
import '../../shared/resq_logo.dart';
import '../../shared/tab_activity.dart';

class AdminSidebar extends StatelessWidget {
  final int selectedIndex;
  final Function(int index) onSelectTab;
  final VoidCallback onLogout;
  /// Tabs with activity the admin hasn't looked at yet (shown with a dot).
  final Set<int> tabsWithActivity;

  const AdminSidebar({
    super.key,
    required this.selectedIndex,
    required this.onSelectTab,
    required this.onLogout,
    this.tabsWithActivity = const {},
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeService.instance,
      builder: (context, _) {
        final ts = ThemeService.instance;
        final Color sidebarBg = ts.sidebarBackground;
        final Color border = ts.borderColor;
        final Color dividerColor = ts.isDark ? const Color(0xFF2D3748) : const Color(0xFFE2E8F0);
        final Color inactiveIconColor = ts.isDark ? const Color(0xFF64748B) : const Color(0xFF94A3B8);

        return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          width: 80,
          decoration: BoxDecoration(
            color: sidebarBg,
            border: Border(
              right: BorderSide(color: border, width: 1),
            ),
          ),
          child: Column(
            children: [
              const SizedBox(height: 24),
              // ResQ Admin Brand Shield Container
              const ResqLogo(size: 52, radius: 14),
              const SizedBox(height: 24),

              // Main Navigation Items List
              Expanded(
                child: SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: Column(
                    children: [
                      _buildSidebarIcon(
                        Icons.dashboard_rounded,
                        0,
                        "Operations Dashboard",
                        inactiveIconColor,
                      ),
                      _buildSidebarIcon(
                        Icons.directions_car_outlined,
                        1,
                        "Fleet & Vehicles",
                        inactiveIconColor,
                      ),
                      _buildSidebarIcon(
                        Icons.map_outlined,
                        2,
                        "Operations Map",
                        inactiveIconColor,
                      ),
                      _buildSidebarIcon(
                        Icons.gpp_maybe_outlined,
                        3,
                        "Incident Reports",
                        inactiveIconColor,
                      ),
                      _buildSidebarIcon(
                        Icons.receipt_long_rounded,
                        4,
                        "Activity Logs",
                        inactiveIconColor,
                      ),
                      _buildSidebarIcon(
                        Icons.bar_chart_rounded,
                        8,
                        "Analytics Reports",
                        inactiveIconColor,
                      ),
                      _buildSidebarIcon(
                        Icons.manage_accounts_outlined,
                        6,
                        "Department Fleet Management",
                        inactiveIconColor,
                      ),
                      _buildSidebarIcon(
                        Icons.settings_outlined,
                        7,
                        "Settings",
                        inactiveIconColor,
                      ),

                    ],
                  ),
                ),
              ),

              Divider(height: 1, indent: 16, endIndent: 16, color: dividerColor),

              // Exit / Logout Session Button
              GestureDetector(
                onTap: onLogout,
                behavior: HitTestBehavior.opaque,
                child: const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20.0),
                  child: Tooltip(
                    message: "Exit Admin Session",
                    child: Icon(
                      Icons.meeting_room_outlined,
                      color: Color(0xFFEF4444),
                      size: 26,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSidebarIcon(IconData icon, int targetIndex, String tooltipText, Color inactiveColor) {
    final bool isActive = selectedIndex == targetIndex;
    return GestureDetector(
      onTap: () => onSelectTab(targetIndex),
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: tooltipText,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14.0, horizontal: 24.0),
          child: ActivityDot(
            show: !isActive && tabsWithActivity.contains(targetIndex),
            child: Icon(
              icon,
              color: isActive ? const Color(0xFFFF6B00) : inactiveColor,
              size: 24,
            ),
          ),
        ),
      ),
    );
  }
}
