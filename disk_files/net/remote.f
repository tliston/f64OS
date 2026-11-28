( f64OS Remote Telnet REPL & Network File Transfer - remote.f )
( Prerequisite: INCLUDE /net.f - Note: This is now handled!)

DECIMAL

HERE @ LATEST @
CONSTANT REM-ORIG-LATEST
CONSTANT REM-ORIG-HERE

: ENSURE-NET ( -- )
    S" TCP-ACCEPT" FIND 0= IF
        ." /net/net.f not loaded; loading /net.f..." CR
        REM-ORIG-LATEST LATEST !
        REM-ORIG-HERE   HERE !
        INCLUDE
        10 BUFFTOP @ C!
        1 BUFFTOP +!
        S" INCLUDE /net/remote.f" BUFFTOP @ SWAP DUP >R CMOVE
        R> BUFFTOP +!
        10 BUFFTOP @ C!
        1 BUFFTOP +!
    ELSE
        WORD 2DROP
    THEN
;

ENSURE-NET /net/net.f

32768 ALLOT CONSTANT REM-OUT-BUF
256   ALLOT CONSTANT REM-IN-BUF
64    ALLOT CONSTANT REM-RX-TMP

0 VALUE REM-IN-LEN
0 VALUE REM-IAC
0 VALUE FL-OFF
0 VALUE FL-CHUNK

: TELNET-FLUSH ( -- )
    EMIT-LEN @ 0<= IF 0 EMIT-LEN ! EXIT THEN
    0 TO FL-OFF
    BEGIN
        FL-OFF EMIT-LEN @ <
    WHILE
        EMIT-LEN @ FL-OFF - 1024 MIN TO FL-CHUNK
        REM-OUT-BUF FL-OFF +  FL-CHUNK  TCP-SEND
        FL-CHUNK +TO FL-OFF
    REPEAT
    0 EMIT-LEN !
;

: TELNET-FILTER ( b -- char | 0 )
    REM-IAC 1 = IF
        DUP 251 255 WITHIN IF DROP 2 TO REM-IAC 0 EXIT THEN
        DUP 250 = IF DROP 3 TO REM-IAC 0 EXIT THEN
        DROP 0 TO REM-IAC 0 EXIT
    THEN
    REM-IAC 2 = IF
        DROP 0 TO REM-IAC 0 EXIT
    THEN
    REM-IAC 3 = IF
        240 = IF 0 TO REM-IAC THEN
        0 EXIT
    THEN
    DUP 255 = IF
        DROP 1 TO REM-IAC 0 EXIT
    THEN
;

: TELNET-READ-LINE ( -- flag )
    0 TO REM-IN-LEN
    0 TO REM-IAC
    BEGIN
        TCP-STATE TCP-ESTABLISHED =  TCP-RX-LEN 0> OR
    WHILE
        NET-KEY? IF
            KEY-RAW DROP FALSE EXIT
        THEN
        REM-RX-TMP 1 20 TCP-RECV 1 = IF
            REM-RX-TMP C@ TELNET-FILTER
            DUP 10 = IF
                DROP
                10 REM-IN-BUF REM-IN-LEN + C!
                0 EMIT-CAP !
                REM-IN-BUF REM-IN-LEN TELL CR
                REM-OUT-BUF EMIT-CAP !
                1 +TO REM-IN-LEN
                REM-IN-BUF CURRKEY !
                REM-IN-BUF REM-IN-LEN + BUFFTOP !
                TRUE EXIT
            ELSE DUP 8 = OVER 127 = OR IF
                DROP
                REM-IN-LEN 0> IF -1 +TO REM-IN-LEN THEN
            ELSE DUP 32 127 WITHIN IF
                REM-IN-LEN 250 < IF
                    REM-IN-BUF REM-IN-LEN + C!
                    1 +TO REM-IN-LEN
                ELSE
                    DROP
                THEN
            ELSE
                DROP
            THEN THEN THEN
        THEN
    REPEAT
    FALSE
;

: TELNET-STOP ( -- )
    TELNET-FLUSH
    0 EMIT-CAP !
    0 EMIT-LEN !
    TCP-CLOSE
    ['] REPL-STEP S" QUIT" FIND >DFA 16 + !
    ." [Telnet session closed]" CR
;

: TBYE ( -- )
    ." Goodbye from f64OS!" CR
    TELNET-STOP
;

: TELNET-REPL-STEP ( -- )
    BEGIN
        SKIP-BUF-WS
        CURRKEY @ BUFFTOP @ >=
    WHILE
        PROMPT
        TELNET-FLUSH
        TELNET-READ-LINE NOT IF
            TELNET-STOP EXIT
        THEN
    REPEAT
    INTERPRET
;

: TELNETD ( port -- )
    TCP-ACCEPT NOT IF EXIT THEN
    0 EMIT-LEN !
    REM-OUT-BUF EMIT-CAP !
    ." f64OS Remote Forth REPL (type TBYE to disconnect)" CR
    ['] TELNET-REPL-STEP S" QUIT" FIND >DFA 16 + !
;

524288 CONSTANT XFER-MAX
XFER-MAX ALLOT CONSTANT XFER-BUF
0 VALUE XFER-LEN
0 VALUE XFER-LBA

: NET-RECV ( port "filepath" -- )
    TCP-ACCEPT NOT IF WORD 2DROP EXIT THEN
    0 TO XFER-LEN
    BEGIN
        XFER-LEN XFER-MAX <
    WHILE
        XFER-BUF XFER-LEN +  XFER-MAX XFER-LEN -  200  TCP-RECV
        ?DUP 0> IF
            +TO XFER-LEN
        ELSE
            TCP-CLOSE
            ." Received " XFER-LEN . ." bytes." CR
            XFER-BUF XFER-LEN WRITE-FILE
            EXIT
        THEN
    REPEAT
    TCP-CLOSE
    ." Buffer full (" XFER-LEN . ." bytes)." CR
    XFER-BUF XFER-LEN WRITE-FILE
;

: NET-SEND ( port "filepath" -- )
    WORD ENTER-PATH-DIR NOT IF 2DROP DROP EXIT THEN
    DUP 0= IF 2DROP DROP ORIG-CWD TO CWD-LBA ." File not found" CR EXIT THEN
    FIND-ENTRY
    ORIG-CWD TO CWD-LBA
    ?DUP 0= IF DROP ." File not found" CR EXIT THEN
    DUP DE-DIR? IF 2DROP ." Is a directory" CR EXIT THEN
    DUP DE-LBA TO XFER-LBA
    DE-SIZE TO XFER-LEN
    TCP-ACCEPT NOT IF EXIT THEN
    0 TO FL-OFF
    BEGIN
        FL-OFF XFER-LEN <
    WHILE
        XFER-LBA FL-OFF 512 / +  SEC-BUF  SECTOR@
        XFER-LEN FL-OFF - 512 MIN TO FL-CHUNK
        SEC-BUF FL-CHUNK TCP-SEND
        FL-CHUNK +TO FL-OFF
    REPEAT
    TCP-CLOSE
    ." Sent " XFER-LEN . ." bytes." CR
;

: HTTP-BODY-OFFSET ( -- offset )
    XFER-LEN 4 >= IF
        XFER-LEN 3 - 0 DO
            XFER-BUF I +
            DUP C@ 13 =
            OVER 1+ C@ 10 = AND
            OVER 2 + C@ 13 = AND
            SWAP 3 + C@ 10 = AND IF
                I 4 + UNLOOP EXIT
            THEN
        LOOP
    THEN
    0
;

: HTTP-FETCH ( dst-ip port path-addr path-len "filepath" -- )
    2SWAP
    ." Connecting to " OVER .IP ." :" DUP . CR
    TCP-CONNECT NOT IF
        2DROP WORD 2DROP ." Connection failed." CR EXIT
    THEN
    0 TO HTTP-RLEN
    S" GET " HTTP-ADD
    HTTP-ADD
    S"  HTTP/1.0" HTTP-ADD
    13 HTTP-REQ HTTP-RLEN + C!  1 +TO HTTP-RLEN
    10 HTTP-REQ HTTP-RLEN + C!  1 +TO HTTP-RLEN
    S" Host: f64OS" HTTP-ADD
    13 HTTP-REQ HTTP-RLEN + C!  1 +TO HTTP-RLEN
    10 HTTP-REQ HTTP-RLEN + C!  1 +TO HTTP-RLEN
    13 HTTP-REQ HTTP-RLEN + C!  1 +TO HTTP-RLEN
    10 HTTP-REQ HTTP-RLEN + C!  1 +TO HTTP-RLEN

    HTTP-REQ HTTP-RLEN TCP-SEND
    0 TO XFER-LEN
    BEGIN
        XFER-LEN XFER-MAX <
    WHILE
        XFER-BUF XFER-LEN +  XFER-MAX XFER-LEN -  200  TCP-RECV
        ?DUP 0> IF
            +TO XFER-LEN
        ELSE
            TCP-CLOSE
            HTTP-BODY-OFFSET
            XFER-BUF OVER +
            XFER-LEN ROT -
            DUP ." Saving " . ." bytes..." CR
            WRITE-FILE
            EXIT
        THEN
    REPEAT
    TCP-CLOSE
    HTTP-BODY-OFFSET
    XFER-BUF OVER +
    XFER-LEN ROT -
    WRITE-FILE
;

: REMOTE-UNLOAD ( -- )
    0 EMIT-CAP !
    0 EMIT-LEN !
    ['] REPL-STEP S" QUIT" FIND >DFA 16 + !
    REM-ORIG-LATEST LATEST !
    REM-ORIG-HERE   HERE !
    ." Remote tools unloaded (" UNUSED . ." cells free)" CR
;

." Remote tools ready: <port> TELNETD, <port> NET-RECV <file>," CR
." <port> NET-SEND <file>, HTTP-FETCH. Use REMOTE-UNLOAD to" CR
." unload and free allocated cells." CR
