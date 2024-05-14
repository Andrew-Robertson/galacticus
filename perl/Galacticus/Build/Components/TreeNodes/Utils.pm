# Contains a Perl module which provides various utility functions for tree nodes.

package Galacticus::Build::Components::TreeNodes::Utils;
use strict;
use warnings;
use utf8;
use Cwd;
use lib $ENV{'GALACTICUS_EXEC_PATH'}."/perl";
use Text::Template 'fill_in_string';
use List::ExtraUtils;
use Galacticus::Build::Components::Utils qw($workaround);
use Galacticus::Build::Components::DataTypes;

# Insert hooks for our functions.
%Galacticus::Build::Component::Utils::componentUtils = 
    (
     %Galacticus::Build::Component::Utils::componentUtils,
     treeNodeUtils =>
     {
	 functions =>
	     [
	      \&Tree_Node_Copy             ,
	      \&Tree_Node_Move             ,
	      \&Tree_Node_Mass_Distribution
	     ]
     }
    );

sub Tree_Node_Copy {
    # Generate a function to copy one tree node to another.
    my $build = shift();
    my $function =
    {
	type        => "void",
	name        => "treeNodeCopyNodeTo",
	description => "Make a copy of {\\normalfont \\ttfamily self} in {\\normalfont \\ttfamily targetNode}.",
	variables   =>
	    [
	     {
		 intrinsic  => "class",
		 type       => "treeNode",
		 attributes => [ "intent(in   )" ],
		 variables  => [ "self" ]
	     },
	     {
		 intrinsic  => "class",
		 type       => "treeNode",
		 attributes => [ "intent(inout)" ],
		 variables  => [ "targetNode" ]
	     },
	     {
		 intrinsic  => "logical",
		 attributes => [ "intent(in   )", "optional" ],
		 variables  => [ "skipFormationNode", "skipEvent" ]
	     },
	     {
		 intrinsic  => "logical",
		 variables  => [ "skipFormationNodeActual", "skipEventActual" ]
	     },
	     {
		 intrinsic  => "integer",
		 variables  => [ "i" ]
	     }
	    ]
    };    
    $function->{'content'}  = fill_in_string(<<'CODE', PACKAGE => 'code');
skipFormationNodeActual=.false.
skipEventActual        =.false.
if (present(skipFormationNode)) skipFormationNodeActual=skipFormationNode
if (present(skipEvent        )) skipEventActual        =skipEvent
{join("",map {"targetNode%".$_." =  self%".$_."\n"} ( "uniqueIdValue", "indexValue", "timeStepValue", "subsamplingWeightValue" ))}
{join("",map {"targetNode%".$_." => self%".$_."\n"} ( "parent", "firstChild", "sibling", "firstSatellite", "mergeTarget", "firstMergee", "siblingMergee", "event", "formationNode", "hostTree" ))}
if (skipFormationNodeActual) targetNode%formationNode => null()
if (skipEventActual        ) targetNode%event         => null()
CODE
    # Loop over all component classes
    if ( $workaround == 1 ) { # Workaround "Assignment to an allocatable polymorphic variable is not yet supported"
	foreach $code::class ( &List::ExtraUtils::hashList($build->{'componentClasses'}) ) {
	    next
		unless ( grep {$code::class->{'name'} eq $_} @{$build->{'componentClassListActive'}} );
	    $function->{'content'} .= fill_in_string(<<'CODE', PACKAGE => 'code');
if (allocated(targetNode%component{ucfirst($class->{'name'})})) deallocate(targetNode%component{ucfirst($class->{'name'})})
allocate(targetNode%component{ucfirst($class->{'name'})}(size(self%component{ucfirst($class->{'name'})})),source=self%component{ucfirst($class->{'name'})}(1))
do i=1,size(self%component{ucfirst($class->{'name'})})
CODE
	    foreach $code::member ( @{$code::class->{'members'}} ) {
		$function->{'content'} .= fill_in_string(<<'CODE', PACKAGE => 'code');
   select type (from => self%component{ucfirst($class->{'name'})})
   type is (nodeComponent{ucfirst($class->{'name'}).ucfirst($member->{'name'})})
     select type (to => targetNode%component{ucfirst($class->{'name'})})
     type is (nodeComponent{ucfirst($class->{'name'}).ucfirst($member->{'name'})})
       to=from
     end select
   end select
CODE
	    }
	    $function->{'content'} .= fill_in_string(<<'CODE', PACKAGE => 'code');
end do
CODE
	}
    } else {
	foreach $code::component ( &List::ExtraUtils::hashList($build->{'componentClasses'}) ) {
	    next
		unless ( grep {$code::class->{'name'} eq $_} @{$build->{'componentClassListActive'}} );
	    $function->{'content'} .=
		join("",map {"targetNode%component".ucfirst($_->{'name'})." = self%component".ucfirst($_->{'name'})."\n"} &List::ExtraUtils::hashList($build->{'componentClasses'}));
	}
    }
    # Update target node pointers.
    $function->{'content'} .= fill_in_string(<<'CODE', PACKAGE => 'code');
select type (targetNode)
type is (treeNode)
CODE
    foreach $code::class ( &List::ExtraUtils::hashList($build->{'componentClasses'}) ) {
	next
	    unless ( grep {$code::class->{'name'} eq $_} @{$build->{'componentClassListActive'}} );
	$function->{'content'} .= fill_in_string(<<'CODE', PACKAGE => 'code');
   do i=1,size(self%component{ucfirst($class->{'name'})})
     targetNode%component{ucfirst($class->{'name'})}(i)%hostNode => targetNode
   end do
CODE
    }
    $function->{'content'} .= fill_in_string(<<'CODE', PACKAGE => 'code');
end select
CODE
    # Insert a type-binding for this function into the treeNode type.
    push(
	@{$build->{'types'}->{'treeNode'}->{'boundFunctions'}},
	{
	    type        => "procedure", 
	    descriptor  => $function,
	    name        => "copyNodeTo", 
	    returnType  => "\\void", 
	    arguments   => "\\textcolor{red}{\\textless class(treeNode)\\textgreater} targetNode\\arginout, \\logicalzero\\ [skipFormationNode]\\argin"
	}
	);
}

sub Tree_Node_Move {
    # Generate a function to move components of one tree node to another.
    my $build = shift();
    my $function =
    {
	type        => "void",
	name        => "treeNodeComponentsMove",
	description => "Move components from {\\normalfont \\ttfamily self} to {\\normalfont \\ttfamily targetNode}.",
	variables   =>
	    [
	     {
		 intrinsic  => "class",
		 type       => "treeNode",
		 attributes => [ "intent(inout)" ],
		 variables  => [ "self" ]
	     },
	     {
		 intrinsic  => "type",
		 type       => "treeNode",
		 attributes => [ "intent(inout)", "target" ],
		 variables  => [ "targetNode" ]
	     },
	     {
		 intrinsic  => "integer",
		 variables  => [ "i" ]
	     }
	    ]
    };
    # Iterate over all component classes
    foreach $code::class ( &List::ExtraUtils::hashList($build->{'componentClasses'}) ) {
	next
	    unless ( grep {$code::class->{'name'} eq $_} @{$build->{'componentClassListActive'}} );
	$function->{'content'} .= fill_in_string(<<'CODE', PACKAGE => 'code');
if (allocated(targetNode%component{ucfirst($class->{'name'})})) then
  do i=1,size(targetNode%component{ucfirst($class->{'name'})})
    call targetNode%component{ucfirst($class->{'name'})}(i)%destroy()
  end do
  deallocate(targetNode%component{ucfirst($class->{'name'})})
end if
if (allocated(self      %component{ucfirst($class->{'name'})})) then
   call Move_Alloc(self%component{ucfirst($class->{'name'})},targetNode%component{ucfirst($class->{'name'})})
   do i=1,size(targetNode%component{ucfirst($class->{'name'})})
     targetNode%component{ucfirst($class->{'name'})}(i)%hostNode => targetNode
   end do
end if
CODE
    }
    # Insert a type-binding for this function into the treeNode type.
    push(
	@{$build->{'types'}->{'treeNode'}->{'boundFunctions'}},
	{
	    type        => "procedure", 
	    descriptor  => $function,
	    name        => "moveComponentsTo"
	}
	);
}

sub Tree_Node_Mass_Distribution {
    # Generate a function to construct and return the mass distribution associated with a node.
    my $build = shift();
    my $function =
    {
	type        => "class(massDistributionClass), pointer => massDistribution_",
	name        => "treeNodeMassDistribution",
	description => "Construct and return the mass distribution associated with {\\normalfont \\ttfamily self}.",
	modules     =>
	    [
	     "Mass_Distributions        , only : massDistributionClass       , massDistributionComposite, massDistributionList"   ,
	     "Galactic_Structure_Options, only : enumerationComponentTypeType, enumerationMassTypeType  , enumerationWeightByType"
	    ],
	variables   =>
	    [
	     {
		 intrinsic  => "class",
		 type       => "treeNode",
		 attributes => [ "intent(inout)" ],
		 variables  => [ "self" ]
	     },
	     {
		 intrinsic  => "type",
		 type       => "enumerationComponentTypeType",
		 attributes => [ "intent(in   )", "optional" ],
		 variables  => [ "componentType" ]
	     },
	     {
		 intrinsic  => "type",
		 type       => "enumerationMassTypeType",
		 attributes => [ "intent(in   )", "optional" ],
		 variables  => [ "massType" ]
	     },
	     {
		 intrinsic  => "type",
		 type       => "enumerationWeightByType",
		 attributes => [ "intent(in   )", "optional" ],
		 variables  => [ "weightBy" ]
	     },
	     {
		 intrinsic  => "integer",
		 attributes => [ "intent(in   )", "optional" ],
		 variables  => [ "weightIndex" ]
	     },
	     {
		 intrinsic  => "class",
		 type       => "massDistributionClass",
		 attributes => [ "pointer" ],
		 variables  => [ "massDistributionComponent" ]
	     },
	     {
		 intrinsic  => "integer",
		 variables  => [ "i", "iMassDistribution" ]
	     },
	     {
		 intrinsic  => "type",
		 type       => "massDistributionList",
		 attributes => [ "pointer" ],
		 variables  => [ "massDistributionList_", "massDistributionList__", "next_", "next__" ]
	     }
	    ]
    };
    $function->{'content'} .= fill_in_string(<<'CODE', PACKAGE => 'code');
! Search for a match to our ID.
iMassDistribution=0
do i=1,massDistributionsCount
 if (massDistributions__(i)%uniqueID == self%uniqueID()) then
  iMassDistribution=i
  exit
 end if
end do
! If no existing mass distribution matched, free up space for a new one. Avoid replacing the parent of a node as parent/child
! massDistribution pairs are frequently used (e.g. in orbital evolution calculations).
if (iMassDistribution == 0) then
 massDistributionsLast=mod(massDistributionsLast,massDistributionsCount)+1
 if (associated(massDistributions__(massDistributionsLast)%massDistribution_)) then
  if (associated(self%parent) .and. massDistributions__(massDistributionsLast)%uniqueID == self%parent%uniqueID()) then
   massDistributionsLast=mod(massDistributionsLast,massDistributionsCount)+1
  end if
 end if
 !![
 <objectDestructor name="massDistributions__(massDistributionsLast)%massDistribution_"/>
 !!]
 massDistributions__(massDistributionsLast)%uniqueID=-huge(kind_int8)
 iMassDistribution=massDistributionsLast
end if
if (.not.associated(massDistributions__(iMassDistribution)%massDistribution_)) then
 massDistributionList_  => null()
 massDistributionList__ => null()
 next_                  => null()
 next__                 => null()
CODE
    # Iterate over all component classes
    foreach $code::class ( &List::ExtraUtils::hashList($build->{'componentClasses'}) ) {
	next
	    unless ( grep {$code::class->{'name'} eq $_} @{$build->{'componentClassListActive'}} );
	# <workaround type="gfortran" PR="37336" url="https:&#x2F;&#x2F;gcc.gnu.org&#x2F;bugzilla&#x2F;show_bug.cgi=37336">
	#   <description>
	#    In the following, we build two, identical lists of mass distributions. This is necessary as the first is passed to the
	#    massDistributionComposite() constructor and retained. But, we need to call objectDestructor on each of the mass
	#    distributions in our list to release them. If we did that by iterating over the list passed to
	#    massDistributionComposite() we would nullify its pointers, leaving it unable to find the mass distributions. Therefore,
	#    we make a second list, iterate over it calling objectDestructor on each massDistribution, and then destroy that list.
	#
	#    With correct resource management in assignment, copy, and finalization, this should be handled automatically.
	#   </description>
	# </workaround>
	$function->{'content'} .= fill_in_string(<<'CODE', PACKAGE => 'code');
 if (allocated(self%component{ucfirst($class->{'name'})})) then
    do i=1,size(self%component{ucfirst($class->{'name'})})
      massDistributionComponent => self%component{ucfirst($class->{'name'})}(i)%massDistribution(componentType,massType)
      if (associated(massDistributionComponent)) then
        if (massDistributionComponent%matches(componentType,massType)) then
          if (associated(massDistributionList_)) then
            allocate(next_ %next)
            allocate(next__%next)
            next_  => next_ %next
            next__ => next__%next
          else
            allocate(massDistributionList_ )
            allocate(massDistributionList__)
            next_  => massDistributionList_
            next__ => massDistributionList__
          end if
          next_ %massDistribution_ => massDistributionComponent
          next__%massDistribution_ => massDistributionComponent
          next_ %next              => null()
          next__%next              => null()
        else
          !![
          <objectDestructor name="massDistributionComponent"/>
          !!]
        end if
      end if
    end do
 end if
CODE
    }
    $function->{'content'} .= fill_in_string(<<'CODE', PACKAGE => 'code');
 allocate(massDistributionComposite :: massDistributions__(iMassDistribution)%massDistribution_)
 select type (massDistribution__ => massDistributions__(iMassDistribution)%massDistribution_)
 type is (massDistributionComposite)
   !![
   <referenceConstruct isResult="yes" object="massDistribution__" constructor="massDistributionComposite(massDistributionList_)"/>
   !!]
 end select
 massDistributions__(iMassDistribution)%uniqueID =  self                                  %uniqueID         ()
 next_ => massDistributionList__
 do while (associated(next_))
  !![
  <objectDestructor name="next_%massDistribution_"/>
  !!]
  next__ => next_%next
  deallocate(next_)
  next_  => next__
 end do
 nullify(massDistributionList_ )
 nullify(massDistributionList__)
end if
!![
<referenceAcquire target="massDistribution_" source="massDistributions__(iMassDistribution)%massDistribution_"/>
!!]
CODE
    # Insert a type-binding for this function into the treeNode type.
    push(
	@{$build->{'types'}->{'treeNode'}->{'boundFunctions'}},
	{
	    type        => "procedure", 
	    descriptor  => $function,
	    name        => "massDistribution"
	}
	);
}

1;
