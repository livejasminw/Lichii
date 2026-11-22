// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <cstddef>
#include <cstdint>
#include <optional>

// JIT memory on iOS. Executable memory needs a debugger (StikDebug): on devices without TXM the
// attach alone allows it, and with TXM every executable region has to be prepared through the
// debugger ("universal.js" protocol) before it detaches. So the whole code cache is reserved
// up front as one pool, with a writable view for emitting code and an executable view for
// running it.
namespace Common::IosJit {

struct Region {
    std::uint32_t* writable;
    std::uint32_t* executable;
    std::size_t size;
};

/// Size of every code cache slot the pool hands out.
constexpr std::size_t SlotSize = 48 * 1024 * 1024;
/// Number of slots reserved when JIT is prepared (one per emulated core, with room to spare).
constexpr std::size_t SlotCount = 8;

/// Whether a debugger has marked this process CS_DEBUGGED.
bool IsDebugged();

/// Whether this device enforces TXM, which needs the StikDebug script handshake.
bool HasTXM();

/// Reserves the code cache pool. Call once, while CS_DEBUGGED is set; on TXM devices this also
/// prepares the pool through the debugger and detaches it.
bool Prepare();

/// Whether Prepare() succeeded.
bool IsReady();

/// Hands out one slot of SlotSize bytes; nullopt when the pool is exhausted or not ready.
std::optional<Region> Allocate();

/// Returns a slot by its executable address.
void Free(const std::uint32_t* executable);

} // namespace Common::IosJit
