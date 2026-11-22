cmake_minimum_required(VERSION 3.24)
project(PelagicOrbits VERSION 0.10.31 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

add_library(ocean STATIC src/Sea.cpp)
target_compile_options(ocean PRIVATE -Wall -Wextra -Wpedantic)

set(SC_APP_ENGINE "${CMAKE_CURRENT_SOURCE_DIR}/vendor/sc-app-engine")
set(SC_HEADERS "${SC_APP_ENGINE}/vendor/supercollider/include")
add_library(sc_app_engine STATIC
    "${SC_APP_ENGINE}/src/portable_sc_engine.cpp"
    "${SC_APP_ENGINE}/src/sc_app_engine.cpp")
target_compile_definitions(sc_app_engine PRIVATE SCAE_BUILDING_LIBRARY=1)
target_include_directories(sc_app_engine PUBLIC "${SC_APP_ENGINE}/include"
    PRIVATE "${SC_HEADERS}/common" "${SC_HEADERS}/plugin_interface" "${SC_HEADERS}/server")
target_link_libraries(sc_app_engine PRIVATE ${CMAKE_DL_LIBS})

add_executable(PelagicOrbits MACOSX_BUNDLE
    src/Mac.mm src/Score.cpp src/Spectrum.cpp src/Sea.metal data/orbits.txt
    audio/bell.scd audio/pelagic.scd)
set_source_files_properties(src/Sea.metal data/orbits.txt
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources HEADER_FILE_ONLY TRUE)
set_source_files_properties(audio/bell.scd audio/pelagic.scd
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources/synthdefs HEADER_FILE_ONLY TRUE)

set(SC_RUNTIME "${SC_APP_ENGINE}/runtime/supercollider")
if(NOT EXISTS "${SC_RUNTIME}/lib/libscsynth.dylib" OR NOT EXISTS "${SC_RUNTIME}/lib/libweldsclang.dylib")
    message(FATAL_ERROR "The embedded SuperCollider runtime is missing from ${SC_RUNTIME}")
endif()
file(GLOB_RECURSE SC_RESOURCES CONFIGURE_DEPENDS LIST_DIRECTORIES FALSE
    RELATIVE "${SC_RUNTIME}" "${SC_RUNTIME}/*")
foreach(relative IN LISTS SC_RESOURCES)
    get_filename_component(directory "${relative}" DIRECTORY)
    set(asset "${SC_RUNTIME}/${relative}")
    set_source_files_properties("${asset}" PROPERTIES
        MACOSX_PACKAGE_LOCATION "Resources/supercollider/${directory}" HEADER_FILE_ONLY TRUE)
    target_sources(PelagicOrbits PRIVATE "${asset}")
endforeach()

target_compile_options(PelagicOrbits PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc> -Wall -Wextra -Wpedantic -Wno-unused-parameter)
target_link_libraries(PelagicOrbits PRIVATE ocean sc_app_engine
    "-framework AppKit" "-framework AVFoundation" "-framework CoreAudio" "-framework Accelerate" "-framework Metal"
    "-framework MetalKit" "-framework QuartzCore" "-framework CoreGraphics")
set_target_properties(PelagicOrbits PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_BUNDLE_GUI_IDENTIFIER "studio.pelagic.orbits"
    MACOSX_BUNDLE_BUNDLE_NAME "Pelagic Orbits"
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION}
    MACOSX_BUNDLE_BUNDLE_VERSION "62")
