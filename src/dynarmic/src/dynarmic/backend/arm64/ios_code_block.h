// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#pragma once

#include <cstddef>
#include <cstdint>
#include <new>

#include <libkern/OSCacheControl.h>

extern "C" bool LichiiIosJitAllocate(std::uint32_t** writable, std::uint32_t** executable,
                                     std::size_t* size);
extern "C" void LichiiIosJitFree(const std::uint32_t* executable);

namespace Dynarmic::Backend::Arm64 {

/// Code cache on iOS: a slot of the pool the frontend prepared through StikDebug. Code is written
/// through wptr() and runs from ptr(); the two views never change protection.
class IosCodeBlock {
public:
    explicit IosCodeBlock(std::size_t size) {
        std::size_t slot_size = 0;
        if (!LichiiIosJitAllocate(&m_wmem, &m_xmem, &slot_size) || slot_size < size) {
            throw std::bad_alloc{};
        }
        m_size = size;
    }
    ~IosCodeBlock() {
        LichiiIosJitFree(m_xmem);
    }

    IosCodeBlock(const IosCodeBlock&) = delete;
    IosCodeBlock& operator=(const IosCodeBlock&) = delete;

    /// Executable view.
    std::uint32_t* ptr() const {
        return m_xmem;
    }
    /// Writable view.
    std::uint32_t* wptr() const {
        return m_wmem;
    }

    void protect() {}
    void unprotect() {}

    void invalidate(std::uint32_t* mem, std::size_t size) {
        sys_icache_invalidate(mem, size);
    }
    void invalidate_all() {
        sys_icache_invalidate(m_xmem, m_size);
    }

private:
    std::uint32_t* m_wmem = nullptr;
    std::uint32_t* m_xmem = nullptr;
    std::size_t m_size = 0;
};

} // namespace Dynarmic::Backend::Arm64
