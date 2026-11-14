# Loads Encore's Now Playing helper into the system's Perl and runs it.
# Usage: /usr/bin/perl bridge.pl /path/to/bridge.dylib
use strict;
use warnings;
use DynaLoader;

my $path = $ARGV[0] or die "usage: bridge.pl /path/to/bridge.dylib\n";
my $lib = DynaLoader::dl_load_file($path, 0)
    or die "encore: could not load $path: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($lib, "bridge_run")
    or die "encore: bridge_run is missing from $path\n";
my $run = DynaLoader::dl_install_xsub("main::bridge_run", $symbol);
&$run();
