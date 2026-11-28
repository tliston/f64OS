( f64OS x86-64 Assembler - asm.f                                        )
( Usage:  INCLUDE asm.f                                                 )
(                                                                       )
( Provides a 64-bit x86-64 postfix assembler for f64OS capable of       )
( assembling executable native code in memory or saving/loading flat    )
( binaries executed via CALL-NATIVE, just like DOOM.                    )

DECIMAL

HERE @ LATEST @
CONSTANT ASM-ORIG-LATEST
CONSTANT ASM-ORIG-HERE

( --- Bitwise Shift Helpers ------------------------------------------- )

: LSHIFT ( x n -- x<<n )
    DUP 0> IF 0 DO DUP + LOOP ELSE DROP THEN
;

: 1RSHIFT ( u -- u>>1 )
    DUP 0< IF
        1 63 LSHIFT INVERT AND
        2 /
        1 62 LSHIFT OR
    ELSE
        2 /
    THEN
;

: RSHIFT ( u n -- u>>n )
    DUP 0> IF 0 DO 1RSHIFT LOOP ELSE DROP THEN
;

( --- Assembler State & Buffers --------------------------------------- )

HEX
1000000 CONSTANT NATIVE-BASE
DECIMAL

16384 ALLOT 16384 + CONSTANT NATIVE-STACK

0 VALUE ASM-CUSTOM-ORG
0 VALUE ASM-ENTRY
0 VALUE ASM-PC
0 VALUE ASM-SIZE
0 VALUE ASM-AT-HERE

VARIABLE ASM-TMP

( Local label table: 64 labels, 0..63 )
64 CELLS ALLOT CONSTANT ASM-LBLS

( Forward-reference fixup table: up to 128 entries )
128 CELLS ALLOT CONSTANT ASM-FIX-ADDR
128 CELLS ALLOT CONSTANT ASM-FIX-LBL
0 VALUE ASM-FIX-CNT

: ASM-AT ( addr -- ) TO ASM-CUSTOM-ORG ;

( --- Code Emission Primitives ---------------------------------------- )

: B, ( b -- ) ASM-PC C!  1 +TO ASM-PC ;
: W, ( w -- ) ASM-TMP !  ASM-TMP C@ B,  ASM-TMP 1+ C@ B, ;
: D, ( d -- ) ASM-TMP !  ASM-TMP ASM-PC 4 CMOVE  4 +TO ASM-PC ;
: Q, ( q -- ) ASM-PC !   8 +TO ASM-PC ;

: DB, ( b -- ) B, ;
: DW, ( w -- ) W, ;
: DD, ( d -- ) D, ;
: DQ, ( q -- ) Q, ;

: D! ( d addr -- ) SWAP ASM-TMP !  ASM-TMP SWAP 4 CMOVE ;

: BYTES, ( addr len -- )
    DUP 0> IF
        DUP ASM-PC SWAP CMOVE
        +TO ASM-PC DROP
    ELSE
        2DROP
    THEN
;

: CSTR, ( addr len -- ) BYTES, 0 B, ;

: ALIGN, ( n -- )
    BEGIN
        ASM-PC OVER MOD 0<>
    WHILE
        144 B,
    REPEAT
    DROP
;

( --- Register Constants (0..15) -------------------------------------- )

0  CONSTANT RAX   0  CONSTANT EAX   0  CONSTANT AX   0  CONSTANT AL
1  CONSTANT RCX   1  CONSTANT ECX   1  CONSTANT CX   1  CONSTANT CL
2  CONSTANT RDX   2  CONSTANT EDX   2  CONSTANT DX   2  CONSTANT DL
3  CONSTANT RBX   3  CONSTANT EBX   3  CONSTANT BX   3  CONSTANT BL.
4  CONSTANT RSP   4  CONSTANT ESP   4  CONSTANT SP   4  CONSTANT SPL
5  CONSTANT RBP   5  CONSTANT EBP   5  CONSTANT BP   5  CONSTANT BPL
6  CONSTANT RSI   6  CONSTANT ESI   6  CONSTANT SI   6  CONSTANT SIL
7  CONSTANT RDI   7  CONSTANT EDI   7  CONSTANT DI   7  CONSTANT DIL
8  CONSTANT R8    8  CONSTANT R8D   8  CONSTANT R8W  8  CONSTANT R8B
9  CONSTANT R9    9  CONSTANT R9D   9  CONSTANT R9W  9  CONSTANT R9B
10 CONSTANT R10   10 CONSTANT R10D  10 CONSTANT R10W 10 CONSTANT R10B
11 CONSTANT R11   11 CONSTANT R11D  11 CONSTANT R11W 11 CONSTANT R11B
12 CONSTANT R12   12 CONSTANT R12D  12 CONSTANT R12W 12 CONSTANT R12B
13 CONSTANT R13   13 CONSTANT R13D  13 CONSTANT R13W 13 CONSTANT R13B
14 CONSTANT R14   14 CONSTANT R14D  14 CONSTANT R14W 14 CONSTANT R14B
15 CONSTANT R15   15 CONSTANT R15D  15 CONSTANT R15W 15 CONSTANT R15B

( --- Condition Code Constants (0..15) -------------------------------- )

0  CONSTANT O=    1  CONSTANT NO=
2  CONSTANT B=    2  CONSTANT C=
3  CONSTANT AE=   3  CONSTANT NC=
4  CONSTANT E=    4  CONSTANT Z=
5  CONSTANT NE=   5  CONSTANT NZ=
6  CONSTANT BE=   7  CONSTANT A=
8  CONSTANT S=    9  CONSTANT NS=
10 CONSTANT P=    11 CONSTANT NP=
12 CONSTANT L=    13 CONSTANT GE=
14 CONSTANT LE=   15 CONSTANT G=

( --- REX, ModR/M, and SIB Encoding Helpers --------------------------- )

: RHI ( reg -- 0|1 ) 3 RSHIFT 1 AND ;
: RLOW ( reg -- 0..7 ) 7 AND ;

( REX.W + B )
: REX-WB ( rm -- ) RHI 72 OR B, ;

( REX.W + R + B )
: REX-WRB ( reg rm -- ) RHI SWAP RHI 4 * OR 72 OR B, ;

( REX.W + R + X + B )
: REX-WRXB ( reg idx base -- )
    RHI SWAP RHI 2 * OR SWAP RHI 4 * OR 72 OR B,
;

( Optional REX for 32/16-bit ops when reg >= 8 or rm >= 8 )
: REX-RB? ( reg rm -- )
    RHI SWAP RHI 4 * OR
    ?DUP IF 64 OR B, THEN
;

( Optional REX for 8-bit ops when reg >= 4 or rm >= 8 )
: REX-B8 ( reg rm -- )
    OVER 4 >= OVER 8 >= OR IF
        RHI SWAP RHI 4 * OR 64 OR B,
    ELSE
        2DROP
    THEN
;

: MODRM ( mod reg rm -- )
    RLOW SWAP RLOW 8 * OR SWAP 64 * OR B,
;

: MODRM-RR ( reg rm -- ) 3 -ROT MODRM ;

( Encode [base + disp] with reg field; handles RSP/R12 SIB & RBP/R13 disp8 )
: SIB-RSP? ( base -- ) RLOW 4 = IF 36 B, THEN ;

: MEM-DISP ( reg base disp -- )
    OVER RLOW 5 <> OVER 0= AND IF
        DROP
        DUP >R 0 -ROT MODRM R> SIB-RSP?
    ELSE DUP -128 128 WITHIN IF
        >R DUP >R 1 -ROT MODRM R> SIB-RSP? R> B,
    ELSE
        >R DUP >R 2 -ROT MODRM R> SIB-RSP? R> D,
    THEN THEN
;

: SCALE-BITS ( scale -- bits )
    CASE
        1 OF 0 ENDOF
        2 OF 1 ENDOF
        4 OF 2 ENDOF
        8 OF 3 ENDOF
        0
    ENDCASE
;

( Encode [base + index*scale + disp] with reg field )
0 VALUE SIB-REG
0 VALUE SIB-BASE
0 VALUE SIB-IDX
0 VALUE SIB-SC
0 VALUE SIB-DISP

: SIB-SETUP ( reg base idx scale disp -- )
    TO SIB-DISP
    SCALE-BITS TO SIB-SC
    TO SIB-IDX
    TO SIB-BASE
    TO SIB-REG
;

: SIB-ST-SETUP ( base idx scale disp src -- )
    TO SIB-REG
    TO SIB-DISP
    SCALE-BITS TO SIB-SC
    TO SIB-IDX
    TO SIB-BASE
;

: EMIT-SIB ( -- )
    SIB-DISP 0= SIB-BASE RLOW 5 <> AND IF
        0 SIB-REG 4 MODRM
        SIB-SC SIB-IDX SIB-BASE MODRM
    ELSE SIB-DISP -128 128 WITHIN IF
        1 SIB-REG 4 MODRM
        SIB-SC SIB-IDX SIB-BASE MODRM
        SIB-DISP B,
    ELSE
        2 SIB-REG 4 MODRM
        SIB-SC SIB-IDX SIB-BASE MODRM
        SIB-DISP D,
    THEN THEN
;

( --- Data Movement Instructions -------------------------------------- )

( mov r64, r64 : dst src -- )
: MOV ( dst src -- )
    SWAP 2DUP REX-WRB 137 B, MODRM-RR
;

( mov r32, r32 : dst src -- )
: MOVD ( dst src -- )
    SWAP 2DUP REX-RB? 137 B, MODRM-RR
;

( movabs r64, imm64 : dst imm64 -- )
: MOVI64 ( dst imm64 -- )
    SWAP DUP REX-WB RLOW 184 + B, Q,
;

( mov r32, imm32 : dst imm32 -- )
: MOVI32 ( dst imm32 -- )
    SWAP DUP RHI IF 65 B, THEN RLOW 184 + B, D,
;

( mov r64, imm : uses 5-byte zero-ext, 7-byte sign-ext, or 10-byte imm64 )
: MOVI ( dst imm -- )
    DUP -2147483648 2147483648 WITHIN IF
        DUP 0>= IF
            MOVI32
        ELSE
            SWAP DUP REX-WB 199 B, 0 SWAP MODRM-RR D,
        THEN
    ELSE
        MOVI64
    THEN
;

( Memory Loads: dst base disp -- )
: LDQ  ( dst base disp -- ) >R 2DUP REX-WRB 139 B, R> MEM-DISP ;
: LDD  ( dst base disp -- ) >R 2DUP REX-RB? 139 B, R> MEM-DISP ;
: LDW  ( dst base disp -- ) >R 2DUP REX-WRB 15 B, 183 B, R> MEM-DISP ;
: LDB  ( dst base disp -- ) >R 2DUP REX-WRB 15 B, 182 B, R> MEM-DISP ;
: LDSD ( dst base disp -- ) >R 2DUP REX-WRB 99 B, R> MEM-DISP ;
: LDSW ( dst base disp -- ) >R 2DUP REX-WRB 15 B, 191 B, R> MEM-DISP ;
: LDSB ( dst base disp -- ) >R 2DUP REX-WRB 15 B, 190 B, R> MEM-DISP ;

( Memory Stores: base disp src -- )
: STQ  ( base disp src -- ) SWAP >R SWAP 2DUP REX-WRB 137 B, R> MEM-DISP ;
: STDW ( base disp src -- ) SWAP >R SWAP 2DUP REX-RB? 137 B, R> MEM-DISP ;
: STW  ( base disp src -- ) 102 B, SWAP >R SWAP 2DUP REX-RB? 137 B, R> MEM-DISP ;
: STB  ( base disp src -- ) SWAP >R SWAP 2DUP REX-B8 136 B, R> MEM-DISP ;

( Immediate Memory Stores: base disp imm -- )
: STQI ( base disp imm32 -- ) >R OVER REX-WB 199 B, 0 -ROT MEM-DISP R> D, ;
: STDI ( base disp imm32 -- ) >R OVER RHI IF 65 B, THEN 199 B, 0 -ROT MEM-DISP R> D, ;
: STWI ( base disp imm16 -- ) 102 B, >R OVER RHI IF 65 B, THEN 199 B, 0 -ROT MEM-DISP R> W, ;
: STBI ( base disp imm8  -- ) >R OVER RHI IF 65 B, THEN 198 B, 0 -ROT MEM-DISP R> B, ;

( Indexed SIB Loads/Stores/LEA )
: LDQ-X ( dst base idx scale disp -- )
    SIB-SETUP SIB-REG SIB-IDX SIB-BASE REX-WRXB 139 B, EMIT-SIB
;
: LDB-X ( dst base idx scale disp -- )
    SIB-SETUP SIB-REG SIB-IDX SIB-BASE REX-WRXB 15 B, 182 B, EMIT-SIB
;
: LEA-X ( dst base idx scale disp -- )
    SIB-SETUP SIB-REG SIB-IDX SIB-BASE REX-WRXB 141 B, EMIT-SIB
;
: STQ-X ( base idx scale disp src -- )
    SIB-ST-SETUP SIB-REG SIB-IDX SIB-BASE REX-WRXB 137 B, EMIT-SIB
;
: STB-X ( base idx scale disp src -- )
    SIB-ST-SETUP SIB-REG SIB-IDX SIB-BASE REX-WRXB 136 B, EMIT-SIB
;

( Address Calculation & Exchange )
: LEA ( dst base disp -- ) >R 2DUP REX-WRB 141 B, R> MEM-DISP ;
: LEA-RIP ( dst disp32 -- ) SWAP DUP 0 REX-WRB 141 B, 0 SWAP 5 MODRM D, ;
: XCHG ( r1 r2 -- ) SWAP 2DUP REX-WRB 135 B, MODRM-RR ;

( --- Stack Instructions ---------------------------------------------- )

: PUSH ( reg -- ) DUP RHI IF 65 B, THEN RLOW 80 + B, ;
: POP  ( reg -- ) DUP RHI IF 65 B, THEN RLOW 88 + B, ;
: PUSHI ( imm -- )
    DUP -128 128 WITHIN IF 106 B, B, ELSE 104 B, D, THEN
;
: PUSHFQ ( -- ) 156 B, ;
: POPFQ  ( -- ) 157 B, ;

( --- ALU Instructions ------------------------------------------------ )

: ALU-RR ( dst src op -- )
    >R SWAP 2DUP REX-WRB R> 8 * 1 + B, MODRM-RR
;

: ALU-RI ( dst imm op -- )
    >R SWAP DUP REX-WB
    OVER -128 128 WITHIN IF
        131 B, R> SWAP MODRM-RR B,
    ELSE
        129 B, R> SWAP MODRM-RR D,
    THEN
;

: ADD  ( dst src -- ) 0 ALU-RR ;   : ADDR ( dst src -- ) 0 ALU-RR ;
: OR.  ( dst src -- ) 1 ALU-RR ;   : ORR  ( dst src -- ) 1 ALU-RR ;
: ADC  ( dst src -- ) 2 ALU-RR ;   : ADCR ( dst src -- ) 2 ALU-RR ;
: SBB  ( dst src -- ) 3 ALU-RR ;   : SBBR ( dst src -- ) 3 ALU-RR ;
: AND. ( dst src -- ) 4 ALU-RR ;   : ANDR ( dst src -- ) 4 ALU-RR ;
: SUB  ( dst src -- ) 5 ALU-RR ;   : SUBR ( dst src -- ) 5 ALU-RR ;
: XOR. ( dst src -- ) 6 ALU-RR ;   : XORR ( dst src -- ) 6 ALU-RR ;
: CMP  ( dst src -- ) 7 ALU-RR ;   : CMPR ( dst src -- ) 7 ALU-RR ;

: ADDI ( dst imm -- ) 0 ALU-RI ;
: ORI  ( dst imm -- ) 1 ALU-RI ;
: ADCI ( dst imm -- ) 2 ALU-RI ;
: SBBI ( dst imm -- ) 3 ALU-RI ;
: ANDI ( dst imm -- ) 4 ALU-RI ;
: SUBI ( dst imm -- ) 5 ALU-RI ;
: XORI ( dst imm -- ) 6 ALU-RI ;
: CMPI ( dst imm -- ) 7 ALU-RI ;

: TEST ( r1 r2 -- ) SWAP 2DUP REX-WRB 133 B, MODRM-RR ;
: TESTI ( reg imm32 -- ) SWAP DUP REX-WB 247 B, 0 SWAP MODRM-RR D, ;

( --- Unary, Multiply, Divide, and Sign-Extension --------------------- )

: INC   ( reg -- ) DUP REX-WB 255 B, 0 SWAP MODRM-RR ;
: DEC   ( reg -- ) DUP REX-WB 255 B, 1 SWAP MODRM-RR ;
: NOT.  ( reg -- ) DUP REX-WB 247 B, 2 SWAP MODRM-RR ;
: NOTR  ( reg -- ) NOT. ;
: NEG   ( reg -- ) DUP REX-WB 247 B, 3 SWAP MODRM-RR ;
: MUL1  ( reg -- ) DUP REX-WB 247 B, 4 SWAP MODRM-RR ;
: IMUL1 ( reg -- ) DUP REX-WB 247 B, 5 SWAP MODRM-RR ;
: DIV1  ( reg -- ) DUP REX-WB 247 B, 6 SWAP MODRM-RR ;
: IDIV  ( reg -- ) DUP REX-WB 247 B, 7 SWAP MODRM-RR ;

( 2-operand signed multiply: dst = dst * src )
: IMUL ( dst src -- ) 2DUP REX-WRB 15 B, 175 B, MODRM-RR ;

( 3-operand signed multiply: dst = src * imm )
: IMULI ( dst src imm -- )
    >R 2DUP REX-WRB
    R@ -128 128 WITHIN IF
        107 B, MODRM-RR R> B,
    ELSE
        105 B, MODRM-RR R> D,
    THEN
;

: CQO ( -- ) 72 B, 153 B, ;
: CDQ ( -- ) 153 B, ;

( --- Shifts and Rotates ---------------------------------------------- )

: SHIFT-IMM ( reg imm8 subop -- )
    >R SWAP DUP REX-WB 193 B, R> SWAP MODRM-RR B,
;

: SHIFT-CL ( reg subop -- )
    SWAP DUP REX-WB 211 B, MODRM-RR
;

: ROLI ( reg imm8 -- ) 0 SHIFT-IMM ;
: RORI ( reg imm8 -- ) 1 SHIFT-IMM ;
: SHLI ( reg imm8 -- ) 4 SHIFT-IMM ;
: SHRI ( reg imm8 -- ) 5 SHIFT-IMM ;
: SARI ( reg imm8 -- ) 7 SHIFT-IMM ;

: ROL-CL ( reg -- ) 0 SHIFT-CL ;
: ROR-CL ( reg -- ) 1 SHIFT-CL ;
: SHL-CL ( reg -- ) 4 SHIFT-CL ;
: SHR-CL ( reg -- ) 5 SHIFT-CL ;
: SAR-CL ( reg -- ) 7 SHIFT-CL ;

( --- Conditional Set & Conditional Move ------------------------------ )

: SETCC ( reg cc -- )
    OVER 4 >= IF OVER RHI 64 OR B, THEN
    15 B, 144 + B, 0 SWAP MODRM-RR
;

: SETE  ( reg -- ) E=  SETCC ;   : SETZ  ( reg -- ) Z=  SETCC ;
: SETNE ( reg -- ) NE= SETCC ;   : SETNZ ( reg -- ) NZ= SETCC ;
: SETL  ( reg -- ) L=  SETCC ;   : SETG  ( reg -- ) G=  SETCC ;
: SETLE ( reg -- ) LE= SETCC ;   : SETGE ( reg -- ) GE= SETCC ;
: SETB  ( reg -- ) B=  SETCC ;   : SETA  ( reg -- ) A=  SETCC ;

: CMOVCC ( dst src cc -- )
    >R 2DUP REX-WRB 15 B, R> 64 + B, MODRM-RR
;

: CMOVE. ( dst src -- ) E=  CMOVCC ;  : CMOVZ  ( dst src -- ) Z=  CMOVCC ;
: CMOVNE ( dst src -- ) NE= CMOVCC ;  : CMOVNZ ( dst src -- ) NZ= CMOVCC ;
: CMOVL  ( dst src -- ) L=  CMOVCC ;  : CMOVG  ( dst src -- ) G=  CMOVCC ;
: CMOVLE ( dst src -- ) LE= CMOVCC ;  : CMOVGE ( dst src -- ) GE= CMOVCC ;
: CMOVB  ( dst src -- ) B=  CMOVCC ;  : CMOVA  ( dst src -- ) A=  CMOVCC ;

( --- Labels, Branches, Calls, and Structured Control Flow ------------ )

: LBL-ADDR ( id -- addr ) CELLS ASM-LBLS + ;

: ADD-FIXUP ( id patch-addr -- )
    ASM-FIX-CNT 128 < IF
        ASM-FIX-CNT CELLS ASM-FIX-ADDR + !
        ASM-FIX-CNT CELLS ASM-FIX-LBL  + !
        1 +TO ASM-FIX-CNT
    ELSE
        2DROP ." ASM error: fixup table full" CR
    THEN
;

( Emit 4-byte relative offset to label id at current ASM-PC )
: EMIT-REL32 ( id -- )
    DUP LBL-ADDR @ ?DUP IF
        NIP ASM-PC 4 + - D,
    ELSE
        ASM-PC ADD-FIXUP
        0 D,
    THEN
;

( Define label id at current ASM-PC and resolve any forward references )
: L: ( id -- )
    DUP LBL-ADDR ASM-PC SWAP !
    ASM-FIX-CNT 0> IF
        ASM-FIX-CNT 0 DO
            I CELLS ASM-FIX-LBL + @ OVER = IF
                I CELLS ASM-FIX-ADDR + @ ?DUP IF
                    ASM-PC OVER 4 + - SWAP D!
                    0 I CELLS ASM-FIX-ADDR + !
                THEN
            THEN
        LOOP
    THEN
    DROP
;

: JMP  ( id -- ) 233 B, EMIT-REL32 ;
: CALL ( id -- ) 232 B, EMIT-REL32 ;

: JCC ( id cc -- ) 15 B, 128 + B, EMIT-REL32 ;

: JO  ( id -- ) O=  JCC ;   : JNO ( id -- ) NO= JCC ;
: JB  ( id -- ) B=  JCC ;   : JC  ( id -- ) C=  JCC ;
: JAE ( id -- ) AE= JCC ;   : JNC ( id -- ) NC= JCC ;
: JE  ( id -- ) E=  JCC ;   : JZ  ( id -- ) Z=  JCC ;
: JNE ( id -- ) NE= JCC ;   : JNZ ( id -- ) NZ= JCC ;
: JBE ( id -- ) BE= JCC ;   : JA  ( id -- ) A=  JCC ;
: JS  ( id -- ) S=  JCC ;   : JNS ( id -- ) NS= JCC ;
: JL  ( id -- ) L=  JCC ;   : JGE ( id -- ) GE= JCC ;
: JLE ( id -- ) LE= JCC ;   : JG  ( id -- ) G=  JCC ;

( Load address of label id into dst using RIP-relative LEA )
: LEA-LBL ( dst id -- )
    SWAP DUP 0 REX-WRB 141 B, 0 SWAP 5 MODRM EMIT-REL32
;

( Indirect register jumps and calls )
: JMP-R  ( reg -- ) DUP RHI IF 65 B, THEN 255 B, 4 SWAP MODRM-RR ;
: CALL-R ( reg -- ) DUP RHI IF 65 B, THEN 255 B, 2 SWAP MODRM-RR ;
: RET    ( -- ) 195 B, ;

( Structured Assembler Control Flow )
: IF, ( cc -- patch-addr )
    15 B, 1 XOR 128 + B, ASM-PC 0 D,
;

: THEN, ( patch-addr -- )
    DUP 4 + ASM-PC SWAP - SWAP D!
;

: ELSE, ( patch-addr1 -- patch-addr2 )
    233 B, ASM-PC 0 D, SWAP THEN,
;

: BEGIN, ( -- loop-addr ) ASM-PC ;

: AGAIN, ( loop-addr -- )
    233 B, ASM-PC 4 + - D,
;

: UNTIL, ( loop-addr cc -- )
    15 B, 1 XOR 128 + B, ASM-PC 4 + - D,
;

: WHILE, ( loop-addr cc -- loop-addr patch-addr ) IF, ;

: REPEAT, ( loop-addr patch-addr -- ) SWAP AGAIN, THEN, ;

( --- String, I/O, and System Instructions ---------------------------- )

: NOP    ( -- ) 144 B, ;
: CLD    ( -- ) 252 B, ;
: STD.   ( -- ) 253 B, ;
: CLI    ( -- ) 250 B, ;
: STI    ( -- ) 251 B, ;
: HLT    ( -- ) 244 B, ;
: PAUSE  ( -- ) 243 B, 144 B, ;
: RDTSC  ( -- ) 15 B, 49 B, ;
: CPUID  ( -- ) 15 B, 162 B, ;
: IRETQ  ( -- ) 72 B, 207 B, ;
: INT    ( imm8 -- ) 205 B, B, ;

: REP   ( -- ) 243 B, ;
: MOVSB ( -- ) 164 B, ;
: MOVSQ ( -- ) 72 B, 165 B, ;
: STOSB ( -- ) 170 B, ;
: STOSW ( -- ) 102 B, 171 B, ;
: STOSD ( -- ) 171 B, ;
: STOSQ ( -- ) 72 B, 171 B, ;
: LODSB ( -- ) 172 B, ;
: LODSQ ( -- ) 72 B, 173 B, ;

: INB-DX   ( -- ) 236 B, ;
: INW-DX   ( -- ) 102 B, 237 B, ;
: IND-DX   ( -- ) 237 B, ;
: OUTB-DX  ( -- ) 238 B, ;
: OUTW-DX  ( -- ) 102 B, 239 B, ;
: OUTD-DX  ( -- ) 239 B, ;
: INB-IMM  ( port8 -- ) 228 B, B, ;
: OUTB-IMM ( port8 -- ) 230 B, B, ;

( --- Assembly Session, Binary Saving/Loading, and CALL-NATIVE -------- )

: ASM-BEGIN ( -- )
    ASM-CUSTOM-ORG ?DUP IF
        TO ASM-ENTRY
        0 TO ASM-CUSTOM-ORG
        0 TO ASM-AT-HERE
    ELSE
        ALIGN
        HERE @ TO ASM-ENTRY
        1 TO ASM-AT-HERE
    THEN
    ASM-ENTRY TO ASM-PC
    0 TO ASM-SIZE
    ASM-LBLS 512 ZERO-MEM
    0 TO ASM-FIX-CNT
;

: ASM-END ( -- )
    ASM-FIX-CNT 0> IF
        ASM-FIX-CNT 0 DO
            I CELLS ASM-FIX-ADDR + @ 0<> IF
                ." ASM warning: unresolved label "
                I CELLS ASM-FIX-LBL + @ . CR
            THEN
        LOOP
    THEN
    ASM-PC ASM-ENTRY - TO ASM-SIZE
    ASM-AT-HERE IF
        ASM-PC ALIGNED HERE !
    THEN
;

: ASM-DUMP ( -- ) ASM-ENTRY ASM-SIZE DUMP ;

( Compile-time helper to embed the next space-delimited token as a string )
: COMPILE-WORD-STR ( -- )
    WORD
    ' LITSTRING ,
    DUP ,
    DUP 0> IF
        DUP 0 DO
            OVER I + C@ C,
        LOOP
    THEN
    2DROP
    ALIGN
;

( Write ASM-ENTRY / ASM-SIZE to file named by addr/len )
: (ASM-SAVE) ( name-addr name-len -- )
    DUP 16 > IF DROP 16 THEN
    TO MK-LEN
    MK-NAME-BUF MK-LEN CMOVE
    ASM-ENTRY TO WF-ADDR
    ASM-SIZE  TO WF-SIZE

    MK-NAME-BUF MK-LEN FIND-ENTRY ?DUP IF
        DUP DE-DIR? IF
            DROP ." Is a directory" CR EXIT
        THEN
        32 ZERO-MEM
        SAVE-DIR
    THEN

    WF-SIZE 511 + 512 /
    DUP 0= IF DROP 1 THEN
    DUP TO WF-SECTORS
    ALLOC-SECTORS TO WF-LBA

    FREE-ENTRY ?DUP 0= IF
        ." Directory full" CR EXIT
    THEN
    TO WF-DE

    WF-SECTORS 0 DO
        SEC-BUF 512 ZERO-MEM
        WF-SIZE I 512 * -
        DUP 512 > IF DROP 512 THEN
        DUP 0> IF
            WF-ADDR I 512 * +  SEC-BUF  ROT  CMOVE
        ELSE
            DROP
        THEN
        WF-LBA I + SEC-BUF SECTOR!
    LOOP

    MK-NAME-BUF MK-LEN WF-DE DE-SET-NAME
    WF-LBA WF-DE 16 + !
    WF-SIZE WF-DE 24 + !
    SAVE-DIR
;

( Save the last assembled block to "filename"; works interactive & compiled )
: ASM-SAVE IMMEDIATE ( "filename" -- )
    STATE @ IF
        COMPILE-WORD-STR
        ' (ASM-SAVE) ,
    ELSE
        WORD (ASM-SAVE)
    THEN
;

0 VALUE BIN-LBA
0 VALUE BIN-ADDR

( Read directory entry 'de' into memory at 'addr', returning byte size )
: LOAD-DE ( de addr -- size )
    TO BIN-ADDR
    DUP DE-LBA TO BIN-LBA
    DE-SIZE DUP 511 + 512 /
    DUP 0> IF
        0 DO
            BIN-LBA I +  BIN-ADDR I 512 * +  SECTOR@
        LOOP
    ELSE
        DROP
    THEN
;

: (LOAD-BIN) ( addr name-addr name-len -- size )
    FIND-ENTRY ?DUP 0= IF
        DROP ." File not found" CR 0 EXIT
    THEN
    DUP DE-DIR? IF
        2DROP ." Is a directory" CR 0 EXIT
    THEN
    OVER TO ASM-ENTRY
    SWAP LOAD-DE
    DUP TO ASM-SIZE
;

( Load a binary file from the current directory into 'addr' )
: LOAD-BIN IMMEDIATE ( addr "filename" -- size )
    STATE @ IF
        COMPILE-WORD-STR
        ' (LOAD-BIN) ,
    ELSE
        WORD (LOAD-BIN)
    THEN
;

( Execute native function at 'entry' with 'arg' on NATIVE-STACK )
: RUN-NATIVE ( arg entry -- result )
    NATIVE-STACK CALL-NATIVE
;

( Execute the most recently assembled or loaded block with 'arg' )
: ASM-RUN ( arg -- result )
    ASM-ENTRY NATIVE-STACK CALL-NATIVE
;

: (RUN-BIN) ( arg name-addr name-len -- result )
    NATIVE-BASE -ROT (LOAD-BIN) 0> IF
        NATIVE-BASE NATIVE-STACK CALL-NATIVE
    ELSE
        DROP 0
    THEN
;

( Load "filename" to NATIVE-BASE and run it via CALL-NATIVE like DOOM )
: RUN-BIN IMMEDIATE ( arg "filename" -- result )
    STATE @ IF
        COMPILE-WORD-STR
        ' (RUN-BIN) ,
    ELSE
        WORD (RUN-BIN)
    THEN
;

( High-level defining word for inline native functions:                 )
(   NATIVE: <name>  ...x64 instructions...  ;NATIVE                     )
( Creates a Forth word <name> ( arg -- result ) using CALL-NATIVE.      )
: NATIVE: ( "name" -- )
    WORD CREATE
    DOCOL ,
    ' LIT , HERE @ 40 + ,
    ' LIT , NATIVE-STACK ,
    ' CALL-NATIVE ,
    ' EXIT ,
    ASM-BEGIN
;

: ;NATIVE ( -- )
    ASM-END
;

: ASM-UNLOAD ( -- )
    ASM-ORIG-LATEST LATEST !
    ASM-ORIG-HERE   HERE !
    ." x64 Assembler unloaded (" UNUSED . ." cells free)" CR
;

." f64 x64 Assembler loaded." CR
