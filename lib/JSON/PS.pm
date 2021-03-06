package JSON::PS;
use strict;
use warnings;
no warnings 'utf8';
use warnings FATAL => 'recursion';
our $VERSION = '4.0';
use B;
use Carp;

BEGIN {
  if (eval q{ use Web::Encoding (); 1 }) {
    *_du = \&Web::Encoding::decode_web_utf8;
    *_eu = \&Web::Encoding::encode_web_utf8;
  } else {
    require Encode;
    *_du = sub { return scalar Encode::decode ('utf-8', $_[0]) };
    *_eu = sub { return scalar Encode::encode ('utf-8', $_[0]) };
  }
}

our @EXPORT;

sub import ($;@) {
  my $from_class = shift;
  my ($to_class, $file, $line) = caller;
  no strict 'refs';
  for (@_ ? @_ : @{$from_class . '::EXPORT'}) {
    my $code = $from_class->can ($_)
        or croak qq{"$_" is not exported by the $from_class module at $file line $line};
    *{$to_class . '::' . $_} = $code;
  }
} # import

our $OnError ||= sub {
  warn sprintf "%s at index %d\n", $_[0]->{type}, $_[0]->{index} || 0;
}; # $OnError

my $_OnError = sub {
  if (ref $_[0] eq 'HASH') {
    $OnError->($_[0]);
  } else {
    $OnError->({type => $_[0]});
  }
}; # $_OnError

my $EscapeToChar = {
  '"' => q<">,
  '\\' => q<\\>,
  '/' => q</>,
  'b' => "\x08",
  'f' => "\x0C",
  'n' => "\x0A",
  'r' => "\x0D",
  't' => "\x09",
};

sub _decode_value ($);
sub _decode_value ($) {
  if ($_[0] =~ /\G"([\x20\x21\x23-\x5B\x5D-\x7E]*)"/gc) {
    return $1;
  } elsif ($_[0] =~ /\G(-?(?>[1-9][0-9]*|0)(?>\.[0-9]+)?(?>[eE][+-]?[0-9]+)?)/gc) {
    return 1*(0+$1);
  } elsif ($_[0] =~ /\G"/gc) {
    my @s;
    while (1) {
      if ($_[0] =~ /\G([^\x22\x5C\x00-\x1F]+)/gc) {
        push @s, $1;
      } elsif ($_[0] =~ m{\G\\(["\\/bfnrt])}gc) {
        push @s, $EscapeToChar->{$1};
      } elsif ($_[0] =~ /\G\\u([Dd][89ABab][0-9A-Fa-f]{2})\\u([Dd][C-Fc-f][0-9A-Fa-f]{2})/gc) {
        push @s, chr (0x10000 + ((hex ($1) - 0xD800) << 10) + (hex ($2) - 0xDC00));
      } elsif ($_[0] =~ /\G\\u([0-9A-Fa-f]{4})/gc) {
        push @s, chr hex $1;
      } elsif ($_[0] =~ /\G"/gc) {
        last;
      } else {
        die {index => pos $_[0], type => 'json:bad string'};
      }
    }
    return join '', @s;
  } elsif ($_[0] =~ m{\G\{}gc) {
    my $obj = {};
    $_[0] =~ /\G[\x09\x0A\x0D\x20]+/gc;
    if ($_[0] =~ /\G\}/gc) {
      #
    } else {
      OBJECT: {
        my $name;
        if ($_[0] =~ /\G"([\x20\x21\x23-\x5B\x5D-\x7E]*)"/gc) {
          $name = $1;
        } elsif ($_[0] =~ /\G(?=\")/gc) {
          $name = _decode_value $_[0];
        }
        if (defined $name) {
          $_[0] =~ /\G[\x09\x0A\x0D\x20]+/gc;
          if ($_[0] =~ /\G:/gc) {
            $_[0] =~ /\G[\x09\x0A\x0D\x20]+/gc;
            # XXX duplicate $name warning
            $obj->{$name} = _decode_value $_[0];
            $_[0] =~ /\G[\x09\x0A\x0D\x20]+/gc;
            if ($_[0] =~ /\G,/gc) {
              $_[0] =~ /\G[\x09\x0A\x0D\x20]+/gc;
              redo OBJECT;
            } elsif ($_[0] =~ /\G\}/gc) {
              last OBJECT;
            } else {
              die {index => pos $_[0], type => 'json:bad object sep'};
            }
          } else {
            die {index => pos $_[0], type => 'json:bad object nv sep'};
          }
        } else {
          die {index => pos $_[0], type => 'json:bad object name'};
        }
      } # OBJECT
    }
    return $obj;
  } elsif ($_[0] =~ m{\G\[}gc) {
    my @item;
    $_[0] =~ /\G[\x09\x0A\x0D\x20]+/gc;
    if ($_[0] =~ /\G\]/gc) {
      #
    } else {
      ARRAY: {
        push @item, _decode_value $_[0];
        $_[0] =~ /\G[\x09\x0A\x0D\x20]+/gc;
        if ($_[0] =~ /\G,/gc) {
          $_[0] =~ /\G[\x09\x0A\x0D\x20]+/gc;
          redo ARRAY;
        } elsif ($_[0] =~ /\G\]/gc) {
          last ARRAY;
        } else {
          die {index => pos $_[0], type => 'json:bad array sep'};
        }
      } # ARRAY
    }
    return \@item;
  } elsif ($_[0] =~ /\Gtrue/gc) {
    return 1;
  } elsif ($_[0] =~ /\Gfalse/gc) {
    return 0;
  } elsif ($_[0] =~ /\Gnull/gc) {
    return undef;
  } else {
    die {index => pos $_[0], type => 'json:bad value'};
  }
} # _decode_value

sub _decode ($) {
  return undef unless defined $_[0];
  pos ($_[0]) = 0;
  $_[0] =~ /\G[\x09\x0A\x0D\x20]+/gc;
  my $result = _decode_value $_[0];
  $_[0] =~ /\G[\x09\x0A\x0D\x20]+/gc;
  die {index => pos $_[0], type => 'json:eof expected'} if $_[0] =~ /\G./gcs;
  return $result;
} # _decode

push @EXPORT, qw(json_bytes2perl);
sub json_bytes2perl ($) {
  local $@;
  if (utf8::is_utf8 ($_[0])) { # backcompat
    my $value = scalar eval { _decode $_[0] };
    $_OnError->($@) if $@;
    return $value;
  } else {
    my $value = scalar eval { _decode _du $_[0] };
    $_OnError->($@) if $@;
    return $value;
  }
} # json_bytes2perl

push @EXPORT, qw(json_chars2perl);
sub json_chars2perl ($) {
  local $@;
  my $value = scalar eval { _decode $_[0] };
  $_OnError->($@) if $@;
  return $value;
} # json_chars2perl

my $StringNonSafe = qr/[\x00-\x1F\x22\x5C\x2B\x3C\x7F-\x9F\x{2028}\x{2029}\x{D800}-\x{DFFF}\x{FDD0}-\x{FDEF}\x{FFFE}-\x{FFFF}\x{1FFFE}-\x{1FFFF}\x{2FFFE}-\x{2FFFF}\x{3FFFE}-\x{3FFFF}\x{4FFFE}-\x{4FFFF}\x{5FFFE}-\x{5FFFF}\x{6FFFE}-\x{6FFFF}\x{7FFFE}-\x{7FFFF}\x{8FFFE}-\x{8FFFF}\x{9FFFE}-\x{9FFFF}\x{AFFFE}-\x{AFFFF}\x{BFFFE}-\x{BFFFF}\x{CFFFE}-\x{CFFFF}\x{DFFFE}-\x{DFFFF}\x{EFFFE}-\x{EFFFF}\x{FFFFE}-\x{FFFFF}\x{10FFFE}-\x{10FFFF}]/;

our $Symbols = {
  LBRACE => '{',
  RBRACE => '}',
  LBRACKET => '[',
  RBRACKET => ']',
  COLON => ':',
  COMMA => ',',
  indent => '',
  last => '',
  sort => 0,
};
my $PrettySymbols = {
  LBRACE => "{\x0A",
  RBRACE => '}',
  LBRACKET => "[\x0A",
  RBRACKET => ']',
  COLON => ' : ',
  COMMA => ",\x0A",
  indent => '   ',
  last => "\x0A",
  sort => 1,
};

sub _encode_value ($$);
sub _encode_value ($$) {
  if (defined $_[0]) {
    if (my $ref = ref $_[0]) {
      if (UNIVERSAL::can ($_[0], 'TO_JSON')) {
        return _encode_value $_[0]->TO_JSON, $_[1];
      }

      if ($ref eq 'ARRAY') {
        my $indent = $_[1].$Symbols->{indent};
        my @v = map { $indent, (_encode_value $_, $indent), $Symbols->{COMMA} } @{$_[0]};
        $v[-1] = $Symbols->{last} if @v;
        return $Symbols->{LBRACKET}, @v, $_[1], $Symbols->{RBRACKET};
      }

      if ($ref eq 'HASH') {
        my $indent = $_[1].$Symbols->{indent};
        my @key = keys %{$_[0]};
        @key = sort { $a cmp $b } @key if $Symbols->{sort};
        my @v = map {
          if ($_ =~ /$StringNonSafe/o) {
            my $v = $_;
            $v =~ s{($StringNonSafe)}{
              my $c = ord $1;
              if ($c >= 0x10000) {
                sprintf '\\u%04X\\u%04X',
                    (($c - 0x10000) >> 10) + 0xD800,
                    (($c - 0x10000) & 0x3FF) + 0xDC00;
              } else {
                sprintf '\\u%04X', $c;
              }
            }geo;
            $indent, '"', $v, '"', $Symbols->{COLON}, _encode_value ($_[0]->{$_}, $indent), $Symbols->{COMMA};
          } else {
            $indent, '"', $_, '"', $Symbols->{COLON}, _encode_value ($_[0]->{$_}, $indent), $Symbols->{COMMA};
          }
        } @key;
        $v[-1] = $Symbols->{last} if @v;
        return $Symbols->{LBRACE}, @v, $_[1], $Symbols->{RBRACE};
      }

      if ($ref eq 'SCALAR') {
        if (defined ${$_[0]} and not ref ${$_[0]}) {
          if (${$_[0]} eq '1') {
            return 'true';
          } elsif (${$_[0]} eq '0') {
            return 'false';
          }
        }
      } else {
        if (Types::Serialiser->can ('is_bool')) {
          if (Types::Serialiser::is_true ($_[0])) {
            return 'true';
          } elsif (Types::Serialiser::is_false ($_[0])) {
            return 'false';
          }
        }
      }
    } # $ref

    my $f = B::svref_2object (\($_[0]))->FLAGS;
    if ($f & (B::SVp_IOK | B::SVp_NOK) && $_[0] * 0 == 0) {
      my $n = 0 + $_[0];
      if ($n =~ /\A(-?(?>[1-9][0-9]*|0)(?>\.[0-9]+)?(?>[eE][+-]?[0-9]+)?)\z/) {
        return $n;
      }
    }

    if ($_[0] =~ /$StringNonSafe/o) {
      my $v = $_[0];
      $v =~ s{($StringNonSafe)}{
        my $c = ord $1;
        if ($c >= 0x10000) {
          sprintf '\\u%04X\\u%04X',
              (($c - 0x10000) >> 10) + 0xD800,
              (($c - 0x10000) & 0x3FF) + 0xDC00;
        } else {
          sprintf '\\u%04X', $c;
        }
      }geo;
      return '"', $v, '"';
    } else {
      return '"', $_[0], '"';
    }
  } else {
    return 'null';
  }
} # _encode_value

push @EXPORT, qw(perl2json_bytes);
sub perl2json_bytes ($) {
  return _eu join '', _encode_value $_[0], '';
} # perl2json_bytes

push @EXPORT, qw(perl2json_chars);
sub perl2json_chars ($) {
  return scalar join '', _encode_value $_[0], '';
} # perl2json_chars

push @EXPORT, qw(perl2json_bytes_for_record);
sub perl2json_bytes_for_record ($) {
  local $Symbols = $PrettySymbols;
  return _eu join '', _encode_value ($_[0], ''), "\x0A";
} # perl2json_bytes_for_record

push @EXPORT, qw(perl2json_chars_for_record);
sub perl2json_chars_for_record ($) {
  local $Symbols = $PrettySymbols;
  return scalar join '', _encode_value ($_[0], ''), "\x0A";
} # perl2json_chars_for_record

## Deprecated
#push @EXPORT_OK, qw(file2perl);
sub file2perl ($) {
  return json_chars2perl _du scalar $_[0]->slurp;
} # file2perl

1;

=head1 LICENSE

Copyright 2014-2019 Wakaba <wakaba@suikawiki.org>.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
