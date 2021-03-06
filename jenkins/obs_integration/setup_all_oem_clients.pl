#! /usr/bin/perl -w
#
# (c) 2014 jw@owncloud.com - GPLv2 or ask.
#
# 
# Iterate over customer-themes github repo, get a list of themes.
# for each theme, 
#  - generate the branding tar ball
#  - generate project hierarchy (assert that ...:oem:BRANDINGNAME exists)
#  - assert the client package exists, (empty or not)
#  - checkout the client package
#  - run ./genbranding.pl with a build token number.
#  - checkin (done by genbranding)
#  - Remove the checkout working dir. It is not in the tmp area.
#  - run ./setup_oem_client.pl with the dest_prj, (packages to be created on demand)
#
# Poll obs every 5 minutes:
#  For each packge in the obs tree
#   - check all enabled targets for binary packages with the given build token number.
#     if a package has them all ready. Generate the linux package binary tar ball.
#
# This replaces:
#  https://rotor.owncloud.com/view/mirall/job/mirall-source-master (rolled into
#  https://rotor.owncloud.com/job/customer-themes		   (we pull ourselves)
#  https://rotor.owncloud.com/view/mirall/job/mirall-linux-custom  (another genbranding.pl wrapper)
#
use Data::Dumper;
use File::Path;
use File::Temp ();	# tempdir()
use POSIX;		# strftime()
use Cwd ();

my $build_token         = 'jw_'.strftime("%Y%m%d", localtime);

my $source_tar          = shift || 'v1.6.1';
my $container_project   = 'home:jw:oem';


my $customer_themes_git = 'git@github.com:owncloud/customer-themes.git';
my $source_git          = 'https://github.com/owncloud/mirall.git';
my $osc_cmd             = 'osc -Ahttps://s2.owncloud.com';
my $genbranding         = "env OBS_INTEGRATION_OSC='$osc_cmd' ./genbranding.pl -p '$container_project' -r '<CI_CNT>.<B_CNT>.$build_token' -o -f";

my $TMPDIR_TEMPL = '_oem_XXXXX';
our $verbose = 1;
our $no_op = 0;
my $skipahead = 5;	# 5 start with all tarballs there.

sub run
{
  my ($cmd) = @_;
  print "+ $cmd\n" if $::verbose;
  return if $::no_op;
  system($cmd) and die "failed to run '$cmd': Error $!\n";
}

sub pull_VERSION_cmake
{
  my ($file) = @_;
  my ($maj,$min,$pat,$so) = (0,0,0,0);

  open(my $fd, "<$file") or die "cannot read $file\n";
  while (defined(my $line = <$fd>))
    {
      chomp $line;
      $maj = $1 if $line =~ m{MIRALL_VERSION_MAJOR\s+(\d+)};
      $min = $1 if $line =~ m{MIRALL_VERSION_MINOR\s+(\d+)};
      $pat = $1 if $line =~ m{MIRALL_VERSION_PATCH\s+(\d+)};
      $so  = $1 if $line =~ m{MIRALL_SOVERSION\s+(\d+)};
    }
  close $fd;
  return "$maj.$min.$pat";
}

# pull a branch from git, place it into destdir, packaged as a tar ball.
# This also double-checks if the version in VERSION.cmake matches the name of the branch.
sub fetch_mirall_from_branch
{
  my ($giturl, $branch, $destdir) = @_;

  my $gitsubdir = "$destdir/mirall_git";
  # CAUTION: keep in sync with
  # https://rotor.owncloud.com/view/mirall/job/mirall-source-master/configure

  run("git clone --depth 1 --branch $branch $source_git $gitsubdir")
    unless $skipahead > 1;

  my $version = $1 if $branch =~ m{^v([\d\.]+)$};
  my $v_git = pull_VERSION_cmake("$gitsubdir/VERSION.cmake");
  if (defined $version)
    {
      if ($v_git ne $version)
	{
	  warn "oops: asked for git branch v$version, but got version $v_git\n";
	  $version = $v_git;
	}
      else
	{
	  print "$version == $v_git, yeah!\n";
	}
    }
  else
    {
      print "branch=$branch contains VERSION.cmake version=$version\n";
      $version = $v_git;
    }

  my $pkgname = "mirall-${version}";
  $source_tar = "$destdir/$pkgname.tar.bz2";
  run("cd $gitsubdir && git archive HEAD --prefix=$pkgname/ --format tar | bzip2 > $source_tar")
    unless $skipahead > 2;
  return $source_tar;
}


my $tmp;
if ($skipahead)
  {
    $tmp = '/tmp/_oem_KxE90';
    print "re-using tmp=$tmp\n";
  }
else
  {
    $tmp = File::Temp::tempdir($TMPDIR_TEMPL, DIR => '/tmp/');
  }

my $tmp_t = "$tmp/customer_themes_git";

$source_tar = fetch_mirall_from_branch($source_git, $source_tar, $tmp) 
  if $source_tar =~ m{^v[\d\.]+$};
$source_tar = Cwd::abs_path($source_tar);	# we'll chdir() around. Take care.

die "need a source_tar path name or version number matching /^v[\\d\\.]+$/\n" unless defined $source_tar;

run("git clone --depth 1 $customer_themes_git $tmp_t") 
  unless $skipahead > 3;

opendir(DIR, $tmp_t) or die("cannot opendir my own $tmp: $!");
my @d = grep { ! /^\./ } readdir(DIR);
closedir(DIR);

my @candidates = ();
for my $dir (sort @d)
  {
    next unless -d "$tmp_t/$dir/mirall";
    #  - generate the branding tar ball
    # CAUTION: keep in sync with jenkins jobs customer_themes
    # https://rotor.owncloud.com/view/mirall/job/customer-themes/configure
    chdir($tmp_t);
    run("tar cjf ../$dir.tar.bz2 ./$dir")
      unless $skipahead > 4;
    push @candidates, $dir if -f "$tmp_t/$dir/mirall/package.cfg";
  }

print Dumper \@candidates;

sub obs_user
{
  my ($osc_cmd) = @_;
  open(my $ifd, "$osc_cmd user|") or die "cannot fetch user info: $!\n";
  my $info = join("",<$ifd>);
  chomp $info;
  $info =~ s{:.*}{};
  return $info;
}

# KEEP IN SYNC with obs_pkg_from_template
sub obs_prj_from_template
{
  my ($osc_cmd, $template_prj, $prj, $title) = @_;

  # test, if it is already there, if so, do nothing:
  open(my $tfd, "$osc_cmd meta prj '$prj' 2>/dev/null|") or die "cannot check '$prj'\n";
  if (<$tfd>)
    {
      close($tfd);
      print "Project '$prj' already there.\n";
      return;
    }

  open(my $ifd, "$osc_cmd meta prj '$template_prj'|") or die "cannot fetch meta prj $template_prj: $!\n";
  my $meta_prj_template = join("",<$ifd>);
  close($ifd);
  my $user = obs_user($osc_cmd);

  # fill in the template with our data:
  $meta_prj_template =~ s{<project\s+name="\Q$template_prj\E">}{<project name="$prj">}s;
  $meta_prj_template =~ s{<title>.*?</title>}{<title/>}s;	# make empty, if any.
  # now we always have the empty tag, to fill in.
  $meta_prj_template =~ s{<title/>}{<title>$title</title>}s;
  # add myself as maintainer:
  $meta_prj_template =~ s{(\s*<person\s)}{$1userid="$user" role="maintainer"/>$1}s;

  open(my $ofd, "|$osc_cmd meta prj '$prj' -F - >/dev/null") or die "cannot create project: $!\n";
  print $ofd $meta_prj_template;
  close($ofd);
  print "Project '$prj' created.\n";
}

# almost a duplicate from above.
# KEEP IN SYNC with obs_prj_from_template
sub obs_pkg_from_template
{
  my ($osc_cmd, $template_prj, $template_pkg, $prj, $pkg, $title) = @_;

  # test, if it is already there, if so, do nothing:
  open(my $tfd, "$osc_cmd meta pkg '$prj' '$pkg' 2>/dev/null|") or die "cannot check '$prj/$pkg'\n";
  if (<$tfd>)
    {
      close($tfd);
      print "Package '$prj/$pkg' already there.\n";
      return;
    }

  open(my $ifd, "$osc_cmd meta pkg '$template_prj' '$template_pkg'|") or die "cannot fetch meta pkg $template_prj/$template_pkg: $!\n";
  my $meta_pkg_template = join("",<$ifd>);
  close($ifd);

  # fill in the template with our data:
  $meta_pkg_template =~ s{<package\s+name="\Q$template_pkg\E" project="\Q$template_prj\E">}{<package name="$pkg" project="$prj">}s;
  $meta_pkg_template =~ s{<title>.*?</title>}{<title/>}s;	# make empty, if any.
  # now we always have the empty tag, to fill in.
  $meta_pkg_template =~ s{<title/>}{<title>$title</title>}s;

  open(my $ofd, "|$osc_cmd meta pkg '$prj' '$pkg' -F - >/dev/null") or die "cannot create package: $!\n";
  print $ofd $meta_pkg_template;
  close($ofd);
  print "Package '$prj/$pkg' created.\n";
}


## make sure the top project is there in obs
obs_prj_from_template($osc_cmd, 'desktop', $container_project, "OwnCloud Desktop Client OEM Container project");
my $scriptdir = $1 if $0 =~ m{(.*)/};
chdir($scriptdir) if defined $scriptdir;

for my $branding ('switchdrive')	# @candidates)
  {
    ## generate the individual container projects
    obs_prj_from_template($osc_cmd, 'desktop', "$container_project:$branding", "OwnCloud Desktop Client project $branding");

    ## create an empty package, so that genbranding is happy.
    obs_pkg_from_template($osc_cmd, 'desktop', 'owncloud-client', "$container_project:$branding", "$branding-client", "$branding Desktop Client");

    run("$osc_cmd checkout '$container_project:$branding' '$branding-client'");
    run("$genbranding '$source_tar' '$tmp/$branding.tar.bz2'");	# checkout branding-client, update, checkin.
    run("rm -rf '$container_project:$branding'");

    ## fill in all the support packages.
    ## CAUTION: trailing colon is important!
    run("./setup_oem_client.pl '$branding' '$container_project:'");
  }

die("leaving around $tmp");

