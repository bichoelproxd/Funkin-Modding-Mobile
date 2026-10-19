package funkin.ui.debug;

#if (FEATURE_HAXEUI && FEATURE_TOUCH_CONTROLS)
import flixel.FlxBasic;
import flixel.FlxState;
import haxe.ui.components.Button;
import haxe.ui.containers.HBox;
import haxe.ui.containers.VBox;
import haxe.ui.core.Screen;
import openfl.events.KeyboardEvent;
import openfl.ui.Keyboard;
import openfl.ui.KeyLocation;

/**
 * A small touch toolbar that lets the debug editors (Chart Editor, Stage Editor, Animation Editor)
 * be used without a keyboard or a mouse wheel.
 *
 * It works by feeding synthetic keyboard / mouse events to the stage, so the editors
 * don't need to know about it: `FlxG.keys`, `FlxG.mouse` and HaxeUI all react to them like to real input.
 *
 * What it provides:
 * - Sticky `CTRL` / `SHIFT` / `ALT` toggles (multi-select, shortcuts, fine adjustments).
 * - Undo, redo, play/pause, delete, enter, escape and arrow keys.
 * - Scroll and zoom (hold the buttons, or use two fingers: drag to scroll, pinch to zoom).
 * - A `R-CLICK` button which turns your next tap into a right click (context menus).
 *
 * Usage: call `EditorMobileOverlay.attach(this)` at the end of the editor's `create()`.
 */
class EditorMobileOverlay extends FlxBasic
{
  /**
   * How many frames a tapped key stays pressed.
   * It needs to be at least 2 so Flixel can see both `justPressed` and `justReleased`.
   */
  static final TAP_FRAMES:Int = 3;

  /**
   * How much a single scroll step moves (same scale as a real mouse wheel notch).
   */
  static final WHEEL_STEP:Float = 3;

  /**
   * How many pixels two fingers have to travel together to produce one scroll step.
   */
  static final DRAG_PIXELS_PER_STEP:Float = 28;

  /**
   * How many pixels two fingers have to pinch to produce one zoom step.
   */
  static final PINCH_PIXELS_PER_STEP:Float = 36;

  /**
   * Attaches a toolbar to the given state.
   * Does nothing if the state already has one.
   */
  public static function attach(state:FlxState):EditorMobileOverlay
  {
    for (member in state.members)
    {
      if (Std.isOfType(member, EditorMobileOverlay)) return cast member;
    }

    var overlay:EditorMobileOverlay = new EditorMobileOverlay();
    state.add(overlay);
    return overlay;
  }

  var panel:VBox;
  var toolsButton:Button;
  var root:VBox;

  var ctrlButton:Button;
  var shiftButton:Button;
  var altButton:Button;
  var rightClickButton:Button;

  var ctrlHeld:Bool = false;
  var shiftHeld:Bool = false;
  var altHeld:Bool = false;

  /**
   * When `true`, the next tap becomes a right click.
   */
  var rightClickArmed:Bool = false;

  /**
   * `-1` = scrolling up, `1` = scrolling down, `0` = idle. Set while a scroll button is held.
   */
  var heldScroll:Int = 0;

  /**
   * `1` = zooming in, `-1` = zooming out, `0` = idle. Set while a zoom button is held.
   */
  var heldZoom:Int = 0;

  var holdTimer:Float = 0;

  /**
   * Keys that were pressed by a tap and need to be released after a few frames.
   */
  var pendingReleases:Array<{code:Int, frames:Int}> = [];

  /**
   * Right mouse button releases that need to be sent after a few frames.
   */
  var pendingRightRelease:Int = -1;

  // Two finger gesture state.
  var gestureActive:Bool = false;
  var lastGestureCenterY:Float = 0;
  var lastGestureDistance:Float = 0;
  var dragAccumulator:Float = 0;
  var pinchAccumulator:Float = 0;

  function new()
  {
    super();

    buildUI();
  }

  function buildUI():Void
  {
    root = new VBox();
    root.left = 6;
    root.top = 96;

    toolsButton = makeButton('TOOLS', 76, function():Void
    {
      panel.hidden = !panel.hidden;
    });
    root.addComponent(toolsButton);

    panel = new VBox();
    panel.hidden = true;
    root.addComponent(panel);

    // Modifiers.
    ctrlButton = makeToggle('CTRL', 60, function(on:Bool):Void
    {
      ctrlHeld = on;
      sendKey(Keyboard.CONTROL, on);
    });
    shiftButton = makeToggle('SHFT', 60, function(on:Bool):Void
    {
      shiftHeld = on;
      sendKey(Keyboard.SHIFT, on);
    });
    altButton = makeToggle('ALT', 60, function(on:Bool):Void
    {
      altHeld = on;
      sendKey(Keyboard.ALTERNATE, on);
    });
    addRow(ctrlButton, shiftButton, altButton);

    // Common actions.
    addRow(makeButton('UNDO', 94, function():Void tapChord(Keyboard.Z, true)), makeButton('REDO', 94, function():Void tapChord(Keyboard.Y, true)));
    addRow(makeButton('PLAY', 62, function():Void tapKey(Keyboard.SPACE)), makeButton('DEL', 62, function():Void tapKey(Keyboard.DELETE)),
      makeButton('ENTR', 62, function():Void tapKey(Keyboard.ENTER)));

    // Scroll and zoom, hold to keep going.
    var scrollUp:Button = makeButton('UP', 94, function():Void {});
    scrollUp.registerEvent(haxe.ui.events.MouseEvent.MOUSE_DOWN, function(_):Void
    {
      heldScroll = -1;
    });
    var scrollDown:Button = makeButton('DOWN', 94, function():Void {});
    scrollDown.registerEvent(haxe.ui.events.MouseEvent.MOUSE_DOWN, function(_):Void
    {
      heldScroll = 1;
    });
    addRow(scrollUp, scrollDown);

    var zoomIn:Button = makeButton('ZOOM+', 94, function():Void {});
    zoomIn.registerEvent(haxe.ui.events.MouseEvent.MOUSE_DOWN, function(_):Void
    {
      heldZoom = 1;
    });
    var zoomOut:Button = makeButton('ZOOM-', 94, function():Void {});
    zoomOut.registerEvent(haxe.ui.events.MouseEvent.MOUSE_DOWN, function(_):Void
    {
      heldZoom = -1;
    });
    addRow(zoomIn, zoomOut);

    // Arrow keys.
    addRow(makeButton('<', 46, function():Void tapKey(Keyboard.LEFT)), makeButton('^', 46, function():Void tapKey(Keyboard.UP)),
      makeButton('v', 46, function():Void tapKey(Keyboard.DOWN)), makeButton('>', 46, function():Void tapKey(Keyboard.RIGHT)));

    // Right click and escape.
    rightClickButton = makeToggle('R-CLICK', 94, function(on:Bool):Void
    {
      rightClickArmed = on;
    });
    addRow(rightClickButton, makeButton('ESC', 94, function():Void tapKey(Keyboard.ESCAPE)));

    Screen.instance.addComponent(root);
  }

  function addRow(...buttons:Button):Void
  {
    var row:HBox = new HBox();
    for (button in buttons)
    {
      row.addComponent(button);
    }
    panel.addComponent(row);
  }

  function makeButton(text:String, width:Float, onTap:Void->Void):Button
  {
    var button:Button = new Button();
    button.text = text;
    button.width = width;
    button.height = 46;
    button.onClick = function(_):Void onTap();
    return button;
  }

  function makeToggle(text:String, width:Float, onChange:Bool->Void):Button
  {
    var button:Button = new Button();
    button.text = text;
    button.width = width;
    button.height = 46;
    button.toggle = true;
    button.onClick = function(_):Void onChange(button.selected);
    return button;
  }

  // - Synthetic input -

  function sendKey(code:Int, down:Bool):Void
  {
    if (FlxG.stage == null) return;

    FlxG.stage.dispatchEvent(new KeyboardEvent(down ? KeyboardEvent.KEY_DOWN : KeyboardEvent.KEY_UP, true, false, 0, code, KeyLocation.STANDARD, ctrlHeld, altHeld, shiftHeld));
  }

  /**
   * Presses a key and releases it after a few frames.
   */
  function tapKey(code:Int):Void
  {
    sendKey(code, true);
    pendingReleases.push({code: code, frames: TAP_FRAMES});
  }

  /**
   * Presses a key together with the given modifiers (on top of the sticky ones).
   */
  function tapChord(code:Int, ctrl:Bool = false, shift:Bool = false, alt:Bool = false):Void
  {
    if (ctrl && !ctrlHeld)
    {
      sendKey(Keyboard.CONTROL, true);
      pendingReleases.push({code: Keyboard.CONTROL, frames: TAP_FRAMES + 1});
    }

    if (shift && !shiftHeld)
    {
      sendKey(Keyboard.SHIFT, true);
      pendingReleases.push({code: Keyboard.SHIFT, frames: TAP_FRAMES + 1});
    }

    if (alt && !altHeld)
    {
      sendKey(Keyboard.ALTERNATE, true);
      pendingReleases.push({code: Keyboard.ALTERNATE, frames: TAP_FRAMES + 1});
    }

    tapKey(code);
  }

  /**
   * Sends a mouse wheel event. Positive scrolls up (like a real wheel).
   * @param zoom If `true` CTRL is reported as held, which is what the editors use to zoom.
   */
  function sendWheel(delta:Float, zoom:Bool = false):Void
  {
    if (FlxG.stage == null) return;

    var ctrl:Bool = ctrlHeld || zoom;
    var wasHeld:Bool = ctrlHeld;

    // Editors read the modifier from FlxG.keys, so it has to be pressed while the wheel event is processed.
    if (zoom && !wasHeld)
    {
      sendKey(Keyboard.CONTROL, true);
      pendingReleases.push({code: Keyboard.CONTROL, frames: TAP_FRAMES});
    }

    FlxG.stage.dispatchEvent(new openfl.events.MouseEvent(openfl.events.MouseEvent.MOUSE_WHEEL, true, false, FlxG.stage.mouseX, FlxG.stage.mouseY, null, ctrl,
      altHeld, shiftHeld, false, Std.int(delta)));
  }

  function sendRightClick():Void
  {
    if (FlxG.stage == null) return;

    FlxG.stage.dispatchEvent(new openfl.events.MouseEvent(openfl.events.MouseEvent.RIGHT_MOUSE_DOWN, true, false, FlxG.stage.mouseX, FlxG.stage.mouseY, null,
      ctrlHeld, altHeld, shiftHeld, true));
    pendingRightRelease = TAP_FRAMES;
  }

  // - Update -

  override function update(elapsed:Float):Void
  {
    super.update(elapsed);

    updatePendingReleases();
    updateHeldButtons(elapsed);
    updateTwoFingerGestures();
    updateRightClick();
  }

  function updatePendingReleases():Void
  {
    var i:Int = pendingReleases.length - 1;
    while (i >= 0)
    {
      var pending = pendingReleases[i];
      pending.frames--;

      if (pending.frames <= 0)
      {
        // Don't release a modifier the player is holding with the sticky toggles.
        var stickyModifier:Bool = (pending.code == Keyboard.CONTROL && ctrlHeld)
          || (pending.code == Keyboard.SHIFT && shiftHeld)
          || (pending.code == Keyboard.ALTERNATE && altHeld);

        if (!stickyModifier) sendKey(pending.code, false);
        pendingReleases.splice(i, 1);
      }

      i--;
    }

    if (pendingRightRelease >= 0)
    {
      pendingRightRelease--;

      if (pendingRightRelease < 0 && FlxG.stage != null)
      {
        FlxG.stage.dispatchEvent(new openfl.events.MouseEvent(openfl.events.MouseEvent.RIGHT_MOUSE_UP, true, false, FlxG.stage.mouseX, FlxG.stage.mouseY,
          null, ctrlHeld, altHeld, shiftHeld, false));
      }
    }
  }

  function updateHeldButtons(elapsed:Float):Void
  {
    // Stop as soon as the finger is lifted (even if it's no longer on the button).
    if (!FlxG.mouse.pressed)
    {
      heldScroll = 0;
      heldZoom = 0;
      holdTimer = 0;
      return;
    }

    if (heldScroll == 0 && heldZoom == 0) return;

    holdTimer -= elapsed;

    if (holdTimer <= 0)
    {
      // First step is instant, the rest repeat quickly.
      holdTimer = 0.06;

      if (heldScroll != 0) sendWheel(-heldScroll * WHEEL_STEP);
      if (heldZoom != 0) sendWheel(heldZoom * WHEEL_STEP, true);
    }
  }

  function updateTwoFingerGestures():Void
  {
    var fingers:Array<flixel.input.touch.FlxTouch> = [];

    for (touch in FlxG.touches.list)
    {
      if (touch != null && touch.pressed) fingers.push(touch);
    }

    if (fingers.length < 2)
    {
      gestureActive = false;
      dragAccumulator = 0;
      pinchAccumulator = 0;
      return;
    }

    var a = fingers[0];
    var b = fingers[1];
    var centerY:Float = (a.screenY + b.screenY) / 2;
    var distance:Float = Math.sqrt(Math.pow(a.screenX - b.screenX, 2) + Math.pow(a.screenY - b.screenY, 2));

    if (!gestureActive)
    {
      gestureActive = true;
      lastGestureCenterY = centerY;
      lastGestureDistance = distance;
      return;
    }

    dragAccumulator += centerY - lastGestureCenterY;
    pinchAccumulator += distance - lastGestureDistance;
    lastGestureCenterY = centerY;
    lastGestureDistance = distance;

    // Pinching takes priority over dragging, so a zoom doesn't also scroll.
    if (Math.abs(pinchAccumulator) >= PINCH_PIXELS_PER_STEP)
    {
      var steps:Int = Std.int(pinchAccumulator / PINCH_PIXELS_PER_STEP);
      sendWheel(steps * WHEEL_STEP, true);
      pinchAccumulator -= steps * PINCH_PIXELS_PER_STEP;
      dragAccumulator = 0;
    }
    else if (Math.abs(dragAccumulator) >= DRAG_PIXELS_PER_STEP)
    {
      var steps:Int = Std.int(dragAccumulator / DRAG_PIXELS_PER_STEP);
      // Dragging the content up scrolls down, like on any phone.
      sendWheel(-steps * WHEEL_STEP);
      dragAccumulator -= steps * DRAG_PIXELS_PER_STEP;
    }
  }

  function updateRightClick():Void
  {
    if (!rightClickArmed) return;

    // Ignore the tap that pressed the R-CLICK button itself.
    if (FlxG.mouse.justReleased && !isOverToolbar())
    {
      sendRightClick();
      rightClickArmed = false;
      rightClickButton.selected = false;
    }
  }

  function isOverToolbar():Bool
  {
    var point = FlxG.mouse.getViewPosition();
    var over:Bool = root.hitTest(point.x, point.y);
    point.put();
    return over;
  }

  override function destroy():Void
  {
    // Let go of anything that is still held, so the editor doesn't get stuck with a modifier.
    if (ctrlHeld) sendKey(Keyboard.CONTROL, false);
    if (shiftHeld) sendKey(Keyboard.SHIFT, false);
    if (altHeld) sendKey(Keyboard.ALTERNATE, false);

    for (pending in pendingReleases)
    {
      sendKey(pending.code, false);
    }
    pendingReleases = [];

    if (root != null)
    {
      Screen.instance.removeComponent(root);
      root = null;
    }

    super.destroy();
  }
}
#end
