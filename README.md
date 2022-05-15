Alternative Play Count
====

*Alternative Play Count* provides *alternative* **play count**s and **skip count**s that aim to reflect your true listening history.<br><br>
If you *skip* tracks in a playlist, LMS still increases their *play* counts. With **Alternative Play Count** you set a time *after* which a song counts as **played**. If you skip the song **before**, it counts as **skipped**, **not played**.<br><br>
You can use APC data with plugins like [**Dynamic Playlists 3**](https://github.com/AF-1/lms-dynamicplaylists) or [**Visual Statistics**](https://github.com/AF-1/lms-visualstatistics).<br><br>
The longer you use APC, the more you will benefit from the more accurate quality of the data.
<br><br>

## Requirements

- LMS version >= 7.**9**
- LMS database = **SQLite**
<br><br><br>


## Features
- Set a time[^1] *after* which a song counts as **played**. If you skip the song **before**, it counts as **skipped**, **not played**.
- *Separate database table* for APC values (play count, date last played, skip count, date last skipped)
- *Create* (scheduled) **backups** of your APC data and *restore* values from backup files.
- Option to undo a track's last (accidental) skip count increment if the track is played within a certain time span afterwards.
- **Reset play count** or **skip count** for **individual** tracks by clicking on the corresponding context menu item.
- Use APC data with plugins like [**Dynamic Playlists 3**](https://github.com/AF-1/lms-dynamicplaylists) or [**Visual Statistics**](https://github.com/AF-1/lms-visualstatistics).
<br><br><br>

[^1]: i.e. percentage of the total song duration

## Installation

### Using the repository URL

- Add the repository URL below at the bottom of *LMS* > *Settings* > *Plugins* and click *Apply*:
[https://raw.githubusercontent.com/AF-1/lms-alternativeplaycount/main/public.xml](https://raw.githubusercontent.com/AF-1/lms-alternativeplaycount/main/public.xml)
- Install the new version

### Manual Install
Please read notes on how to [install a plugin manually](https://github.com/AF-1/sobras/wiki/Manual-installation-of-LMS-plugins).

<br>

### Initial values to start with
The plugin will use the current LMS play counts as a starting point.<br>
If you want to start from scratch (no play counts) or use only higher LMS play count values to start your APC database, then you should change this in the APC settings right after installation.
<br><br><br>


## Translation
The [**strings.txt**](https://github.com/AF-1/lms-alternativeplaycount/blob/main/AlternativePlayCount/strings.txt) file contains all localizable strings. Once you're done **testing** the plugin with your translated strings just create a pull request on GitHub.<br>
* Please try not to use the [**single**](https://www.fileformat.info/info/unicode/char/27/index.htm) quote character (apostrophe) or the [**double**](https://www.fileformat.info/info/unicode/char/0022/index.htm) quote character (quotation mark) in your translated strings. They could cause problems. You can use the [*right single quotation mark*](https://www.fileformat.info/info/unicode/char/2019/index.htm) or the [*double quotation mark*](https://www.fileformat.info/info/unicode/char/201d/index.htm) instead. And if possible, avoid (special) characters that are used as [**metacharacters**](https://en.wikipedia.org/wiki/Metacharacter) in programming languages (Perl), regex or SQLite.
* It's probably not a bad idea to keep the translated strings roughly as long as the original ones.<br>
* Some of these strings are supposed to be used with different UIs: my tests usually cover the LMS *default* skin, *Material* skin, *piCorePlayer* (or any other jivelite player like *SqueezePlay*) and maybe some ip3k player like *Boom* if applicable.
* Please leave *(multiple) blank lines* (used to visually delineate different parts) as they are.
<br>
