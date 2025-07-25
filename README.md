Alternative Play Count
====
![Min. LMS Version](https://img.shields.io/badge/dynamic/xml?url=https%3A%2F%2Fraw.githubusercontent.com%2FAF-1%2Fsobras%2Fmain%2Frepos%2Flms%2Fpublic.xml&query=%2F%2F*%5Blocal-name()%3D'plugin'%20and%20%40name%3D'AlternativePlayCount'%5D%2F%40minTarget&prefix=v&label=Min.%20LMS%20Version%20Required&color=darkgreen)<br>

**Alternative Play Count** provides *alternative* **play count**s and **skip count**s that aim to **reflect your *true* listening history**.<br><br>
If you *skip* tracks in a playlist, LMS still increases their *play* counts. With **Alternative Play Count** you set a time *after* which a song counts as **played**. If you skip the song **before**, it counts as **skipped**, **not played**.<br><br>
You can use APC data in any SQLite query or with other plugins to create/play smart playlists (dynamic playlists), virtual libraries or to skip specific tracks. See [**features**](#features) section for details.<br>

> [!TIP]
> As LMS and APC play counts diverge in the long term, you will benefit from the more accurate quality of the data (e.g. in smart playlists & statistics).

<br>

[⬅️ **Back to the list of all plugins**](https://github.com/AF-1/)
<br><br>

**Use the** &nbsp; <img src="screenshots/menuicon.png" width="30"> &nbsp;**icon** (top right) to **jump directly to a specific section.**

<br><br>


## Features

* Set a time[^2] *after* which a song counts as **played**. If you skip the song **before**, it counts as **skipped**, **not played**.

* The **dynamic played/skipped value** (DPSV) reflects your **listening history/decisions of the *recent past*** and is independent of the absolute play count and skip count values. A track's DPSV increases if played and decreases if skipped (see [FAQ](#faq) for details). You can use it to create smart playlists (dynamic playlists), virtual libraries or skip filter rules.

* Let APC *automatically change the rating* of a track when it's marked as played or skipped (disabled by default).

* *Separate database table* for APC values (play count, date last played, skip count, date last skipped, dynamic played/skipped value)

* *Create* (scheduled) **backups** of your APC data and *restore* values from backup files.

* Automatically undo a track's last (accidental) skip count increment if the track is played within a certain time span afterwards (see plugin settings).

* Option to ignore, i.e. not count skips triggered by the [Custom Skip](https://github.com/AF-1/#-custom-skip) plugin

* **Reset** *play count*, *skip count* or *dynamic played/skipped value* (DPSV) for single tracks, for a selected artist, album, genre, year, decade or playlist (context menu) or for **all** tracks (see [FAQ](#faq)).<br>

* These plugins already make use of APC data: [**Dynamic Playlists**](https://github.com/AF-1/#-dynamic-playlists), [**Dynamic Playlist Creator**](https://github.com/AF-1/#-dynamic-playlist-creator), [**Virtual Library Creator**](https://github.com/AF-1/#-virtual-library-creator), [**Custom Skip**](https://github.com/AF-1/#-custom-skip), [**Context Stats**](https://github.com/AF-1/#-context-stats) and [**Visual Statistics**](https://github.com/AF-1/#-visual-statistics).

**Some features are not enabled by default.** Please go to the plugin's settings page to enable them.

<br><br>


## Screenshots[^1]
<img src="screenshots/apc.gif" width="100%">
<br><br>


## Installation

**Alternative Play Count** is available from the LMS plugin library: `LMS > Settings > Manage Plugins`.<br>

If you want to test a new patch that hasn't made it into a release version yet, you'll have to [install the plugin manually](https://github.com/AF-1/sobras/wiki/Manual-installation-of-LMS-plugins).
<br><br>


### Initial values to start with
The plugin uses the current LMS play counts as a starting point.<br>
If you want to start from scratch (no play counts) or use only higher LMS play count values to start your APC database, then you should change this in the APC settings right after installation.<br>
APC play count and skip count values are used <i>once</i> to populate the DPSV column of the APC database when you <i>first</i> install the plugin. These are just initial values which you can <i>reset</i> at any time on this page: <i>LMS Settings</i> > <i>Advanced</i> > <i>Alternative Play Count</i> > <i>Reset</i>.
<br><br><br>


## Report a new issue

To report a new issue please file a GitHub [**issue report**](https://github.com/AF-1/lms-alternativeplaycount/issues/new/choose).
<br><br><br>


## ⭐ Help others discover this project

If you find this project useful, giving it a <img src="screenshots/githubstar.png" width="20" height="20" alt="star" /> (top right of this page) is a great way to show your support and help others discover it. Thank you.
<br><br><br><br>


## FAQ

<details><summary>»<b>What's a <i>dynamic played/skipped</i> value? How does it work?</b>«</summary><br><p>
The <b>dynamic played/skipped value (DPSV)</b> is supposed to reflect your <i>recent</i> listening habits/decisions and <b>range</b>s between <b>-100</b> (skipped very often recently) and <b>100</b> (played very often recently). When a track has been played long enough to count as played, the DPSV increases, just as it decreases if the track is skipped. The closer the current DPSV is to the middle of the scale (0), the greater the increase/decrease. Conversely, DPSV close to 100 or -100, i.e. tracks that have been played or skipped very often recently, change less and will therefore have to be played or skipped more often to move away from the end of the scale. Also, skipping a track decreases its DPSV twice as much as playing it increases it (this is hard-coded and not a user setting).<br><br>
<i>Example:</i> You've been listening to a great track (rated 5 stars) too many times and you started skipping it when it came up in a mix. It's still a great track, therefore the rating shouldn't change. If you create a dynamic playlist or a CustomSkip filter that exclude tracks with a DPSV of -80 or lower, eventually this track will no longer be played, either skipped by CustomSkip or filtered out in a dynamic playlist - without changing its rating.<br>A quick way to get the track back into the mix would be to reset the track's DPSV to zero by clicking on the DPSV value in the track's context menu.
</p></details><br>

<details><summary>»<b>I have <i>renamed / moved</i> some audio files. How can I preserve the APC data for these tracks (play/skip count, date last played/skipped, DPSV)?</b>«</summary><br><p>
You can use backups. Go to the plugin's settings page (backup section) immediately before you rescan your library and confirm that <i>Backup before each library rescan</i> is <b>en</b>abled. Just to be safe on the safe side, create a manual backup as well.<br>With the rescan completed, go to the plugin's settings page and restore the APC data from the pre-scan backup. APC will try to restore data for moved/renamed tracks using (relative) path guessing and MusicBrainz IDs. Of course, there's no guarantee that it will restore 100% but that's as good as it gets.
</p></details><br>

<details><summary>»<b>Can I <i>reset</i> <i>play count</i>, <i>skip count</i> or <i>DPSV</i> values?</b>«</summary><br><p>
You can <b>reset play count</b>, <b>skip count</b> and / or <b>DPSV</b> values for a single track or for a selected artist, album, genre, year, decade or static playlist by clicking on the corresponding item in the <b>context menu</b>.<br><br>
If you want to reset <ins><b>all</b></ins> APC play count, skip count or DPSV values or even the <i>complete</i> database, you can do so on this page: <i>LMS Settings > Advanced > Alternative Play Count > Reset</i>.
</p></details><br>

<details><summary>»<b>When I create a backup, APC <i>does not write a backup file</i>.</b>«</summary><br><p>
The <i>AlternativePlayCount</i> folder is where APC stores its backup files. On every LMS (re)start, APC checks if there's a folder called <i>AlternativePlayCount</i> in the parent folder. The default <b>parent</b> folder is the <i>LMS preferences folder</i> but you can change that in APC's preferences. If it doesn't find the folder <i>AlternativePlayCount</i> inside the specified parent folder, it will try to create it.<br><br>
The most likely cause is that APC can't create the folder because LMS doesn't have read/write permissions for the parent folder (or the <i>AlternativePlayCount</i> folder). There may be matching error messages in the server log.<br><br>
So please make sure that <b>LMS has read/write permissions (755) for the <i>parent</i> folder - and the <i>AlternativePlayCount</i> folder</b> (if it exists but cannot be accessed).
</p></details><br>

<details><summary>»<b>How does <i>automatic rating</i> work?</b>«</summary><br><p>
If you have the <i>Ratings Light</i> plugin installed, APC can change the <i>rating value</i> of a track when it's marked as played or skipped. When a track has been played long enough to count as played, the rating value increases, just as it decreases if the track is skipped.<br><br><b>Dynamic rating</b><br>The closer the current track rating is to the middle of the scale (50), the greater the increase/decrease. Conversely, ratings close to 100 or 0, i.e. tracks that have been played or skipped very often, change less and will therefore have to be played or skipped more often to move away from the end of the scale. Also, skipping a track decreases its rating up to twice as much as playing it increases it (this is hard-coded and not a user setting). There's a setting that gives you some control over how the dynamic rating algorithm changes ratings and an optional baseline rating for tracks <i>never</i> played before according to the APC database.<br><br><b>Linear rating</b><br>Enable this if you prefer <b>constant/linear</b> rating changes. If a track is then marked as played or skipped, the rating value is always increased or decreased by a <b>constant</b> value that you can set in the plugin settings.
</p></details><br>

<details><summary>»<b>Can this plugin be <i>displayed in my language</i>?</b>«</summary><br><p>If you want localized strings in your language, please read <a href="https://github.com/AF-1/sobras/wiki/Adding-localization-to-LMS-plugins"><b>this</b></a>.</p></details>

<br><br><br>
[^1]: The screenshots might not correspond to the UI of the latest release in every detail.
[^2]: i.e. percentage of the total song duration
