#
# Alternative Play Count
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::AlternativePlayCount::Common;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Schema;
use Slim::Utils::DateTime;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Text;
use File::Basename;
use File::Copy qw(move);
use File::Spec::Functions qw(:ALL);
use File::stat;
use FileHandle;
use POSIX qw(strftime);
use Time::HiRes qw(time);
use Path::Class;

use base 'Exporter';
our %EXPORT_TAGS = (
	all => [qw(createBackup cleanupBackups isTimeOrEmpty getMusicDirs parse_duration pathForItem roundFloat toIntTimestamp)],
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{all} } );

my $log = logger('plugin.alternativeplaycount');
my $prefs = preferences('plugin.alternativeplaycount');
my $serverPrefs = preferences('server');

my ($backupQueue, $backupOutput, $backupStarted, $backupTotalCount);

sub createBackup {
	my $importerCall = shift;

	if ($prefs->get('status_backuprestore')) {
		$log->warn('A backup is already in progress, please wait for it to finish');
		return;
	}
	$prefs->set('status_backuprestore', 1);
	$prefs->set('backuprestoreprogresspercentage', 0);
	$prefs->set('backuprestoreresult', 0);

	my $backupDir = $prefs->get('apcfolderpath');
	my $dbh = Slim::Schema->dbh;
	my ($trackURL, $trackURLmd5, $apcPlayCount, $apcLastPlayed, $apcSkipCount, $apcLastSkipped, $apcDynPSval, $apcRemote, $apcTrackMBID);
	$backupStarted = time();
	my $backuptimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
	my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;

	$backupQueue = [];
	eval {
		my $sth = $dbh->prepare("select alternativeplaycount.url, alternativeplaycount.urlmd5, alternativeplaycount.playCount, alternativeplaycount.lastPlayed, alternativeplaycount.skipCount, alternativeplaycount.lastSkipped, alternativeplaycount.dynPSval, alternativeplaycount.remote, alternativeplaycount.musicbrainz_id from alternativeplaycount where (ifnull(alternativeplaycount.playCount, 0) > 0 or ifnull(alternativeplaycount.skipCount, 0) > 0)");
		$sth->execute();
		$sth->bind_columns(undef, \$trackURL, \$trackURLmd5, \$apcPlayCount, \$apcLastPlayed, \$apcSkipCount, \$apcLastSkipped, \$apcDynPSval, \$apcRemote, \$apcTrackMBID);
		while ($sth->fetch()) {
			push (@{$backupQueue}, {'url' => $trackURL, 'urlmd5' => $trackURLmd5, 'playcount' => $apcPlayCount, 'lastplayed' => $apcLastPlayed, 'skipcount' => $apcSkipCount, 'lastskipped' => $apcLastSkipped, 'dynpsval' => $apcDynPSval, 'remote' => $apcRemote, 'musicbrainzid' => $apcTrackMBID});
		}
		$sth->finish();
	};
	if ($@) {
		$log->error("Database error during backup: $@");
		$prefs->set('backuprestoreresult', 2);
		$prefs->set('status_backuprestore', 0);
		return;
	}

	$backupTotalCount = scalar(@{$backupQueue});

	if ($backupTotalCount) {
		my $filename = catfile($backupDir, 'APC_Backup_'.$filename_timestamp.'.xml');
		$backupOutput = FileHandle->new($filename, '>:utf8') or do {
			$log->error('Could not open '.$filename.' for writing. Does the AlternativePlayCount folder exist? Does LMS have read/write permissions (755) for the (parent) folder?');
			$prefs->set('backuprestoreresult', 2);
			$prefs->set('status_backuprestore', 0);
			return;
		};
		main::DEBUGLOG && $log->is_debug && $log->debug('Found '.$backupTotalCount.' track(s) with values in the APC database');

		print $backupOutput "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
		print $backupOutput "<!-- Backup of APC database values for ".$backupTotalCount." track(s) -->\n";
		print $backupOutput "<!-- ".$backuptimestamp." -->\n";
		print $backupOutput "<AlternativePlayCount>\n";
		print $backupOutput "\t<trackcount>".$backupTotalCount."</trackcount>\n";

		if ($importerCall) {
			while (writeBackupChunk()) {}
		} else {
			Slim::Utils::Scheduler::add_task(\&writeBackupChunk);
		}
	} else {
		main::INFOLOG && $log->is_info && $log->info('No tracks with play/skip counts in APC database');
		$prefs->set('backuprestoreresult', 1);
		$prefs->set('status_backuprestore', 0);
	}
}

sub writeBackupChunk {
	if (my $APCTrack = shift(@{$backupQueue})) {
		if (!defined($APCTrack->{'remote'})) {
			_advanceBackupProgress();
			return 1;
		}

		my $BACKUPtrackURL = $APCTrack->{'url'};
		my $BACKUPtrackURLmd5 = $APCTrack->{'urlmd5'};
		my $BACKUPplayCount = $APCTrack->{'playcount'} // '';
		my $BACKUPlastPlayed = toIntTimestamp($APCTrack->{'lastplayed'}) // '';
		my $BACKUPskipCount = $APCTrack->{'skipcount'} // '';
		my $BACKUPlastSkipped = toIntTimestamp($APCTrack->{'lastskipped'}) // '';
		my $BACKUPdynPSval = $APCTrack->{'dynpsval'} // '';
		my $BACKUPremote = $APCTrack->{'remote'};
		my $BACKUPrelFilePath = ($BACKUPremote == 0 ? getRelFilePath($BACKUPtrackURL) : '');
		my $BACKUPtrackMBID = $APCTrack->{'musicbrainzid'} || '';

		$BACKUPtrackURL = escape($BACKUPtrackURL);
		$BACKUPrelFilePath = $BACKUPrelFilePath ? escape($BACKUPrelFilePath) : '';
		print $backupOutput "\t<track>\n\t\t<url>".$BACKUPtrackURL."</url>\n\t\t<urlmd5>".$BACKUPtrackURLmd5."</urlmd5>\n\t\t<relurl>".$BACKUPrelFilePath."</relurl>\n\t\t<playcount>".$BACKUPplayCount."</playcount>\n\t\t<lastplayed>".$BACKUPlastPlayed."</lastplayed>\n\t\t<skipcount>".$BACKUPskipCount."</skipcount>\n\t\t<lastskipped>".$BACKUPlastSkipped."</lastskipped>\n\t\t<dynpsval>".$BACKUPdynPSval."</dynpsval>\n\t\t<remote>".$BACKUPremote."</remote>\n\t\t<musicbrainzid>".$BACKUPtrackMBID."</musicbrainzid>\n\t</track>\n";
		_advanceBackupProgress();
		return 1;
	}

	print $backupOutput "</AlternativePlayCount>\n";
	close $backupOutput;
	$backupOutput = undef;
	main::INFOLOG && $log->is_info && $log->info('Backup completed after '.(time() - $backupStarted).' seconds.');

	$prefs->set('lastbackup', int(time()));
	cleanupBackups();
	$prefs->set('backuprestoreprogresspercentage', 100);
	$prefs->set('backuprestoreresult', 1);
	$prefs->set('status_backuprestore', 0);
	return 0;
}

sub _advanceBackupProgress {
	return unless $backupTotalCount;
	$prefs->set('backuprestoreprogresspercentage', sprintf("%.0f", (($backupTotalCount - scalar(@{$backupQueue})) / $backupTotalCount) * 100));
}

sub cleanupBackups {
	my $autodeletebackups = $prefs->get('autodeletebackups');
	my $backupFilesMin = $prefs->get('backupfilesmin');
	if ($autodeletebackups) {
		my $backupDir = $prefs->get('apcfolderpath');
		return unless (-d $backupDir);
		my $backupsdaystokeep = $prefs->get('backupsdaystokeep');
		my $maxkeeptime = $backupsdaystokeep * 24 * 60 * 60; # in seconds
		opendir(my $DH, $backupDir) or do { $log->error("Error opening $backupDir: $!"); return; };
		my @files = grep(/^APC_Backup_.*$/, readdir($DH));
		closedir($DH);
		main::DEBUGLOG && $log->is_debug && $log->debug('number of backup files found: '.scalar(@files));
		my $etime = int(time());
		my $n = 0;
		if (scalar(@files) > $backupFilesMin) {
			foreach my $file (@files) {
				my $filepath = catfile($backupDir, $file);
				my $mtime = stat($filepath)->mtime;
				if (($etime - $mtime) > $maxkeeptime) {
					if (unlink($filepath)) {
						$n++;
						last if ((scalar(@files) - $n) <= $backupFilesMin);
					} else {
						$log->error("Can't delete $file: $!");
					}
				}
			}
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug('Not deleting any backups. Number of backup files to keep ('.$backupFilesMin.') '.((scalar(@files) - $n) == $backupFilesMin ? '=' : '>').' backup files found ('.scalar(@files).').');
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('Deleted '.$n.($n == 1 ? ' backup. ' : ' backups. ').(scalar(@files) - $n).((scalar(@files) - $n) == 1 ? " backup" : " backups")." remaining.");
	}
}

sub getRelFilePath {
	main::DEBUGLOG && $log->is_debug && $log->debug('Getting relative file url/path.');
	my $fullTrackURL = shift;
	my $relFilePath;
	my $lmsmusicdirs = getMusicDirs();
	main::DEBUGLOG && $log->is_debug && $log->debug('Valid LMS music dirs = '.Data::Dump::dump($lmsmusicdirs));

	foreach (@{$lmsmusicdirs}) {
		my $dirSep = File::Spec->canonpath("/");
		my $mediaDirPath = $_.$dirSep;
		my $fullTrackPath = Slim::Utils::Misc::pathFromFileURL($fullTrackURL);
		my $match = checkInFolder($fullTrackPath, $mediaDirPath);

		main::DEBUGLOG && $log->is_debug && $log->debug("Full file path \"$fullTrackPath\" is".($match == 1 ? "" : " NOT")." part of media dir \"".$mediaDirPath."\"");
		if ($match == 1) {
			$relFilePath = file($fullTrackPath)->relative($_);
			$relFilePath = Slim::Utils::Misc::fileURLFromPath($relFilePath);
			$relFilePath =~ s/^(file:)?\/+//isg;
			main::DEBUGLOG && $log->is_debug && $log->debug('Saving RELATIVE file path: '.$relFilePath);
			last;
		}
	}
	if (!$relFilePath) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Couldn't get relative file path for \"$fullTrackURL\".");
	}
	return $relFilePath;
}

sub checkInFolder {
	my $path = shift || return;
	my $checkdir = shift;

	$path = Slim::Utils::Misc::fixPath($path) || return 0;
	$path = Slim::Utils::Misc::pathFromFileURL($path) || return 0;
	main::DEBUGLOG && $log->is_debug && $log->debug('path = '.$path.' -- checkdir = '.$checkdir);

	if ($checkdir && $path =~ /^\Q$checkdir\E/) {
		return 1;
	} else {
		return 0;
	}
}

sub getMusicDirs {
	my $mediadirs = $serverPrefs->get('mediadirs');
	my $ignoreInAudioScan = $serverPrefs->get('ignoreInAudioScan');
	my $lmsmusicdirs = [];
	my %musicdircount;
	my $thisdir;
	foreach $thisdir (@{$mediadirs}, @{$ignoreInAudioScan}) {$musicdircount{$thisdir}++}
	foreach $thisdir (keys %musicdircount) {
		if ($musicdircount{$thisdir} == 1) {
			push (@{$lmsmusicdirs}, $thisdir);
		}
	}
	return $lmsmusicdirs;
}

sub parse_duration {
	use integer;
	my $s = sprintf("%s%s%s%s%s",
		$_[0]/2592000 ? sprintf("%dmo ", $_[0]/2592000) : '',
		$_[0]/604800%4 ? sprintf("%dw ", $_[0]/604800%4) : '',
		$_[0]/86400%7 ? sprintf("%dd ", $_[0]/86400%7) : '',
		$_[0]/3600%24 ? sprintf("%dh ", $_[0]/3600%24) : '',
		$_[0]/60%60 ? sprintf("%dmin", $_[0]/60%60) : ''
	);
	$s =~ s/^\s+|\s+$//g; # trim whitespace
	return $s || '0 min';
}

sub isTimeOrEmpty {
	my $name = shift;
	my $arg = shift;
	if (!$arg || $arg eq '') {
		return 1;
	} elsif ($arg =~ m/^(0?[0-9]|1[0-9]|2[0-3]):([0-5][0-9])$/) {
		return 1;
	}
	return 0;
}

sub pathForItem {
	my $item = shift;
	if (Slim::Music::Info::isFileURL($item) && !Slim::Music::Info::isFragment($item)) {
		my $path = Slim::Utils::Misc::fixPath($item) || return 0;
		return Slim::Utils::Misc::pathFromFileURL($path);
	}
	return $item;
}

sub roundFloat {
	my $float = shift;
	return int($float + $float/abs($float*2 || 1));
}

sub toIntTimestamp {
	my $val = shift;
	return undef unless defined $val && $val ne '';
	$val =~ s/,/./;
	return undef unless $val =~ /^\d+(?:\.\d+)?$/;
	return int($val + 0.5);
}

*escape = \&URI::Escape::uri_escape_utf8;
*unescape = \&URI::Escape::uri_unescape;

1;
