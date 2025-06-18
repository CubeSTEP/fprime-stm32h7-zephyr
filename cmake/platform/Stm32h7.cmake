####
# Stm32h7.cmake:
#
# Stm32h7 platform file for standard stm32h7 targets.
####

set(FPRIME_HAS_SOCKETS ON)
add_fprime_subdirectory("${CMAKE_CURRENT_LIST_DIR}/types/Platform")

register_fprime_config(
        PlatformStm32h7
   INTERFACE # No buildable files generated
   CHOOSES_IMPLEMENTATIONS
        Os_Console_Zephyr
        Os_Mutex_Zephyr
        # Os_File_Zephyr
        Os_Task_Zephyr
        # Fw_StringFormat_snprintf
        # No Zephyr or STM32H7 Implementation
        Os_Cpu_Stub
        Os_File_Stub
        Os_Memory_Stub
        Os_Queue_Stub
        Os_RawTime_Stub
)
target_compile_definitions(PlatformStm32h7 INTERFACE -DTGT_OS_TYPE_STM32H7)