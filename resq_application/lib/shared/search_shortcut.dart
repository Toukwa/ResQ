import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';

/// Ctrl+F jumps into the search box of the screen being looked at.
/// Search fields register their FocusNode while they exist.
class SearchShortcut {
  static final _fields = <FocusNode>[];

  static void register(FocusNode node) => _fields.add(node);
  static void unregister(FocusNode node) => _fields.remove(node);

  /// Focuses the newest search box that is actually on screen (tabs kept alive in the
  /// background are skipped: a tap at the box's centre must land on the box itself).
  static bool focusVisible() {
    for (final node in _fields.reversed) {
      final ctx = node.context;
      final box = ctx?.findRenderObject();
      if (ctx == null || box is! RenderBox || !box.attached || !box.hasSize) continue;
      final centre = box.localToGlobal(box.size.center(Offset.zero));
      final result = HitTestResult();
      RendererBinding.instance.hitTestInView(result, centre, View.of(ctx).viewId);
      if (result.path.any((e) => e.target == box || _isInside(e.target, box))) {
        node.requestFocus();
        return true;
      }
    }
    return false;
  }

  static bool _isInside(HitTestTarget target, RenderBox box) {
    if (target is! RenderObject) return false;
    RenderObject? o = target;
    while (o != null) {
      if (o == box) return true;
      o = o.parent;
    }
    return false;
  }
}
