#!/usr/bin/perl
#Sat Jan 10 16:21:26 EST 2015
#Carlos A. Godinez

use strict;
use warnings;

$| = 1;
use DBI;
use Data::Dumper;
use Log::Log4perl qw(:easy);
use Benchmark;
use WWW::Curl::Easy;
use File::Temp qw/tempfile/;
use File::Basename;
use Fcntl qw(:flock);
use Term::ANSIColor qw(:constants);
use IO::Handle;

BEGIN { require "config.pl"; }

my $CURL = '/usr/bin/curl';
my $XMLLINT = '/usr/bin/xmllint';
my $SENDMAIL = '/usr/lib/sendmail';

my $HEAD = qq!<?xml version="1.0" standalone="yes"?>\n<root>\n!;
my $TAIL = qq!</root>\n!;

umask 000;
chomp(my $ts = `/bin/date '+%m%d%y'`);
Log::Log4perl->easy_init( { level  => $INFO,
	file   => ">>logs/batch3_$ts.log",
    layout => '[%d] %m%n'
});

# exit if script is already running
open(LOCK, ">/data/tmp/$runlck") or LOGDIE "Cannot open /data/tmp/$runlck: $!";
flock(LOCK, LOCK_EX | LOCK_NB) or LOGDIE "$0: already running. Aborting";

my $command = "$0 @ARGV";
ALWAYS ">>> START: $command";

# Open database
my $dbh = DBI->connect( "dbi:SQLite:dbname=$DB", "", "", {
	PrintError => 1,
	RaiseError => 1,
	ShowErrorStatement => 1,
	AutoCommit => 0
	}) or LOGDIE("Could not create database connection: " . DBI->errstr);

my $SQL1 = qq(
	SELECT
		id,
		manfname,
		outfname,
		email,
		timestamp,
		description	
	FROM
		manifest
	WHERE
		outfname IS NULL
		AND email IS NOT NULL
	ORDER BY
		id DESC
);

my %rl = %{$dbh->selectall_hashref($SQL1, 'id')};
$DEBUG && print '%rl: ' . Dumper(\%rl) . "\n";

$dbh->disconnect;

# Process resulting set if any
if (scalar(keys %rl)) {
	foreach my $r (keys %rl) {

		my $t0 = Benchmark->new;

		my $xmlfile = $rl{$r}->{'manfname'} . ".xml";
		my $mn = basename( $rl{$r}->{'manfname'} );
		$DEBUG && print "XML file: $xmlfile\n";

		open (my $fh, '>',  $xmlfile) or LOGDIE("Unable to open $xmlfile file");
		print $fh $HEAD;
		close ($fh) or WARN "Could not close $xmlfile : $!";

		my @manifest;
		if( open ($fh, '<', "$rl{$r}->{'manfname'}") ) {
			@manifest = <$fh>;
			close ($fh);
		} else {
			ERROR ("Unable to open $rl{$r}->{'manfname'} manifest file");
		}

		if (@manifest) {
			INFO "Processing $rl{$r}->{'manfname'} : " . scalar(@manifest) . " URLs";
			sendEmail( $rl{$r}->{'email'}, $FROM, "$ADMIN,$CC", "Rendering started for manifest: $mn", "Started rendering $mn: " . scalar(@manifest) . "URLs");

			my $ChildrenCount = 0;

			foreach my $url (@manifest) {	
				if($ChildrenCount >= $MaxForks3) {
					wait();   #Wait for some child to finish
					$ChildrenCount--;
				}

				$url =~ s!//(dev|qa)-(uat|preview)\.!//$host[$ChildrenCount%2].!;

				my $pid = fork();
				LOGDIE "Could not fork: $!" unless defined($pid);

				if (!$pid) {
					$DEBUG && print "\nCHILD: enter ...\n";
					my $out = urlRender($url);
					$DEBUG && print RED, "\nURLrENDER OUT\n", RESET, ">>>\n$out\n<<<\n";
					if( $out ) {
						$DEBUG && print RED, "\nCHILD: writing file\n", RESET;
						open (my $fh, '>>', $xmlfile) or LOGDIE("Unable to open $xmlfile file");
						flock($fh, LOCK_EX); # wait until unlock;
						print $fh $out . "\n";
						close ($fh) or WARN "Could not close $HD/files/$xmlfile : $!";
						$DEBUG && print RED, "\nCHILD: closing file\n", RESET;
						sleep 2;
					}
					$DEBUG && print "\nCHILD: exit ...\n";
					exit 0;
				}
				$ChildrenCount++;
			}
		} else {
			ERROR "EMPTY manifest: " . $rl{$r}->{'manfname'};
			next;
		}
		$DEBUG && print "\nPARENT: done rendering manifest, continuing ...\n";

		# No zombies!
		sleep 1 while wait > 0;

		# append the heard
		open ($fh, '>>', $xmlfile) or LOGDIE("Unable to open $xmlfile file");
		print $fh $TAIL;
		close ($fh) or WARN "Could not close $xmlfile : $!";

		if( system("/bin/gzip -f $xmlfile 2> $xmlfile.gziperr") != 0 ) {
			ERROR "FAILED gzip: see errors xmlfile.gziperr";
			sendEmail( $ADMIN, $FROM, $CC, "GZIP failed for $mn", "gzip failed for manifest file $rl{$r}->{'manfname'}");
			next;
		} 
		my $gzfile = basename( $xmlfile ) . ".gz";
	
		# Update manifest table with output file name
		my $dbh = DBI->connect( "dbi:SQLite:dbname=$DB", "", "", {
			PrintError => 1,
			RaiseError => 1,
			ShowErrorStatement => 1,
			AutoCommit => 0
			}) or LOGDIE("Could not create database connection: " . DBI->errstr);

		eval {
			$dbh->do("UPDATE manifest SET outfname = '$gzfile' WHERE id = $r");
			$dbh->commit;
		};
		if ($@) {
	        $dbh->rollback or LOGDIE "Couldn't rollback transaction: " . DBI->errstr;
	        LOGDIE "UPDATE into manifest aborted because: $@";
	    }
		$dbh->disconnect;

		my $t1 = Benchmark->new;
		INFO "Finish processing $rl{$r}->{'manfname'} (" . scalar(@manifest) . " URLs)";
		INFO "GZIP output sent to: $gzfile";
		INFO "Processing completed in: " . timestr(timediff($t1, $t0));

		my $body = "File is available at:\n\thttps://dcms-tools.timeinc.net/migrate/ew/files/$gzfile";
		sendEmail( $rl{$r}->{'email'}, $FROM, "$ADMIN,$CC", "Rendering done for manifest: $mn", "Complete rendering $mn\n$body" );
	}
} else {
	INFO "No manifests to process";
}

$DEBUG && print "\nPARENT: exiting  ...\n";

# clean logs
unlink grep { -M > 60 } <./logs/*>;
unlink grep { -z } <../files/*>;

ALWAYS ">>> END <<<";

sub validateXML {
	my( $url, $curlout ) = @_;

	my $DEBUG = 0;

	my $rc = 1;
	
	my $tf = File::Temp->new(DIR => '/data/tmp', UNLINK => 1);
	my $tfn = $tf->filename;
	print $tf $curlout;	
	close $tf;

	my $linterr = qx( $XMLLINT --noout $tfn 2>&1 );
	
	$DEBUG && print RED, "\nCURLOUT\n" , RESET, ">>>\n$curlout\n<<<\n";
	$DEBUG && print YELLOW, "\nTemp file name: $tfn\n", RESET;
	$DEBUG && print RED, "\nLINTERR\n", RESET, ">>>\n$linterr<<<\n";

	if( $linterr ) {
		sendEmail( $ADMIN, $FROM, $CC, "xmllint ERROR", "\nxmllint error output for $url\n\n$linterr" );
		ERROR "FAILED xmllint: $linterr";
		$rc = 0;
	}	
	$DEBUG && print RED, "\nRETURN\n", RESET, ">>>\n$rc<<<\n";
	return $rc;
}

sub urlRender {
	my( $url ) = @_;
	chomp($url);

	my $DEBUG = 0;

	my $curlout;
	open (my $fh, '>', \$curlout) or LOGDIE("curlout error: $!");
	my $curl = WWW::Curl::Easy->new;

	INFO "CURLing $url ...";
	$curl->setopt(CURLOPT_HEADER, 0);
	$curl->setopt(CURLOPT_URL, $url);
	$curl->setopt(CURLOPT_WRITEDATA, \$fh);
	my $rc = $curl->perform;
	my $hc = $curl->getinfo(CURLINFO_HTTP_CODE);

	$DEBUG && print RED, "\nOUTPUT for $url (return code: $rc - http code: $hc)", RESET, "\n>>>\n$curlout\n<<<";

	if( $rc == 0 and $hc == 200 ) {
		$curlout =~ s/<\?xml .*?\?>//;
		if( validateXML( $url, $curlout ) ) {
			return $curlout;
		} else {
			WARN "ERROR: validateXML function returned an error";
			return;
		}
	} else {
		WARN "ERROR: failed to render $url (CURL rc: $rc - HTTP rc: $hc)";
		sendEmail( $ADMIN, $FROM, $CC, "Failure to render $url" , "Error rendering $url (CURL rc: $rc - HTTP rc: $hc)" );
		return;
	}
	close ($fh);
}

sub sendEmail {
	my ($to, $from, $cc, $subject, $message) = @_;

	open(MAIL, "|$SENDMAIL -oi -t");
	print MAIL "From: $FROM\n";
	print MAIL "To: $to\n";
	print MAIL "CC: $cc\n";
	print MAIL "Subject: $SUBJECT: $subject\n\n";
	print MAIL "\n$message\n\nRegards,\n\nTimeInc";
	close(MAIL);

	INFO "Emailed to $to:\n$message";
} 

