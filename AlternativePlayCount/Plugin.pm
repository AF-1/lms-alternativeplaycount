#
# Alternative Play Count
#
# (c) 2022 AF
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
use Digest::MD5 qw(md5_hex);
use base qw(FileHandle);
use File::Basename;
use File::Copy qw(move);
use File::Spec::Functions qw(:ALL);
use File::stat;
use FindBin qw($Bin);
use POSIX qw(strftime floor ceil);
use Scalar::Util qw(blessed);
use Time::HiRes qw(time);
use XML::Parser;

use Plugins::AlternativePlayCount::Common ':all';
use Plugins::AlternativePlayCount::Importer;

my $log = Slim::Utils::Log->addLogCategory({
	'category' => 'plugin.alternativeplaycount',
	'defaultLevel' => 'ERROR',
	'description' => 'PLUGIN_ALTERNATIVEPLAYCOUNT',
});
my $serverPrefs = preferences('server');
my $prefs = preferences('plugin.alternativeplaycount');

my ($ratingslight_enabled, %restoreitem, $currentKey, $inTrack, $inValue, $backupParser, $backupParserNB, $restorestarted, %itemNames);
my $opened = 0;

sub initPlugin {
	my $class = shift;
	my $client = shift;
	$class->SUPER::initPlugin(@_);

	initPrefs();

	if (main::WEBUI) {
		require Plugins::AlternativePlayCount::Settings::Basic;
		require Plugins::AlternativePlayCount::Settings::Backup;
		require Plugins::AlternativePlayCount::Settings::Reset;
		require Plugins::AlternativePlayCount::Settings::Autorating;
		Plugins::AlternativePlayCount::Settings::Basic->new($class);
		Plugins::AlternativePlayCount::Settings::Backup->new($class);
		Plugins::AlternativePlayCount::Settings::Reset->new($class);
		Plugins::AlternativePlayCount::Settings::Autorating->new($class);

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
	Slim::Menu::TrackInfo->registerInfoProvider(apcdynpsval => (
		parent => 'moreinfo',
		after => 'apclastskipped',
		func => sub { return trackInfoHandler('dynPSval', @_); }
	));

	Slim::Music::Import->addImporter('Plugins::AlternativePlayCount::Importer', {
		'type' => 'post',
		'weight' => 299,
		'use' => 1,
	});

	addTitleFormat('APC_PLAYCOUNT');
	addTitleFormat('APC_SKIPCOUNT');
	addTitleFormat('APC_DPSV');
	Slim::Music::TitleFormatter::addFormat('APC_PLAYCOUNT',
		sub { my $track = shift; getTitleFormat($track, 'playCount'); }, 1);
	Slim::Music::TitleFormatter::addFormat('APC_SKIPCOUNT',
		sub { my $track = shift; getTitleFormat($track, 'skipCount'); }, 1);
	Slim::Music::TitleFormatter::addFormat('APC_DPSV',
		sub { my $track = shift; getTitleFormat($track, 'dynPSval'); }, 1);

	Slim::Control::Request::addDispatch(['alternativeplaycount','resetvaluechoice','_infoitem', '_urlmd5'], [0, 1, 1, \&resetValueChoiceJive]);
	Slim::Control::Request::addDispatch(['alternativeplaycount','resetvalue','_infoitem', '_urlmd5'], [0, 1, 1, \&resetValueJive]);

	Slim::Control::Request::subscribe(\&_setRefreshCBTimer, [['rescan'], ['done']]);
	Slim::Control::Request::subscribe(\&_APCcommandCB,[['mode', 'play', 'stop', 'pause', 'playlist']]);
}

sub postinitPlugin {
	unless (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning) {
		initDatabase();
		Slim::Utils::Timers::setTimer(undef, time() + 2, \&backupScheduler);
	}
	$ratingslight_enabled = Slim::Utils::PluginManager->isEnabled('Plugins::RatingsLight::Plugin');
	main::DEBUGLOG && $log->is_debug && $log->debug('Plugin "Ratings Light" is enabled') if $ratingslight_enabled;
}

sub initPrefs {
	$prefs->init({
		apcparentfolderpath => Slim::Utils::OSDetect::dirsFor('prefs'),
		playedthreshold_percent => 20,
		undoskiptimespan => 5,
		alwaysdisplayvals => 1,
		autoratingdynamicfactor => 8,
		autoratinglineardelta => 5,
		dbpopdpsvinitial => 1,
		dbpoplmsvalues => 1,
		dbpoplmsminplaycount => 1,
		prescanbackup => 1,
		backuptime => '05:28',
		backup_lastday => '',
		backupsdaystokeep => 30,
		backupfilesmin => 20,
		postscanscheduledelay => 20,
		ignoreCS3skiprequests => 1,
	});

	createAPCfolder();

	$prefs->setValidate(sub {
		return if (!$_[1] || !(-d $_[1]) || (main::ISWINDOWS && !(-d Win32::GetANSIPathName($_[1]))) || !(-d Slim::Utils::Unicode::encode_locale($_[1])));
		my $apcFolderPath = catdir($_[1], 'AlternativePlayCount');
		eval {
			mkdir($apcFolderPath, 0755) unless (-d $apcFolderPath);
		} or do {
			$log->error("Could not create AlternativePlayCount folder in parent folder '$_[1]'! Please make sure that LMS has read/write permissions (755) for the parent folder.");
			return;
		};
		$prefs->set('apcfolderpath', $apcFolderPath);
		return 1;
	}, 'apcparentfolderpath');

	$prefs->set('status_creatingbackup', '0');
	$prefs->set('status_restoringfrombackup', '0');
	$prefs->set('status_resetapcdatabase', '0');
	$prefs->set('isTSlegacyBackupFile', 0);

	$prefs->setValidate({'validator' => 'intlimit', 'low' => 0, 'high' => 15}, 'undoskiptimespan');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 10}, 'autoratinglineardelta');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 4, 'high' => 8}, 'autoratingdynamicfactor');
	$prefs->setValidate({'validator' => \&isTimeOrEmpty}, 'backuptime');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 365}, 'backupsdaystokeep');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 10, 'high' => 90}, 'playedthreshold_percent');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 1, 'high' => 50}, 'dbpoplmsminplaycount');
	$prefs->setValidate({'validator' => 'intlimit', 'low' => 5, 'high' => 600}, 'postscanscheduledelay');
	$prefs->setValidate('file', 'restorefile');

	%itemNames = ('playCount' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_DISPLAY_APCPLAYCOUNT'),
				'lastPlayed' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_DISPLAY_APCLASTPLAYED'),
				'skipCount' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_DISPLAY_APCSKIPCOUNT'),
				'lastSkipped' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_DISPLAY_APCLASTSKIPPED'),
				'dynPSval' => string('PLUGIN_ALTERNATIVEPLAYCOUNT_LANGSTRINGS_DISPLAY_APCDYNPSVAL') );

	$prefs->setChange(sub {
			main::DEBUGLOG && $log->is_debug && $log->debug('Pref for scheduled backups changed. Resetting or killing timer.');
			backupScheduler();
		}, 'scheduledbackups', 'backuptime');
}

sub trackInfoHandler {
	my ($infoItem, $client, $url, $track, $remoteMeta, $tags, $filter) = @_;

	# check if remote track is part of online library
	if ((Slim::Music::Info::isRemoteURL($url) == 1) && (!defined($track->extid))) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Track is remote but not part of LMS library. Track URL: '.$url);
		return;
	}

	my $alwaysDisplayVals = $prefs->get('alwaysdisplayvals');
	my $returnVal = 0;
	my ($apcPlayCount, $apcLastPlayed, $persistentPlayCount, $persistentLastPlayed, $apcSkipCount, $apcLastSkipped, $dynPSval);
	my $urlmd5 = $track->urlmd5 || md5_hex($url);
	my $dbh = Slim::Schema->dbh;

	my $sql = "select ifnull(alternativeplaycount.playCount, 0), ifnull(alternativeplaycount.lastPlayed, 0), ifnull(alternativeplaycount.skipCount, 0), ifnull(alternativeplaycount.lastSkipped, 0), ifnull(alternativeplaycount.dynPSval, 0), ifnull(tracks_persistent.playCount, 0), ifnull(tracks_persistent.lastPlayed, 0) from alternativeplaycount left join tracks_persistent on tracks_persistent.urlmd5 = alternativeplaycount.urlmd5 where alternativeplaycount.urlmd5 = \"$urlmd5\"";
	eval {
			my $sth = $dbh->prepare($sql);
			$sth->execute() or do {
				$sql = undef;
				$log->error("Error executing: $sql");
			};
			$sth->bind_columns(undef, \$apcPlayCount, \$apcLastPlayed, \$apcSkipCount, \$apcLastSkipped, \$dynPSval, \$persistentPlayCount, \$persistentLastPlayed);
			$sth->fetch();
			$sth->finish();
	};
	if ($@) {
		$log->error("Database error: $DBI::errstr");
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('track title = '.substr($track->title, 0, 15).' # apcPlayCount = '.Data::Dump::dump($apcPlayCount).' # persistentPlayCount = '.Data::Dump::dump($persistentPlayCount).' # apcSkipCount = '.Data::Dump::dump($apcSkipCount).' # apcLastPlayed = '.Data::Dump::dump($apcLastPlayed).' # persistentLastPlayed = '.Data::Dump::dump($persistentLastPlayed).' # apcLastSkipped = '.Data::Dump::dump($apcLastSkipped).' # apcdynPSval = '.Data::Dump::dump($dynPSval));

	if (!defined($persistentPlayCount) && !defined($apcPlayCount) && !defined($apcSkipCount) && !defined($apcLastPlayed) && !defined($persistentLastPlayed) && !defined($apcLastSkipped) && !defined($dynPSval)) {
		my $sqlTrackExists = "select count(*) from alternativeplaycount where alternativeplaycount.urlmd5 = \"$urlmd5\"";
		my $trackInDB = quickSQLquery($sqlTrackExists);
		if (!$trackInDB) {
			$log->warn("Couldn't retrieve information for this track.\nCould be part of a (client) playlist whose track references are no longer valid after a *rescan*.\nTrack url = ".$url."\nTrack urlmd5 = ".$urlmd5);
			return;
		}
	}

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

	if ($infoItem eq 'dynPSval') {
		$returnVal = $dynPSval;
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
			trackid => $track->id,
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

sub resetValueWeb {
	my ($client, $params, $callback, $httpClient, $response) = @_;

	my $urlmd5 = $params->{urlmd5};
	my $infoItem = $params->{infoitem};
	my $trackID = $params->{trackid};
	my $action = $params->{action};
	$params->{name} = $itemNames{$infoItem};
	$params->{trackid} = $trackID;
	$params->{infoitem} = $infoItem;
	$params->{urlmd5} = $urlmd5;
	main::DEBUGLOG && $log->is_debug && $log->debug('name = '.$itemNames{$infoItem}.' ## infoItem = '.$infoItem.' ## urlmd5 = '.$urlmd5.' ## trackID = '.$trackID);

	if ($action) {
		resetValue($infoItem, $urlmd5);
		$params->{resetdone} = 1;
		main::INFOLOG && $log->is_info && $log->info('Reset '.$itemNames{$infoItem}.' for trackID '.$trackID);
	}
	return Slim::Web::HTTP::filltemplatefile('plugins/AlternativePlayCount/html/resetvalue.html', $params);
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
	main::DEBUGLOG && $log->is_debug && $log->debug('infoItem = '.$infoItem.' ## urlmd5 = '.$urlmd5);

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
	$request->addResult('window', {text => $windowTitle});

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
	main::DEBUGLOG && $log->is_debug && $log->debug('infoItem = '.$infoItem.' ## urlmd5 = '.$urlmd5);

	resetValue($infoItem, $urlmd5);

	$request->setStatusDone();
}

sub resetValVFD {
	my ($client, $callback, $params, $infoItem, $urlmd5) = @_;
	main::DEBUGLOG && $log->is_debug && $log->debug('infoItem = '.$infoItem);
	main::DEBUGLOG && $log->is_debug && $log->debug('urlmd5 = '.$urlmd5);

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
	} elsif ($infoItem eq 'dynPSval') {
		$sqlstatement = "update alternativeplaycount set dynPSval = null where urlmd5 = \"$urlmd5\"";
	}

	return if (!$sqlstatement);
	executeSQLstat($sqlstatement);
	main::DEBUGLOG && $log->is_debug && $log->debug("Finished resetting value for \"$infoItem\"");
}


## mark as played or skipped

sub _APCcommandCB {
	my $request = shift;
	my $client = $request->client();

	if (Slim::Music::Import->stillScanning) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Access to APC table blocked until library scan is completed.');
		return;
	}

	if (!defined $client) {
		main::DEBUGLOG && $log->is_debug && $log->debug('No client. Exiting APCcommandCB');
		return;
	}

	my $clientID = $client->id();
	main::DEBUGLOG && $log->is_debug && $log->debug('Received command "'.$request->getRequestString().'" from client "'.$clientID.'"');
	my $track = Slim::Player::Playlist::track($client);

	if (defined $track) {
		if (defined $track && !defined($track->url)) {
			$log->warn('No track url. Exiting.');
			return;
		}

		# check if remote track is part of online library
		if ((Slim::Music::Info::isRemoteURL($track->url) == 1) && (!defined($track->extid))) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Track is remote but not part of LMS library. Track URL: '.$track->url);
			return;
		}

		my $currentTrackURL = $track->url;
		my $currentTrackURLmd5 = $track->urlmd5;
		my $currentTrackMBID = getTrackMBID($track) || '';
		my $previousTrackURL = $client->pluginData('currentTrackURL');
		my $previousTrackURLmd5 = $client->pluginData('currentTrackURLmd5');
		my $previousTrackMBID = $client->pluginData('currentTrackMBID');

		main::DEBUGLOG && $log->is_debug && $log->debug('Current track on client "'.$clientID.'" is '.$currentTrackURL.' with urlmd5 = '.$currentTrackURLmd5.' and Musicbrainz ID = '.Data::Dump::dump($currentTrackMBID));
		main::DEBUGLOG && $log->is_debug && $log->debug('Previous track on client "'.$clientID.'" is '.Data::Dump::dump($previousTrackURL).' with urlmd5 = '.Data::Dump::dump($previousTrackURLmd5).' and Musicbrainz ID = '.Data::Dump::dump($previousTrackMBID));

		# skip requested by CustomSkip3 ?
		if ($prefs->get('ignoreCS3skiprequests') && $request->getRequestString() && $request->getRequestString() =~ 'playlist deleteitem' && $request->source && $request->source =~ 'PLUGIN_CUSTOMSKIP3') {
			if ($request->getParamsCopy()->{'lastCustomSkippedTrackURLmd5'}) {
				main::DEBUGLOG && $log->is_debug && $log->debug("skip requested by CustomSkip3 plugin for track: ".$previousTrackURL);
				$client->pluginData('lastCustomSkippedTrackURLmd5' => $request->getParamsCopy()->{'lastCustomSkippedTrackURLmd5'});
			}
		}

		## newsong
		if ($request->isCommand([['playlist'],['newsong']])) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Received "newsong" cb.');
			# stop old timer for this client
			Slim::Utils::Timers::killTimers($client, \&markAsPlayed);

			# check current track url against previous track url because jumping inside a track also triggers newsong event
			if (!defined($previousTrackURL) || ($currentTrackURL ne $previousTrackURL)) {
				# if previous song wasn't marked as played, mark as skipped
				main::DEBUGLOG && $log->is_debug && $log->debug('previousTrackURL = '.Data::Dump::dump($previousTrackURL));
				main::DEBUGLOG && $log->is_debug && $log->debug('previousTrackURLmd5 = '.Data::Dump::dump($previousTrackURLmd5).' -- lastCustomSkippedTrackURLmd5 = '.Data::Dump::dump($client->pluginData('lastCustomSkippedTrackURLmd5')));

				if (defined($previousTrackURL) && (!defined($client->pluginData('markedAsPlayed')) || $client->pluginData('markedAsPlayed') ne $previousTrackURL)) {
					if ($prefs->get('ignoreCS3skiprequests') && $client->pluginData('lastCustomSkippedTrackURLmd5') && $client->pluginData('lastCustomSkippedTrackURLmd5') eq $previousTrackURLmd5) {
						main::INFOLOG && $log->is_info && $log->info("skip requested by CustomSkip3 - don't mark this track as skipped in db: ".$previousTrackURL);
						$client->pluginData('lastCustomSkippedTrackURLmd5' => undef);
					} else {
						markAsSkipped($client, $previousTrackURL, $previousTrackURLmd5, $previousTrackMBID);
					}
				}

				$client->pluginData('markedAsPlayed' => undef);
				$client->pluginData('currentTrackURL' => $currentTrackURL);
				$client->pluginData('currentTrackURLmd5' => $currentTrackURLmd5);
				$client->pluginData('currentTrackMBID' => $currentTrackMBID);
			}

			startPlayCountTimer($client, $track);
		}

		## play
		if (($request->isCommand([['playlist'],['play']])) || ($request->isCommand([['mode','play']]))) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Received "play" or "mode play" cb.');
			startPlayCountTimer($client, $track);
		}

		## pause
		if ($request->isCommand([['pause']]) || $request->isCommand([['mode'],['pause']])) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Received "pause" or "mode pause" cb.');
			my $playmode = Slim::Player::Source::playmode($client);
			main::DEBUGLOG && $log->is_debug && $log->debug('playmode = '.$playmode);

			if ($playmode eq 'pause') {
				Slim::Utils::Timers::killTimers($client, \&markAsPlayed);
			} elsif ($playmode eq 'play') {
				startPlayCountTimer($client, $track);
			}
		}

		## stop
		if ($request->isCommand([["stop"]]) || $request->isCommand([['mode'],['stop']]) || $request->isCommand([['playlist'],['stop']]) || $request->isCommand([['playlist'],['sync']]) || $request->isCommand([['playlist'],['clear']]) || $request->isCommand([['power']])) {
			main::DEBUGLOG && $log->is_debug && $log->debug('Received "stop", "clear", "power" or "sync" cb.');
			Slim::Utils::Timers::killTimers($client, \&markAsPlayed);
			$client->pluginData('markedAsPlayed' => undef);
			$client->pluginData('currentTrackURL' => undef);
			$client->pluginData('currentTrackURLmd5' => undef);
			$client->pluginData('currentTrackMBID' => undef);
			$client->pluginData('lastCustomSkippedTrackURL' => undef);
		}
	}
}

sub startPlayCountTimer {
	my ($client, $track) = @_;

	# check if track has been marked as played already
	if ($client->pluginData('markedAsPlayed') && $client->pluginData('markedAsPlayed') eq $track->url) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Song has already been marked as played in this session.');
		return;
	}

	my $playedThreshold_percent = ($prefs->get('playedthreshold_percent') || 20) / 100;
	my $songProgress = Slim::Player::Source::progress($client);
	main::DEBUGLOG && $log->is_debug && $log->debug('playedThreshold_percent = '.($playedThreshold_percent * 100).'% -- songProgress so far = '.(sprintf "%.1f", ($songProgress * 100)).'%');

	if ($songProgress >= $playedThreshold_percent) {
		main::DEBUGLOG && $log->is_debug && $log->debug('songProgress > playedThreshold_percent. Will mark song as played.');
		markAsPlayed($client, $track);
	} else {
		my $songDuration = $track->secs;
		my $remainingThresholdTime = $songDuration * $playedThreshold_percent - $songDuration * $songProgress;
		main::DEBUGLOG && $log->is_debug && $log->debug('songDuration = '.$songDuration.' seconds -- remainingThresholdTime = '.(sprintf "%.1f", $remainingThresholdTime).' seconds');

		# Start timer for new song
		Slim::Utils::Timers::setTimer($client, time() + $remainingThresholdTime, \&markAsPlayed, $track);
	}
}

sub markAsPlayed {
	my ($client, $track) = @_;

	my $trackURL = $track->url;
	my $trackURLmd5 = $track->urlmd5 || md5_hex($track->url);
	my $trackMBID = getTrackMBID($track) || '';

	# if the track was skipped very recently => undo last skip count increment
	# and correct dynamic played/skipped value BEFORE increasing it
	undoLastSkipCountIncrement($client, $track);

	main::INFOLOG && $log->is_info && $log->info('Marking track with url "'.$trackURL.'" as played. urlmd5 = '.Data::Dump::dump($trackURLmd5));
	$client->pluginData('markedAsPlayed' => $trackURL);
	my $lastPlayed = time();

	# get previous APC play count for auto-rating baseline rating
	my $baselineRatingPlayCount;
	if ($prefs->get('autorating') && $prefs->get('baselinerating')) {
		my $dbh = Slim::Schema->dbh;
		my $APCplaycount = $dbh->selectcol_arrayref("select ifnull(alternativeplaycount.playCount, 0) from alternativeplaycount where alternativeplaycount.urlmd5 = \"$trackURLmd5\"");
		$baselineRatingPlayCount = $APCplaycount->[0];
		main::DEBUGLOG && $log->is_debug && $log->debug('previous APC play count for baseline rating = '.Data::Dump::dump($baselineRatingPlayCount));
	}

	my $sqlstatement = "update alternativeplaycount set playCount = ifnull(playCount, 0) + 1, lastPlayed = $lastPlayed";
	if ($prefs->get('allmusicbrainzidversions') && $trackMBID) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Updating APC play count for ALL tracks with Musicbrainz ID = '.Data::Dump::dump($trackMBID));
		$sqlstatement .= " where musicbrainz_id = \"$trackMBID\"";
	} else {
		$sqlstatement .= " where urlmd5 = \"$trackURLmd5\"";
	}
	executeSQLstat($sqlstatement);
	_setDynamicPlayedSkippedValue($trackURL, $trackURLmd5, $trackMBID, 1);
	_setAutoRatingValue($client, $track, 1, $baselineRatingPlayCount) if $prefs->get('autorating');

	main::DEBUGLOG && $log->is_debug && $log->debug("Marked track as played\n\n");
}

sub markAsSkipped {
	my ($client, $trackURL, $trackURLmd5, $trackMBID) = @_;
	main::INFOLOG && $log->is_info && $log->info('Marking track with url "'.$trackURL.'" as skipped. urlmd5 = '.Data::Dump::dump($trackURLmd5));
	$trackURLmd5 = md5_hex($trackURL) if !$trackURLmd5;

	my $lastSkipped = time();

	my $sqlstatement = "update alternativeplaycount set skipCount = ifnull(skipCount, 0) + 1, lastSkipped = $lastSkipped";
	if ($prefs->get('allmusicbrainzidversions') && $trackMBID) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Updating APC skip count for ALL tracks with Musicbrainz ID = '.Data::Dump::dump($trackMBID));
		$sqlstatement .= " where musicbrainz_id = \"$trackMBID\"";
	} else {
		$sqlstatement .= " where urlmd5 = \"$trackURLmd5\"";
	}
	executeSQLstat($sqlstatement);
	_setDynamicPlayedSkippedValue($trackURL, $trackURLmd5, $trackMBID, 2);

	if ($prefs->get('autorating')) {
		my $track = Slim::Schema->search('Track', {'urlmd5' => $trackURLmd5 })->first();
		$track = Slim::Schema->objectForUrl({ 'url' => $trackURL }) if !$track;
		_setAutoRatingValue($client, $track, 2);
	}
	main::DEBUGLOG && $log->is_debug && $log->debug("Marked track as skipped\n\n");
}

sub undoLastSkipCountIncrement {
	my $undoSkipTimeSpan = $prefs->get('undoskiptimespan');
	if ($undoSkipTimeSpan > 0) {
		my ($client, $track) = @_;
		my $trackURLmd5 = $track->urlmd5 || md5_hex($track->url);
		my $trackMBID = getTrackMBID($track) || '';
		my $lastSkippedSQL = "select ifnull(alternativeplaycount.skipCount, 0), ifnull(alternativeplaycount.lastSkipped, 0) from alternativeplaycount where alternativeplaycount.urlmd5 = \"$trackURLmd5\"";
		my ($skipCount, $lastSkipped) = quickSQLquery($lastSkippedSQL, 2);
		my $songDuration = $track->secs;
		my $playedThreshold_percent = ($prefs->get('playedthreshold_percent') || 20) / 100;

		if ($lastSkipped > 0 && (time()-$lastSkipped < ($undoSkipTimeSpan * 60 + $songDuration * $playedThreshold_percent))) {
			main::INFOLOG && $log->is_info && $log->info("Played track was skipped in the last $undoSkipTimeSpan mins. Reducing skip count (by 1) and dynamic played/skipped value (DPSV)");
			my $reduceSkipCountSQL;
			if ($skipCount - 1 == 0) {
				$reduceSkipCountSQL = "update alternativeplaycount set skipCount = null, lastSkipped = null";
			} else {
				# we can't know what the previous last skipped time was but we can reduce the skip count
				$reduceSkipCountSQL = "update alternativeplaycount set skipCount = skipCount - 1";
			}
			if ($prefs->get('allmusicbrainzidversions') && $trackMBID) {
				main::DEBUGLOG && $log->is_debug && $log->debug("Reducing skip count (by 1) and dynamic played/skipped value (DPSV) for ALL tracks with Musicbrainz ID = ".Data::Dump::dump($trackMBID));
				$reduceSkipCountSQL .= " where musicbrainz_id = \"$trackMBID\"";
			} else {
				$reduceSkipCountSQL .= " where urlmd5 = \"$trackURLmd5\"";
			}
			executeSQLstat($reduceSkipCountSQL);
			_setDynamicPlayedSkippedValue($track->url, $trackURLmd5, $trackMBID, 3);
			_setAutoRatingValue($client, $track, 3) if $prefs->get('autorating');
		}
	}
}

sub _setDynamicPlayedSkippedValue {
	my ($trackURL, $trackURLmd5, $trackMBID, $action) = @_; # action: 1 = DPSV increase, 2 = DPSV decrease, 3 = undo last DPSV decrease
	return if (!$trackURL || !$trackURLmd5 || !$action);

	# get current DPSV
	my $dbh = Slim::Schema->dbh;
	my $sql = "select ifnull(dynPSval, 0) from alternativeplaycount where urlmd5 = \"$trackURLmd5\"";
	my $curDPSV;
	my $sth = $dbh->prepare($sql);
	$sth->execute();
	$sth->bind_columns(undef, \$curDPSV);
	$sth->fetch();
	$sth->finish();
	main::DEBUGLOG && $log->is_debug && $log->debug('Current dynamic played/skipped value (DPSV) = '.Data::Dump::dump($curDPSV));

	return if !defined($curDPSV); # e.g. if rescan invalidated old client playlist

	# calculate new DPSV (range -100 to 100)
	my ($newDPSV, $logActionPrefix);
	my $delta = 100 - abs($curDPSV);
	if ($action == 1 && $curDPSV < 100) {
		$logActionPrefix = 'Increased';
		$delta = $delta/8;
		$delta = 1 if $delta < 1;
		main::DEBUGLOG && $log->is_debug && $log->debug('delta (DPSV increase) = '.$delta);
		$newDPSV = $curDPSV + $delta;
		$newDPSV = roundFloat($newDPSV);
		$newDPSV = 100 if $newDPSV > 100;

	} elsif ($action == 2 && $curDPSV > -100) {
		$logActionPrefix = 'Reduced';
		$delta = $delta/4;
		$delta = 1 if $delta < 1;
		main::DEBUGLOG && $log->is_debug && $log->debug('delta (DPSV decrease) = '.$delta);
		$newDPSV = $curDPSV - $delta;
		$newDPSV = roundFloat($newDPSV);
		$newDPSV = -100 if $newDPSV < -100;

	} elsif ($action == 3 && $curDPSV < 100) {
		$logActionPrefix = 'Reset';
		# Because of rounding, the calculated previous value may differ slightly from the real previous value.
		if ($curDPSV >= 0) {
			$newDPSV = (4 * abs($curDPSV) + 100)/5;
		} elsif ($curDPSV < -25) {
			$newDPSV = (4 * $curDPSV + 100)/3;
		} else {
			$newDPSV = (4 * $curDPSV + 100)/5;
		}
		$newDPSV = roundFloat($newDPSV);
		main::DEBUGLOG && $log->is_debug && $log->debug('Resetting DPSV to previous value = '.$newDPSV);
		$newDPSV = 100 if $newDPSV > 100;
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('No action required. # action = '.$action.' -- curRating = '.$curDPSV);
		return;
	}

	# set new DPSV
	my $sqlstatement = "update alternativeplaycount set dynPSval = $newDPSV";
	if ($prefs->get('allmusicbrainzidversions') && $trackMBID) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Updating dynamic played/skipped value (DPSV) for ALL tracks with Musicbrainz ID = ".Data::Dump::dump($trackMBID));
		$sqlstatement .= " where musicbrainz_id = \"$trackMBID\"";
	} else {
		$sqlstatement .= " where urlmd5 = \"$trackURLmd5\"";
	}
	executeSQLstat($sqlstatement);
	main::INFOLOG && $log->is_info && $log->info($logActionPrefix.' dynamic played/skipped value (DPSV) from '.$curDPSV.' to '.$newDPSV.' for track with url: '.$trackURL);
}

sub _setAutoRatingValue {
	my ($client, $track, $action, $baselineRatingPlayCount) = @_;
	if (!$ratingslight_enabled) {
		$log->warn('Auto-rating requires the "Ratings Light" plugin.');
		return;
	}
	return if (!$track || !$action || !$client);

	# can't rate non-library remote tracks
	if ((Slim::Music::Info::isRemoteURL($track->url) == 1) && (!defined($track->extid))) {
		main::DEBUGLOG && $log->is_debug && $log->debug("Can't set rating. Track is remote but not part of LMS library. Track URL: ".$track->url);
		return;
	}

	# get current track rating
	my $curRating = $track->rating || 0;
	main::DEBUGLOG && $log->is_debug && $log->debug('Current track rating = '.Data::Dump::dump($curRating));

	# calculate new rating value
	my ($newRating, $logActionPrefix);
	my $delta = $curRating > 50 ? (100 - $curRating) : $curRating;

	# rating actions: 1 = increase, 2 = decrease, 3 = undo last decrease
	if ($action == 1 && $curRating < 100) {
		$logActionPrefix = 'Increasing';
		if ($prefs->get('autorating') == 2) {
			$delta = $prefs->get('autoratinglineardelta');
			main::DEBUGLOG && $log->is_debug && $log->debug('linear rating increase = '.$delta);
		} else {
			# use baseline rating for unplayed and unrated tracks?
			if ($prefs->get('baselinerating') && defined($baselineRatingPlayCount) && $baselineRatingPlayCount == 0 && $curRating == 0) {
				$delta = $prefs->get('baselinerating');
				main::DEBUGLOG && $log->is_debug && $log->debug('applying baseline rating of '.$delta.' to unplayed track');
			} else {
				my $dynAutoRatingFactor = $prefs->get('autoratingdynamicfactor') || 8;
				$delta = $delta/$dynAutoRatingFactor;
				if ($delta < 1) {
					main::DEBUGLOG && $log->is_debug && $log->debug('delta increase raw = '.$delta);
					$delta = 1;
				}
			}
			main::DEBUGLOG && $log->is_debug && $log->debug('rating increase = '.$delta);
		}

		$newRating = $curRating + $delta;
		$newRating = roundFloat($newRating) if $delta > 1;
		$newRating = 100 if $newRating > 100;

	} elsif ($action == 2 && $curRating > 0) {
		$logActionPrefix = 'Reducing';
		if ($prefs->get('autorating') == 2) {
			$delta = $prefs->get('autoratinglineardelta');
			main::DEBUGLOG && $log->is_debug && $log->debug('linear rating decrease = '.$delta);
		} else {
			$delta = $delta/4;
			if ($delta < 1) {
				main::DEBUGLOG && $log->is_debug && $log->debug('delta decrease raw = '.$delta);
				$delta = 1;
			}
			main::DEBUGLOG && $log->is_debug && $log->debug('rating decrease = '.$delta);
		}

		$newRating = $curRating - $delta;
		$newRating = roundFloat($newRating) if $delta > 1;
		$newRating = 0 if $newRating < 0;

	} elsif ($action == 3 && $curRating < 100) {
		$logActionPrefix = 'Resetting';
		if ($prefs->get('autorating') == 2) {
			main::DEBUGLOG && $log->is_debug && $log->debug('linear rating reset increase = '.$prefs->get('autoratinglineardelta'));
			$newRating = $curRating + $prefs->get('autoratinglineardelta');
		# Because of rounding, the calculated previous value may differ from the actual previous value.
		} elsif ($curRating > 50) {
			$newRating = (4 * $curRating + 100)/5;
		} else {
			$newRating = ($curRating * 4)/3;
		}

		$newRating = roundFloat($newRating);
		$newRating = 100 if $newRating > 100;
		$newRating = 0 if $newRating < 0;
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('No action required. # action = '.$action.' -- curRating = '.$curRating);
		return;
	}

	# set new rating
	main::INFOLOG && $log->is_info && $log->info($logActionPrefix.' rating value from '.$curRating.' to '.$newRating.' for track with url: '.$track->url."\n\n");

	Slim::Control::Request::executeRequest($client, ['ratingslight', 'setratingpercent', 'track_id:'.$track->id, $newRating]);
}


## backup, restore

sub backupScheduler {
	main::DEBUGLOG && $log->is_debug && $log->debug('Checking backup scheduler');

	main::DEBUGLOG && $log->is_debug && $log->debug('Killing all backup timers');
	Slim::Utils::Timers::killTimers(undef, \&backupScheduler);

	if ($prefs->get('scheduledbackups')) {
		my $backuptime = $prefs->get('backuptime');
		my $day = $prefs->get('backup_lastday');
		if (!defined($day)) {
			$day = '';
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('backup time = '.Data::Dump::dump($backuptime));
		main::DEBUGLOG && $log->is_debug && $log->debug('last backup day = '.Data::Dump::dump($day));

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
			main::DEBUGLOG && $log->is_debug && $log->debug('local time = '.Data::Dump::dump(padnum($hour).':'.padnum($min).':'.padnum($sec).' -- '.padnum($mday).'.'.padnum($mon).'.'));

			my $currenttime = $hour * 60 * 60 + $min * 60;

			if (($day ne $mday) && $currenttime > $time) {
				main::DEBUGLOG && $log->is_debug && $log->debug('Starting scheduled backup');
				eval {
					Slim::Utils::Scheduler::add_task(\&createBackup);
				};
				if ($@) {
					$log->error("Scheduled backup failed: $@");
				}
				$prefs->set('backup_lastday',$mday);
			} else {
				my $timeleft = $time - $currenttime;
				if ($day eq $mday) {
					$timeleft = $timeleft + 60 * 60 * 24;
				}
				main::DEBUGLOG && $log->is_debug && $log->debug(parse_duration($timeleft)." ($timeleft seconds) left until next scheduled backup time. The actual backup is created no later than 30 minutes after the set backup time.");
			}

			Slim::Utils::Timers::setTimer(undef, time() + 1800, \&backupScheduler);
		}
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
		if ($clearallbeforerestore) {
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
			$log->error('Couldn\'t open backup file: '.$restorefile);
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
		$line =~ s/&#(\d*);/escape(chr($1))/ge;
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
	main::DEBUGLOG && $log->is_debug && $log->debug('Restore completed after '.$ended.' seconds.');
	sleep(1.5); # if task is removed too soon from scheduler => undef val as sub ref error
	Slim::Utils::Scheduler::remove_task(\&restoreScanFunction);
	$prefs->set('isTSlegacyBackupFile', 0);
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
	if ($element eq 'TrackStat') {
		$prefs->set('isTSlegacyBackupFile', 1);
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
	my $isTSlegacyBackupFile = $prefs->get('isTSlegacyBackupFile');

	if ($inTrack && $element eq 'track') {
		$inTrack = 0;

		my $curTrack = \%restoreitem;
		my $trackURL = undef;
		my $fullTrackURL = $curTrack->{'url'};
		my $trackURLmd5 = undef;
		my $backupTrackURLmd5 = $isTSlegacyBackupFile ? undef : $curTrack->{'urlmd5'};
		my $isRemote = $isTSlegacyBackupFile ? undef : $curTrack->{'remote'};
		my $relTrackURL = $isTSlegacyBackupFile ? undef : $curTrack->{'relurl'};
		my $trackMBID = $isTSlegacyBackupFile ? $curTrack->{'musicbrainzId'} : $curTrack->{'musicbrainzid'};

		# for local tracks only: check if FULL file url is valid
		# Otherwise, try RELATIVE file URL with current media dirs
		$fullTrackURL = Encode::decode('utf8', unescape($fullTrackURL));
		$relTrackURL = Encode::decode('utf8', unescape($relTrackURL)) if $relTrackURL;

		if ($isRemote && $isRemote == 1) {
			main::DEBUGLOG && $log->is_debug && $log->debug('is remote track. URL = '.Data::Dump::dump($fullTrackURL));
			$trackURL = $fullTrackURL;
			$trackURLmd5 = $backupTrackURLmd5;
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug('is local track. URL = '.Data::Dump::dump($fullTrackURL));
			my $fullTrackPath = pathForItem($fullTrackURL);
			if ($fullTrackPath && -f $fullTrackPath) {
				main::DEBUGLOG && $log->is_debug && $log->debug("found file at url \"$fullTrackPath\"");
				$trackURL = $fullTrackURL;
				$trackURLmd5 = $backupTrackURLmd5 unless $isTSlegacyBackupFile;
			} else {
				main::DEBUGLOG && $log->is_debug && $log->debug("** Couldn't find file for FULL file url. Will try with RELATIVE file url and current LMS media folders.");
				if (!$relTrackURL) {
					main::DEBUGLOG && $log->is_debug && $log->debug("** Couldn't find RELATIVE file url.");
				} else {
					my $lmsmusicdirs = getMusicDirs();
					main::DEBUGLOG && $log->is_debug && $log->debug('Valid LMS music dirs = '.Data::Dump::dump($lmsmusicdirs));

					foreach (@{$lmsmusicdirs}) {
						my $dirSep = File::Spec->canonpath("/");
						my $mediaDirURL = Slim::Utils::Misc::fileURLFromPath($_.$dirSep);
						main::DEBUGLOG && $log->is_debug && $log->debug('Trying LMS music dir url: '.$mediaDirURL);

						my $newFullTrackURL = $mediaDirURL.$relTrackURL;
						my $newFullTrackPath = pathForItem($newFullTrackURL);
						main::DEBUGLOG && $log->is_debug && $log->debug('Trying with new full track path: '.$newFullTrackPath);

						if (-f $newFullTrackPath) {
							$trackURL = Slim::Utils::Misc::fileURLFromPath($newFullTrackURL);
							main::DEBUGLOG && $log->is_debug && $log->debug('Found file at new full file url: '.$trackURL);
							main::DEBUGLOG && $log->is_debug && $log->debug('OLD full file url was: '.$fullTrackURL);
							last;
						}
					}
				}
			}
		}

		if (!$trackURL && !$trackURLmd5 && !$trackMBID) {
			$log->warn("No valid urlmd5, url or musicbrainz id for this track. Can't restore values for file with restore URL = ".Data::Dump::dump($fullTrackURL));
		} else {
			$trackURLmd5 = md5_hex($trackURL) if (!$trackURLmd5 && $trackURL);
			my $sqlstatement = "update alternativeplaycount ";

			if ($isTSlegacyBackupFile) {
				my $playCount = (!$curTrack->{'playCount'} ? "null" : $curTrack->{'playCount'});
				my $lastPlayed = (!$curTrack->{'lastPlayed'} ? "null" : $curTrack->{'lastPlayed'});
				$sqlstatement .= "set playCount = $playCount, lastPlayed = $lastPlayed ";
			} else {
				my $playCount = ($curTrack->{'playcount'} == 0 ? "null" : $curTrack->{'playcount'});
				my $lastPlayed = ($curTrack->{'lastplayed'} == 0 ? "null" : $curTrack->{'lastplayed'});
				my $skipCount = ($curTrack->{'skipcount'} == 0 ? "null" : $curTrack->{'skipcount'});
				my $lastSkipped = ($curTrack->{'lastskipped'} == 0 ? "null" : $curTrack->{'lastskipped'});
				my $dynPSval = ($curTrack->{'dynpsval'} == 0 ? "null" : $curTrack->{'dynpsval'});
				$sqlstatement .= "set playCount = $playCount, lastPlayed = $lastPlayed, skipCount = $skipCount, lastSkipped = $lastSkipped, dynPSval = $dynPSval";
			}

			if ($trackURLmd5) {
				$sqlstatement .= " where urlmd5 = \"$trackURLmd5\"";
			} elsif ($trackMBID) {
				main::DEBUGLOG && $log->is_debug && $log->debug("** Trying to restore values for track with musicbrainz ID = ".$trackMBID);
				$sqlstatement .= " where musicbrainz_id = \"$trackMBID\"";
			}
			executeSQLstat($sqlstatement);
		}
		%restoreitem = ();
	}
	if ($element eq 'AlternativePlayCount' || $element eq 'TrackStat') {
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

	my %recentlyplayedsimilartracksbysameartist = (
		'id' => 'alternativeplaycount_recentlyplayedsimilartrackbysameartist',
		'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_RACKSRECENTLYPLAYEDSIMILARBYSAMEARTIST_NAME"),
		'filtercategory' => 'songs',
		'description' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_RACKSRECENTLYPLAYEDSIMILARBYSAMEARTIST_DESC"),
		'parameters' => [
			{
				'id' => 'time',
				'type' => 'singlelist',
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKSRECENTLYPLAYED_PARAM_NAME"),
				'data' => '300=5 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',600=10 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',900=15 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',1800=30 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',3600=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOUR").',7200=2 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',10800=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',21600=6 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',43200=12 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',86400=24 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',259200=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_DAYS").',604800=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEK"),
				'value' => 3600
			},
			{
				'id' => 'similarityval',
				'type' => 'numberrange',
				'minvalue' => 50,
				'maxvalue' => 100,
				'stepvalue' => 1,
				'name' => string("PLUGIN_CUSTOMSKIP3_FILTERS_TRACKTITLESIMILARITYVAL_PARAM_NAME"),
				'value' => 85
			},
		]
	);
	push @result, \%recentlyplayedsimilartracksbysameartist;

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

	my %recentlyplayedcomposers = (
		'id' => 'alternativeplaycount_recentlyplayedcomposer',
		'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_RECENTLYPLAYEDCOMPOSER_NAME"),
		'filtercategory' => 'composers',
		'description' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_RECENTLYPLAYEDCOMPOSER_DESC"),
		'parameters' => [
			{
				'id' => 'time',
				'type' => 'singlelist',
				'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_RECENTLYPLAYEDARTIST_PARAM_NAME"),
				'data' => '300=5 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',600=10 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',900=15 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',1800=30 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_MINS").',3600=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOUR").',7200=2 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',10800=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',21600=6 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',43200=12 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',86400=24 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_HOURS").',259200=3 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_DAYS").',604800=1 '.string("PLUGIN_CUSTOMSKIP3_LANGSTRINGS_TIME_WEEK"),
				'value' => 600
			}
		]
	);
	push @result, \%recentlyplayedcomposers;

	my %dpsvhigh = (
		'id' => 'alternativeplaycount_dpsvhigh',
		'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_DPSVHIGH_NAME"),
		'description' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_DPSVHIGH_DESC"),
		'filtercategory' => 'songs',
		'parameters' => [
			{
				'id' => 'dpsv',
				'type' => 'singlelist',
				'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_DPSVHIGH_PARAM_NAME"),
				'data' => '-100=-100,-90=-90,-80=-80,-70=-70,-60=-60,-50=-50,-40=-40,-30=-30,-20=-20,-10=-10,0=0,10=10,20=20,30=30,40=40,50=50,60=60,70=70,80=80,90=90',
				'value' => 0
			}
		]
	);
	push @result, \%dpsvhigh;

	my %dpsvlow = (
		'id' => 'alternativeplaycount_dpsvlow',
		'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_DPSVLOW_NAME"),
		'description' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_DPSVLOW_DESC"),
		'filtercategory' => 'songs',
		'parameters' => [
			{
				'id' => 'dpsv',
				'type' => 'singlelist',
				'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_DPSVLOW_PARAM_NAME"),
				'data' => '-90=-90,-80=-80,-70=-70,-60=-60,-50=-50,-40=-40,-30=-30,-20=-20,-10=-10,0=0,10=10,20=20,30=30,40=40,50=50,60=60,70=70,80=80,90=90,100=100',
				'value' => 0
			}
		]
	);
	push @result, \%dpsvlow;

	my %dpsvexactrounded = (
		'id' => 'alternativeplaycount_dpsvexactrounded',
		'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_DPSVEXACTROUNDED_NAME"),
		'description' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_DPSVEXACTROUNDED_DESC"),
		'filtercategory' => 'songs',
		'parameters' => [
			{
				'id' => 'dpsv',
				'type' => 'singlelist',
				'name' => string("PLUGIN_ALTERNATIVEPLAYCOUNT_CUSTOMSKIP_DPSVEXACTROUNDED_PARAM_NAME"),
				'data' => '-100=-100,-90=-90,-80=-80,-70=-70,-60=-60,-50=-50,-40=-40,-30=-30,-20=-20,-10=-10,0=0,10=10,20=20,30=30,40=40,50=50,60=60,70=70,80=80,90=90,100=100',
				'value' => 0
			}
		]
	);
	push @result, \%dpsvexactrounded;

	return \@result;
}

sub checkCustomSkipFilterType {
	my ($client, $filter, $track, $lookaheadonly, $index) = @_;

	my $currentTime = time();
	my $parameters = $filter->{'parameter'};
	my $dbh = Slim::Schema->dbh;
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
						$log->error("Error executing SQL: $@\n$DBI::errstr");
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
						$log->error("Error executing SQL: $@\n$DBI::errstr");
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
	} elsif ($filter->{'id'} eq 'alternativeplaycount_recentlyplayedsimilartrackbysameartist') {
		require String::LCSS;
		use List::Util qw(max);
		my $started = time();
		my $curTitle = $track->title;
		my $curTitleNormalised = normaliseTrackTitle($curTitle);
		my $artist = $track->artist;

		if (defined($artist) && defined($curTitle)) {
			# get available track titles for current artist
			my @artistTracks = ();
			my ($trackTitle, $trackTitleSearch, $lastPlayed) = undef;
			my $dbh = Slim::Schema->dbh;
			my $sth = $dbh->prepare("select tracks.title,tracks.titlesearch,ifnull(alternativeplaycount.lastPlayed,0) from tracks, alternativeplaycount, contributor_track where tracks.urlmd5 = alternativeplaycount.urlmd5 and tracks.id = contributor_track.track and contributor_track.contributor = ? and tracks.id != ? group by tracks.id");
			eval {
				$sth->bind_param(1, $artist->id);
				$sth->bind_param(2, $track->id);
				$sth->execute();
				$sth->bind_columns(undef, \$trackTitle, \$trackTitleSearch, \$lastPlayed);
				while ($sth->fetch()) {
					push @artistTracks, {'lastplayed' => $lastPlayed, 'tracktitle' => $trackTitle, 'tracktitlesearch' => $trackTitleSearch}
				}
			};
			if ($@) {
				$log->error("Error executing SQL: $@\n$DBI::errstr");
			}
			$sth->finish();

			main::INFOLOG && $log->is_info && $log->info("Checking playlist track '".$track->titlesearch."' against all tracks by artist '".$track->artist->name."'");
			if (scalar @artistTracks > 0) {
				my ($recentlyPlayedPeriod, $similarityThreshold) = undef;
				# get filter param values
				for my $parameter (@{$parameters}) {
					if ($parameter->{'id'} eq 'time') {
						my $times = $parameter->{'value'};
						$recentlyPlayedPeriod = $times->[0] if (defined($times) && scalar(@{$times}) > 0);
					}
					if ($parameter->{'id'} eq 'similarityval') {
						my $similarityVals = $parameter->{'value'};
						$similarityThreshold = $similarityVals->[0] if (defined($similarityVals) && scalar(@{$similarityVals}) > 0);
					}
				}

				foreach (@artistTracks) {
					my $lastPlayed = $_->{'lastplayed'};
					my $thisTrackTitle = $_->{'tracktitle'};

					if (defined($lastPlayed) && defined($thisTrackTitle)) {
						# next if not played in specified recent period
						if (time() - $lastPlayed >= $recentlyPlayedPeriod) {
							main::DEBUGLOG && $log->is_debug && $log->debug('- Track NOT played recently: '.$_->{'tracktitlesearch'});
							next;
						}

						# calc LCSS/similarity
						require String::LCSS;
						use List::Util qw(max);

						main::INFOLOG && $log->is_info && $log->info('-- Track played recently, checking similarity: '.$_->{'tracktitlesearch'});

						my $thisTitleNormalised = normaliseTrackTitle($thisTrackTitle);
						main::DEBUGLOG && $log->is_debug && $log->debug("-- currentTrackTitle normalised = $curTitleNormalised");
						main::DEBUGLOG && $log->is_debug && $log->debug("-- thisTrackTitle normalised = $thisTitleNormalised");

						my @result = String::LCSS::lcss($curTitleNormalised, $thisTitleNormalised);
						main::DEBUGLOG && $log->is_debug && $log->debug('-- Longest common substring = '.Data::Dump::dump($result[0]));

						if ($result[0] && length($result[0]) > 3) { # returns undef if LCSS = zero or 1
							# similarity = max. length LCSS/track title
							my $similarity = max(length($result[0])/length($curTitleNormalised), length($result[0])/length($thisTitleNormalised)) * 100;
							main::DEBUGLOG && $log->is_debug && $log->debug('--- longest common substring = '.$result[0]);
							main::INFOLOG && $log->is_info && $log->info('--- Similarity = '.Data::Dump::dump($similarity)."\t-- ".$_->{'tracktitlesearch'});

							# skip if above similarity threshold
							if ($similarity > $similarityThreshold) {
								main::INFOLOG && $log->is_info && $log->info(">>> SKIPPING similar playlist track: $curTitle");
								main::DEBUGLOG && $log->is_debug && $log->debug('--- filter exec time = '.(time()-$started).' secs.');
								main::INFOLOG && $log->is_info && $log->info("\n");
								return 1;
							} else {
								main::INFOLOG && $log->is_info && $log->info("--- Similarity of tracks is below user-specified minimum value.");
							}
						} else {
							main::INFOLOG && $log->is_info && $log->info("--- Tracks don't have a common substring with the minimum length.");
							next;
						}
					}
				}
				main::DEBUGLOG && $log->is_debug && $log->debug('Filter exec time = '.(time()-$started).' secs.');
				main::INFOLOG && $log->is_info && $log->info("\n");
			} else {
				main::INFOLOG && $log->is_info && $log->info("- Found no further tracks by artist '".$track->artist->name."'.");
				main::INFOLOG && $log->is_info && $log->info("\n");
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
						$log->error("Error executing SQL: $@\n$DBI::errstr");
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
						$log->error("Error executing SQL: $@\n$DBI::errstr");
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
	} elsif ($filter->{'id'} eq 'alternativeplaycount_recentlyplayedcomposer') {
		for my $parameter (@{$parameters}) {
			if ($parameter->{'id'} eq 'time') {
				my $times = $parameter->{'value'};
				my $time = $times->[0] if (defined($times) && scalar(@{$times}) > 0);
				my $trackID = $track->id;

				my $composerName;
				my $dbh = Slim::Schema->dbh;
				my $sthComposerName = $dbh->prepare("select contributors.namesearch from contributors join contributor_track on contributors.id = contributor_track.contributor join tracks on contributor_track.track = tracks.id where contributor_track. role = 2 and tracks.id = $trackID");
				eval {
					$sthComposerName->execute();
					$composerName = $sthComposerName->fetchrow || '';
				};
				if ($@) {
					$log->error("Error executing SQL: $@\n$DBI::errstr");
				}
				$sthComposerName->finish();

				if ($composerName) {
					my $lastPlayed;
					my $sth = $dbh->prepare("select max(ifnull(alternativeplaycount.lastPlayed,0)) from tracks, alternativeplaycount, contributor_track, contributors where tracks.urlmd5 = alternativeplaycount.urlmd5 and tracks.id = contributor_track.track and contributor_track.contributor = contributors.id and contributors.namesearch = \"$composerName\" and contributor_track.role = 2");
					eval {
						$sth->execute();
						$lastPlayed = $sth->fetchrow || 0;
					};
					if ($@) {
						$log->error("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();

					if ($lastPlayed) {
						if ((time() - $lastPlayed) < $time) {
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
						$log->error("Error executing SQL: $@\n$DBI::errstr");
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
	} elsif ($filter->{'id'} eq 'alternativeplaycount_dpsvhigh') {
		for my $parameter (@$parameters) {
			if ($parameter->{'id'} eq 'dpsv') {
				my $dpsv_paramvals = $parameter->{'value'};
				my $dpsv_selected = $dpsv_paramvals->[0] if (defined($dpsv_paramvals) && scalar(@{$dpsv_paramvals}) > 0);

				my $urlmd5 = $track->urlmd5;
				if ($urlmd5) {
					my $dpsv;
					my $sth = $dbh->prepare("select ifnull(alternativeplaycount.dynPSval, 0)) from alternativeplaycount where alternativeplaycount.urlmd5 = \"$urlmd5\"");
					eval {
						$sth->execute();
						$sth->bind_columns(undef, \$dpsv);
						$sth->fetch();
					};
					if ($@) {
						$log->error("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if (defined($dpsv) && $dpsv > $dpsv_selected) {
						return 1;
					}
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'alternativeplaycount_dpsvlow') {
		for my $parameter (@$parameters) {
			if ($parameter->{'id'} eq 'dpsv') {
				my $dpsv_paramvals = $parameter->{'value'};
				my $dpsv_selected = $dpsv_paramvals->[0] if (defined($dpsv_paramvals) && scalar(@{$dpsv_paramvals}) > 0);

				my $urlmd5 = $track->urlmd5;
				if ($urlmd5) {
					my $dpsv;
					my $sth = $dbh->prepare("select ifnull(alternativeplaycount.dynPSval, 0)) from alternativeplaycount where alternativeplaycount.urlmd5 = \"$urlmd5\"");
					eval {
						$sth->execute();
						$sth->bind_columns(undef, \$dpsv);
						$sth->fetch();
					};
					if ($@) {
						$log->error("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if (defined($dpsv) && $dpsv < $dpsv_selected) {
						return 1;
					}
				}
				last;
			}
		}
	} elsif ($filter->{'id'} eq 'alternativeplaycount_dpsvexactrounded') {
		for my $parameter (@$parameters) {
			if ($parameter->{'id'} eq 'dpsv') {
				my $dpsv_paramvals = $parameter->{'value'};
				my $dpsv_selected = $dpsv_paramvals->[0] if (defined($dpsv_paramvals) && scalar(@{$dpsv_paramvals}) > 0);

				my $urlmd5 = $track->urlmd5;
				if ($urlmd5) {
					my $dpsv;
					my $sth = $dbh->prepare("select ifnull(alternativeplaycount.dynPSval, 0)) from alternativeplaycount where alternativeplaycount.urlmd5 = \"$urlmd5\"");
					eval {
						$sth->execute();
						$sth->bind_columns(undef, \$dpsv);
						$sth->fetch();
					};
					if ($@) {
						$log->error("Error executing SQL: $@\n$DBI::errstr");
					}
					$sth->finish();
					if (defined($dpsv)) {
						my $roundedDPSV;
						if ($dpsv >= 0) {
							$roundedDPSV = floor(($dpsv + 5) / 10) * 10;
						} else {
							$roundedDPSV = ceil(($dpsv - 5) / 10) * 10;
						}

						if (defined($roundedDPSV) && $roundedDPSV == $dpsv_selected) {
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


# title formats

sub getTitleFormat {
	my $track = shift;
	my $titleFormatName = shift;
	my $returnVal = 0;

	# get local track if unblessed
	if ($track && !blessed($track)) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Track is not blessed');
		my $trackObj = Slim::Schema->find('Track', $track->{id});
		if (blessed($trackObj)) {
			$track = $trackObj;
		} else {
			my $trackURL = $track->{'url'};
			main::DEBUGLOG && $log->is_debug && $log->debug('Slim::Schema->find found no blessed track object for id. Trying to retrieve track object with url: '.Data::Dump::dump($trackURL));
			if (defined ($trackURL)) {
				if (Slim::Music::Info::isRemoteURL($trackURL) == 1) {
					$track = Slim::Schema->_retrieveTrack($trackURL);
					main::DEBUGLOG && $log->is_debug && $log->debug('Track is remote. Retrieved trackObj = '.Data::Dump::dump($track));
				} else {
					$track = Slim::Schema->rs('Track')->single({'url' => $trackURL});
					main::DEBUGLOG && $log->is_debug && $log->debug('Track is not remote. TrackObj for url = '.Data::Dump::dump($track));
				}
			} else {
				return '';
			}
		}
	}

	if ($track) {
		my $urlmd5 = $track->urlmd5;
		my $dbh = Slim::Schema->dbh;

		my $sql = "select ifnull(alternativeplaycount.$titleFormatName, 0) from alternativeplaycount where alternativeplaycount.urlmd5 = \"$urlmd5\"";
		my $sth = $dbh->prepare($sql);
		eval {
			$sth->execute();
			$returnVal = $sth->fetchrow || 0;
			$sth->finish();
		};
		if ($@) {
			$log->error("Database error: $DBI::errstr");
		}
		main::DEBUGLOG && $log->is_debug && $log->debug("Title format: $titleFormatName --- Value: $returnVal");
	}
	return $returnVal;
}

sub addTitleFormat {
	my $titleformat = shift;
	my $titleFormats = $serverPrefs->get('titleFormat');
	foreach my $format (@{$titleFormats}) {
		if ($titleformat eq $format) {
			return;
		}
	}
	push @{$titleFormats}, $titleformat;
	$serverPrefs->set('titleFormat', $titleFormats);
}



sub quickSQLquery {
	my $sqlstatement = shift;
	my $valuesToBind = shift || 1; # up to 2 vars
	my ($thisResult, $thisResult2);
	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare($sqlstatement);
	eval {
		$sth->execute() or do {
			$sqlstatement = undef;
		};
	};
	if ($@) {
		$log->error("Database error: $DBI::errstr");
	}
	if ($valuesToBind == 2) {
		$sth->bind_columns(undef, \$thisResult, \$thisResult2);
	} else {
		$sth->bind_columns(undef, \$thisResult);
	}
	$sth->fetch();
	$sth->finish();
	if ($valuesToBind == 2) {
		return $thisResult, $thisResult2;
	} else {
		return $thisResult;
	}
}

sub executeSQLstat {
	my $sqlstatement = shift;
	my $dbh = Slim::Schema->dbh;

	for my $sql (split(/[\n\r]/, $sqlstatement)) {
		my $sth = $dbh->prepare($sql);
		eval {
			$sth->execute();
			commit($dbh);
		};
		if ($@) {
			$log->error("Database error: $DBI::errstr");
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
	my $dbh = Slim::Schema->dbh;
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
		$log->error("Database error: $DBI::errstr\n");
	}
	$sth->finish();
	main::DEBUGLOG && $log->is_debug && $log->debug($tableExists ? 'APC table table found.' : 'No APC table table found.');

	# create APC table if it doesn't exist
	unless ($tableExists) {
		# create table
		main::DEBUGLOG && $log->is_debug && $log->debug('Creating table.');
		my $sqlstatement = "create table if not exists persistentdb.alternativeplaycount (url text NOT NULL COLLATE NOCASE, playCount int(10), lastPlayed int(10), skipCount int(10), lastSkipped int(10), dynPSval int(10), remote bool, urlmd5 char(32) not null default '0', musicbrainz_id varchar(40));";
		main::DEBUGLOG && $log->is_debug && $log->debug('Creating APC database table');
		executeSQLstat($sqlstatement);

		# create indices
		main::DEBUGLOG && $log->is_debug && $log->debug('Creating indices.');
		my $dbIndex = "create index if not exists persistentdb.cpurlIndex on alternativeplaycount (url);
create index if not exists persistentdb.cpurlmd5Index on alternativeplaycount (urlmd5);";
		executeSQLstat($dbIndex);

		populateAPCtable();
	}
	refreshDatabase();
	my $ended = time() - $started;
	main::DEBUGLOG && $log->is_debug && $log->debug('DB init completed after '.$ended.' seconds.');
}

sub populateAPCtable {
	my $isRestore = shift;
	my $dbh = Slim::Schema->dbh;

	if (!$isRestore && $prefs->get('dbpoplmsvalues')) {
		# populate table with playCount + lastPlayed values from tracks_persistent
		main::DEBUGLOG && $log->is_debug && $log->debug('Populating empty APC table with values from LMS persistent database.');
		my $minPlayCount = $prefs->get('dbpoplmsminplaycount');
		my $sql = "INSERT INTO alternativeplaycount (url,playCount,lastPlayed,urlmd5,remote,musicbrainz_id) select tracks.url,case when ifnull(tracks_persistent.playCount, 0) >= $minPlayCount then tracks_persistent.playCount else null end,case when ifnull(tracks_persistent.playCount, 0) >= $minPlayCount then tracks_persistent.lastPlayed else null end,tracks.urlmd5,tracks.remote,tracks.musicbrainz_id from tracks left join tracks_persistent on tracks.urlmd5=tracks_persistent.urlmd5 left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5 where tracks.audio = 1 and tracks.content_type != \"cpl\" and tracks.content_type != \"src\" and tracks.content_type != \"ssp\" and tracks.content_type != \"dir\" and tracks.content_type is not null and alternativeplaycount.urlmd5 is null;";

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
			$log->error("Database error: $DBI::errstr\n");
			eval { rollback($dbh); };
		}
		$sth->finish();
	} else {
		# insert only values for track url, urlmd5 & musicbrainz_id
		main::DEBUGLOG && $log->is_debug && $log->debug('Copying values for url, urlmd5 and musicbrainz id to empty APC table.');
		my $sql = "INSERT INTO alternativeplaycount (url, urlmd5, remote, musicbrainz_id) select tracks.url, tracks.urlmd5, tracks.remote, tracks.musicbrainz_id from tracks left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5 where tracks.audio = 1 and tracks.content_type != \"cpl\" and tracks.content_type != \"src\" and tracks.content_type != \"ssp\" and tracks.content_type != \"dir\" and tracks.content_type is not null and alternativeplaycount.urlmd5 is null;";
		my $sth = $dbh->prepare($sql);
		eval {
			$sth->execute();
			commit($dbh);
		};
		if($@) {
			$log->error("Database error: $DBI::errstr\n");
			eval { rollback($dbh); };
		}
		$sth->finish();
	}
	if (!$isRestore && $prefs->get('dbpopdpsv')) {
		populateDPSV();
	} else {
		$prefs->set('status_resetapcdatabase', 0);
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('Finished populating APC database table');
}

sub populateDPSV {
	my $popMethod = $prefs->get('dbpopdpsvinitial');
	my $dbh = Slim::Schema->dbh;
	# revisit both methods when LMS uses SQLite version >= 3.33.0 that supports update FROM
	if ($popMethod == 2) {
		my $sqlstatement = "update alternativeplaycount set dynPSval = case when (ifnull(playCount, 0) > 0 and ifnull(skipCount, 0) == 0) then playCount when (ifnull(playCount, 0) == 0 and skipCount == 1) then cast(95 as float)/100 when (ifnull(playCount, 0) == 0 and ifnull(skipCount, 0) > 1) then cast(1 as float)/skipCount when (ifnull(playCount, 0) > 0 and ifnull(skipCount, 0) > 0) then cast(playCount as float)/skipCount end where ifnull(alternativeplaycount.playCount, 0) > 0 or ifnull(alternativeplaycount.skipCount, 0) > 0;
update alternativeplaycount set dynPSval = case when (dynPSval == 1 and ifnull(skipCount, 0) == 0) then 10 when dynPSval == 1 then 0 when (dynPSval > 1 and dynPSval <= 15) then 10 when (dynPSval > 15 and dynPSval <= 25) then 20 when (dynPSval > 25 and dynPSval <= 35) then 30 when (dynPSval > 35 and dynPSval <= 45) then 40 when (dynPSval > 45 and dynPSval <= 55) then 50 when (dynPSval > 55 and dynPSval <= 65) then 60 when (dynPSval > 65 and dynPSval <= 75) then 70 when (dynPSval > 75 and dynPSval <= 85) then 80 when (dynPSval > 85 and dynPSval <= 95) then 90 when dynPSval > 95 then 100 when (dynPSval < 1 and dynPSval > cast(85 as float)/100) then -10 when (dynPSval <= cast(85 as float)/100 and dynPSval > cast(75 as float)/100) then -20 when (dynPSval <= cast(75 as float)/100 and dynPSval > cast(65 as float)/100) then -30 when (dynPSval <= cast(65 as float)/100 and dynPSval > cast(55 as float)/100) then -40 when (dynPSval <= cast(55 as float)/100 and dynPSval > cast(45 as float)/100) then -50 when (dynPSval <= cast(45 as float)/100 and dynPSval > cast(35 as float)/100) then -60 when (dynPSval <= cast(35 as float)/100 and dynPSval > cast(25 as float)/100) then -70 when (dynPSval <= cast(25 as float)/100 and dynPSval > cast(15 as float)/100) then -80 when (dynPSval <= cast(15 as float)/100 and dynPSval > cast(5 as float)/100) then -90 when dynPSval <= cast(5 as float)/100 then -100 end;";
		executeSQLstat($sqlstatement);
		main::DEBUGLOG && $log->is_debug && $log->debug('Finished populating DPSV column with values calculated using APC play count/skip count ratio');

	} elsif ($popMethod == 3) {
		# get all rated tracks
		my %ratedTracks = ();
		my ($trackURLmd5, $trackRating);
		my $sqlstatementGetRatings = "select tracks_persistent.urlmd5, tracks_persistent.rating from tracks_persistent where tracks_persistent.rating > 0";
		my $sth = $dbh->prepare($sqlstatementGetRatings);
		$sth->execute();

		$sth->bind_col(1,\$trackURLmd5);
		$sth->bind_col(2,\$trackRating);

		while ($sth->fetch()) {
			my $dpsv = 0;
			# use rating to determine DPSV
			$dpsv = -100 if $trackRating > 0 and $trackRating <= 5;
			$dpsv = -80 if $trackRating > 5 and $trackRating <= 15;
			$dpsv = -60 if $trackRating > 15 and $trackRating <= 25;
			$dpsv = -40 if $trackRating > 25 and $trackRating <= 35;
			$dpsv = -20 if $trackRating > 35 and $trackRating <= 45;
			$dpsv = 0 if $trackRating > 45 and $trackRating <= 55;
			$dpsv = 20 if $trackRating > 55 and $trackRating <= 65;
			$dpsv = 40 if $trackRating > 65 and $trackRating <= 75;
			$dpsv = 60 if $trackRating > 75 and $trackRating <= 85;
			$dpsv = 80 if $trackRating > 85 and $trackRating <= 95;
			$dpsv = 100 if $trackRating > 95;

			$ratedTracks{$trackURLmd5} = $dpsv;
		}
		$sth->finish;

		# set dynPSval db values
		foreach my $trackurlmd5 (keys %ratedTracks) {
			my $dpsv = $ratedTracks{$trackurlmd5};
			my $sqlSetRatings = "update alternativeplaycount set dynPSval = $dpsv where alternativeplaycount.urlmd5 = \"$trackurlmd5\"";
			my $sthUpdate = $dbh->prepare($sqlSetRatings);
			$sthUpdate->execute();
			$sth->finish();
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('Finished populating DPSV column with values derived from track ratings');

	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('DPSV already null');
	}
	$prefs->set('status_resetapcdatabase', 0);
}

sub resetDPSV {
	my $sqlstatement = "update alternativeplaycount set dynPSval = null where ifnull(dynPSval, 0) != 0";
	executeSQLstat($sqlstatement);
	main::DEBUGLOG && $log->is_debug && $log->debug('Finished resetting DPSV column');
	populateDPSV();
}

sub resetSkipCounts {
	my $sqlstatement = "update alternativeplaycount set skipCount = null, lastSkipped = null where ifnull(skipCount, 0) != 0";
	executeSQLstat($sqlstatement);
	main::DEBUGLOG && $log->is_debug && $log->debug('Finished resetting skip counts');
}

sub refreshDatabase {
	if (Slim::Music::Import->stillScanning) {
		$log->warn("Warning: can't refresh database until library scan is completed.");
		return;
	}

	removeDeadTracks();

	my $dbh = Slim::Schema->dbh;

	# add new tracks
	main::DEBUGLOG && $log->is_debug && $log->debug('Add new tracks to the APC table.');
	my $newTracksSql = "INSERT INTO alternativeplaycount (url, urlmd5, remote, musicbrainz_id) select tracks.url, tracks.urlmd5, tracks.remote, tracks.musicbrainz_id from tracks left join alternativeplaycount on tracks.urlmd5 = alternativeplaycount.urlmd5 where tracks.audio = 1 and tracks.content_type != \"cpl\" and tracks.content_type != \"src\" and tracks.content_type != \"ssp\" and tracks.content_type != \"dir\" and tracks.content_type is not null and alternativeplaycount.urlmd5 is null;";
	eval {$dbh->do($newTracksSql)};
	if($@) {
		$log->error("Database error: $DBI::errstr\n");
		eval { rollback($dbh); };
	}

	# refresh Musicbrainz IDs in APC table
	main::DEBUGLOG && $log->is_debug && $log->debug('Refreshing Musicbrainz IDs.');
	my $refreshMBIDsSql = "update alternativeplaycount set musicbrainz_id = (select tracks.musicbrainz_id from tracks where tracks.urlmd5 = alternativeplaycount.urlmd5 and tracks.audio = 1 and tracks.content_type != \"ssp\");";
	eval {$dbh->do($refreshMBIDsSql)};
	if($@) {
		$log->error("Database error: $DBI::errstr\n");
		eval { rollback($dbh); };
	}

	$dbh->do("analyze alternativeplaycount;");
	main::DEBUGLOG && $log->is_debug && $log->debug('DB refresh complete.');
}

sub removeDeadTracks {
	my $database = shift || 'alternativeplaycount';
	my $dbh = Slim::Schema->dbh;
	main::DEBUGLOG && $log->is_debug && $log->debug('Removing dead tracks from APC database that no longer exist in LMS database');

	my $sqlstatement = "delete from $database where urlmd5 not in (select urlmd5 from tracks where tracks.urlmd5 = $database.urlmd5)";
	eval {$dbh->do($sqlstatement)};
	if($@) {
		$log->error("Database error: $DBI::errstr\n");
		eval { rollback($dbh); };
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('Finished removing dead tracks from DB.');
}

sub resetLMSvalues {
	my $dbh = Slim::Schema->dbh;
	main::DEBUGLOG && $log->is_debug && $log->debug('Resetting play count and date last played values of the LMS tracks_persistent table to APC values');

	my $sqlstatement = "update tracks_persistent set playCount = (select alternativeplaycount.playCount from alternativeplaycount where tracks_persistent.urlmd5 = alternativeplaycount.urlmd5), lastPlayed = (select round(alternativeplaycount.lastPlayed,0) from alternativeplaycount where tracks_persistent.urlmd5 = alternativeplaycount.urlmd5);";
	eval {$dbh->do($sqlstatement)};
	if($@) {
		$log->error("Database error: $DBI::errstr\n");
		eval { rollback($dbh); };
	}

	main::DEBUGLOG && $log->is_debug && $log->debug('Finished resetting LMS to APC values.');
}

sub resetAPCDatabase {
	my $isRestore = shift; # don't copy data from tracks_persistent when restoring
	my $status_creatingbackup = $prefs->get('status_resetapcdatabase');
	if ($status_creatingbackup == 1) {
		$log->warn('A database reset is already in progress, please wait for the previous reset to finish');
		return;
	}
	$prefs->set('status_resetapcdatabase', 1);

	my $sqlstatement = "delete from alternativeplaycount";
	executeSQLstat($sqlstatement);
	main::DEBUGLOG && $log->is_debug && $log->debug('APC table cleared');

	populateAPCtable($isRestore);
}

sub _setRefreshCBTimer {
	main::DEBUGLOG && $log->is_debug && $log->debug('Killing existing timers for post-scan refresh to prevent multiple calls');
	Slim::Utils::Timers::killOneTimer(undef, \&delayedPostScanRefresh);
	main::DEBUGLOG && $log->is_debug && $log->debug('Scheduling a delayed post-scan refresh');
	Slim::Utils::Timers::setTimer(undef, time() + $prefs->get('postscanscheduledelay'), \&delayedPostScanRefresh);
}

sub delayedPostScanRefresh {
	if (Slim::Music::Import->stillScanning) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Scan in progress. Waiting for current scan to finish.');
		_setRefreshCBTimer();
	} else {
		main::DEBUGLOG && $log->is_debug && $log->debug('Starting post-scan database table refresh.');
		initDatabase();
	}
}

sub createAPCfolder {
	my $apcParentFolderPath = $prefs->get('apcparentfolderpath') || Slim::Utils::OSDetect::dirsFor('prefs');
	my $apcFolderPath = catdir($apcParentFolderPath, 'AlternativePlayCount');
	eval {
		mkdir($apcFolderPath, 0755) unless (-d $apcFolderPath);
	} or do {
		$log->error("Could not create AlternativePlayCount folder in parent folder '$apcParentFolderPath'! Please make sure that LMS has read/write permissions (755) for the parent folder.");
		return;
	};
	$prefs->set('apcfolderpath', $apcFolderPath);
}

sub normaliseTrackTitle {
	my $title = shift;
	return if !$title;
	$title =~ s/[\[\(].*[\)\]]*//g; # delete everything between brackets + parentheses
	$title =~ s/((bonus|deluxe|12“|live|extended|instrumental|edit|interlude|alt\.|alternate|alternative|album|single|ep|maxi)+[ -]*(version|remix|mix|take|track))//ig; # delete some common words
	$title = uc(Slim::Utils::Text::ignoreCase($title, 1));
	return $title;
}

sub getTrackMBID {
	my $track = shift;
	my $trackMBID = $track->musicbrainz_id;
	$trackMBID = undef if (defined $trackMBID && $trackMBID !~ /.*-.*/);
	return $trackMBID;
}

sub padnum {
	use integer;
	sprintf("%02d", $_[0]);
}

*escape = \&URI::Escape::uri_escape_utf8;
*unescape = \&URI::Escape::uri_unescape;

1;
