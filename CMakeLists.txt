cmake_minimum_required(VERSION 3.24)
project(PelagicSpheres VERSION 0.20.4 LANGUAGES CXX OBJCXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 20)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

add_library(ocean STATIC src/Sea.cpp src/BubbleStrings.cpp src/PassagePattern.cpp src/ShipFlight.cpp src/ShipMission.cpp src/XalariaCockpit.cpp
    src/XalariaInstruments.cpp src/XalariaWeather.cpp src/XalariaTerrain.cpp src/XalariaTerrainDetail.cpp
    src/XalariaGeology.cpp)
target_include_directories(ocean SYSTEM PRIVATE vendor/glm vendor/xalaria-terrain/include)
target_compile_options(ocean PRIVATE -Wall -Wextra -Wpedantic)
set_source_files_properties(src/XalariaTerrain.cpp src/XalariaGeology.cpp PROPERTIES
    COMPILE_DEFINITIONS "infinity=pelagic_terrain")

set(XALARIA_BACKEND "${CMAKE_CURRENT_SOURCE_DIR}/vendor/xalaria-missions")
set(XALARIA_STORY_DATA "${CMAKE_CURRENT_BINARY_DIR}/xalaria-mission-generated")
file(MAKE_DIRECTORY "${XALARIA_STORY_DATA}")
set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS data/story-library.tsv data/story-expansion.tsv)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/data/story-library.tsv" XALARIA_STORIES)
file(READ "${CMAKE_CURRENT_SOURCE_DIR}/data/story-expansion.tsv" XALARIA_EXPANSION)
string(APPEND XALARIA_STORIES "\n${XALARIA_EXPANSION}")
string(REPLACE "\n" ")XALARIA_STORIES\",\nR\"XALARIA_STORIES(" XALARIA_STORY_ROWS "${XALARIA_STORIES}")
file(WRITE "${XALARIA_STORY_DATA}/XalariaStoryData.hpp"
    "#pragma once\n#include <string_view>\ninline constexpr std::string_view xalariaStoryLibrary[] = {\nR\"XALARIA_STORIES(${XALARIA_STORY_ROWS})XALARIA_STORIES\"};\n")
file(GLOB XALARIA_NATIVE_SOURCES CONFIGURE_DEPENDS "${XALARIA_BACKEND}/src/*.cpp")
add_library(xalaria_backend OBJECT ${XALARIA_NATIVE_SOURCES})
target_include_directories(xalaria_backend SYSTEM PUBLIC
    "${XALARIA_BACKEND}/include" vendor/glm
    "${XALARIA_BACKEND}/third-party/FastNoise2" "${XALARIA_BACKEND}/third-party/FastSIMD"
    "${XALARIA_BACKEND}/third-party/TBB" "${XALARIA_BACKEND}/third-party/zstd"
    "${XALARIA_BACKEND}/third-party/FastNoiseGenerated"
    PRIVATE "${XALARIA_STORY_DATA}")
target_compile_definitions(xalaria_backend PUBLIC FASTNOISE_STATIC_LIB FASTSIMD_STATIC_LIB)
target_compile_options(xalaria_backend PRIVATE -ffp-contract=off)
target_link_libraries(xalaria_backend PUBLIC
    "${XALARIA_BACKEND}/lib/libinfinity_core.a" "${XALARIA_BACKEND}/lib/libFastNoise.a"
    "${XALARIA_BACKEND}/lib/libtbb.a" "${XALARIA_BACKEND}/lib/libzstd.a" sqlite3)
file(GLOB XALARIA_BACKEND_LICENSES CONFIGURE_DEPENDS "${XALARIA_BACKEND}/licenses/*")

set(SC_APP_ENGINE "${CMAKE_CURRENT_SOURCE_DIR}/vendor/sc-app-engine")
set(SC_HEADERS "${SC_APP_ENGINE}/vendor/supercollider/include")
add_library(sc_app_engine STATIC
    "${SC_APP_ENGINE}/src/portable_sc_engine.cpp"
    "${SC_APP_ENGINE}/src/sc_app_engine.cpp")
target_compile_definitions(sc_app_engine PRIVATE SCAE_BUILDING_LIBRARY=1)
target_include_directories(sc_app_engine PUBLIC "${SC_APP_ENGINE}/include"
    PRIVATE "${SC_HEADERS}/common" "${SC_HEADERS}/plugin_interface" "${SC_HEADERS}/server")
target_link_libraries(sc_app_engine PRIVATE ${CMAKE_DL_LIBS})

set(EXTERIOR_RESOURCES src/Sea.metal src/XalariaSpace.metal src/XalariaCabin.metal
    src/XalariaTerrainShadow.metal src/XalariaTerrain.metal
    src/XalariaWeather.metal src/ShipFlight.metal data/orbits.txt data/xalaria-meshes.bin
    data/xalaria-weather.tsv data/xalaria-terrain.bin data/xalaria-catalog.tsv)
add_executable(PelagicSpheres MACOSX_BUNDLE
    src/Mac.mm src/BubbleFlightHud.mm src/Score.cpp src/Spectrum.cpp src/BubbleMissions.cpp src/MissionRuntime.cpp src/MissionDispatch.cpp
    src/MissionStrategy.cpp src/MissionTransport.cpp src/MissionTravel.cpp src/MissionView.mm
    ${EXTERIOR_RESOURCES} ${XALARIA_BACKEND_LICENSES} audio/bell.scd audio/pelagic.scd licenses/Inter-OFL.txt)
set_source_files_properties(${EXTERIOR_RESOURCES}
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources HEADER_FILE_ONLY TRUE)
set_source_files_properties(licenses/Inter-OFL.txt
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources/licenses HEADER_FILE_ONLY TRUE)
set_source_files_properties(${XALARIA_BACKEND_LICENSES}
    PROPERTIES MACOSX_PACKAGE_LOCATION Resources/licenses/xalaria HEADER_FILE_ONLY TRUE)
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
    target_sources(PelagicSpheres PRIVATE "${asset}")
endforeach()

target_compile_options(PelagicSpheres PRIVATE
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc> -Wall -Wextra -Wpedantic -Wno-unused-parameter)
target_link_libraries(PelagicSpheres PRIVATE ocean sc_app_engine xalaria_backend
    "-framework AppKit" "-framework AVFoundation" "-framework CoreAudio" "-framework Accelerate" "-framework Metal"
    "-framework MetalKit" "-framework QuartzCore" "-framework CoreGraphics")
set_target_properties(PelagicSpheres PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/Info.plist.in"
    MACOSX_BUNDLE_GUI_IDENTIFIER "studio.pelagic.spheres"
    MACOSX_BUNDLE_BUNDLE_NAME "Pelagic Spheres"
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION}
    MACOSX_BUNDLE_BUNDLE_VERSION "53")
