import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controller/state/editor-controller.state.dart';
import '../../cursor/services/cursor.service.dart';
import '../../cursor/state/cursor-controller.state.dart';
import '../../selection/services/text-selection.service.dart';
import '../const/floating.const.dart';
import '../state/editor-config.state.dart';
import '../state/editor-renderer.state.dart';
import 'lines-blocks.service.dart';

// +++ CONVERT TO CONTROLLER INSTEAD OF SERVICE
// When long pressing the cursor can be moved by dragging your finger on the screen.
// The floating cursor helps users see where the cursor is going to be placed
// while their finger is obscuring the view.
class FloatingCursorService {
  final _editorControllerState = EditorControllerState();
  final _editorConfigState = EditorConfigState();
  final _cursorControllerState = CursorControllerState();
  final _editorRendererState = EditorRendererState();
  final _linesBlocksService = LinesBlocksService();
  final _cursorService = CursorService();
  final _textSelectionService = TextSelectionService();

  // The relative origin in relation to the distance the user has theoretically dragged the floating cursor offscreen.
  // This value is used to account for the difference in the rendering position and the raw offset value.
  Offset _relativeOrigin = Offset.zero;
  Offset? _previousOffset;
  bool _resetOriginOnLeft = false;
  bool _resetOriginOnRight = false;
  bool _resetOriginOnTop = false;
  bool _resetOriginOnBottom = false;
  bool _floatingCursorOn = false;

  // The original position of the caret on FloatingCursorDragState.start.
  Rect? _startCaretRect;

  // The most recent text position as determined by the location of the floating cursor.
  TextPosition? _lastTextPosition;

  // The offset of the floating cursor as determined from the start call.
  Offset? _pointOffsetOrigin;

  // The most recent position of the floating cursor.
  Offset? _lastBoundedOffset;

  // The time it takes for the floating cursor to snap to the text aligned
  // cursor position after the user has finished placing it.
  final Duration _floatingCursorResetTime = const Duration(milliseconds: 125);

  static final _instance = FloatingCursorService._privateConstructor();

  factory FloatingCursorService() => _instance;

  FloatingCursorService._privateConstructor();
  // Sets the screen position of the floating cursor and the text position closest to the cursor.
  // `resetLerpValue` drives the size of the floating cursor.
  void setFloatingCursor(
    FloatingCursorDragState dragState,
    Offset boundedOffset,
    TextPosition textPosition, {
    double? resetLerpValue,
  }) {
    if (_editorConfigState.config.floatingCursorDisabled) return;

    if (dragState == FloatingCursorDragState.Start) {
      _relativeOrigin = Offset.zero;
      _previousOffset = null;
      _resetOriginOnBottom = false;
      _resetOriginOnTop = false;
      _resetOriginOnRight = false;
      _resetOriginOnBottom = false;
    }

    _floatingCursorOn = dragState != FloatingCursorDragState.End;
    final renderer = _editorRendererState.renderer;

    if (_floatingCursorOn) {
      renderer.floatingCursorTextPosition = textPosition;
      final sizeAdjustment = resetLerpValue != null
          ? EdgeInsets.lerp(
              floatingCaretSizeIncrease,
              EdgeInsets.zero,
              resetLerpValue,
            )!
          : floatingCaretSizeIncrease;
      final child = _linesBlocksService.childAtPosition(textPosition);
      final caretPrototype = child.getCaretPrototype(
        child.globalToLocalPosition(textPosition),
      );

      renderer.floatingCursorRect =
          sizeAdjustment.inflateRect(caretPrototype).shift(boundedOffset);

      _cursorControllerState.controller.setFloatingCursorTextPosition(
        renderer.floatingCursorTextPosition,
      );
    } else {
      renderer.floatingCursorRect = null;
      _cursorControllerState.controller.setFloatingCursorTextPosition(null);
    }
  }

  void updateFloatingCursor(
      RawFloatingCursorPoint point,
      AnimationController floatingCursorResetController,
      ) {
    switch (point.state) {
      case FloatingCursorDragState.Start:
        if (floatingCursorResetController.isAnimating) {
          floatingCursorResetController.stop();
          onFloatingCursorResetTick(
            floatingCursorResetController,
          );
        }

        // We want to send in points that are centered around a (0,0) origin, so we cache the position.
        _pointOffsetOrigin = point.offset;

        final currentTextPosition = TextPosition(
          offset: _editorControllerState.controller.selection.baseOffset,
        );
        _startCaretRect = _cursorService.getLocalRectForCaret(
          currentTextPosition,
        );

        _lastBoundedOffset = _startCaretRect!.center -
            _floatingCursorOffset(currentTextPosition);
        _lastTextPosition = currentTextPosition;

        setFloatingCursor(
          point.state,
          _lastBoundedOffset!,
          _lastTextPosition!,
        );
        break;

      case FloatingCursorDragState.Update:
        assert(_lastTextPosition != null, 'Last text position was not set');
        final floatingCursorOffset = _floatingCursorOffset(
          _lastTextPosition!,
        );
        final centeredPoint = point.offset! - _pointOffsetOrigin!;
        final rawCursorOffset =
            _startCaretRect!.center + centeredPoint - floatingCursorOffset;

        final preferredLineHeight = _linesBlocksService.preferredLineHeight(
          _lastTextPosition!,
        );
        _lastBoundedOffset =
            _calculateBoundedFloatingCursorOffset(
              rawCursorOffset,
              preferredLineHeight,
            );
        _lastTextPosition = _linesBlocksService.getPositionForOffset(
          _editorRendererState.renderer.localToGlobal(
            _lastBoundedOffset! + floatingCursorOffset,
          ),
        );
        setFloatingCursor(
          point.state,
          _lastBoundedOffset!,
          _lastTextPosition!,
        );

        final newSelection = TextSelection.collapsed(
          offset: _lastTextPosition!.offset,
          affinity: _lastTextPosition!.affinity,
        );

        // Setting selection as floating cursor moves will have scroll view
        // bring background cursor into view
        _textSelectionService.onSelectionChanged(
          newSelection,
          SelectionChangedCause.forcePress,
        );
        break;

      case FloatingCursorDragState.End:
      // We skip animation if no update has happened.
        if (_lastTextPosition != null && _lastBoundedOffset != null) {
          floatingCursorResetController
            ..value = 0.0
            ..animateTo(
              1,
              duration: _floatingCursorResetTime,
              curve: Curves.decelerate,
            );
        }
        break;
    }
  }

  // Specifies the floating cursor dimensions and position based the animation controller value.
  // The floating cursor is resized (see [RenderAbstractEditor.setFloatingCursor]) and repositioned
  // (linear interpolation between position of floating cursor and current position of background cursor)
  void onFloatingCursorResetTick(
      AnimationController floatingCursorResetController,
      ) {
    final finalPosition =
        _cursorService.getLocalRectForCaret(_lastTextPosition!).centerLeft -
            _floatingCursorOffset(_lastTextPosition!);

    if (floatingCursorResetController.isCompleted) {
      setFloatingCursor(
        FloatingCursorDragState.End,
        finalPosition,
        _lastTextPosition!,
      );
      _startCaretRect = null;
      _lastTextPosition = null;
      _pointOffsetOrigin = null;
      _lastBoundedOffset = null;
    } else {
      final lerpValue = floatingCursorResetController.value;
      final lerpX = lerpDouble(
        _lastBoundedOffset!.dx,
        finalPosition.dx,
        lerpValue,
      )!;
      final lerpY = lerpDouble(
        _lastBoundedOffset!.dy,
        finalPosition.dy,
        lerpValue,
      )!;

      setFloatingCursor(
        FloatingCursorDragState.Update,
        Offset(lerpX, lerpY),
        _lastTextPosition!,
        resetLerpValue: lerpValue,
      );
    }
  }

  // === PRIVATE ===

  // Returns the position within the editor closest to the raw cursor offset.
  Offset _calculateBoundedFloatingCursorOffset(
      Offset rawCursorOffset,
      double preferredLineHeight,
      ) {
    var deltaPosition = Offset.zero;
    final topBound = floatingCursorAddedMargin.top;
    final bottomBound = _editorRendererState.renderer.size.height -
        preferredLineHeight +
        floatingCursorAddedMargin.bottom;
    final leftBound = floatingCursorAddedMargin.left;
    final rightBound = _editorRendererState.renderer.size.width -
        floatingCursorAddedMargin.right;

    if (_previousOffset != null) {
      deltaPosition = rawCursorOffset - _previousOffset!;
    }

    // If the raw cursor offset has gone off an edge,
    // we want to reset the relative origin of
    // the dragging when the user drags back into the field.
    if (_resetOriginOnLeft && deltaPosition.dx > 0) {
      _relativeOrigin = Offset(
        rawCursorOffset.dx - leftBound,
        _relativeOrigin.dy,
      );
      _resetOriginOnLeft = false;
    } else if (_resetOriginOnRight && deltaPosition.dx < 0) {
      _relativeOrigin = Offset(
        rawCursorOffset.dx - rightBound,
        _relativeOrigin.dy,
      );
      _resetOriginOnRight = false;
    }
    if (_resetOriginOnTop && deltaPosition.dy > 0) {
      _relativeOrigin = Offset(
        _relativeOrigin.dx,
        rawCursorOffset.dy - topBound,
      );
      _resetOriginOnTop = false;
    } else if (_resetOriginOnBottom && deltaPosition.dy < 0) {
      _relativeOrigin = Offset(
        _relativeOrigin.dx,
        rawCursorOffset.dy - bottomBound,
      );
      _resetOriginOnBottom = false;
    }

    final currentX = rawCursorOffset.dx - _relativeOrigin.dx;
    final currentY = rawCursorOffset.dy - _relativeOrigin.dy;
    final double adjustedX = math.min(
      math.max(currentX, leftBound),
      rightBound,
    );
    final double adjustedY = math.min(
      math.max(currentY, topBound),
      bottomBound,
    );
    final adjustedOffset = Offset(adjustedX, adjustedY);

    if (currentX < leftBound && deltaPosition.dx < 0) {
      _resetOriginOnLeft = true;
    } else if (currentX > rightBound && deltaPosition.dx > 0) {
      _resetOriginOnRight = true;
    }

    if (currentY < topBound && deltaPosition.dy < 0) {
      _resetOriginOnTop = true;
    } else if (currentY > bottomBound && deltaPosition.dy > 0) {
      _resetOriginOnBottom = true;
    }

    _previousOffset = rawCursorOffset;

    return adjustedOffset;
  }

  // Because the center of the cursor is preferredLineHeight / 2 below the touch origin,
  // but the touch origin is used to determine which line the cursor is on,
  // we need this offset to correctly render and move the cursor.
  Offset _floatingCursorOffset(TextPosition textPosition) => Offset(
    0,
    _linesBlocksService.preferredLineHeight(textPosition) / 2,
  );

}
