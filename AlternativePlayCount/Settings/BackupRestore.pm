#
# Alternative Play Count
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#


package Plugins::AlternativePlayCount::Settings::BackupRestore;

use strict;
use warnings;
use utf8;

use base qw(Plugins::AlternativePlayCount::Settings::BaseSettings);
use Plugins::AlternativePlayCount::Common ':all';

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;
use File::Spec::Functions qw(catfile);

my $prefs = preferences('plugin.alternativeplaycount');
my $log = logger('plugin.alternativeplaycount');

sub new {
	my ($class, $plugin) = @_;
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_ALTERNATIVEPLAYCOUNT_SETTINGS_BACKUP_RESTORE');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/AlternativePlayCount/settings/backuprestore.html');
}

sub currentPage {
	return name();
}

sub pages {
	return [{ 'name' => name(), 'page' => page() }];
}

sub prefs {
	return ($prefs, qw(backupexternaldata scheduledbackups backuptime prescanbackup autodeletebackups backupsdaystokeep backupfilesmin clearallbeforerestore));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result;
	my $callHandler = 1;
	$paramRef->{'pref_backuptime'} = trim($paramRef->{'pref_backuptime'} // '');

	if ($paramRef->{'saveSettings'}) {
		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}

	if ($paramRef->{'backup'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
			$callHandler = 0;
		}
		if (Slim::Music::Import->stillScanning) {
			$log->warn('Cannot start a backup while an LMS scan is in progress');
		} else {
			createBackup();
		}
	} elsif ($paramRef->{'restore'}) {
		my $folderPath = $prefs->get('apcfolderpath');
		my $selectedfile = $paramRef->{'pref_restorefile'} // '';
		my $selectedexternalfile = $paramRef->{'pref_restoreexternalfile'} // '';
		$selectedfile = '' if defined($selectedfile) && defined($folderPath) && $selectedfile eq $folderPath;
		$selectedexternalfile = '' if defined($selectedexternalfile) && defined($folderPath) && $selectedexternalfile eq $folderPath;
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
			$callHandler = 0;
		}
		main::DEBUGLOG && $log->is_debug && $log->debug('restorefile = '.Data::Dump::dump($selectedfile).', restoreexternalfile = '.Data::Dump::dump($selectedexternalfile));

		my $validfile = ($selectedfile ne '' && $selectedfile =~ /\.xml$/i && hasValidBackupRootElement($selectedfile, 'AlternativePlayCount')) ? 1 : 0;
		my $validexternalfile = ($selectedexternalfile ne '' && $selectedexternalfile =~ /\.xml$/i && hasValidBackupRootElement($selectedexternalfile, 'APCExternalData')) ? 1 : 0;

		if ($selectedfile ne '' && !$validfile) {
			$paramRef->{'restoremissingfile'} = 2;
		}
		if ($selectedexternalfile ne '' && !$validexternalfile) {
			$paramRef->{'restoreexternalmissingfile'} = 2;
		}

		if (!$validfile && !$validexternalfile) {
			$paramRef->{'restoremissingfile'} = 1 unless $paramRef->{'restoremissingfile'};
		} else {
			$prefs->set('restorefile', $validfile ? $selectedfile : '');
			$prefs->set('restoreexternalfile', $validexternalfile ? $selectedexternalfile : '');
			if (Slim::Music::Import->stillScanning) {
				$log->warn('Cannot start a restore while an LMS scan is in progress');
			} else {
				Plugins::AlternativePlayCount::Plugin::restoreFromBackup();
			}
		}
	}

	$result = $class->SUPER::handler($client, $paramRef);
	return $result;
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	$paramRef->{'restorefilefolder'} = $prefs->get('apcfolderpath');
	$paramRef->{'restoreexternalfilefolder'} = $prefs->get('apcfolderpath');
	$paramRef->{lastsuccessfulbackup} = Slim::Utils::DateTime::longDateF($prefs->get('lastbackup')).", ".Slim::Utils::DateTime::timeF($prefs->get('lastbackup')) if $prefs->get('lastbackup');
	$paramRef->{'squeezebox_server_jsondatareq'} = '/jsonrpc.js';
	$paramRef->{'activebackuprestore'} = 1 if $prefs->get('status_backuprestore');
	$paramRef->{'activelmsscan'} = 1 if (!Slim::Schema::hasLibrary() || Slim::Music::Import->stillScanning);
}

sub trim {
	my $str = shift;
	$str =~ s{^\s+}{};
	$str =~ s{\s+$}{};
	return $str;
}

1;
