Alternative Play Count
====

*Alternative Play Count*[^1] provides *alternative* **play count**s and **skip count**s that aim to reflect your true listening history.<br><br>
If you *skip* tracks in a playlist, LMS still increases their *play* counts. With **Alternative Play Count** you set a time *after* which a song counts as **played**. If you skip the song **before**, it counts as **skipped**, **not played**.<br><br>
💡 Even though you can use APC data with any plugin and in any SQLite query, the ***Alternative Play Count* plugin was designed with [Dynamic Playlists](https://github.com/AF-1/lms-dynamicplaylists) and [Visual Statistics](https://github.com/AF-1/lms-visualstatistics) in mind**.<br><br>
As LMS and APC play counts diverge in the long term, you will benefit from the more accurate quality of the data (e.g. in DPL mixes & VS charts).
<br><br>
[⬅️ **Back to the list of all plugins**](https://github.com/AF-1/)
<br><br>

## Requirements

- LMS version >= 7.**9**
- LMS database = **SQLite**
<br><br><br>


## Features
- Set a time[^2] *after* which a song counts as **played**. If you skip the song **before**, it counts as **skipped**, **not played**.
- *Separate database table* for APC values (play count, date last played, skip count, date last skipped)
- *Create* (scheduled) **backups** of your APC data and *restore* values from backup files.
- Option to undo a track's last (accidental) skip count increment if the track is played within a certain time span afterwards.
- **Reset play count** or **skip count** for **individual** tracks by clicking on the corresponding context menu item.
- Use APC data with plugins like [**Dynamic Playlists**](https://github.com/AF-1/lms-dynamicplaylists#dynamic-playlists) or [**Visual Statistics**](https://github.com/AF-1/lms-visualstatistics#visual-statistics).
- Includes skip/filter rules for [**Custom Skip**](https://github.com/AF-1/lms-customskip#custom-skip).
<br><br><br>

[^2]: i.e. percentage of the total song duration

## Installation

You should be able to install **Alternative Play Count** from the LMS main repository (LMS plugin library):<br>**LMS > Settings > Plugins**.<br>

If you want to test a new patch that hasn't made it into a release version yet or you need to install a previous version you'll have to [install the plugin manually](https://github.com/AF-1/sobras/wiki/Manual-installation-of-LMS-plugins).

*Previously released* versions are available here for a very *limited* time after the release of a new version. The official LMS plugins page is updated about twice a day so it usually takes a couple of hours before new released versions are listed.
<br><br>


### Initial values to start with
The plugin will use the current LMS play counts as a starting point.<br>
If you want to start from scratch (no play counts) or use only higher LMS play count values to start your APC database, then you should change this in the APC settings right after installation.
<br><br><br>


## Reporting a bug

If you think that you've found a bug, open an [**issue here on GitHub**](https://github.com/AF-1/lms-alternativeplaycount/issues) and fill out the ***Bug report* issue template**. Please post bug reports on **GitHub only**.

[^1]: If you want localized strings in your language, read <a href="https://github.com/AF-1/sobras/wiki/Adding-localization-to-LMS-plugins"><b>this</b></a>.