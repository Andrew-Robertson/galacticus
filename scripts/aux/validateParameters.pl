#!/usr/bin/env perl
my $galacticusPath;
if ( exists($ENV{"GALACTICUS_ROOT_V094"}) ) {
    $galacticusPath = $ENV{"GALACTICUS_ROOT_V094"};
    $galacticusPath .= "/" unless ( $galacticusPath =~ m/\/$/ );
} else {
    $galacticusPath = "./";
}
unshift(@INC, $galacticusPath."perl"); 
use strict;
use warnings;
use XML::SAX::ParserFactory;
use XML::Validator::Schema;
use XML::Simple;
use Scalar::Util 'reftype';
use Data::Dumper;
require List::ExtraUtils;

# Validate a Galacticus XML parameter file.
# Andrew Benson (1-December-2013)

# Get command line arguments.
die("Usage: validateParameters.pl <file>")
    unless ( scalar(@ARGV) == 1 );
my $file = $ARGV[0];
# Parse the file.
my $xml = new XML::Simple;
my $parameters = $xml->XMLin($file, KeyAttr => "");
# Determine the format.
my $format = 2; # Best guess if not other information.
if ( exists($parameters->{'formationVersion'}) ) {
    # Use the format declared in the file itself.
    $format = $parameters->{'formationVersion'};
} elsif ( exists($parameters->{'parameter'}) ) {
    # Does it look like format version 1?
    $format = 1;
}
# Assume valid by default.
my $valid = 0;
# Handle different file formats.
if ( $format == 1 ) {
    # Handle format version 1.
    # Validate the parameter file using XML schema.
    my $validator = XML::Validator::Schema->new(file => $galacticusPath.'schema/parameters.xsd');
    my $parser    = XML::SAX::ParserFactory->parser(Handler => $validator); 
    eval { $parser->parse_file($file) };
    die "Parameter file fails XML schema validation\n".$@
	if $@;
    # Check for duplicated entries.
    my %names;
    ++$names{$_->{'name'}}
        foreach ( &ExtraUtils::as_array($parameters->{'parameter'}) );
    foreach ( keys(%names) ) {
	if ( $names{$_} > 1 ) {
	    $valid = 1;
	    print "Parameter '".$_."' appears ".$names{$_}." times - should appear only once\n";
	}
    }
} elsif ( $format == 2 ) {
    # Handle format version 2.
    my $hasFormat;
    my $hasVersion;
    # Create a stack of elements to check.
    my @stack = map {{name => $_, node => $parameters->{$_}}} keys(%{$parameters});
    while ( scalar(@stack) > 0 ) {
	my $element = pop(@stack);
	if ( $element->{'name'} eq 'formatVersion' ) {
	    $hasFormat = 1;
	} elsif ( $element->{'name'} eq 'version' ) {
	    $hasVersion = 1;
	} elsif ( reftype($element->{'node'}) eq "ARRAY" ) {
	    $valid = 1;
	    print "Parameter '".$element->{'name'}."' appears ".scalar(@{$element->{'node'}})." times - should appear only once\n"; 
	} else {
	    unless ( exists($element->{'node'}->{'value'}) ) {
		$valid = 1;
		print "Parameter '".$element->{'name'}."' has no value\n";
	    }
	    push
		(
		 @stack,
		 map {$_ eq "value" || ! reftype($element->{'node'}->{$_}) ? () : {name => $element->{'name'}."->".$_, node => $element->{'node'}->{$_}}} keys(%{$element->{'node'}})
		);
	}
    }
}

exit $valid;
