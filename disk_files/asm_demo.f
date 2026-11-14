( f64OS x64 Assembler Demo & Test Suite - asm_demo.f                    )
( Usage:                                                                )
(   INCLUDE asm.f                                                       )
(   INCLUDE asm_demo.f                                                  )

DECIMAL

( 1. Inline Native Function: Iterative 64-bit Fibonacci                 )
(    Demonstrates NATIVE: ... ;NATIVE and structured BEGIN,/WHILE,/REPEAT, )

NATIVE: NATIVE-FIB ( n -- fib[n] )
    RAX RAX XOR.             ( rax = a = 0 )
    RDX 1 MOVI               ( rdx = b = 1 )
    BEGIN,
        RDI RDI TEST         ( while n > 0 )
    G= WHILE,
        RCX RAX MOV          ( rcx = a )
        RAX RDX MOV          ( a = b )
        RDX RCX ADD          ( b = a + b )
        RDI DEC              ( n-- )
    REPEAT,
    RET
;NATIVE

( 2. Inline Native Function: Collatz Hailstone Steps                    )
(    Demonstrates local labels L:, JLE, JMP, IF,/ELSE,/THEN,, and IMULI )

NATIVE: NATIVE-COLLATZ ( n -- steps )
    RAX RAX XOR.             ( rax = steps = 0 )
    0 L:
    RDI 1 CMPI
    1 JLE                    ( if n <= 1, jump to label 1 )
    RCX RDI MOV
    RCX 1 ANDI
    NZ= IF,
        RDI RDI 3 IMULI      ( n = 3 * n + 1 )
        RDI INC
    ELSE,
        RDI 1 SHRI           ( n = n >> 1 )
    THEN,
    RAX INC
    0 JMP
    1 L:
    RET
;NATIVE

( 3. Addressing Modes, Shifts, Division, CMOVcc, and Local CALL Test    )
(    Verifies RSP/R12 SIB base, RBP/R13 disp8, LDSB, SHLI, SARI, IDIV   )

NATIVE: NATIVE-OPS-TEST ( x -- res )
    RBX PUSH
    R12 PUSH
    R13 PUSH
    RBP PUSH
    RBP RSP MOV
    RSP 32 SUBI

    R12 RSP MOV
    R13 RBP MOV
    RSP 0 RDI STQ            ( [rsp] = x )
    RAX R12 0 LDQ            ( rax = [r12] = x )
    RBP 0 RAX STQ            ( [rbp+0] = x, tests RBP disp=0 )
    RBX R13 0 LDQ            ( rbx = [r13+0] = x, tests R13 disp=0 )

    RSP 8 -5 STBI            ( byte [rsp+8] = -5 )
    RCX RSP 8 LDSB           ( sign-extend byte [rsp+8] -> rcx = -5 )
    RAX RCX ADD              ( rax = x - 5 )

    RAX 2 SHLI               ( rax = (x - 5) * 4 )
    RAX 1 SARI               ( rax = (x - 5) * 2 )
    RCX 3 MOVI
    CQO
    RCX IDIV                 ( rax = ((x - 5) * 2) / 3 )

    R8 100 MOVI
    R9 200 MOVI
    RAX 5 CMPI
    R8 R9 CMOVG              ( if rax > 5, r8 = 200 else 100 )
    RAX R8 ADD

    5 CALL                   ( call local subroutine at label 5 )
    0 JMP

    5 L:
    RAX 7 ADDI
    RET

    0 L:
    RSP RBP MOV
    RBP POP
    R13 POP
    R12 POP
    RBX POP
    RET
;NATIVE

( 4. Standalone Binary: Assemble, Save to Disk, Load & CALL-NATIVE      )
(    Mirrors DOOM's boot-block + binary loader + CALL-NATIVE workflow.  )
(                                                                       )
(    Boot block layout passed in RDI/RCX (4 cells):                     )
(      +0   KSERVICES address                                           )
(      +8   Pointer to 64-bit integer array                             )
(      +16  Number of elements in array                                 )
(      +24  Output slot: filled with PIT ticks read via KSERVICES       )

4 CELLS ALLOT CONSTANT DEMO-BOOT
5 CELLS ALLOT CONSTANT DEMO-ARR

10 DEMO-ARR 0 CELLS + !
20 DEMO-ARR 1 CELLS + !
30 DEMO-ARR 2 CELLS + !
40 DEMO-ARR 3 CELLS + !
50 DEMO-ARR 4 CELLS + !

: BUILD-DEMO-BIN ( -- )
    ASM-BEGIN
        ( rdi = pointer to DEMO-BOOT )
        RBX PUSH

        ( Read KSERVICES from [rdi + 0], then ticks ptr from [ksvc + 8] )
        RAX RDI 0 LDQ            ( rax = KSERVICES )
        RAX RAX 8 LDQ            ( rax = &systimer_ticks )
        RAX RAX 0 LDQ            ( rax = current ticks )
        RDI 24 RAX STQ           ( store ticks into [rdi + 24] )

        ( Sum the array using SIB indexed addressing [rbx + rcx*8 + 0] )
        RBX RDI 8 LDQ            ( rbx = array base pointer )
        RDX RDI 16 LDQ           ( rdx = element count )
        RAX RAX XOR.             ( rax = sum = 0 )
        RCX RCX XOR.             ( rcx = index = 0 )

        0 L:
        RCX RDX CMP
        1 JGE                    ( if index >= count, jump to label 1 )
        R8 RBX RCX 8 0 LDQ-X     ( r8 = [rbx + rcx*8 + 0] )
        RAX R8 ADD               ( sum += r8 )
        RCX INC                  ( index++ )
        0 JMP

        1 L:
        ( Also add a constant from an RIP-relative embedded table at label 2 )
        RSI 2 LEA-LBL            ( rsi = RIP-relative address of label 2 )
        R8 RSI 0 LDQ             ( r8 = [rsi] = 1000 )
        RAX R8 ADD               ( sum += 1000 )

        RBX POP
        RET

        8 ALIGN,
        2 L:
        1000 DQ,
    ASM-END

    ." Assembled demo.bin (" ASM-SIZE . ." bytes):" CR
    ASM-DUMP
    ASM-SAVE demo.bin
    ." Saved demo.bin to filesystem." CR
;

: RUN-DEMO ( -- )
    ." [1] NATIVE-FIB(10)=" 10 NATIVE-FIB .
    ." FIB(83)=" 83 NATIVE-FIB . CR
    ." [2] NATIVE-COLLATZ(27)=" 27 NATIVE-COLLATZ . ." (expect 111)" CR
    ." [3] NATIVE-OPS-TEST(20)=" 20 NATIVE-OPS-TEST . ." (expect 217)" CR

    ." [4] Building & Saving demo.bin:" CR
    BUILD-DEMO-BIN

    ." [5] Loading demo.bin to NATIVE-BASE & calling CALL-NATIVE:" CR
    KSERVICES DEMO-BOOT 0 CELLS + !
    DEMO-ARR  DEMO-BOOT 1 CELLS + !
    5         DEMO-BOOT 2 CELLS + !
    0         DEMO-BOOT 3 CELLS + !

    NATIVE-BASE LOAD-BIN demo.bin
    ." Loaded " . ." bytes to NATIVE-BASE." CR

    DEMO-BOOT NATIVE-BASE NATIVE-STACK CALL-NATIVE
    ." CALL-NATIVE result = " . ." (expect 1150)" CR
    ." Kernel ticks read by native code = " DEMO-BOOT 3 CELLS + @ . CR
;

RUN-DEMO
