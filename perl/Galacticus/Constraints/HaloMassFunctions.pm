# Contains a Perl module which implements various useful functions for halo mass function constraints.

package Galacticus::Constraints::HaloMassFunctions;
use strict;
use warnings;
use lib $ENV{'GALACTICUS_EXEC_PATH'}."/perl";
use XML::Simple;
use Storable qw(dclone);
use Exporter 'import';
our @EXPORT_OK = qw(iterate selectSimulations matchSelection);

sub iterate {
    # Construct a list that can be iterated over to visit each simulation of interest.
    # The list can be truncated after any stage (simulation, group, etc.).
    # Various useful properties (e.g. Hubble parameter, particle mass, are automatically added to the data structure as needed).
    my $simulations    =   shift() ;
    my %options        = %{shift()};
    my (%optionsExtra) = @_
	if ( $#_ >= 1 );
    # Validate the 'stopAfter' option.
    $optionsExtra{'stopAfter'} = "realization"
	unless ( exists($optionsExtra{'stopAfter'}) );
    my @allowedStopAfter = ( 'suite', 'group', 'simulation', 'redshift', 'realization' );
    die('unrecognized "stopAfter" option - allowed choices are: '.join(", ",map {'"'.$_.'"'} @allowedStopAfter))
	unless ( grep {$_ eq $optionsExtra{'stopAfter'}} @allowedStopAfter );
    # Build the list of selections if we do not yet have it.
    @{$simulations->{'selections'}} = &selectSimulations(\%options)
	unless ( exists($simulations->{'selections'}) );
    # Construct the list.
    my @simulationList;
    # Iterate over suites.
    foreach my $suite ( &List::ExtraUtils::hashList($simulations->{'suite'}, keyAs => "name") ) {
	next
	    unless ( &matchSelection($simulations->{'selections'},$suite->{'name'}) );
	# Find the Hubble parameter for this suite.
	unless ( exists($suite->{'cosmology'}->{'HubbleParameter'}) ) {
	    my $xml = new XML::Simple();
	    my $cosmologyParameters = $xml->XMLin($options{'pipelinePath'}."cosmology_".$suite->{'name'}.".xml");
	    $suite->{'cosmology'}->{'HubbleParameter'} = $cosmologyParameters->{'cosmologyParameters'}->{'HubbleConstant'}->{'value'};
	}
	# Push to the list and move on if we are to stop after the "suite" stage.  
	if ( $optionsExtra{'stopAfter'} eq "suite" ) {
	    push(@simulationList,{suite => $suite});
	    next;
	}
 	# Iterate over groups in the suite.
	foreach my $group ( &List::ExtraUtils::hashList($suite->{'group'}, keyAs => "name") ) {
	    next
		unless ( &matchSelection($simulations->{'selections'},$suite->{'name'},$group->{'name'}) );
	    # Find the particle mass for this group.
	    unless ( exists($group->{'massParticle'}) ) {
		my $xml = new XML::Simple();
		my $simulationParameters = $xml->XMLin($options{'pipelinePath'}."simulation_".$suite->{'name'}."_".$group->{'name'}.".xml");
		my $massParticle         = $simulationParameters->{'simulation'}->{'massParticle'}->{'value'};
		# Handle any Hubble parameter scaling.
		if ( $massParticle =~ m/^=/ ) {
		    $massParticle =~ s/^=//;
		    $massParticle =~ s/\[cosmologyParameters::HubbleConstant\]/$suite->{'cosmology'}->{'HubbleParameter'}/;
		    $massParticle = eval($massParticle);
		}
		$group->{'massParticle'} = $massParticle;
	    }
	    # Push to the list and move on if we are to stop after the "group" stage.  	    
	    if ( $optionsExtra{'stopAfter'} eq "group" ) {
		push(@simulationList,{suite => $suite, group => $group});
		next;
	    }	    
	    # Iterate over simulations in the group.
	    foreach my $simulation ( &List::ExtraUtils::hashList($group->{'simulation'}, keyAs => "name") ) {
		next
		    unless ( &matchSelection($simulations->{'selections'},$suite->{'name'},$group->{'name'},$simulation->{'name'}) );
		# Push to the list and move on if we are to stop after the "simulation" stage.  	    
		if ( $optionsExtra{'stopAfter'} eq "simulation" ) {
		    push(@simulationList,{suite => $suite, group => $group, simulation => $simulation});
		    next;
		}		
		# Extract lists of redshifts and realizations.
		my @redshifts    =                                         split(" ",$simulation->{'redshifts'   }->{'value'})             ;
		my @realizations = exists($simulation->{'realizations'}) ? split(" ",$simulation->{'realizations'}->{'value'}) : ( "only" );
		# Iterate over redshifts in the simulation.
		foreach my $redshift ( @redshifts ) {
		    my $redshiftShort = sprintf("%5.3f",$redshift);
		    next
			unless ( &matchSelection($simulations->{'selections'},$suite->{'name'},$group->{'name'},$simulation->{'name'},$redshiftShort) );
		    # Push to the list and move on if we are to stop after the "redshift" stage.  	    
		    if ( $optionsExtra{'stopAfter'} eq "redshift" ) {
			push(@simulationList,{suite => $suite, group => $group, simulation => $simulation, redshift => $redshiftShort});
			next;
		    }
		    # Iterate over realizations in the simulation.
		    foreach my $realization ( @realizations ) {
			next
			    unless ( &matchSelection($simulations->{'selections'},$suite->{'name'},$group->{'name'},$simulation->{'name'},$redshiftShort,$realization) );
			# Begin constructing the complete entry that will be pushed to the list.
			my $entry = {suite => $suite, group => $group, simulation => $simulation, redshift => $redshiftShort, realization => $realization};
			# Set the target data file.
			$entry->{'fileTargetData'} = 
			    $ENV{'GALACTICUS_DATA_PATH'}             .
			    "/static/darkMatter/haloMassFunction_"   .
			        $entry->{'suite'      }->{'name'}."_".
			        $entry->{'group'      }->{'name'}."_".
			        $entry->{'simulation' }->{'name'}."_".
			        $entry->{'realization'}          ."_".
			    "z".$entry->{'redshift'   }              .
			    ".hdf5";
			# Extract data from the target data file.
			die("target data file '".$entry->{'fileTargetData'}."' does not exist")
			    unless ( -e $entry->{'fileTargetData'} );
			my $dataTarget       = new PDL::IO::HDF5($entry->{'fileTargetData'});
			my $simulationTarget = $dataTarget->group('simulation0001');
			# Extract properties of the primary halo from the target data file.
			($entry->{'massPrimary'}) = $simulationTarget->attrGet('massPrimary')
			    if ( $entry->{'suite'}->{'limitMassMaximum'}->{'value'} eq "primaryFraction" );
			# Extract properties of the environment, if needed.
			if ( $entry->{'suite'}->{'includeEnvironment'}->{'value'} eq "true" ) {
			    foreach my $attributeName ( 'massEnvironment', 'overdensityEnvironment' ) {
				die("Attribute '".$attributeName."' is missing in file ".$entry->{'fileTargetData'})
				    unless ( grep {$_ eq $attributeName} $simulationTarget->attrs() );
				($entry->{'environment'}->{$attributeName}) = $simulationTarget->attrGet($attributeName);
			    }
			}
			# Push to the list and move on if we are to stop after the "realization" stage.  	    
			if ( $optionsExtra{'stopAfter'} eq "realization" ) {
			    push(@simulationList,$entry);
			    next;
			}
		    }
		}
	    }
	}
    }
    # Return the iterable list that we have constructed.
    return @simulationList;
}

sub selectSimulations {
    # Construct a list of selected simulations.
    my %options = %{shift()};
    my @selections;
    foreach my $selection ( &List::ExtraUtils::as_array($options{'select'}) ) {
	# Split the selection into sub-selections.
	my @subselections = split(/:/,$selection);
	foreach my $subselection ( @subselections ) {
	    my @splitSelection = split(/,/,$subselection);
	    $subselection = \@splitSelection;
	}
	push(
	    @selections,
	    {
		suite       => $subselections[0],
		group       => $subselections[1],
		simulation  => $subselections[2],
		redshift    => $subselections[3],
		realization => $subselections[4],
	    }
	    );
    }
    return @selections;
}

sub matchSelection {
    # Test if the current simulation matches a selection.
    my @selections  = @{shift()};
    my $suite       =   shift() ;
    my $group       =   shift() ;
    my $simulation  =   shift() ;
    my $redshift    =   shift() ;
    my $realization =   shift() ;
    # If there are no selections, everything is a match.
    return 1
	if ( scalar(@selections) == 0 );
    foreach my $selection ( @selections ) {
	next unless ( ! defined($selection->{'suite'      }) || ! defined($suite      ) || grep {$_ eq $suite       || $_ eq "*"} @{$selection->{'suite'      }} );
	next unless ( ! defined($selection->{'group'      }) || ! defined($group      ) || grep {$_ eq $group       || $_ eq "*"} @{$selection->{'group'      }} );
	next unless ( ! defined($selection->{'simulation' }) || ! defined($simulation ) || grep {$_ eq $simulation  || $_ eq "*"} @{$selection->{'simulation' }} );
	next unless ( ! defined($selection->{'redshift'   }) || ! defined($redshift   ) || grep {$_ eq $redshift    || $_ eq "*"} @{$selection->{'redshift'   }} );
	next unless ( ! defined($selection->{'realization'}) || ! defined($realization) || grep {$_ eq $realization || $_ eq "*"} @{$selection->{'realization'}} );
	return 1;
    }
    return 0
}

1;
