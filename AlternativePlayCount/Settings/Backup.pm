#
# Alternative Play Count
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#


package Plugins::AlternativePlayCount::Settings::Backup;

use strict;
use warnings;
use utf8;

use base qw(Plugins::AlternativePlayCount::Settings::BaseSettings);
use Plugins::AlternativePlayCount::Common ':all';

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Misc;
use Slim::Utils::Strings;

my $prefs = preferences('plugin.alternativeplaycount');
my $log = logger('plugin.alternativeplaycount');

my $plugin;

sub new {
	my $class = shift;
	$plugin = shift;
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_ALTERNATIVEPLAYCOUNT_SETTINGS_BACKUP_RESTORE');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/AlternativePlayCount/settings/backup.html');
}

sub currentPage {
	return name();
}

sub pages {
	my %page = (
		'name' => name(),
		'page' => page(),
	);
	my @pages = (\%page);
	return \@pages;
}

sub prefs {
	return ($prefs, qw(scheduledbackups backuptime prescanbackup autodeletebackups backupsdaystokeep backupfilesmin restorefile clearallbeforerestore));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result;
	my $callHandler = 1;

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
		createBackup();
	} elsif ($paramRef->{'restore'}) {
		if ($callHandler) {
			$paramRef->{'saveSettings'} = 1;
			$result = $class->SUPER::handler($client, $paramRef);
			$callHandler = 0;
		}
		my $selectedfile = $paramRef->{'pref_restorefile'};
		main::DEBUGLOG && $log->is_debug && $log->debug("restorefile = ".$selectedfile);
		if (!defined($selectedfile) || $selectedfile eq '') {
			$paramRef->{'restoremissingfile'} = 1;
		} elsif ($selectedfile !~ /\.xml/i) {
			$paramRef->{'restoremissingfile'} = 2;
		} else {
			Plugins::AlternativePlayCount::Plugin::restoreFromBackup();
		}
	}

	# Reset restorefile pref to APC folder path so the file browser
	# opens in the correct directory next time
	$prefs->set('restorefile', $prefs->get('apcfolderpath'));

	$result = $class->SUPER::handler($client, $paramRef) if $callHandler;
	return $result;
}

1;
