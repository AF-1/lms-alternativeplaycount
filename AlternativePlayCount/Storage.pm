#
# Alternative Play Count
# (c) 2022 AF
# Licensed under the GPLv3 - see LICENSE file
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

	$dbh->do("PRAGMA journal_mode = WAL");
	$dbh->do("PRAGMA synchronous = NORMAL");
	$dbh->do("PRAGMA temp_store = MEMORY");
	$dbh->do("PRAGMA cache_size = 10000");

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

	my $tableExists = $dbh->selectrow_array("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='play_history'");

	if (!$tableExists) {
		$class->createTables();
	} else {
		$class->_migrateSchema();
	}

	$initialized = 1;
	main::DEBUGLOG && $log->is_debug && $log->debug("APC external database initialized successfully");

	return 1;
}

sub createTables {
	my $class = shift;
	return unless $dbh;

	eval {
		$dbh->do(qq{
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
		});
	};
	if ($@) {
		$log->error("Failed to create play_history table: $@");
		return 0;
	}

	my @indices = (
		'CREATE INDEX IF NOT EXISTS urlmd5Idx ON play_history (urlmd5)',
		'CREATE INDEX IF NOT EXISTS playedIdx ON play_history (played)',
		'CREATE INDEX IF NOT EXISTS mbidIdx ON play_history (musicbrainz_id)',
		'CREATE INDEX IF NOT EXISTS clientIdx ON play_history (client_id)',
	);

	foreach my $index (@indices) {
		eval { $dbh->do($index) };
		$log->warn("Failed to create index: $@") if $@;
	}

	eval {
		$dbh->do(qq{
			CREATE TABLE IF NOT EXISTS players (
				mac TEXT PRIMARY KEY NOT NULL,
				name TEXT,
				model TEXT,
				last_seen INT NOT NULL DEFAULT 0
			)
		});
	};
	if ($@) {
		$log->error("Failed to create players table: $@");
		return 0;
	}

	eval { $dbh->do("PRAGMA user_version = " . _currentSchemaVersion()) };
	$log->error("Failed to set user_version: $@") if $@;

	main::DEBUGLOG && $log->is_debug && $log->debug('play_history and players tables created.');
	return 1;
}

sub _currentSchemaVersion { return 2 }

sub _migrateSchema {
	my $class = shift;

	my $installedVersion;
	eval { ($installedVersion) = $dbh->selectrow_array("PRAGMA user_version") };
	if ($@) { $log->error("Failed to read schema version: $@"); $installedVersion = 0; }
	$installedVersion //= 0;

	my $currentVersion = _currentSchemaVersion();

	return if $installedVersion >= $currentVersion;

	main::DEBUGLOG && $log->is_debug && $log->debug("APC external schema migration needed: v$installedVersion -> v$currentVersion");

	# Never remove or renumber existing blocks
	if ($installedVersion < 1) {
		my %existingColumns;
		eval {
			my $sth = $dbh->prepare("PRAGMA table_info(play_history)");
			$sth->execute();
			while (my $row = $sth->fetchrow_hashref()) {
				$existingColumns{lc($row->{name})} = 1;
			}
			$sth->finish();
		};
		if ($@) {
			$log->error("play_history schema migration: failed to read table_info: $@");
			return;
		}

		# Add new columns here and add a corresponding "if ($installedVersion < N)" block below
		my %expectedColumns = (
			url => 'TEXT NOT NULL COLLATE NOCASE',
			urlmd5 => "CHAR(32) NOT NULL DEFAULT '0'",
			musicbrainz_id => 'VARCHAR(40)',
			played => 'INT(10) NOT NULL',
			rating => 'INTEGER',
			remote => "BOOL DEFAULT '0'",
			client_id => 'TEXT',
		);

		for my $col (sort keys %expectedColumns) {
			unless ($existingColumns{$col}) {
				$log->warn("play_history schema migration: adding missing column '$col'");
				eval { $dbh->do("ALTER TABLE play_history ADD COLUMN $col $expectedColumns{$col}") };
				$log->error("play_history schema migration: failed to add column '$col': $@") if $@;
			}
		}

		# Add missing indices
		my %expectedIndices = (
			urlmd5Idx => 'CREATE INDEX IF NOT EXISTS urlmd5Idx ON play_history (urlmd5)',
			playedIdx => 'CREATE INDEX IF NOT EXISTS playedIdx ON play_history (played)',
			mbidIdx => 'CREATE INDEX IF NOT EXISTS mbidIdx ON play_history (musicbrainz_id)',
			clientIdx => 'CREATE INDEX IF NOT EXISTS clientIdx ON play_history (client_id)',
		);

		my %existingIndices;
		eval {
			my $sth = $dbh->prepare("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='play_history'");
			$sth->execute();
			while (my ($name) = $sth->fetchrow_array()) {
				$existingIndices{$name} = 1;
			}
			$sth->finish();
		};

		for my $idx (sort keys %expectedIndices) {
			unless ($existingIndices{$idx}) {
				eval { $dbh->do($expectedIndices{$idx}) };
				$log->warn("play_history schema migration: failed to create index '$idx': $@") if $@;
			}
		}

		# Remove obsolete indices
		for my $idx (qw(remoteIdx urlmd5PlayedIdx)) {
			eval { $dbh->do("DROP INDEX IF EXISTS $idx") };
			$log->warn("play_history schema migration: failed to drop index '$idx': $@") if $@;
		}

		main::DEBUGLOG && $log->is_debug && $log->debug('APC external schema migration v1 complete.');
	}

	if ($installedVersion < 2) {
		eval {
			$dbh->do(qq{
				CREATE TABLE IF NOT EXISTS players (
					mac TEXT PRIMARY KEY NOT NULL,
					name TEXT,
					model TEXT,
					last_seen INT NOT NULL DEFAULT 0
				)
			});
		};
		if ($@) {
			$log->error("APC external schema migration v2: failed to create players table: $@");
		} else {
			main::DEBUGLOG && $log->is_debug && $log->debug('APC external schema migration v2 complete.');
		}
	}

	eval {$dbh->do("PRAGMA user_version = $currentVersion")};
	$log->error("APC external schema migration: failed to set user_version: $@") if $@;
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
			$params->{played} || int(time()),
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
			$dbh->do("DELETE FROM play_history WHERE id NOT IN (SELECT id FROM play_history ORDER BY played DESC LIMIT ?)", undef, $maxdbentries);
		};
		if ($@) { $log->error("Error trimming play history: $@"); }
	}

	return 1;
}

sub updateLatestPlayRating {
	my ($class, $params) = @_;
	return unless $dbh && $initialized;
	return unless $params->{urlmd5} && defined $params->{rating} && $params->{client_id};

	eval {
		my $sth = $dbh->prepare_cached(qq{
			UPDATE play_history SET rating = ?
			WHERE id = (
				SELECT id FROM play_history
				WHERE urlmd5 = ?
				AND client_id = ?
				ORDER BY played DESC
				LIMIT 1
			)
		});
		$sth->execute($params->{rating}, $params->{urlmd5}, $params->{client_id});
		$sth->finish();
	};
	$log->error("updateLatestPlayRating failed: $@") if $@;
}

sub savePlayer {
	my ($class, $params) = @_;
	return unless $dbh && $initialized;
	return unless $params->{mac};

	eval {
		my ($exists) = $dbh->selectrow_array('SELECT 1 FROM players WHERE mac = ?', undef, $params->{mac});
		if ($exists) {
			$dbh->do(
				'UPDATE players SET name = ?, model = ?, last_seen = ? WHERE mac = ?',
				undef,
				$params->{name},
				$params->{model},
				$params->{last_seen} || int(time()),
				$params->{mac},
			);
		} else {
			$dbh->do(
				'INSERT INTO players (mac, name, model, last_seen) VALUES (?, ?, ?, ?)',
				undef,
				$params->{mac},
				$params->{name},
				$params->{model},
				$params->{last_seen} || int(time()),
			);
		}
	};
	$log->error("savePlayer failed: $@") if $@;
}

sub getPlayerName {
	my ($class, $mac) = @_;
	return undef unless $dbh && $initialized && $mac;

	my $name;
	eval {
		($name) = $dbh->selectrow_array('SELECT name FROM players WHERE mac = ?', undef, $mac);
	};
	$log->error("getPlayerName failed: $@") if $@;
	return $name;
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
