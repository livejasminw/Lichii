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
};

} // namespace

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
            _controls.push_back({Kind::Button, b, VStick::Left, text, nil, nil, nil});
        };
        const auto add_stick = [&](VStick s) {
            _controls.push_back({Kind::Stick, VButton::ButtonA, s, @"", nil, nil, nil});
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
        add_button(VButton::StickL, @"LS");
        add_button(VButton::StickR, @"RS");

        for (auto& c : _controls) {
            UIView* v = [[UIView alloc] init];
            v.userInteractionEnabled = NO;
            v.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
            v.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.55].CGColor;
            v.layer.borderWidth = 1.5;
            if (c.kind == Kind::Button) {
                UILabel* label = [[UILabel alloc] init];
                label.text = c.label;
                label.textColor = [UIColor colorWithWhite:1.0 alpha:0.9];
                label.font = [UIFont boldSystemFontOfSize:18];
                label.textAlignment = NSTextAlignmentCenter;
                label.autoresizingMask =
                    UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [v addSubview:label];
            } else {
                UIView* knob = [[UIView alloc] init];
                knob.userInteractionEnabled = NO;
                knob.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.45];
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
    [super layoutSubviews];
    const CGRect safe = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    const CGFloat W = safe.size.width, H = safe.size.height, X = safe.origin.x, Y = safe.origin.y;
    const CGFloat b = std::min(W, H) * 0.13;  // face button size
    const CGFloat s = std::min(W, H) * 0.34;  // stick size
    const CGFloat d = b * 0.95;               // d-pad button size

    // Face buttons (Switch layout) bottom right; right stick to their left.
    const CGFloat fx = X + W - b * 1.9, fy = Y + H - b * 2.3;
    for (auto& c : _controls) {
        if (c.kind == Kind::Stick) {
            const bool left = c.stick == VStick::Left;
            const CGFloat cx = left ? X + s * 0.62 : X + W - b * 4.6 - s * 0.2;
            const CGFloat cy = left ? Y + H * 0.42 + s * 0.2 : Y + H - s * 0.48;
            const CGFloat size = left ? s : s * 0.72;
            Place(c.view, cx, cy, size, size, true);
            Place(c.knob, size / 2, size / 2, size * 0.42, size * 0.42, true);
            continue;
        }
        switch (c.button) {
        case VButton::ButtonA: Place(c.view, fx + b * 1.05, fy, b, b, true); break;
        case VButton::ButtonB: Place(c.view, fx, fy + b * 1.05, b, b, true); break;
        case VButton::ButtonX: Place(c.view, fx, fy - b * 1.05, b, b, true); break;
        case VButton::ButtonY: Place(c.view, fx - b * 1.05, fy, b, b, true); break;
        case VButton::ButtonUp: Place(c.view, X + s * 1.45, Y + H - d * 2.6, d, d, false); break;
        case VButton::ButtonDown: Place(c.view, X + s * 1.45, Y + H - d * 0.7, d, d, false); break;
        case VButton::ButtonLeft: Place(c.view, X + s * 1.45 - d, Y + H - d * 1.65, d, d, false); break;
        case VButton::ButtonRight: Place(c.view, X + s * 1.45 + d, Y + H - d * 1.65, d, d, false); break;
        case VButton::TriggerZL: Place(c.view, X + b * 0.9, Y + b * 0.6, b * 1.5, b * 0.8, false); break;
        case VButton::TriggerL: Place(c.view, X + b * 2.6, Y + b * 0.6, b * 1.5, b * 0.8, false); break;
        case VButton::TriggerR: Place(c.view, X + W - b * 2.6, Y + b * 0.6, b * 1.5, b * 0.8, false); break;
        case VButton::TriggerZR: Place(c.view, X + W - b * 0.9, Y + b * 0.6, b * 1.5, b * 0.8, false); break;
        case VButton::ButtonMinus: Place(c.view, X + W / 2 - b * 1.2, Y + b * 0.6, b * 0.75, b * 0.75, true); break;
        case VButton::ButtonPlus: Place(c.view, X + W / 2 + b * 1.2, Y + b * 0.6, b * 0.75, b * 0.75, true); break;
        case VButton::StickL: Place(c.view, X + s * 0.62, Y + H * 0.42 - s * 0.55, b * 0.75, b * 0.75, true); break;
        case VButton::StickR: Place(c.view, X + W - b * 4.6 - s * 0.2, Y + H - s * 1.05, b * 0.75, b * 0.75, true); break;
        default: break;
        }
    }
    [_toggle sizeToFit];
    _toggle.center = CGPointMake(X + W / 2, Y + b * 1.35);
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
    const CGRect f = c.view.frame;
    const CGPoint p = [touch locationInView:self];
    const CGFloat r = f.size.width / 2;
    CGFloat dx = (p.x - CGRectGetMidX(f)) / r;
    CGFloat dy = (p.y - CGRectGetMidY(f)) / r;
    const CGFloat len = std::hypot(dx, dy);
    if (len > 1.0) {
        dx /= len;
        dy /= len;
    }
    Place(c.knob, r + dx * r * 0.6, r + dy * r * 0.6, f.size.width * 0.42, f.size.width * 0.42, true);
    if (g_pad) {
        g_pad->SetStickPosition(0, c.stick, static_cast<float>(dx), static_cast<float>(-dy));
    }
}

- (void)press:(Control&)c touch:(UITouch*)touch {
    c.touch = touch;
    if (c.kind == Kind::Stick) {
        [self updateStick:c touch:touch];
    } else if (g_pad) {
        g_pad->SetButtonState(0, c.button, true);
        c.view.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.45];
    }
}

- (void)release:(Control&)c {
    c.touch = nil;
    if (c.kind == Kind::Stick) {
        const CGFloat w = c.view.frame.size.width;
        Place(c.knob, w / 2, w / 2, w * 0.42, w * 0.42, true);
        if (g_pad) {
            g_pad->SetStickPosition(0, c.stick, 0.0f, 0.0f);
        }
    } else {
        if (g_pad) {
            g_pad->SetButtonState(0, c.button, false);
        }
        c.view.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    }
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* t in touches) {
        const CGPoint p = [t locationInView:self];
        for (auto& c : _controls) {
            if (c.touch == nil && CGRectContainsPoint(CGRectInset(c.view.frame, -10, -10), p)) {
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
