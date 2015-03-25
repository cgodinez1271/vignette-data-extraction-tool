#config.pl
#Mon Jan 26 22:47:23 EST 2015

use vars qw( $runlck @host $DEBUG $MaxForks2 $MaxForks3 $HD $DB $FROM $ADMIN $CC $SUBJECT );

$DEBUG = 0;

$runlck = 'ew.lck';

@host = ( 'qa-uat', 'dev-uat' );

$MaxForks2 = 6;
$MaxForks3 = 30;

$HD = '/data/timeinc/content/qa/feeds/htdocs/migrate/ew';
$DB = "$HD/files/ewmigration.db";

$FROM = 'ics@timeinc.net';
$ADMIN = 'kevin_wiechmann@ew.com';
$CC = 'carlos_godinez@timeinc.com';
$SUBJECT = 'EW Content Extraction Notice';
