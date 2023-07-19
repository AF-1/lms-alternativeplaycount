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

package Plugins::AlternativePlayCount::Settings::Basic;

use strict;
use warnings;
use utf8;

use base qw(Plugins::AlternativePlayCount::Settings::BaseSettings);

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
	$class->SUPER::new($plugin,1);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_ALTERNATIVEPLAYCOUNT');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/AlternativePlayCount/settings/basic.html');
}

sub currentPage {
	return Slim::Utils::Strings::string('PLUGIN_ALTERNATIVEPLAYCOUNT_SETTINGS_VARIOUS');
}

sub pages {
	my %page = (
		'name' => Slim::Utils::Strings::string('PLUGIN_ALTERNATIVEPLAYCOUNT_SETTINGS_VARIOUS'),
		'page' => page(),
	);
	my @pages = (\%page);
	return \@pages;
}

sub prefs {
	return ($prefs, qw(apcparentfolderpath playedthreshold_percent undoskiptimespan alwaysdisplayvals postscanscheduledelay));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	return $class->SUPER::handler($client, $paramRef);
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	my $advMode = $prefs->get('advmode');
	$paramRef->{'advmode'} = 1 if $advMode;
}

1;
