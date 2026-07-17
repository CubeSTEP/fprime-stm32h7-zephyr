zephyr_library()

zephyr_library_sources_ifdef(
    CONFIG_FPRIME_STM32H7_RAMECC
    ../ramecc/src/ramecc.c
    ../ramecc/src/mem_scrubber.c
)

zephyr_library_include_directories(
    ../ramecc/include
)