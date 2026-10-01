// Unit tests for the tolerant, hint-only NetworkConnectivityProbe (task 4.2).
//
// Validates: Requirements 4.1, 4.4, 4.5
//
// These tests drive NetworkConnectivityProbe with a fake ReachabilityCheck the
// test fully controls, so ConnectivityStatus transitions are exercised
// deterministically with no real network or DNS. checkNow() forces a single
// check without waiting on the timer; one test uses fake_async to prove the
// periodic timer both fires and is stopped by dispose().
//
// The behaviors under test (mirroring task 4.2):
//   1. Initial value is `unknown` before any check has run (Req 4.1).
//   2. A check reporting reachable=true moves value to `online` and notifies
//      listeners (Req 4.1, 4.5).
//   3. A check reporting reachable=false yields `offline` (Req 4.1).
//   4. online -> offline -> online transitions update value and fire
//      notifyListeners ONLY when the value actually changes — a repeated same
//      result produces no spurious notification (Req 4.5).
//   5. Tolerance: a ReachabilityCheck that throws is treated as `offline`
//      rather than rethrowing or crashing (Req 4.4).
//   6. After dispose() a late-completing check neither notifies nor changes
//      observable behavior, and the periodic timer is stopped so start()
//      followed by dispose() leaves no pending work (Req 4.4, 4.5).

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

// ConnectivityStatus is re-exported from the data-layer library, so importing
// connectivity_probe.dart alone provides both the probe and the enum.
import 'package:spwrite/data/ai/connectivity_probe.dart';

// ---------------------------------------------------------------------------
// A fully test-controlled ReachabilityCheck.
//
// Each invocation returns the next queued result: a bool resolves the check to
// that reachability, while a thrown-marker makes the check throw (to exercise
// the probe's tolerance, Req 4.4). Once the queue is exhausted the last result
// repeats, so a test can, e.g., queue a single `true` and call checkNow()
// several times to prove no spurious notification fires on an unchanged status.
// It records how many times it was called so timer-driven tests can assert the
// check stopped running after dispose().
// ---------------------------------------------------------------------------
class _FakeReachability {
  _FakeReachability(this._results);

  /// Queued outcomes consumed in order; each is either a `bool` (reachable) or
  /// [_throws] (the check should throw on that invocation).
  final List<Object> _results;

  /// Number of times the check has been invoked.
  int callCount = 0;

  /// Sentinel meaning "this invocation throws" so a test can exercise the
  /// tolerant path without needing a real error source.
  static const Object _throws = Object();

  /// The [ReachabilityCheck] to inject into the probe.
  Future<bool> call() async {
    final int index = callCount < _results.length
        ? callCount
        : _results.length - 1;
    callCount += 1;
    final Object result = _results[index];
    if (identical(result, _throws)) {
      throw const _FakeCheckException();
    }
    return result as bool;
  }
}

/// Error the fake throws so the tolerance test asserts on a concrete type
/// rather than a bare Exception.
class _FakeCheckException implements Exception {
  const _FakeCheckException();
}

/// A ReachabilityCheck whose completion the test controls, so a check can be
/// left in flight, dispose() called, and only THEN resolved — proving a late
/// completion never notifies after disposal (Req 4.4).
class _ControllableReachability {
  final Completer<bool> _completer = Completer<bool>();
  int callCount = 0;

  Future<bool> call() {
    callCount += 1;
    return _completer.future;
  }

  void complete(bool reachable) => _completer.complete(reachable);
}

/// Counts how many times a listenable notified, so tests can assert exactly
/// when (and when NOT) notifyListeners fired.
class _NotifyCounter {
  int count = 0;
  void call() => count += 1;
}

void main() {
  test('initial value is unknown before any check has run', () {
    // A check that would report online, but we never invoke it.
    final _FakeReachability check = _FakeReachability(<Object>[true]);
    final NetworkConnectivityProbe probe =
        NetworkConnectivityProbe(check: check.call);
    addTearDown(probe.dispose);

    expect(probe.value, ConnectivityStatus.unknown);
    expect(check.callCount, 0);
  });

  test('a reachable=true check becomes online and notifies listeners',
      () async {
    final _FakeReachability check = _FakeReachability(<Object>[true]);
    final NetworkConnectivityProbe probe =
        NetworkConnectivityProbe(check: check.call);
    addTearDown(probe.dispose);

    final _NotifyCounter notified = _NotifyCounter();
    probe.addListener(notified.call);

    await probe.checkNow();

    expect(probe.value, ConnectivityStatus.online);
    expect(notified.count, 1);
  });

  test('a reachable=false check yields offline', () async {
    final _FakeReachability check = _FakeReachability(<Object>[false]);
    final NetworkConnectivityProbe probe =
        NetworkConnectivityProbe(check: check.call);
    addTearDown(probe.dispose);

    final _NotifyCounter notified = _NotifyCounter();
    probe.addListener(notified.call);

    await probe.checkNow();

    expect(probe.value, ConnectivityStatus.offline);
    expect(notified.count, 1);
  });

  test(
    'online->offline->online updates value and notifies only on actual change',
    () async {
      // Sequence of checks: online, online (unchanged), offline, online.
      final _FakeReachability check =
          _FakeReachability(<Object>[true, true, false, true]);
      final NetworkConnectivityProbe probe =
          NetworkConnectivityProbe(check: check.call);
      addTearDown(probe.dispose);

      final _NotifyCounter notified = _NotifyCounter();
      probe.addListener(notified.call);

      // unknown -> online: value changes, one notification.
      await probe.checkNow();
      expect(probe.value, ConnectivityStatus.online);
      expect(notified.count, 1);

      // online -> online: value unchanged, NO spurious notification.
      await probe.checkNow();
      expect(probe.value, ConnectivityStatus.online);
      expect(notified.count, 1);

      // online -> offline: value changes, notification fires.
      await probe.checkNow();
      expect(probe.value, ConnectivityStatus.offline);
      expect(notified.count, 2);

      // offline -> online: value changes, notification fires.
      await probe.checkNow();
      expect(probe.value, ConnectivityStatus.online);
      expect(notified.count, 3);
    },
  );

  test('tolerance: a check that throws results in offline, not a crash',
      () async {
    final _FakeReachability check =
        _FakeReachability(<Object>[_FakeReachability._throws]);
    final NetworkConnectivityProbe probe =
        NetworkConnectivityProbe(check: check.call);
    addTearDown(probe.dispose);

    final _NotifyCounter notified = _NotifyCounter();
    probe.addListener(notified.call);

    // Must complete normally (no rethrow) and land on offline.
    await probe.checkNow();

    expect(probe.value, ConnectivityStatus.offline);
    expect(notified.count, 1);
  });

  test(
    'after dispose(), a late-completing check neither notifies nor changes value',
    () async {
      final _ControllableReachability check = _ControllableReachability();
      final NetworkConnectivityProbe probe =
          NetworkConnectivityProbe(check: check.call);

      final _NotifyCounter notified = _NotifyCounter();
      probe.addListener(notified.call);

      // Kick off a check that will not resolve yet.
      final Future<void> pending = probe.checkNow();
      expect(check.callCount, 1);

      // Dispose while the check is still in flight, then resolve it online.
      probe.dispose();
      check.complete(true);
      await pending;

      // The late completion must not have fired a notification or changed the
      // observable value (which stays at its pre-dispose unknown).
      expect(notified.count, 0);
      expect(probe.value, ConnectivityStatus.unknown);
    },
  );

  test(
    'periodic timer fires while running and is stopped by dispose()',
    () {
      fakeAsync((FakeAsync async) {
        // A short interval so the fake clock can advance across several ticks.
        const Duration interval = Duration(milliseconds: 100);
        final _FakeReachability check = _FakeReachability(<Object>[true]);
        final NetworkConnectivityProbe probe = NetworkConnectivityProbe(
          check: check.call,
          interval: interval,
        );

        // start() runs an immediate check, then the timer drives the rest.
        probe.start();
        async.flushMicrotasks();
        expect(check.callCount, 1); // immediate check
        expect(probe.value, ConnectivityStatus.online);

        // Advance across three intervals: three more timer-driven checks.
        async.elapse(interval * 3);
        expect(check.callCount, 4);

        // Dispose stops the timer: no further checks run no matter how long we
        // wait, so start-then-dispose leaves no pending work.
        probe.dispose();
        final int callsAtDispose = check.callCount;
        async.elapse(interval * 5);
        expect(check.callCount, callsAtDispose);

        // No timers remain pending after dispose().
        expect(async.pendingTimers, isEmpty);
      });
    },
  );
}
