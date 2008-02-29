! Copyright (C) 2005, 2008 Slava Pestov.
! See http://factorcode.org/license.txt for BSD license.
USING: io.backend io.nonblocking io.unix.backend io.files io
       unix unix.stat kernel math continuations math.bitfields byte-arrays
       alien combinators combinators.cleave calendar ;

IN: io.unix.files

M: unix-io cwd
    MAXPATHLEN dup <byte-array> swap
    getcwd [ (io-error) ] unless* ;

M: unix-io cd
    chdir io-error ;

: read-flags O_RDONLY ; inline

: open-read ( path -- fd )
    O_RDONLY file-mode open dup io-error ;

M: unix-io (file-reader) ( path -- stream )
    open-read <reader> ;

: write-flags { O_WRONLY O_CREAT O_TRUNC } flags ; inline

: open-write ( path -- fd )
    write-flags file-mode open dup io-error ;

M: unix-io (file-writer) ( path -- stream )
    open-write <writer> ;

: append-flags { O_WRONLY O_APPEND O_CREAT } flags ; inline

: open-append ( path -- fd )
    append-flags file-mode open dup io-error
    [ dup 0 SEEK_END lseek io-error ] [ ] [ close ] cleanup ;

M: unix-io (file-appender) ( path -- stream )
    open-append <writer> ;

: touch-mode
    { O_WRONLY O_APPEND O_CREAT O_EXCL } flags ; foldable

M: unix-io touch-file ( path -- )
    touch-mode file-mode open
    dup 0 < [ err_no EEXIST = [ err_no io-error ] unless ] when
    close ;

M: unix-io move-file ( from to -- )
    rename io-error ;

M: unix-io delete-file ( path -- )
    unlink io-error ;

M: unix-io make-directory ( path -- )
    OCT: 777 mkdir io-error ;

M: unix-io delete-directory ( path -- )
    rmdir io-error ;

: (copy-file) ( from to -- )
    dup parent-directory make-directories
    <file-writer> [
        swap <file-reader> [
            swap stream-copy
        ] with-disposal
    ] with-disposal ;

M: unix-io copy-file ( from to -- )
    >r dup file-permissions over r> (copy-file) chmod io-error ;

: stat>type ( stat -- type )
    stat-st_mode {
        { [ dup S_ISREG  ] [ +regular-file+     ] }
        { [ dup S_ISDIR  ] [ +directory+        ] }
        { [ dup S_ISCHR  ] [ +character-device+ ] }
        { [ dup S_ISBLK  ] [ +block-device+     ] }
        { [ dup S_ISFIFO ] [ +fifo+             ] }
        { [ dup S_ISLNK  ] [ +symbolic-link+    ] }
        { [ dup S_ISSOCK ] [ +socket+           ] }
        { [ t            ] [ +unknown+          ] }
      } cond nip ;

M: unix-io file-info ( path -- info )
    stat* {
        [ stat>type ]
        [ stat-st_size ]
        [ stat-st_mode ]
        [ stat-st_mtim timespec-sec seconds unix-1970 time+ ]
    } cleave
    \ file-info construct-boa ;
