# Allow config to be included regardless of platform
add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/fprime-stm32h7-zephyr/config")

# For any reusable Cerberus/stm32h7 components
# add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/fprime-stm32h7-zephyr/Os")
# add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/fprime-stm32h7-zephyr/Svc")