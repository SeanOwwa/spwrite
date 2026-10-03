/// State layer: [GuideVisibilityState], the dashboard's "Show guides" switch.
///
/// Owns one concern only (single responsibility): whether the built-in guide
/// projects are listed. It reads and writes through the
/// [GuideVisibilityPreference] abstraction, never storage directly.
library;

import 'package:flutter/foundation.dart';

import '../domain/guides/built_in_guide.dart';

class GuideVisibilityState extends ChangeNotifier {
  GuideVisibilityState(this._preference);

  final GuideVisibilityPreference _preference;

  bool _visible = true;
  bool _disposed = false;

  /// Whether the dashboard shows the built-in guides. `true` until [load]
  /// reads the saved choice.
  bool get visible => _visible;

  /// Reads the saved choice. A storage failure keeps guides visible.
  Future<void> load() async {
    try {
      final bool saved = await _preference.load();
      if (_disposed || saved == _visible) return;
      _visible = saved;
      notifyListeners();
    } catch (_) {
      // Keep the default (visible).
    }
  }

  /// Shows or hides the guides and remembers the choice. The switch updates
  /// immediately; a failed save only means the choice is not remembered.
  Future<void> setVisible(bool visible) async {
    if (visible == _visible) return;
    _visible = visible;
    notifyListeners();
    try {
      await _preference.save(visible);
    } catch (_) {
      // Not remembered across launches; the current session still honours it.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
