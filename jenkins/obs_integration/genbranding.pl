#!/usr/bin/perl
#
# This script automates package build for jenkins based on OBS
# Copyright Klaas Freitag <freitag@owncloud.com>
#
# Released under GPL V.2.
#
# Requires: perl-Config-IniFiles
# Requires: perl-Template-Toolkit
#
# 2014-06-12 jw@owncloud.com, v1.1
#	- added  OBS_INTEGRATION_VERBOSE, OBS_INTEGRATION_OSC for 
#	  debugging and more flexibility when calling osc. Suggested usage: 
#	  env OBS_INTEGRATION_OSC='osc -Ahttps://s2.owncloud.com' ./genbranding.pl ...
#       - added OBS_INTEGRATION_PRODUCT to overwrite the default product openSUSE_13.1
#       - added '--download-api-only' per default to avoid issues with download.o.c.
#	- fixed the year in changelog entries.
#	- Deriving the version number from the mirall tar ball filename, per default.
#	  We can remove the version => ... entries from package.cfg now.
#
# 2014-06-20 jw@owncloud.com, v1.2
#       - option -p destproj added. Default: 'oem:*' Now I can test in home:jw:oem:* 
#         without messing with killing official builds.
#       - option -r relid added. Default '<CI_CNT>.<B_CNT>'
#
# 2014-07-11, jw, V1.3
#	- allow absolute path names as parameters, too. Needed for scripting!

use Getopt::Std;
use Config::IniFiles;
use File::Copy;
use File::Basename;
use File::Path;
use File::Find;
use ownCloud::BuildHelper;
use Cwd;
use Template;

use strict;
use vars qw($miralltar $themetar $templatedir $dir $opt_h $opt_o $opt_b $opt_c $opt_n $opt_f $opt_p $dest_prj $opt_r);

sub help() {
  print<<ENDHELP

  genbranding - Generates a branding from mirall sources and a branding

  Both the mirall and the branding tarball have to be passed ot this
  script. It combines both and creates a new branded source pack. It also
  creates packaging input files (spec-file and debian packaging files).

  This script reads the following input files
  - OEM.cmake from the branding tarball
  - a file mirall/package.cfg from the branding dir.
  - templates for the packaging files from the local templates directory

  Options:
  -h:           help, displays help text
  -b:           build the package locally before uploading
  -o:           osc mode, build against ownCloud obs
  -c "params":  additional osc paramters
  -n:           don't recreate the tarball, use an existing one.
  -f:           force upload, upload even if nothing changed.
  -p "project":	obs project used for -o and -b. Default: '$dest_prj'
  -r "relid":	specify a build release identifier. This number will be part of the binary file names built by osc.

  Call example:
  ./genbranding.pl mirall-1.5.3.tar.bz2 cern.tar.bz2

  Output will be in directory cern-client. 
  Build directory (with -b) will be oem:cern-client.

  Options:
  -h      this help text.

  Environment variables and their defaults:
    OBS_INTEGRATION_VERBOSE=''
    OBS_INTEGRATION_OSC='/usr/bin/osc'
    OBS_INTEGRATION_PRODUCT='openSUSE_13.1'
    OBS_INTEGRATION_ARCH='x86_64'

ENDHELP
;
  exit 1;
}


# ======================================================================================
sub getFileName( $ ) {
  my ($tarname) = @_;
  $tarname = basename($tarname);
  $tarname =~ s/\.tar.*//;
  return $tarname;
}

# Extracts the mirall tarball and puts the theme tarball the new dir
sub prepareTarBall( ) {
    print "Preparing tarball...";

    system("/bin/tar", ("xif", $miralltar, "--force-local") );
    print "Extract mirall...\n";
    my $mirall = getFileName( $ARGV[0] );
    my $theme = getFileName( $ARGV[1] );
    my $newname = $mirall;
    $newname =~ s/mirall-/$theme-/;
    move($mirall, $newname);
    chdir($newname);
    print "Extracting theme...\n";
    my @args = ("--wildcards", "--force-local", "-xif", "$themetar", "*/mirall/*");
    system("/bin/tar", @args);
    chdir("..");

    print " success: $newname\n";
    return $newname;
}

# read all files from the template directory and replace the contents
# of the .in files with values from the substition hash ref.
sub createClientFromTemplate($) {
    my ($substs) = @_;

    print "Create client from template\n";
    foreach my $log( keys %$substs ) {
	print "  - $log => $substs->{$log}\n";
    }

    my $clienttemplatedir = "$templatedir/client";
    my $theme = getFileName( $ARGV[1] );
    my $targetDir = "$theme-client";

    if( $opt_o ) {
	$targetDir = "$dest_prj:$theme/$targetDir";
    } else {
	mkdir("$theme-client");
    }
    opendir(my $dh, $clienttemplatedir);
    my $source;
    # all files, excluding hidden ones, . and ..
    my $tt = Template->new(ABSOLUTE=>1);

    foreach my $source (grep ! /^\./,  readdir($dh)) {
        my $target = $source;
        $target =~ s/BRANDNAME/$theme/;

        if($source =~ /\.in$/) {
            $target =~ s/\.in$//;
            $tt->process("$clienttemplatedir/$source", $substs, "$targetDir/$target") or die $tt->error();
        } else {
            copy("$clienttemplatedir/$source", "$targetDir/$target");
        }
     }
     closedir($dh);

     return cwd();
}

# Create the final themed tarball 
sub createTar($$)
{
    my ($clientdir, $newname) = @_;

    my $tarName = "$clientdir/$newname.tar.bz2";

    if( $opt_n ) {
	die( "Option -n given, but no tarball $tarName exists\n") unless( -e $tarName );
	return;
    }
    my $cwd = cwd();

    die( "Can not find directory to tar: $newname\n" ) unless( -d $newname );

    print "Creating tar $tarName from $newname, in cwd $cwd\n";
    my @args = ("cjfi", $tarName, $newname, "--force-local") ;
    system("/bin/tar", @args);
    rmtree("$newname");
    print " success: Created $tarName\n";
}

# open the OEM.cmake 
sub readOEMcmake( $ ) 
{
    my ($file) = @_;
    my %substs;

    print "Reading OEM cmake file: $file\n";
    
    die("Could not open <$file>\n") unless open( OEM, "$file" );
    my @lines = <OEM>;
    close OEM;
    
    foreach my $l (@lines) {
	if( $l =~ /^\s*set\(\s*(\S+)\s*"(\S+)"\s*\)/i ) {
	    my $key = $1;
	    my $val = $2;
	    print "  * found <$key> => $val\n";
	    $substs{$key} = $val;
	}
    }

    if( $substs{APPLICATION_SHORTNAME} ) {
	$substs{shortname} = $substs{APPLICATION_SHORTNAME};
	$substs{displayname} = $substs{APPLICATION_SHORTNAME};
    }
    if( $substs{APPLICATION_NAME} ) {
	$substs{displayname} = $substs{APPLICATION_NAME};
    }
    if( $substs{APPLICATION_DOMAIN} ) {
	$substs{projecturl} = $substs{APPLICATION_DOMAIN};
    }
    # more tags: APPLICATION_EXECUTABLE, APPLICATION_VENDOR, APPLICATION_REV_DOMAIN, THEME_CLASS, WIN_SETUP_BITMAP_PATH
    return %substs;
}

sub getSubsts( $ ) 
{
    my ($subsDir) = @_;
    my $cfgFile;

    find( { wanted => sub {
	if( $_ =~ /mirall\/package.cfg/ ) {
	    print "Substs from $File::Find::name\n";
	    $cfgFile = $File::Find::name;
          } 
        },
	no_chdir => 1 }, "$subsDir");

    die("Please provide a mirall/package.cfg file in the custom dir!\n") unless( $cfgFile );

    print "Reading substs from $cfgFile\n";
    my %substs;

    my $oemFile = $cfgFile;
    $oemFile =~ s/package\.cfg/OEM.cmake/;
    %substs = readOEMcmake( $oemFile );

    # read the file package.cfg from the tarball and also remove it there evtl.
    my %s2;
    if( -r "$cfgFile" ) {
	%s2 = do $cfgFile;
    } else {
	die "ERROR: Could not read package config file $cfgFile!\n";
    }

    foreach my $k ( keys %s2 ) {
	$substs{$k} = $s2{$k};
    }

    # calculate some subst values, such as 
    $substs{tarball} = $subsDir unless( $substs{tarball} );
    $substs{pkgdescription_debian} = debianDesc( $substs{pkgdescription} );
    $substs{sysconfdir} = "/etc/". $substs{shortname} unless( $substs{sysconfdir} );
    $substs{maintainer} = "ownCloud Inc." unless( $substs{maintainer} );
    $substs{maintainer_person} = "ownCloud packages <packages\@owncloud.com>" unless( $substs{maintainer_person} );
    $substs{desktopdescription} = $substs{displayname} . " desktop sync client" unless( $substs{desktopdescription} );

    return \%substs;
}


# main here.
$dest_prj = 'oem';
getopts('fnbohc:p:r:');
$dest_prj = $opt_p if defined $opt_p;
$dest_prj =~ s{:$}{};

help() if( $opt_h );
help() unless( defined $ARGV[0] && defined $ARGV[1] );

# remember the base dir.
$dir = getcwd;

# Not used currently
# mkdir("packages") unless( -d "packages" );

$miralltar = ($ARGV[0] =~ m{^/}) ? $ARGV[0] : $dir .'/'. $ARGV[0];
$themetar  = ($ARGV[1] =~ m{^/}) ? $ARGV[1] : $dir .'/'. $ARGV[1];
$templatedir = $dir .'/'. "templates";
print "Mirall Tarball: $miralltar\n";
print "Theme Tarball: $themetar\n";

# if -o (osc mode) check if an oem directory exists
my $theme = getFileName( $ARGV[1] );

if( $opt_o ) {
    unless( -d "./$dest_prj" && -d "./$dest_prj:$theme/.osc" ) {
	print "Checking out package $dest_prj:$theme/$theme-client\n";
	my $cwd = Cwd::getcwd;
	checkoutPackage( "$dest_prj:$theme", "$theme-client", $opt_c );
	# chdir('../..'); # checkoutPackage chdirs into the package checkout, if the checkout succeeds.
	chdir($cwd);
    } else {
	# Update the checkout
	my @osc = oscParams($opt_c);
	push @osc, 'up';
	chdir( "$dest_prj:$theme");
	doOSC( @osc );
	chdir( '..' );
    }
}

my $dirName = prepareTarBall();

# returns hash reference
my $substs = getSubsts($dirName);
$substs->{themename} = $theme;

# Automatically derive version number from the mirall tarball.
# It is used in the spec file to find the tar ball anyway, so this should be safe.
unless( defined $substs->{version} )
  {
    my $vers = getFileName($miralltar);
    if ($vers =~ m{-(\d[\d\.]*)$})
      {
        $vers = $1;
      }
    else
      {
        die "\n\nOops: mirall filename $vers does not match {-(\\d[\\d\\.]\*)\$}.\n Cannot exctract version number from here.\n Please add 'version' to package.cfg in $themetar\n";
      }
    $substs->{version} = $vers;
  }

unless (defined $substs->{buildrelease} )
  {
    if (defined $opt_r)
      {
        $substs->{buildrelease} = "<CI_CNT>.<B_CNT>.$opt_r";
      }
    else
      {
        $substs->{buildrelease} = '0';
      }
  }

createClientFromTemplate( $substs );

my $clientdir = ".";


if( $opt_o ) {
    $clientdir = "$dest_prj:$theme/$theme-client";
}
createTar($clientdir, $dirName);

# Check if really files were added and if the tarball was already added
# to the osc repo
my $changeCnt = 0;

if( $opt_o ) {
    chdir( $clientdir );
    my %changes = oscChangedFiles($opt_c);

    foreach my $f (keys %changes) {
	# print " * Checking $f => $changes{$f} ($dirName.tar.bz2)\n";
	if( $changes{$f} =~ /[A\?]/ ) {
	    my @osc = oscParams($opt_c);
	    if( $changes{$f} eq '?' ) { # Add the new tarball to obs
		push @osc, ('add', $f);
		doOSC(@osc);
		$changeCnt++;
	    }

	    # remove the previous tarball!
	    # search for the old tarball
	    if( $f eq $dirName . ".tar.bz2" ) {
	      my $oldTar = $dirName; # something like mirall-cernbox-1.6.0nightly20140505
	      $oldTar =~ s/(.+)-.*$/$1/;   # remove the version

	      opendir(my $dh, '.') || die "can't opendir '.': $!";
	      $oldTar = grep { /$oldTar-.*\.tar\.bz2/ && $_ ne "$dirName.tar.bz2" } readdir($dh);
	      closedir $dh;

	      if( $oldTar && -e $oldTar ) {
		  print "Removing old source file $oldTar\n";
		  @osc = oscParams($opt_c);
		  push @osc, ('rm', $oldTar);
		  doOSC(@osc);
		  $changeCnt++;
	      }
	    }
	} else {
	    print "  Status of $f: $changes{$f}\n";
	    # count files with real changes
	    if( $changes{$f} !~ /[MD]/ ) {
		print "Error: An unexpected file <$f> was found in the osc package.\n";
		die("Please remove or osc add and try again!\n");
	    }
	    $changeCnt++;
	}
    }
    chdir( "../.." );
    print "----\n";
}

# Finished if nothing changed.
if( $changeCnt == 0 && ! $opt_f && $opt_o ) {
    print "No changes to the package, exit!\n";
    exit(0);
}

# Add changelog entries
if( $opt_o ) {
    chdir( $clientdir );
    # create and osc add changelog files if they do not exist yet.
    foreach my $f ( ('debian.changelog', "$theme-client.changes") ) {
      unless( -e $f ) {
	system( "touch $f" );
	my @osc = oscParams($opt_c);
	push @osc, ('add', $f);
	doOSC(@osc);
      }
    }
    
    my $change = "  automatically generated branding added.";
    addDebChangelog( "$theme-client", $change, $substs->{version} );
    addSpecChangelog( "$theme-client", $change );
    chdir( "../.." );
}

# Build the package
my $buildOk = 0;
if( $opt_b ) {
    my @osc = oscParams($opt_c);
    my $product = $ENV{OBS_INTEGRATION_PRODUCT} || 'openSUSE_13.1';
    my $arch =    $ENV{OBS_INTEGRATION_ARCH}    || 'x86_64';
    push @osc, ('build', '--no-service', '--clean', '--download-api-only', '--local-package', $product, $arch, "$theme-client.spec");
    print "+ osc " . join( " ", @osc ) . "\n";
    chdir( $clientdir );
    $buildOk = doOSC( @osc );
    chdir( "../.." );
}

# push to obs.
if( $opt_o ) {
    if( $opt_b ) {
	die( "Local build failed, no uplaod!" ) unless ( $buildOk );
    }
    chdir( $clientdir );

    my @osc = oscParams($opt_c);
    push @osc, ('diff');
    doOSC( @osc );

    @osc = oscParams($opt_c);
    push @osc, ('commit', '-m', 'Pushed by genbranding.pl');

    $buildOk = doOSC( @osc );
    chdir( "../.." );
}

print " Finished!\n\n";

