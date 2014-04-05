! Copyright (C) 2013 Jon Harper.
! See http://factorcode.org/license.txt for BSD license.
USING: accessors alien.data arrays assocs byte-arrays
classes.struct combinators combinators.extras
combinators.short-circuit destructors fry hashtables
hashtables.identity io.encodings.string io.encodings.utf8 kernel
libc linked-assocs locals make math math.parser namespaces
sequences sets strings yaml.conversion yaml.ffi ;
FROM: sets => set ;
IN: yaml

<PRIVATE

: yaml-assert-ok ( ? -- ) [ "yaml error" throw ] unless ;

TUPLE: yaml-alias anchor ;
C: <yaml-alias> yaml-alias
SYMBOL: anchors
: ?register-anchor ( obj event -- obj )
    dupd anchor>> [ anchors get set-at ] [ drop ] if* ;
: assert-anchor-exists ( anchor -- )
    anchors get at* nip
    [ "No previous anchor" throw ] unless ;

: deref-anchor ( event -- obj )
    data>> alias>> anchor>>
    [ assert-anchor-exists ]
    [ <yaml-alias> ] bi ;

: event>scalar ( event -- obj )
    data>> scalar>>
    [ construct-scalar ]
    [ ?register-anchor ] bi ;

! TODO simplify this ?!?
TUPLE: factor_sequence_start_event_data anchor tag implicit style ;
TUPLE: factor_mapping_start_event_data anchor tag implicit style ;
TUPLE: factor_event_data sequence_start mapping_start ;
TUPLE: factor_yaml_event_t type data start_mark end_mark ;
: deep-copy-seq ( data -- data' )
    { [ anchor>> clone ] [ tag>> clone ] [ implicit>> ] [ style>> ] } cleave
    factor_sequence_start_event_data boa ;
: deep-copy-map ( data -- data' )
    { [ anchor>> clone ] [ tag>> clone ] [ implicit>> ] [ style>> ] } cleave
    factor_mapping_start_event_data boa ;
: deep-copy-data ( event -- data )
    [ data>> ] [ type>> ] bi {
        { YAML_SEQUENCE_START_EVENT [ sequence_start>> deep-copy-seq f ] }
        { YAML_MAPPING_START_EVENT [ mapping_start>> deep-copy-map f swap ] }
        [ throw ]
    } case factor_event_data boa ;
: deep-copy-event ( event -- event' )
    { [ type>> ] [ deep-copy-data ] [ start_mark>> ] [ end_mark>> ] } cleave
    factor_yaml_event_t boa ;

: ?scalar-value ( event -- scalar/event scalar? )
    dup type>> {
        { YAML_SCALAR_EVENT [ event>scalar t ] }
        { YAML_ALIAS_EVENT [ deref-anchor t ] }
        [ drop deep-copy-event f ]
    } case ;

! Must not reuse the event struct before with-destructors scope ends
: next-event ( parser event -- event )
    [ yaml_parser_parse yaml-assert-ok ] [ &yaml_event_delete ] bi ;

DEFER: parse-sequence
DEFER: parse-mapping
: (parse-sequence) ( parser event prev-event -- obj )
    data>> sequence_start>> [ [ 2drop f ] dip ?register-anchor drop ]
    [ [ parse-sequence ] [ construct-sequence ] bi* ] [ 2nip ?register-anchor ] 3tri ;
: (parse-mapping) ( parser event prev-event -- obj )
    data>> mapping_start>> [ [ 2drop f ] dip ?register-anchor drop ]
    [ [ parse-mapping ] [ construct-mapping ] bi* ] [ 2nip ?register-anchor ] 3tri ;
: next-complex-value ( parser event prev-event -- obj )
    dup type>> {
        { YAML_SEQUENCE_START_EVENT [ (parse-sequence) ] }
        { YAML_MAPPING_START_EVENT [ (parse-mapping) ] }
        [ throw ]
    } case ;

:: next-value ( parser event -- obj )
    parser event [ next-event ?scalar-value ] with-destructors
    [ [ parser event ] dip next-complex-value ] unless ;

:: parse-mapping ( parser event -- map )
    [
        f :> done!
        [ done ] [
            [
                parser event next-event type>>
                YAML_MAPPING_END_EVENT = [
                    t done! f f
                ] [
                    event ?scalar-value
                ] if
            ] with-destructors
            done [ 2drop ] [
                [ [ parser event ] dip next-complex-value ] unless
                parser event next-value swap ,,
            ] if
        ] until
    ] H{ } make ;

:: parse-sequence ( parser event  -- seq )
    [
        f :> done!
        [ done ] [
            [
                parser event next-event type>>
                YAML_SEQUENCE_END_EVENT = [
                    t done! f f
                ] [
                    event ?scalar-value
                ] if
            ] with-destructors
            done [ 2drop ] [
              [ [ parser event ] dip next-complex-value ] unless ,
            ] if
        ] until
    ] { } make ;

: expect-event ( parser event type -- )
    [
        [ next-event type>> ] dip =
        [ "wrong event" throw ] unless
    ] with-destructors ;

GENERIC: (deref-aliases) ( anchors obj -- obj' )
M: object (deref-aliases) nip ;
M: byte-array (deref-aliases) nip ;
M: string (deref-aliases) nip ;
M: yaml-alias (deref-aliases) anchor>> swap at ;

M: sequence (deref-aliases)
    [ (deref-aliases) ] with map! ;
M: set (deref-aliases)
    [ members (deref-aliases) ] [ clear-set ] [ swap union! ] tri ;
: assoc-map! ( assoc quot -- )
    [ assoc-map ] [ drop clear-assoc ] [ drop swap assoc-union! ] 2tri ; inline
M: assoc (deref-aliases)
    swap '[ [ _ swap (deref-aliases) ] bi@ ] assoc-map! ;

:: parse-yaml-doc ( parser event -- obj )
    H{ } clone anchors [
        parser event next-value
        anchors get swap (deref-aliases)
    ] with-variable ;

:: ?parse-yaml-doc ( parser event -- obj/f ? )
    [
        parser event next-event type>> {
            { YAML_DOCUMENT_START_EVENT [ t ] }
            { YAML_STREAM_END_EVENT [ f ] }
            [ "wrong event" throw ]
        } case
    ] with-destructors
    [
        parser event parse-yaml-doc t
        parser event YAML_DOCUMENT_END_EVENT expect-event
    ] [ f f ] if ;

! registers destructors (use with with-destructors)
:: init-parser ( str -- parser event )
    yaml_parser_t (malloc-struct) &free :> parser
    parser yaml_parser_initialize yaml-assert-ok
    parser &yaml_parser_delete drop

    str utf8 encode
    [ malloc-byte-array &free ] [ length ] bi :> ( input length )
    parser input length yaml_parser_set_input_string

    yaml_event_t (malloc-struct) &free :> event
    parser event ;

PRIVATE>

: yaml> ( str -- obj )
    [
        init-parser
        [ YAML_STREAM_START_EVENT expect-event ]
        [ ?parse-yaml-doc [ "No Document" throw ] unless ] 2bi
    ] with-destructors ;

: yaml-docs> ( str -- arr )
    [
        init-parser
        [ YAML_STREAM_START_EVENT expect-event ]
        [ [ ?parse-yaml-doc ] 2curry [ ] produce nip ] 2bi
    ] with-destructors ;

<PRIVATE

TUPLE: yaml-anchors objects new-objects next-anchor ;
: <yaml-anchors> ( -- yaml-anchors )
    IH{ } clone IH{ } clone 0 yaml-anchors boa ;
GENERIC: (replace-aliases) ( yaml-anchors obj -- obj' )
: incr-anchor ( yaml-anchors -- current-anchor )
    [ next-anchor>> ] [
        [ [ number>string ] [ 1 + ] bi ]
        [ next-anchor<< ] bi*
    ] bi ;
:: ?replace-aliases ( yaml-anchors obj -- obj' )
    yaml-anchors objects>> :> objects
    obj objects at* [
        [ yaml-anchors incr-anchor dup obj objects set-at ] unless*
        <yaml-alias>
    ] [
        drop f obj objects set-at
        yaml-anchors obj (replace-aliases) :> obj'
        obj obj' yaml-anchors new-objects>> set-at
        obj'
    ] if ;

M: object (replace-aliases) nip ;
M: byte-array (replace-aliases) nip ;
M: string (replace-aliases) nip ;

M: sequence (replace-aliases)
    [ ?replace-aliases ] with map ;
M: set (replace-aliases) [ members (replace-aliases) ] keep set-like ;
M: assoc (replace-aliases)
    swap '[ [ _ swap ?replace-aliases ] bi@ ] assoc-map ;

TUPLE: yaml-anchor anchor obj ;
C: <yaml-anchor> yaml-anchor

GENERIC: (replace-anchors) ( yaml-anchors obj -- obj' )
: (get-anchor) ( yaml-anchors obj -- anchor/f ) swap objects>> at ;
: get-anchor ( yaml-anchors obj -- anchor/f )
    { [ (get-anchor) ] [ over new-objects>> at (get-anchor) ] } 2|| ;
: ?replace-anchors ( yaml-anchors obj -- obj' )
    [ (replace-anchors) ] [ get-anchor ] 2bi [ swap <yaml-anchor> ] when* ;
M: object (replace-anchors) nip ;
M: byte-array (replace-anchors) nip ;
M: string (replace-anchors) nip ;

M: sequence (replace-anchors)
    [ ?replace-anchors ] with map ;
M: set (replace-anchors) [ members ?replace-anchors ] keep set-like ;
M: assoc (replace-anchors)
    swap '[ [ _ swap ?replace-anchors ] bi@ ] assoc-map ;

: replace-identities ( obj -- obj' )
    [ <yaml-anchors> ] dip dupd ?replace-aliases ?replace-anchors ;

! TODO We can also pass some data when registering the write handler,
! use this to have several buffers if it can be interrupted.
! For now, only do operations on strings that are in memory
! so we don't need to be reentrant.
SYMBOL: yaml-write-buffer
: yaml-write-handler ( -- alien )
    [
        memory>byte-array yaml-write-buffer get-global
        push-all drop 1
    ] yaml_write_handler_t ;

GENERIC: emit-value ( emitter event anchor obj -- )
: emit-object ( emitter event obj -- ) [ f ] dip emit-value ;

:: emit-scalar ( emitter event anchor obj -- )
    event anchor
    obj [ yaml-tag ] [ represent-scalar ] bi
    -1 f f YAML_ANY_SCALAR_STYLE
    yaml_scalar_event_initialize yaml-assert-ok
    emitter event yaml_emitter_emit yaml-assert-ok ;

M: object emit-value ( emitter event anchor obj -- ) emit-scalar ;

M: yaml-anchor emit-value ( emitter event unused obj -- )
    nip [ anchor>> ] [ obj>> ] bi emit-value ;
M:: yaml-alias emit-value ( emitter event unused obj -- )
    event obj anchor>> yaml_alias_event_initialize yaml-assert-ok
    emitter event yaml_emitter_emit yaml-assert-ok ;

:: emit-sequence-start ( emitter event anchor tag -- )
    event anchor tag f YAML_ANY_SEQUENCE_STYLE
    yaml_sequence_start_event_initialize yaml-assert-ok
    emitter event yaml_emitter_emit yaml-assert-ok ;

: emit-sequence-end ( emitter event -- )
    dup yaml_sequence_end_event_initialize yaml-assert-ok
    yaml_emitter_emit yaml-assert-ok ;

: emit-sequence-body ( emitter event seq -- )
    [ emit-object ] with with each ;
: emit-assoc-body ( emitter event assoc -- )
    >alist concat emit-sequence-body ;
: emit-linked-assoc-body ( emitter event linked-assoc -- )
    >alist [ first2 swap associate ] map emit-sequence-body ;
: emit-set-body ( emitter event set -- )
    [ members ] [ cardinality f <array> ] bi zip concat emit-sequence-body ;

M: f emit-value ( emitter event anchor f -- ) emit-scalar ;
M: string emit-value ( emitter event anchor string -- ) emit-scalar ;
M: byte-array emit-value ( emitter event anchor byte-array -- ) emit-scalar ;
M: sequence emit-value ( emitter event anchor seq -- )
    [ drop YAML_SEQ_TAG emit-sequence-start ]
    [ nip emit-sequence-body ]
    [ 2drop emit-sequence-end ] 4tri ;
M: linked-assoc emit-value ( emitter event anchor assoc -- )
    [ drop YAML_OMAP_TAG emit-sequence-start ]
    [ nip emit-linked-assoc-body ]
    [ 2drop emit-sequence-end ] 4tri ;

:: emit-assoc-start ( emitter event anchor tag -- )
    event anchor tag f YAML_ANY_MAPPING_STYLE
    yaml_mapping_start_event_initialize yaml-assert-ok
    emitter event yaml_emitter_emit yaml-assert-ok ;

: emit-assoc-end ( emitter event -- )
    dup yaml_mapping_end_event_initialize yaml-assert-ok
    yaml_emitter_emit yaml-assert-ok ;

M: assoc emit-value ( emitter event anchor assoc -- )
    [ drop YAML_MAP_TAG emit-assoc-start ]
    [ nip emit-assoc-body ]
    [ 2drop emit-assoc-end ] 4tri ;
M: set emit-value ( emitter event anchor set -- )
    [ drop YAML_SET_TAG emit-assoc-start ]
    [ nip emit-set-body ]
    [ 2drop emit-assoc-end ] 4tri ;

! registers destructors (use with with-destructors)
:: init-emitter ( -- emitter event )
    yaml_emitter_t (malloc-struct) &free :> emitter
    emitter yaml_emitter_initialize yaml-assert-ok
    emitter &yaml_emitter_delete drop

    BV{ } clone :> output
    output yaml-write-buffer set-global
    emitter yaml-write-handler f yaml_emitter_set_output

    yaml_event_t (malloc-struct) &free :> event

    event YAML_UTF8_ENCODING
    yaml_stream_start_event_initialize yaml-assert-ok

    emitter event yaml_emitter_emit yaml-assert-ok
    emitter event ;

:: emit-doc ( emitter event obj -- )
    event f f f f yaml_document_start_event_initialize yaml-assert-ok
    emitter event yaml_emitter_emit yaml-assert-ok

    emitter event obj emit-object

    event f yaml_document_end_event_initialize yaml-assert-ok
    emitter event yaml_emitter_emit yaml-assert-ok ;

! registers destructors (use with with-destructors)
:: flush-emitter ( emitter event -- str )
    event yaml_stream_end_event_initialize yaml-assert-ok
    emitter event yaml_emitter_emit yaml-assert-ok

    emitter yaml_emitter_flush yaml-assert-ok
    yaml-write-buffer get utf8 decode ;

PRIVATE>

: >yaml ( obj -- str )
    [
        [ init-emitter ] dip
        [ replace-identities emit-doc ] [ drop flush-emitter ] 3bi
    ] with-destructors ;

: >yaml-docs ( seq -- str )
    [
        [ init-emitter ] dip
        [ [ replace-identities emit-doc ] with with each ] [ drop flush-emitter ] 3bi
    ] with-destructors ;