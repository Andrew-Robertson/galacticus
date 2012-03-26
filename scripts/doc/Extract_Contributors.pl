#!/usr/bin/env perl
use lib './perl';
use strict;
use warnings;
use LaTeX::Encode;
use Data::Dumper;

# Scan Fortran90 source code and extract contributor data from "!+" lines.
# Andrew Benson 25-Mar-2012

# Get source directory
unless ($#ARGV == 1) {die 'Usage: Extract_Contributors.pl <sourceDir> <outputFile>'};
my $sourceDir  = $ARGV[0];
my $outputFile = $ARGV[1];

# Data structure for contributions.
my $contributions;

# Open the source directory.
opendir(dirHndl,$sourceDir);

# Read files from the source directory.
while ( my $fileName = readdir(dirHndl) ) {

    # Find Fortran 90 and C++ source files.
    if ( $fileName =~ m/\.F90$/ || $fileName =~ m/\.Inc$/ || $fileName =~ m/\.cpp$/ ) {

	# Open the file.
	open(fileHndl,$sourceDir."/".$fileName);

	# Scan the file.
	while ( my $line = <fileHndl> ) {

	    if ( $line =~ m/^\s*!\+\s*(.*)/ ) {
		# Capture the contributors.
		my $contributors = $1;
		# Strip any leading text.
		$contributors =~ s/^.*:\s*//;
		# Strip any trailing period.
		$contributors =~ s/\.\s*$//;
		# Split into contributors.
		my @people = split(/\s*,\s*/,$contributors);
		# Store file by contributor.
		foreach my $person ( @people ) {
		    $contributions->{$person}->{$fileName} = 1;
		}
	    }

	}

	# Close the file.
	close(fileHndl);

    }

}

# Close the source directory.
closedir(dirHndl);

# Generate LaTeX output.
open(oHndl,">".$outputFile);
print oHndl "\\chapter{Contributions}\n\n";
print oHndl "Contributions to the \\glc\\ project have been made by the following people:\n\n";
print oHndl "\\begin{description}\n";
my @sortedNames = sort(keys(%{$contributions}));
foreach my $person ( @sortedNames ) {

    # Accents.
    my $name = $person;
    $name =~ s/Ç/\\c{C}/g;
    $name =~ s/ü/\\"u/g;
    $name =~ s/é/\\'e/g;
    $name =~ s/â/\\^a/g;
    $name =~ s/ä/\\"a/g;
    $name =~ s/à/\\`a/g;
    $name =~ s/ç/\\c{c}/g;
    $name =~ s/ê/\\^e/g;
    $name =~ s/ë/\\"e/g;
    $name =~ s/è/\\`e/g;
    $name =~ s/ï/\\"i/g;
    $name =~ s/î/\\^i/g;
    $name =~ s/ì/\\`i/g;
    $name =~ s/Ä/\\"A/g;
    $name =~ s/Å/\\AA/g;
    $name =~ s/É/\\'E/g;
    $name =~ s/ô/\\^o/g;
    $name =~ s/ö/\\"o/g;
    $name =~ s/ò/\\`o/g;
    $name =~ s/û/\\^u/g;
    $name =~ s/ù/\\`u/g;
    $name =~ s/ÿ/\\"y/g;
    $name =~ s/Ö/\\"O/g;
    $name =~ s/Ü/\\"U/g;
    $name =~ s/á/\\'a/g;
    $name =~ s/í/\\'i/g;
    $name =~ s/ó/\\'o/g;
    $name =~ s/ú/\\'u/g;
    $name =~ s/ñ/\\~n/g;
    $name =~ s/Ñ/\\~N/g;

    # Output this person.
    print oHndl "\\item[".$name."] \\hfill\n";
    print oHndl "\\begin{itemize}\n";
    foreach my $fileName ( sort(keys(%{$contributions->{$person}})) ) {
	print oHndl "\\item \\hyperlink{".$fileName."}{\\tt ".latex_encode($fileName)."}\n";
    }
    print oHndl "\\end{itemize}\n";
}
print oHndl "\\end{description}\n";
close(oHndl);

exit;
