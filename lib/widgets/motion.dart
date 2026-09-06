import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The app's four reusable animations.
///
/// They live in one file on purpose. Motion added ad hoc — a different duration
/// and curve at each call site — reads as jitter rather than as a designed
/// interface, and it is impossible to retune later. Everything here draws its
/// timing from [AppMotion], so changing the feel of the whole app is one edit.
///
/// All four are cheap: no clipping, no shaders, no `AnimatedBuilder` rebuilding
/// subtrees. They animate opacity and transforms only, which the compositor
/// handles without repainting children.

// =============================================================================
// Entrance
// =============================================================================

/// Fades and lifts its child into place once, when it is first built.
///
/// Pass [delay] to stagger a list: `FadeSlideIn(delay: AppMotion.stagger * i)`.
/// The delay is a real timer rather than an `Interval` curve because an interval
/// still holds the widget at opacity 0 while its animation runs, which means a
/// long list would keep 30 controllers ticking to show nothing.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = AppMotion.normal,
    this.offset = 14.0,
    this.curve = AppMotion.enter,
  });

  final Widget child;
  final Duration delay;
  final Duration duration;

  /// How far below its resting place the child starts, in logical pixels.
  /// Small on purpose — a large slide draws attention to the animation instead
  /// of to the content.
  final double offset;

  final Curve curve;

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: widget.duration,
    vsync: this,
  );

  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      // Held in a field so it can be cancelled: a staggered list scrolled away
      // before its timers fire would otherwise call `forward()` on a disposed
      // controller.
      _timer = Timer(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _controller, curve: widget.curve);
    return AnimatedBuilder(
      animation: curved,
      // `child` is passed through rather than rebuilt, so the subtree is built
      // once and only the transform and opacity change per frame.
      child: widget.child,
      builder: (context, child) => Opacity(
        opacity: curved.value,
        child: Transform.translate(
          offset: Offset(0, widget.offset * (1 - curved.value)),
          child: child,
        ),
      ),
    );
  }
}

/// Applies a staggered [FadeSlideIn] to each item in a list.
///
/// Capped at [maxStaggered] items: beyond about ten, the last item's delay is
/// longer than the user's patience, and the effect stops reading as polish.
List<Widget> staggered(
  List<Widget> children, {
  Duration step = AppMotion.stagger,
  int maxStaggered = 10,
}) {
  return List<Widget>.generate(children.length, (i) {
    return FadeSlideIn(
      delay: step * (i < maxStaggered ? i : maxStaggered),
      child: children[i],
    );
  });
}

// =============================================================================
// State changes
// =============================================================================

/// Cross-fades between states of the same region — a status card going from
/// Disconnected to Connected, a button label changing.
///
/// Give each state a distinct [ValueKey] or the switcher cannot tell that
/// anything changed and will not animate.
class AppSwap extends StatelessWidget {
  const AppSwap({
    super.key,
    required this.child,
    this.duration = AppMotion.normal,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final Duration duration;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration,
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      // The default layout builder stacks children centred, which makes a card
      // jump when the outgoing and incoming states are different heights.
      // Aligning to the top-left keeps text anchored where it was.
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        children: [...previous, ?current],
      ),
      transitionBuilder: (child, animation) => FadeTransition(
        opacity: animation,
        child: ScaleTransition(
          // Barely perceptible, and that is the point: a big scale on a status
          // card looks like an error state.
          scale: Tween<double>(begin: 0.97, end: 1.0).animate(animation),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

// =============================================================================
// Live status
// =============================================================================

/// A dot that breathes while [active], and sits still when it is not.
///
/// Used for the connection indicator. Motion is the honest signal here: a static
/// green dot says "connected" whether or not the link is still alive, whereas a
/// dot that stops moving when the stream stops is self-evidencing.
class PulseDot extends StatefulWidget {
  const PulseDot({
    super.key,
    required this.color,
    this.active = true,
    this.size = 10.0,
    this.haloSize = 22.0,
  });

  final Color color;
  final bool active;
  final double size;

  /// Outer diameter of the expanding halo. Ignored when inactive.
  final double haloSize;

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  // Created eagerly in `initState`, not as a `late final` initialiser.
  //
  // That distinction is not style. A lazy field is only constructed when it is
  // first read, and the only read in `initState` was behind `if (widget.active)`.
  // An inactive dot — the disconnected state, which is the app's default — never
  // touched it, so the first read was `_controller.dispose()`, which *built* the
  // controller during disposal. `AnimationController` calls `createTicker`, which
  // looks up `TickerMode` through the element tree, and that element has already
  // been deactivated by then: "Looking up a deactivated widget's ancestor is
  // unsafe". The thrown assertion aborted the rest of the dispose walk, which is
  // also why sibling widgets leaked their timers.
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: AppMotion.pulse, vsync: this);
    if (widget.active) _controller.repeat();
  }

  @override
  void didUpdateWidget(PulseDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active == oldWidget.active) return;
    if (widget.active) {
      _controller.repeat();
    } else {
      // Stopped rather than reset, so the halo fades out from wherever it was
      // instead of snapping to full size for one frame.
      _controller.animateTo(0, duration: AppMotion.fast);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.haloSize,
      height: widget.haloSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (widget.active)
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                final t = _controller.value;
                return Container(
                  width: widget.size + (widget.haloSize - widget.size) * t,
                  height: widget.size + (widget.haloSize - widget.size) * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: 0.28 * (1 - t)),
                  ),
                );
              },
            ),
          AnimatedContainer(
            duration: AppMotion.normal,
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color,
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Press feedback
// =============================================================================

/// Shrinks slightly while held. For cards and tiles that act as buttons.
///
/// Material's ink ripple alone is easy to miss on a large card, and on a dark
/// surface it is nearly invisible; a scale change is legible in both themes.
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.975,
    this.borderRadius = 16.0,
  });

  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final double borderRadius;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool value) {
    if (_down == value) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return GestureDetector(
      onTapDown: enabled ? (_) => _set(true) : null,
      onTapUp: enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? () => _set(false) : null,
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: AppMotion.fast,
        curve: AppMotion.standard,
        child: widget.child,
      ),
    );
  }
}
