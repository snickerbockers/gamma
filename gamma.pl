#!/usr/bin/env perl

################################################################################
#
#
#     Copyright (C) 2022 snickerbockers
#
#     This program is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 3 of the License, or
#     (at your option) any later version.
#
#     This program is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#
################################################################################

use v5.20;
use POSIX qw(strftime);
use File::Path qw(make_path);
use File::Copy;

sub on_branch_fail {
    my ($branch, $reason) = @_;

    say STDERR "****************************************";
    say STDERR "*****";
    say STDERR "***** ERROR: FAILURE TO REBUILD $branch";
    say STDERR "***** $reason";
    say STDERR "*****";
    say STDERR "****************************************";
}

my $starttime = time();

my $cfg_path = $ARGV[0];

my $datestring = strftime "%m_%d_%y", localtime;

say "datestring is $datestring";
say "configure file will be read from $cfg_path";

open my $cfgfile, '<', $cfg_path or die "unable to open \"$cfg_path\"";
my %cfg;
for (<$cfgfile>) {
    /(.+)=(.+)/;
    my $key = $1;
    my $val = $2;

    # trim leading/trailing whitespace
    $key =~ s/^\s+//;
    $val =~ s/^\s+//;
    $key =~ s/\s+$//;
    $val =~ s/\s+$//;

    if ($key eq 'branches') {
        my @branchlist = split /;/, $val;
        $val = \@branchlist;
    }

    $cfg{$key} = $val;
}

say "build directory is $cfg{builddir}";
say "publish directory is $cfg{pubdir}";

make_path $cfg{'builddir'};
chdir $cfg{'builddir'};

exists $cfg{'branches'} or die 'no branches to build';
exists $cfg{'repo'} or die 'no git repository supplied';

say "the following branches will be built:";
for (@{$cfg{'branches'}}) {
    say "\t$_";
}

for my $branch (@{$cfg{'branches'}}) {
    chdir $cfg{'builddir'};
    say "checking out $branch";
    my $dir = "gamma_$branch";
    `rm -rf $dir`;
    if (system('git', 'clone', '--recursive', "$cfg{repo}", $dir) != 0) {
        on_branch_fail($branch, "unable to clone");
        next;
    }

    chdir $dir;
    if (system('git', 'checkout', "$branch") != 0) {
        on_branch_fail($branch, "failure to checkout branch");
        next;
    }

    make_path 'build';

    if (!chdir 'build') {
        on_branch_fail($branch, "failure to enter build directory");
        next;
    }

    if (system('cmake', '..') != 0) {
        on_branch_fail($branch, "failure to configure cmake");
        next;
    }

    if (system('cmake', '--build', '.', '--target', 'package_source') != 0) {
        on_branch_fail($branch, "failure to create source tarball");
        next;
    }

    if (system('cmake', '--build', '.') != 0) {
        on_branch_fail($branch, "failure to build program");
        next;
    }

    if (system('cpack', '.') != 0) {
        on_branch_fail($branch, "failure to package build");
        next;
    }

    my $branchdir = "$cfg{pubdir}/$branch";
    make_path $branchdir;

    my $pubdir_first = "$cfg{pubdir}/$branch/$datestring";
    my $pubdir = $pubdir_first;

    my $idx = 0;
    while (-e $pubdir) {
        $idx++;
        $pubdir = $pubdir_first . "_build_$idx";
    }

    make_path $pubdir;

    if (!copy('WashingtonDC-0.0.0-Source.tar.gz', "$pubdir/")) {
        on_branch_fail($branch, "failure to copy source tarball to $pubdir");
        next;
    }

    if (!copy('WashingtonDC-0.0.0-Linux.tar.gz', "$pubdir/")) {
        on_branch_fail($branch, "failure to copy binary tarball to $pubdir");
        next;
    }
}

my $deltatime = time() - $starttime;

say "All operations completed in $deltatime seconds";
