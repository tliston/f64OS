( f64OS Z-Machine Interpreter [v1-v5, v7-v8] - zmachine.f )
( This is part 1 of 2, zm1.f                              )

DECIMAL
HERE @ LATEST @
CONSTANT ZM-ORIG-LATEST
CONSTANT ZM-ORIG-HERE

( --- Bitwise Shift & 16-bit Signed Helpers --------------------------- )
: ZLSHIFT ( x n -- x<<n )
  DUP 0> IF 0 DO DUP + LOOP ELSE DROP THEN
;

: Z1RSHIFT ( u -- u>>1 )
  DUP 0< IF
    1 63 ZLSHIFT INVERT AND 2 / 1 62 ZLSHIFT OR
  ELSE
    2 /
  THEN
;

: ZRSHIFT ( u n -- u>>n )
  DUP 0> IF 0 DO Z1RSHIFT LOOP ELSE DROP THEN
;

: Z-U16 ( n -- u16 ) 65535 AND ;

: Z-SIGN ( u16 -- s64 )
  65535 AND DUP 32768 >= IF 65536 - THEN
;

: Z-ABS ( n -- u ) DUP 0< IF NEGATE THEN ;

: Z-BLANK ( addr len -- )
  DUP 0> IF 0 DO 32 OVER I + C! LOOP THEN DROP
;

: Z-BE16! ( u16 c-addr -- )
  OVER 8 ZRSHIFT 255 AND OVER C!
  1+ SWAP 255 AND SWAP C!
;

( Division and Modulo matching Z-Machine truncated signed 16-bit semantics )
: Z-DIV ( a b -- q )
  DUP 0= IF 2DROP 0 EXIT THEN
  >R Z-SIGN R> Z-SIGN / Z-U16
;

: Z-MOD ( a b -- r )
  DUP 0= IF 2DROP 0 EXIT THEN
  >R Z-SIGN R> Z-SIGN
  2DUP / * - Z-U16
;

( --- Z-Machine Memory & State Buffers -------------------------------- )
524288 ALLOT CONSTANT Z-MEM
65536  ALLOT CONSTANT Z-UNDO-MEM
4096   CELLS ALLOT CONSTANT Z-STACK
16     CELLS ALLOT CONSTANT Z-LOCALS

( Call stack: 64 frames * 24 cells per frame )
1536   CELLS ALLOT CONSTANT Z-FRAMES
256    CELLS ALLOT CONSTANT Z-UNDO-STATE
0 VALUE Z-FILE-LBA
0 VALUE Z-FILE-SIZE
0 VALUE Z-VER
0 VALUE Z-PC
0 VALUE Z-SP
0 VALUE Z-FP
0 VALUE Z-NARGS
0 VALUE Z-NLOCALS
0 VALUE Z-RUNNING
0 VALUE Z-LOADED
0 VALUE Z-HAS-UNDO
0 VALUE Z-DICT-BASE
0 VALUE Z-OBJ-BASE
0 VALUE Z-GLOB-BASE
0 VALUE Z-STAT-BASE
0 VALUE Z-ABBR-BASE

( Instruction operands: up to 8 operands )
8 CELLS ALLOT CONSTANT Z-OPS
8 CELLS ALLOT CONSTANT Z-OTYPES
0 VALUE Z-NOPS

: Z-OP@ ( i -- val ) CELLS Z-OPS + @ ;

: Z-OP! ( val i -- ) CELLS Z-OPS + ! ;

: OP0 ( -- val ) 0 Z-OP@ ;

: OP1 ( -- val ) 1 Z-OP@ ;

: OP2 ( -- val ) 2 Z-OP@ ;

: OP3 ( -- val ) 3 Z-OP@ ;

( --- Story Memory Accessors ------------------------------------------ )

: Z-B@ ( zaddr -- u8 ) 524287 AND Z-MEM + C@ ;

: Z-B! ( u8 zaddr -- ) 524287 AND Z-MEM + C! ;

: Z-W@ ( zaddr -- u16 )
  DUP Z-B@ 256 * SWAP 1+ Z-B@ OR
;

: Z-W! ( u16 zaddr -- )
  OVER 8 ZRSHIFT 255 AND OVER Z-B!
  1+ SWAP 255 AND SWAP Z-B!
;

: Z-PC@B ( -- u8 )
  Z-PC Z-B@  1 +TO Z-PC
;

: Z-PC@W ( -- u16 )
  Z-PC Z-W@  2 +TO Z-PC
;

: Z-UNPACK ( paddr -- addr )
  Z-U16
  Z-VER 3 <= IF 2 *
  ELSE Z-VER 8 = IF 8 *
  ELSE 4 * THEN THEN
;

: Z-UNPACK-R ( paddr -- addr )
  Z-UNPACK Z-VER 7 = IF 40 Z-W@ 8 * + THEN
;

: Z-UNPACK-S ( paddr -- addr )
  Z-UNPACK Z-VER 7 = IF 42 Z-W@ 8 * + THEN
;

( --- Evaluation Stack & Variables ------------------------------------ )
: Z-PUSH ( u16 -- )
  Z-U16 Z-SP CELLS Z-STACK + !
  1 +TO Z-SP
;

: Z-POP ( -- u16 )
  Z-SP 0> IF
    -1 +TO Z-SP
    Z-SP CELLS Z-STACK + @
  ELSE
    0
  THEN
;

: Z-VAR@ ( var -- u16 )
  255 AND
  DUP 0= IF
    DROP Z-POP
  ELSE DUP 16 < IF
    1- CELLS Z-LOCALS + @
  ELSE
    16 - 2 * Z-GLOB-BASE + Z-W@
  THEN THEN
;

: Z-VAR! ( u16 var -- )
  255 AND
  SWAP Z-U16 SWAP
  DUP 0= IF
    DROP Z-PUSH
  ELSE DUP 16 < IF
    1- CELLS Z-LOCALS + !
  ELSE
    16 - 2 * Z-GLOB-BASE + Z-W!
  THEN THEN
;

( Indirect variable peek/poke: var 0 reads/writes TOS in-place )
: Z-PEEK ( var -- u16 )
  255 AND
  DUP 0= IF
    DROP Z-SP 0> IF Z-SP 1- CELLS Z-STACK + @ ELSE 0 THEN
  ELSE
    Z-VAR@
  THEN
;

: Z-POKE ( u16 var -- )
  255 AND
  DUP 0= IF
    DROP Z-U16
    Z-SP 0> IF Z-SP 1- CELLS Z-STACK + ! ELSE Z-PUSH THEN
  ELSE
    Z-VAR!
  THEN
;

: Z-STORE ( val -- ) Z-PC@B Z-VAR! ;

( --- Screen, Status Bar, Word-Wrap, and Output Streams --------------- )
0 VALUE Z-WIN
0 VALUE Z-UPPER-H
0 VALUE Z-UX
1 VALUE Z-UY
0 VALUE Z-COL
0 VALUE Z-ROW-COUNT
1 VALUE Z-BUF-MODE
0 VALUE Z-STYLE

( Output stream 3 [memory table stack, up to 16 levels] )
16 CELLS ALLOT CONSTANT Z-STR3-TAB
16 CELLS ALLOT CONSTANT Z-STR3-POS
0 VALUE Z-STR3-DEPTH

( Word-wrap buffer for lower window )
80 ALLOT CONSTANT WRAP-BUF
0 VALUE WRAP-LEN

( Status bar render buffer on VGA Row 1: 0xB8000 + 160 = 753824 )
0 VALUE Z-SB-MODE
0 VALUE Z-SB-X
80 ALLOT CONSTANT Z-SB-BUF

: Z-CLEAR-ROW1 ( -- )
  80 0 DO
    32 753824 I 2 * + C!
    15 753825 I 2 * + C!
  LOOP
;

: Z-DRAW-ROW1 ( -- )
  80 0 DO
    Z-SB-BUF I + C@  753824 I 2 * + C!
    112              753825 I 2 * + C!
  LOOP
;

: Z-RAW-NL ( -- )
  Z-CLEAR-ROW1
  CR
  0 TO Z-COL
  Z-SB-BUF C@ 0<> IF Z-DRAW-ROW1 THEN
  1 +TO Z-ROW-COUNT
  Z-ROW-COUNT 21 >= IF
    0 TO Z-ROW-COUNT
    ." [MORE]"
    KEY-RAW DROP
    6 0 DO 8 EMIT LOOP
    6 0 DO 32 EMIT LOOP
    6 0 DO 8 EMIT LOOP
  THEN
;

: Z-FLUSH-WRAP ( -- )
  WRAP-LEN 0> IF
    Z-COL WRAP-LEN + 79 > IF
      Z-RAW-NL
    THEN
    WRAP-LEN 0 DO
      WRAP-BUF I + C@ EMIT
    LOOP
    WRAP-LEN +TO Z-COL
    0 TO WRAP-LEN
  THEN
;

: Z-EMIT ( c -- )
  ( 1. If Stream 3 [memory table] is active, write exclusively to it )
  Z-STR3-DEPTH 0> IF
    DUP 10 = IF DROP 13 THEN
    Z-STR3-DEPTH 1- CELLS Z-STR3-POS + @
    TUCK Z-B!
    1+ Z-STR3-DEPTH 1- CELLS Z-STR3-POS + !
    EXIT
  THEN
  ( 2. If status-bar capture mode is active, write to Z-SB-BUF )
  Z-SB-MODE IF
    Z-SB-X 80 < OVER 32 >= AND IF
      Z-SB-BUF Z-SB-X + C!
      1 +TO Z-SB-X
    ELSE
      DROP
    THEN
    EXIT
  THEN
  ( 3. Upper window [Z-WIN = 1]: direct coordinate output to VRAM )
  Z-WIN 1 = IF
    DUP 13 = OVER 10 = OR IF
      DROP 0 TO Z-UX
      Z-UY 24 < IF 1 +TO Z-UY THEN
    ELSE DUP 32 >= IF
      Z-UX 80 < IF
        Z-UY 1 = IF
          DUP Z-SB-BUF Z-UX + C!
        THEN
        753664 Z-UY 160 * + Z-UX 2 * +
        TUCK C!
        1+ Z-STYLE 1 AND Z-UY 1 = OR IF 112 ELSE 15 THEN SWAP C!
        1 +TO Z-UX
      ELSE
        DROP
      THEN
    ELSE
      DROP
    THEN THEN
    EXIT
  THEN
  ( 4. Lower window [Z-WIN = 0]: word-wrapped output )
  DUP 13 = OVER 10 = OR IF
    DROP Z-FLUSH-WRAP Z-RAW-NL
  ELSE DUP 32 = IF
    DROP Z-FLUSH-WRAP
    Z-COL 79 >= IF
      Z-RAW-NL
    ELSE
      32 EMIT 1 +TO Z-COL
    THEN
  ELSE DUP 32 >= IF
    Z-BUF-MODE IF
      WRAP-LEN 78 < IF
        WRAP-BUF WRAP-LEN + C!
        1 +TO WRAP-LEN
      ELSE
        Z-FLUSH-WRAP
        WRAP-BUF C!
        1 TO WRAP-LEN
      THEN
    ELSE
      EMIT 1 +TO Z-COL
    THEN
  ELSE
    DROP
  THEN THEN THEN
;

: Z-PRINT-NUM-STR ( n -- )
  DUP 0< IF
    45 Z-EMIT NEGATE
  THEN
  10 /MOD ?DUP IF RECURSE THEN
  48 + Z-EMIT
;

( --- ZSCII Text & Alphabet Decoder ----------------------------------- )
78 ALLOT CONSTANT Z-ALPHA-TAB

: INIT-Z-ALPHA ( -- )
  S" abcdefghijklmnopqrstuvwxyz" Z-ALPHA-TAB 0  + SWAP CMOVE
  S" ABCDEFGHIJKLMNOPQRSTUVWXYZ" Z-ALPHA-TAB 26 + SWAP CMOVE
  S"  ^0123456789.,!?_#'"        Z-ALPHA-TAB 52 + SWAP CMOVE
  34 Z-ALPHA-TAB 71 + C!
  S" /\-:()"                     Z-ALPHA-TAB 72 + SWAP CMOVE
;

INIT-Z-ALPHA
0 VALUE Z-PADDR
0 VALUE Z-SHIFT
0 VALUE Z-ABBR
0 VALUE Z-ESC
0 VALUE Z-ESC-HI

: Z-ALPHA@ ( row idx -- char )
  Z-VER 5 >= IF
    52 Z-W@ ?DUP IF
      SWAP 26 * + + Z-B@ EXIT
    THEN
  THEN
  SWAP 26 * + Z-ALPHA-TAB + C@
;

( Forward declaration for recursive abbreviation printing )
0 VALUE PRINT-ZSTR-XT
: Z-DECODE-ZC ( zc -- )
  Z-ESC 1 = IF
    32 * TO Z-ESC-HI
    2 TO Z-ESC
    0 TO Z-SHIFT
    EXIT
  THEN
  Z-ESC 2 = IF
    0 TO Z-ESC
    Z-ESC-HI OR Z-EMIT
    EXIT
  THEN
  Z-ABBR 0> IF
    Z-ABBR 1- 32 * + 2 * Z-ABBR-BASE + Z-W@ 2 *
    0 TO Z-ABBR
    0 TO Z-SHIFT
    Z-PADDR >R  Z-SHIFT >R  Z-ABBR >R  Z-ESC >R
    PRINT-ZSTR-XT EXECUTE DROP
    R> TO Z-ESC  R> TO Z-ABBR  R> TO Z-SHIFT  R> TO Z-PADDR
    EXIT
  THEN
  DUP 0= IF
    DROP 32 Z-EMIT 0 TO Z-SHIFT EXIT
  THEN
  DUP 4 < IF
    TO Z-ABBR 0 TO Z-SHIFT EXIT
  THEN
  DUP 4 = IF
    DROP 1 TO Z-SHIFT EXIT
  THEN
  DUP 5 = IF
    DROP 2 TO Z-SHIFT EXIT
  THEN
  Z-SHIFT 2 = OVER 6 = AND IF
    DROP 1 TO Z-ESC 0 TO Z-SHIFT EXIT
  THEN
  Z-SHIFT 2 = OVER 7 = AND IF
    DROP 0 TO Z-SHIFT 13 Z-EMIT EXIT
  THEN
  6 - Z-SHIFT SWAP Z-ALPHA@
  0 TO Z-SHIFT
  Z-EMIT
;

: Z-PRINT-ZSTR ( zaddr -- end-zaddr )
  TO Z-PADDR
  0 TO Z-SHIFT
  0 TO Z-ABBR
  0 TO Z-ESC
  BEGIN
    Z-PADDR Z-W@
    2 +TO Z-PADDR
    DUP 10 ZRSHIFT 31 AND Z-DECODE-ZC
    DUP 5  ZRSHIFT 31 AND Z-DECODE-ZC
    DUP            31 AND Z-DECODE-ZC
    32768 AND
  UNTIL
  Z-PADDR
;

: BIND-PRINT-ZSTR ( -- ) ['] Z-PRINT-ZSTR TO PRINT-ZSTR-XT ;
BIND-PRINT-ZSTR

( --- Object Table [v1-v3 and v4-v5] ---------------------------------- )
: OBJ-ENTRY ( obj -- zaddr )
  Z-VER 3 <= IF
    1- 9 * 62 + Z-OBJ-BASE +
  ELSE
    1- 14 * 126 + Z-OBJ-BASE +
  THEN
;

: OBJ-ATTR-ADDR ( obj attr -- byte-zaddr bit-mask )
  DUP 3 ZRSHIFT
  ROT OBJ-ENTRY +
  SWAP 7 AND 128 SWAP ZRSHIFT
;

: OBJ-TEST-ATTR ( obj attr -- flag )
  OVER 0= IF 2DROP FALSE EXIT THEN
  OBJ-ATTR-ADDR SWAP Z-B@ AND 0<>
;

: OBJ-SET-ATTR ( obj attr -- )
  OVER 0= IF 2DROP EXIT THEN
  OBJ-ATTR-ADDR OVER Z-B@ OR SWAP Z-B!
;

: OBJ-CLR-ATTR ( obj attr -- )
  OVER 0= IF 2DROP EXIT THEN
  OBJ-ATTR-ADDR INVERT OVER Z-B@ AND SWAP Z-B!
;

: OBJ-PARENT@ ( obj -- parent )
  DUP 0= IF EXIT THEN
  OBJ-ENTRY Z-VER 3 <= IF 4 + Z-B@ ELSE 6 + Z-W@ THEN
;

: OBJ-PARENT! ( parent obj -- )
  DUP 0= IF 2DROP EXIT THEN
  OBJ-ENTRY Z-VER 3 <= IF 4 + Z-B! ELSE 6 + Z-W! THEN
;

: OBJ-SIBLING@ ( obj -- sibling )
  DUP 0= IF EXIT THEN
  OBJ-ENTRY Z-VER 3 <= IF 5 + Z-B@ ELSE 8 + Z-W@ THEN
;

: OBJ-SIBLING! ( sibling obj -- )
  DUP 0= IF 2DROP EXIT THEN
  OBJ-ENTRY Z-VER 3 <= IF 5 + Z-B! ELSE 8 + Z-W! THEN
;

: OBJ-CHILD@ ( obj -- child )
  DUP 0= IF EXIT THEN
  OBJ-ENTRY Z-VER 3 <= IF 6 + Z-B@ ELSE 10 + Z-W@ THEN
;

: OBJ-CHILD! ( child obj -- )
  DUP 0= IF 2DROP EXIT THEN
  OBJ-ENTRY Z-VER 3 <= IF 6 + Z-B! ELSE 10 + Z-W! THEN
;

: OBJ-PROP-TAB ( obj -- zaddr )
  OBJ-ENTRY Z-VER 3 <= IF 7 + Z-W@ ELSE 12 + Z-W@ THEN
;

: OBJ-PRINT-NAME ( obj -- )
  DUP 0= IF DROP EXIT THEN
  OBJ-PROP-TAB DUP Z-B@ IF
    1+ Z-PRINT-ZSTR DROP
  ELSE
    DROP
  THEN
;

: OBJ-REMOVE ( obj -- )
  DUP 0= IF DROP EXIT THEN
  DUP OBJ-PARENT@ ?DUP 0= IF DROP EXIT THEN
  OVER OBJ-SIBLING@             ( obj parent sib )
  OVER OBJ-CHILD@               ( obj parent sib first-child )
  3 PICK = IF
    SWAP OBJ-CHILD!
  ELSE
    SWAP OBJ-CHILD@           ( obj sib cur )
    BEGIN
      DUP 0<>
    WHILE
      DUP OBJ-SIBLING@ 3 PICK = IF
        OVER SWAP OBJ-SIBLING!
        0
      ELSE
        OBJ-SIBLING@
      THEN
    REPEAT
    2DROP
  THEN
  0 OVER OBJ-PARENT!
  0 SWAP OBJ-SIBLING!
;

: OBJ-INSERT ( obj dest -- )
  OVER 0= OVER 0= OR IF 2DROP EXIT THEN
  OVER OBJ-REMOVE
  2DUP SWAP OBJ-PARENT!
  DUP OBJ-CHILD@ 2 PICK OBJ-SIBLING!
  OBJ-CHILD!
;

( Property table helpers for v1-v3 and v4-v5 )
: OBJ-FIRST-PROP ( obj -- paddr )
  OBJ-PROP-TAB DUP Z-B@ 2 * + 1+
;

: PROP-HDR ( paddr -- prop-num data-addr data-len )
  DUP Z-B@
  Z-VER 3 <= IF
    DUP 31 AND
    ROT 1+
    ROT 5 ZRSHIFT 1+
  ELSE
    DUP 63 AND
    SWAP DUP 128 AND IF
      DROP
      SWAP DUP 2 +
      SWAP 1+ Z-B@ 63 AND
      DUP 0= IF DROP 64 THEN
    ELSE
      64 AND IF 2 ELSE 1 THEN
      ROT 1+ SWAP
    THEN
  THEN
;

: OBJ-GET-PROP ( obj prop -- val )
  SWAP OBJ-FIRST-PROP
  BEGIN
    DUP Z-B@ 0<>
  WHILE
    PROP-HDR                  ( prop pnum daddr dlen )
    2 PICK 4 PICK = IF
      2SWAP 2DROP
      1 = IF Z-B@ ELSE Z-W@ THEN
      EXIT
    THEN
    2 PICK 4 PICK < IF
      2DROP DROP
      1- 2 * Z-OBJ-BASE + Z-W@ EXIT
    THEN
    + NIP
  REPEAT
  DROP
  1- 2 * Z-OBJ-BASE + Z-W@
;

: OBJ-PUT-PROP ( obj prop val -- )
  >R SWAP OBJ-FIRST-PROP
  BEGIN
    DUP Z-B@ 0<>
  WHILE
    PROP-HDR
    2 PICK 4 PICK = IF
      2SWAP 2DROP
      1 = IF R> SWAP Z-B! ELSE R> SWAP Z-W! THEN
      EXIT
    THEN
    + NIP
  REPEAT
  R> 2DROP DROP
;

: OBJ-GET-PROP-ADDR ( obj prop -- daddr | 0 )
  SWAP OBJ-FIRST-PROP
  BEGIN
    DUP Z-B@ 0<>
  WHILE
    PROP-HDR
    2 PICK 4 PICK = IF
      DROP NIP NIP EXIT
    THEN
    2 PICK 4 PICK < IF
      2DROP 2DROP 0 EXIT
    THEN
    + NIP
  REPEAT
  2DROP 0
;

: OBJ-GET-NEXT-PROP ( obj prop -- next-prop )
  DUP 0= IF
    DROP OBJ-FIRST-PROP Z-B@
    Z-VER 3 <= IF 31 AND ELSE 63 AND THEN
    EXIT
  THEN
  SWAP OBJ-FIRST-PROP
  BEGIN
    DUP Z-B@ 0<>
  WHILE
    PROP-HDR
    2 PICK 4 PICK = IF
      + Z-B@
      Z-VER 3 <= IF 31 AND ELSE 63 AND THEN
      NIP NIP EXIT
    THEN
    + NIP
  REPEAT
  2DROP 0
;

: PROP-DATA-LEN ( daddr -- len )
  DUP 0= IF EXIT THEN
  1- Z-B@
  Z-VER 3 <= IF
    5 ZRSHIFT 1+
  ELSE
    DUP 128 AND IF
      63 AND DUP 0= IF DROP 64 THEN
    ELSE
      64 AND IF 2 ELSE 1 THEN
    THEN
  THEN
;

( --- Status Line [v1-v3 SHOW-STATUS] --------------------------------- )
: SHOW-STATUS ( -- )
  Z-VER 3 > IF EXIT THEN
  Z-SB-BUF 80 Z-BLANK
  1 TO Z-SB-MODE
  0 TO Z-SB-X
  32 Z-EMIT
  16 Z-VAR@ ?DUP IF OBJ-PRINT-NAME THEN
  52 TO Z-SB-X
  1 Z-B@ 2 AND IF
    S" Time: " 0 DO DUP I + C@ Z-EMIT LOOP DROP
    17 Z-VAR@ Z-SIGN Z-PRINT-NUM-STR
    58 Z-EMIT
    18 Z-VAR@ Z-SIGN DUP 10 < IF 48 Z-EMIT THEN Z-PRINT-NUM-STR
  ELSE
    S" Score: " 0 DO DUP I + C@ Z-EMIT LOOP DROP
    17 Z-VAR@ Z-SIGN Z-PRINT-NUM-STR
    66 TO Z-SB-X
    S" Moves: " 0 DO DUP I + C@ Z-EMIT LOOP DROP
    18 Z-VAR@ Z-SIGN Z-PRINT-NUM-STR
  THEN
  0 TO Z-SB-MODE
  Z-DRAW-ROW1
;

( --- Dictionary Encoding, Lookup, and Tokenization ------------------- )
12 CELLS ALLOT CONSTANT ENC-Z
6  ALLOT CONSTANT ENC-BYTES
0 VALUE ENC-CNT
0 VALUE ENC-MAX

: ENC-PUSH ( zc -- )
  ENC-CNT ENC-MAX < IF
    ENC-CNT CELLS ENC-Z + !
    1 +TO ENC-CNT
  ELSE
    DROP
  THEN
;

: FIND-A2 ( char -- idx | -1 )
  -1
  26 2 DO
    2 I Z-ALPHA@ 2 PICK = IF
      DROP I 6 + LEAVE
    THEN
  LOOP
  NIP
;

: Z-ENCODE-WORD ( c-addr len -- )
  Z-VER 3 <= IF 6 ELSE 9 THEN TO ENC-MAX
  0 TO ENC-CNT
  12 0 DO 5 I CELLS ENC-Z + ! LOOP
  DUP 0> IF
    0 DO
      DUP I + C@
      DUP 97 123 WITHIN IF
        91 - ENC-PUSH
      ELSE
        DUP FIND-A2 DUP 0>= IF
          NIP 5 ENC-PUSH ENC-PUSH
        ELSE
          DROP
          5 ENC-PUSH 6 ENC-PUSH
          DUP 5 ZRSHIFT 31 AND ENC-PUSH
          31 AND ENC-PUSH
        THEN
      THEN
    LOOP
  THEN
  DROP
  0 CELLS ENC-Z + @ 10 ZLSHIFT
  1 CELLS ENC-Z + @ 5  ZLSHIFT OR
  2 CELLS ENC-Z + @ OR
  Z-VER 3 <= IF
    ENC-BYTES 0 + Z-BE16!
    3 CELLS ENC-Z + @ 10 ZLSHIFT
    4 CELLS ENC-Z + @ 5  ZLSHIFT OR
    5 CELLS ENC-Z + @ OR 32768 OR
    ENC-BYTES 2 + Z-BE16!
  ELSE
    ENC-BYTES 0 + Z-BE16!
    3 CELLS ENC-Z + @ 10 ZLSHIFT
    4 CELLS ENC-Z + @ 5  ZLSHIFT OR
    5 CELLS ENC-Z + @ OR
    ENC-BYTES 2 + Z-BE16!
    6 CELLS ENC-Z + @ 10 ZLSHIFT
    7 CELLS ENC-Z + @ 5  ZLSHIFT OR
    8 CELLS ENC-Z + @ OR 32768 OR
    ENC-BYTES 4 + Z-BE16!
  THEN
;

0 VALUE D-BASE
0 VALUE D-NSEP
0 VALUE D-ELEN
0 VALUE D-ECNT
0 VALUE D-EBASE
0 VALUE D-WBYTES

: Z-DICT-SETUP ( dict-addr -- )
  ?DUP 0= IF Z-DICT-BASE THEN
  TO D-BASE
  D-BASE Z-B@ TO D-NSEP
  D-BASE 1+ D-NSEP + Z-B@ TO D-ELEN
  D-BASE 2 + D-NSEP + Z-W@ Z-SIGN
  DUP 0< IF NEGATE THEN TO D-ECNT
  D-BASE 4 + D-NSEP + TO D-EBASE
  Z-VER 3 <= IF 4 ELSE 6 THEN TO D-WBYTES
;

: DICT-ENTRY-MATCH? ( eaddr -- flag )
  TRUE
  D-WBYTES 0 DO
    OVER I + Z-B@  ENC-BYTES I + C@  <> IF
      DROP FALSE LEAVE
    THEN
  LOOP
  NIP
;

: Z-DICT-FIND ( c-addr len dict-addr -- entry-zaddr | 0 )
  Z-DICT-SETUP
  Z-ENCODE-WORD
  D-ECNT 0> IF
    D-ECNT 0 DO
      D-EBASE I D-ELEN * +
      DUP DICT-ENTRY-MATCH? IF UNLOOP EXIT THEN
      DROP
    LOOP
  THEN
  0
;

: IS-DICT-SEP? ( char -- flag )
  FALSE
  D-NSEP 0> IF
    D-NSEP 0 DO
      D-BASE 1+ I + Z-B@ 2 PICK = IF
        DROP TRUE LEAVE
      THEN
    LOOP
  THEN
  NIP
;

0 VALUE TK-TEXT
0 VALUE TK-PARSE
0 VALUE TK-DICT
0 VALUE TK-FLAG
0 VALUE TK-MAX
0 VALUE TK-CNT
0 VALUE TK-POS
0 VALUE TK-END
0 VALUE TK-START

: TK-ADD-TOKEN ( start-off len -- )
  TK-CNT TK-MAX >= IF 2DROP EXIT THEN
  OVER TK-TEXT + Z-MEM + OVER TK-DICT Z-DICT-FIND
  DUP 0= TK-FLAG 0<> AND IF
    2DROP DROP
  ELSE
    TK-PARSE 2 + TK-CNT 4 * +
    DUP >R Z-W!
    R@ 2 + Z-B!
    R> 3 + Z-B!
  THEN
  1 +TO TK-CNT
;

INCLUDE /zm/zm2.f
