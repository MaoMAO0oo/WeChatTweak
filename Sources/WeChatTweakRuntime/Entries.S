#if defined(__arm64__)
.text
.p2align 2

.macro WT_SAVE
    sub sp, sp, #0x120
    .cfi_adjust_cfa_offset 0x120
    stp x0, x1, [sp, #0x00]
    stp x2, x3, [sp, #0x10]
    stp x4, x5, [sp, #0x20]
    stp x6, x7, [sp, #0x30]
    stp x8, x9, [sp, #0x40]
    stp x10, x11, [sp, #0x50]
    stp x12, x13, [sp, #0x60]
    stp x14, x15, [sp, #0x70]
    stp x16, x17, [sp, #0x80]
    stp x29, x30, [sp, #0x90]
    stp q0, q1, [sp, #0xa0]
    stp q2, q3, [sp, #0xc0]
    stp q4, q5, [sp, #0xe0]
    stp q6, q7, [sp, #0x100]
.endm

.macro WT_RESTORE
    ldp q0, q1, [sp, #0xa0]
    ldp q2, q3, [sp, #0xc0]
    ldp q4, q5, [sp, #0xe0]
    ldp q6, q7, [sp, #0x100]
    ldp x0, x1, [sp, #0x00]
    ldp x2, x3, [sp, #0x10]
    ldp x4, x5, [sp, #0x20]
    ldp x6, x7, [sp, #0x30]
    ldp x8, x9, [sp, #0x40]
    ldp x10, x11, [sp, #0x50]
    ldp x12, x13, [sp, #0x60]
    ldp x14, x15, [sp, #0x70]
    ldp x16, x17, [sp, #0x80]
    ldp x29, x30, [sp, #0x90]
    add sp, sp, #0x120
    .cfi_adjust_cfa_offset -0x120
.endm

.globl _WTReplaceEntry
_WTReplaceEntry:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_same_value 30
    WT_SAVE
    .cfi_offset 30, -136
    mov x2, x8
    bl _WTHandleRecall
    .cfi_remember_state
    cbnz w0, 1f
    WT_RESTORE
    .cfi_same_value 30
    adrp x16, _WTOriginalReplace@PAGE
    ldr x16, [x16, _WTOriginalReplace@PAGEOFF]
    br x16
1:
    .cfi_restore_state
    WT_RESTORE
    .cfi_same_value 30
    ret
    .cfi_endproc

.globl _WTBindEntry
_WTBindEntry:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_same_value 30
    stp x19, x30, [sp, #-0x10]!
    .cfi_adjust_cfa_offset 16
    .cfi_offset 19, -16
    .cfi_offset 30, -8
    mov x19, x0
    adrp x16, _WTOriginalBind@PAGE
    ldr x16, [x16, _WTOriginalBind@PAGEOFF]
    blr x16
    WT_SAVE
    mov x0, x19
    bl _WTDidBindView
    WT_RESTORE
    ldp x19, x30, [sp], #0x10
    .cfi_adjust_cfa_offset -16
    .cfi_same_value 19
    .cfi_same_value 30
    ret
    .cfi_endproc

.globl _WTDestroyEntry
_WTDestroyEntry:
    .cfi_startproc
    .cfi_def_cfa sp, 0
    .cfi_same_value 30
    WT_SAVE
    .cfi_offset 30, -136
    bl _WTWillDestroyView
    WT_RESTORE
    .cfi_same_value 30
    adrp x16, _WTOriginalDestroy@PAGE
    ldr x16, [x16, _WTOriginalDestroy@PAGEOFF]
    br x16
    .cfi_endproc
#endif
