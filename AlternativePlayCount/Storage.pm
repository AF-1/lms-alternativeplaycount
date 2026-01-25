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

package Plugins::AlternativePlayCount::Storage;

use strict;
use warnings;
use utf8;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::SQLiteHelper;
use DBI;
use File::Spec::Functions qw(catdir catfile);

my $log = logger('plugin.alternativeplaycount');
my $prefs = preferences('plugin.alternativeplaycount');

my $dbh;
my $initialized = 0;

sub init {
	my $class = shift;

	my $persistDir = Slim::Utils::Prefs::dir() || Slim::Utils::OSDetect::dirsFor('prefs');
	my $dbFile = File::Spec->catfile($persistDir, 'apc_external.db');

	main::DEBUGLOG && $log->is_debug && $log->debug("Initializing APC external database at: $dbFile");

	eval {
		$dbh = DBI->connect(
			"dbi:SQLite:dbname=$dbFile",
			'', '',
			{
				RaiseError => 1,
				PrintError => 0,
				AutoCommit => 1,
				sqlite_unicode => 1,
			}
		);
	};

	if ($@) {
		$log->error("Failed to connect to database: $@");
		return 0;
	}

	# optimize SQLite
	$dbh->do("PRAGMA journal_mode = WAL");
	$dbh->do("PRAGMA synchronous = NORMAL");
	$dbh->do("PRAGMA temp_store = MEMORY");
	$dbh->do("PRAGMA cache_size = 10000");

	# create table and indices
	$class->createTables();

	$initialized = 1;
	main::DEBUGLOG && $log->is_debug && $log->debug("APC external database initialized successfully");

	return 1;
}

sub createTables {
	my $class = shift;

	return unless $dbh;

	# create main table
	my $sql = qq{
		CREATE TABLE IF NOT EXISTS play_history (
			id INTEGER PRIMARY KEY AUTOINCREMENT,
			url TEXT NOT NULL COLLATE NOCASE,
			urlmd5 CHAR(32) NOT NULL DEFAULT '0',
			musicbrainz_id VARCHAR(40),
			played INT(10) NOT NULL,
			rating INTEGER,
			remote BOOL DEFAULT '0',
			client_id TEXT
		)
	};

	eval {
		$dbh->do($sql);
		main::DEBUGLOG && $log->is_debug && $log->debug('Created play_history table');
	};

	if ($@) {
		$log->error("Failed to create play_history table: $@");
		return 0;
	}

	# create indices
	my @indices = (
		'CREATE INDEX IF NOT EXISTS urlmd5Idx ON play_history (urlmd5)',
		'CREATE INDEX IF NOT EXISTS playedIdx ON play_history (played)',
		'CREATE INDEX IF NOT EXISTS mbidIdx ON play_history (musicbrainz_id)',
		'CREATE INDEX IF NOT EXISTS clientIdx ON play_history (client_id)',
		'CREATE INDEX IF NOT EXISTS remoteIdx ON play_history (remote)',
		'CREATE INDEX IF NOT EXISTS urlmd5PlayedIdx ON play_history (urlmd5, played)',
	);

	foreach my $index (@indices) {
		eval {
			$dbh->do($index);
		};

		if ($@) {
			$log->warn("Failed to create index: $@");
		}
	}
	main::DEBUGLOG && $log->is_debug && $log->debug('Created indices for play_history table');
	return 1;
}

sub dbh {
	return $dbh if $initialized;

	$log->warn('Database not initialized, attempting to initialize now');
	__PACKAGE__->init();

	return $dbh;
}

sub addPlayEntry {
	my ($class, $params) = @_;

	return unless $dbh && $initialized;

	my $sql = qq{
		INSERT INTO play_history (url, urlmd5, musicbrainz_id, played, rating, remote, client_id)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	};

	eval {
		my $sth = $dbh->prepare_cached($sql);
		$sth->execute(
			$params->{url},
			$params->{urlmd5},
			$params->{musicbrainz_id},
			$params->{played} || time(),
			$params->{rating},
			$params->{remote} || 0,
			$params->{client_id}
		);
		$sth->finish();
	};

	if ($@) {
		$log->error("Failed to add play entry: $@");
		return 0;
	}

	return 1;
}

sub getPlayHistoryForTrack {
	my ($class, $urlmd5, $limit) = @_;

	return [] unless $dbh && $initialized;

	$limit ||= 100;

	my $sql = qq{
		SELECT id, url, urlmd5, musicbrainz_id, played, rating, remote, client_id
		FROM play_history
		WHERE urlmd5 = ?
		ORDER BY played DESC
		LIMIT ?
	};

	my $history = [];

	eval {
		my $sth = $dbh->prepare_cached($sql);
		$sth->execute($urlmd5, $limit);

		while (my $row = $sth->fetchrow_hashref()) {
			push @$history, $row;
		}
		$sth->finish();
	};

	if ($@) {
		$log->error("Failed to get play history: $@");
		return [];
	}
	return $history;
}

sub getPlayHistoryForClient {
	my ($class, $client_id, $limit) = @_;

	return [] unless $dbh && $initialized;
	$limit ||= 100;

	my $sql = qq{
		SELECT id, url, urlmd5, musicbrainz_id, played, rating, remote, client_id
		FROM play_history
		WHERE client_id = ?
		ORDER BY played ASC
		LIMIT ?
	};

	my $history = [];

	eval {
		my $sth = $dbh->prepare_cached($sql);
		$sth->execute($client_id, $limit);

		while (my $row = $sth->fetchrow_hashref()) {
			push @$history, $row;
		}
		$sth->finish();
	};

	if ($@) {
		$log->error("Failed to get play history for client: $@");
		return [];
	}
	return $history;
}

sub shutdown {
	my $class = shift;

	if ($dbh) {
		main::DEBUGLOG && $log->is_debug && $log->debug('Closing APC external database connection');
		$dbh->disconnect();
		$dbh = undef;
		$initialized = 0;
	}
}

1;
