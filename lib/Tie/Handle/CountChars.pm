package Tie::Handle::CountChars;
use strict;
use warnings;
use version 0.77; our $VERSION = version->declare( "v0.1.0" );
# ABSTRACT: make your handles count the bytes in and out
use base qw( Exporter Tie::Handle );
use Carp;
use Data::Dumper;

our @EXPORT_OK = qw( make_fh_accountable );

# TODO: find a way to keep errors from reporting from this package.
#  $Carp::Internal does not seem to work :-/

### TODO? make the tie-object inherit from the same classes as the tied
###  file-handle. Doing so might allow us to simply use the object as
###  the handle.


# the whole point for all this hackery
sub chars_written { return shift->{written} }
sub chars_read    { return shift->{read}    }
sub chars_total   { my $self = shift; return $self->{read} + $self->{written} }


# convienence export to make the tie prettier
sub make_fh_accountable {
  return tie *{$_[0]}, __PACKAGE__, $_[0];
}


# create the tie by aliasing the file-handle. The user must actually tie the
# actual glob and then pass a ref to that glob as an argument after the tie
# class. This sucks, but I see no good way to do it without using padwalker
# or other such deep magick.
sub TIEHANDLE {
  my ($class, $fh) = @_;

  $fh and ref($fh) eq 'GLOB'
    or croak
      "Need to pass a ref to the filehandle as the third argument to tie\n";

  # XXX: If there's a way to get the 'mode' of the original handle, I can't
  #  find it. '+>' works for me, but I suspect it may not work for everyone.
  open my $dup_fh, '+>&=', $fh or croak $!;

  # TODO: find out what characteristics of the original fh are 'inherited' by
  #  the alias fh and which aren't - and which need to be manually set, like
  #  autoflush, below.

  # if autoflush was on, make the new FH match.
  # (else, turn it back off on the original fh)
  $fh->autoflush ? $dup_fh->autoflush : $fh->autoflush(0);

  # XXX: I dunno if I should keep a ref to the original fh here, but I
  # suspect it's not the best idea, even if I use weaken().
  return bless { dup_fh => $dup_fh, read => 0, written => 0 }, $class;
}


### various write operations ###

sub PRINT {
  my $self = shift;
  my $len = length join '', @_;
  my $ret = print { $self->{dup_fh} } @_;
  $self->{written} += $len if $len and $ret;
  return $ret;
}

# using $_[x] vars for better performance (as if all the rest of 
# his magick isn't bad enough)
sub WRITE {
  my $fh = $_[0]->{dup_fh};
  my $len =
    @_  < 3 ? CORE::syswrite( $fh, $_[1]               ) :
    @_ == 3 ? CORE::syswrite( $fh, $_[1], $_[2]        ) :
              CORE::syswrite( $fh, $_[1], $_[2], $_[3] ) ;
  $_[0]->{written} += $len if $len;
  return $len;
}


### various read operations ###

sub GETC { 
  my $ret = getc( $_[0]->{dup_fh} );
  $_[0]->{read}++ if $ret;
  return $ret;
}

sub READ {
  my $fh = $_[0]->{dup_fh};
  my $len =
    @_ == 3 ? CORE::read( $fh, $_[1], $_[2]        ) :
              CORE::read( $fh, $_[1], $_[2], $_[3] ) ;
  $_[0]->{read} += $len if $len;
  return $len;
}

sub READLINE {
  my $fh = $_[0]->{dup_fh};
  if ( wantarray ) {
    my @lines = <$fh>;
    $_[0]->{read} += length join '', @lines;
    return @lines;
  }
  elsif ( defined wantarray ) {
    my $lines = <$fh>;
    $_[0]->{read} += length $lines;
    return $lines;
  }
  # XXX: if wantarray is undef, we have void context. can that ever happen here?
}


### these just pass-through to underlying built-ins ###

sub EOF     { eof(     $_[0]->{dup_fh} ) }
sub TELL    { tell(    $_[0]->{dup_fh} ) }
sub FILENO  { fileno(  $_[0]->{dup_fh} ) }
sub CLOSE   { close(   $_[0]->{dup_fh} ) }
sub BINMODE { binmode( $_[0]->{dup_fh} ) }
sub SEEK    { seek(    $_[0]->{dup_fh}, $_[1], $_[2] ) }


### XXX: not yet sure if this needs to be done differently. I pretty much
###  cargo-culted it from Tie::StdHandle
sub OPEN {
 close  $_[0]->{dup_fh} if defined fileno $_[0]->{dup_fh};
 return @_ == 2 ?
   open( $_[0]->{dup_fh}, $_[1]        ) :
   open( $_[0]->{dup_fh}, $_[1], $_[2] ) ;
}

sub DESTROY { $_[0]->CLOSE( $_[0]->{dup_fh} ) }

1 && q{ I can't believe this wasn't already on the CPAN. }; # truth
__END__

=head1 NAME

Tie::Handle::CountChars - make your handles count the bytes in and out

=head1 VERSION

version 0.1.0
(alpha: interfaces and implementations may change)

=head1 SYNOPSIS

  use File::Temp qw( tmpnam );
  use File::Slurp qw( read_file );

  use Tie::Handle::CountChars qw( make_fh_accountable );

  my $tmpfile = tmpnam();

  open my $fh, '>', $tmpfile;

  make_fh_accountable( $fh );    # this does the tie properly

  print $fh "FOO\n";             # write 4 bytes to the handle
  syswrite $fh, "BAR\nX\n\n", 6; # only write 6 of the 7 bytes
  close $fh;

  my $chars_in_file = length scalar read_file( $tmpfile );
  my $chars_written = ( tied *$fh )->chars_written;

  print "CHARS IN FILE: $chars_in_file\n";
  print "CHARS WRITTEN: $chars_written\n";
  print $chars_in_file == $chars_written ? "OK\n" : "NOT OK\n";


=head1 DESCRIPTION

This module allows you to keep track of the characters written to and read
from a perl "HANDLE" (or IO::Handle object). This seems to work for anything
that behaves as a HANDLE, including anything that inherits from IO::Handle.

When you are done counting the chars, get your data by calling methods on
the tied-object and then simply untie the handle.

This almost certainly imposes a performance penalty on IO through the tied
handles but I have yet to benchmark it to figure out how much of an impact
actually exists.

So... why B<characters> and not B<bytes>? Simple. When working with B<ASCII>,
I<characters *are* bytes>... but if the handle you've got is using B<utf8>
mode, I<characters can potentially be several bytes long>, and the various
facilities in perl to track this stuff always return
B<character counts, not bytes>! 

I could add some code to tease out the actual byte-count in all cases, but
I'll wait for somebody to formally request it before even trying.
I<(hint, hint: patches welcome!)>

=head1 EXPORTABLE FUNCTIONS

=over 4

=item B<make_fh_accountable( $fh )>

This function takes a reference to the handle you want to tie and does the
tie properly. When called in void context, nothing is returned. When called
in scalar context, the tie-object is returned. When called in list context,
the tie-object and the tied handle are returned.

Remember, the argument B<must> be a reference to the handle GLOB or a
handle-like variable (for example, something that inherits from IO::Handle)

Some examples:

  make_fh_accountable( \*STDOUT     );
  make_fh_accountable( $io_file_obj );
  make_fh_accountable( $lexical_fh  );

=back

=head1 METHODS

All methods listed below must be called on the tie-object, obtained like so:

  my $to = tied *$fh;

=over 4

=item B<chars_read()>

Returns the number of characters read from the tied handle.

=item B<chars_written()>

Returns the number of characters written to the tied handle.

=item B<chars_total()>

The sum of the read and written character counts.

=back

=head1 SEE ALSO

=over 4

=item L<Tie::Handle>

=item L<IO::WrapTie>

=item L<IO::Handle>

=item L<perlopentut>

=item L<perlipc>

=item L<perltie>

=item L<IO::Socket::ByteCounter>

=back

=head1 BUGS & CAVEATS

No known bugs yet. Please report any you find and I'm happy to fix them.

Caveats include the usual when using tie, and also the fact that this adds
overhead to any operations done on the tied handles. I don't know I<how much>
overhead, but I suspect that for applications that need maximum IO performance
it could be a deal-breaker. However, why don't you try it and let me know. I
strongly suspect that the overhead will not make much of a difference for the
vast majority of those who use this.

=head1 SUPPORT

=head2 bugs

Please report any bugs or feature requests via one of the following:

=over 4

=item * L<< Web: The CPAN Request Tracker (RT) queue for this module | http://rt.cpan.org/NoAuth/Bugs.html?Dist=Tie-Handle-CountChars >>

=item * L<< Email: CPAN RT email queue for this module | mailto:bug-tie-handle-countchars@rt.cpan.org >>

=back

=head2 feature requests

If you want additional features, please make that request by opening a ticket
in RT, just like for bug reports, as described above.

=head2 questions

If you have questions, please contact me via one of the following:

=over 4

=item * Email to the author or maintainers

=item * L<< IRC channel #perl-help on irc.perl.org | irc://irc.perl.org/perl-help >>

=item * L<< IRC channel #perl on irc.freenode.net | irc://irc.freenode.net/perl >>

=back

=head2 other info

You can also find more information at:

=over 4

=item * L<< AnnoCPAN: Annotated CPAN documentation | http://annocpan.org/dist/Tie-Handle-CountChars >>

=item * L<< CPAN Ratings | http://cpanratings.perl.org/d/Tie-Handle-CountChars >>

=item * L<< CPAN Search | http://search.cpan.org/dist/Tie-Handle-CountChars >>

=item * perldoc

After installing, you can find this documentation with the perldoc command:

  perldoc Tie::Handle::CountChars

=back

=head1 AUTHOR

L<< Stephen R. Scaffidi | mailto:sscaffidi@cpan.org >>

=head1 CONTRIBUTORS & ACKNOWLEDGEMENTS

Submit bug reports or feature requests or patches to get your name right here!

=head1 COPYRIGHT & LICENSE

Copyright 2011 L<< Stephen R. Scaffidi | mailto:sscaffidi@cpan.org >>,
all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

