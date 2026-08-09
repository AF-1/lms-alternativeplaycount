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
	all => [qw(createBackup cleanupBackups isTimeOrEmpty getMusicDirs parse_duration pathForItem roundFloat toIntTimestamp hasValidBackupRootElement)],
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{all} } );

my $log = logger('plugin.alternativeplaycount');
my $prefs = preferences('plugin.alternativeplaycount');
my $serverPrefs = preferences('server');

my ($backupQueue, $backupOutput, $backupStarted, $backupTotalCount, $backupCombinedTotal, $backupCombinedItemsDone, $backupImporterCall);
my ($extBackupPlayHistoryQueue, $extBackupPlayersQueue, $extBackupOutput, $extBackupTotalCount, $extBackupSection);

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
	$backupImporterCall = $importerCall;
	my $backuptimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
	my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;

	$backupCombinedItemsDone = 0;
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

	$extBackupPlayHistoryQueue = [];
	$extBackupPlayersQueue = [];
	if ($prefs->get('backupexternaldata')) {
		require Plugins::AlternativePlayCount::Storage;
		$extBackupPlayHistoryQueue = Plugins::AlternativePlayCount::Storage->getAllPlayHistoryForExport();
		$extBackupPlayersQueue = Plugins::AlternativePlayCount::Storage->getAllPlayersForExport();
	}
	$extBackupTotalCount = scalar(@{$extBackupPlayHistoryQueue}) + scalar(@{$extBackupPlayersQueue});

	$backupCombinedTotal = $backupTotalCount + $extBackupTotalCount;

	if ($backupTotalCount) {
		my $filename = catfile($backupDir, 'APC_Backup_'.$filename_timestamp.'.xml');
		$backupOutput = FileHandle->new($filename, '>:utf8') or do {
			$log->error('Could not open '.$filename.' for writing. Does the AlternativePlayCount folder exist? Does LMS have read/write permissions (755) for the (parent) folder?');
			$prefs->set('backuprestoreresult', 2);
			$prefs->set('status_backuprestore', 0);
			return;
		};
		main::DEBUGLOG && $log->is_debug && $log->debug('Found '.$backupTotalCount.' track(s) with values in the APC database');

		my $osDetails = Slim::Utils::OSDetect::details();
		my $backupCodepage = getBackupCodepage();
		print $backupOutput "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
		print $backupOutput "<!-- Backup of APC database values for ".$backupTotalCount." track(s) -->\n";
		print $backupOutput "<!-- ".$backuptimestamp." -->\n";
		print $backupOutput "<!-- Created on OS: ".($osDetails->{'osName'} || $^O)."; OS family: ".($osDetails->{'os'} || 'unknown')." -->\n";
		print $backupOutput "<!-- OS-Arch: ".($osDetails->{'osArch'} || 'unknown')."; Perl-Arch: ".($osDetails->{'binArch'} || 'unknown')."; FS: ".($osDetails->{'fsType'} || 'unknown')."; Perl $] -->\n";
		print $backupOutput "<AlternativePlayCount>\n";
		print $backupOutput "\t<backupos>".($osDetails->{'os'} || $^O)."</backupos>\n";
		print $backupOutput "\t<backupcodepage>".($backupCodepage || '')."</backupcodepage>\n";
		print $backupOutput "\t<trackcount>".$backupTotalCount."</trackcount>\n";
		if ($importerCall) {
			while (writeBackupChunk()) {}
		} else {
			Slim::Utils::Scheduler::add_task(\&writeBackupChunk);
		}
	} else {
		main::INFOLOG && $log->is_info && $log->info('No tracks with play/skip counts in APC database');
		_finishOrStartExternalBackup();
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

	_finishOrStartExternalBackup();
	return 0;
}

sub _advanceBackupProgress {
	return unless $backupCombinedTotal;
	$backupCombinedItemsDone++;
	$prefs->set('backuprestoreprogresspercentage', sprintf("%.0f", ($backupCombinedItemsDone / $backupCombinedTotal) * 100));
}

sub _finishOrStartExternalBackup {
	if ($extBackupTotalCount) {
		_startExternalBackup();
	} else {
		_finalizeBackup();
	}
}

sub _finalizeBackup {
	if ($backupTotalCount || $extBackupTotalCount) {
		$prefs->set('lastbackup', int(time()));
		cleanupBackups();
	} else {
		main::INFOLOG && $log->is_info && $log->info('Nothing to back up: no APC values and no external data found.');
	}
	main::INFOLOG && $log->is_info && $log->info('Backup completed after '.(time() - $backupStarted).' seconds.');
	$prefs->set('backuprestoreprogresspercentage', 100);
	$prefs->set('backuprestoreresult', 1);
	$prefs->set('status_backuprestore', 0);
}

sub _startExternalBackup {
	my $backupDir = $prefs->get('apcfolderpath');
	my $backuptimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
	my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;
	my $filename = catfile($backupDir, 'APC_ExternalData_Backup_'.$filename_timestamp.'.xml');

	$extBackupOutput = FileHandle->new($filename, '>:utf8') or do {
		$log->error('Could not open '.$filename.' for writing external data backup. Does the AlternativePlayCount folder exist? Does LMS have read/write permissions (755) for the (parent) folder?');
		_finalizeBackup();
		return;
	};

	main::DEBUGLOG && $log->is_debug && $log->debug('Found '.scalar(@{$extBackupPlayHistoryQueue}).' play history entrie(s) and '.scalar(@{$extBackupPlayersQueue}).' player(s) to back up');

	my $osDetails = Slim::Utils::OSDetect::details();
	my $backupCodepage = getBackupCodepage();
	print $extBackupOutput "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
	print $extBackupOutput "<!-- Backup of APC external database tables (e.g. play history) -->\n";
	print $extBackupOutput "<!-- ".$backuptimestamp." -->\n";
	print $extBackupOutput "<!-- Created on OS: ".($osDetails->{'osName'} || $^O)."; OS family: ".($osDetails->{'os'} || 'unknown')." -->\n";
	print $extBackupOutput "<!-- OS-Arch: ".($osDetails->{'osArch'} || 'unknown')."; Perl-Arch: ".($osDetails->{'binArch'} || 'unknown')."; FS: ".($osDetails->{'fsType'} || 'unknown')."; Perl $] -->\n";
	print $extBackupOutput "<APCExternalData>\n";
	print $extBackupOutput "\t<backupos>".($osDetails->{'os'} || $^O)."</backupos>\n";
	print $extBackupOutput "\t<backupcodepage>".($backupCodepage || '')."</backupcodepage>\n";
	print $extBackupOutput "\t<playhistorycount>".scalar(@{$extBackupPlayHistoryQueue})."</playhistorycount>\n";
	print $extBackupOutput "\t<playercount>".scalar(@{$extBackupPlayersQueue})."</playercount>\n";
	print $extBackupOutput "\t<playhistory>\n";
	$extBackupSection = 'playhistory';

	if ($backupImporterCall) {
		while (writeExternalBackupChunk()) {}
	} else {
		Slim::Utils::Scheduler::add_task(\&writeExternalBackupChunk);
	}
}

sub writeExternalBackupChunk {
	if ($extBackupSection eq 'playhistory') {
		if (my $entry = shift(@{$extBackupPlayHistoryQueue})) {
			my $entryURL = escape($entry->{'url'});
			my $entryUrlMD5 = $entry->{'urlmd5'} // '';
			my $entryMBID = $entry->{'musicbrainz_id'} // '';
			my $entryPlayed = $entry->{'played'} // '';
			my $entryRating = $entry->{'rating'} // '';
			my $entryRemote = $entry->{'remote'} // 0;
			my $entryClientID = $entry->{'client_id'} ? escape($entry->{'client_id'}) : '';
			print $extBackupOutput "\t\t<entry>\n\t\t\t<url>".$entryURL."</url>\n\t\t\t<urlmd5>".$entryUrlMD5."</urlmd5>\n\t\t\t<musicbrainzid>".$entryMBID."</musicbrainzid>\n\t\t\t<played>".$entryPlayed."</played>\n\t\t\t<rating>".$entryRating."</rating>\n\t\t\t<remote>".$entryRemote."</remote>\n\t\t\t<clientid>".$entryClientID."</clientid>\n\t\t</entry>\n";
			_advanceBackupProgress();
			return 1;
		}
		print $extBackupOutput "\t</playhistory>\n\t<players>\n";
		$extBackupSection = 'players';
		return 1;
	}

	if (my $player = shift(@{$extBackupPlayersQueue})) {
		my $playerMac = escape($player->{'mac'});
		my $playerName = $player->{'name'} ? escape($player->{'name'}) : '';
		my $playerModel = $player->{'model'} ? escape($player->{'model'}) : '';
		my $playerLastSeen = $player->{'last_seen'} // '';
		print $extBackupOutput "\t\t<player>\n\t\t\t<mac>".$playerMac."</mac>\n\t\t\t<name>".$playerName."</name>\n\t\t\t<model>".$playerModel."</model>\n\t\t\t<lastseen>".$playerLastSeen."</lastseen>\n\t\t</player>\n";
		_advanceBackupProgress();
		return 1;
	}

	print $extBackupOutput "\t</players>\n</APCExternalData>\n";
	close $extBackupOutput;
	$extBackupOutput = undef;
	main::INFOLOG && $log->is_info && $log->info('External data backup completed.');
	_finalizeBackup();
	return 0;
}

sub cleanupBackups {
	_cleanupBackupFiles(qr/^APC_Backup_.*$/, 'APC table backup(s)');
	_cleanupBackupFiles(qr/^APC_ExternalData_Backup_.*$/, 'external data backup(s)');
}

sub _cleanupBackupFiles {
	my ($pattern, $label) = @_;
	my $autodeletebackups = $prefs->get('autodeletebackups');
	my $backupFilesMin = $prefs->get('backupfilesmin');
	if ($autodeletebackups) {
		my $backupDir = $prefs->get('apcfolderpath');
		return unless (-d $backupDir);
		my $backupsdaystokeep = $prefs->get('backupsdaystokeep');
		my $maxkeeptime = $backupsdaystokeep * 24 * 60 * 60; # in seconds
		opendir(my $DH, $backupDir) or do { $log->error("Error opening $backupDir: $!"); return; };
		my @files = grep(/$pattern/, readdir($DH));
		closedir($DH);
		main::DEBUGLOG && $log->is_debug && $log->debug('number of '.$label.' found: '.scalar(@files));
		my %mtimes = map { $_ => stat(catfile($backupDir, $_))->mtime } @files;
		my @sortedFiles = sort { $mtimes{$a} <=> $mtimes{$b} } @files;
		my $etime = int(time());
		my $n = 0;
		if (scalar(@files) > $backupFilesMin) {
			foreach my $file (@sortedFiles) {
				if (($etime - $mtimes{$file}) > $maxkeeptime) {
					if (unlink(catfile($backupDir, $file))) {
						$n++;
						last if ((scalar(@files) - $n) <= $backupFilesMin);
					} else {
						$log->error("Can't delete $file: $!");
					}
				}
			}
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug('Not deleting any '.$label.'. Number of files to keep ('.$backupFilesMin.') '.((scalar(@files) - $n) == $backupFilesMin ? '=' : '>').' files found ('.scalar(@files).').');
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('Deleted '.$n.' '.$label.'. '.(scalar(@files) - $n).' remaining.');
	}
}

sub getBackupCodepage {
	return undef unless main::ISWINDOWS;
	my $codepage;
	eval {
		require Win32;
		my $cp = Win32::GetACP();
		$codepage = 'cp'.$cp if $cp;
	};
	main::DEBUGLOG && $log->is_debug && $log->debug('Could not determine Windows codepage: '.$@) if $@;
	return $codepage;
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
			$relFilePath =~ s/^\.\///;
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

sub hasValidBackupRootElement {
	my ($file, $rootElement) = @_;
	return 0 unless $file && -f $file;

	open(my $fh, '<', $file) or return 0;
	my $found = 0;
	for (1..10) {
		my $line = <$fh>;
		last unless defined $line;
		if ($line =~ /<\Q$rootElement\E[\s>]/) {
			$found = 1;
			last;
		}
	}
	close($fh);

	return $found;
}

*escape = \&URI::Escape::uri_escape_utf8;
*unescape = \&URI::Escape::uri_unescape;

1;
