// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#import <GameController/GameController.h>
#import <UIKit/UIKit.h>

#include <cmath>
#include <vector>

#include "input_common/drivers/virtual_gamepad.h"
#include "input_common/main.h"
#include "lichii_cmd/ios/touch_controls.h"

using VButton = InputCommon::VirtualGamepad::VirtualButton;
using VStick = InputCommon::VirtualGamepad::VirtualStick;

static InputCommon::VirtualGamepad* g_pad = nullptr;

namespace {

enum class Kind { Button, Stick };

struct Control {
    Kind kind;
    VButton button;
    VStick stick;
    NSString* label;
    UIView* view;
    UIView* knob; // sticks only
    UITouch* touch;
    bool moved = false;
    CFTimeInterval down_time = 0;
};

} // namespace

static UIColor* FillColor() {
    return [UIColor colorWithRed:0.90 green:0.93 blue:1.00 alpha:0.95];
}
static UIColor* PressedColor() {
    return [UIColor colorWithRed:0.62 green:0.71 blue:0.98 alpha:0.95];
}
static UIColor* OutlineColor() {
    return [UIColor colorWithRed:0.45 green:0.55 blue:0.86 alpha:1.0];
}
static UIColor* StickColor() {
    return [UIColor colorWithRed:0.47 green:0.58 blue:0.90 alpha:0.95];
}
static UIColor* LabelColor() {
    return [UIColor colorWithRed:0.28 green:0.33 blue:0.52 alpha:1.0];
}

@interface LichiiControlsView : UIView
@end

@implementation LichiiControlsView {
    std::vector<Control> _controls;
    UIButton* _toggle;
    BOOL _hidden;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        const auto add_button = [&](VButton b, NSString* text) {
            _controls.push_back({Kind::Button, b, VStick::Left, text, nil, nil, nil, false, 0});
        };
        const auto add_stick = [&](VStick s) {
            _controls.push_back({Kind::Stick, VButton::ButtonA, s, @"", nil, nil, nil, false, 0});
        };
        add_stick(VStick::Left);
        add_stick(VStick::Right);
        add_button(VButton::ButtonA, @"A");
        add_button(VButton::ButtonB, @"B");
        add_button(VButton::ButtonX, @"X");
        add_button(VButton::ButtonY, @"Y");
        add_button(VButton::ButtonUp, @"▲");
        add_button(VButton::ButtonDown, @"▼");
        add_button(VButton::ButtonLeft, @"◀");
        add_button(VButton::ButtonRight, @"▶");
        add_button(VButton::TriggerL, @"L");
        add_button(VButton::TriggerZL, @"ZL");
        add_button(VButton::TriggerR, @"R");
        add_button(VButton::TriggerZR, @"ZR");
        add_button(VButton::ButtonMinus, @"−");
        add_button(VButton::ButtonPlus, @"+");

        for (auto& c : _controls) {
            UIView* v = [[UIView alloc] init];
            v.userInteractionEnabled = NO;
            v.backgroundColor = c.kind == Kind::Stick ? StickColor() : FillColor();
            v.layer.borderColor = OutlineColor().CGColor;
            v.layer.borderWidth = c.kind == Kind::Stick ? 0 : 3;
            if (c.kind == Kind::Button) {
                UILabel* label = [[UILabel alloc] init];
                label.text = c.label;
                label.textColor = LabelColor();
                label.font = [UIFont systemFontOfSize:18 weight:UIFontWeightMedium];
                label.textAlignment = NSTextAlignmentCenter;
                label.autoresizingMask =
                    UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [v addSubview:label];
            } else {
                UIView* knob = [[UIView alloc] init];
                knob.userInteractionEnabled = NO;
                knob.backgroundColor = UIColor.clearColor;
                [v addSubview:knob];
                c.knob = knob;
            }
            [self addSubview:v];
            c.view = v;
        }

        _toggle = [UIButton buttonWithType:UIButtonTypeSystem];
        [_toggle setTitle:@"Hide" forState:UIControlStateNormal];
        _toggle.tintColor = [UIColor colorWithWhite:1.0 alpha:0.7];
        [_toggle addTarget:self
                      action:@selector(toggleControls)
            forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_toggle];
    }
    return self;
}

- (void)toggleControls {
    _hidden = !_hidden;
    for (auto& c : _controls) {
        c.view.hidden = _hidden;
    }
    [_toggle setTitle:(_hidden ? @"Show" : @"Hide") forState:UIControlStateNormal];
}

static void Place(UIView* v, CGFloat cx, CGFloat cy, CGFloat w, CGFloat h, bool round) {
    v.frame = CGRectMake(cx - w / 2, cy - h / 2, w, h);
    v.layer.cornerRadius = round ? std::min(w, h) / 2 : 12;
    if (v.subviews.count > 0) {
        v.subviews[0].frame = v.bounds;
    }
}

- (void)layoutSubviews {
    // Always cover the whole game view; the overlay may have been sized before a rotation.
    if (self.superview && !CGRectEqualToRect(self.frame, self.superview.bounds)) {
        self.frame = self.superview.bounds;
    }
    [super layoutSubviews];
    const CGRect full = self.bounds;
    const UIEdgeInsets inset = self.safeAreaInsets;
    const CGFloat W = full.size.width - inset.left - inset.right;
    const CGFloat X = full.origin.x + inset.left;
    const bool portrait = full.size.height > full.size.width;

    CGFloat b;           // round button size
    CGPoint dpad, face;  // diamond centers
    CGFloat shoulder_y, minus_y;
    CGFloat shoulders[4];
    if (portrait) {
        // Split at the fold: the game is drawn at the top of the upper half (see
        // Layout::portrait_top_inset); the controller fills the lower half.
        const CGFloat top = full.size.height * 0.5;
        const CGFloat bottom = full.size.height - inset.bottom;
        const CGFloat area_h = bottom - top;
        b = std::min(W * 0.68 / 6.5, area_h / 5.8);
        const CGFloat cluster_w = b * 6.5;
        const CGFloat cx = X + W / 2;
        const CGFloat total_h = b * (0.72 + 0.35 + 3.1 + 0.3 + 0.8);
        const CGFloat cy0 = top + (area_h - total_h) / 2;
        shoulder_y = cy0 + b * 0.36;
        const CGFloat diamond_y = cy0 + b * (0.72 + 0.35 + 1.55);
        dpad = CGPointMake(cx - cluster_w / 2 + b * 1.55, diamond_y);
        face = CGPointMake(cx + cluster_w / 2 - b * 1.55, diamond_y);
        minus_y = diamond_y + b * (1.55 + 0.3 + 0.4);
        for (int i = 0; i < 4; ++i) {
            shoulders[i] = cx - cluster_w / 2 + b * 0.6 + i * (cluster_w - b * 1.2) / 3;
        }
    } else {
        // Landscape: the game fills the screen; d-pad and face buttons in the lower corners.
        const CGFloat H = full.size.height - inset.top - inset.bottom;
        const CGFloat Y = full.origin.y + inset.top;
        b = H * 0.105;
        dpad = CGPointMake(X + b * 2.0, Y + H - b * 2.0);
        face = CGPointMake(X + W - b * 2.0, Y + H - b * 2.0);
        shoulder_y = dpad.y - b * 2.45;
        minus_y = Y + H - b * 0.7;
        shoulders[0] = dpad.x - b * 0.65;
        shoulders[1] = dpad.x + b * 0.65;
        shoulders[2] = face.x - b * 0.65;
        shoulders[3] = face.x + b * 0.65;
    }
    const CGFloat o = b * 1.05; // diamond spacing
    const CGFloat sw = b * 1.15, sh = b * 0.72;
    const CGFloat nub = b * 0.68;
    const CGFloat mid_x = (dpad.x + face.x) / 2;

    for (auto& c : _controls) {
        if (c.kind == Kind::Stick) {
            const CGPoint p = c.stick == VStick::Left ? dpad : face;
            c.view.transform = CGAffineTransformIdentity;
            Place(c.view, p.x, p.y, nub, nub, true);
            Place(c.knob, nub / 2, nub / 2, nub, nub, true);
            continue;
        }
        switch (c.button) {
        case VButton::ButtonA: Place(c.view, face.x + o, face.y, b, b, true); break;
        case VButton::ButtonB: Place(c.view, face.x, face.y + o, b, b, true); break;
        case VButton::ButtonX: Place(c.view, face.x, face.y - o, b, b, true); break;
        case VButton::ButtonY: Place(c.view, face.x - o, face.y, b, b, true); break;
        case VButton::ButtonUp: Place(c.view, dpad.x, dpad.y - o, b, b, true); break;
        case VButton::ButtonDown: Place(c.view, dpad.x, dpad.y + o, b, b, true); break;
        case VButton::ButtonLeft: Place(c.view, dpad.x - o, dpad.y, b, b, true); break;
        case VButton::ButtonRight: Place(c.view, dpad.x + o, dpad.y, b, b, true); break;
        case VButton::TriggerZL: Place(c.view, shoulders[0], shoulder_y, sw, sh, false); break;
        case VButton::TriggerL: Place(c.view, shoulders[1], shoulder_y, sw, sh, false); break;
        case VButton::TriggerR: Place(c.view, shoulders[2], shoulder_y, sw, sh, false); break;
        case VButton::TriggerZR: Place(c.view, shoulders[3], shoulder_y, sw, sh, false); break;
        case VButton::ButtonMinus: Place(c.view, mid_x - b * 0.85, minus_y, b * 0.8, b * 0.8, true); break;
        case VButton::ButtonPlus: Place(c.view, mid_x + b * 0.85, minus_y, b * 0.8, b * 0.8, true); break;
        default: break;
        }
    }
    for (auto& c : _controls) {
        if (c.kind == Kind::Button) {
            static_cast<UILabel*>(c.view.subviews[0]).font =
                [UIFont systemFontOfSize:b * 0.38 weight:UIFontWeightMedium];
        }
    }
    [_toggle sizeToFit];
    _toggle.center = portrait
        ? CGPointMake(X + W - _toggle.bounds.size.width, full.size.height - inset.bottom - 16)
        : CGPointMake(X + W / 2, full.origin.y + inset.top + 18);
}

// Only the controls take touches; everything else reaches the game (touch screen).
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    if (CGRectContainsPoint(_toggle.frame, point)) {
        return _toggle;
    }
    if (!_hidden) {
        for (auto& c : _controls) {
            if (CGRectContainsPoint(CGRectInset(c.view.frame, -10, -10), point)) {
                return self;
            }
        }
    }
    return nil;
}

- (void)updateStick:(Control&)c touch:(UITouch*)touch {
    // center and bounds ignore the transform that shows the stick's deflection
    const CGPoint center = c.view.center;
    const CGFloat w = c.view.bounds.size.width;
    const CGPoint p = [touch locationInView:self];
    const CGFloat r = w * 1.6;
    CGFloat dx = (p.x - center.x) / r;
    CGFloat dy = (p.y - center.y) / r;
    const CGFloat len = std::hypot(dx, dy);
    if (len > 1.0) {
        dx /= len;
        dy /= len;
    }
    c.view.transform = CGAffineTransformMakeTranslation(dx * w * 0.6, dy * w * 0.6);
    if (std::hypot(dx, dy) > 0.2) {
        c.moved = true;
    }
    if (g_pad) {
        g_pad->SetStickPosition(0, c.stick, static_cast<float>(dx), static_cast<float>(-dy));
    }
}

- (void)press:(Control&)c touch:(UITouch*)touch {
    c.touch = touch;
    if (c.kind == Kind::Stick) {
        c.moved = false;
        c.down_time = CACurrentMediaTime();
        // Grab the stick where it is; dragging from there moves it.
        if (g_pad) {
            g_pad->SetStickPosition(0, c.stick, 0.0f, 0.0f);
        }
    } else if (g_pad) {
        g_pad->SetButtonState(0, c.button, true);
        c.view.backgroundColor = PressedColor();
    }
}

- (void)release:(Control&)c {
    c.touch = nil;
    if (c.kind == Kind::Stick) {
        c.view.transform = CGAffineTransformIdentity;
        if (g_pad) {
            g_pad->SetStickPosition(0, c.stick, 0.0f, 0.0f);
            // A short tap without moving clicks the stick (L3/R3).
            if (!c.moved && CACurrentMediaTime() - c.down_time < 0.25) {
                const VButton click = c.stick == VStick::Left ? VButton::StickL : VButton::StickR;
                g_pad->SetButtonState(0, click, true);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC),
                               dispatch_get_main_queue(), ^{
                                 if (g_pad) {
                                     g_pad->SetButtonState(0, click, false);
                                 }
                               });
            }
        }
    } else {
        if (g_pad) {
            g_pad->SetButtonState(0, c.button, false);
        }
        c.view.backgroundColor = FillColor();
    }
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* t in touches) {
        const CGPoint p = [t locationInView:self];
        for (auto& c : _controls) {
            if (c.touch == nil && CGRectContainsPoint(CGRectInset(c.view.frame, -6, -6), p)) {
                [self press:c touch:t];
                break;
            }
        }
    }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* t in touches) {
        const CGPoint p = [t locationInView:self];
        for (auto& c : _controls) {
            if (c.touch != t) {
                continue;
            }
            if (c.kind == Kind::Stick) {
                [self updateStick:c touch:t];
            } else if (!CGRectContainsPoint(CGRectInset(c.view.frame, -24, -24), p)) {
                [self release:c];
            }
        }
        // Sliding onto another button presses it (d-pad rolls, face-button slides).
        for (auto& c : _controls) {
            if (c.touch == nil && c.kind == Kind::Button &&
                CGRectContainsPoint(c.view.frame, p)) {
                bool owned = false;
                for (auto& other : _controls) {
                    owned |= other.touch == t && other.kind == Kind::Stick;
                }
                if (!owned) {
                    [self press:c touch:t];
                }
            }
        }
    }
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* t in touches) {
        for (auto& c : _controls) {
            if (c.touch == t) {
                [self release:c];
            }
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self touchesEnded:touches withEvent:event];
}

@end

static void BindGamepad(GCController* controller, LichiiControlsView* overlay) {
    GCExtendedGamepad* pad = controller.extendedGamepad;
    if (pad == nil) {
        return;
    }
    // Switch layout: the pad's east button is A, south is B.
    const auto button = [](GCControllerButtonInput* input, VButton b) {
        input.pressedChangedHandler = ^(GCControllerButtonInput*, float, BOOL pressed) {
          if (g_pad) {
              g_pad->SetButtonState(0, b, pressed);
          }
        };
    };
    button(pad.buttonB, VButton::ButtonA);
    button(pad.buttonA, VButton::ButtonB);
    button(pad.buttonY, VButton::ButtonX);
    button(pad.buttonX, VButton::ButtonY);
    button(pad.leftShoulder, VButton::TriggerL);
    button(pad.rightShoulder, VButton::TriggerR);
    button(pad.leftTrigger, VButton::TriggerZL);
    button(pad.rightTrigger, VButton::TriggerZR);
    button(pad.buttonOptions, VButton::ButtonMinus);
    button(pad.buttonMenu, VButton::ButtonPlus);
    if (pad.leftThumbstickButton) {
        button(pad.leftThumbstickButton, VButton::StickL);
    }
    if (pad.rightThumbstickButton) {
        button(pad.rightThumbstickButton, VButton::StickR);
    }
    if (pad.buttonHome) {
        button(pad.buttonHome, VButton::ButtonHome);
    }
    button(pad.dpad.up, VButton::ButtonUp);
    button(pad.dpad.down, VButton::ButtonDown);
    button(pad.dpad.left, VButton::ButtonLeft);
    button(pad.dpad.right, VButton::ButtonRight);
    pad.leftThumbstick.valueChangedHandler = ^(GCControllerDirectionPad*, float x, float y) {
      if (g_pad) {
          g_pad->SetStickPosition(0, VStick::Left, x, y);
      }
    };
    pad.rightThumbstick.valueChangedHandler = ^(GCControllerDirectionPad*, float x, float y) {
      if (g_pad) {
          g_pad->SetStickPosition(0, VStick::Right, x, y);
      }
    };
    // A real controller replaces the on-screen one; it comes back when the pad disconnects.
    overlay.hidden = YES;
}

namespace IosControls {

void Attach(InputCommon::InputSubsystem* input) {
    g_pad = input->GetVirtualGamepad();
    dispatch_async(dispatch_get_main_queue(), ^{
      UIWindow* window = nil;
      for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
          if ([scene isKindOfClass:UIWindowScene.class]) {
              for (UIWindow* w in ((UIWindowScene*)scene).windows) {
                  if (w.isKeyWindow || window == nil) {
                      window = w;
                  }
              }
          }
      }
      UIView* host = window.rootViewController.view ?: window;
      if (host == nil) {
          return;
      }
      LichiiControlsView* overlay = [[LichiiControlsView alloc] initWithFrame:host.bounds];
      [host addSubview:overlay];
      __weak LichiiControlsView* weak_overlay = overlay;
      [NSTimer scheduledTimerWithTimeInterval:0.5
                                      repeats:YES
                                        block:^(NSTimer* timer) {
                                          LichiiControlsView* o = weak_overlay;
                                          if (o == nil) {
                                              [timer invalidate];
                                          } else if (o.superview &&
                                                     !CGRectEqualToRect(o.frame, o.superview.bounds)) {
                                              [o setNeedsLayout];
                                          }
                                        }];

      for (GCController* controller in GCController.controllers) {
          BindGamepad(controller, overlay);
      }
      [NSNotificationCenter.defaultCenter
          addObserverForName:GCControllerDidConnectNotification
                      object:nil
                       queue:NSOperationQueue.mainQueue
                  usingBlock:^(NSNotification* note) {
                    BindGamepad(note.object, overlay);
                  }];
      [NSNotificationCenter.defaultCenter
          addObserverForName:GCControllerDidDisconnectNotification
                      object:nil
                       queue:NSOperationQueue.mainQueue
                  usingBlock:^(NSNotification*) {
                    if (GCController.controllers.count == 0) {
                        overlay.hidden = NO;
                        if (g_pad) {
                            g_pad->ResetControllers();
                        }
                    }
                  }];
    });
}

} // namespace IosControls
