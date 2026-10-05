/// Which home screen a signed-in user is allowed to open.
enum RoleHome { superAdmin, admin, citizen }

/// Anything that isn't Superadmin or Admin only gets the citizen screens.
RoleHome homeForRole(String? role) => switch (role) {
      'Superadmin' => RoleHome.superAdmin,
      'Admin' => RoleHome.admin,
      _ => RoleHome.citizen,
    };
