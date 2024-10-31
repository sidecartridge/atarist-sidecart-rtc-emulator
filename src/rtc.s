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
RANDOM_TOKEN_ADDR:        equ (ROM_EXCHG_BUFFER_ADDR)
RANDOM_TOKEN_SEED_ADDR:   equ (RANDOM_TOKEN_ADDR + 4) ; RANDOM_TOKEN_ADDR + 0 bytes

CMD_MAGIC_NUMBER        equ (ROM3_START_ADDR + $ABCD)       ; Magic number to identify a command
APP_RTCEMUL             equ $0300                           ; MSB is the app code. RTC is $03
CMD_TEST_NTP            equ ($0 + APP_RTCEMUL)              ; Command code to ping to the Sidecart
CMD_READ_DATETME        equ ($1 + APP_RTCEMUL)              ; Command code to read the date and time from the Sidecart
CMD_SAVE_VECTORS        equ ($2 + APP_RTCEMUL)              ; Command code to save the vectors in the Sidecart
RTCEMUL_NTP_SUCCESS     equ (ROM_EXCHG_BUFFER_ADDR + $8)         ; Magic number to identify a successful NTP query
RTCEMUL_DATETIME        equ (RTCEMUL_NTP_SUCCESS + $2)      ; ntp_success + 2 bytes
RTCEMUL_OLD_XBIOS       equ (RTCEMUL_DATETIME + $4)         ; ntp_success + 4 bytes

XBIOS_TRAP_ADDR         equ $b8                             ; TRAP #14 Handler (XBIOS)

    ifne _DEBUG
        include inc/tos.s
        include inc/debug.s
    endif

    ifne _RELEASE
        org $FA0040
        include inc/tos.s
    endif
rom_function:
    print rtc_emulator_msg
;    move.w sr, -(sp)                    ; Save the status register
;    move.w #$2700, sr                  ; Disable interrupts

; Wait for the NTP in the RP2040 to be ready;
    print query_ntp_msg
    bsr test_ntp
    tst.w d0
    bne.s _exit_timemout

; NTP ready, now we can safely set the date and time
_ntp_ready:
    print set_datetime_msg

    bsr set_datetime
    tst.w d0
    bne.s _exit_timemout

;    move.w (sp)+, sr                    ; Restore the status register
    print ready_datetime_msg

    rts

; DISABLED FOR NOW. NEED TO FIX THE CODE
; Save the old XBIOS vector in RTCEMUL_OLD_XBIOS and set our own vector
;    print set_vectors_msg
;    bsr save_vectors
;    tst.w d0
;    bne _exit_timemout
;    rts

_exit_timemout:
;    move.w (sp)+, sr                    ; Restore the status register
    asksil error_sidecart_comm_msg
    rts



; Ask the RPP2040 is the NTP is working and has a valid date and time
test_ntp:
    move.w #QUERY_NTP_WAIT_TIME, d7           ; Wait for a while until ping responds
_retest_ntp:
    move.w d7, -(sp)                 
    move.w #CMD_TEST_NTP,d0              ; Command code to test the NTP
    move.w #0,d1                         ; Payload size is 0 bytes. No payload

    bsr send_sync_command_to_sidecart

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
    move.w #CMD_SAVE_VECTORS,d0          ; Command code to save the vectors
    move.w #4,d1                         ; Payload size is 0 bytes. No payload
    move.l XBIOS_TRAP_ADDR.w,d3            ; Address of the old XBIOS vector

    bsr send_sync_command_to_sidecart
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
    move.l sp,a0
; On non68000 CPU we need to compensate for long stackframe
	tst.w $59e
	beq.s _non68000
	addq.w #2,a1
_non68000:
    btst #5,(sp)                    ; check if called from user mode
    bne.s _not_user                 ; if not, do not correct stack pointer
    move.l usp,a0                   ; if yes, correct stack pointer
    subq.l #6,a0                    ; correct stack pointer
_not_user:
    move.w 6(a0),d0                 ; get XBIOS call number
    cmp.w #23,d0                    ; is it XBIOS call 23 / getdatetime?
    beq.s _getdatetime              ; if yes, go to our own routine
    cmp.w #22,d0                    ; is it XBIOS call 22 / setdatetime?
    beq.s _setdatetime              ; if yes, go to our own routine

_continue_xbios:
    move.l RTCEMUL_OLD_XBIOS,a0        ; get old XBIOS vector
    jmp (a0)

; Adjust the time when reading to compensate for the Y2K problem
_getdatetime:
	move.w #23,-(sp)
	trap #14
	addq.l #2,sp
	add.l #$3c000000,d0
	rte

; Adjust the time when setting to compensate for the Y2K problem
_setdatetime:
	move.l 2(a0),d0
	sub.l #$3c000000,d0
	move.l d0,-(sp)
	move.w #22,-(sp)
	trap #14
	addq.l #6,sp
    rte

; Get the date and time from the RP2040 and set the IKBD information
set_datetime:
    move.w #CMD_READ_DATETME,d0          ; Command code READ DATETIME
    move.w #0,d1                         ; Payload size is 0 bytes. No payload

    bsr send_sync_command_to_sidecart
    tst.w d0                            ; 0 if no error
    bne _read_timeout                 ; The RP2040 is not responding, timeout now

    ; The date and time comes in the buffer

    pea RTCEMUL_DATETIME                ; Buffer should have a valid IKBD date and time format
    move.w #6, -(sp)                    ; Six bytes plus the header = 7 bytes
    move.w #25, -(sp)                   ; 
    trap #14
    addq.l #8, sp

    moveq #0, d0

	move.w #23,-(sp)                    ; gettime from XBIOS
	trap #14
	addq.l #2,sp

    add.l #$3c000000,d0                 ; Fix the Y2K problem

	move.l d0,d7

	move.w d7,-(sp)
	move.w #$2d,-(sp)                   ; settime with GEMDOS
	trap #1
	addq.l #4,sp

	swap d7

	move.w d7,-(sp)
	move.w #$2b,-(sp)                   ; settime with GEMDOS  
	trap #1
	addq.l #4,sp

    ; And we are done!
    moveq #0, d0
    rts

print_hex:
    movem.l d0-d7, -(sp)     ; Push all registers
    move.l  d0, d6           ; Copy D0 to D6 for manipulation
    rol.l #8, d6             ; Shift right by 8 bits to get the next byte
    moveq   #7, d1           ; Counter for 8 nibbles (32 bits / 4 bits per nibble)

print_next_nibble:
    move.l  d6, d3           ; Copy D2 to D3 to extract the nibble
    btst    #0, d1           ;
    beq.s   print_low_nibble ; If the counter is even, print the low nibble
print_high_nibble:
    lsr.l   #4, d3           ; Shift right by 4 bits to get the high nibble
    bra.s print_nibble
print_low_nibble:
    rol.l #8, d6             ; Shift right by 8 bits to get the next byte
print_nibble:
    andi.l  #$0F, d3         ; Mask off all but the lower nibble
    cmpi.l  #$0A, d3         ; Compare with 10 to determine if it's A-F
    blt.s   digit            ; If less than 10, it's a digit
    addi.l  #$37, d3         ; Convert to ASCII ('A' - 'F')
    bra.s   print_char
digit:
    addi.l  #$30, d3        ; Convert to ASCII ('0' - '9')
print_char:
    move.w  d3, -(sp)        ; Push the character to print
    move.w  #2, -(sp)		; Push 2 bytes to print
    trap    #1               ; Print char
    addq.l  #4, sp           ; Rewind stack

    dbra    d1, print_next_nibble  ; Decrement d1 and branch if not yet zero

    movem.l  (sp)+, d0-d7     ; Pop all registers

    rts                       ; Return from subroutine

; Send an async command to the Sidecart
; Fire and forget style
; Input registers:
; d0.w: command code
; d1.w: payload size
; From d2 to d7 the payload based on the size of the payload field d1.w
; The order is: d2.l d2.h d3.l d3.h d4.l d4.h d5.l d5.h d6.l d6.h d7.l d7.h
; the limit is not 12 words, but since this code is going to be executed in the
; Atari ST ROM, its difficult to not use a buffer in RAM
; Output registers:
; d1-d7 are modified. a0-a3 modified.
send_async_command_to_sidecart:
    move.l #_end_async_code_in_stack - _start_async_code_in_stack, d7
    lea -(_end_async_code_in_stack - _start_async_code_in_stack)(sp), sp
    move.l sp, a2
    lea _start_async_code_in_stack, a1    ; a1 points to the start of the code in ROM
    lsr.w #2, d7
    subq #1, d7
_copy_async_code:
    move.l (a1)+, (a2)+
    dbf d7, _copy_async_code
    jsr (a3)                                                            ; Jump to the code in the stack
    lea (_end_async_code_in_stack - _start_async_code_in_stack)(sp), sp
    rts

; Send an sync command to the Sidecart
; Wait until the command sets a response in the memory with a random number used as a token
; Input registers:
; d0.w: command code
; d1.w: payload size
; From d3 to d7 the payload based on the size of the payload field d1.w
; Output registers:
; d0: error code, 0 if no error
; d1-d7 are modified. a0-a3 modified.
send_sync_command_to_sidecart:
    move.l #_end_sync_code_in_stack - _start_sync_code_in_stack, d7
    lea -(_end_sync_code_in_stack - _start_sync_code_in_stack)(sp), sp
    move.l sp, a2
    move.l sp, a3
    lea _start_sync_code_in_stack, a1    ; a1 points to the start of the code in ROM
    lsr.w #2, d7
    subq #1, d7
_copy_sync_code:
    move.l (a1)+, (a2)+
    dbf d7, _copy_sync_code
    move.w #$4e71, (_no_async_return - _start_sync_code_in_stack)(a3)   ; Put a NOP when sync
    jsr (a3)                                                            ; Jump to the code in the stack
    lea (_end_sync_code_in_stack - _start_sync_code_in_stack)(sp), sp
    rts

_start_sync_code_in_stack:
    ; The sync command synchronize with a random token
    move.l RANDOM_TOKEN_SEED_ADDR,d2
    mulu  #221,d2
    add.b #53, d2                       ; Save the random number in d2
    addq.w #4, d1                       ; Add 4 bytes to the payload size to include the token

_start_async_code_in_stack:
    move.l #ROM3_START_ADDR, a0 ; Start address of the ROM3

    ; SEND HEADER WITH MAGIC NUMBER
    swap d0                     ; Save the command code in the high word of d0         
    move.b CMD_MAGIC_NUMBER, d0; Command header. d0 is a scratch register

    ; SEND COMMAND CODE
    swap d0                     ; Recover the command code
    move.l a0, a1               ; Address of the ROM3
    add.w d0, a1                ; We can use add because the command code msb is 0 and there is no sign extension            
    move.b (a1), d0             ; Command code. d0 is a scratch register

    ; SEND PAYLOAD SIZE
    move.l a0, d0               ; Address of the ROM3 in d0    
    or.w d1, d0                 ; OR high and low words in d0
    move.l d0, a1               ; move to a1 ready to read from this address
    move.b (a1), d0             ; Command payload size. d0 is a scratch register
    tst.w d1
    beq _no_more_payload_stack        ; If the command does not have payload, we are done.

    ; SEND PAYLOAD
    move.l a0, d0
    or.w d2, d0
    move.l d0, a1
    move.b (a1), d0           ; Command payload low d2
    cmp.w #2, d1
    beq _no_more_payload_stack

    swap d2
    move.l a0, d0
    or.w d2, d0
    move.l d0, a1
    move.b (a1), d0           ; Command payload high d2
    cmp.w #4, d1
    beq _no_more_payload_stack

    move.l a0, d0
    or.w d3, d0
    move.l d0, a1
    move.b (a1), d0           ; Command payload low d3
    cmp.w #6, d1
    beq _no_more_payload_stack

    swap d3
    move.l a0, d0
    or.w d3, d0
    move.l d0, a1
    move.b (a1), d0           ; Command payload high d3
    cmp.w #8, d1
    beq _no_more_payload_stack

    move.l a0, d0
    or.w d4, d0
    move.l d0, a1
    move.b (a1), d0           ; Command payload low d4
    cmp.w #10, d1
    beq _no_more_payload_stack

    swap d4
    move.l a0, d0
    or.w d4, d0
    move.l d0, a1
    move.b (a1), d0           ; Command payload high d4
    cmp.w #12, d1
    beq.s _no_more_payload_stack

    move.l a0, d0
    or.w d5, d0
    move.l d0, a1
    move.b (a1), d0           ; Command payload low d5
    cmp.w #14, d1
    beq.s _no_more_payload_stack

    swap d5
    move.l a0, d0
    or.w d5, d0
    move.l d0, a1
    move.b (a1), d0           ; Command payload high d5
    cmp.w #16, d1
    beq.s _no_more_payload_stack

    move.l a0, d0
    or.w d6, d0
    move.l d0, a1
    move.b (a1), d0           ; Command payload low d6
    cmp.w #18, d1
    beq.s _no_more_payload_stack

    swap d6
    move.l a0, d0
    or.w d6, d0
    move.l d0, a1
    move.b (a1), d0           ; Command payload high d6

_no_more_payload_stack:
    swap d2                   ; D2 is the only register that is not used as a scratch register
_no_async_return:
    rts                 ; if the code is SYNC, we will NOP this
_end_async_code_in_stack:

    move.l #$FFFF000F, d7                   ; Most significant word is the inner loop, least significant word is the outer loop
_wait_sync_for_token_a_lot:
    swap d7
_wait_sync_for_token:
    cmp.l RANDOM_TOKEN_ADDR, d2              ; Compare the random number with the token
    beq.s _sync_token_found                  ; Token found, we can finish succesfully
    dbf d7, _wait_sync_for_token
    swap d7
    dbf d7, _wait_sync_for_token_a_lot
_sync_token_not_found:
    moveq #-1, d0                     ; Timeout
    rts
_sync_token_found:
    clr.w d0                            ; Clear the error code
    rts
    nop

_end_sync_code_in_stack:

    rts

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
        dc.b	"+- Set vectors...",$d,$a,0

query_ntp_msg:
        dc.b	"+- Querying a NTP server...",0

set_datetime_msg:
        dc.b	$d,$a,"+- Setting date and time.",$d,$a,0

ready_datetime_msg:
        dc.b	"+- Date and time set.",$d,$a,0

error_sidecart_comm_msg:
        dc.b	$d,$a,"Communication error. Press reset.",$d,$a,0

backwards:
        dc.b    $8, $8,0

        even
ikbddate_test:
        dc.b $1b,$23,$11,$09,$15,$55,$30,0

        even
rom_function_end: