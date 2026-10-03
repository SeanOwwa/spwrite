/// State layer: the [AutosaveDebouncer] coalesces a rapid burst of Content or
/// Title changes into a single deferred action, so a save runs only after the
/// user has paused editing for a fixed idle window (Req 7.1).
library;

import 'dart:async';

/// Debounces a callback behind a resettable [Timer].
///
/// Each call to [schedule] cancels any timer left pending from a previous call
/// and starts a fresh one. The supplied callback runs only once the debounce
/// [duration] elapses with no intervening [schedule] call — i.e. after the
/// editor has been idle for that long. This implements the "no further change
/// within 2 seconds" autosave trigger (Req 7.1).
///
/// The debounce window defaults to 2 seconds per Req 7.1. It is configurable
/// through the constructor so tests can inject a duration (for example when
/// driving a `FakeAsync` clock).
class AutosaveDebouncer {
  /// The idle window that must elapse after the most recent [schedule] call
  /// before the pending callback runs.
  final Duration duration;

  Timer? _timer;

  /// Creates a debouncer with the given idle [duration], defaulting to the
  /// 2-second autosave window mandated by Req 7.1.
  AutosaveDebouncer({this.duration = const Duration(seconds: 2)});

  /// Whether a callback is currently scheduled and has not yet run.
  bool get isPending => _timer?.isActive ?? false;

  /// Cancels any pending callback and schedules [callback] to run once
  /// [duration] elapses with no further [schedule] call. Calling this again
  /// before the timer fires restarts the window, so only the final change in a
  /// burst results in a run (Req 7.1).
  void schedule(void Function() callback) {
    _timer?.cancel();
    _timer = Timer(duration, callback);
  }

  /// Cancels any pending callback without running it, so the owner can run the
  /// work immediately instead (e.g. an explicit "save now").
  void cancel() {
    _timer?.cancel();
    _timer = null;
  }

  /// Cancels any pending callback. Called when the owning state is disposed so
  /// no timer outlives it.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
