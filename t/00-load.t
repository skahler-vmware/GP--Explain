#!perl

use Test::More tests => 5;

BEGIN {
    use_ok( 'GP::Explain' );
    use_ok( 'GP::Explain::From' );
    use_ok( 'GP::Explain::FromText' );
    use_ok( 'GP::Explain::Node' );
    use_ok( 'GP::Explain::StringAnonymizer' );
}

diag( "Testing GP::Explain $GP::Explain::VERSION, Perl $], $^X" );
