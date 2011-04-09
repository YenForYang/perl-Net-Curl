/* vim: ts=4:sw=4:ft=xs:fdm=marker: */
/*
 * Copyright 2011 (C) Przemyslaw Iskra <sparky at pld-linux.org>
 *
 * Loosely based on code by Cris Bailiff <c.bailiff+curl at devsecure.com>,
 * and subsequent fixes by other contributors.
 */


typedef enum {
	CB_MULTI_SOCKET = 0,
	CB_MULTI_TIMER,
	CB_MULTI_LAST,
} perl_curl_multi_callback_code_t;

struct perl_curl_multi_s {
	/* last seen version of this object */
	SV *perl_self;

	/* curl multi handle */
	CURLM *handle;

	/* list of callbacks */
	callback_t cb[ CB_MULTI_LAST ];

	/* list of data assigned to sockets */
	simplell_t *socket_data;
};

/* make a new multi */
static perl_curl_multi_t *
perl_curl_multi_new( void )
/*{{{*/ {
	perl_curl_multi_t *multi;
	Newxz( multi, 1, perl_curl_multi_t );
	multi->handle = curl_multi_init();
	return multi;
} /*}}}*/

/* delete the multi */
static void
perl_curl_multi_delete( pTHX_ perl_curl_multi_t *multi )
/*{{{*/ {
	perl_curl_multi_callback_code_t i;

	if ( multi->handle )
		curl_multi_cleanup( multi->handle );

	if ( multi->socket_data ) {
		simplell_t *next, *now = multi->socket_data;
		do {
			next = now->next;
			sv_2mortal( (SV *) now->value );
			Safefree( now );
		} while ( ( now = next ) != NULL );
	}

	for( i = 0; i < CB_MULTI_LAST; i++ ) {
		sv_2mortal( multi->cb[i].func );
		sv_2mortal( multi->cb[i].data );
	}

	Safefree( multi );
} /*}}}*/

static int
cb_multi_socket( CURL *easy_handle, curl_socket_t s, int what, void *userptr,
		void *socketp )
/*{{{*/ {
	dTHX;

	perl_curl_multi_t *multi;
	perl_curl_easy_t *easy;

	multi = (perl_curl_multi_t *) userptr;
	(void) curl_easy_getinfo( easy_handle, CURLINFO_PRIVATE, (void *) &easy );

	/* $multi, $easy, $socket, $what, $socketdata, $userdata */
	SV *args[] = {
		/* 0 */ newSVsv( multi->perl_self ),
		/* 1 */ newSVsv( easy->perl_self ),
		/* 2 */ newSVuv( s ),
		/* 3 */ newSViv( what ),
		/* 4 */ &PL_sv_undef
	};
	if ( socketp )
		args[4] = newSVsv( (SV *) socketp );

	return PERL_CURL_CALL( &multi->cb[ CB_MULTI_SOCKET ], args );
} /*}}}*/

static int
cb_multi_timer( CURLM *multi_handle, long timeout_ms, void *userptr )
/*{{{*/ {
	dTHX;

	perl_curl_multi_t *multi;
	multi = (perl_curl_multi_t *) userptr;

	/* $multi, $timeout, $userdata */
	SV *args[] = {
		newSVsv( multi->perl_self ),
		newSViv( timeout_ms )
	};

	return PERL_CURL_CALL( &multi->cb[ CB_MULTI_TIMER ], args );
} /*}}}*/


#define MULTI_DIE( ret )		\
	STMT_START {				\
		CURLMcode code = (ret);	\
		if ( code != CURLM_OK )	\
			die_code( "Multi", code ); \
	} STMT_END


MODULE = WWW::CurlOO	PACKAGE = WWW::CurlOO::Multi

INCLUDE: const-multi-xs.inc

PROTOTYPES: ENABLE

void
new( sclass="WWW::CurlOO::Multi", base=HASHREF_BY_DEFAULT )
	const char *sclass
	SV *base
	PREINIT:
		perl_curl_multi_t *multi;
		HV *stash;
	PPCODE:
		if ( ! SvOK( base ) || ! SvROK( base ) )
			croak( "object base must be a valid reference\n" );

		multi = perl_curl_multi_new();
		perl_curl_setptr( aTHX_ base, multi );

		stash = gv_stashpv( sclass, 0 );
		ST(0) = sv_bless( base, stash );

		multi->perl_self = newSVsv( ST(0) );
		sv_rvweaken( multi->perl_self );

		XSRETURN(1);


void
add_handle( multi, easy )
	WWW::CurlOO::Multi multi
	WWW::CurlOO::Easy easy
	PREINIT:
		CURLMcode ret;
	CODE:
		if ( easy->multi )
			croak( "Specified easy handle is attached to %s multi handle already",
				easy->multi == multi ? "this" : "another" );

		ret = curl_multi_add_handle( multi->handle, easy->handle );
		if ( !ret ) {
			/* XXX: add to handle list */
			easy->self_sv = newSVsv( easy->perl_self );
			easy->multi = multi;
		}
		MULTI_DIE( ret );

void
remove_handle( multi, easy )
	WWW::CurlOO::Multi multi
	WWW::CurlOO::Easy easy
	PREINIT:
		CURLMcode ret;
	CODE:
		CLEAR_ERRSV();
		if ( easy->multi != multi )
			croak( "Specified easy handle is not attached to %s multi handle",
				easy->multi ? "this" : "any" );

		ret = curl_multi_remove_handle( multi->handle, easy->handle );
		/* XXX: remove from handle list */
		sv_2mortal( easy->self_sv );
		easy->self_sv = NULL;
		easy->multi = NULL;

		/* rethrow errors */
		if ( SvTRUE( ERRSV ) )
			croak( NULL );

		MULTI_DIE( ret );


void
info_read( multi )
	WWW::CurlOO::Multi multi
	PREINIT:
		int queue;
		CURLMsg *msg;
	PPCODE:
		CLEAR_ERRSV();
		while ( (msg = curl_multi_info_read( multi->handle, &queue ) ) ) {
			/* most likely CURLMSG_DONE */
			if ( msg->msg != CURLMSG_NONE && msg->msg != CURLMSG_LAST ) {
				WWW__CurlOO__Easy easy;
				SV *errsv;

				curl_easy_getinfo( msg->easy_handle,
					CURLINFO_PRIVATE, (void *) &easy );

				EXTEND( SP, 3 );
				mPUSHs( newSViv( msg->msg ) );
				mPUSHs( newSVsv( easy->perl_self ) );

				errsv = sv_newmortal();
				sv_setref_iv( errsv, "WWW::CurlOO::Easy::Code",
					msg->data.result );
				PUSHs( errsv );

				/* cannot rethrow errors, because we want to make sure we
				 * return the easy, but $@ should be set */

				XSRETURN( 3 );
			}

			/* rethrow errors */
			if ( SvTRUE( ERRSV ) )
				croak( NULL );
		};

		/* rethrow errors */
		if ( SvTRUE( ERRSV ) )
			croak( NULL );

		XSRETURN_EMPTY;


void
fdset( multi )
	WWW::CurlOO::Multi multi
	PREINIT:
		CURLMcode ret;
		fd_set fdread, fdwrite, fdexcep;
		int maxfd, i;
		int readsize, writesize, excepsize;
		unsigned char readset[ sizeof( fd_set ) ] = { 0 };
		unsigned char writeset[ sizeof( fd_set ) ] = { 0 };
		unsigned char excepset[ sizeof( fd_set ) ] = { 0 };
	PPCODE:
		/* {{{ */
		FD_ZERO( &fdread );
		FD_ZERO( &fdwrite );
		FD_ZERO( &fdexcep );

		ret = curl_multi_fdset( multi->handle,
			&fdread, &fdwrite, &fdexcep, &maxfd );
		MULTI_DIE( ret );

		readsize = writesize = excepsize = 0;

		if ( maxfd != -1 ) {
			for ( i = 0; i <= maxfd; i++ ) {
				if ( FD_ISSET( i, &fdread ) ) {
					readsize = i / 8 + 1;
					readset[ i / 8 ] |= 1 << ( i % 8 );
				}
				if ( FD_ISSET( i, &fdwrite ) ) {
					writesize = i / 8 + 1;
					writeset[ i / 8 ] |= 1 << ( i % 8 );
				}
				if ( FD_ISSET( i, &fdexcep ) ) {
					excepsize = i / 8 + 1;
					excepset[ i / 8 ] |= 1 << ( i % 8 );
				}
			}
		}
		EXTEND( SP, 3 );
		mPUSHs( newSVpvn( (char *) readset, readsize ) );
		mPUSHs( newSVpvn( (char *) writeset, writesize ) );
		mPUSHs( newSVpvn( (char *) excepset, excepsize ) );
		/* }}} */


long
timeout( multi )
	WWW::CurlOO::Multi multi
	PREINIT:
		long timeout;
		CURLMcode ret;
	CODE:
		ret = curl_multi_timeout( multi->handle, &timeout );
		MULTI_DIE( ret );

		RETVAL = timeout;
	OUTPUT:
		RETVAL

void
setopt( multi, option, value )
	WWW::CurlOO::Multi multi
	int option
	SV *value
	PREINIT:
		CURLMcode ret1 = CURLM_OK, ret2 = CURLM_OK;
	CODE:
		switch ( option ) {
			case CURLMOPT_SOCKETDATA:
				SvREPLACE( multi->cb[ CB_MULTI_SOCKET ].data, value );
				break;

			case CURLMOPT_SOCKETFUNCTION:
				SvREPLACE( multi->cb[ CB_MULTI_SOCKET ].func, value );
				ret2 = curl_multi_setopt( multi->handle, CURLMOPT_SOCKETFUNCTION,
					SvOK( value ) ? cb_multi_socket : NULL );
				ret1 = curl_multi_setopt( multi->handle, CURLMOPT_SOCKETDATA, multi );
				break;

			/* introduced in 7.16.0 */
#ifdef CURLMOPT_TIMERDATA
#ifdef CURLMOPT_TIMERFUNCTION
			case CURLMOPT_TIMERDATA:
				SvREPLACE( multi->cb[ CB_MULTI_TIMER ].data, value );
				break;

			case CURLMOPT_TIMERFUNCTION:
				SvREPLACE( multi->cb[ CB_MULTI_TIMER ].func, value );
				ret2 = curl_multi_setopt( multi->handle, CURLMOPT_TIMERFUNCTION,
					SvOK( value ) ? cb_multi_timer : NULL );
				ret1 = curl_multi_setopt( multi->handle, CURLMOPT_TIMERDATA, multi );
				break;
#endif
#endif

			/* default cases */
			default:
				if ( option < CURLOPTTYPE_OBJECTPOINT ) {
					/* A long (integer) value */
					ret1 = curl_multi_setopt( multi->handle, option,
						(long) SvIV( value ) );
				} else {
					croak( "Unknown curl multi option" );
				}
				break;
		};
		MULTI_DIE( ret2 );
		MULTI_DIE( ret1 );


int
perform( multi )
	WWW::CurlOO::Multi multi
	PREINIT:
		int remaining;
		CURLMcode ret;
	CODE:
		CLEAR_ERRSV();
		do {
			ret = curl_multi_perform( multi->handle, &remaining );
		} while ( ret == CURLM_CALL_MULTI_PERFORM );

		/* rethrow errors */
		if ( SvTRUE( ERRSV ) )
			croak( NULL );

		MULTI_DIE( ret );

		RETVAL = remaining;
	OUTPUT:
		RETVAL


int
socket_action( multi, sockfd=CURL_SOCKET_BAD, ev_bitmask=0 )
	WWW::CurlOO::Multi multi
	int sockfd
	int ev_bitmask
	PREINIT:
		int remaining;
		CURLMcode ret;
	CODE:
		CLEAR_ERRSV();
		do {
			ret = curl_multi_socket_action( multi->handle,
				(curl_socket_t) sockfd, ev_bitmask, &remaining );
		} while ( ret == CURLM_CALL_MULTI_PERFORM );

		/* rethrow errors */
		if ( SvTRUE( ERRSV ) )
			croak( NULL );

		MULTI_DIE( ret );

		RETVAL = remaining;
	OUTPUT:
		RETVAL


#if LIBCURL_VERSION_NUM >= 0x070f05

void
assign( multi, sockfd, value=NULL )
	WWW::CurlOO::Multi multi
	unsigned long sockfd
	SV *value
	PREINIT:
		CURLMcode ret;
		void *sockptr;
	CODE:
		if ( value && SvOK( value ) ) {
			SV **valueptr;
			valueptr = perl_curl_simplell_add( aTHX_ &multi->socket_data,
				sockfd );
			if ( !valueptr )
				croak( "internal WWW::CurlOO error" );
			if ( *valueptr )
				sv_2mortal( *valueptr );
			sockptr = *valueptr = newSVsv( value );
		} else {
			sockptr = NULL;
		}
		ret = curl_multi_assign( multi->handle, sockfd, sockptr );
		MULTI_DIE( ret );

#endif


void
DESTROY( multi )
	WWW::CurlOO::Multi multi
	CODE:
		/* TODO: remove all associated easy handles */
		sv_2mortal( multi->perl_self );
		perl_curl_multi_delete( aTHX_ multi );


SV *
strerror( ... )
	PROTOTYPE: $;$
	PREINIT:
		const char *errstr;
	CODE:
		if ( items < 1 || items > 2 )
#ifdef croak_xs_usage
			croak_xs_usage(cv, "[multi], errnum");
#else
			croak( "Usage: WWW::CurlOO::Multi::strerror( [multi], errnum )" );
#endif
		errstr = curl_multi_strerror( SvIV( ST( items - 1 ) ) );
		RETVAL = newSVpv( errstr, 0 );
	OUTPUT:
		RETVAL
