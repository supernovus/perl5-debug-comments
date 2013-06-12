=head1

Debug::Comments - Enable magic debugging comments

=head1 DESCRIPTION

Inspired by Smart::Comments, this module enables you to write special
comments that when this source filter is loaded, become special debugging
statements.

This is the third incarnation, now a standalone project, the previous versions 
having been been included in old library sets that I've since discontinued.

=head1 USAGE

  use Debug::Comments env => 'MYDEUG'; ## Look for settings in $ENV{'MYDEBUG'}

  OR

  use Debug::Comments show => ['tag1', {tag=>'tag2',trace=>2}];
  ##[tag1,tag2,tag3] message to show   ## Simple messages only.
  ##[tag2,tag3]= $dump_this_object     ## $scalars, @arrays, %hashes only.
  ##[tag3]~ run_this_code();           ## Only enabled if exec => 1

Note: a single comment will only ever be shown once, so whichever tag is
specified first in the show statement will be executed on it.

=head1 OPTIONS

When calling this module, the I<use> statement can take a few options.

  show => $arrayref         A list of the tags you want to be shown.
                            If a tag is a string, that is the name of the tag.
                            If a tag is a hash ref, it means there are special
                            options available for that tag:
                              tag    => $tagname     The name of the tag.
                              trace  => $levels      Do a backtrace.
                              output => $file        Output logged to $file.
                              format => $format      Output format for tag.

  output => $filename       Set to a filename to output to. 
                            If unset, output will be sent to STDERR. 
                            This can be overriden on a per-tag basis.

  format => $format         Set the output format. Can be one of:
                              'yaml'          Use YAML::XS
                              'json'          Use JSON
                              'data'          Use Data::Dumper
                            If not set, it defaults to 'data'.
                            This can be overriden on a per-tag basis.

  settings => $string       Get settings from elsewhere. The string can be
                            either a filename, pointing to a JSON file, or
                            a JSON string representing an object (aka Hash.)
                            If this option is found, the settings in the JSON
                            will override those in the use statement.
                            Only the 'show', 'output' and 'format' settings 
                            will be recognized in the JSON object.

  env => $string            Another way to specify the settings, if the
                            environment variale described by $string is found,
                            we enable debugging comments, and use the value of
                            the environment variable as the 'settings' string,
                            which as described above, can either be a file path
                            or a JSON string representing an object.

  exec => 1                 If enabled, ##[tag]~ comments will be parsed.
                            This can only be enabled in the use statement.

=cut

package Debug::Comments;
# ABSTRACT: Enables the use of magic comments for debugging purposes.

use v5.10;
use strict;
use warnings;

use version 0.77;
our $VERSION =  'v3.0.0';

use Filter::Simple;

## Function: getarg
## Look for a parameter in a hash reference.
## Can handle default values, or required parameters.
sub getarg {
  my ($opts, $name, $default) = @_;
  if (exists $opts->{$name} && defined $opts->{$name}) {
    return $opts->{$name};
  }
  else {
    return $default;
  }
}

## Function: slurp
## Loads the contents of a file into a string.
sub slurp {
  my $filename = shift;
  ## Dark magick, based on some crazy Perlmongers voodoo.
  my $text = do { local( @ARGV, $/ ) = $filename ; <> } ;
  return $text;
}

## Function: savefile
## Save a string or array to a file.
## Supports appending by passing { append => 1 } as the second argument.
sub savefile {
  my $filename = shift;
  my $args = ( ref $_[0] eq 'HASH' ) ? shift : {} ;
  my $mode = '>';
  if ($args->{append}) { $mode = '>>'; }
  
  open (my $file, $mode, $filename);
  print $file @_;
  close($file);
}

## The source filter definition.
FILTER {
  my ($package, %opts) = @_;
  my $hws = qr/[^\S\n]/;

  ## Check for environment settings.
  if (exists $opts{env} && $opts{env}) {
    my $envname = $opts{env};
    if (exists $ENV{$envname} && $ENV{$envname}) {
      $opts{settings} = $ENV{$envname};
    }
    else {
      return;
    }
  }

  ## Check for JSON settings.
  if (exists $opts{settings}) {
    require JSON;
    my $settings = $opts{settings};
    my $defs;
    if ($settings =~ /^\{/) {
      $defs = decode_json($settings);
    }
    else {
      my $jsonfile = slurp($settings);
      $defs = decode_json($settings);
    }
    if ($defs && ref $defs eq 'HASH') {
      if ($defs->{show}) { 
        $opts{show} = $defs->{show}; 
      }
      if ($defs->{output}) {
        $opts{output} = $defs->{output};
      }
    }
  }

  ## Okay, now let's get the rest.
  my $show = getarg(\%opts,   'show');
  my $output = getarg(\%opts, 'output');
  my $format = getarg(\%opts, 'format');
  my $exec = getarg(\%opts,   'exec', 0);

  return if !$show; ## We can't continue if there's nothing to show.

  my $src = $_; ## Assign the topic to a variable.

  my $showtype = ref $show;
  if (!$showtype || $showtype ne 'ARRAY') {
    $show = [$show]; ## Wrap the non-Array $show in an array.
  }

  for my $show (@{$show}) {
    my $log = $output;
    my $fmt = $format;
    my $trace = 0;
    my $tag;
    if (ref $show eq 'HASH') {
      ## The "tag" setting is the only required one.
      $tag = $show->{tag};
      if (exists $show->{output}) {
        $log = $show->{output};
      }
      if (exists $show->{trace}) {
        $trace = $show->{trace};
      }
    }
    else {
      $tag = $show;
    }

    ## Let's build a search query.
    my $search = qr/$hws*\#\#\[.*?$tag.*?\]/;

    ## Find variable dump statements.
    $src =~ s{ ^ $search = $hws* (.*?) $ }
    {
      _create_callback
      (
        log    => $log,
        format => $fmt,
        trace  => $trace,
        dump   => $1,
      );
    }xgem;

    ## Next, if exec is enabled, find code blocks.
    if ($exec) { 
      $src =~ s{ ^ $search ~ $hws* (.*?) $ } { $1 }xgem;
    }
    else {
      $src =~ s{ ^ $search ~ $hws* .*? $ } {''}xgem;
    }

    ## Finally, look for message blocks.
    $src =~ s{ ^ $search $hws* (.*?) $ }
    {
      _create_callback
      (
        log    => $log,
        format => $fmt,
        trace  => $trace,
        msg    => $1,
      );
    }xgem;
  }

  $_ = $src; ## Reset the topic again.

};

## Private method: _create_callback()
## Generates calls to debug_msg(), debug_dump() and debug_trace().
sub _create_callback {
  my $callstring;
  my (%opts) = @_;
  my $log    = getarg(\%opts, 'log',     '');
  my $trace  = getarg(\%opts, 'trace',   0);
  my $format = getarg(\%opts, 'format',  '');

  if (exists $opts{dump}) {
    my $callopts = '';
    my @objects = split(/[\s,]+/, $opts{dump});
    for my $obj (@objects) {
      my $name = $obj;
      if ($obj =~ /^(\w+)[:=]/) {
        $name = $1;
        $obj =~ s/^$name[:=]//g;
      }
      if ($obj =~ /^[@%]/) {
        $obj = '\\'.$obj;
      }
      $callopts .= "'$name' => $obj, ";
    }
    $callstring = 
      "Debug::Comments::debug_dump(\"$log\", \"$format\", $callopts);";
  }
  elsif (exists $opts{msg}) {
    $callstring = 
      "Debug::Comments::debug_msg(\"$log\", \"".$opts{msg}."\");";
  }

  ## Add Trace if it is defined.
  if ($trace) {
    $callstring .= 
      "Debug::Comments::debug_trace(\"$log\", $trace, \"$format\");";
  }
  return $callstring;
}

## Protected method: debug_msg($log, $message)
## Outputs the message to the specified log file.
## If the log file is undefined, outputs to STDERR.
sub debug_msg {
  my ($log, $message) = @_;
  if ($log) {
    savefile($log, {append=>1}, $message);
  }
  else {
    say STDERR $message;
  }
  return 1;
}

## Protected method: debug_dump($log, ...)
## Sends its named parameters to either YAML::XS or Data::Dumper,
## then sends the string to debug_msg();
sub debug_dump {
  my ($log, $format, %data) = @_;

  $format = lc($format);

  my $output;

  if ($format eq 'yaml' && eval("require YAML::XS")) {
    $output = YAML::XS::Dump(\%data);
  }
  elsif ($format eq 'json' && eval("require JSON")) {
    $output = JSON->new->utf8->pretty->encode(\%data);
  }
  else {
    require Data::Dumper;
    my $dump = Data::Dumper->new([\%data]);
    $dump->Terse(1);
    $dump->Indent(2);
    $output = $dump->Dump;
  }

  return debug_msg($log, $output);
}

## Protected method: debug_trace($log, $levels)
## Does a backtrace, a certain number of callers back.
## Sends the trace object to debug_dump().
sub debug_trace {
  my ($log, $trace, $format) = @_;
  my @trace;
  for (my $i=0; $i<$trace; $i++) {
    my @class = caller($i);
    if (!@class) { last; } ## end if nothing to trace.
    my @function = caller($i+1);
    my %defs;
    $defs{package} = $class[0];
    $defs{filename} = $class[1];
    $defs{line} = $class[2];
    if (@function) {
      my $sub = $function[3];
      if ($sub) {
        $defs{sub} = $sub;
        $defs{sub} =~ s/.*://g;
      }
    }
    push @trace, \%defs;
  }
  return debug_dump($log, $format, TRACE => \@trace);
}

=head1 DEPENDENCIES

=over 1

=item *

Perl 5.10 or higher

=item *

Filter::Simple (core module)

=item *

JSON (if using settings)

=item *

YAML::XS (recommended)

=item *

Data::Dumper (core module)

=back

=head1 BUGS AND LIMITATIONS

It's a source filter, be careful with it!

=head1 AUTHOR

Timothy Totten <2009@huri.net>

=head1 LICENSE

Artistic License 2.0

=cut

## End of package
1;