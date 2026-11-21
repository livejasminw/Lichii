// SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
// SPDX-License-Identifier: GPL-3.0-or-later

#include "common/ios_jit.h"

#include <array>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>

#include <mach/mach.h>
#include <mach/mach_error.h>
#include <mach/vm_map.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <csetjmp>
#include <signal.h>
#include <libkern/OSCacheControl.h>

#include <fmt/format.h>

#include "common/logging.h"

extern "C" int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);

// StikDebug universal.js "syscalls": x16 selects the command, x0/x1 carry the arguments.
extern "C" __attribute__((noinline, optnone, naked)) void LichiiJIT26Detach() {
    __asm__("mov x16, #0\n"
            "brk #0xf00d\n"
            "ret\n");
}

extern "C" __attribute__((noinline, optnone, naked)) void* LichiiJIT26PrepareRegion(void*, size_t) {
    __asm__("mov x16, #1\n"
            "brk #0xf00d\n"
            "ret\n");
}

namespace Common::IosJit {

namespace {

constexpr unsigned int CS_OPS_STATUS = 0;
constexpr std::uint32_t CS_DEBUGGED = 0x10000000;

std::mutex pool_mutex;
bool ready = false;
std::uint8_t* pool_w = nullptr;
std::uint8_t* pool_x = nullptr;
std::array<bool, SlotCount> slot_used{};

std::string SysctlString(const char* name) {
    char buffer[64]{};
    size_t size = sizeof(buffer);
    if (sysctlbyname(name, buffer, &size, nullptr, 0) != 0) {
        return {};
    }
    return buffer;
}

/// Maps a writable view of [executable, executable + size).
std::uint8_t* MapWritableAlias(std::uint8_t* executable, std::size_t size) {
    vm_address_t alias = 0;
    vm_prot_t cur_prot = VM_PROT_NONE;
    vm_prot_t max_prot = VM_PROT_NONE;
    kern_return_t ret = vm_remap(mach_task_self(), &alias, size, 0, VM_FLAGS_ANYWHERE,
                                 mach_task_self(), reinterpret_cast<vm_address_t>(executable),
                                 false, &cur_prot, &max_prot, VM_INHERIT_NONE);
    if (ret != KERN_SUCCESS) {
        LOG_CRITICAL(Common, "iOS JIT: vm_remap failed: {}", mach_error_string(ret));
        return nullptr;
    }
    ret = vm_protect(mach_task_self(), alias, size, false, VM_PROT_READ | VM_PROT_WRITE);
    if (ret != KERN_SUCCESS) {
        LOG_CRITICAL(Common, "iOS JIT: making the writable view failed: {}",
                     mach_error_string(ret));
        return nullptr;
    }
    return reinterpret_cast<std::uint8_t*>(alias);
}

sigjmp_buf probe_jump;

void ProbeFault(int) {
    siglongjmp(probe_jump, 1);
}

/// Runs a single `ret` from the start of the pool. An unprepared region faults; that is caught
/// here instead of crashing the first game thread.
bool Probe() {
    constexpr std::uint32_t RET = 0xd65f03c0;
    *reinterpret_cast<volatile std::uint32_t*>(pool_w) = RET;
    sys_icache_invalidate(pool_x, sizeof(RET));

    struct sigaction action{};
    struct sigaction old_bus{};
    struct sigaction old_segv{};
    action.sa_handler = ProbeFault;
    sigemptyset(&action.sa_mask);
    sigaction(SIGBUS, &action, &old_bus);
    sigaction(SIGSEGV, &action, &old_segv);
    bool ok = false;
    if (sigsetjmp(probe_jump, 1) == 0) {
        reinterpret_cast<void (*)()>(pool_x)();
        ok = true;
    }
    sigaction(SIGBUS, &old_bus, nullptr);
    sigaction(SIGSEGV, &old_segv, nullptr);
    *reinterpret_cast<volatile std::uint32_t*>(pool_w) = 0;
    return ok;
}

} // namespace

bool IsDebugged() {
    std::uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof(flags)) != 0) {
        return false;
    }
    return (flags & CS_DEBUGGED) != 0;
}

bool HasTXM() {
    const std::string version = SysctlString("kern.osproductversion");
    const int major = std::atoi(version.c_str());
    if (major < 26) {
        return false;
    }
    // Same rule as StikJIT: TXM on iPhone15,x (A16) and newer, and on M-series/A15+ iPads.
    const std::string machine = SysctlString("hw.machine");
    int family = 0;
    if (std::sscanf(machine.c_str(), "iPhone%d,", &family) == 1) {
        return family >= 15;
    }
    if (std::sscanf(machine.c_str(), "iPad%d,", &family) == 1) {
        return family >= 13;
    }
    return true;
}

bool Prepare() {
    std::scoped_lock lock{pool_mutex};
    if (ready) {
        return true;
    }
    if (!IsDebugged()) {
        LOG_CRITICAL(Common, "iOS JIT: not debugged; enable JIT with StikDebug first");
        return false;
    }

    const std::size_t size = SlotSize * SlotCount;
    const bool txm = HasTXM();
    LOG_INFO(Common, "iOS JIT: preparing {} MiB of code cache ({})", size >> 20,
             txm ? "TXM, universal.js" : "no TXM");

    if (txm) {
        // Map the executable region ourselves (a debugger-allocated one at 0x7000000000 once came
        // back unprepared), have StikDebug prepare it, then detach.
        auto* region = static_cast<std::uint8_t*>(
            mmap(nullptr, size, PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0));
        if (region == MAP_FAILED) {
            LOG_CRITICAL(Common, "iOS JIT: mmap of the executable region failed: {}",
                         std::strerror(errno));
            LichiiJIT26Detach();
            return false;
        }
        auto* executable = static_cast<std::uint8_t*>(LichiiJIT26PrepareRegion(region, size));
        if (executable != region) {
            LOG_CRITICAL(Common, "iOS JIT: StikDebug did not prepare the region ({} -> {})",
                         fmt::ptr(region), fmt::ptr(executable));
            LichiiJIT26Detach();
            return false;
        }
        std::uint8_t* writable = MapWritableAlias(executable, size);
        LichiiJIT26Detach();
        if (writable == nullptr) {
            return false;
        }
        pool_x = executable;
        pool_w = writable;
    } else {
        // Debugged without TXM: a writable mapping with an executable view is enough.
        auto* writable = static_cast<std::uint8_t*>(
            mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0));
        if (writable == MAP_FAILED) {
            LOG_CRITICAL(Common, "iOS JIT: mmap failed: {}", std::strerror(errno));
            return false;
        }
        vm_address_t executable = 0;
        vm_prot_t cur_prot = VM_PROT_NONE;
        vm_prot_t max_prot = VM_PROT_NONE;
        const kern_return_t ret =
            vm_remap(mach_task_self(), &executable, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                     reinterpret_cast<vm_address_t>(writable), false, &cur_prot, &max_prot,
                     VM_INHERIT_NONE);
        if (ret != KERN_SUCCESS ||
            mprotect(reinterpret_cast<void*>(executable), size, PROT_READ | PROT_EXEC) != 0) {
            LOG_CRITICAL(Common, "iOS JIT: making the executable view failed");
            return false;
        }
        pool_w = writable;
        pool_x = reinterpret_cast<std::uint8_t*>(executable);
    }

    if (!Probe()) {
        LOG_CRITICAL(Common, "iOS JIT: the code cache can't run code; it wasn't prepared");
        return false;
    }
    LOG_INFO(Common, "iOS JIT: ready (executable {}, writable {})", fmt::ptr(pool_x),
             fmt::ptr(pool_w));
    ready = true;
    return true;
}

bool IsReady() {
    std::scoped_lock lock{pool_mutex};
    return ready;
}

std::optional<Region> Allocate() {
    std::scoped_lock lock{pool_mutex};
    if (!ready) {
        return std::nullopt;
    }
    for (std::size_t i = 0; i < SlotCount; ++i) {
        if (!slot_used[i]) {
            slot_used[i] = true;
            return Region{reinterpret_cast<std::uint32_t*>(pool_w + i * SlotSize),
                          reinterpret_cast<std::uint32_t*>(pool_x + i * SlotSize), SlotSize};
        }
    }
    LOG_CRITICAL(Common, "iOS JIT: all {} code cache slots are in use", SlotCount);
    return std::nullopt;
}

void Free(const std::uint32_t* executable) {
    std::scoped_lock lock{pool_mutex};
    const auto offset = reinterpret_cast<const std::uint8_t*>(executable) - pool_x;
    if (pool_x == nullptr || offset < 0 || static_cast<std::size_t>(offset) >= SlotSize * SlotCount) {
        return;
    }
    slot_used[static_cast<std::size_t>(offset) / SlotSize] = false;
}

} // namespace Common::IosJit

// Plain C entry points for dynarmic, which doesn't link against common.
extern "C" bool LichiiIosJitAllocate(std::uint32_t** writable, std::uint32_t** executable,
                                     std::size_t* size) {
    const auto region = Common::IosJit::Allocate();
    if (!region) {
        return false;
    }
    *writable = region->writable;
    *executable = region->executable;
    *size = region->size;
    return true;
}

extern "C" void LichiiIosJitFree(const std::uint32_t* executable) {
    Common::IosJit::Free(executable);
}
