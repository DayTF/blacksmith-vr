cmake_minimum_required(VERSION 3.24)
project(blacksmith_native LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
option(BLACKSMITH_BUILD_EXTENSION "Build the Godot adapter as well as the portable kernel" ON)

add_library(blacksmith_solver STATIC src/solver.cpp)
target_include_directories(blacksmith_solver PUBLIC include)
if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
  target_compile_options(blacksmith_solver PRIVATE -Wall -Wextra -Wpedantic -ffp-contract=off)
endif()

if(BLACKSMITH_BUILD_EXTENSION)
  include(FetchContent)
  set(GODOTCPP_API_VERSION "4.7" CACHE STRING "Godot API")
  set(GODOTCPP_TARGET "template_release" CACHE STRING "Bindings target")
  set(GODOTCPP_BUILD_PROFILE "${CMAKE_CURRENT_SOURCE_DIR}/godotcpp-profile.json" CACHE FILEPATH "Bindings profile")
  FetchContent_Declare(godot_cpp
    URL https://github.com/godotengine/godot-cpp/archive/507ed9d840c01a3c5b2a39af8bb4000bfac30bf5.tar.gz
    URL_HASH SHA256=30da4ac295997061a6af81ae531510efd4e6a86e506eb4466edc0898ef3fe048
    DOWNLOAD_EXTRACT_TIMESTAMP FALSE)
  FetchContent_MakeAvailable(godot_cpp)
  add_library(blacksmith_native SHARED src/extension.cpp)
  target_link_libraries(blacksmith_native PRIVATE blacksmith_solver godot-cpp)
  set_target_properties(blacksmith_native PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/bin"
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/bin")
  foreach(config DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)
    set_target_properties(blacksmith_native PROPERTIES
      LIBRARY_OUTPUT_DIRECTORY_${config} "${CMAKE_CURRENT_SOURCE_DIR}/bin"
      RUNTIME_OUTPUT_DIRECTORY_${config} "${CMAKE_CURRENT_SOURCE_DIR}/bin")
  endforeach()
endif()

enable_testing()
add_executable(solver_tests tests/solver_tests.cpp)
target_link_libraries(solver_tests PRIVATE blacksmith_solver)
add_test(NAME solver_invariants COMMAND solver_tests)
