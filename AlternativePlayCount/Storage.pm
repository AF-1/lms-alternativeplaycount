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
use Scalar::Util qw(looks_like_number);
use DBI;
use File::Spec::Functions qw(catdir catfile);

my $log = logger('plugin.alternativeplaycount');
my $prefs = preferences('plugin.alternativeplaycount');

my $dbh;
my $initialized = 0;
my $libraryAttached = 0;

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

	# attach LMS library.db for album/artist JOIN queries (for menus)
	if ($prefs->get('playhistory_contextmenu') || $prefs->get('playhistory_homemenu')) {
		my $lmsDbFile = Slim::Utils::SQLiteHelper->dbFile('library');
		$lmsDbFile .= '.db' unless $lmsDbFile =~ /\.db$/i;
		if ($lmsDbFile && -f $lmsDbFile) {
			eval {
				$dbh->do("ATTACH DATABASE ? AS library", undef, $lmsDbFile);
				$libraryAttached = 1;
			};
			if ($@) {
				$log->warn("Could not attach library.db: $@");
			}
		} else {
			$log->warn("library.db not found, album/artist play history will not be available");
		}
	}

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
	__PACKAGE__->shutdown() if $dbh; # close any stale connection first
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

	# trim oldest entries if maxdbentries limit is set
	my $maxdbentries = $prefs->get('playhistory_maxdbentries') // 0;
	if ($maxdbentries > 0) {
		eval {
			$dbh->do("DELETE FROM play_history WHERE id NOT IN (SELECT id FROM play_history ORDER BY played DESC LIMIT $maxdbentries)");
		};
		if ($@) { $log->error("Error trimming play history: $@"); }
	}

	return 1;
}

sub getPlayHistory {
	my ($class, $params) = @_;

	return [] unless $dbh && $initialized;

	my $type = $params->{type} // 'all'; # 'track', 'album', 'artist', or 'all'
	my $id = $params->{id}; # urlmd5 (track), album id, or contributor id
	my $client_id = $params->{client_id}; # optional client filter
	my $limit = $params->{limit} || 100;

	my @bind;
	my $whereClause = '';

	if ($type eq 'track' && $id) {
		# match by urlmd5, with MBID fallback for tracks whose URL may have changed
		$whereClause = qq{
			WHERE (ph.urlmd5 = ?
			OR (ph.musicbrainz_id IS NOT NULL AND ph.musicbrainz_id != ''
				AND ph.musicbrainz_id = (
					SELECT t.musicbrainz_id FROM library.tracks t WHERE t.urlmd5 = ? LIMIT 1
				)
			))
		};
		push @bind, $id, $id;

	} elsif ($type eq 'album' && $id && $libraryAttached) {
		# join with library.tracks on album id, urlmd5 or MBID match
		$whereClause = qq{
			JOIN library.tracks lt
				ON (ph.urlmd5 = lt.urlmd5
					OR (ph.musicbrainz_id IS NOT NULL AND ph.musicbrainz_id != ''
						AND ph.musicbrainz_id = lt.musicbrainz_id))
			WHERE lt.album = ?
		};
		push @bind, $id;

	} elsif ($type eq 'artist' && $id && $libraryAttached) {
		# join with library.tracks + contributor_track on contributor id, urlmd5 or MBID match
		$whereClause = qq{
			JOIN library.tracks lt
				ON (ph.urlmd5 = lt.urlmd5
					OR (ph.musicbrainz_id IS NOT NULL AND ph.musicbrainz_id != ''
						AND ph.musicbrainz_id = lt.musicbrainz_id))
			JOIN library.contributor_track ct ON ct.track = lt.id
			WHERE ct.contributor = ?
		};
		push @bind, $id;
	}
	# type 'all' or fallback: no WHERE clause, returns entire play history

	# optional client filter
	if ($client_id) {
		$whereClause .= ($whereClause =~ /WHERE/i ? ' AND' : ' WHERE');
		$whereClause .= ' ph.client_id = ?';
		push @bind, $client_id;
	}

	push @bind, $limit;

	my $sql = qq{
		SELECT DISTINCT ph.id, ph.url, ph.urlmd5, ph.musicbrainz_id,
			ph.played, ph.rating, ph.remote, ph.client_id
		FROM play_history ph
		$whereClause
		ORDER BY ph.played DESC
		LIMIT ?
	};

	my $history = [];
	eval {
		my $sth = $dbh->prepare($sql);
		$sth->execute(@bind);
		while (my $row = $sth->fetchrow_hashref()) {
			push @$history, $row;
		}
		$sth->finish();
	};
	if ($@) {
		$log->error("getPlayHistory failed (type=$type): $@");
		return [];
	}

	main::DEBUGLOG && $log->is_debug && $log->debug("getPlayHistory: type=$type, id=".($id//'none').", client=".($client_id//'any').", returned ".scalar(@$history)." rows");
	return $history;
}

sub getDistinctClients {
	my $class = shift;
	return [] unless $dbh && $initialized;

	my $clients = [];
	eval {
		my $sth = $dbh->prepare_cached('SELECT DISTINCT client_id FROM play_history WHERE client_id IS NOT NULL AND client_id != ""');
		$sth->execute();
		while (my ($id) = $sth->fetchrow_array()) {
			push @$clients, $id;
		}
		$sth->finish();
	};
	if ($@) {
		$log->error("getDistinctClients failed: $@");
		return [];
	}
	return $clients;
}

sub shutdown {
	my $class = shift;

	if ($dbh) {
		eval { $dbh->do("DETACH DATABASE library") } if $libraryAttached;
		$libraryAttached = 0;
		main::DEBUGLOG && $log->is_debug && $log->debug('Closing APC external database connection');
		$dbh->disconnect();
		$dbh = undef;
		$initialized = 0;
	}
}

1;
