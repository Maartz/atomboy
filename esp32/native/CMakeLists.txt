# The host for the generated core. Everything under main/ is a shim: the
# emulator itself is emitted by Elixir into main/blob.h and owns no peripheral.
cmake_minimum_required(VERSION 3.16)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(atomboy_native)
