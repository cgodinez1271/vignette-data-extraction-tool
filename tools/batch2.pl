#!/usr/bin/perl
#Mon Jan 26 11:57:54 EST 2015
#Carlos A. Godinez, Principal CMS Engineer

use strict;
use warnings;

use DBI;
use Data::Dumper;
use Log::Log4perl qw(:easy);
use Benchmark;
use WWW::Curl::Easy;
use File::Temp qw/tempfile/;
use Term::ANSIColor qw(:constants);
use Fcntl qw(:flock);

BEGIN { require "config.pl"; }

my $SENDMAIL = '/usr/lib/sendmail';

umask 000;
chomp(my $ts = `/bin/date '+%m%d%y'`);
Log::Log4perl->easy_init( { level  => $INFO,
	file   => ">>logs/batch2_$ts.log",
    layout => '[%d] %m%n'
});

# exit if script is already running
open(LOCK, ">/data/tmp/$runlck") or LOGDIE "Cannot open /data/tmp/$runlck: $!";
flock(LOCK, LOCK_EX | LOCK_NB) or LOGDIE "$0: already running. Aborting";

my $command = "$0 @ARGV";
ALWAYS ">>> START: $command";

my $SQL1 = qq(
	SELECT
		id,
		email,
		manifesturl,
		description	
	FROM
		manifesturls
	WHERE
		timestamp IS NULL
		AND email IS NOT NULL
	ORDER BY
		id DESC
);

my $dbh = DBI->connect( "dbi:SQLite:dbname=$DB", "", "", {
	PrintError => 1,
	RaiseError => 1,
	ShowErrorStatement => 1,
	AutoCommit => 0
	}) or LOGDIE("Could not create database connection: " . DBI->errstr);

my %rl = %{$dbh->selectall_hashref($SQL1, 'id')};
$DEBUG && print '%rl: ' . Dumper(\%rl) . "\n";

$dbh->disconnect;

my $t0 = Benchmark->new;

# process selected set if any
if( scalar keys(%rl) ) {
	foreach my $id (keys %rl) {
		my @urls = split(',', $rl{$id}->{'manifesturl'});
		$DEBUG && print '@urls: ' . Dumper(\@urls) . "\n";
		INFO "Processing batch id $id ...";
		
		( my $tag = $rl{$id}->{'description'} ) =~ s/\s+/_/g;
		$tag =~ s/[^a-zA-Z0-9 _-]//g;
		sendEmail($rl{$id}->{'email'}, $FROM, "$ADMIN,$CC", "started manifest $tag group processing", "Started manifest $tag (" . scalar(@urls) . " URLs) group processing.");
		my $manifest = "$HD/files/mf$id-$tag";

		my $curl = WWW::Curl::Easy->new;

		my $ChildrenCount = 0;		
		foreach my $url (@urls) {
			chomp($url);

			if ($ChildrenCount >= $MaxForks2) {
				wait();
				$ChildrenCount--;
			}

			# randomly select wich host renders request
			#$url =~ s/dev-uat/qa-uat/ if(int(rand(2)));
			$url =~ s!//(dev|qa)-(preview|uat)\.!//$host[$ChildrenCount%2].!;

			my $pid = fork();	
			LOGDIE "Could not fork: $!" unless defined($pid);

			if (!$pid) {
				my $out = urlRender($url);
				if ($out) {
					$DEBUG && print RED, "\nCHILD: rendered $url", RESET, ">>>\n" . Dumper($out) . "\n<<<\n";
					open (my $fh, '>>',  $manifest) or LOGDIE("Unable to open $manifest file");
					flock($fh, LOCK_EX);
					print $fh join("\n", @$out);
					print $fh "\n";
					close ($fh) or WARN "Could not close $manifest : $!";
					sleep 2;
				}
				exit 0;
			}
			$ChildrenCount++;	
		}
		sleep 2 while wait > 0;

		$DEBUG && print "\nPARENT: done rendering manifests, continuing ...\n"    ;
		
		$dbh = DBI->connect( "dbi:SQLite:dbname=$DB", "", "", {
			PrintError => 1,
			RaiseError => 1,
			ShowErrorStatement => 1,
			AutoCommit => 0
		}) or LOGDIE("Could not create database connection: " . DBI->errstr);

		chomp(my $lts = `date '+%m/%d/%y %H:%M'`);
		if ( -e $manifest ) {
			my $sth = $dbh->prepare("INSERT INTO manifest (manfname, email, timestamp, description) VALUES (?, ?, ?, ?)");
			$sth->execute($manifest, $rl{$id}->{'email'}, $lts, $rl{$id}->{'description'});
			$sth->finish;

			chomp( my $count = qx(/usr/bin/wc -l $manifest 2>/dev/null) );
			my $message = "Manifest $tag group processing done. Built manifest $manifest ($count URLs), which has been queued for rendering.";
			sendEmail($rl{$id}->{'email'}, $FROM, "$ADMIN,$CC", "Manifest $tag group processing done", $message);
		} else {
			$manifest = 'no manifest created: URLs rendered no content';
			sendEmail($rl{$id}->{'email'}, $FROM, "$ADMIN,$CC", "Manifest $tag group processing done", "Warning: no manifest created: URLs rendered no content.");
			WARN "Warning: manifest $tag group resulted in empty content.";
		}

		eval {
			$dbh->do("UPDATE manifesturls SET timestamp = '$lts', description = '$manifest' WHERE id = $id");
			$dbh->commit;
		};
		if ($@) {
			$dbh->rollback or LOGDIE "Couldn't rollback transaction: " . DBI->errstr;
			LOGDIE "UPDATE into manifest aborted because: $@";
		}   
		undef $dbh;
		
		my $t1 = Benchmark->new;
		INFO "Manifest $manifest built in " . timestr(timediff($t1, $t0));
	}
} else {
	WARN "No records to process.";
}
ALWAYS ">>> END <<<";

sub urlRender {
	my( $url ) = @_;
	chomp($url);
	my($to, $from, $cc, $subject, $message);
	my $DEBUG = 0;

	my $curlout = '';
	my $curl = WWW::Curl::Easy->new;
	open (my $fh, '>', \$curlout) or LOGDIE("curlout error: $!");

	$curl->setopt(CURLOPT_HEADER, 0);
	$curl->setopt(CURLOPT_URL, $url);
	$curl->setopt(CURLOPT_WRITEDATA, $fh);
	#$curl->setopt(CURLOPT_VERBOSE, 1);
	my $rc = $curl->perform;
	my $hc = $curl->getinfo(CURLINFO_HTTP_CODE);

	if( $rc == 0 and $hc == 200 ) {
		my @aret = split(/\r/, $curlout);
		$DEBUG && print RED, "\nOUTPUT for $url", RESET, "\n" . Dumper(\@aret) . "\n";
		INFO "CURL $url -> " . scalar @aret . " URLs";
		return \@aret if scalar @aret;
	} else {
		$DEBUG && print RED, "Unable to render $url (HTTP return code: $hc)", RESET;	
		WARN "ERROR: unable to render $url (HTTP return code: $hc)";
	}
	return;
}

sub sendEmail
{
	my ($to, $from, $cc, $subject, $message) = @_;

	open(MAIL, "|$SENDMAIL -oi -t");
	print MAIL "From: $from\n";
	print MAIL "To: $to\n";
	print MAIL "CC: $cc\n";
	print MAIL "Subject: $SUBJECT: $subject\n\n";
	print MAIL "\n$message\n\nRegards,\n\nTimeInc";
	close(MAIL);

	INFO "Emailed to $to:\n$message";
} 

