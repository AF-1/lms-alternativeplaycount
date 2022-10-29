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

package Plugins::AlternativePlayCount::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::Base);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Prefs;
use Slim::Utils::Text;
use Slim::Schema;
use Slim::Utils::DateTime;
use Data::Dumper;
use Digest::MD5 qw(md5_hex);
use base qw(FileHandle);
use File::Basename;
use File::Copy qw(move);
use File::Spec::Functions qw(:ALL);
use File::stat;
use FindBin qw($Bin);
use POSIX qw(strftime);
use Scalar::Util qw(blessed);
use Time::HiRes qw(time);
use URI::Escape qw(uri_escape_utf8 uri_unescape);
use XML::Parser;

use Plugins::AlternativePlayCount::Common ':all';
use Plugins::AlternativePlayCount::Importer;
use Plugins::AlternativePlayCount::Settings::Basic;
use Plugins::AlternativePlayCount::Settings::Backup;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.alternativeplaycount',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_ALTERNATIVEPLAYCOUNT',
});
my $serverPrefs = preferences('server');
my $prefs = preferences('plugin.alternativeplaycount');

my (%restoreitem, $currentKey, $inTrack, $inValue, $backupParser, $backupParserNB, $restorestarted, %itemNames);
my $opened = 0;

sub initPlugin {
	my $class = shift;
	my $client = shift;
	$class->SUPER::initPlugin(@_);

	initPrefs();

	if (main::WEBUI) {
		Plugins::AlternativePlayCount::Settings::Basic->new($class);
		Plugins::AlternativePlayCount::Settings::Backup->new($class);

		Slim::Web::Pages->addPageFunction('resetq', \&resetValChoiceWeb);
		Slim::Web::Pages->addPageFunction('resetvalue', \&resetValueWeb);
	}

	Slim::Menu::TrackInfo->registerInfoProvider(apcplaycount => (
		parent => 'moreinfo', isa => 'bottom',
		func => sub { return trackInfoHandler('playCount', @_); }
	));
	Slim::Menu::TrackInfo->registerInfoProvider(apclastplayed => (
		parent => 'moreinfo',
		after => 'apcplaycount',
		before => 'apcskipcount',
		func => sub { return trackInfoHandler('lastPlayed', @_); }
	));
	Slim::Menu::TrackInfo->registerInfoProvider(apcskipcount => (
		parent => 'moreinfo',
		after => 'apcplaycount',
		func => sub { return trackInfoHandler('skipCount', @_); }
	));
	Slim::Menu::TrackInfo->registerInfoProvider(apclastskipped => (
		parent => 'moreinfo',
		after => 'apcskipcount',
		func => sub { return trackInfoHandler('lastSkipped', @_); }
	));

	Slim::Music::Import->addImporter('Plugins::AlternativePlayCount::Importer', {
		'type' => 'post',
		'weight' => 299,
		'use' => 1,
	});

	Slim::Control::Request::addDispatch(['alternativeplaycount','resetvaluechoice','_infoitem', '_urlmd5'], [0, 1, 1, \&resetValueChoiceJive]);
	Slim::Control::Request::addDispatch(['alternativeplaycount','resetvalue','_infoitem', '_urlmd5'], [0, 1, 1, \&resetValueJive]);

	Slim::Control::Request::subscribe(\&_setRefreshCBTimer, [['rescan'], ['done']]);
	Slim::Control::Request::subscribe(\&_APCcommandCB,[['mode', 'play', 'stop', 'pause', 'playlist']]);
}

sub postinitPlugin {
	unless (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		initDatabase();
		backupScheduler();
	}
}

sub initPrefs {
	$prefs->init({
		apcparentfolderpath => $serverPrefs->get('playlistdir'),
		playedtreshold_percent => 20,
		undoskiptimespan => 5,
		alwaysdisplayvals => 1,
		dbpopminplaycount => 1,
		prescanbackup => 1,
		backuptime => '05:28',
		backup_lastday => '',
		backupsdaystokeep => 30,
		backupfilesmin => 20,
		postscanscheduledelay => 20
	});

	createAPCfolder();

	$prefs->setValidate(sub {
		return if (!$_[1] || !(-d $_[1]) || (main::ISWINDOWS && !(-d Win32::GetANSIPathName($_[1]))) || !(-d Slim::Utils::Unicode::encode_locale($_[1])));
		my $apcFolderPath = catdir($_[1], 'AlternativePlayCount');
		eval {
			mkdir($apcFolderPath, 0755) unless (-d $apcFolderPath);
			chdir($apcFolderPath);
		} or do {
			$log->warn("Could not create or access AlternativePlayCount folder in parent folder '$_[1]'!");
			return;
		};
		$prefs->set('apcfolderpath', $apcFolderPath);
		return 1;
	}, 'apcparentfolderpath');

	$prefs->set('status_creatingbackup', '0');
	$prefs->set('status_restoringfrombackup', '0');
	$prefs->set('status_resetapcdatabase', '0');

	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 15}, 'undoskiptimespan');
	$prefs->setValidate({'validator' => \&isTimeOrEmpty}, 'backuptime');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 365}, 'backupsdaystokeep');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 10, 'high' => 90}, 'playedtreshold_percent');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 50}, 'dbpopminplaycount');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 5, 'high' => 600}, 'postscanscheduledelay');
	$prefs->setValidate('file', 'restorefile');

	%itemNames = ('playCount' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_DISPLAY_APCPLAYCOUNT'),
				'lastPlayed' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_DISPLAY_APCLASTPLAYED'),
				'skipCount' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_DISPLAY_APCSKIPCOUNT'),
				'lastSkipped' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_DISPLAY_APCLASTSKIPPED') );
}

sub trackInfoHandler {
	my ($infoItem, $client, $url, $track, $remoteMeta, $tags, $filter) = @_;

	my $alwaysDisplayVals = $prefs->get('alwaysdisplayvals');
	my $returnVal = 0;
	my ($apcPlayCount, $apcLastPlayed, $persistentPlayCount, $persistentLastPlayed, $apcSkipCount, $apcLastSkipped);
	my $urlmd5 = $track->urlmd5 || md5_hex($url);
	my $dbh = getCurrentDBH();

	my $sql = "select ifnull(alternativeplaycount.playCount, 0), ifnull(alternativeplaycount.lastPlayed, 0), ifnull(alternativeplaycount.skipCount, 0), ifnull(alternativeplaycount.lastSkipped, 0), ifnull(tracks_persistent.playCount, 0), ifnull(tracks_persistent.lastPlayed, 0) from alternativeplaycount left join tracks_persistent on tracks_persistent.urlmd5 = alternativeplaycount.urlmd5 where alternativeplaycount.urlmd5 = \"$urlmd5\"";
	eval {
			my $sth = $dbh->prepare($sql);
			$sth->execute() or do {
				$sql = undef;
				$log->warn("Error executing: $sql");
			};
			$sth->bind_columns(undef, \$apcPlayCount, \$apcLastPlayed, \$apcSkipCount, \$apcLastSkipped, \$persistentPlayCount, \$persistentLastPlayed);
			$sth->fetch();
			$sth->finish();
	};
	if ($@) {
		$log->warn("Database error: $DBI::errstr");
	}
	$log->debug('apcPlayCount = '.$apcPlayCount.' -- persistentPlayCount = '.$persistentPlayCount.' -- apcSkipCount = '.$apcSkipCount.' -- apcLastPlayed = '.$apcLastPlayed.' -- persistentLastPlayed = '.$persistentLastPlayed.' -- apcLastSkipped = '.$apcLastSkipped);

	if ($infoItem eq 'playCount') {
		# Don't display APC play count if values in APC and LMS table are the same or value is zero
		if ($apcPlayCount == $persistentPlayCount || $apcPlayCount == 0) {
			return unless $alwaysDisplayVals;
		}
		$returnVal = $apcPlayCount;
	}

	if ($infoItem eq 'lastPlayed') {
		# Don't display APC date last played if play count OR last played values in APC and LMS table are the same or value is zero
		if ($apcPlayCount == $persistentPlayCount || $apcLastPlayed == $persistentLastPlayed || $apcLastPlayed == 0) {
			return unless $alwaysDisplayVals;
		}
		if ($apcLastPlayed == 0) {
			$returnVal = string('PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_NEVER');
		} else {
			$returnVal = Slim::Utils::DateTime::longDateF($apcLastPlayed).", ".Slim::Utils::DateTime::timeF($apcLastPlayed);
		}
	}

	if ($infoItem eq 'skipCount') {
		# Don't display APC skip count if value is zero
		unless ($alwaysDisplayVals) {
			return if $apcSkipCount == 0;
		}
		$returnVal = $apcSkipCount;
	}

	if ($infoItem eq 'lastSkipped') {
		unless ($alwaysDisplayVals) {
			return if $apcLastSkipped == 0;
		}
		if ($apcLastSkipped == 0) {
			$returnVal = string('PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_NEVER');
		} else {
			$returnVal = Slim::Utils::DateTime::longDateF($apcLastSkipped).", ".Slim::Utils::DateTime::timeF($apcLastSkipped);
		}
	}

	my $displayText = $itemNames{$infoItem}.': '.$returnVal;

	if ($tags->{menuMode}) {
		my $jive = {};
		my $actions = {
			go => {
				player => 0,
				cmd => ['alternativeplaycount', 'resetvaluechoice', $infoItem, $urlmd5],
			},
		};
		if ($infoItem eq 'lastPlayed' || $infoItem eq 'lastSkipped') {
			return {
				type => 'text',
				name => $displayText,
			};
		}

		$jive->{actions} = $actions;
		return {
			type => 'redirect',
			name => $displayText,
			jive => $jive,
		};
	} else {
		my $item = {
			type => 'text',
			name => $displayText,
			urlmd5 => $urlmd5,
			infoitem => $infoItem,
		};
		unless ($infoItem eq 'lastPlayed' || $infoItem eq 'lastSkipped') {
			$item->{'web'} = {
				'type' => 'htmltemplate',
				'value' => 'plugins/AlternativePlayCount/html/displayapcvalue.html',
			};
		}

		delete $item->{type};
		$item->{name} = $displayText;

		if ($infoItem eq 'lastPlayed' || $infoItem eq 'lastSkipped') {
			$item->{type} = 'text';
			return $item;
		} else {
			$item->{url} = \&resetValChoiceVFD;
			$item->{passthrough} = [$infoItem, $urlmd5];
		}

		my @items = ();
		my $choiceText = string('PLUGIN_ALTERNATIVEPLAYCOUNT_WEB_RESETVALUE').' '.$itemNames{$infoItem}.' '.string('PLUGIN_ALTERNATIVEPLAYCOUNT_WEB_RESETVALUE_TRACK');
		push(@items, {
			name => $choiceText,
			url => \&resetValVFD,
			passthrough => [$infoItem, $urlmd5],
		});
		$item->{items} = \@items;
		return $item;
	}
}

sub resetValChoiceWeb {
	my ($client, $params, $callback, $httpClient, $response) = @_;

	my $urlmd5 = $params->{urlmd5};
	my $infoItem = $params->{infoitem};
	$params->{name} = $itemNames{$infoItem};
	$params->{infoitem} = $infoItem;
	$params->{urlmd5} = $urlmd5;
	$log->debug('name = '.$itemNames{$infoItem}.' ## infoItem = '.$infoItem.' ## urlmd5 = '.$urlmd5);

	return Slim::Web::HTTP::filltemplatefile('plugins/AlternativePlayCount/html/resetq.html', $params);
}

sub resetValueWeb {
	my ($client, $params, $callback, $httpClient, $response) = @_;

	my $urlmd5 = $params->{urlmd5};
	my $infoItem = $params->{infoitem};
	$log->debug('infoItem = '.$infoItem.' ## urlmd5 = '.$urlmd5);

	resetValue($infoItem, $urlmd5);
}

sub resetValueChoiceJive {
	my $request = shift;
	my $client = $request->client();

	if (!$request->isQuery([['alternativeplaycount'],['resetvaluechoice']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required!');
		$request->setStatusNeedsClient();
		return;
	}
	my $infoItem = $request->getParam('_infoitem');
	my $urlmd5 = $request->getParam('_urlmd5');
	$log->debug('infoItem = '.$infoItem.' ## urlmd5 = '.$urlmd5);

	my $action = {
		'do' => {
			'player' => 0,
			'cmd' => ['alternativeplaycount', 'resetvalue', $infoItem, $urlmd5],
		},
		'play' => {
			'player' => 0,
			'cmd' => ['alternativeplaycount', 'resetvalue', $infoItem, $urlmd5],
		},
	};
	my $windowTitle = string('PLUGIN_ALTERNATIVEPLAYCOUNT_WEB_RESETVALUE').' '.$itemNames{$infoItem};
	my $displayText = $windowTitle.' '.string('PLUGIN_ALTERNATIVEPLAYCOUNT_WEB_RESETVALUE_TRACK');
	$request->addResultLoop('item_loop', 0, 'text', $displayText);
	$request->addResultLoop('item_loop', 0, 'type', 'redirect');
	$request->addResultLoop('item_loop', 0, 'actions', $action);
	$request->addResultLoop('item_loop', 0, 'nextWindow', 'parent');

	my $materialCaller = 1 if (defined($request->{'_connectionid'}) && $request->{'_connectionid'} =~ 'Slim::Web::HTTP::ClientConn' && defined($request->{'_source'}) && $request->{'_source'} eq 'JSONRPC');
	# Material always displays last selection as window title. Add correct window title as textarea
	if ($materialCaller) {
		$request->addResult('window', {textarea => $windowTitle});
	} else {
		$request->addResult('window', {text => $windowTitle});
	}
	$request->addResult('offset', 0);
	$request->addResult('count', 1);
	$request->setStatusDone();
}

sub resetValueJive {
	my $request = shift;
	my $client = $request->client();

	if (!$request->isQuery([['alternativeplaycount'],['resetvalue']])) {
		$log->warn('incorrect command');
		$request->setStatusBadDispatch();
		return;
	}
	if (!defined $client) {
		$log->warn('client required!');
		$request->setStatusNeedsClient();
		return;
	}
	my $infoItem = $request->getParam('_infoitem');
	my $urlmd5 = $request->getParam('_urlmd5');
	$log->debug('infoItem = '.$infoItem.' ## urlmd5 = '.$urlmd5);

	resetValue($infoItem, $urlmd5);

	$request->setStatusDone();
}

sub resetValVFD {
	my ($client, $callback, $params, $infoItem, $urlmd5) = @_;
	$log->debug('infoItem = '.$infoItem);
	$log->debug('urlmd5 = '.$urlmd5);

	resetValue($infoItem, $urlmd5);
	my $cbtext = string('PLUGIN_ALTERNATIVEPLAYCOUNT_RESETVALUE_CB');
	$callback->([{
		type => 'text',
		name => $cbtext,
		showBriefly => 1, popback => 3,
		favorites => 0, refresh => 1,
	}]);
}

sub resetValue {
	my ($infoItem, $urlmd5) = @_;
	return if (!$infoItem || !$urlmd5);

	my $sqlstatement;
	if ($infoItem eq 'playCount') {
		$sqlstatement = "update alternativeplaycount set playCount = null, lastPlayed = null where urlmd5 = \"$urlmd5\"";
	} elsif ($infoItem eq 'skipCount') {
		$sqlstatement = "update alternativeplaycount set skipCount = null, lastSkipped = null where urlmd5 = \"$urlmd5\"";
	}

	return if (!$sqlstatement);
	executeSQLstat($sqlstatement);
	$log->debug("Finished resetting value for \"$infoItem\"");
}


## mark as played or skipped

sub _APCcommandCB {
	my $request = shift;
	my $client = $request->client();

	if (Slim::Music::Import->stillScanning) {
		$log->debug('Access to APC table blocked until library scan is completed.');
		return;
	}

	if (!defined $client) {
		$log->debug('No client. Exiting APCcommandCB');
		return;
	}

	my $clientID = $client->id();
	$log->debug('Received command "'.$request->getRequestString().'" from client "'.$clientID.'"');
	my $track = $::VERSION lt '8.2' ? Slim::Player::Playlist::song($client) : Slim::Player::Playlist::track($client);

	if (defined $track) {
		if (defined $track && !defined($track->url)) {
			$log->warn('No track url. Exiting.');
			return;
		}
		my $currentTrackURL = $track->url;
		my $currentTrackURLmd5 = $track->urlmd5;
		my $previousTrackURL = $client->pluginData('currentTrackURL');
		my $previousTrackURLmd5 = $client->pluginData('currentTrackURLmd5');
		$log->debug('Current track on client "'.$clientID.'" is '.$currentTrackURL.' with urlmd5 = '.$currentTrackURLmd5);
		$log->debug('Previous track on client "'.$clientID.'" is '.Dumper($previousTrackURL).' with urlmd5 = '.Dumper($previousTrackURLmd5));

		## newsong
		if ($request->isCommand([['playlist'],['newsong']])) {
			$log->debug('Received "newsong" cb.');
			# stop old timer for this client
			Slim::Utils::Timers::killTimers($client, \&markAsPlayed);

			# check current track url against previous track url because jumping inside a track also triggers newsong event
			if (!defined($previousTrackURL) || ($currentTrackURL ne $previousTrackURL)) {
				# if previous song wasn't marked as played, mark as skipped
				if (defined($previousTrackURL) && (!defined($client->pluginData('markedAsPlayed')) || $client->pluginData('markedAsPlayed') ne $previousTrackURL)) {
					markAsSkipped($previousTrackURL, $previousTrackURLmd5);
				}

				$client->pluginData('markedAsPlayed' => undef);
				$client->pluginData('currentTrackURL' => $currentTrackURL);
				$client->pluginData('currentTrackURLmd5' => $currentTrackURLmd5);
			}

			startPlayCountTimer($client, $track);
		}

		## play
		if (($request->isCommand([['playlist'],['play']])) || ($request->isCommand([['mode','play']]))) {
			$log->debug('Received "play" or "mode play" cb.');
			startPlayCountTimer($client, $track);
		}

		## pause
		if ($request->isCommand([['pause']]) || $request->isCommand([['mode'],['pause']])) {
			$log->debug('Received "pause" or "mode pause" cb.');
			my $playmode = Slim::Player::Source::playmode($client);
			$log->debug('playmode = '.$playmode);

			if ($playmode eq 'pause') {
				Slim::Utils::Timers::killTimers($client, \&markAsPlayed);
			} elsif ($playmode eq 'play') {
				startPlayCountTimer($client, $track);
			}
		}

		## stop
		if ($request->isCommand([["stop"]]) || $request->isCommand([['mode'],['stop']]) || $request->isCommand([['playlist'],['stop']]) || $request->isCommand([['playlist'],['sync']]) || $request->isCommand([['playlist'],['clear']]) || $request->isCommand([['power']])) {
			$log->debug('Received "stop", "clear", "power" or "sync" cb.');
			Slim::Utils::Timers::killTimers($client, \&markAsPlayed);
			$client->pluginData('markedAsPlayed' => undef);
			$client->pluginData('currentTrackURL' => undef);
		}
	}
}

sub startPlayCountTimer {
	my ($client, $track) = @_;

	# check if track has been marked as played already
	if ($client->pluginData('markedAsPlayed') && $client->pluginData('markedAsPlayed') eq $track->url) {
		$log->debug('Song has already been marked as played in this session.');
		return;
	}

	my $playedTreshold_percent = ($prefs->get('playedtreshold_percent') || 20) / 100;
	my $songProgress = Slim::Player::Source::progress($client);
	$log->debug('playedTreshold_percent = '.($playedTreshold_percent * 100).'% -- songProgress so far = '.(sprintf "%.1f", ($songProgress * 100)).'%');

	if ($songProgress >= $playedTreshold_percent) {
		$log->debug('songProgress > playedTreshold_percent. Will mark song as played.');
		markAsPlayed($client, $track->url, $track->urlmd5);
	} else {
		my $songDuration = $track->secs;
		my $remainingTresholdTime = $songDuration * $playedTreshold_percent - $songDuration * $songProgress;
		$log->debug('songDuration = '.$songDuration.' seconds -- remainingTresholdTime = '.(sprintf "%.1f", $remainingTresholdTime).' seconds');

		# Start timer for new song
		Slim::Utils::Timers::setTimer($client, time() + $remainingTresholdTime, \&markAsPlayed, $track->url, $track->urlmd5);
	}
}

sub markAsPlayed {
	my ($client, $trackURL, $trackURLmd5) = @_;
	$log->info('Marking track with url "'.$trackURL.'" as played. urlmd5 = '.Dumper($trackURLmd5));
	$client->pluginData('markedAsPlayed' => $trackURL);
	$trackURLmd5 = md5_hex($trackURL) if !$trackURLmd5;
	my $lastPlayed = time();

	my $sqlstatement = "update alternativeplaycount set playCount = ifnull(playCount, 0) + 1, lastPlayed = $lastPlayed where urlmd5 = \"$trackURLmd5\"";
	executeSQLstat($sqlstatement);
	$log->debug('Marked track as played.');

	# if the track was skipped very recently => undo last skip count increment
	undoLastSkipCountIncrement($trackURL, $trackURLmd5);
}

sub markAsSkipped {
	my ($trackURL, $trackURLmd5) = @_;
	$log->info('Marking track with url "'.$trackURL.'" as skipped. urlmd5 = '.Dumper($trackURLmd5));
	$trackURLmd5 = md5_hex($trackURL) if !$trackURLmd5;
	my $lastSkipped = time();

	my $sqlstatement = "update alternativeplaycount set skipCount = ifnull(skipCount, 0) + 1, lastSkipped = $lastSkipped where urlmd5 = \"$trackURLmd5\"";
	executeSQLstat($sqlstatement);
	$log->debug('Marked track as skipped.');
}

sub undoLastSkipCountIncrement {
	my $undoSkipTimeSpan = $prefs->get('undoskiptimespan');
	if ($undoSkipTimeSpan > 0) {
		my ($trackURL, $trackURLmd5) = @_;
		$trackURLmd5 = md5_hex($trackURL) if !$trackURLmd5;
		my $lastSkippedSQL = "select ifnull(alternativeplaycount.lastSkipped, 0) from alternativeplaycount left join tracks_persistent on tracks_persistent.urlmd5 = alternativeplaycount.urlmd5 where alternativeplaycount.urlmd5 = \"$trackURLmd5\"";
		my $lastSkipped = quickSQLquery($lastSkippedSQL);
		my $track = Slim::Schema->rs('Track')->single({'urlmd5' => $trackURLmd5});
		$track = Slim::Schema->objectForUrl({ 'url' => $trackURL }) if !$track;
		my $songDuration = $track->secs;
		my $playedTreshold_percent = ($prefs->get('playedtreshold_percent') || 20) / 100;

		if ($lastSkipped > 0 && (time()-$lastSkipped < ($undoSkipTimeSpan * 60 + $songDuration * $playedTreshold_percent))) {
			$log->info("Played track was skipped in the last $undoSkipTimeSpan mins. Reducing skip count by 1.");
			my $reduceSkipCountSQL = "update alternativeplaycount set skipCount = skipCount - 1 where urlmd5 = \"$trackURLmd5\"";
			executeSQLstat($reduceSkipCountSQL);
		}
	}
}


## backup, restore

sub backupScheduler {
	my $scheduledbackups = $prefs->get('scheduledbackups');
	if (defined $scheduledbackups) {
		my $backuptime = $prefs->get('backuptime');
		my $day = $prefs->get('backup_lastday');
		if (!defined($day)) {
			$day = '';
		}

		if (defined($backuptime) && $backuptime ne '') {
			my $time = 0;
			$backuptime =~ s{
				^(0?[0-9]|1[0-9]|2[0-4]):([0-5][0-9])\s*(P|PM|A|AM)?$
			}{
				if (defined $3) {
					$time = ($1 == 12?0:$1 * 60 * 60) + ($2 * 60) + ($3 =~ /P/?12 * 60 * 60:0);
				} else {
					$time = ($1 * 60 * 60) + ($2 * 60);
				}
			}iegsx;
			my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time);

			my $currenttime = $hour * 60 * 60 + $min * 60;

			if (($day ne $mday) && $currenttime>$time) {
				eval {
					createBackup();
				};
				if ($@) {
					$log->error("Scheduled backup failed: $@");
				}
				$prefs->set('backup_lastday',$mday);
			} else {
				my $timesleft = $time-$currenttime;
				if ($day eq $mday) {
					$timesleft = $timesleft + 60*60*24;
				}
				$log->debug(parse_duration($timesleft)." ($timesleft seconds) left until next scheduled backup");
			}
		}
		Slim::Utils::Timers::setTimer(0, time() + 3600, \&backupScheduler);
	}
}

sub restoreFromBackup {
	if (Slim::Music::Import->stillScanning) {
		$log->warn('Warning: access to APC table blocked until library scan is completed');
		return;
	}

	my $status_restoringfrombackup = $prefs->get('status_restoringfrombackup');
	my $clearallbeforerestore = $prefs->get('clearallbeforerestore');

	if ($status_restoringfrombackup == 1) {
		$log->warn('Restore is already in progress, please wait for the previous restore to finish');
		return;
	}

	$prefs->set('status_restoringfrombackup', 1);
	$restorestarted = time();
	my $restorefile = $prefs->get('restorefile');

	if ($restorefile) {
		if (defined $clearallbeforerestore) {
			resetAPCDatabase(1);
		}
		initRestore();
		Slim::Utils::Scheduler::add_task(\&restoreScanFunction);
	} else {
		$log->error('Error: No backup file specified');
		$prefs->set('status_restoringfrombackup', 0);
	}
}

sub initRestore {
	if (defined($backupParserNB)) {
		eval {$backupParserNB->parse_done};
		$backupParserNB = undef;
	}
	$backupParser = XML::Parser->new(
		'ErrorContext' => 2,
		'ProtocolEncoding' => 'UTF-8',
		'NoExpand' => 1,
		'NoLWP' => 1,
		'Handlers' => {
			'Start' => \&handleStartElement,
			'Char' => \&handleCharElement,
			'End' => \&handleEndElement,
		},
	);
}

sub restoreScanFunction {
	my $restorefile = $prefs->get('restorefile');
	if ($opened != 1) {
		open(BACKUPFILE, $restorefile) || do {
			$log->warn('Couldn\'t open backup file: '.$restorefile);
			$prefs->set('status_restoringfrombackup', 0);
			return 0;
		};
		$opened = 1;
		$inTrack = 0;
		$inValue = 0;
		%restoreitem = ();
		$currentKey = undef;

		if (defined $backupParser) {
			$backupParserNB = $backupParser->parse_start();
		} else {
			$log->warn('No backupParser was defined!');
		}
	}

	if (defined $backupParserNB) {
		local $/ = '>';
		my $line;

		for (my $i = 0; $i < 25;) {
			my $singleLine = <BACKUPFILE>;
			if (defined($singleLine)) {
				$line .= $singleLine;
				if ($singleLine =~ /(<\/track>)$/) {
					$i++;
				}
			} else {
				last;
			}
		}
		$line =~ s/&#(\d*);/uri_escape_utf8(chr($1))/ge;
		$backupParserNB->parse_more($line);
		return 1;
	}

	$log->warn('No backupParserNB defined!');
	$prefs->set('status_restoringfrombackup', 0);
	return 0;
}

sub doneScanning {
	if (defined $backupParserNB) {
		eval {$backupParserNB->parse_done};
	}

	$backupParserNB = undef;
	$backupParser = undef;
	$opened = 0;
	close(BACKUPFILE);

	my $ended = time() - $restorestarted;
	$log->debug('Restore completed after '.$ended.' seconds.');
	sleep(1.5); # if task is removed too soon from scheduler => undef val as sub ref error
	Slim::Utils::Scheduler::remove_task(\&restoreScanFunction);
	$prefs->set('status_restoringfrombackup', 0);
}

sub handleStartElement {
	my ($p, $element) = @_;

	if ($inTrack) {
		$currentKey = $element;
		$inValue = 1;
	}
	if ($element eq 'track') {
		$inTrack = 1;
	}
}

sub handleCharElement {
	my ($p, $value) = @_;

	if ($inValue && $currentKey) {
		$restoreitem{$currentKey} = $value;
	}
}

sub handleEndElement {
	my ($p, $element) = @_;
	$inValue = 0;

	if ($inTrack && $element eq 'track') {
		$inTrack = 0;

		my $curTrack = \%restoreitem;
		my $trackURL = undef;
		my $fullTrackURL = $curTrack->{'url'};
		my $trackURLmd5 = $curTrack->{'urlmd5'};
		my $relTrackURL = $curTrack->{'relurl'};

		# check if FULL file url is valid
		# Otherwise, try RELATIVE file URL with current media dirs
		$fullTrackURL = Encode::decode('utf8', uri_unescape($fullTrackURL));
		$relTrackURL = Encode::decode('utf8', uri_unescape($relTrackURL));

		my $fullTrackPath = pathForItem($fullTrackURL);
		if (-f $fullTrackPath) {
			#$log->debug("found file at url \"$fullTrackPath\"");
			$trackURL = $fullTrackURL;
		} else {
			$log->debug("** Couldn't find file for FULL file url. Will try with RELATIVE file url and current LMS media folders.");
			my $lmsmusicdirs = getMusicDirs();
			$log->debug('Valid LMS music dirs = '.Dumper($lmsmusicdirs));

			foreach (@{$lmsmusicdirs}) {
				my $dirSep = File::Spec->canonpath("/");
				my $mediaDirURL = Slim::Utils::Misc::fileURLFromPath($_.$dirSep);
				$log->debug('Trying LMS music dir url: '.$mediaDirURL);

				my $newFullTrackURL = $mediaDirURL.$relTrackURL;
				my $newFullTrackPath = pathForItem($newFullTrackURL);
				$log->debug('Trying with new full track path: '.$newFullTrackPath);

				if (-f $newFullTrackPath) {
					$trackURL = Slim::Utils::Misc::fileURLFromPath($newFullTrackURL);
					$log->debug('Found file at new full file url: '.$trackURL);
					$log->debug('OLD full file url was: '.$fullTrackURL);
					last;
				}
			}
		}
		if (!$trackURL && !$trackURLmd5) {
			$log->warn("Neither track urlmd5 nor valid track url. Can't restore values for file with restore url \"$fullTrackURL\"");
		} else {
			$trackURLmd5 = md5_hex($trackURL) if !$trackURLmd5;
			my $playCount = ($curTrack->{'playcount'} == 0 ? "null" : $curTrack->{'playcount'});
			my $lastPlayed = ($curTrack->{'lastplayed'} == 0 ? "null" : $curTrack->{'lastplayed'});
			my $skipCount = ($curTrack->{'skipcount'} == 0 ? "null" : $curTrack->{'skipcount'});
			my $lastSkipped = ($curTrack->{'lastskipped'} == 0 ? "null" : $curTrack->{'lastskipped'});

			my $sqlstatement = "update alternativeplaycount set playCount = $playCount, lastPlayed = $lastPlayed, skipCount = $skipCount, lastSkipped = $lastSkipped where urlmd5 = \"$trackURLmd5\"";
			executeSQLstat($sqlstatement);
		}
		%restoreitem = ();
	}
	if ($element eq 'AlternativePlayCount') {
		doneScanning();
		return 0;
	}
}


## CustomSkip filters ##

sub getCustomSkipFilterTypes {
	my @result = ();

	my %recentlyplayedtracks = (
		'id' => 'alternativeplaycount_recentlyplayedtrack',
		'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_TRACKSRECENTLYPLAYED_NAME"),
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_TRACKSRECENTLYPLAYED_DESC"),
		'parameters' => [
			{
				'id' => 'time',
				'type' => 'singlelist',
				'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_TRACKSRECENTLYPLAYED_PARAM_NAME"),
				'data' => '300=5 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',600=10 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',900=15 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',1800=30 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',3600=1 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOUR").',7200=2 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',10800=3 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',21600=6 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',43200=12 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',86400=24 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',259200=3 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_DAYS").',604800=1 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_WEEK"),
				'value' => 3600
			}
		]
	);
	push @result, \%recentlyplayedtracks;

	my %recentlyskippedtracks = (
		'id' => 'alternativeplaycount_recentlyskippedtrack',
		'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_TRACKSRECENTLYSKIPPED_NAME"),
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_TRACKSRECENTLYSKIPPED_DESC"),
		'parameters' => [
			{
				'id' => 'time',
				'type' => 'singlelist',
				'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_TRACKSRECENTLYSKIPPED_PARAM_NAME"),
				'data' => '300=5 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',600=10 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',900=15 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',1800=30 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',3600=1 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOUR").',7200=2 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',10800=3 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',21600=6 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',43200=12 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',86400=24 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',259200=3 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_DAYS").',604800=1 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_WEEK"),
				'value' => 3600
			}
		]
	);
	push @result, \%recentlyskippedtracks;

	my %highapcskipcount = (
		'id' => 'alternativeplaycount_highapcskipcount',
		'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_HIGHAPCSKIPCOUNT_NAME"),
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_HIGHAPCSKIPCOUNT_DESC"),
		'parameters' => [
			{
				'id' => 'apcskipcount',
				'type' => 'singlelist',
				'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_HIGHAPCSKIPCOUNT_PARAM_NAME"),
				'data' => '1=1,5=5,10=10,20=20,30=30,40=40,50=50,60=60,70=70,80=80,90=90,100=100',
				'value' => 3600
			}
		]
	);
	push @result, \%highapcskipcount;

	my %recentlyplayedalbums = (
		'id' => 'alternativeplaycount_recentlyplayedalbum',
		'name' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_RECENTLYPLAYEDALBUM_NAME'),
		'filtercategory' => 'albums',
		'description' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_RECENTLYPLAYEDALBUM_DESC'),
		'parameters' => [
			{
				'id' => 'time',
				'type' => 'singlelist',
				'name' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_RECENTLYPLAYEDALBUM_PARAM_NAME'),
				'data' => '300=5 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',600=10 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',900=15 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',1800=30 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',3600=1 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOUR").',7200=2 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',10800=3 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',21600=6 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',43200=12 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',86400=24 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',259200=3 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_DAYS").',604800=1 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_WEEK"),
				'value' => 900
			}
		]
	);
	push @result, \%recentlyplayedalbums;
	my %recentlyplayedartists = (
		'id' => 'alternativeplaycount_recentlyplayedartist',
		'name' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_RECENTLYPLAYEDARTIST_NAME'),
		'filtercategory' => 'artists',
		'description' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_RECENTLYPLAYEDARTIST_DESC'),
		'parameters' => [
			{
				'id' => 'time',
				'type' => 'singlelist',
				'name' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_RECENTLYPLAYEDARTIST_PARAM_NAME'),
				'data' => '300=5 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',600=10 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',900=15 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',1800=30 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_MINS").',3600=1 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOUR").',7200=2 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',10800=3 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',21600=6 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',43200=12 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',86400=24 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_HOURS").',259200=3 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_DAYS").',604800=1 '.string("PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_TIME_WEEK"),
				'value' => 900
			}
		]
	);
	push @result, \%recentlyplayedartists;
	return \@result;
}

sub checkCustomSkipFilterType {
	my $client = shift;
	my $filter = shift;
	my $track = shift;

	my $currentTime = time();
	my $parameters = $filter->{'parameter'};
	my $dbh = getCurrentDBH();
	my $sql = undef;
	my $result = 0;
	if ($filter->{'id'} eq 'alternativeplaycount_recentlyplayedtrack') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'time') {
				my $times = $parameter->{'value'};
				my $time = $times->[0] if (defined($times) && scalar(@{$times}) > 0);

				my $urlmd5 = $track->urlmd5;
				if (defined($urlmd5)) {
					my $lastPlayed;
					my $sth = $dbh->prepare("select ifnull(alternativeplaycount.lastPlayed, 0) from alternativeplaycount where alternativeplaycount.urlmd5 = ?");
					eval {
						$sth->bind_param(1, $urlmd5);
						$sth->execute();
						$sth->bind_columns(undef, \$lastPlayed);
						$sth->fetch();
					};
					if ($@) {
						$log->warn("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if (defined($lastPlayed) && (!defined($client->pluginData('markedAsPlayed')) || (defined($client->pluginData('markedAsPlayed')) && $client->pluginData('markedAsPlayed') ne $track->url))) {
						if (time() - $lastPlayed < $time) {
							return 1;
						}
					}
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'alternativeplaycount_recentlyskippedtrack') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'time') {
				my $times = $parameter->{'value'};
				my $time = $times->[0] if (defined($times) && scalar(@{$times}) > 0);

				my $urlmd5 = $track->urlmd5;
				if (defined($urlmd5)) {
					my $lastSkipped;
					my $sth = $dbh->prepare("select ifnull(alternativeplaycount.lastSkipped, 0) from alternativeplaycount where alternativeplaycount.urlmd5 = ?");
					eval {
						$sth->bind_param(1, $urlmd5);
						$sth->execute();
						$sth->bind_columns(undef, \$lastSkipped);
						$sth->fetch();
					};
					if ($@) {
						$log->warn("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if (defined($lastSkipped) && $lastSkipped > 0) {
						if (time() - $lastSkipped < $time) {
							return 1;
						}
					}
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'alternativeplaycount_highapcskipcount') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'apcskipcount') {
				my $skipCountValues = $parameter->{'value'};
				my $skipCountMax = $skipCountValues->[0] if (defined($skipCountValues) && scalar(@{$skipCountValues}) > 0);

				my $urlmd5 = $track->urlmd5;
				if (defined($urlmd5)) {
					my $skipCount;
					my $sth = $dbh->prepare("select ifnull(alternativeplaycount.skipCount, 0) from alternativeplaycount where alternativeplaycount.urlmd5 = ?");
					eval {
						$sth->bind_param(1, $urlmd5);
						$sth->execute();
						$sth->bind_columns(undef, \$skipCount);
						$sth->fetch();
					};
					if ($@) {
						$log->warn("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if (defined($skipCount) && !defined($client->pluginData('markedAsPlayed'))) {
						if ($skipCount > $skipCountMax) {
							return 1;
						}
					}
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'alternativeplaycount_recentlyplayedartist') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'time') {
				my $times = $parameter->{'value'};
				my $time = $times->[0] if (defined($times) && scalar(@{$times}) > 0);

				my $artist = $track->artist;
				if (defined($artist)) {
					my $lastPlayed;
					my $sth = $dbh->prepare("select max(ifnull(alternativeplaycount.lastPlayed,0)) from tracks, alternativeplaycount, contributor_track where tracks.urlmd5 = alternativeplaycount.urlmd5 and tracks.id = contributor_track.track and contributor_track.contributor = ?");
					eval {
						$sth->bind_param(1, $artist->id);
						$sth->execute();
						$sth->bind_columns(undef, \$lastPlayed);
						$sth->fetch();
					};
					if ($@) {
						$log->warn("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if (defined($lastPlayed) && (!defined($client->pluginData('markedAsPlayed')) || (defined($client->pluginData('markedAsPlayed')) && $client->pluginData('markedAsPlayed') ne $track->url))) {
						if (time() - $lastPlayed < $time) {
							return 1;
						}
					}
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'alternativeplaycount_recentlyplayedalbum') {
		for my $parameter (@$parameters) {
			if ($parameter->{'id'} eq 'time') {
				my $times = $parameter->{'value'};
				my $time = $times->[0] if (defined($times) && scalar(@{$times}) > 0);

				my $album = $track->album;
				if (defined($album)) {
					my $lastPlayed;
					my $sth = $dbh->prepare("select max(ifnull(alternativeplaycount.lastPlayed,0)) from tracks, alternativeplaycount where tracks.urlmd5 = alternativeplaycount.urlmd5 and tracks.album = ?");
					eval {
						$sth->bind_param(1, $album->id);
						$sth->execute();
						$sth->bind_columns(undef, \$lastPlayed);
						$sth->fetch();
					};
					if ($@) {
						$log->warn("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if (defined($lastPlayed) && (!defined($client->pluginData('markedAsPlayed')) || (defined($client->pluginData('markedAsPlayed')) && $client->pluginData('markedAsPlayed') ne $track->url))) {
						if (time() - $lastPlayed < $time) {
							return 1;
						}
					}
				}
				last;
			}
		}
	}
	return 0;
}



sub quickSQLquery {
	my $sqlstatement = shift;
	my $thisResult;
	my $dbh = getCurrentDBH();
	my $sth = $dbh->prepare($sqlstatement);
	$sth->execute();
	$sth->bind_columns(undef, \$thisResult);
	$sth->fetch();
	return $thisResult;
}

sub executeSQLstat {
	my $sqlstatement = shift;
	my $dbh = getCurrentDBH();

	for my $sql (split(/[\n\r]/, $sqlstatement)) {
		my $sth = $dbh->prepare($sql);
		eval {
			$sth->execute();
			commit($dbh);
		};
		if ($@) {
			$log->warn("Database error: $DBI::errstr");
			eval {
				rollback($dbh);
			};
		}
		$sth->finish();
	}
}

sub initDatabase {
	if (Slim::Music::Import->stillScanning) {
		$log->warn("Warning: can't initialize table until library scan is completed");
		return;
	}
	my $started = time();
	my $dbh = getCurrentDBH();
	my $sth = $dbh->table_info();
	my $tableExists;
	eval {
		while (my ($qual, $owner, $table, $type) = $sth->fetchrow_array()) {
			if ($table eq 'alternativeplaycount') {
				$tableExists = 1;
			}
		}
	};
	if($@) {
		$log->warn("Database error: $DBI::errstr\n");
	}
	$sth->finish();
	$log->debug($tableExists ? 'APC table table found.' : 'No APC table table found.');

	# create APC db table if it doesn't exist
	unless ($tableExists) {
		# create table
		$log->debug('Creating table.');
		my $sqlstatement = "create table if not exists persistentdb.alternativeplaycount (url text not null, playCount int(10), lastPlayed int(10), skipCount int(10), lastSkipped int(10), urlmd5 char(32) not null default '0');";
		$log->debug('Creating APC database table');
		executeSQLstat($sqlstatement);

		# create indices
		$log->debug('Creating indices.');
		my $dbIndex = "create index if not exists persistentdb.cpurlIndex on alternativeplaycount (url);
create index if not exists persistentdb.cpurlmd5Index on alternativeplaycount (urlmd5);";
		executeSQLstat($dbIndex);

		populateAPCtable(1);
	}
	refreshDatabase();
	my $ended = time() - $started;
	$log->info('DB init completed after '.$ended.' seconds.');
}

sub populateAPCtable {
	my $useLMSvalues = shift || 0;
	my $dbh = getCurrentDBH();

	if ($useLMSvalues == 1) {
		# populate table with playCount + lastPlayed values from persistentdb
		$log->debug('Populating empty APC table with values from LMS persistent database.');
		my $minPlayCount = $prefs->get('dbpopminplaycount');
		my $sql = "INSERT INTO alternativeplaycount (url,playCount,lastPlayed,urlmd5) select tracks.url,case when ifnull(tracks_persistent.playCount, 0) >= $minPlayCount then tracks_persistent.playCount else null end,case when ifnull(tracks_persistent.playCount, 0) >= $minPlayCount then tracks_persistent.lastPlayed else null end,tracks.urlmd5 from tracks left join tracks_persistent on tracks.urlmd5=tracks_persistent.urlmd5 left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5 where tracks.audio=1 and alternativeplaycount.urlmd5 is null;";

		my $sth = $dbh->prepare($sql);
		my $count = 0;
		eval {
			$count = $sth->execute();
			if($count eq '0E0') {
				$count = 0;
			}
			commit($dbh);
		};
		if($@) {
			$log->warn("Database error: $DBI::errstr\n");
			eval { rollback($dbh); };
		}
		$sth->finish();
	} else {
		# insert only values for track url & urlmd5
		$log->debug('Populating empty APC table with track urls.');
		my $sql = "INSERT INTO alternativeplaycount (url, urlmd5) select tracks.url, tracks.urlmd5 from tracks left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5 where tracks.audio = 1 and alternativeplaycount.urlmd5 is null;";
		my $sth = $dbh->prepare($sql);
		eval {
			$sth->execute();
			commit($dbh);
		};
		if($@) {
			$log->warn("Database error: $DBI::errstr\n");
			eval { rollback($dbh); };
		}
		$sth->finish();
	}
	$prefs->set('status_resetapcdatabase', 0);
}

sub refreshDatabase {
	if (Slim::Music::Import->stillScanning) {
		$log->warn("Warning: can't refresh database until library scan is completed.");
		return;
	}
	my $dbh = getCurrentDBH();
	my $sth;
	my $count;
	$log->debug('Refreshing APC database');

	# add new tracks
	$log->debug('If LMS database has new tracks, add them to APC database.');
	my $sqlstatement = "INSERT INTO alternativeplaycount (url, urlmd5) select tracks.url, tracks.urlmd5 from tracks left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5 where tracks.audio = 1 and alternativeplaycount.urlmd5 is null;";
	$sth = $dbh->prepare($sqlstatement);
	$count = 0;
	eval {
		$count = $sth->execute();
		if($count eq '0E0') {
			$count = 0;
		}
		commit($dbh);
	};
	if($@) {
		$log->warn("Database error: $DBI::errstr\n");
		eval { rollback($dbh); };
	}
	$sth->finish();

	removeDeadTracks();

	$dbh->do("analyze alternativeplaycount;");
	$log->debug('DB refresh complete.');
}

sub removeDeadTracks {
	my $database = shift || 'alternativeplaycount';
	my $dbh = getCurrentDBH();
	my $sth;
	my $count;
	$log->debug('Removing dead tracks from APC database that no longer exist in LMS database');

	my $sqlstatement = "delete from $database where urlmd5 not in (select urlmd5 from tracks where tracks.urlmd5 = $database.urlmd5)";

	$sth = $dbh->prepare($sqlstatement);
	$count = 0;
	eval {
		$count = $sth->execute();
		if($count eq '0E0') {
			$count = 0;
		}
		commit($dbh);
	};
	if($@) {
		$log->warn("Database error: $DBI::errstr\n");
		eval { rollback($dbh); };
	}

	$sth->finish();
	$log->debug('Finished removing dead tracks from DB.');
}

sub resetAPCDatabase {
	my $status_creatingbackup = $prefs->get('status_resetapcdatabase');
	if ($status_creatingbackup == 1) {
		$log->warn('A database reset is already in progress, please wait for the previous reset to finish');
		return;
	}
	$prefs->set('status_resetapcdatabase', 1);
	my $useLMSvalues = shift || 0;
	my $sqlstatement = "delete from alternativeplaycount";
	executeSQLstat($sqlstatement);
	$log->debug('APC table cleared.');
	populateAPCtable($useLMSvalues);
}

sub _setRefreshCBTimer {
	$log->debug('Killing existing timers for post-scan refresh to prevent multiple calls');
	Slim::Utils::Timers::killOneTimer(undef, \&delayedPostScanRefresh);
	$log->debug('Scheduling a delayed post-scan refresh');
	Slim::Utils::Timers::setTimer(undef, time() + $prefs->get('postscanscheduledelay'), \&delayedPostScanRefresh);
}

sub delayedPostScanRefresh {
	if (Slim::Music::Import->stillScanning) {
		$log->debug('Scan in progress. Waiting for current scan to finish.');
		_setRefreshCBTimer();
	} else {
		$log->debug('Starting post-scan database table refresh.');
		initDatabase();
	}
}

sub createAPCfolder {
	my $apcParentFolderPath = $prefs->get('apcparentfolderpath') || $serverPrefs->get('playlistdir');
	my $apcFolderPath = catdir($apcParentFolderPath, 'AlternativePlayCount');
	eval {
		mkdir($apcFolderPath, 0755) unless (-d $apcFolderPath);
		chdir($apcFolderPath);
	} or do {
		$log->error("Could not create or access AlternativePlayCount folder in parent folder '$apcParentFolderPath'!");
		return;
	};
	$prefs->set('apcfolderpath', $apcFolderPath);
}

1;
