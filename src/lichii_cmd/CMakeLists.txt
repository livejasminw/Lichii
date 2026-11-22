# SPDX-FileCopyrightText: Copyright 2026 Eden Emulator Project
# SPDX-License-Identifier: GPL-3.0-or-later

# SPDX-License-Identifier: GPL-2.0-or-later

# Credits to Samantas5855 and others for this function.
function(create_resource file output filename)
    # Read hex data from file
    file(READ ${file} filedata HEX)
    # Convert hex data for C compatibility
    string(REGEX REPLACE "([0-9a-f][0-9a-f])" "0x\\1," filedata ${filedata})
    # Write data to output file
    set(RESOURCES_DIR "${PROJECT_BINARY_DIR}/dist" PARENT_SCOPE)
    file(WRITE "${PROJECT_BINARY_DIR}/dist/${output}" "const unsigned char ${filename}[] = {${filedata}};\nconst unsigned ${filename}_size = sizeof(${filename});\n")
endfunction()

if (ENABLE_OPENGL)
    list(APPEND OPENGL_SOURCES
        emu_window/emu_window_sdl3_gl.cpp
        emu_window/emu_window_sdl3_gl.h
    )
else()
    set(OPENGL_SOURCES "")
endif()

add_executable(lichii-cmd
    emu_window/emu_window_sdl3.cpp
    emu_window/emu_window_sdl3.h
    emu_window/sdl_window_state.h
    emu_window/emu_window_sdl3_null.cpp
    emu_window/emu_window_sdl3_null.h
    emu_window/emu_window_sdl3_vk.cpp
    emu_window/emu_window_sdl3_vk.h
    sdl_config.cpp
    sdl_config.h
    lichii.cpp
    lichii.rc
    ${OPENGL_SOURCES}
)

target_link_libraries(lichii-cmd PRIVATE common core input_common frontend_common video_core)
if (ENABLE_OPENGL)
    target_link_libraries(lichii-cmd PRIVATE glad)
endif()
target_link_libraries(lichii-cmd PRIVATE ${PLATFORM_LIBRARIES} Threads::Threads)

create_resource("../../dist/eden.bmp" "lichii_cmd/lichii_icon.h" "lichii_icon")
target_include_directories(lichii-cmd PRIVATE ${RESOURCES_DIR})

target_link_libraries(lichii-cmd PRIVATE SDL3::SDL3)

if(UNIX AND NOT APPLE)
    install(TARGETS lichii-cmd)
endif()

if(WIN32)
    # compile as a win32 gui application instead of a console application
    if(MSVC)
        # SDL's main implementation provides wmain when UNICODE is defined, which src/CMakeLists.txt
        # does for cl.exe but not for clang-cl; forcing mainCRTStartup failed to link with cl.exe.
        if(CXX_CLANG)
            set(LICHII_CMD_ENTRY mainCRTStartup)
        else()
            set(LICHII_CMD_ENTRY wmainCRTStartup)
        endif()
        set_target_properties(lichii-cmd PROPERTIES LINK_FLAGS_RELEASE "/SUBSYSTEM:WINDOWS /ENTRY:${LICHII_CMD_ENTRY}")
    elseif(MINGW)
        set_target_properties(lichii-cmd PROPERTIES LINK_FLAGS_RELEASE "-Wl,--subsystem,windows")
    endif()
endif()

create_target_directory_groups(lichii-cmd)

if (IOS)
    # SDL3 provides the UIKit app delegate; this target becomes Lichii.app.
    set_target_properties(lichii-cmd PROPERTIES
        OUTPUT_NAME Lichii
        MACOSX_BUNDLE ON
        MACOSX_BUNDLE_INFO_PLIST "${PROJECT_SOURCE_DIR}/dist/ios/Info.plist.in"
        MACOSX_BUNDLE_GUI_IDENTIFIER "com.livejasminw.lichii"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1"
        MACOSX_BUNDLE_BUNDLE_VERSION "1"
        BUILD_WITH_INSTALL_RPATH ON
        INSTALL_RPATH "@executable_path/Frameworks")
    target_sources(lichii-cmd PRIVATE ios/touch_controls.mm ios/touch_controls.h)
    set_source_files_properties(ios/touch_controls.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")
    target_link_libraries(lichii-cmd PRIVATE "-framework UIKit" "-framework GameController")
    # Static FFmpeg's dependencies (dav1d for AV1 video), which FindFFmpeg doesn't list.
    if (LICHII_IOS_EXTRA_LIBS)
        target_link_libraries(lichii-cmd PRIVATE ${LICHII_IOS_EXTRA_LIBS})
    endif()
    add_custom_command(TARGET lichii-cmd POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory "$<TARGET_BUNDLE_DIR:lichii-cmd>/Frameworks"
        COMMAND ${CMAKE_COMMAND} -E copy_directory "${MOLTENVK_FRAMEWORK}"
            "$<TARGET_BUNDLE_DIR:lichii-cmd>/Frameworks/MoltenVK.framework"
        VERBATIM)
endif()

if (HAS_HYPERVISOR)
    add_custom_command(TARGET lichii-cmd POST_BUILD
        COMMAND /usr/bin/codesign --force --sign -
            --entitlements "${PROJECT_SOURCE_DIR}/dist/eglantine.entitlements"
            "$<TARGET_FILE:lichii-cmd>"
        VERBATIM)
endif()

# needed for vma
if (NOT MSVC)
    target_compile_options(lichii-cmd PRIVATE
        $<$<COMPILE_LANGUAGE:C,CXX>:-Wno-conversion>
        $<$<COMPILE_LANGUAGE:C,CXX>:-Wno-unused-variable>
        $<$<COMPILE_LANGUAGE:C,CXX>:-Wno-unused-parameter>
        $<$<COMPILE_LANGUAGE:C,CXX>:-Wno-missing-field-initializers>)
endif()
