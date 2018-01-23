cmake_minimum_required (VERSION 3.1)

find_program(TERRA "terra" DOC "Path to terra executable")
if (NOT TERRA)
    message(FATAL_ERROR "Unable to find terra executable")
endif()


add_custom_command(
    OUTPUT opt_c_interface.o
    COMMAND "${TERRA}" "./API/src/createwrapper.t"
            Opt "./API/src" o "./API/release/include/Opt.h"
            "${CMAKE_CURRENT_BINARY_DIR}/opt_c_interface.o" true
            DEPENDS API/src/ad.t API/src/asdl.t API/src/createwrapper.t API/src/im.t
                    API/src/lib.t API/src/o.t API/src/precision.t API/src/solverGPUGaussNewton.t
                    API/src/util.t API/src/version.t API/src/windowsErrorContextWrapper.t
                    API/release/include/Opt.h
    WORKING_DIRECTORY "${CMAKE_SOURCE_DIR}")
add_custom_target(OptCInterface ALL DEPENDS opt_c_interface.o)

install(FILES "${CMAKE_CURRENT_BINARY_DIR}/opt_c_interface.o" DESTINATION lib)
