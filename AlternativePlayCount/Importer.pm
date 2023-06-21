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
	main::INFOLOG && $log->is_info && $log->info('prescanbackup = '.Data::Dump::dump($preScanBackup));
	if ($preScanBackup) {
		main::INFOLOG && $log->is_info && $log->info('creating pre-scan backup before scan process starts');
		createBackup();
	}
}

sub startScan {
	main::INFOLOG && $log->is_info && $log->info('ending importer');
	Slim::Music::Import->endImporter(__PACKAGE__);
}

1;
