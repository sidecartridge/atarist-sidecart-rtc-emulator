; SidecarTridge Multidevice Real Time Clock (RTC) Emulator
; (C) 2023-24 by Diego Parrilla
; License: GPL v3

; Emulate a Real Time Clock from the SidecarT

; Bootstrap the code in ASM

    XDEF   rom_function

    ifne _DEBUG
    XREF    nf_has_flag
    XREF    nf_stderr_crlf
    XREF    nf_stderr_id
    XREF    nf_hexnum_buff
    XREF    nf_debugger_id
    endif

; CONSTANTS
RANDOM_SEED             equ $1284FBCD  ; Random seed for the random number generator. Should be provided by the pico in the future
QUERY_NTP_WAIT_TIME     equ 60         ; Number of seconds (aprox) to wait for a ping response from the Sidecart. Power of 2 numbers. Max 127.

ROM4_START_ADDR         equ $FA0000 ; ROM4 start address
ROM3_START_ADDR         equ $FB0000 ; ROM3 start address
ROM_EXCHG_BUFFER_ADDR   equ (ROM3_START_ADDR)               ; ROM4 buffer address
RANDOM_TOKEN_POST_WAIT: equ $1        ; Wait this cycles after the random number generator is ready

RANDOM_TOKEN_ADDR:        equ (ROM_EXCHG_BUFFER_ADDR)
RANDOM_TOKEN_SEED_ADDR:   equ (RANDOM_TOKEN_ADDR + 4) ; RANDOM_TOKEN_ADDR + 0 bytes

CMD_MAGIC_NUMBER        equ (ROM3_START_ADDR + $ABCD)       ; Magic number to identify a command
APP_RTCEMUL             equ $0300                           ; MSB is the app code. RTC is $03
CMD_TEST_NTP            equ ($0 + APP_RTCEMUL)              ; Command code to ping to the Sidecart
CMD_READ_DATETME        equ ($1 + APP_RTCEMUL)              ; Command code to read the date and time from the Sidecart
CMD_SAVE_VECTORS        equ ($2 + APP_RTCEMUL)              ; Command code to save the vectors in the Sidecart
CMD_REENTRY_LOCK        equ ($3 + APP_RTCEMUL)              ; Command code to lock the reentry to XBIOS in the Sidecart
CMD_REENTRY_UNLOCK      equ ($4 + APP_RTCEMUL)              ; Command code to unlock the reentry to XBIOS in the Sidecart
CMD_SET_SHARED_VAR      equ ($5 + APP_RTCEMUL)              ; Command code to set a shared variable in the Sidecart
RTCEMUL_NTP_SUCCESS     equ (ROM_EXCHG_BUFFER_ADDR + 8)    ; Magic number to identify a successful NTP query
RTCEMUL_DATETIME_BCD    equ (RTCEMUL_NTP_SUCCESS + 4)      ; ntp_success + 4 bytes
RTCEMUL_DATETIME_MSDOS  equ (RTCEMUL_DATETIME_BCD + 8)     ; datetime_bcd + 8 bytes
RTCEMUL_OLD_XBIOS       equ (RTCEMUL_DATETIME_MSDOS + 8)   ; datetime_msdos + 8 bytes
RTCEMUL_REENTRY_TRAP    equ (RTCEMUL_OLD_XBIOS + 4)        ; old_bios + 4 bytes
RTCEMUL_Y2K_PATCH       equ (RTCEMUL_REENTRY_TRAP + 4)     ; reentry_trap + 4 byte
RTCEMUL_SHARED_VARIABLES equ (RTCEMUL_Y2K_PATCH + 8)       ; y2k_patch + 8 bytes

_dskbufp                equ $4c6                            ; Address of the disk buffer pointer    
XBIOS_TRAP_ADDR         equ $b8                             ; TRAP #14 Handler (XBIOS)
_longframe      equ $59e    ; Address of the long frame flag. If this value is 0 then the processor uses short stack frames, otherwise it uses long stack frames.

    ifne _DEBUG
        include inc/tos.s
        include inc/debug.s
    endif

    ifne _RELEASE
        org $FA0040
        include inc/tos.s
    endif

    include inc/sidecart_macros.s

; Send a synchronous command to the Sidecart setting the reentry flag for the next XBIOS calls
; inside our trapped XBIOS calls. Should be always paired with reentry_xbios_unlock
reentry_xbios_lock	macro
                    movem.l d0-d7/a0-a6,-(sp)            ; Save all registers
                    send_sync CMD_REENTRY_LOCK,0         ; Command code to lock the reentry
                    movem.l (sp)+,d0-d7/a0-a6            ; Restore all registers
                	endm

; Send a synchronous command to the Sidecart clearing the reentry flag for the next XBIOS calls
; inside our trapped XBIOS calls. Should be always paired with reentry_xbios_lock
reentry_xbios_unlock  macro
                    movem.l d0-d7/a0-a6,-(sp)            ; Save all registers
                    send_sync CMD_REENTRY_UNLOCK,0       ; Command code to unlock the reentry
                    movem.l (sp)+,d0-d7/a0-a6            ; Restore all registers
                	endm

rom_function:
    print rtc_emulator_msg

    bsr get_tos_version
    bsr detect_hw

; Wait for the NTP in the RP2040 to be ready;
    print query_ntp_msg
    bsr test_ntp
    tst.w d0
    bne _exit_timemout

; NTP ready, now we can safely set the date and time
_ntp_ready:
    send_sync CMD_READ_DATETME,0         ; Command code to read the date and time
    tst.w d0                            ; 0 if no error
    bne _exit_timemout                   ; The RP2040 is not responding, timeout now

_show_tos_version:
    bsr print_tos_version

_set_vectors:

    tst.l RTCEMUL_Y2K_PATCH
    beq.s _set_vectors_ignore

; We don't need to fix Y2K problem in EmuTOS
; Save the old XBIOS vector in RTCEMUL_OLD_XBIOS and set our own vector
    print set_vectors_msg
    bsr save_vectors
    tst.w d0
    bne _exit_timemout

_set_vectors_ignore:
    pea RTCEMUL_DATETIME_BCD            ; Buffer should have a valid IKBD date and time format
    move.w #6, -(sp)                    ; Six bytes plus the header = 7 bytes
    move.w #25, -(sp)                   ; 
    trap #14
    addq.l #8, sp

    print set_datetime_msg


    move.l RTCEMUL_DATETIME_MSDOS, d0
    bsr set_datetime
    tst.w d0
    bne _exit_timemout

	move.w #23,-(sp)                    ; gettime from XBIOS
	trap #14
	addq.l #2,sp

    tst.l RTCEMUL_Y2K_PATCH
    beq.s _ignore_y2k
    add.l #$3c000000,d0                 ; +30 years to guarantee the Y2K problem works in all TOS versions
_ignore_y2k:

    move.l d0, -(sp)                    ; Save the date and time in MSDOS format
    move.w #22,-(sp)                    ; settime with XBIOS
    trap #14
    addq.l #6, sp

    print ready_datetime_msg

    rts

_exit_timemout:
    asksil error_sidecart_comm_msg
    rts



; Ask the RPP2040 is the NTP is working and has a valid date and time
test_ntp:
    move.w #QUERY_NTP_WAIT_TIME, d7      ; Wait for a while until ping responds
_retest_ntp:
    move.w d7, -(sp)                 
    send_sync CMD_TEST_NTP,0            ; Command code to test the NTP
    move.w (sp)+, d7

    cmp.w #$FFFF, RTCEMUL_NTP_SUCCESS
    bne.s _ntp_not_yet                ; The NTP has a valid date, exit
_exit_test_ntp:
    moveq #0, d0
    rts


_ntp_not_yet:

    move.w d7,d0                        ; Pass the number of seconds to print
    print_num                           ; Print the decimal number

    print backwards

    move.w #50, d6                      ; Loop to wait a second (aprox 50 VBlanks)
_ntp_not_yet_loop:
    move.w 	#37,-(sp)                   ; Wait for the VBlank. Add a delay
    trap 	#14
    addq.l 	#2,sp
    dbf d6, _ntp_not_yet_loop

    dbf d7, _retest_ntp                 ; The NTP does not have a valid date, wait a bit more

_test_ntp_timeout:
    moveq #-1, d0
    rts

save_vectors:
    move.l XBIOS_TRAP_ADDR.w,d3          ; Address of the old XBIOS vector
    send_sync CMD_SAVE_VECTORS,4         ; Send the command to the Sidecart
    tst.w d0                            ; 0 if no error
    bne.s _read_timeout                 ; The RP2040 is not responding, timeout now

    ; Now we have the XBIOS vector in RTCEMUL_OLD_XBIOS
    ; Now we can safely change it to our own vector
    move.l #custom_xbios,XBIOS_TRAP_ADDR.w    ; Set our own vector

    rts

_read_timeout:
    moveq #-1, d0
    rts

custom_xbios:
    btst #0, RTCEMUL_REENTRY_TRAP      ; Check if the reentry is locked
    beq.s _custom_bios_trapped         ; If the bit is active, we are in a reentry call. We need to exec_old_handler the code

    move.l RTCEMUL_OLD_XBIOS, -(sp) ; if not, continue with XBIOS call
    rts 

_custom_bios_trapped:
    btst #5, (sp)                    ; Check if called from user mode
    beq.s _user_mode                 ; if so, do correct stack pointer
_not_user_mode:
    move.l sp,a0                     ; Move stack pointer to a0
    bra.s _check_cpu
_user_mode:
    move.l usp,a0                    ; if user mode, correct stack pointer
    subq.l #6,a0
;
; This code checks if the CPU is a 68000 or not
;
_check_cpu:
    tst.w _longframe                ; Check if the CPU is a 68000 or not
    beq.s _notlong
_long:
    addq.w #2, a0                   ; Correct the stack pointer parameters for long frames 
_notlong:
    cmp.w #23,6(a0)                 ; is it XBIOS call 23 / getdatetime?
    beq.s _getdatetime              ; if yes, go to our own routine
    cmp.w #22,6(a0)                 ; is it XBIOS call 22 / setdatetime?
    beq.s _setdatetime              ; if yes, go to our own routine

_continue_xbios:
    move.l RTCEMUL_OLD_XBIOS, -(sp) ; if not, continue with XBIOS call
    rts 

; Adjust the time when reading to compensate for the Y2K problem
; We should not tap this call for EmuTOS
_getdatetime:
    reentry_xbios_lock
	move.w #23,-(sp)
	trap #14
	addq.l #2,sp
	add.l #$3c000000,d0 ; +30 years for all TOS except EmuTOS
    reentry_xbios_unlock
	rte

; Adjust the time when setting to compensate for the Y2K problem
; We should not tap this call for TOS 2.06 and EmuTOS
_setdatetime:
	sub.l #$3c000000,8(a0)
    bra.s _continue_xbios

; Get the date and time from the RP2040 and set the IKBD information
; d0.l : Date and time in MSDOS format
set_datetime:
    move.l d0, d7

    bsr print_hour
    pchar ':'
    move.l d7, d0
    bsr print_minute
    pchar ':'
    move.l d7, d0
    bsr print_seconds

    pchar ' '

    swap d7
    move.l d7, d0
    bsr print_day
    pchar '/'
    move.l d7, d0
    bsr print_month
    pchar '/'
    move.l d7, d0
    bsr print_year

    swap d7

	move.w d7,-(sp)
	move.w #$2d,-(sp)                   ; settime with GEMDOS
	trap #1
	addq.l #4,sp
    tst.w d0
    bne.s _exit_set_time

	swap d7

	move.w d7,-(sp)
	move.w #$2b,-(sp)                   ; settime with GEMDOS  
	trap #1
	addq.l #4,sp
    tst.w d0
    bne.s _exit_set_time

    ; And we are done!
    moveq #0, d0
    rts
_exit_set_time:
    moveq #-1, d0
    rts

print_seconds:
    and.l #%11111,d0
    print_num
    rts

print_minute:
    lsr.l #5, d0
    and.l #%111111,d0
    print_num
    rts

print_hour:
    lsr.l #8, d0
    lsr.l #3, d0
    and.l #%11111,d0
    print_num
    rts

print_day:
    and.l #%11111,d0
    print_num
    rts

print_month:
    lsr.l #5, d0
    and.l #%1111,d0
    print_num
    rts

print_year:
    lsr.l #8, d0
    lsr.l #1, d0
    and.l #%1111111,d0
    sub.l #20, d0 ; Year - 1980
    print_num
    rts

; Print the obtained TOS version
print_tos_version:
    print set_version_msg   ; Print the TOS version message

    move.l (RTCEMUL_SHARED_VARIABLES + (SHARED_VARIABLE_SVERSION * 4)), d0   ; Get the TOS version from the shared variables
    swap d0
    and.l #$FFFF,d0
    move.w d0, d1
    lsr.w #8, d1    ; Major version

    move.w d0, d2
    and.w #$FF, d2  ; Minor version

    add.w #48, d1
    move.w d1, d0
    pchar_reg

    pchar '.'

;    move.w d2, d0
;    print_num
    move.w d2, d0
    swap d0
    lsl.l #8, d0
    moveq #1, d1    ; Number of digits to print minus 1 
    print_hex

    pchar '.'
    pchar '.'
    pchar '.'

    rts

    include "inc/sidecart_functions.s"


        even
rtc_emulator_msg:
        dc.b	"SidecarTridge Multi-device",$d,$A
        dc.b    "Real Time Clock - "
        
version:
        dc.b    "v"
        dc.b    VERSION_MAJOR
        dc.b    "."
        dc.b    VERSION_MINOR
        dc.b    "."
        dc.b    VERSION_PATCH
        dc.b    $d,$a

spacing:
        dc.b    "+" ,$d,$a,0

set_vectors_msg:
        dc.b	$d,$a,"+- Set vectors...",0

query_ntp_msg:
        dc.b	"+- Querying a NTP server...",0

set_datetime_msg:
        dc.b	$d,$a,"+- Date and time: ",0

set_version_msg:
        dc.b	$d,$a,"+- TOS version: ",0

ready_datetime_msg:
        dc.b	$d,$a,"+- Date and time set.",0

error_sidecart_comm_msg:
        dc.b	$d,$a,"Communication error. Press reset.",$d,$a,0

backwards:
        dc.b    $8, $8,0

        even
ikbddate_test:
        dc.b $1b,$23,$11,$09,$15,$55,$30,0

        even
rom_function_end: