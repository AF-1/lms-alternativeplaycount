#
# Alternative Play Count
#
# (c) 2022 AF-1
#
# GPLv3 license
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.
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
use FindBin qw($Bin);
use POSIX qw(strftime);
use Time::HiRes qw(time);
use Path::Class;

use base 'Exporter';
our %EXPORT_TAGS = (
	all => [qw(commit rollback createBackup cleanupBackups isTimeOrEmpty getMusicDirs parse_duration pathForItem roundFloat)],
);
our @EXPORT_OK = ( @{ $EXPORT_TAGS{all} } );

my $log = logger('plugin.alternativeplaycount');
my $prefs = preferences('plugin.alternativeplaycount');
my $serverPrefs = preferences('server');

sub createBackup {
	my $status_creatingbackup = $prefs->get('status_creatingbackup');
	if ($status_creatingbackup == 1) {
		$log->warn('A backup is already in progress, please wait for the previous backup to finish');
		return;
	}
	$prefs->set('status_creatingbackup', 1);

	my $backupDir = $prefs->get('apcfolderpath');
	my ($sql, $sth) = undef;
	my $dbh = Slim::Schema->dbh;
	my ($trackURL, $trackURLmd5, $apcPlayCount, $apcLastPlayed, $apcSkipCount, $apcLastSkipped, $apcDynPSval, $apcRemote, $apcTrackMBID);
	my $started = time();
	my $backuptimestamp = strftime "%Y-%m-%d %H:%M:%S", localtime time;
	my $filename_timestamp = strftime "%Y%m%d-%H%M", localtime time;

	$sql = "select alternativeplaycount.url, alternativeplaycount.urlmd5, ifnull(alternativeplaycount.playCount, 0), ifnull(alternativeplaycount.lastPlayed, 0), ifnull(alternativeplaycount.skipCount, 0), ifnull(alternativeplaycount.lastSkipped, 0), ifnull(alternativeplaycount.dynPSval, 0), alternativeplaycount.remote, alternativeplaycount.musicbrainz_id from alternativeplaycount where (ifnull(alternativeplaycount.playCount, 0) > 0 or ifnull(alternativeplaycount.skipCount, 0) > 0)";
	$sth = $dbh->prepare($sql);
	$sth->execute();
	$sth->bind_columns(undef, \$trackURL, \$trackURLmd5, \$apcPlayCount, \$apcLastPlayed, \$apcSkipCount, \$apcLastSkipped, \$apcDynPSval, \$apcRemote, \$apcTrackMBID);

	my @APCTracks = ();
	while ($sth->fetch()) {
		push (@APCTracks, {'url' => $trackURL, 'urlmd5' => $trackURLmd5, 'playcount' => $apcPlayCount, 'lastplayed' => $apcLastPlayed, 'skipcount' => $apcSkipCount, 'lastskipped' => $apcLastSkipped, 'dynpsval' => $apcDynPSval, 'remote' => $apcRemote, 'musicbrainzid' => $apcTrackMBID});
	}
	$sth->finish();

	if (@APCTracks) {
		my $filename = catfile($backupDir, 'APC_Backup_'.$filename_timestamp.'.xml');
		my $output = FileHandle->new($filename, '>:utf8') or do {
			$log->error('Could not open '.$filename.' for writing. Does the AlternativePlayCount folder exist? Does LMS have read/write permissions (755) for the (parent) folder?');
			$prefs->set('status_creatingbackup', 0);
			return;
		};
		my $trackcount = scalar(@APCTracks);
		my $ignoredtracks = 0;
		main::DEBUGLOG && $log->is_debug && $log->debug('Found '.$trackcount.($trackcount == 1 ? ' track' : ' tracks').' with values in the APC database');

		print $output "<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n";
		print $output "<!-- Backup of APC Database Values -->\n";
		print $output "<!-- ".$backuptimestamp." -->\n";
		print $output "<AlternativePlayCount>\n";
		for my $APCTrack (@APCTracks) {
			if (!defined($APCTrack->{'remote'})) {
				$trackcount--;
				next;
			}
			my $BACKUPtrackURL = $APCTrack->{'url'};
			my $BACKUPtrackURLmd5 = $APCTrack->{'urlmd5'};
			my $BACKUPplayCount = $APCTrack->{'playcount'} || 0;
			my $BACKUPlastPlayed = $APCTrack->{'lastplayed'} || 0;
			my $BACKUPskipCount = $APCTrack->{'skipcount'} || 0;
			my $BACKUPlastSkipped = $APCTrack->{'lastskipped'} || 0;
			my $BACKUPdynPSval = $APCTrack->{'dynpsval'} || 0;
			my $BACKUPremote = $APCTrack->{'remote'};
			my $BACKUPrelFilePath = ($BACKUPremote == 0 ? getRelFilePath($BACKUPtrackURL) : '');
			my $BACKUPtrackMBID = $APCTrack->{'musicbrainzid'} || '';

			$BACKUPtrackURL = escape($BACKUPtrackURL);
			$BACKUPrelFilePath = $BACKUPrelFilePath ? escape($BACKUPrelFilePath) : '';
			print $output "\t<track>\n\t\t<url>".$BACKUPtrackURL."</url>\n\t\t<urlmd5>".$BACKUPtrackURLmd5."</urlmd5>\n\t\t<relurl>".$BACKUPrelFilePath."</relurl>\n\t\t<playcount>".$BACKUPplayCount."</playcount>\n\t\t<lastplayed>".$BACKUPlastPlayed."</lastplayed>\n\t\t<skipcount>".$BACKUPskipCount."</skipcount>\n\t\t<lastskipped>".$BACKUPlastSkipped."</lastskipped>\n\t\t<dynpsval>".$BACKUPdynPSval."</dynpsval>\n\t\t<remote>".$BACKUPremote."</remote>\n\t\t<musicbrainzid>".$BACKUPtrackMBID."</musicbrainzid>\n\t</track>\n";
		}
		print $output "</AlternativePlayCount>\n";

		print $output "<!-- This backup contains ".$trackcount.($trackcount == 1 ? " track" : " tracks")." -->\n";
		close $output;
		my $ended = time() - $started;
		main::DEBUGLOG && $log->is_debug && $log->debug('Backup completed after '.$ended.' seconds.');

		cleanupBackups();
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('Info: no tracks in APC database');
	}
	$prefs->set('status_creatingbackup', 0);
}

sub cleanupBackups {
	my $autodeletebackups = $prefs->get('autodeletebackups');
	my $backupFilesMin = $prefs->get('backupfilesmin');
	if (defined $autodeletebackups) {
		my $backupDir = $prefs->get('apcfolderpath');
		return unless (-d $backupDir);
		my $backupsdaystokeep = $prefs->get('backupsdaystokeep');
		my $maxkeeptime = $backupsdaystokeep * 24 * 60 * 60; # in seconds
		my @files;
		opendir(my $DH, $backupDir) or die "Error opening $backupDir: $!";
		@files = grep(/^APC_Backup_.*$/, readdir($DH));
		closedir($DH);
		main::DEBUGLOG && $log->is_debug && $log->debug('number of backup files found: '.scalar(@files));
		my $mtime;
		my $etime = int(time());
		my $n = 0;
		if (scalar(@files) > $backupFilesMin) {
			foreach my $file (@files) {
				my $filepath = catfile($backupDir, $file);
				$mtime = stat($filepath)->mtime;
				if (($etime - $mtime) > $maxkeeptime) {
					unlink($filepath) or die "Can't delete $file: $!";
					$n++;
					last if ((scalar(@files) - $n) <= $backupFilesMin);
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
	sprintf("%02dh:%02dm", $_[0]/3600, $_[0]/60%60);
}

sub isTimeOrEmpty {
	my $name = shift;
	my $arg = shift;
	if (!$arg || $arg eq '') {
		return 1;
	} elsif ($arg =~ m/^([0\s]?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$/isg) {
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

sub commit {
	my $dbh = shift;
	if (!$dbh->{'AutoCommit'}) {
		$dbh->commit();
	}
}

sub rollback {
	my $dbh = shift;
	if (!$dbh->{'AutoCommit'}) {
		$dbh->rollback();
	}
}

*escape = \&URI::Escape::uri_escape_utf8;
*unescape = \&URI::Escape::uri_unescape;

1;
