#!/usr/bin/env perl

################################################################################
#
#
#     Copyright (C) 2022, 2023 snickerbockers
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
use Capture::Tiny 'tee_merged';

my $logfile;

sub on_branch_fail {
    my ($branch, $reason) = @_;

    say $logfile "****************************************";
    say $logfile "*****";
    say $logfile "***** ERROR: FAILURE TO REBUILD $branch";
    say $logfile "***** $reason";
    say $logfile "*****";
    say $logfile "****************************************";
}

sub log_cmd {
    my ($cmd, $logfiles) = @_;
    my ($txt, $exit) = tee_merged {system("$cmd");};
    for my $file (@{$logfiles}) {
        say $file "****************************************";
        say $file "*****";
        say $file "***** EXECUTE COMMAND \"$cmd\"";
        say $file "*****";
        say $file "****************************************\n";

        print $file $txt;

        say $file "****************************************";
        say $file "*****";
        say $file "***** COMMAND EXIT $exit";
        say $file "*****";
        say $file "****************************************\n";
    }
    return $exit;
}

my $starttime = time();

my $cfg_path = $ARGV[0];

my $datestring = strftime "%m_%d_%y", localtime;

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

    if ($key eq 'branches' || $key eq 'coverity_branches') {
        my @branchlist = split /;/, $val;
        $val = \@branchlist;
    }

    $cfg{$key} = $val;
}

my $logdir = $cfg{'logdir'};
make_path $logdir;
my $logfile_name = strftime "%m_%d_%y_%H-%M-%S.txt", localtime;
my $logfile_path = "$logdir/$logfile_name";
say "the logfile will be \"$logfile_path\"!";
open $logfile, '>', $logfile_path or die "unable to open $logfile_path";

say $logfile "datestring is $datestring";

say $logfile "build directory is $cfg{builddir}";
say $logfile "publish directory is $cfg{pubdir}";

make_path $cfg{'builddir'};
chdir $cfg{'builddir'};

exists $cfg{'branches'} or die 'no branches to build';
exists $cfg{'repo'} or die 'no git repository supplied';

say $logfile "the following branches will be built:";
for (@{$cfg{'branches'}}) {
    say $logfile "\t$_";
}

 build_branch:
for my $branch (@{$cfg{'branches'}}) {
    my $branchdir = "$cfg{pubdir}/$branch";
    make_path $branchdir;

    chdir $cfg{'builddir'};
    say $logfile "checking out $branch";
    my $dir = "gamma_$branch";
    `rm -rf $dir`;
    if (log_cmd("git clone --recursive $cfg{repo} $dir", [$logfile]) != 0) {
        on_branch_fail($branch, "unable to clone");
        next;
    }

    chdir $dir;
    if (log_cmd("git checkout $branch", [$logfile]) != 0) {
        on_branch_fail($branch, "failure to checkout branch");
        next;
    }

    my $hash = `git rev-parse HEAD`;
    chomp $hash;

    # check to see if we already made a build for this hash in this branch
    # the purpose of this is so that we only publish a new nightly if something
    # has changed.
    #
    # note that we do allow for multiple builds with identical hashes as long as
    # they're in different branches.
    if (opendir(my $branchdir_handle, $branchdir)) {
        while (my $buildstamp = readdir($branchdir_handle)) {
            next if ($buildstamp eq '.' || $buildstamp eq '..');
            say $logfile "checking against build $buildstamp";
            my $hashfile = "$branchdir/$buildstamp/BUILD_HASH";
            if (-e $hashfile) {
                open my $hashfile_handle, '<', $hashfile;
                my $oldhash = <$hashfile_handle>;
                close $hashfile_handle;
                chomp $oldhash;
                say $logfile "comparing \"$hash\" to \"$oldhash\"";
                if ($oldhash eq $hash) {
                    say $logfile "Branch $branch build skipped because there is " .
                        "already a build of hash $hash";
                    next build_branch;
                }
            } else {
                say $logfile "$buildstamp did not have a BUILD_HASH file";
            }
        }
    }

    make_path 'build';

    if (!chdir 'build') {
        on_branch_fail($branch, "failure to enter build directory");
        next;
    }

    if (log_cmd('cmake ..', [$logfile]) != 0) {
        on_branch_fail($branch, "failure to configure cmake");
        next;
    }

    if (log_cmd('cmake --build . --target package_source', [$logfile]) != 0) {
        on_branch_fail($branch, "failure to create source tarball");
        next;
    }

    if (log_cmd('cmake --build .', [$logfile]) != 0) {
        on_branch_fail($branch, "failure to build program");
        next;
    }

    if (log_cmd('cpack .', [$logfile]) != 0) {
        on_branch_fail($branch, "failure to package build");
        next;
    }

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

    if (open(my $hashfile_handle, '>', "$pubdir/BUILD_HASH")) {
        say $hashfile_handle $hash;
        close($hashfile_handle)
    } else {
        on_branch_fail($branch, "failure to open $pubdir/BUILD_HASH for writing");
    }

    my $latest_link = "$branchdir/LATEST";
    if (-e $latest_link) {
        unlink $latest_link;
    }
    symlink($datestring, $latest_link);

    # now upload to coverity (if enabled)
    if (grep(/$branch/, @{$cfg{'coverity_branches'}})) {
        say $logfile "*******************************************";
        say $logfile "********* ITS COVERITY TIME $branch *********";
        say $logfile "*******************************************";

        my $checkoutdir = "$cfg{builddir}/gamma_$branch";
        say $logfile "about to chdir to \"$checkoutdir\"";
        chdir $checkoutdir;
        make_path 'coverity_build';
        chdir 'coverity_build';

        `cmake ..`;
        if (log_cmd('cmake ..', [$logfile]) != 0) {
            on_branch_fail($branch, 'failure to configure cmake (coverity)');
            next;
        }

        if (log_cmd("$cfg{'coverity_cmd'} --dir cov-int cmake --build .", [$logfile]) != 0) {
            on_branch_fail($branch, 'failure to build program with cov-build');
            next;
        }

        my $covfile = 'washingtondc-coverity-data.tgz';
        if (log_cmd("tar -czf $covfile cov-int", [$logfile]) != 0) {
            on_branch_fail($branch, 'failure to create coverity tarball');
            next;
        }

        if (log_cmd("curl --form token=$cfg{coverity_token} --form email=$cfg{coverity_email} --form file=\@$covfile --form version=\"$cfg{coverity_version}\" --form description=\"$cfg{coverity_description}\" https://scan.coverity.com/builds?project=WashingtonDC", [$logfile]) != 0) {
            on_branch_fail($branch, 'failure to upload tarball to coverity');
            next;
        }

        say $logfile "************************************************";
        say $logfile "********* COVERITY SUBMISSION COMPLETE *********";
        say $logfile "************************************************";
    }
}

my $deltatime = time() - $starttime;

say "All operations completed in $deltatime seconds";
say $logfile "All operations completed in $deltatime seconds";

close $cfgfile;
close $logfile;
