package Devel::Analyze::Constants;

use strict;
use warnings;

use parent qw{ Exporter };

our $VERSION = '0.01';

use Readonly;
use Log::Log4perl qw{ :easy };

# stat
Readonly our $DEV     => 0;
Readonly our $INO     => 1;
Readonly our $MODE    => 2;
Readonly our $NLINK   => 3;
Readonly our $UID     => 4;
Readonly our $GID     => 5;
Readonly our $RDEV    => 6;
Readonly our $SIZE    => 7;
Readonly our $ATIME   => 8;
Readonly our $MTIME   => 9;
Readonly our $CTIME   => 10;
Readonly our $BLKSIZE => 11;
Readonly our $BLOCKS  => 12;

# chars
Readonly our $ASTERISK  => q{*};
Readonly our $EMPTY     => q{};
Readonly our $COMMA     => q{,};
Readonly our $AMPERSAND => q{&};
Readonly our $SPACE     => q{ };

# booleans
Readonly our $TRUE  => 1;
Readonly our $FALSE => 0;

# shell succes/failure
Readonly our $SUCCESS => 0;
Readonly our $FAILURE => 1;

Readonly our $SLURP_RAW   => 1;
Readonly our $SLURP_LINES => 0;

# sprintf templates
Readonly our $ISO8601_FORMAT => q{%Y-%m-%dT%H:%M:%S%z};

# bitmasks for detecting perl code
Readonly our $IS_PERL_EXECUTABLE => 1; # could be a perl script
Readonly our $IS_PERL_EXTENSION  => 2; # might be perl code
Readonly our $IS_PERL_SHEBANG    => 4; # probably perl code
Readonly our $IS_PERL_CODE       => 8; # must be perl code

# bitmasks for detecting shell scripts
Readonly our $IS_SHELL_EXECUTABLE => 1; # could be a shell script
Readonly our $IS_SHELL_EXTENSION  => 2; # might be a shell script
Readonly our $IS_SHELL_SHEBANG    => 4; # probably a shell script

our %EXPORT_TAGS = (
  stat => [
    qw{
                                 $DEV     
                                 $INO     
                                 $MODE    
                                 $NLINK   
                                 $UID     
                                 $GID     
                                 $RDEV    
                                 $SIZE    
                                 $ATIME   
                                 $MTIME   
                                 $CTIME   
                                 $BLKSIZE 
                                 $BLOCKS  
                             },
  ],
  chars => [
    qw{
                                  
                                  $ASTERISK  
                                  $EMPTY     
                                  $COMMA     
                                  $AMPERSAND 
                                  $SPACE
                              },
  ],

  booleans => [
    qw{
                                     $TRUE    
                                     $FALSE   
                                     $SUCCESS 
                                     $FAILURE
                                 },
  ],

  slurp => [
    qw{
                                  $SLURP_RAW
                                  $SLURP_LINES
                              },
  ],
  templates => [
    qw{
                                      
                                      $ISO8601_FORMAT
                                  },
  ],
  bitmasks => [
    qw{
                                     $IS_PERL_EXECUTABLE  
                                     $IS_PERL_EXTENSION   
                                     $IS_PERL_SHEBANG     
                                     $IS_PERL_CODE        
                                     $IS_SHELL_EXECUTABLE 
                                     $IS_SHELL_EXTENSION  
                                     $IS_SHELL_SHEBANG    
                                 },
  ],
);

our @EXPORT_OK = ();

foreach my $t ( keys %EXPORT_TAGS ) {
  push @EXPORT_OK, @{ $EXPORT_TAGS{$t} };
} ## end foreach my $t ( keys %EXPORT_TAGS)

$EXPORT_TAGS{'all'} = [@EXPORT_OK];

1;
