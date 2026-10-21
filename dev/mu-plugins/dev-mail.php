<?php
/**
 * Local development only (mounted by compose.override.yml).
 *
 * On http://localhost WordPress sends from "wordpress@localhost", which PHPMailer
 * rejects as invalid, so no mail would ever reach Mailpit.
 */
add_filter( 'wp_mail_from', function ( $from ) {
	return str_ends_with( $from, '@localhost' ) ? 'wordpress@localhost.test' : $from;
} );
