#
# Alternative Play Count
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::AlternativePlayCount::Importer;

use strict;
use warnings;
use utf8;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Schema;
use Plugins::AlternativePlayCount::Common ':all';

my $log = logger('plugin.alternativeplaycount');
my $prefs = preferences('plugin.alternativeplaycount');
my $serverPrefs = preferences('server');

sub initPlugin {
	main::INFOLOG && $log->is_info && $log->info('importer module init');

	my $preScanBackup = $prefs->get('prescanbackup');
	main::INFOLOG && $log->is_info && $log->info('prescanbackup = ' . ($preScanBackup ? '1' : '0'));
	if ($preScanBackup) {
		main::INFOLOG && $log->is_info && $log->info('creating pre-scan backup before scan process starts');
		createBackup(1);
	}
}

sub startScan {
	main::INFOLOG && $log->is_info && $log->info('ending importer');
	Slim::Music::Import->endImporter(__PACKAGE__);
}

1;
