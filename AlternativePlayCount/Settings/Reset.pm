#
# Alternative Play Count
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
#

package Plugins::AlternativePlayCount::Settings::Reset;

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

sub new {
	my ($class, $plugin) = @_;
	$class->SUPER::new($plugin);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_ALTERNATIVEPLAYCOUNT_SETTINGS_RESET');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/AlternativePlayCount/settings/reset.html');
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
	return ($prefs, qw(dbpoplmsminplaycount dbpoplmsvalues dbpopdpsvinitial dbpopdpsv));
}

sub handler {
	my ($class, $client, $paramRef) = @_;
	my $result;
	my $callHandler = 1;
	if ($paramRef->{'saveSettings'}) {
		$result = $class->SUPER::handler($client, $paramRef);
		$callHandler = 0;
	}
	if ($paramRef->{'resetapcdatabase'}) {
		if ($callHandler) {
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::AlternativePlayCount::Plugin::resetAPCDatabase();
	} elsif ($paramRef->{'resetplaycount'} || $paramRef->{'resetskipcount'} || $paramRef->{'resetdpsv'}) {
		if ($callHandler) {
			$result = $class->SUPER::handler($client, $paramRef);
		}
		if ($paramRef->{'resetplaycount'}) {
			Plugins::AlternativePlayCount::Plugin::resetColValues('playcount');
		} elsif ($paramRef->{'resetskipcount'}) {
			Plugins::AlternativePlayCount::Plugin::resetColValues('skipcount');
		} else {
			Plugins::AlternativePlayCount::Plugin::resetColValues('dpsv');
		}
	} elsif ($paramRef->{'resettrackspersistentvalues'}) {
		if ($callHandler) {
			$result = $class->SUPER::handler($client, $paramRef);
		}
		Plugins::AlternativePlayCount::Plugin::resetLMSvalues();
	} elsif ($callHandler) {
		$result = $class->SUPER::handler($client, $paramRef);
	}
	return $result;
}

1;
