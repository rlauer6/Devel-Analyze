package Devel::Analyze;

use strict;
use warnings;

# Analyze a source tree and store state to SQLite database

use lib qw{. lib};

our $VERSION = '0.1';

use parent qw{ Class::Accessor::Fast };

use Carp;
use DBD::SQLite;
use Data::Dumper;
use Date::Format;
use Digest::MD5 qw{ md5_hex};
use English qw{ -no_match_vars };
use File::Basename qw{ fileparse };
use File::Find;
use Getopt::Long qw{ :config no_ignore_case };
use List::Util qw{ any max };
use Module::ScanDeps::Static;
use Perl::Critic;
use Pod::Usage;
use Pod::Find qw{ pod_where };
use Scalar::Util qw{ reftype };
use Log::Log4perl qw{ :easy };

if ( $ENV{'DEBUG'} ) {
  require Carp::Always;

  Carp::Always->import;
} ## end if ( $ENV{'DEBUG'} )

# CLI options (--log-level) to Log::Log4perl logging levels mapping
our %LOG_LEVELS = (
  'debug' => $DEBUG,
  'trace' => $TRACE,
  'info'  => $INFO,
  'warn'  => $WARN,
  'error' => $ERROR,
  'fatal' => $FATAL,
);

use Devel::Analyze::Constants qw{ :all };

__PACKAGE__->follow_best_practice;

__PACKAGE__->mk_accessors(
  qw{
    core db_handle db_dsn db_name db_type
    db_user db_password db_options
    dryrun directories sth force filter limit
    ignore
  }
);

caller or __PACKAGE__->main;

########################################################################
sub new {
########################################################################
  my ( $class, @args ) = @_;

  my %options = ref $args[0] ? %{ $args[0] } : @args;

  # required arguments
  foreach my $o (qw{ db_name }) {
    croak "$o is a required argument"
      if !exists $options{$o};
  } ## end foreach my $o (qw{ db_name })

  # database defaults
  $options{'db_type'} //= 'SQLite';

  $options{'db_options'} //= {
    PrintError => $TRUE,
    RaiseError => $TRUE,
    AutoCommit => $TRUE
  };

  $options{'log_level'} //= $ENV{'DEBUG'} ? $DEBUG : $INFO;

  my $self = $class->SUPER::new( \%options );

  $self->init_database;

  return $self;
} ## end sub new

########################################################################
sub init_database {
########################################################################
  my ($self) = @_;

  $self->set_db_handle(
    $self->open_database(
      name     => $self->get_db_name,
      type     => $self->get_db_type,
      user     => $self->get_db_user,
      password => $self->get_db_password,
    )
  );

  return $self;
} ## end sub init_database

########################################################################
sub slurp_file {
########################################################################
  my ( $file, $raw ) = @_;

  my $lines;

  if ( -f $file && -s $file ) {

    open my $fh, '<', $file
      or croak "could not open $file";

    local $RS = undef;

    $lines = <$fh>;

    croak "could not close $file"
      if !close $fh;
  } ## end if ( -f $file && -s $file)

  return $raw ? $lines : [ split /\n/xsm, $lines ];
} ## end sub slurp_file

# returns: id of row or false
########################################################################
sub find_file {
########################################################################
  my ( $self, $file, %args ) = @_;

  my $by = $args{'by'};

  my @fields = $args{'fields'} ? @{ $args{'fields'} } : ($ASTERISK);

  my $field_list = join $COMMA, @fields;

  my $limit = $args{'limit'} ? ' limit ' . $args{'limit'} : $EMPTY;

  my $sql = sprintf q{select * from file where %s = ? %s}, $by, $limit;

  TRACE $sql;

  my @files;

  my $sth = $self->get_db_handle->prepare($sql);
  $sth->execute($file);

  while ( my $row = $sth->fetchrow_hashref ) {
    push @files, $row;
  } ## end while ( my $row = $sth->fetchrow_hashref)

  return \@files;
} ## end sub find_file

# return: hash ref representing row in file table or undef
########################################################################
sub find_single_file {
########################################################################
  my ( $self, $path, %options ) = @_;

  my $files = $self->find_file( $path, by => 'full_path', %options );

  return if !$files || !ref $files || @{$files} != 1;

  return $files->[0];
} ## end sub find_single_file

# returns: bitmask of tests for a file with perl code...

########################################################################
sub is_perl {
########################################################################
  my ( $self, $file ) = @_;

  my $is_perl = 0;

  if ( $file =~ /[.]p[ml]\z/xsm ) {
    $is_perl |= $IS_PERL_EXTENSION;
  } ## end if ( $file =~ /[.]p[ml]\z/xsm)

  if ( -x $file ) {
    $is_perl |= $IS_PERL_EXECUTABLE;
  } ## end if ( -x $file )

  my $is_really_perl = eval {

    open my $fh, '<', $file
      or croak 'could not open ' . $file;

    my $first_line = <$fh>;
    return 0 if !$first_line;

    close $fh
      or croak 'could not close ' . $file;

    if ( $first_line =~ /\A[#][!][[:lower:]]*perl/xsm ) {
      $is_perl |= $IS_PERL_SHEBANG;
    } ## end if ( $first_line =~ /\A[#][!][[:lower:]]*perl/xsm)

    my $err = qx(perl -wc $file 2>&1); ## no critic (InputOutput::ProhibitBacktickOperators)

    TRACE "perl -wc ($err)";

    if ( $err =~ /OK$/xsm ) {
      $is_perl |= $IS_PERL_CODE;
    } ## end if ( $err =~ /OK$/xsm )
    elsif ( $err =~ /Can[']t\s+locate/xsm ) {
      $is_perl |= $IS_PERL_CODE;
    } ## end elsif ( $err =~ /Can[']t\s+locate/xsm)
    else {
      TRACE $file . ' is not perl code';
    } ## end else [ if ( $err =~ /OK$/xsm )]

    return $is_perl;
  };

  return defined $is_really_perl ? $is_really_perl : $is_perl;
} ## end sub is_perl

########################################################################
sub is_shell {
########################################################################
  my ( $self, $file ) = @_;

  my $is_shell = 0;

  if ( $file =~ /[.]sh\z/xsm ) {
    $is_shell |= $IS_SHELL_EXTENSION;
  } ## end if ( $file =~ /[.]sh\z/xsm)

  if ( -x $file ) {
    $is_shell |= $IS_SHELL_EXECUTABLE;
  } ## end if ( -x $file )

  open my $fh, '<', $file
    or croak 'could not open ' . $file;

  my $first_line = <$fh>;

  close $fh
    or croak 'could not close ' . $file;

  if ( $first_line =~ /\A#![a-z\/]*bash|[z]sh\s*$/xsm ) {
    $is_shell |= $IS_SHELL_SHEBANG;
  } ## end if ( $first_line =~ /\A#![a-z\/]*bash|[z]sh\s*$/xsm)

  return $is_shell;
} ## end sub is_shell

########################################################################
sub time_format {
########################################################################
  my ( $time_val, $format ) = @_;

  $time_val //= time;

  $format //= $ISO8601_FORMAT;

  return time2str $format, $time_val;
} ## end sub time_format

########################################################################
sub count_findings {
########################################################################
  my ( $self, $id ) = @_;

  my $sth = $self->get_db_handle->prepare(
    q{select count(*) from critic where file_id = ?});
  $sth->execute($id);

  my ($count) = $sth->fetchrow_array;

  return $count;
} ## end sub count_findings

########################################################################
sub update_perlcritic_findings {
########################################################################
  my ( $self, $file_id, $num_findings ) = @_;

  my $query = <<'END_OF_SQL';
UPDATE file
 SET perlcritic_findings = ?
 WHERE id = ?
END_OF_SQL

  return $self->get_db_handle->do( $query, undef, $num_findings, $file_id );
} ## end sub update_perlcritic_findings

########################################################################
sub _update_critic {
########################################################################
  my ( $self, $files ) = @_;

  my $insert_sth = $self->get_db_handle->prepare(
    <<'END_OF_SQL'
INSERT INTO critic
 (file_id, policy, severity, line_number, column_number, description, full_description)
VALUES
 ( ?,?,?,?,?,?,?)
END_OF_SQL
  );

  my $sth;

  my $next = sub {
    if ($files) {
      my $file = shift @{$files};

      return if !$file;

      my $path = join $EMPTY, @{$file}{qw{path name}};

      return $self->find_single_file($path);
    } ## end if ($files)
    else {

      if ( !$sth ) {
        my $limit = $self->get_limit ? 'LIMIT ' . $self->get_limit : $EMPTY;

        my $query = <<'END_OF_SQL';
SELECT * FROM file
  WHERE is_perl > 1
  %s
END_OF_SQL

        $query = sprintf $query, $limit;

        $sth = $self->get_db_handle->prepare($query);

        $sth->execute;
      } ## end if ( !$sth )

      return $sth->fetchrow_hashref;
    } ## end else [ if ($files) ]
  };

  my %all_findings;

  while ( my $file = $next->() ) {
    INFO sprintf 'criticizing [%s]...', $file->{'full_path'};

    my $id = $file->{'id'};

    my $status = $self->file_status( file => $file );
    TRACE sub { return Dumper( [ $status, $file ] ); };

    if ( !$status->{'status'} && defined $file->{'perlcritic_findings'} ) {
      INFO 'skipping ' . $file->{'full_path'};
      next;
    } ## end if ( !$status->{'status'...})

    if ( $self->count_findings($id) ) {
      INFO 'deleting old findings for ' . $file->{'full_path'};

      $self->get_db_handle->do( 'delete from critic where file_id = ?',
        undef, $id );
    } ## end if ( $self->count_findings...)

    my $critic = Perl::Critic->new(
      -severity => 1,
      -theme    => 'pbp||security||certrule||community||bugs||maintenance'
    );

    my @findings = eval { $critic->critique( $file->{'full_path'} ); };

    if ($EVAL_ERROR) {
      carp 'error executing perlcritic ' . $EVAL_ERROR;
      next;
    } ## end if ($EVAL_ERROR)

    my $max_severity = max map { $_->severity } @findings;

    INFO sprintf 'findings: %d, max severity: %d', scalar @findings,
      $max_severity;

    $self->update_perlcritic_findings( $id, scalar @findings );

    TRACE sub { return Dumper( \@findings ); };

    $all_findings{ $file->{'full_path'} } = scalar @findings;

    if (@findings) {

      foreach my $vio (@findings) {

        DEBUG sprintf "(%s) [%d:%d] [%d] [%s]- %s\n%s\n",
          $file->{'full_path'},
          $vio->line_number,
          $vio->column_number,
          $vio->severity,
          $vio->policy,
          $vio->description,
          $vio->to_string;

        $self->execute( $insert_sth, $id, $vio->policy,
          $vio->severity,    $vio->line_number, $vio->column_number,
          $vio->description, $vio->to_string );

      } ## end foreach my $vio (@findings)
    } ## end if (@findings)
  } ## end while ( my $file = $next->...)

  return $files;
} ## end sub _update_critic

# returns: (check sum, number of lines)
########################################################################
sub check_sum {
########################################################################
  my ( $path, $name ) = @_;

  croak 'no path or name'
    if !$path;

  $name //= $path;

  if ( !( -e $name && -r $name ) ) {
    TRACE 'skipping check_sum on ' . $path;
    return;
  } ## end if ( !( -e $name && -r...))

  return if !-r $name;

  my $contents = slurp_file $name, $SLURP_RAW;

  my $nlines = () = $contents =~ /\n/xsmg;

  return ( md5_hex($contents), $nlines );
} ## end sub check_sum

# return (check sum, nlines, row) or () if file has not been updated
########################################################################
sub file_status {
########################################################################
  my ( $self, %args ) = @_;

  TRACE sub { return Dumper( \%args ); };

  my ( $file, $path, $name ) = @args{qw{ file path name }};

  if ( !$file ) {
    $file = $self->find_single_file($path);
    $file //= {};

    DEBUG sub { return Dumper( [$file] ); };
  } ## end if ( !$file )
  else {
    $path = $file->{'full_path'};
    $name = sprintf '%s%s', @{$file}{qw{name file_type}};
  } ## end else [ if ( !$file ) ]

  my $target = $name && -e $name ? $name : $path;

  my ( undef, $name_part, $ext ) = fileparse( $target, qr/[.][^.]*\z/xsm );

  TRACE "target $target";

  my ( $check_sum, $nlines )
    = check_sum( $path, $name && -e $name ? $name : undef );

  my $is_perl  = $file->{'is_perl'};
  my $is_shell = $file->{'is_shell'};

  if ( !$file->{'check_sum'} || $check_sum ne $file->{'check_sum'} ) {

    if (
      $name_part && !any {/\A$ext\z/xsm}
      qw{ .cvsignore .gitignore .vimrc .jpg .jpeg .css .htm .html .js .swf .gif }

    ) {

      $is_perl  = $self->is_perl($target);
      $is_shell = 0;

      if ( $is_perl <= $IS_PERL_EXECUTABLE ) {
        $is_shell = $self->is_shell($target);

        if ( $is_shell > $IS_SHELL_EXECUTABLE ) {
          $is_perl = 0;
        } ## end if ( $is_shell > $IS_SHELL_EXECUTABLE)
      } ## end if ( $is_perl <= $IS_PERL_EXECUTABLE)
    } ## end if ( $name_part && !any...)
  } ## end if ( !$file->{'check_sum'...})

  TRACE sub { return Dumper( [ ref $file, $file ] ); };

  my %status = (
    check_sum     => $check_sum,
    lines         => $nlines,
    file          => $file // {},
    path          => $path,
    is_shell      => $is_shell,
    is_perl       => $is_perl,
    is_executable => -x $path,
    file_ext      => $ext,
  );

  if ( !$file->{'id'} ) {
    $status{'status'} = 'new';
  } ## end if ( !$file->{'id'} )
  elsif ( $file->{'check_sum'} && $check_sum ne $file->{'check_sum'} ) {
    $status{'status'} = 'updated';
  } ## end elsif ( $file->{'check_sum'...})
  else {
    $status{'status'} = $EMPTY;
  } ## end else [ if ( !$file->{'id'} ) ]

  return \%status;
} ## end sub file_status

########################################################################
sub _update_dependencies {
########################################################################
  my ($self) = @_;

  my $insert_query = <<'END_OF_SQL';
INSERT INTO dependency
  (file_id, dependency, version)
VALUES
  (?, ?, ?)
END_OF_SQL

  my $insert_sth = $self->get_db_handle->prepare($insert_query);

  my $query = <<'END_OF_SQL';
SELECT * FROM file 
  WHERE is_perl > 1
  %s
END_OF_SQL

  my $update_query = <<'END_OF_SQL';
UPDATE file SET dependencies = ?
  WHERE id = ?
END_OF_SQL

  $query = sprintf $query,
    $self->get_limit ? 'LIMIT ' . $self->get_limit : $EMPTY;

  my $sth        = $self->get_db_handle->prepare($query);
  my $sth_update = $self->get_db_handle->prepare($update_query);

  my $scanner = Module::ScanDeps::Static->new( { core => $self->get_core } );

  TRACE sub { return Dumper($scanner); };

  $sth->execute;

  while ( my $file = $sth->fetchrow_hashref ) {
    TRACE sub { return Dumper($file); };

    my $full_path = $file->{'full_path'};
    my $id        = $file->{'id'};

    if ( !-e $full_path ) {
      carp sprintf 'file (%s) no longer exists...skipping', $full_path;

      next;
    } ## end if ( !-e $full_path )

    # skip empty files
    next if !-s $full_path;

    my $status = $self->file_status( file => $file );

    TRACE sub { return Dumper($status); };
    # unless force is set, skip if we already have dependencies
    if ( !$self->get_force
      && defined $file->{'dependencies'}
      && !$status->{'status'} ) {
      INFO 'skipping ' . $full_path;
      next;
    } ## end if ( !$self->get_force...)

    DEBUG 'deleting records from dependency table for ' . $full_path;

    $self->_do(
      statement  => 'delete from dependency where file_id = ?',
      parameters => [ undef, $id ]
    );

    $scanner->set_path($full_path);

    $scanner->set_require( {} );
    $scanner->set_perlreq( {} );

    $scanner->parse;

    my $require = $scanner->get_require;

    TRACE sub { return Dumper($require); };

    my @required_modules = keys %{$require};

    if (@required_modules) {

      $self->execute( $sth_update, ( scalar @required_modules ), $id );

      foreach my $m ( keys %{$require} ) {

        if ( !$self->get_core && $scanner->is_core($m) ) {
          INFO sprintf 'skipping (core) module: %s version: %s', $m,
            $require->{$m};
        } ## end if ( !$self->get_core ...)
        else {
          INFO sprintf 'file: %s module: %s version: %s', $full_path, $m,
            $require->{$m};

          $self->execute( $insert_sth, $id, $m, $require->{$m} );
        } ## end else [ if ( !$self->get_core ...)]
      } ## end foreach my $m ( keys %{$require...})
    } ## end if (@required_modules)
  } ## end while ( my $file = $sth->...)

  return $SUCCESS;
} ## end sub _update_dependencies

########################################################################
sub find_files {
########################################################################
  my ( $self, @directories ) = @_;

  my @ignore_list = @{ $self->get_ignore // [] };

  TRACE sub { return Dumper( \@ignore_list ); };

  my @files;

  find(
    sub {
      my $name = $_;

      my $dir = $File::Find::dir;
      $dir =~ s/[\/]\z//xsm;

      # remove trailing slash from ignore list
      @ignore_list = map { $_ =~ s/[\/]\z//xsm; $_; } @ignore_list;

      return
        if @ignore_list
        && any { $dir =~ /\A([.][\/])?$_[\/]?(.*?)/xsm } @ignore_list;

      if ( !-d $name && $File::Find::name !~ /\A[.][.]?\z/xsm ) {
        TRACE "[$dir] [$File::Find::name] [$name]";
        push @files, $File::Find::name;
      } ## end if ( !-d $name && $File::Find::name...)
    },
    @directories
  );

  return @files;
} ## end sub find_files

########################################################################
sub _update_inventory {
########################################################################
  my ($self) = @_;

  my @filter = $self->get_filter ? @{ $self->get_filter } : ();

  my @directories = @{ $self->get_directories };

  DEBUG sub {
    return Dumper( [ 'filter', \@filter, 'directories', \@directories ] );
  };

  my $file_count = 0;

  my $limit = $self->get_limit;

  my @file_list;

  ######################################################################
  # use File::Find or read list of files from STDIN
  ######################################################################
  if (@directories) {
    @file_list = $self->find_files(@directories);
  } ## end if (@directories)
  else {
    my $fh = *STDIN;

    while (<$fh>) {
      chomp;
      push @file_list, $_;
    } ## end while (<$fh>)
  } ## end else [ if (@directories) ]

  TRACE Dumper( \@file_list );

  return if !@file_list;

  ######################################################################
  # analyze each file
  ######################################################################
  my @files;

  $file_count = eval {
    foreach my $path (@file_list) {
      next if @filter && !any { $path =~ /[.]$_\z/xsm } @filter;

      croak 'limit'
        if $limit && $file_count >= $limit;

      INFO 'analyzing: ', $path;

      $file_count++;

      my $status = $self->file_status( path => $path );

      TRACE sub { return Dumper($status); };

      if ( !$status->{'status'} ) {
        INFO "skipping [$path], file has not changed";
        next;
      } ## end if ( !$status->{'status'...})
      elsif ( $status->{'status'} eq 'new' ) {
        INFO "new file found [$path]";
      } ## end elsif ( $status->{'status'...})
      else {
        DEBUG "file ($path) changed";
      } ## end else [ if ( !$status->{'status'...})]

      my (@stats) = stat $path;

      my $file_info = {
        id                 => $status->{'file'}->{'id'},
        check_sum          => $status->{'check_sum'},
        file_type          => $status->{'file_ext'},
        file_size          => $stats[$SIZE],
        last_analyzed_time => time,
        lines              => $status->{'lines'},
        modified_time      => $stats[$MTIME],
        path               => $path,
        is_perl            => $status->{'is_perl'},
        is_shell           => $status->{'is_shell'},
        is_executable      => $status->{'is_executable'},
      };

      DEBUG sub { return Dumper($file_info) };

      push @files, $file_info;
    } ## end foreach my $path (@file_list)

    return $file_count;
  };

  croak $EVAL_ERROR
    if $EVAL_ERROR && $EVAL_ERROR !~ /limit/xsm;

  carp 'no files analyzed'
    if !@files;

  my $insert_sql = <<'END_OF_SQL';
INSERT INTO file
 (
  full_path, name, path, file_type, num_lines,
  file_size, modified_time, check_sum, last_analyzed_time,
  is_perl, is_shell, is_executable
 )
  VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
END_OF_SQL

  my $update_sql = << 'END_OF_SQL';
UPDATE file SET
  full_path          = ?,
  name               = ?,
  path               = ?,
  file_type          = ?,
  num_lines          = ?,
  file_size          = ?,
  modified_time      = ?,
  check_sum          = ?,
  last_analyzed_time = ?,
  is_perl            = ?,
  is_shell           = ?,
  is_executable      = ?

WHERE id = ?
  
END_OF_SQL

  my $update_sth = $self->get_db_handle->prepare($update_sql);
  my $insert_sth = $self->get_db_handle->prepare($insert_sql);

  TRACE sub { return Dumper( \@files ); };

  foreach my $file (@files) {

    my $path = $file->{'path'};

    my @parameters = ($path);

    my ( $parsed_name, $parsed_path, $parsed_ext )
      = fileparse( $path, qr/[.][^.]*\z/xsm );
    $parsed_path =~ s/\A[.][\/]//xsm; # remove leading relative path

    push @parameters, ( $parsed_name, $parsed_path, $parsed_ext );

    push @parameters,
      @{$file}{
      qw{ lines file_size modified_time check_sum last_analyzed_time is_perl is_shell is_executable }
      };

    my $sth = $insert_sth;

    if ( $file->{'id'} ) {
      $sth = $update_sth;
      push @parameters, $file->{'id'};
    } ## end if ( $file->{'id'} )

    INFO sub { return 'updating record: ' . Dumper( \@parameters ); };

    $self->execute( $sth, @parameters );
  } ## end foreach my $file (@files)

  return \@files;
} ## end sub _update_inventory

########################################################################
sub execute {
########################################################################
  my ( $self, $sth, @parameters ) = @_;

  my $rv = $TRUE;

  if ( !$self->get_dryrun ) {
    $rv = $sth->execute(@parameters);
  } ## end if ( !$self->get_dryrun)

  return $rv;
} ## end sub execute

########################################################################
sub _do {
########################################################################
  my ( $self, @argv ) = @_;

  TRACE sub { return Dumper( \@argv ) };

  my %args;

  if ( @argv == 1 && !ref $argv[0] ) {
    %args = ( statement => shift @argv );
  } ## end if ( @argv == 1 && !ref...)
  elsif ( @argv == 1 ) {
    %args = ( statement => $argv[0] );
  } ## end elsif ( @argv == 1 )
  else {
    %args = @argv;
  } ## end else [ if ( @argv == 1 && !ref...)]

  my $statement = $args{'statement'};

  if ( ref $statement && reftype($statement) eq 'ARRAY' ) {
    $statement = join "\n", @{$statement};
  } ## end if ( ref $statement &&...)

  my $parameters = $args{'parameters'} // [];

  croak 'parameter argument must be array'
    if !ref $parameters || reftype($parameters) ne 'ARRAY';

  TRACE sub {
    return "executing: $statement\n\tparameters:" . Dumper($parameters);
  };

  my $result = 1; # default if dryrun is 1 row effected

  if ( !$self->{'dryrun'} ) {
    $result = $self->get_db_handle->do( $statement, @{$parameters} );
  } ## end if ( !$self->{'dryrun'...})

  return $result;
} ## end sub _do

########################################################################
sub create_tables {
########################################################################
  my ( $self, $fh ) = @_;

  my @create;

  while ( my $line = <$fh> ) {
    chomp $line;
    next if !$line;

    last if $line eq '__END__';

    if ( $line =~ /\A\s*create/xsm && @create ) {

      $self->_do( \@create );

      @create = ();
    } ## end if ( $line =~ /\A\s*create/xsm...)

    push @create, $line;
  } ## end while ( my $line = <$fh> )

  if ( @create > 1 ) {
    $self->_do( \@create );
  } ## end if ( @create > 1 )

  return $self;
} ## end sub create_tables

# returns: array of rows from 'file' table
########################################################################
sub fetch_files {
########################################################################
  my ( $self, %args ) = @_;

  my $dbh = $self->get_db_handle;

  my $sql = q{select * from file order by create_date};

  if ( $args{'limit'} ) {
    $sql .= ' limit ' . $args{'limit'};
  } ## end if ( $args{'limit'} )

  return $dbh->selectall_arrayref( $sql, { Slice => {} } );
} ## end sub fetch_files

########################################################################
sub open_database {
########################################################################
  my ( $self, %options ) = @_;

  my $dsn = sprintf 'dbi:%s:dbname=%s', $self->get_db_type,
    $self->get_db_name;

  $self->set_db_dsn($dsn);

  TRACE sub {
    return sprintf 'opening database %s as (%s)', $self->get_db_dsn,
      $self->get_db_user // $EMPTY;
  };

  $self->set_db_handle(
    DBI->connect(
      $self->get_db_dsn,      $self->get_db_user,
      $self->get_db_password, $self->get_db_options
    )
  );

  return $self->get_db_handle;
} ## end sub open_database

########################################################################
sub update_inventory {
########################################################################
  my (%options) = @_;

  my $help = << 'END_OF_HELP';
analyze update inventory dir dir dir ...

Options
-------
--limit, -l   max files to process
--dryrun, -d  don't actually update table
--report, -r  create report
--format, -f  report format (json, text)

END_OF_HELP
  my $command_args = $options{'command-args'};
  my $command      = shift @{$command_args};

  if ( !$command || $command eq 'help' ) {
    return usage($help);
  } ## end if ( !$command || $command...)

  $options{'directories'} = $command_args;

  my $analyzer = Devel::Analyze->new( \%options );
  my $files    = $analyzer->_update_inventory;

  $analyzer->get_db_handle->disconnect;

  TRACE sub { return Dumper($files); };

  return $SUCCESS;
} ## end sub update_inventory

sub usage {
  my ( $help, $retcode ) = @_;

  print $help;

  return $retcode // $SUCCESS;
} ## end sub usage

########################################################################
sub update_critic {
########################################################################
  my (%options) = @_;

  my $analyzer = Devel::Analyze->new( \%options );
  $analyzer->_update_critic;

  return $SUCCESS;
} ## end sub update_critic

########################################################################
sub update_dependencies {
########################################################################
  my (%options) = @_;

  my $analyzer = Devel::Analyze->new( \%options );
  $analyzer->_update_dependencies;

  return $SUCCESS;
} ## end sub update_dependencies

########################################################################
sub clear_table {
########################################################################
  my (%options) = @_;

  my $analyzer = Devel::Analyze->new( \%options );
  my (@tables) = @{ $options{'command-args'} };

  croak 'no table name'
    if !@tables;

  if ( any { $_ eq 'file' } @tables ) {
    @tables = qw{ file dependency critic };
  } ## end if ( any { $_ eq 'file'...})
  elsif ( !any {/\Afile|critic|dependency\z/xsm} @tables ) {
    croak 'not a table in the database';
  } ## end elsif ( !any {/\Afile|critic|dependency\z/xsm...})

  INFO sprintf "deleting data from [%s]", join "$COMMA$SPACE", @tables;

  foreach my $t (@tables) {
    $analyzer->_do( 'delete from ' . $t );
  } ## end foreach my $t (@tables)

  # if we cleared the dependency or critic tables, reset counts
  if ( !any { $_ eq 'file' } @tables ) {
    if ( any { $_ eq 'dependency' } @tables ) {
      TRACE 'resetting dependency counts in file to null';
      $analyzer->_do('update file set dependencies = null');
    } ## end if ( any { $_ eq 'dependency'...})

    if ( any { $_ eq 'critic' } @tables ) {
      TRACE 'resetting perlcritic findings count in file to null';
      $analyzer->_do('update file set perlcritic_findings = null');
    } ## end if ( any { $_ eq 'critic'...})
  } ## end if ( !any { $_ eq 'file'...})

  return $SUCCESS;
} ## end sub clear_table

########################################################################
sub create_database {
########################################################################
  my (%options) = @_;

  my $analyzer = Devel::Analyze->new( \%options );

  $analyzer->create_tables(*DATA);

  $analyzer->get_db_handle->disconnect;

  return $SUCCESS;
} ## end sub create_database

########################################################################
sub update {
########################################################################
  my (%options) = @_;

  my %updaters = (
    critic    => sub { return update_critic(%options) },
    inventory => sub { return update_inventory(%options) },
    require   => sub { return update_dependencies(%options) },
  );

  my ($command_arg) = @{ $options{'command-args'} };

  croak 'invalid command'
    if !$command_arg || !$updaters{$command_arg};

  return $updaters{$command_arg}->(%options);
} ## end sub update

########################################################################
sub help {
########################################################################
  my (%options) = @_;

  return pod2usage(
    -exitval  => 1,
    -input    => pod_where( { -inc => 1 }, __PACKAGE__ ),
    -sections => 'USAGE|VERSION',
    -verbose  => 99,
  );
} ## end sub help

########################################################################
sub version {
########################################################################
  my (%options) = @_;

  return pod2usage(
    -exitval  => 1,
    -input    => pod_where( { -inc => 1 }, __PACKAGE__ ),
    -sections => 'VERSION|DESCRIPTION|AUTHOR',
    -verbose  => 99,
  );
} ## end sub version

########################################################################
sub init_logger {
########################################################################
  my (%options) = @_;

  if ( !any { $_ eq $options{'log-level'} }
    qw{fatal error warn info debug trace} ) {
    carp 'not a valid log level';
    $options{'log-level'} = 'info';
  } ## end if ( !any { $_ eq $options...})

  $options{'log-level'} = $LOG_LEVELS{ lc $options{'log-level'} };

  return Log::Log4perl->easy_init(
    { level  => $options{'log-level'},
      layout => "(%p) (%r) [%M:%L]- %m{indent}\n",
    }
  );
} ## end sub init_logger

########################################################################
sub set_database {
########################################################################
  my (%options) = @_;

  my $db_name = $options{'database'};

  if ($db_name) {
    $db_name =~ s/[.]db$//xsm;

    $db_name = "$db_name.db";

    carp "WARNING: ($db_name) does not exist...proceeding anyway"
      if !-e $db_name;
  } ## end if ($db_name)

  return $db_name;
} ## end sub set_database

########################################################################
sub main {
########################################################################

  my %options = (
    core        => $TRUE,
    'log-level' => 'error',
  );

  my %commands = (
    update            => \&update,
    clear             => \&clear_table,
    'create-database' => \&create_database,
    help              => \&help,
    version           => \&version,
  );

  if (
    !GetOptions(
      \%options, 'database|D=s', 'log-level|L=s', 'limit|l=i',
      'core!',   'dryrun|d',     'help|h',        'filter|f=s',
      'force|F', 'ignore|i=s@',  'version|v',
    )
  ) {
    exit $FAILURE;
  } ## end if ( !GetOptions( \%options...))

  init_logger(%options);

  TRACE sub { return 'options: ' . Dumper( \%options ); };

  if ( $options{'filter'} ) {
    $options{'filter'} = [ split /\s*$COMMA\s*/xsm, $options{'filter'} ];
  } ## end if ( $options{'filter'...})

  $options{'command'} = shift @ARGV;

  if ( !$options{'help'} && !$options{'version'} ) {
    croak 'not a valid command [' . $options{'command'} . ']'
      if !$options{'command'} || !$commands{ $options{'command'} };

    $options{'db_name'} = set_database(%options);
  } ## end if ( !$options{'help'}...)
  elsif ( $options{'help'} || $options{'version'} ) {
    $options{'command'} = $options{'help'} ? 'help' : 'version';
  } ## end elsif ( $options{'help'} ...)

  TRACE sub { return 'options: ' . Dumper( \%options ); };

  $options{'command-args'} = [@ARGV];
  $commands{ $options{'command'} }->(%options);

  exit $SUCCESS;
} ## end sub main

1;

__DATA__
create table if not exists file (
  id                  integer primary key autoincrement,
  full_path           text,
  path                text,
  name                text,
  file_type           text,
  num_lines           integer,
  commit_hash         text,
  check_sum           text,
  perlcritic_findings integer,
  modified_time       integer,
  last_analyzed_time  integer,
  file_size           integer,
  is_shell            integer, 
  is_perl             integer,
  is_executable       integer,
  dependencies        integer
);
                                 
create table if not exists critic (
  id               integer primary key autoincrement,
  file_id          integer,
  policy           text,
  severity         integer,
  line_number      integer,
  column_number    integer,
  description      text,
  full_description text
);

create table if not exists dependency (
  id         integer primary key autoincrement,
  file_id    integer,
  dependency text,
  version    text
);  
  
__END__

=pod

=head1 NAME

Devel::Analzye - Analyze a source tree and store state to a SQLite database

=head1 DESCRIPTION

Analyzes one or more directories of files looking for Perl and bash
scripts. An inventory of files along with certain attributes are
stored to a SQLite database. Optionally Perl dependencies and their
versions and a C<perlcritic> anlysis can be performed.

=head1 USAGE

perl-analyzer [options] command args

=head2 Options

=over 5

=item --core, -c, --nocore

=item --database, -D

=item --dryrun, -d

=item --filter, -f

=item --force, -f

=item --ignore, -i

=item --limit, -l

=item --log-level, -L

=back

=head2 Commands

=head3 clear

Delete all records from one of the tables. If you clear the C<file>
table, all tables will be cleared.

=over 5

=item Arguments

=over 5

=item table

Name of the table to clear. Valid values are C<file>, C<dependencies>,
C<critic>.

=back

=back

=head3 create-database
 
=head3 update
 
=over 5

=item Arguments

=over 5

=item inventory

=item require

=back

=back

=head1 VERSION

perl-analyzer 0.1

=head1 AUTHOR

Rob Lauer - <bigfoot@cpan.org>

=cut
