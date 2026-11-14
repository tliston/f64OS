# `asm.f` — Forth x86-64 Assembler User Guide

`disk_files/asm.f` is a self-contained, postfix 64-bit x86-64 assembler written in f64 Forth. It allows you to assemble x86-64 machine code directly into memory, wrap native routines as standard Forth words, or write flat `.bin` executables to the f64OS filesystem and execute them via `CALL-NATIVE` using the same mechanism as DOOM.

---

## 1. Quick Start

At the f64OS Forth prompt, load the assembler with `INCLUDE`:

```forth
INCLUDE asm.f
```

To run the built-in demonstration and test suite (`disk_files/asm_demo.f`), which tests inline native functions, structured control flow, local labels, RIP-relative addressing, saving a binary (`demo.bin`) to disk, and loading/executing it with `CALL-NATIVE`:

```forth
INCLUDE asm_demo.f
```

When you are finished using the assembler and want to reclaim the dictionary space it occupies, run:

```forth
ASM-UNLOAD
```

---

## 2. Execution Model & `CALL-NATIVE` ABI

### How `CALL-NATIVE` Works
f64OS provides the primitive `CALL-NATIVE`:

```forth
( arg entry stack-top -- result ) CALL-NATIVE
```

When `CALL-NATIVE` executes:
1. **Saves Forth State**: The Forth interpreter registers (`RSP` data stack pointer, `RSI` instruction pointer, `RBP` return stack pointer, and `R15` iterator stack pointer) are saved to dedicated kernel memory locations.
2. **Switches Stack**: `RSP` is set to `(stack-top & ~15) - 32` (16-byte aligned with 32 bytes of shadow space allocated above the return address).
3. **Passes `arg` in Both ABIs**: The 64-bit `arg` value is placed in **both `RDI`** (System V AMD64 ABI first argument) and **`RCX`** (Microsoft x64 ABI first argument).
4. **Calls Native Code**: Executes `call entry`.
5. **Returns `result` to Forth**: When your native function executes `RET`, `CALL-NATIVE` executes `cld`, restores the Forth registers (`RSP`, `RSI`, `RBP`, `R15`), and pushes **`RAX`** onto the Forth data stack as `result`.

### Register & Environment Rules
* **Input Argument**: `RDI` (and `RCX`) holds the 64-bit `arg` passed from Forth.
* **Return Value**: Place your 64-bit return value in `RAX` before executing `RET`.
* **Scratch vs. Preserved Registers**: Because `CALL-NATIVE` saves `RSP`, `RSI`, `RBP`, and `R15` in static memory and `NEXT` overwrites `RAX`, your top-level entry routine can freely use any general-purpose register (`RAX`, `RCX`, `RDX`, `RBX`, `RBP`, `RSI`, `RDI`, `R8`–`R15`) as long as `RSP` is restored to its entry value before `RET`.
* **Memory Mapping**: The first 1 GiB of physical memory (`0x00000000`–`0x3FFFFFFF`) is identity-mapped with read, write, and execute permissions in Ring 0. Code assembled into `HERE` (`0x200000`–`0x400000`) or loaded into `NATIVE-BASE` (`0x1000000`) executes directly.
* **Pre-allocated Native Stack & Load Base**:
  * `NATIVE-STACK`: A 16 KiB native stack allotted by `asm.f` (pushes the top-of-stack address).
  * `NATIVE-BASE`: Constant `0x1000000` (16 MiB), the same base address where DOOM loads `doom.bin`.

### Passing Multiple Arguments (The Boot-Block Pattern)
Because `CALL-NATIVE` passes a single 64-bit cell `arg` in `RDI`/`RCX`, multi-argument functions (or programs like DOOM) pass the address of an allotted array of 64-bit cells (a "boot block" or parameter block) as `arg`:

```forth
4 CELLS ALLOT CONSTANT MY-PARAMS
KSERVICES MY-PARAMS 0 CELLS + !
100       MY-PARAMS 1 CELLS + !
200       MY-PARAMS 2 CELLS + !
```

Inside your x86-64 code, `RDI` points to `MY-PARAMS`, so you can read fields with `RAX RDI 0 LDQ`, `RBX RDI 8 LDQ`, `RCX RDI 16 LDQ`, and write outputs back with `RDI 24 RAX STQ`.

---

## 3. Three Ways to Assemble and Run Code

### Workflow A: Inline Native Forth Words (`NATIVE: ... ;NATIVE`)
Use `NATIVE: <name> ... ;NATIVE` to define a Forth word with stack effect `( arg -- result )` that automatically invokes your assembled machine code via `CALL-NATIVE`:

```forth
NATIVE: ADD42 ( n -- n+42 )
    RAX RDI MOV
    RAX 42 ADDI
    RET
;NATIVE

100 ADD42 .   ( prints 142 )
```

### Workflow B: In-Memory Assembly (`ASM-BEGIN ... ASM-END`)
Use `ASM-BEGIN` and `ASM-END` to assemble a block of code at `HERE` (or at a custom address specified prior to `ASM-BEGIN` via `<addr> ASM-AT`):

```forth
ASM-BEGIN
    RAX RDI MOV
    RAX RDI IMUL         ( rax = rdi * rdi )
    RET
ASM-END

ASM-DUMP                 ( hex-dump the generated machine code )
12 ASM-RUN .             ( runs ASM-ENTRY on NATIVE-STACK -> prints 144 )

( Or call CALL-NATIVE explicitly: )
12 ASM-ENTRY NATIVE-STACK CALL-NATIVE .
```

### Workflow C: Standalone `.bin` Files (DOOM-Style Disk Loading)
You can save any assembled block to the f64OS filesystem with `ASM-SAVE`, load it into memory with `LOAD-BIN`, and execute it with `CALL-NATIVE` (or `RUN-BIN`):

```forth
ASM-BEGIN
    RAX RDI 3 IMULI      ( rax = rdi * 3 )
    RET
ASM-END

( Save the assembled bytes to a file on the f64OS disk )
ASM-SAVE triple.bin

( Option 1: Explicit load + CALL-NATIVE, just like doom.f )
NATIVE-BASE LOAD-BIN triple.bin DROP
14 NATIVE-BASE NATIVE-STACK CALL-NATIVE .   ( prints 42 )

( Option 2: One-step helper that loads to NATIVE-BASE and calls CALL-NATIVE )
14 RUN-BIN triple.bin .                     ( prints 42 )
```

> **Note:** `ASM-SAVE`, `LOAD-BIN`, and `RUN-BIN` are `IMMEDIATE` words that work **both** interactively at the Forth prompt and inside compiled `: ... ;` definitions.

---

## 4. Syntax & Operand Conventions

### Postfix Intel/NASM Operand Order
All instructions use postfix syntax with **Intel/NASM operand order** (`destination` pushed first, `source` pushed second, followed by the instruction mnemonic):

| NASM Syntax | `asm.f` Forth Syntax | Meaning |
| :--- | :--- | :--- |
| `mov rax, rbx` | `RAX RBX MOV` | `RAX = RBX` |
| `mov rax, 100` | `RAX 100 MOVI` | `RAX = 100` |
| `add rax, rcx` | `RAX RCX ADD` | `RAX += RCX` |
| `sub rax, 8` | `RAX 8 SUBI` | `RAX -= 8` |
| `cmp rax, rdx` | `RAX RDX CMP` | Compare `RAX` with `RDX` (`RAX - RDX`) |
| `mov rax, [rbx + 16]` | `RAX RBX 16 LDQ` | Load 64-bit qword at `[RBX + 16]` into `RAX` |
| `mov [rbx + 16], rax` | `RBX 16 RAX STQ` | Store 64-bit `RAX` into `[RBX + 16]` |
| `mov rax, [rbx + rcx*8 + 0]` | `RAX RBX RCX 8 0 LDQ-X` | Load qword from `[RBX + RCX*8 + 0]` into `RAX` |
| `lea rsi, [rip + label_2]` | `RSI 2 LEA-LBL` | Load address of label `2` into `RSI` |

### Forth Word Collision Avoidance
Because f64 Forth uses a single flat dictionary without separate vocabularies, a few x86 mnemonics would collide with built-in Forth words (`AND`, `OR`, `XOR`, `NOT`, `CMOVE`, `BL`). Those assembler mnemonics add a trailing dot (or `-R` alias):
* Bitwise ALU: `AND.` (or `ANDR`), `OR.` (or `ORR`), `XOR.` (or `XORR`), `NOT.` (or `NOTR`)
* Conditional move on equal: `CMOVE.` (or `CMOVZ`)
* Set direction flag: `STD.`
* 8-bit low `RBX` register alias: `BL.`

Keeping Forth's own `AND`, `OR`, `XOR`, `NOT`, `+`, `-`, `*`, `/`, `LSHIFT`, `RSHIFT`, `DO ... LOOP`, and `IF ... THEN` unshadowed means you can freely use full Forth expressions and loops as a **macro assembler** while assembling x86-64 code.

### Number Base (`DECIMAL` vs. `HEX`)
f64 Forth's `NUMBER` parser converts integer literals according to the current value of `BASE` (`DECIMAL` or `HEX`) and does **not** use `0x` prefixes. Switch bases with `HEX` and `DECIMAL`:

```forth
HEX
RAX B8000 MOVI     ( loads 0xB8000 into RAX )
DECIMAL
```

---

## 5. Complete Instruction Reference

### Registers
All 16 general-purpose registers are defined as constants `0` through `15`. Size aliases are provided for readability:

| ID | 64-bit | 32-bit | 16-bit | 8-bit |
| :-: | :--- | :--- | :--- | :--- |
| `0` | `RAX` | `EAX` | `AX` | `AL` |
| `1` | `RCX` | `ECX` | `CX` | `CL` |
| `2` | `RDX` | `EDX` | `DX` | `DL` |
| `3` | `RBX` | `EBX` | `BX` | `BL.` |
| `4` | `RSP` | `ESP` | `SP` | `SPL` |
| `5` | `RBP` | `EBP` | `BP` | `BPL` |
| `6` | `RSI` | `ESI` | `SI` | `SIL` |
| `7` | `RDI` | `EDI` | `DI` | `DIL` |
| `8`–`15` | `R8`–`R15` | `R8D`–`R15D` | `R8W`–`R15W` | `R8B`–`R15B` |

---

### Data Movement & Address Calculation

| Word | Stack `( before -- )` | x86-64 Instruction | Notes |
| :--- | :--- | :--- | :--- |
| `MOV` | `( dst src -- )` | `mov r64, r64` | 64-bit register copy |
| `MOVD` | `( dst src -- )` | `mov r32, r32` | 32-bit copy (zero-extends upper 32 bits) |
| `MOVI` | `( dst imm -- )` | `mov r64, imm` | Auto-selects 5-byte zero-ext, 7-byte sign-ext `imm32`, or 10-byte `imm64` |
| `MOVI64` | `( dst imm64 -- )` | `movabs r64, imm64` | Always emits 10-byte `REX.W + B8+rd iq` |
| `MOVI32` | `( dst imm32 -- )` | `mov r32, imm32` | Emits 5/6-byte `B8+rd id` (zero-extends to 64 bits) |
| `XCHG` | `( r1 r2 -- )` | `xchg r64, r64` | Swap contents of two 64-bit registers |
| `LEA` | `( dst base disp -- )` | `lea r64, [base + disp]` | Load effective address `base + disp` |
| `LEA-RIP` | `( dst disp32 -- )` | `lea r64, [rip + disp32]` | Raw RIP-relative effective address |
| `LEA-LBL` | `( dst id -- )` | `lea r64, [rip + label_id]` | Load address of local label `id` (`0..63`), backward or forward |

---

### Memory Loads & Stores (`[base + disp]`)
`MEM-DISP` automatically handles all x86-64 ModR/M encoding rules:
* Omitting displacement when `disp == 0` (except for `RBP`/`R13`, where it automatically emits `mod=1, disp8=0`),
* Using 1-byte signed `disp8` when `-128 <= disp <= 127` and 4-byte `disp32` otherwise,
* Emitting the required `0x24` SIB byte whenever the base register is `RSP` (`4`) or `R12` (`12`).

| Word | Stack `( before -- )` | x86-64 Instruction | Description |
| :--- | :--- | :--- | :--- |
| `LDQ` | `( dst base disp -- )` | `mov r64, [base + disp]` | Load 64-bit qword |
| `LDD` | `( dst base disp -- )` | `mov r32, [base + disp]` | Load 32-bit dword (zero-extended to 64 bits) |
| `LDW` | `( dst base disp -- )` | `movzx r64, word [base + disp]` | Load 16-bit word (zero-extended to 64 bits) |
| `LDB` | `( dst base disp -- )` | `movzx r64, byte [base + disp]` | Load 8-bit byte (zero-extended to 64 bits) |
| `LDSD` | `( dst base disp -- )` | `movsxd r64, dword [base + disp]` | Load 32-bit dword (sign-extended to 64 bits) |
| `LDSW` | `( dst base disp -- )` | `movsx r64, word [base + disp]` | Load 16-bit word (sign-extended to 64 bits) |
| `LDSB` | `( dst base disp -- )` | `movsx r64, byte [base + disp]` | Load 8-bit byte (sign-extended to 64 bits) |
| `STQ` | `( base disp src -- )` | `mov [base + disp], r64` | Store 64-bit qword from `src` |
| `STDW` | `( base disp src -- )` | `mov [base + disp], r32` | Store 32-bit dword from `src` |
| `STW` | `( base disp src -- )` | `mov [base + disp], r16` | Store 16-bit word from `src` |
| `STB` | `( base disp src -- )` | `mov [base + disp], r8` | Store 8-bit low byte from `src` (`AL`..`R15B`) |
| `STQI` | `( base disp imm32 -- )` | `mov qword [base + disp], imm32` | Store sign-extended 32-bit immediate as 64-bit qword |
| `STDI` | `( base disp imm32 -- )` | `mov dword [base + disp], imm32` | Store 32-bit immediate |
| `STWI` | `( base disp imm16 -- )` | `mov word [base + disp], imm16` | Store 16-bit immediate |
| `STBI` | `( base disp imm8 -- )` | `mov byte [base + disp], imm8` | Store 8-bit immediate |

---

### Indexed SIB Memory Addressing (`[base + index*scale + disp]`)
`scale` must be `1`, `2`, `4`, or `8` (and `index` cannot be `RSP`).

| Word | Stack `( before -- )` | x86-64 Instruction |
| :--- | :--- | :--- |
| `LDQ-X` | `( dst base idx scale disp -- )` | `mov r64, [base + idx*scale + disp]` |
| `LDB-X` | `( dst base idx scale disp -- )` | `movzx r64, byte [base + idx*scale + disp]` |
| `LEA-X` | `( dst base idx scale disp -- )` | `lea r64, [base + idx*scale + disp]` |
| `STQ-X` | `( base idx scale disp src -- )` | `mov [base + idx*scale + disp], r64` |
| `STB-X` | `( base idx scale disp src -- )` | `mov [base + idx*scale + disp], r8` |

---

### Stack Operations

| Word | Stack `( before -- )` | x86-64 Instruction |
| :--- | :--- | :--- |
| `PUSH` | `( reg -- )` | `push r64` |
| `POP` | `( reg -- )` | `pop r64` |
| `PUSHI` | `( imm -- )` | `push imm8` (if `-128..127`) or `push imm32` |
| `PUSHFQ` | `( -- )` | `pushfq` |
| `POPFQ` | `( -- )` | `popfq` |

---

### Arithmetic & Logic (ALU)
Immediate ALU instructions (`ADDI`, `SUBI`, etc.) automatically use the compact 1-byte sign-extended `0x83` encoding when `-128 <= imm <= 127` and the 4-byte `0x81` encoding otherwise.

| Reg-Reg Word `( dst src -- )` | Alias | Reg-Imm Word `( dst imm -- )` | Operation |
| :--- | :--- | :--- | :--- |
| `ADD` | `ADDR` | `ADDI` | `dst += src / imm` |
| `OR.` | `ORR` | `ORI` | `dst \|= src / imm` |
| `ADC` | `ADCR` | `ADCI` | `dst += src / imm + CF` |
| `SBB` | `SBBR` | `SBBI` | `dst -= src / imm + CF` |
| `AND.` | `ANDR` | `ANDI` | `dst &= src / imm` |
| `SUB` | `SUBR` | `SUBI` | `dst -= src / imm` |
| `XOR.` | `XORR` | `XORI` | `dst ^= src / imm` |
| `CMP` | `CMPR` | `CMPI` | Set flags for `dst - src / imm` |
| `TEST` | — | `TESTI` | Set flags for `dst & src / imm` |

---

### Unary, Multiplication, & Division

| Word | Stack `( before -- )` | x86-64 Instruction | Description |
| :--- | :--- | :--- | :--- |
| `INC` | `( reg -- )` | `inc r64` | `reg++` |
| `DEC` | `( reg -- )` | `dec r64` | `reg--` |
| `NOT.` / `NOTR` | `( reg -- )` | `not r64` | Bitwise one's complement `~reg` |
| `NEG` | `( reg -- )` | `neg r64` | Two's complement negate `-reg` |
| `IMUL` | `( dst src -- )` | `imul r64, r64` | Signed multiply: `dst = dst * src` |
| `IMULI` | `( dst src imm -- )` | `imul r64, r64, imm` | Signed multiply: `dst = src * imm` |
| `MUL1` | `( reg -- )` | `mul r64` | Unsigned `RDX:RAX = RAX * reg` |
| `IMUL1` | `( reg -- )` | `imul r64` | Signed `RDX:RAX = RAX * reg` |
| `DIV1` | `( reg -- )` | `div r64` | Unsigned divide `RDX:RAX` by `reg` (`RAX`=quot, `RDX`=rem) |
| `IDIV` | `( reg -- )` | `idiv r64` | Signed divide `RDX:RAX` by `reg` (`RAX`=quot, `RDX`=rem) |
| `CQO` | `( -- )` | `cqo` | Sign-extend `RAX` into `RDX:RAX` (use before `IDIV`) |
| `CDQ` | `( -- )` | `cdq` | Sign-extend `EAX` into `EDX:EAX` |

---

### Bit Shifts & Rotates

| By Immediate `( reg imm8 -- )` | By `CL` `( reg -- )` | Operation |
| :--- | :--- | :--- |
| `SHLI` | `SHL-CL` | Logical shift left |
| `SHRI` | `SHR-CL` | Logical (unsigned) shift right |
| `SARI` | `SAR-CL` | Arithmetic (signed) shift right |
| `ROLI` | `ROL-CL` | Rotate left |
| `RORI` | `ROR-CL` | Rotate right |

---

### Condition Codes, `SETcc`, & `CMOVcc`

Condition code constants (`0..15`) used by `IF,`, `WHILE,`, `UNTIL,`, `SETCC`, `CMOVCC`, and `JCC`:

| Constant(s) | Value | Meaning |
| :--- | :-: | :--- |
| `O=` / `NO=` | `0` / `1` | Overflow / Not overflow |
| `B=` `C=` / `AE=` `NC=` | `2` / `3` | Unsigned `<` (Below/Carry) / Unsigned `>=` (Above or Equal) |
| `E=` `Z=` / `NE=` `NZ=` | `4` / `5` | Equal (Zero) / Not Equal (Not Zero) |
| `BE=` / `A=` | `6` / `7` | Unsigned `<=` (Below or Equal) / Unsigned `>` (Above) |
| `S=` / `NS=` | `8` / `9` | Sign (Negative) / Not Sign (Non-negative) |
| `P=` / `NP=` | `10` / `11` | Parity Even / Parity Odd |
| `L=` / `GE=` | `12` / `13` | Signed `<` (Less) / Signed `>=` (Greater or Equal) |
| `LE=` / `G=` | `14` / `15` | Signed `<=` (Less or Equal) / Signed `>` (Greater) |

* **Conditional Byte Set `( reg -- )`**: `SETE`/`SETZ`, `SETNE`/`SETNZ`, `SETL`, `SETG`, `SETLE`, `SETGE`, `SETB`, `SETA` (sets the low 8-bit register of `reg` to `0` or `1`).
* **Conditional Move `( dst src -- )`**: `CMOVE.`/`CMOVZ`, `CMOVNE`/`CMOVNZ`, `CMOVL`, `CMOVG`, `CMOVLE`, `CMOVGE`, `CMOVB`, `CMOVA`.

---

### Labels, Branches, & Subroutine Calls

Each `ASM-BEGIN ... ASM-END` (or `NATIVE: ... ;NATIVE`) block provides **64 local labels (`0` to `63`)** and up to **128 forward-reference fixups**:
* `<id> L:` defines label `<id>` at the current `ASM-PC` and immediately patches any earlier forward jumps, calls, or `LEA-LBL` instructions targeting `<id>`.
* `<id> JMP` emits `jmp rel32` to label `<id>`.
* `<id> CALL` emits `call rel32` to label `<id>`.
* Conditional jumps `( id -- )`:
  * Signed: `JL`, `JG`, `JLE`, `JGE`
  * Unsigned: `JB` (`JC`), `JA`, `JBE`, `JAE` (`JNC`)
  * Equality / Sign / Overflow: `JE` (`JZ`), `JNE` (`JNZ`), `JS`, `JNS`, `JO`, `JNO`
* Indirect jumps & calls `( reg -- )`:
  * `<reg> JMP-R` (`jmp r64`)
  * `<reg> CALL-R` (`call r64`)
* Return:
  * `RET` (`ret`)

> Because `JMP`, `CALL`, `Jcc`, and `LEA-LBL` all emit RIP-relative 32-bit offsets, code written with them is **100% position-independent** and can be saved with `ASM-SAVE` and loaded at any address (`NATIVE-BASE` or elsewhere) without relocation.

---

### Structured Control Flow

In addition to numbered labels, `asm.f` provides Forth-style structured control flow words that resolve offsets on the Forth stack at assembly time and can be nested arbitrarily:

1. **Conditional (`IF, ... ELSE, ... THEN,`)**:
   ```forth
   RAX RBX CMP
   G= IF,
       ( executed when RAX > RBX )
   ELSE,
       ( executed when RAX <= RBX )
   THEN,
   ```
2. **Pre-tested Loop (`BEGIN, ... WHILE, ... REPEAT,`)**:
   ```forth
   BEGIN,
       RDI RDI TEST
   G= WHILE,
       ( loop body while RDI > 0 )
       RDI DEC
   REPEAT,
   ```
3. **Post-tested Loop (`BEGIN, ... UNTIL,`) & Infinite Loop (`BEGIN, ... AGAIN,`)**:
   ```forth
   BEGIN,
       RCX DEC
       RCX RCX TEST
   Z= UNTIL,      ( loops until RCX == 0 )
   ```

---

### String, I/O, System, & Data Directives

* **System & CPU**: `NOP`, `CLD`, `STD.`, `CLI`, `STI`, `HLT`, `PAUSE`, `RDTSC`, `CPUID`, `IRETQ`, `<imm8> INT`
* **String Primitives**: `REP`, `MOVSB`, `MOVSQ`, `STOSB`, `STOSW`, `STOSD`, `STOSQ`, `LODSB`, `LODSQ`
  * Example: `CLD  REP STOSQ` emits `FC F3 48 AB`.
* **Port I/O**:
  * DX-addressed (`AL`/`AX`/`EAX` and `DX`): `INB-DX`, `INW-DX`, `IND-DX`, `OUTB-DX`, `OUTW-DX`, `OUTD-DX`
  * Immediate 8-bit port: `<port8> INB-IMM`, `<port8> OUTB-IMM`
* **Data Emission & Alignment**:
  * `<byte> B,` (or `DB,`), `<word16> W,` (or `DW,`), `<dword32> D,` (or `DD,`), `<qword64> Q,` (or `DQ,`)
  * `<addr> <len> BYTES,` (copy raw bytes into the code stream)
  * `<addr> <len> CSTR,` (embed a NUL-terminated string into the code stream)
  * `<power-of-2> ALIGN,` (pad `ASM-PC` to an `n`-byte boundary using `0x90` `NOP`s)

---

## 6. Complete Examples

### Example 1: Iterative 64-bit Fibonacci (`NATIVE: ... ;NATIVE`)
```forth
INCLUDE asm.f

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

83 NATIVE-FIB .              ( prints 99194853094755497 )
```

### Example 2: Standalone Binary with Boot Block & `KSERVICES` (DOOM Pattern)
This example assembles a position-independent binary that reads the kernel tick counter via `KSERVICES`, sums a 64-bit array using SIB indexed addressing (`LDQ-X`), adds an embedded RIP-relative constant (`LEA-LBL`), saves the binary to disk (`demo.bin`), loads it to `NATIVE-BASE`, and runs it via `CALL-NATIVE`:

```forth
4 CELLS ALLOT CONSTANT DEMO-BOOT
5 CELLS ALLOT CONSTANT DEMO-ARR
10 DEMO-ARR 0 CELLS + !
20 DEMO-ARR 1 CELLS + !
30 DEMO-ARR 2 CELLS + !
40 DEMO-ARR 3 CELLS + !
50 DEMO-ARR 4 CELLS + !

ASM-BEGIN
    RBX PUSH

    ( Read KSERVICES from [rdi+0], then systimer_ticks ptr from [ksvc+8] )
    RAX RDI 0 LDQ
    RAX RAX 8 LDQ
    RAX RAX 0 LDQ
    RDI 24 RAX STQ           ( store current ticks into [rdi+24] )

    ( Sum the array at [rdi+8] of length [rdi+16] )
    RBX RDI 8 LDQ
    RDX RDI 16 LDQ
    RAX RAX XOR.
    RCX RCX XOR.

    0 L:
    RCX RDX CMP
    1 JGE
    R8 RBX RCX 8 0 LDQ-X     ( r8 = [rbx + rcx*8] )
    RAX R8 ADD
    RCX INC
    0 JMP

    1 L:
    RSI 2 LEA-LBL            ( rsi = address of embedded constant at label 2 )
    R8 RSI 0 LDQ
    RAX R8 ADD

    RBX POP
    RET

    8 ALIGN,
    2 L:
    1000 DQ,
ASM-END

ASM-SAVE demo.bin

( Populate boot block and run via LOAD-BIN + CALL-NATIVE )
KSERVICES DEMO-BOOT 0 CELLS + !
DEMO-ARR  DEMO-BOOT 1 CELLS + !
5         DEMO-BOOT 2 CELLS + !
0         DEMO-BOOT 3 CELLS + !

NATIVE-BASE LOAD-BIN demo.bin DROP
DEMO-BOOT NATIVE-BASE NATIVE-STACK CALL-NATIVE .   ( prints 1150 )
DEMO-BOOT 3 CELLS + @ .                            ( prints PIT tick count )
```

---

## 7. Notes & Tips for f64OS
* **`INCLUDE` Buffer Limit**: In `kernel/f64.f`, `INCLUDE` uses a single 32 KiB buffer (`INC-BUF`) and cannot be nested inside another `INCLUDE`d file. Always run `INCLUDE asm.f` at the prompt before `INCLUDE`ing your own `.f` assembly files.
* **Inspecting Disassembly**: Use `ASM-DUMP` after `ASM-END` or `;NATIVE` to view a hex dump of the emitted machine code alongside its memory addresses.
* **Persisting `.bin` Files Across Host Rebuilds**: Just like DOOM savegames, files written at runtime via `ASM-SAVE` are stored in the `os.bin` disk image sectors.
