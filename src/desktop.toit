// Copyright (C) 2024 Toitware ApS. All rights reserved.
// Use of this source code is governed by an MIT-style license that can be
// found in the package's LICENSE file.

import host.os
import host.pipe
import system

/**
A library for cross-platform desktop functionality, primarily based on XDG
  (Cross-Desktop Group) specifications.

The XDG specification defines a set of environment variables that are used to
  locate user-specific directories for various purposes. This library provides
  access to some of these directories.

This library does not try to be smart about different operating systems. For
  example, it does not map the $config-home on macOS to the 'Library/Preferences'
  directory. Instead, it uses the \$XDG_CONFIG_HOME environment variable, and, if
  that is not set, falls back to the ~/.config directory. For command-line
  tools, this is more often the correct behavior. However, care must be taken
  when using the \$cache directory. Macos time machine will not back up files in
  '~/Library/Caches', but it will back up files in '~/.cache'. A good work-around
  is to symlink '~/.cache' to somewhere in '~/Library/Caches'.


The XDG base directory specification is available at
  https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html
*/

/**
Returns the value of the given $xdg-env-var-name.
If the environment variable is not set, then uses the given $fallback which
  is assumed to be relative to the user's home.
*/
from-env_ xdg-env-var-name/string --fallback/string -> string?:
  xdg-result := os.env.get xdg-env-var-name
  if xdg-result: return xdg-result

  // All fallbacks are relative to the user's home directory.
  home := os.env.get "HOME"
  if not home and system.platform == system.PLATFORM-WINDOWS:
    home = os.env.get "USERPROFILE"

  if not home: throw "Could not determine home directory."

  separator := system.platform == system.PLATFORM-WINDOWS ? "\\" : "/"
  return "$home$separator$fallback"

/**
The base directory relative to which user-specific data files should be stored.
*/
data-home -> string?:
  return from-env_ "XDG_DATA_HOME" --fallback=".local/share"

/**
The list of additional directories to look for data files in addition to
  $data-home.
*/
data-dirs -> List:
  dirs := os.env.get "XDG_DATA_DIRS"
  if not dirs: return ["/usr/local/share", "/usr/share"]
  return dirs.split ":"

/**
The base directory relative to which user-specific configuration files should be
  stored.
*/
config-home -> string?:
  return from-env_ "XDG_CONFIG_HOME" --fallback=".config"

/**
A list of additional directories to look for configuration files in addition to
  $config-home.
*/
config-dirs -> List:
  dirs := os.env.get "XDG_CONFIG_DIRS"
  if not dirs: return ["/etc/xdg"]
  return dirs.split ":"

/**
The base directory relative to which user-specific state files should be stored.

The state directory contains data that should be kept across program invocations,
  but is not important or portable enough to be stored in the $data-home.

Examples of data that might be stored in the state directory include:
- logs, recently used files, history, etc.
- the current state of the application on this machine (like the layout, undo history, etc.)
*/
state-home -> string?:
  return from-env_ "XDG_STATE_HOME" --fallback=".local/state"

/**
The base directory relative to which user-specific non-essential (cached) data
  should be stored.
*/
cache-home -> string?:
  return from-env_ "XDG_CACHE_HOME" --fallback=".cache"

/**
Opens the given URL in the default browser.

Typically, opening the browser doesn't take long, so the function will wait for
  at most $timeout-ms milliseconds. If the command hasn't returned in that time
  it will be killed.
*/
open-browser url/string --timeout-ms/int=20_000:
  catch:
    command/string? := null
    args/List? := null
    platform := system.platform
    if platform == system.PLATFORM-LINUX:
      command = "xdg-open"
      args = [ url ]
    else if platform == system.PLATFORM-MACOS:
      command = "open"
      args = [ url ]
    else if platform == system.PLATFORM-WINDOWS:
      command = "cmd"
      escaped-url := url.replace "&" "^&"
      args = [ "/c", "start", escaped-url ]
    else:
      throw "Unsupported platform"

    if command != null:
      process := pipe.fork command ([command] + args)
          --create-stdin
          --create-stdout
          --create-stderr
          --use-path
      process.stdin.close
      stdout := process.stdout
      stderr := process.stderr
      task --background:: catch: stdout.in.drain
      task --background:: catch: stderr.in.drain
      task --background::
        // The 'open' command should finish in almost no time.
        // Even if it doesn't, then the CLI almost always terminates
        // shortly after calling 'open'.
        // However, if we modify the CLI, so it becomes long-running (for
        // example inside a server), we need to make sure we don't keep
        // spawned processes around.
        exception := catch: with-timeout --ms=timeout-ms:
          process.wait
        if exception == DEADLINE-EXCEEDED-ERROR:
          killed := false
          if platform != system.PLATFORM-WINDOWS:
            // Try a gentle kill first.
            SIGTERM ::= 15
            catch:
              pipe.kill_ process.pid SIGTERM
              with-timeout --ms=1_000:
                process.wait
                killed = true
          if not killed:
            SIGKILL ::= 9
            catch: pipe.kill_ process.pid SIGKILL
