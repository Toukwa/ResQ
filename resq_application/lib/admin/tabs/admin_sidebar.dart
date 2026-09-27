import 'package:flutter/material.dart';

class AdminSidebar extends StatelessWidget {
  final int selectedIndex;
  final Function(int index) onSelectTab;
  final VoidCallback onLogout;

  const AdminSidebar({
    super.key,
    required this.selectedIndex,
    required this.onSelectTab,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    const Color brandOrange = Color(0xFFFF6B00);

    return Container(
      width: 80,
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(
          right: BorderSide(color: Color(0xFFE2E8F0), width: 1),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 24),
          // ResQ Admin Brand Shield Container
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: brandOrange,
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Icon(
              Icons.shield_outlined,
              color: Colors.white,
              size: 28,
            ),
          ),
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
                  ),
                  _buildSidebarIcon(
                    Icons.directions_car_outlined,
                    1,
                    "Fleet & Vehicles",
                  ),
                  _buildSidebarIcon(
                    Icons.map_outlined,
                    2,
                    "Operations Map",
                  ),
                  _buildSidebarIcon(
                    Icons.gpp_maybe_outlined,
                    3,
                    "Incident Reports",
                  ),
                  _buildSidebarIcon(
                    Icons.receipt_long_rounded,
                    4,
                    "Activity Logs",
                  ),
                  _buildSidebarIcon(
                    Icons.perm_media_outlined,
                    5,
                    "Evidence / Media Gallery",
                  ),
                  _buildSidebarIcon(
                    Icons.manage_accounts_outlined,
                    6,
                    "Department Fleet Management",
                  ),
                  _buildSidebarIcon(
                    Icons.settings_outlined,
                    7,
                    "Settings",
                  ),

                ],
              ),
            ),
          ),

          const Divider(height: 1, indent: 16, endIndent: 16, color: Color(0xFFE2E8F0)),

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
  }

  Widget _buildSidebarIcon(IconData icon, int targetIndex, String tooltipText) {
    final bool isActive = selectedIndex == targetIndex;
    return GestureDetector(
      onTap: () => onSelectTab(targetIndex),
      behavior: HitTestBehavior.opaque,
      child: Tooltip(
        message: tooltipText,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 14.0, horizontal: 24.0),
          child: Icon(
            icon,
            color: isActive ? const Color(0xFFFF6B00) : const Color(0xFF94A3B8),
            size: 24,
          ),
        ),
      ),
    );
  }
}
