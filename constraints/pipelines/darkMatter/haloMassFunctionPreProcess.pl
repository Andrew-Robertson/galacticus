#!/usr/bin/env perl
use strict;
use warnings;
use lib $ENV{'GALACTICUS_EXEC_PATH'}."/perl";
use XML::Simple;
use File::Copy;
use Data::Dumper;
use PDL;
use PDL::NiceSlice;
use PDL::IO::Misc;
use PDL::IO::HDF5;
use PDL::Constants qw(PI);
use Galacticus::Options;
use Galacticus::Launch::Hooks;
use Galacticus::Launch::PBS;
use Galacticus::Launch::Slurm;
use Galacticus::Launch::Local;
use Galacticus::Constraints::Parameters;
use Galacticus::Constraints::HaloMassFunctions qw(iterate);

# Construct halo mass function data from a variety of cosmological N-body simulations.
# Andrew Benson (14-October-2020)

# Get command line options.
my %options =
    (
     submitSleepDuration =>  5,
     waitSleepDuration   => 30,
     pbsJobMaximum       => 64,
     slurmJobMaximum     => 64,
     ompThreads          => "max"
    );
&Galacticus::Options::Parse_Options(\@ARGV,\%options);

# Validate required parameters are present.
foreach ( "simulationDataPath", "pipelinePath" ) {
    die('"'.$_.'" is required but is not present')
	unless ( exists($options{$_}) );
}

# Ensure paths are correctly suffixed.
foreach my $path ( 'simulationDataPath', 'pipelinePath' ) {
    $options{$path} .= "/"
	unless ( $options{$path} =~ m/\/$/ );
}

# Establish a set of processor functions for handling the analysis of individual simulation suites.
my %processors =
    (
     Symphony =>
     {
     	 processIdentify         =>  \&symphonyProcessIdentify                ,
     	 preprocessExtract       => [
     	                             \&symphonyPreProcessExtractLocate,
     	                             \&symphonyPreProcessExtractUncontaminated,
     	                            ]                                         ,
     	 processExtract          =>  \&symphonyProcessExtract                 ,
     	 postprocessExtract      =>
     	                            [
     	                             \&symphonyPostprocessSelectInSphere      ,
     	                             \&symphonyPostprocessExtractSelectedIDs  ,
     	                             \&symphonyPostprocessSelectInICs         ,
     	                             \&symphonyPostprocessAnalyze             ,
     	                             \&symphonyPostprocessSetVolume
     	                            ]                                         ,
     	 postprocessMassFunction =>
     	                            [
     	                             \&symphonyPostProcessMassFunction
     	                            ]	 
     }
    );

# Parse config options.
my $queueManager = &Galacticus::Options::Config(                'queueManager' );
my $queueConfig  = &Galacticus::Options::Config($queueManager->{'manager'     });

# Determine number of OpenMP threads to use.
my $ompThreads = $options{'ompThreads'} eq "max" ? $queueConfig->{'ppn'} : $options{'ompThreads'};

# Parse the simulations definition file.
my $xml = new XML::Simple();
my $simulations = $xml->XMLin(
    $options{'pipelinePath'}."haloMassFunctionSimulations.xml",
    ForceArray => [ "suite"         , "group"         , "simulation"          ],
    KeyAttr    => {  suite => "name",  group => "name",  simulation => "name" }
    );

# Get the list of entries to process.
my @entries = &iterate($simulations,\%options, stopAfter => "realization");

# Iterate over simulations to identify always-isolated halos.
{
    my @jobsIdentify;
    foreach my $entry ( @entries ) {
	# Build redshift labels.
	@{$entry->{'group'}->{'epochs'}} = map {my $redshift = 1.0/$_-1.0; {expansionFactor => $_, redshift => $redshift, redshiftLabel => sprintf("z%5.3f",$redshift)}} @{$entry->{'group'}->{'expansionFactors'}};
	# Determine minimum and maximum masses for the mass function.
	$entry->{'massMinimum'} = 10.0**(int(log($entry->{'group'}->{'massParticle'})/log(10.0))+2);
	$entry->{'massMaximum'} = 1.0e16;
	# Construct the simulation path.
	$entry->{'path'} = $options{'simulationDataPath'}.$entry->{'suite'}->{'name'}."/".$entry->{'group'}->{'name'}."/".$entry->{'simulation'}->{'name'}."/".$entry->{'realization'}."/";
	# Iterate over subvolumes.
	for(my $i=0;$i<$entry->{'group'}->{'subvolumes'};++$i) {
	    for(my $j=0;$j<$entry->{'group'}->{'subvolumes'};++$j) {
		for(my $k=0;$k<$entry->{'group'}->{'subvolumes'};++$k) {
		    # Parse the base parameters.
		    my $parameters = $xml->XMLin($options{'pipelinePath'}."haloMassFunctionIdentifyAlwaysIsolated.xml");
		    # Modify file names.
		    $parameters->{'nbodyImporter'}                        ->{'fileName'}->{'value'} = $entry->{'path'}."tree_"                   .$i."_".$j."_".$k.".dat" ;
		    $parameters->{'nbodyOperator'}->{'nbodyOperator'}->[3]->{'fileName'}->{'value'} = $entry->{'path'}."alwaysIsolated_subVolume".$i."_".$j."_".$k.".hdf5";
		    # Modify cosmological parameters.
		    $parameters->{'cosmologyParameters'}->{$_}->{'value'} = $entry->{'suite'}->{'cosmology'}->{$_}
		        foreach ( 'HubbleConstant', 'OmegaMatter', 'OmegaDarkEnergy', 'OmegaBaryon' );
		    # If a custom process function is defined, call it.
		    &{$processors{$entry->{'suite'}->{'name'}}->{'processIdentify'}}($entry,$parameters,\%options)
			if ( exists($processors{$entry->{'suite'}->{'name'}}->{'processIdentify'}) );
		    # Write parmeter file.
		    my $parameterFileName = $entry->{'path'}."identifyAlwaysIsolated_".$i."_".$j."_".$k.".xml";
		    open(my $outputFile,">",$parameterFileName);
		    print $outputFile $xml->XMLout($parameters, RootName => "parameters");
		    close($outputFile);
		    # Skip if the file exists.
		    next
			if ( -e $entry->{'path'}."alwaysIsolated_subVolume".$i."_".$j."_".$k.".hdf5" );
		    # Generate a job.
		    my $job;
		    $job->{'command'   } =
			$ENV{'GALACTICUS_EXEC_PATH'}."/Galacticus.exe ".$parameterFileName;
		    $job->{'launchFile'} = $entry->{'path'}."identifyAlwaysIsolated_".$i."_".$j."_".$k.".sh" ;
		    $job->{'logFile'   } = $entry->{'path'}."identifyAlwaysIsolated_".$i."_".$j."_".$k.".log";
		    $job->{'label'     } =                  "identifyAlwaysIsolated_".$i."_".$j."_".$k       ;
		    $job->{'ppn'       } = $ompThreads;
		    $job->{'ompThreads'} = $ompThreads;
		    $job->{'nodes'     } = 1 ;
		    $job->{'mem'       } = "8G";
		    $job->{'walltime'  } = "8:00:00";
		    $job->{'mpi'       } = "no";
		    push(@jobsIdentify,$job);
		}
	    }
	}
    }

    print scalar(@jobsIdentify)."\n";

    &{$Galacticus::Launch::Hooks::moduleHooks{$queueManager->{'manager'}}->{'jobArrayLaunch'}}(\%options,@jobsIdentify)
	if ( scalar(@jobsIdentify) > 0 );
}

# Perform any preprocessing.
{
    my $workDone  =  1;
    my $iteration = -1;
    while ( $workDone ) {
	my @preprocessingJobs;
	++$iteration;
	$workDone = 0;
	foreach my $entry ( @entries ) {
	    # If a custom preprocess function is defined, call it.
	    if ( exists($processors{$entry->{'suite'}->{'name'}}->{'preprocessExtract'}) && scalar(@{$processors{$entry->{'suite'}->{'name'}}->{'preprocessExtract'}}) > $iteration ) {
		$workDone = 1;
		&{$processors{$entry->{'suite'}->{'name'}}->{'preprocessExtract'}->[$iteration]}($entry,\@preprocessingJobs,\%options);
	    }
	}
	&{$Galacticus::Launch::Hooks::moduleHooks{$queueManager->{'manager'}}->{'jobArrayLaunch'}}(\%options,@preprocessingJobs)
	    if ( scalar(@preprocessingJobs) > 0 );
    }
}

# Iterate over simulations to extract snapshots
{
    my @jobsExtract;
    foreach my $entry ( @entries ) {
	# Iterate over subvolumes.
	for(my $i=0;$i<$entry->{'group'}->{'subvolumes'};++$i) {
	    for(my $j=0;$j<$entry->{'group'}->{'subvolumes'};++$j) {
		for(my $k=0;$k<$entry->{'group'}->{'subvolumes'};++$k) {
		    # Iterate over expansion factors.
		    foreach my $epoch ( @{$entry->{'group'}->{'epochs'}} ) {
			my $expansionFactorLow  = (1.0-5.0e-4)*$epoch->{'expansionFactor'};
			my $expansionFactorHigh = (1.0+5.0e-4)*$epoch->{'expansionFactor'};
			# Parse the base parameters.
			my $parameters = $xml->XMLin($options{'pipelinePath'}."haloMassFunctionExtractSnapshot.xml");
			# Modify file names.
			$parameters->{'nbodyImporter'}                        ->{'fileName'     }->{'value'} = $entry->{'path'}."alwaysIsolated_subVolume"                        .$i."_".$j."_".$k.".hdf5";
			$parameters->{'nbodyImporter'}                        ->{'properties'   }->{'value'} = "particleID isFlyby expansionFactor massVirial";
			$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[0]->{'propertyNames'}->{'value'} = "isFlyby expansionFactor";
			$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[0]->{'rangeLow'     }->{'value'} = "0 ".$expansionFactorLow ;
			$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[0]->{'rangeHigh'    }->{'value'} = "0 ".$expansionFactorHigh;
			$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[1]->{'propertyNames'}->{'value'} = "isFlyby expansionFactor";
			$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[2]->{'fileName'     }->{'value'} = $entry->{'path'}."nonFlyby_".$epoch->{'redshiftLabel'}."_subVolume".$i."_".$j."_".$k.".hdf5";
			$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[2]->{'redshift'     }->{'value'} =                              $epoch->{'redshift'     }                                      ;
			# If a custom process function is defined, call it.
			&{$processors{$entry->{'suite'}->{'name'}}->{'processExtract'}}($entry,$parameters,$epoch->{'expansionFactor'},\%options)
			    if ( exists($processors{$entry->{'suite'}->{'name'}}->{'processExtract'}) );
			# Write parameter file.
			my $parameterFileName = $entry->{'path'}."identifyNonFlyby_".$epoch->{'redshiftLabel'}."_".$i."_".$j."_".$k.".xml";
			open(my $outputFile,">",$parameterFileName);
			print $outputFile $xml->XMLout($parameters, RootName => "parameters");
			close($outputFile);
			# Skip if the file exists.
			next
			    if ( -e $entry->{'path'}."nonFlyby_".$epoch->{'redshiftLabel'}."_subVolume".$i."_".$j."_".$k.".hdf5" );
			# Generate a job.
			my $job;
			$job->{'command'   } =
			    $ENV{'GALACTICUS_EXEC_PATH'}."/Galacticus.exe ".$parameterFileName;
			$job->{'launchFile'} = $entry->{'path'}."identifyNonFlyby_".$epoch->{'redshiftLabel'}."_".$i."_".$j."_".$k.".sh" ;
			$job->{'logFile'   } = $entry->{'path'}."identifyNonFlyby_".$epoch->{'redshiftLabel'}."_".$i."_".$j."_".$k.".log";
			$job->{'label'     } =                  "identifyNonFlyby_".$epoch->{'redshiftLabel'}."_".$i."_".$j."_".$k       ;
			$job->{'ppn'       } = 1;
			$job->{'ompThreads'} = 1;
			$job->{'nodes'     } = 1;
			$job->{'mem'       } = "8G";
			$job->{'walltime'  } = "8:00:00";
			$job->{'mpi'       } = "yes";
			push(@jobsExtract,$job);
		    }
		}
	    }
	}
    }
    &{$Galacticus::Launch::Hooks::moduleHooks{$queueManager->{'manager'}}->{'jobArrayLaunch'}}(\%options,@jobsExtract)
	if ( scalar(@jobsExtract) > 0 );
}

# Perform any postprocessing.
{
    my $workDone  =  1;
    my $iteration = -1;
    while ( $workDone ) {
	my @postprocessingJobs;
	++$iteration;
	$workDone = 0;
	foreach my $entry ( @entries ) {
	    # If a custom postprocess function is defined, call it.
	    if ( exists($processors{$entry->{'suite'}->{'name'}}->{'postprocessExtract'}) && scalar(@{$processors{$entry->{'suite'}->{'name'}}->{'postprocessExtract'}}) > $iteration ) {
		$workDone = 1;
		&{$processors{$entry->{'suite'}->{'name'}}->{'postprocessExtract'}->[$iteration]}($entry,\@postprocessingJobs,\%options);
	    }
	}
	&{$Galacticus::Launch::Hooks::moduleHooks{$queueManager->{'manager'}}->{'jobArrayLaunch'}}(\%options,@postprocessingJobs)
	    if ( scalar(@postprocessingJobs) > 0 );
    }
}

# Iterate over simulations to construct the mass functions.
{
    my @massFunctionJobs;
    foreach my $entry ( @entries ) {
	# Iterate over expansion factors.
	foreach my $epoch ( @{$entry->{'group'}->{'epochs'}} ) {
	    # Iterate over subvolumes.
	    my @nbodyImporters;
	    for(my $i=0;$i<$entry->{'group'}->{'subvolumes'};++$i) {
		for(my $j=0;$j<$entry->{'group'}->{'subvolumes'};++$j) {
		    for(my $k=0;$k<$entry->{'group'}->{'subvolumes'};++$k) {
			# Add an importer for this subvolume.
			push(
			    @nbodyImporters,
			    {
				value      => "IRATE"                                                                                ,
				fileName   => {value => $entry->{'path'}."nonFlyby_".$epoch->{'redshiftLabel'}."_subVolume".$i."_".$j."_".$k.".hdf5"},
				snapshot   => {value => "1"},
				properties => {value => "massVirial"}
			    }
			    );
		    }
		}
		# Compute the mass function.
		unless ( -e $entry->{'path'}."haloMassFunction_nonFlyby_".$epoch->{'redshiftLabel'}.":MPI0000.hdf5" ) {
		    # Parse the base parameters.
		    my $massFunctionParameters = $xml->XMLin($options{'pipelinePath'}."haloMassFunctionCompute.xml");
		    # Modify parameters.
		    @{$massFunctionParameters->{'nbodyImporter' }->{'nbodyImporter'}}                                          = @nbodyImporters;
		    $massFunctionParameters  ->{'outputFileName'}                                                  ->{'value'} = $entry->{'path'       }."haloMassFunction_nonFlyby_".$epoch->{'redshiftLabel'}.".hdf5";
		    $massFunctionParameters  ->{'nbodyOperator' }->{'nbodyOperator'} ->[0]->{'values'             }->{'value'} = $entry->{'group'      }->{'massParticle'};
		    $massFunctionParameters  ->{'nbodyOperator' }->{'nbodyOperator'} ->[1]->{'simulationReference'}->{'value'} = $entry->{'group'      }->{'reference'   };
		    $massFunctionParameters  ->{'nbodyOperator' }->{'nbodyOperator'} ->[1]->{'simulationURL'      }->{'value'} = $entry->{'group'      }->{'url'         };
		    $massFunctionParameters  ->{'nbodyOperator' }->{'nbodyOperator'} ->[1]->{'massMinimum'        }->{'value'} = $entry->{'massMinimum'}                  ;
		    $massFunctionParameters  ->{'nbodyOperator' }->{'nbodyOperator'} ->[1]->{'massMaximum'        }->{'value'} = $entry->{'massMaximum'}                  ;
		    $massFunctionParameters  ->{'nbodyOperator' }->{'nbodyOperator'} ->[1]->{'description'        }->{'value'} = "Halo mass function of non-flyby halos for the ".$entry->{'suite'}->{'name'}." ".$entry->{'group'}->{'name'}." ".$entry->{'simulation'}->{'name'}." ".$epoch->{'redshiftLabel'}." simulation";
		    # Write the parameter file.
		    my $parameterFileName = $entry->{'path'}."haloMassFunction_nonFlyby_".$epoch->{'redshiftLabel'}.".xml";
		    open(my $outputFile,">",$parameterFileName);
		    print $outputFile $xml->XMLout($massFunctionParameters, RootName => "parameters");
		    close($outputFile);
		    # Construct the job.
		    my $job;
		    $job->{'command'   } =
			$ENV{'GALACTICUS_EXEC_PATH'}."/Galacticus.exe ".$parameterFileName;
		    $job->{'launchFile'} = $entry->{'path'}."haloMassFunction_nonFlyby_".$epoch->{'redshiftLabel'}.".sh" ;
		    $job->{'logFile'   } = $entry->{'path'}."haloMassFunction_nonFlyby_".$epoch->{'redshiftLabel'}.".log";
		    $job->{'label'     } =                  "haloMassFunction_nonFlyby_".$epoch->{'redshiftLabel'}       ;
		    $job->{'ppn'       } = $ompThreads;
		    $job->{'ompThreads'} = $ompThreads;
		    $job->{'nodes'     } = 1;
		    $job->{'mem'       } = "8G";
		    $job->{'walltime'  } = "8:00:00";
		    $job->{'mpi'       } = "no";
		    push(@massFunctionJobs,$job);
		}
	    }
	}
    }
    &{$Galacticus::Launch::Hooks::moduleHooks{$queueManager->{'manager'}}->{'jobArrayLaunch'}}(\%options,@massFunctionJobs)
	if ( scalar(@massFunctionJobs) > 0 );
}

# Perform any postprocessing.
{
    my $workDone  =  1;
    my $iteration = -1;
    while ( $workDone ) {
	my @postprocessingJobs;
	++$iteration;
	$workDone = 0;
	foreach my $entry ( @entries ) {
	    # If a custom postprocess function is defined, call it.
	    if ( exists($processors{$entry->{'suite'}->{'name'}}->{'postprocessMassFunction'}) && scalar(@{$processors{$entry->{'suite'}->{'name'}}->{'postprocessMassFunction'}}) > $iteration ) {
		$workDone = 1;
		&{$processors{$entry->{'suite'}->{'name'}}->{'postprocessMassFunction'}->[$iteration]}($entry,\@postprocessingJobs,\%options);
	    }
	}
	&{$Galacticus::Launch::Hooks::moduleHooks{$queueManager->{'manager'}}->{'jobArrayLaunch'}}(\%options,@postprocessingJobs)
	    if ( scalar(@postprocessingJobs) > 0 );
    }
}

# Move the resulting mass functions.
foreach my $entry ( @entries ) {
    # Iterate over expansion factors.
    foreach my $epoch ( @{$entry->{'group'}->{'epochs'}} ) {
	copy($entry->{'path'}."haloMassFunction_nonFlyby_".$epoch->{'redshiftLabel'}.":MPI0000.hdf5",$ENV{'GALACTICUS_DATA_PATH'}."/static/darkMatter/haloMassFunction_".$entry->{'suite'}->{'name'}."_".$entry->{'group'}->{'name'}."_".$entry->{'simulation'}->{'name'}."_".$entry->{'realization'}."_".$epoch->{'redshiftLabel'}.".hdf5");
    }
}

exit 0;

sub symphonyProcessIdentify {
    # Set the appropriate cosmology.
    my $entry      =   shift();
    my $parameters =   shift();
    my %options    = %{shift()};
    # Find the host halo IDs for this simulation.
    my $xml         = new XML::Simple();
    my $hostHaloIDs = $xml->XMLin($options{'pipelinePath'}."symphonyZoomInHostHaloIDs.xml");
    (my $identifier  = $entry->{'group'}->{'name'}."_".$entry->{'simulation'}->{'name'}) =~ s/:/_/g;
    @{$entry->{'hostHaloIDs'}} = map {$hostHaloIDs->{$identifier}->{$_}} @{$entry->{'simulation'}->{'realizationsList'}};
    # Add read of additional columns.
    my @propertiesImport = split(" ",$parameters->{'nbodyImporter'}->{'readColumns'}->{'value'});
    foreach my $property ( "X", "Y", "Z", "Rvir", "rs" ) {
	$parameters->{'nbodyImporter'}->{'readColumns'}->{'value'} .= " ".$property
	    unless ( grep {$_ eq $property} @propertiesImport );
    }
    # Remove any delete of these properties.
    my @propertiesDeleted = split(" ",$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[2]->{'propertyNames'}->{'value'});
    my @propertiesToDelete;
    foreach my $property ( @propertiesDeleted ) {
	push(@propertiesToDelete,$property)
	    unless
	    (
	     $property eq "position"
	     ||
	     $property eq "radiusScale"
	     ||
	     $property eq "radiusVirial"
	    );
    }
    $parameters->{'nbodyOperator'}->{'nbodyOperator'}->[2]->{'propertyNames'}->{'value'} = join(" ",@propertiesToDelete);
    # Add physical to comoving conversion.
    splice(
	@{$parameters->{'nbodyOperator'}->{'nbodyOperator'}},
	2,0,
	{
	    value => "physicalToComoving"
	}
	);
}

sub symphonyPreProcessExtractLocate {
    # Identify the primary progenitor.
    my $entry   =   shift() ;
    my $jobs    =   shift() ;
    my %options = %{shift()};
    # Find the host halo ID for this realization.
    my $hostHaloID;
    if ( exists($entry->{'hostHaloIDs'}) ) {
	($hostHaloID) = map {$entry->{'simulation'}->{'realizationsList'}->[$_] eq $entry->{'realization'} ? $entry->{'hostHaloIDs'}->[$_] : ()} 0..$#{$entry->{'simulation'}->{'realizationsList'}};
    } else {
	$hostHaloID   = -1;
    }
    # Iterate over expansion factors.
    my $job;
    foreach my $epoch ( @{$entry->{'group'}->{'epochs'}} ) {
	# Look for an existing record of the primary halo.
	my $primaryHaloFileName    = $entry->{'path'}."primaryHalo_".$epoch->{'redshiftLabel'}.".xml";
	my $xml                    = new XML::Simple();
	unless ( -e $primaryHaloFileName ) {
	    # Generate a job to extract the primary halo.
	    unless ( defined($job) ) {
		$job->{'command'   } = "";
		$job->{'launchFile'} = $entry->{'path'}."zoomInExtract_".$entry->{'suite'}->{'name'}."_".$entry->{'group'}->{'name'}."_".$entry->{'simulation'}->{'name'}."_".$entry->{'realization'}.".sh" ;
		$job->{'logFile'   } = $entry->{'path'}."zoomInExtract_".$entry->{'suite'}->{'name'}."_".$entry->{'group'}->{'name'}."_".$entry->{'simulation'}->{'name'}."_".$entry->{'realization'}.".log";
		$job->{'label'     } =                  "zoomInExtract_".$entry->{'suite'}->{'name'}."_".$entry->{'group'}->{'name'}."_".$entry->{'simulation'}->{'name'}."_".$entry->{'realization'}       ;
		$job->{'ppn'       } = 1;
		$job->{'ompThreads'} = 1;
		$job->{'nodes'     } = 1;
		$job->{'mem'       } = "32G";
		$job->{'walltime'  } = "8:00:00";
		$job->{'mpi'       } = "no";
	    }
	    $job->{'command'} .= $options{'pipelinePath'}."haloMassFunctionZoomInExtract.pl ".$entry->{'path'}." ".$primaryHaloFileName." ".$epoch->{'expansionFactor'}." ".$entry->{'suite'}->{'cosmology'}->{'hubbleConstant'}." ".$entry->{'group'}->{'massParticle'}." ".$entry->{'group'}->{'haloMassFunction'}->{'massHostLogMin'}->{'value'}." ".$entry->{'group'}->{'haloMassFunction'}->{'massHostLogMax'}->{'value'}." ".$hostHaloID."\n";
	}
    }   
    push(@{$jobs},$job)
	if ( defined($job) );
}

sub symphonyPreProcessExtractUncontaminated {
    # Find the uncontaminated region.
    my $entry   =   shift() ;
    my $jobs    =   shift() ;
    my %options = %{shift()};
    # Iterate over expansion factors.
    foreach my $epoch ( @{$entry->{'group'}->{'epochs'}} ) {
	# Look for an existing record of the primary halo.
	my $primaryHaloFileName  = $entry->{'path'}."primaryHalo_".$epoch->{'redshiftLabel'}.".xml";
	# Find properties of the central halo.
	my $xml                  = new XML::Simple();
	my $primaryHaloData      = $xml->XMLin($primaryHaloFileName);
	my $expansionFactorLabel = sprintf("sphericalOrigin:a%5.3f",$epoch->{'expansionFactor'});
	$entry->{$expansionFactorLabel} =
	    $primaryHaloData->{'x'}." ".
	    $primaryHaloData->{'y'}." ".
	    $primaryHaloData->{'z'}    ;
	$entry->{'massCentral'} = pdl $primaryHaloData->{'mc'};
	# Generate job to find the uncontaminated region.
	my $uncontaminatedFileName = $entry->{'path'}."uncontaminated_".$epoch->{'redshiftLabel'}.".hdf5";
	unless ( -e $uncontaminatedFileName ) {
	    my $parametersUncontaminated = $xml->XMLin($options{'pipelinePath'}."zoomInSelectUncontaminated.xml");
	    # Modify file names.
	    (my $snapshot) = map {$entry->{'group'}->{'expansionFactors'}->[$_] == $epoch->{'expansionFactor'} ? $entry->{'group'}->{'snapshots'}->[$_] : ()} 0..$#{$entry->{'group'}->{'expansionFactors'}};
	    $parametersUncontaminated->{'nbodyImporter'}                        ->{'fileName'      }->{'value'} = $entry->{'path'}."snapshots/snapshot_".$snapshot;
	    $parametersUncontaminated->{'nbodyOperator'}->{'nbodyOperator'}->[0]->{'point'         }->{'value'} = $entry->{$expansionFactorLabel};
	    $parametersUncontaminated->{'nbodyOperator'}->{'nbodyOperator'}->[1]->{'fileName'      }->{'value'} = $uncontaminatedFileName;
	    $parametersUncontaminated                                           ->{'outputFileName'}->{'value'} = $entry->{'path'}."uncontaminatedExtract_".$epoch->{'redshiftLabel'}.".hdf5";
	    # Write parameter file.
	    my $parameterFileName = $entry->{'path'}."uncontaminated_".$epoch->{'redshiftLabel'}.".xml";
	    open(my $outputFile,">",$parameterFileName);
	    print $outputFile $xml->XMLout($parametersUncontaminated, RootName => "parameters");
	    close($outputFile);
	    # Generate a job to extract the uncontaminated region around the primary halo.
	    my $job;
	    $job->{'command'   } = $ENV{'GALACTICUS_EXEC_PATH'}."/Galacticus.exe ".$entry->{'path'}."uncontaminated_".$epoch->{'redshiftLabel'}.".xml";
	    $job->{'launchFile'} = $entry->{'path'}."uncontaminatedExtract_".$entry->{'suite'}->{'name'}."_".$entry->{'group'}->{'name'}."_".$entry->{'simulation'}->{'name'}."_".$entry->{'realization'}."_".$epoch->{'redshiftLabel'}.".sh" ;
	    $job->{'logFile'   } = $entry->{'path'}."uncontaminatedExtract_".$entry->{'suite'}->{'name'}."_".$entry->{'group'}->{'name'}."_".$entry->{'simulation'}->{'name'}."_".$entry->{'realization'}."_".$epoch->{'redshiftLabel'}.".log";
	    $job->{'label'     } =                  "uncontaminatedExtract_".$entry->{'suite'}->{'name'}."_".$entry->{'group'}->{'name'}."_".$entry->{'simulation'}->{'name'}."_".$entry->{'realization'}."_".$epoch->{'redshiftLabel'}       ;
	    $job->{'ppn'       } = $ompThreads;
	    $job->{'ompThreads'} = $ompThreads;
	    $job->{'nodes'     } = 1;
	    $job->{'mem'       } = "16G";
	    $job->{'walltime'  } = "8:00:00";
	    $job->{'mpi'       } = "no";
	    push(@{$jobs},$job)
	}
    }
}

sub symphonyProcessExtract {
    # Determine the central point, and extent of the high-resolution region in a zoom in simulation.
    my $entry           =   shift() ;
    my $parameters      =   shift() ;
    my $expansionFactor =   shift() ;
    my %options         = %{shift()};
    print "Processing extraction for ".$entry->{'suite'}->{'name'}." : ".$entry->{'group'}->{'name'}." : ".$entry->{'simulation'}->{'name'}." : ".$entry->{'realization'}."\n";
    # Set path names.
    my $redshift               =  1.0/$expansionFactor-1.0;
    my $epoch->{'redshiftLabel'}          = sprintf("z%5.3f",$redshift);
    my $expansionFactorLabel   = sprintf("sphericalOrigin:a%5.3f",$expansionFactor);
    my $primaryHaloFileName    = $entry->{'path'}."primaryHalo_"   .$epoch->{'redshiftLabel'}.".xml";
    my $uncontaminatedFileName = $entry->{'path'}."uncontaminated_".$epoch->{'redshiftLabel'}.".hdf5";
    # Find properties of the central halo.
    my $xml                    = new XML::Simple();
    my $primaryHaloData        = $xml->XMLin($primaryHaloFileName);
    # Find uncontaminated region.
    my $uncontaminatedFile      = new PDL::IO::HDF5($uncontaminatedFileName);
    my $uncontaminatedParticles = $uncontaminatedFile     ->group  ('Snapshot00001/HaloCatalog');
    (my $radiusUncontaminated)  = $uncontaminatedParticles->attrGet('radiusUncontaminated'     );
    $primaryHaloData->{'ur'} = $radiusUncontaminated->sclr();
    open(my $primaryHaloDataFile,">",$primaryHaloFileName);
    print $primaryHaloDataFile $xml->XMLout($primaryHaloData, RootName => "primaryHalo");
    close($primaryHaloDataFile);
    # Add read of (x,y,z) coordinate columns, and subsequent delete.
    $parameters->{'nbodyImporter'}                        ->{'properties'   }->{'value'} .= " position"         ;
    $parameters->{'nbodyOperator'}->{'nbodyOperator'}->[1]->{'propertyNames'}->{'value'} .= " distanceFromPoint";
    # Add calculation of distance from primary halo.
    $entry->{$epoch->{'redshiftLabel'}}->{'sphericalRadiusMinimum'} = 0.0;
    $entry->{$epoch->{'redshiftLabel'}}->{'sphericalRadiusMaximum'} = $radiusUncontaminated->sclr();
    splice(
	@{$parameters->{'nbodyOperator'}->{'nbodyOperator'}},
	1,0,
	{
	    value         => "distanceFromPoint",
	    point         => {value => $entry->{$expansionFactorLabel}}
	},
	{
	    value         =>           "filterProperties"                                   ,
	    propertyNames => {value => "distanceFromPoint"                                 },
	    rangeLow      => {value => $entry->{$epoch->{'redshiftLabel'}}->{'sphericalRadiusMinimum'}},
	    rangeHigh     => {value => $entry->{$epoch->{'redshiftLabel'}}->{'sphericalRadiusMaximum'}},
	},
	{
	    value         => "setBoxSize",
	    boxSize       => {value => $primaryHaloData->{'l'}}
	}
	);
}

sub symphonyPostprocessSelectInSphere {
    # Select all particles within the sphere of interest.
    my $entry   =   shift() ;
    my $jobs    =   shift() ;
    my %options = %{shift()};
    # Generate a parameter file to extract particles within the spherical volume of interest.
    my $xml        = new XML::Simple();
    my $parameters = $xml->XMLin($options{'pipelinePath'}."zoomInSelectInSphere.xml");
    # Iterate over expansion factors.
    foreach my $epoch ( @{$entry->{'group'}->{'epochs'}} ) {
	my $expansionFactorLabel = sprintf("sphericalOrigin:a%5.3f",$epoch->{'expansionFactor'});
	(my $snapshot) = map {$entry->{'group'}->{'expansionFactors'}->[$_] == $epoch->{'expansionFactor'} ? $entry->{'group'}->{'snapshots'}->[$_] : ()} 0..$#{$entry->{'group'}->{'expansionFactors'}};
	$parameters->{'nbodyImporter'}                        ->{'fileName' }->{'value'} = $entry->{'path'}."snapshots/snapshot_".$snapshot;
	$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[4]->{'fileName' }->{'value'} = $entry->{'path'}."selectedParticles_".$epoch->{'redshiftLabel'}.".hdf5";
	$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[4]->{'redshift' }->{'value'} =                                       $epoch->{'redshift'     }        ;
	$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[0]->{'point'    }->{'value'} = $entry->{$expansionFactorLabel}                                        ;
	$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[1]->{'rangeLow' }->{'value'} = $entry->{$epoch->{'redshiftLabel'}}->{'sphericalRadiusMinimum'} ;
	$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[1]->{'rangeHigh'}->{'value'} = $entry->{$epoch->{'redshiftLabel'}}->{'sphericalRadiusMaximum'} ;
	my $parameterFileName = $entry->{'path'}."selectInSphere_".$epoch->{'redshiftLabel'}.".xml";
	open(my $outputFile,">",$parameterFileName);
	print $outputFile $xml->XMLout($parameters, RootName => "parameters");
	close($outputFile);
	my $job;
	$job->{'command'   } =
	    $ENV{'GALACTICUS_EXEC_PATH'}."/Galacticus.exe ".$parameterFileName;
	$job->{'launchFile'} = $entry->{'path'}."selectInSphere_".$epoch->{'redshiftLabel'}.".sh" ;
	$job->{'logFile'   } = $entry->{'path'}."selectInSphere_".$epoch->{'redshiftLabel'}.".log";
	$job->{'label'     } =                  "selectInSphere_".$epoch->{'redshiftLabel'}       ;
	$job->{'ppn'       } = $ompThreads;
	$job->{'ompThreads'} = $ompThreads;
	$job->{'nodes'     } =  1;
	$job->{'mem'       } = "16G";
	$job->{'walltime'  } = "8:00:00";
	$job->{'mpi'       } = "no";
	push(@{$jobs},$job)
	    unless ( -e $parameters->{'nbodyOperator'}->{'nbodyOperator'}->[4]->{'fileName' }->{'value'} );
    }
}

sub symphonyPostprocessExtractSelectedIDs {
    # Extract the IDs of selected particles.
    my $entry   =   shift() ;
    my $jobs    =   shift() ;
    my %options = %{shift()};
    # Iterate over expansion factors.
    foreach my $epoch ( @{$entry->{'group'}->{'epochs'}} ) {
	# Read particle IDs.
	next
	    if ( -e $entry->{'path'}."selectedParticlesIDs_".$epoch->{'redshiftLabel'}.".hdf5" );
	my $selectedParticleFile = new PDL::IO::HDF5(    $entry->{'path'}."selectedParticles_"   .$epoch->{'redshiftLabel'}.".hdf5");
	my $selectedIDFile       = new PDL::IO::HDF5(">".$entry->{'path'}."selectedParticlesIDs_".$epoch->{'redshiftLabel'}.".hdf5");
	my $selectedIDs          = $selectedParticleFile->group('Snapshot00001')->group('HaloCatalog')->dataset('HaloID')->get();
	$selectedIDFile->dataset('id')->set($selectedIDs);
    }
}

sub symphonyPostprocessSelectInICs {
    # Identify selected particles in the initial conditions.
    my $entry   =   shift() ;
    my $jobs    =   shift() ;
    my %options = %{shift()};
    # Find the redshift of the ICs.
    my $musicFileName = $entry->{'path'}."music.conf";
    die("missing file: ".$musicFileName)
	unless ( -e $musicFileName );
    open(my $musicFile,$musicFileName);
    while ( my $line = <$musicFile> ) {
	if ( $line =~ m/^zstart\s*=\s*([\d\.]+)/ ) {
	    $entry->{'redshiftICs'} = $1;
	}
    }
    close($musicFile);
    # Generate a parameter file to extract selected particles in the ICs.
    my $xml        = new XML::Simple();
    my $parameters = $xml->XMLin($options{'pipelinePath'}."zoomInSelectInICs.xml");
    # Iterate over expansion factors.
    foreach my $epoch ( @{$entry->{'group'}->{'epochs'}} ) {
	$parameters->{'nbodyImporter'}                        ->{'fileName'           }->{'value'} =                $entry->{'path'       }."ic/ic_gadget_dist"                                ;
	$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[0]->{'idSelectionFileName'}->{'value'} =                $entry->{'path'       }."selectedParticlesIDs_".$epoch->{'redshiftLabel'}.    ".hdf5" ;
	$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[1]->{'fileName'           }->{'value'} =                $entry->{'path'       }."selectedParticles_"   .$epoch->{'redshiftLabel'}."_ICs.hdf5" ;
	$parameters->{'nbodyOperator'}->{'nbodyOperator'}->[1]->{'redshift'           }->{'value'} = sprintf("%.3f",$entry->{'redshiftICs'}                                                   );
	$parameters                                           ->{'outputFileName'     }->{'value'} =                $entry->{'path'       }."selectInICs_"         .$epoch->{'redshiftLabel'}.    ".hdf5" ;
	my $parameterFileName = $entry->{'path'}."selectInICs_".$epoch->{'redshiftLabel'}.".xml";
	open(my $outputFile,">",$parameterFileName);
	print $outputFile $xml->XMLout($parameters, RootName => "parameters");
	close($outputFile);
	my $job;
	$job->{'command'   } =
	    $ENV{'GALACTICUS_EXEC_PATH'}."/Galacticus.exe ".$parameterFileName;
	$job->{'launchFile'} = $entry->{'path'}."selectInICs_".$epoch->{'redshiftLabel'}.".sh" ;
	$job->{'logFile'   } = $entry->{'path'}."selectInICs_".$epoch->{'redshiftLabel'}.".log";
	$job->{'label'     } =                  "selectInICs_".$epoch->{'redshiftLabel'}       ;
	$job->{'ppn'       } = $ompThreads;
	$job->{'ompThreads'} = $ompThreads;
	$job->{'nodes'     } =  1;
	$job->{'mem'       } = "16G";
	$job->{'walltime'  } = "8:00:00";
	$job->{'mpi'       } = "no";
	push(@{$jobs},$job)
	    unless ( -e $parameters->{'nbodyOperator'}->{'nbodyOperator'}->[1]->{'fileName' }->{'value'} );
    }
}

sub symphonyPostprocessAnalyze {
    # Measure mass and overdensity of the selected region.
    my $entry   =   shift() ;
    my $jobs    =   shift() ;
    my %options = %{shift()};
    # Generate a parameter file to measure mass and overdensity.
    my $xml        = new XML::Simple();
    my $parameters = $xml->XMLin($options{'pipelinePath'}."zoomInAnalyze.xml");
    # Iterate over expansion factors.
    foreach my $epoch ( @{$entry->{'group'}->{'epochs'}} ) {
	$parameters->{'outputFileName'}                                                         ->{'value'} =                $entry->{'path'       }."environment_"      .$epoch->{'redshiftLabel'}.".hdf5"     ;
	$parameters->{'nbodyImporter' }->{'nbodyImporter'}->[0]                   ->{'fileName'}->{'value'} =                $entry->{'path'       }."selectedParticles_".$epoch->{'redshiftLabel'}."_ICs.hdf5" ;
	$parameters->{'nbodyImporter' }->{'nbodyImporter'}->[1]                   ->{'fileName'}->{'value'} =                $entry->{'path'       }."ic/ic_gadget_dist"                             ;
	$parameters->{'nbodyOperator' }->{'nbodyOperator'}->[0]                   ->{'values'  }->{'value'} = sprintf("%.3f",$entry->{'redshiftICs'}                                                );
	$parameters->{'nbodyOperator' }->{'nbodyOperator'}->[5]->{'nbodyOperator'}->{'fileName'}->{'value'} =                $entry->{'path'       }."allParticles_"     .$epoch->{'redshiftLabel'}."_ICs.hdf5" ;
	$parameters->{'nbodyOperator' }->{'nbodyOperator'}->[5]->{'nbodyOperator'}->{'redshift'}->{'value'} = sprintf("%.3f",$entry->{'redshiftICs'}                                                );
	my $parameterFileName = $entry->{'path'}."analyze_".$epoch->{'redshiftLabel'}.".xml";
	open(my $outputFile,">",$parameterFileName);
	print $outputFile $xml->XMLout($parameters, RootName => "parameters");
	close($outputFile);
	my $job;
	$job->{'command'   } =
	    $ENV{'GALACTICUS_EXEC_PATH'}."/Galacticus.exe ".$parameterFileName;
	$job->{'launchFile'} = $entry->{'path'}."analyze_".$epoch->{'redshiftLabel'}.".sh" ;
	$job->{'logFile'   } = $entry->{'path'}."analyze_".$epoch->{'redshiftLabel'}.".log";
	$job->{'label'     } =           "analyze_".$epoch->{'redshiftLabel'}       ;
	$job->{'ppn'       } = $ompThreads;
	$job->{'ompThreads'} = $ompThreads;
	$job->{'nodes'     } =  1;
	$job->{'mem'       } = "32G";
	$job->{'walltime'  } = "8:00:00";
	$job->{'mpi'       } = "no";
	push(@{$jobs},$job)
	    unless ( -e $entry->{'path'}."environment_".$epoch->{'redshiftLabel'}.":MPI0000.hdf5" );
    }
}

sub symphonyPostprocessSetVolume {
    # Set the effective Lagrangian volume for the selected region.
    my $entry   =   shift() ;
    my $jobs    =   shift() ;
    my %options = %{shift()};
    # Iterate over expansion factors.
    foreach my $epoch ( @{$entry->{'group'}->{'epochs'}} ) {
	# Extract the mass of the region.
	my $analysisFile          = new PDL::IO::HDF5($entry->{'path'}."selectedParticles_".$epoch->{'redshiftLabel'}.".hdf5");
	die("error: 'massTotal' attribute is missing from file '".$entry->{'path'}."selectedParticles_".$epoch->{'redshiftLabel'}.".hdf5'")
	    unless ( grep {$_ eq "massTotal"} $analysisFile->group('Snapshot00001')->group('HaloCatalog')->attrs() );
	(my $mass)                = $analysisFile->group('Snapshot00001')->group('HaloCatalog')->attrGet('massTotal');
	# Find properties of the central halo.
	my $primaryHaloFileName   = $entry->{'path'}."primaryHalo_".$epoch->{'redshiftLabel'}.".xml";
	my $xml                   = new XML::Simple();
	my $primaryHaloData       = $xml->XMLin($primaryHaloFileName);
	my $massPrimary           = $primaryHaloData->{'m'};
	# Compute the mean density of the universe.
	my $gravitationalConstant = pdl 4.3011827419096073e-9;
	my $densityMean           = 3.0*$entry->{'suite'}->{'cosmology'}->{'OmegaMatter'}*$entry->{'suite'}->{'cosmology'}->{'HubbleConstant'}**2/8.0/PI/$gravitationalConstant;
	# Compute the volume of a cube containing the mass of our selected region.
	die("Primary halo mass exceeds region mass")
	    if ( $massPrimary >= $mass );
	my $boxSize                                = (    ($mass-$massPrimary)/$densityMean       )**(1.0/3.0);
	$entry->{$epoch->{'redshiftLabel'}}->{'radiusRegion'} = (3.0* $mass              /$densityMean/4.0/PI)**(1.0/3.0);
	$entry->{$epoch->{'redshiftLabel'}}->{'massRegion'  } =       $mass                                              ;
	$entry->{$epoch->{'redshiftLabel'}}->{'massPrimary' } =             $massPrimary                                 ;
	# Set the box size.
	my $halosFile = new PDL::IO::HDF5(">".$entry->{'path'}."nonFlyby_".$epoch->{'redshiftLabel'}."_subVolume0_0_0.hdf5");
	$halosFile->group('Snapshot00001'       )->group('HaloCatalog')->attrSet(boxSize => $boxSize);
	$halosFile->group('SimulationProperties')                      ->attrSet(boxSize => $boxSize);
    }
}

sub symphonyPostProcessMassFunction {
    # Store the region mass and overdensity in the mass function file.
    my $entry   =   shift() ;
    my $jobs    =   shift() ;
    my %options = %{shift()};
    # Iterate over expansion factors.
    foreach my $epoch ( @{$entry->{'group'}->{'epochs'}} ) {
	# Extract overdensity from the analysis file.
	my $analysisFile         = new PDL::IO::HDF5($entry->{'path'}."environment_".$epoch->{'redshiftLabel'}.":MPI0000.hdf5");
	die("error: 'simulation0002' group is missing from file '".$entry->{'path'}."environment_".$epoch->{'redshiftLabel'}.":MPI0000.hdf5'")
	    unless ( grep {$_ eq "simulation0002"} $analysisFile->groups() );
	foreach my $attributeName ( 'massTotal', 'convexHullOverdensity' ) {
	    die("error: '".$attributeName."' attribute is missing from file '".$entry->{'path'}."environment_".$epoch->{'redshiftLabel'}.":MPI0000.hdf5'")
		unless ( grep {$_ eq $attributeName} $analysisFile->group('simulation0002')->attrs() );
	}
	(my $mass)               = $analysisFile->group('simulation0002')->attrGet('massTotal'            );
	(my $overdensity)        = $analysisFile->group('simulation0002')->attrGet('convexHullOverdensity');
	# Store these to the halo mass function.
	my $haloMassFunctionFile = new PDL::IO::HDF5(">".$entry->{'path'}."haloMassFunction_nonFlyby_".$epoch->{'redshiftLabel'}.":MPI0000.hdf5");
	my $simulationGroup      = $haloMassFunctionFile->group('simulation0001')                                     ;
	$simulationGroup->attrSet(massPrimary            => $entry->{$epoch->{'redshiftLabel'}}->{'massPrimary' });
	$simulationGroup->attrSet(massRegion             => $entry->{$epoch->{'redshiftLabel'}}->{'massRegion'  });
	$simulationGroup->attrSet(radiusRegion           => $entry->{$epoch->{'redshiftLabel'}}->{'radiusRegion'});
	$simulationGroup->attrSet(overdensityEnvironment => $overdensity                              );
	$simulationGroup->attrSet(massEnvironment        => $mass                                     );
    }
}
