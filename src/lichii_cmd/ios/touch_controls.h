// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

namespace InputCommon {
class InputSubsystem;
}

namespace IosControls {

/// Puts the on-screen controller over the game window and forwards any connected
/// GameController-framework pad. Both drive player 1 through the virtual gamepad.
void Attach(InputCommon::InputSubsystem* input);

} // namespace IosControls
