# fprime-stm32h7-zephyr
This repository houses reusable STM32H7 board support for F Prime on Zephyr.

## Zephyr module
This repository is packaged as a Zephyr module. Add it to an application before `find_package(Zephyr ...)` with:

```cmake
list(APPEND EXTRA_ZEPHYR_MODULES "${CMAKE_CURRENT_SOURCE_DIR}/lib/fprime-stm32h7-zephyr")
```

The module metadata in `zephyr/module.yml` exposes `board_root: .`, so boards under `boards/<vendor>/<board>` are discovered by Zephyr without copying board files into the workspace.

## Resources
https://github.com/fprime-community/fprime-vxworks/tree/upgrade-to-fprime4
