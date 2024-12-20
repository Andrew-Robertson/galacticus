!! Copyright 2009, 2010, 2011, 2012, 2013, 2014, 2015, 2016, 2017, 2018,
!!           2019, 2020, 2021, 2022, 2023
!!    Andrew Benson <abenson@carnegiescience.edu>
!!
!! This file is part of Galacticus.
!!
!!    Galacticus is free software: you can redistribute it and/or modify
!!    it under the terms of the GNU General Public License as published by
!!    the Free Software Foundation, either version 3 of the License, or
!!    (at your option) any later version.
!!
!!    Galacticus is distributed in the hope that it will be useful,
!!    but WITHOUT ANY WARRANTY; without even the implied warranty of
!!    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!!    GNU General Public License for more details.
!!
!!    You should have received a copy of the GNU General Public License
!!    along with Galacticus.  If not, see <http://www.gnu.org/licenses/>.

  !!{
  Implements a heated spherical mass distribution.
  !!}

  use :: Root_Finder, only : rootFinder

  !![
  <massDistribution name="massDistributionSphericalHeated">
   <description>
     A mass distribution class in which the distribution starts out with a density profile defined by another {\normalfont
     \ttfamily massDistribution}. This profile is then modified by heating, under the assumption that the
     energy of a shell of mass before and after heating are related by
     \begin{equation}
     -{ \mathrm{G} M^\prime(r^\prime) \over r^\prime } = -{ \mathrm{G} M(r) \over r } + 2 \epsilon(r),
     \end{equation}    
     where $M(r)$ is the mass enclosed within a radius $r$, and $\epsilon(r)$ represents the specific heating in the shell
     initially at radius $r$. Primes indicate values after heating, while unprimed variables indicate quantities prior to
     heating. With the assumption of no shell crossing, $M^\prime(r^\prime)=M(r)$ and this equation can be solved for $r$ given
     $r^\prime$ and $\epsilon(r)$.
     
     Not all methods have analytic solutions for this profile. If {\normalfont \ttfamily [nonAnalyticSolver]}$=${\normalfont
     \ttfamily fallThrough} then attempts to call these methods in heated profiles will simply return the result from the
     unheated profile, otherwise a numerical calculation is performed.
    </description>
  </massDistribution>
  !!]
  type, extends(massDistributionSphericalDecorator) :: massDistributionSphericalHeated
     !!{
     Implementation of a heated spherical mass distribution.
     !!}
     !![
     <methods>
       <method description="Initialize the object."                                                                                          method="initialize"            />
       <method description="Return the initial radius corresponding to the given final radius in a heated dark matter halo density profile." method="radiusInitial"         />
       <method description="Return true if the no shell crossing assumption is valid locally."                                               method="noShellCrossingIsValid"/>
     </methods>
     !!]
     private
     class           (massDistributionHeatingClass), pointer :: massDistributionHeating_ => null()
     double precision                                        :: radiusFinalPrevious               , radiusInitialPrevious
     type            (rootFinder                  )          :: finder
   contains
     !![
     <methods>
       <method method="radiusInitial"          description="Compute the initial radius corresponding to a given final radius in a heated mass distribution."/>
       <method method="noShellCrossingIsValid" description="Return true if the no-shell crossing assumption is locally valid."                              />
     </methods>
     !!]
     final     ::                           sphericalHeatedDestructor
     procedure :: radiusInitial          => sphericalHeatedRadiusInitial
     procedure :: noShellCrossingIsValid => sphericalHeatedNoShellCrossingIsValid
     procedure :: density                => sphericalHeatedDensity
     procedure :: massEnclosedBySphere   => sphericalHeatedMassEnclosedBySphere
     procedure :: radiusEnclosingMass    => sphericalHeatedRadiusEnclosingMass
     procedure :: useUndecorated         => sphericalHeatedUseUndecorated
  end type massDistributionSphericalHeated

  interface massDistributionSphericalHeated
     !!{
     Constructors for the {\normalfont \ttfamily sphericalHeated} mass distribution class.
     !!}
     module procedure sphericalHeatedConstructorParameters
     module procedure sphericalHeatedConstructorInternal
  end interface massDistributionSphericalHeated

  ! Global variables used in root solving.
  double precision                                           :: radiusFinal_
  class           (massDistributionSphericalHeated), pointer :: self_
  !$omp threadprivate(radiusFinal_,self_)

contains

  function sphericalHeatedConstructorParameters(parameters) result(self)
    !!{
    Constructor for the {\normalfont \ttfamily sphericalHeated} mass distribution class which builds the object from a parameter
    set.
    !!}
    use :: Input_Parameters          , only : inputParameters
    use :: Galactic_Structure_Options, only : enumerationComponentTypeEncode, enumerationMassTypeEncode
    implicit none
    type (massDistributionSphericalHeated)                :: self
    type (inputParameters                ), intent(inout) :: parameters
    class(massDistributionClass          ), pointer       :: massDistribution_
    class(massDistributionHeatingClass   ), pointer       :: massDistributionHeating_
    type (varying_string                 )                :: nonAnalyticSolver            , componentType, &
         &                                                   massType
    logical                                               :: tolerateVelocityMaximumFailure
    
    !![
    <inputParameter>
      <name>nonAnalyticSolver</name>
      <defaultValue>var_str('fallThrough')</defaultValue>
      <source>parameters</source>
      <description>Selects how solutions are computed when no analytic solution is available. If set to ``{\normalfont \ttfamily fallThrough}'' then the solution ignoring heating is used, while if set to ``{\normalfont \ttfamily numerical}'' then numerical solvers are used to find solutions.</description>
    </inputParameter>
    <inputParameter>
      <name>componentType</name>
      <defaultValue>var_str('unknown')</defaultValue>
      <description>The component type that this mass distribution represents.</description>
      <source>parameters</source>
    </inputParameter>
    <inputParameter>
      <name>massType</name>
      <defaultValue>var_str('unknown')</defaultValue>
      <description>The mass type that this mass distribution represents.</description>
      <source>parameters</source>
    </inputParameter>
    <inputParameter>
      <name>tolerateVelocityMaximumFailure</name>
      <defaultValue>.false.</defaultValue>
      <description>If true, tolerate failures to find the radius of the peak in the rotation curve.</description>
      <source>parameters</source>
    </inputParameter>
    <objectBuilder class="massDistribution"        name="massDistribution_"        source="parameters"/>
    <objectBuilder class="massDistributionHeating" name="massDistributionHeating_" source="parameters"/>
    !!]
    select type (massDistribution_)
    class is (massDistributionSpherical)
       self=massDistributionSphericalHeated(enumerationNonAnalyticSolversEncode(char(nonAnalyticSolver),includesPrefix=.false.),tolerateVelocityMaximumFailure,massDistribution_,massDistributionHeating_,enumerationComponentTypeEncode(componentType,includesPrefix=.false.),enumerationMassTypeEncode(massType,includesPrefix=.false.))
    class default
       call Error_Report('a spherically-symmetric mass distribution is required'//{introspection:location})
    end select
    !![
    <inputParametersValidate source="parameters"/>
    <objectDestructor name="massDistribution_"       />
    <objectDestructor name="massDistributionHeating_"/>
    !!]
    return
  end function sphericalHeatedConstructorParameters
  
  function sphericalHeatedConstructorInternal(nonAnalyticSolver,tolerateVelocityMaximumFailure,massDistribution_,massDistributionHeating_,componentType,massType) result(self)
    !!{
    Constructor for ``sphericalHeated'' mass distribution class.
    !!}
    implicit none
    type            (massDistributionSphericalHeated  )                          :: self
    class           (massDistributionSpherical        ), intent(in   ), target   :: massDistribution_
    class           (massDistributionHeatingClass     ), intent(in   ), target   :: massDistributionHeating_
    type            (enumerationNonAnalyticSolversType), intent(in   )           :: nonAnalyticSolver
    logical                                            , intent(in   )           :: tolerateVelocityMaximumFailure
    type            (enumerationComponentTypeType     ), intent(in   ), optional :: componentType
    type            (enumerationMassTypeType          ), intent(in   ), optional :: massType
    double precision                                   , parameter               :: toleranceAbsolute             =0.0d0, toleranceRelative=1.0d-6
    !![
    <constructorAssign variables="nonAnalyticSolver, tolerateVelocityMaximumFailure, *massDistribution_, *massDistributionHeating_, componentType, massType"/>
    !!]
 
    self%      componentType=self%massDistribution_%componentType
    self%           massType=self%massDistribution_%     massType
    self%radiusFinalPrevious=-huge(0.0d0)
    self%finder             =rootFinder(                                     &
         &                              rootFunction     =radiusInitialRoot, &
         &                              toleranceAbsolute=toleranceAbsolute, &
         &                              toleranceRelative=toleranceRelative  &
         &                             )
    self%dimensionless      =.false.
    return
  end function sphericalHeatedConstructorInternal

  subroutine sphericalHeatedDestructor(self)
    !!{
    Destructor for the ``sphericalHeated'' mass distribution class.
    !!}
    implicit none
    type(massDistributionSphericalHeated), intent(inout) :: self

    !![
    <objectDestructor name="self%massDistribution_"       />
    <objectDestructor name="self%massDistributionHeating_"/>
    !!]
    return
  end subroutine sphericalHeatedDestructor

  logical function sphericalHeatedUseUndecorated(self) result(useUndecorated)
    !!{
    Determines whether to use the undecorated solution.
    !!}
    implicit none
    class(massDistributionSphericalHeated), intent(inout) :: self

    useUndecorated=self%nonAnalyticSolver == nonAnalyticSolversFallThrough .or. self%massDistributionHeating_%specificEnergyIsEverywhereZero()
    return
  end function sphericalHeatedUseUndecorated
  
  double precision function sphericalHeatedDensity(self,coordinates) result(density)
    !!{
    Return the density at the specified {\normalfont \ttfamily coordinates} in a scaled spherical mass distribution.
    !!}
    use :: Coordinates                     , only : coordinateSpherical            , assignment(=)
    use :: Numerical_Constants_Math        , only : Pi
    use :: Numerical_Constants_Astronomical, only : gravitationalConstantGalacticus
    implicit none
    class           (massDistributionSphericalHeated), intent(inout) :: self
    class           (coordinate                     ), intent(in   ) :: coordinates
    type            (coordinateSpherical            )                :: coordinatesInitial
    double precision                                                 :: radius            , radiusInitial, &
         &                                                              densityInitial    , massEnclosed , &
         &                                                              jacobian
    
    if (self%massDistributionHeating_%specificEnergyIsEverywhereZero()) then
       ! No heating, the density is unchanged.
       density=+self%massDistribution_%density(coordinates)
       return
    end if
    radius            =coordinates           %rSpherical   (                  )
    radiusInitial     =self                  %radiusInitial(radius            )
    coordinatesInitial=[radiusInitial,0.0d0,0.0d0]
    densityInitial    =self%massDistribution_%density      (coordinatesInitial)
    if (radius == 0.0d0 .and. radiusInitial == 0.0d0) then
       ! At zero radius, the density is unchanged.
       density     =+densityInitial
    else if (.not.self%noShellCrossingIsValid(radiusInitial,radius)) then
       ! Shell crossing assumption is broken - simply return the density unchanged.
       density     =+self%massDistribution_%density             (coordinates  )
    else
       massEnclosed=+self%massDistribution_%massEnclosedBySphere(radiusInitial)
       if (massEnclosed > 0.0d0) then
          jacobian=+1.0d0                                                                                             &
               &   /(                                                                                                 &
               &     +(                                                                                               &
               &       +radius                                                                                        &
               &       /radiusInitial                                                                                 &
               &      )                                                                                           **2 &
               &     +2.0d0                                                                                           &
               &     *radius                                                                                      **2 &
               &     /gravitationalConstantGalacticus                                                                 &
               &     /massEnclosed                                                                                    &
               &     *(                                                                                               &
               &       +self%massDistributionHeating_%specificEnergyGradient(radiusInitial,self%massDistribution_)    &
               &       -4.0d0                                                                                         &
               &       *Pi                                                                                            &
               &       *radiusInitial                                                                             **2 &
               &       *densityInitial                                                                                &
               &       *self%massDistributionHeating_%specificEnergy        (radiusInitial,self%massDistribution_)    &
               &       /massEnclosed                                                                                  &
               &      )                                                                                               &
               &    )
          density =+densityInitial                                                                                    &
               &   *(                                                                                                 &
               &     +radiusInitial                                                                                   &
               &     /radius                                                                                          &
               &    )                                                                                             **2 &
               &   *jacobian
       else
          density    =+densityInitial
       end if
    end if
    return
  end function sphericalHeatedDensity

  double precision function sphericalHeatedMassEnclosedBySphere(self,radius) result(mass)
    !!{
    Computes the mass enclosed within a sphere of given {\normalfont \ttfamily radius} for a heated mass distributions.
    !!}
    implicit none
    class           (massDistributionSphericalHeated), intent(inout), target :: self
    double precision                                 , intent(in   )         :: radius

    mass=self%massDistribution_%massEnclosedBySphere(self%radiusInitial(radius))
    return
  end function sphericalHeatedMassEnclosedBySphere
  
  double precision function sphericalHeatedRadiusInitial(self,radiusFinal) result(radiusInitial)
    !!{
    Find the initial radius corresponding to the given {\normalfont \ttfamily radiusFinal} in
    the heated mass distribution.
    !!}
    use :: Root_Finder, only : rangeExpandMultiplicative, rangeExpandSignExpectNegative, rangeExpandSignExpectPositive
    implicit none
    class           (massDistributionSphericalHeated), intent(inout), target  :: self
    double precision                                 , intent(in   )          :: radiusFinal
    double precision                                 , parameter              :: epsilonExpand=1.0d-2
    double precision                                                          :: factorExpand
    
    ! If profile is unheated, the initial radius equals the final radius.
    if (self%massDistributionHeating_%specificEnergyIsEverywhereZero()) then
       radiusInitial=radiusFinal
       return
    end if
    ! Zero radius always remains at zero.
    if (radiusFinal <= 0.0d0) then
       radiusInitial=0.0d0
       return
    end if
    ! Find the initial radius in the unheated profile.
    if (radiusFinal /= self%radiusFinalPrevious) then
       self_        => self
       radiusFinal_ =  radiusFinal
       if (self%radiusFinalPrevious <= -huge(0.0d0) .or. radiusFinal < self%radiusInitialPrevious .or. radiusFinal > 10.0d0*self%radiusInitialPrevious) then
          ! No previous solution is available, or the requested final radius is smaller than the previous initial radius, or the
          ! final radius is much larger than the previous initial radius. In this case, our guess for the initial radius is the
          ! final radius, and we expand the range downward to find a solution.
          call self%finder%rangeExpand(                                                             &
               &                       rangeExpandUpward            =1.01d0                       , &
               &                       rangeExpandDownward          =0.50d0                       , &
               &                       rangeExpandDownwardSignExpect=rangeExpandSignExpectNegative, &
               &                       rangeExpandUpwardSignExpect  =rangeExpandSignExpectPositive, &
               &                       rangeExpandType              =rangeExpandMultiplicative      &
               &                      )
          self%radiusInitialPrevious=self%finder%find(rootGuess=radiusFinal)
       else
          ! Previous solution exists, and the requested final radius is larger (but not too much larger) than the previous initial
          ! radius. Use the previous initial radius as a guess for the solution, with range expansion in steps determined by the
          ! relative values of the current and previous final radii. If the current final radius is close to the previous final
          ! radius this should give a guess for the initial radius close to the actual solution.
          if (radiusFinal > self%radiusFinalPrevious) then
             factorExpand=     radiusFinal        /self%radiusFinalPrevious
          else
             factorExpand=self%radiusFinalPrevious/     radiusFinal
          end if
          factorExpand=max(factorExpand,1.0d0+epsilonExpand)
          call self%finder%rangeExpand(                                                             &
               &                       rangeExpandUpward            =1.0d0*factorExpand           , &
               &                       rangeExpandDownward          =1.0d0/factorExpand           , &
               &                       rangeExpandDownwardSignExpect=rangeExpandSignExpectNegative, &
               &                       rangeExpandUpwardSignExpect  =rangeExpandSignExpectPositive, &
               &                       rangeExpandType              =rangeExpandMultiplicative      &
               &                      )
          self%radiusInitialPrevious=self%finder%find(rootGuess=self%radiusInitialPrevious)
       end if       
       self%radiusFinalPrevious=radiusFinal
    end if
    radiusInitial=self%radiusInitialPrevious
    return
  end function sphericalHeatedRadiusInitial
  
  double precision function radiusInitialRoot(radiusInitial)
    !!{
    Root function used in finding initial radii in heated mass distributions.
    !!}
    use :: Numerical_Constants_Astronomical, only : gravitationalConstantGalacticus
    implicit none
    double precision, intent(in   ) :: radiusInitial
    double precision, parameter     :: fractionRadiusSmall=1.0d-3
    double precision                :: massEnclosed
    
    if (radiusInitial < fractionRadiusSmall*radiusFinal_) then
       ! The initial radius is a small fraction of the final radius. Check if the assumption of no shell crossing is locally
       ! broken. If the gradient of the heating term is less than that of the gravitational potential term then it is likely that
       ! no root exists. In this case shell crossing is likely to be occurring. Simply return a value of zero, which places the
       ! root at the current radius.
       if (.not.self_%noShellCrossingIsValid(radiusInitial,radiusFinal_)) then
          radiusInitialRoot=0.0d0
          return
       end if
    end if
    massEnclosed     =+self_%massDistribution_                         %massEnclosedBySphere(radiusInitial                        )
    radiusInitialRoot=+self_                  %massDistributionHeating_%specificEnergy      (radiusInitial,self_%massDistribution_) &
         &            +0.5d0                                                                                                        &
         &            *gravitationalConstantGalacticus                                                                              &
         &            *massEnclosed                                                                                                 &
         &            *(                                                                                                            &
         &              +1.0d0/radiusFinal_                                                                                         &
         &              -1.0d0/radiusInitial                                                                                        &
         &             )
    return
  end function radiusInitialRoot

  logical function sphericalHeatedNoShellCrossingIsValid(self,radiusInitial,radiusFinal) result(isValid)
    !!{
    Determines if the no shell crossing assumption is valid.
    !!}
    use :: Numerical_Constants_Math        , only : Pi
    use :: Numerical_Constants_Astronomical, only : gravitationalConstantGalacticus
    use :: Coordinates                     , only : coordinateSpherical            , assignment(=)
    implicit none
    class           (massDistributionSphericalHeated), intent(inout) :: self
    double precision                                 , intent(in   ) :: radiusInitial     , radiusFinal
    double precision                                                 :: massEnclosed
    type            (coordinateSpherical            )                :: coordinatesInitial

    coordinatesInitial=  [radiusInitial,0.0d0,0.0d0]
    massEnclosed      = +  self%massDistribution_                         %massEnclosedBySphere  (     radiusInitial                       )
    isValid           = +  self                  %massDistributionHeating_%specificEnergyGradient(     radiusInitial,self%massDistribution_) &
         &             >                                                                                                                     &
         &              +0.5d0                                                                                                               &
         &              *gravitationalConstantGalacticus                                                                                     &
         &              *(                                                                                                                   &
         &                +4.0d0                                                                                                             &
         &                *Pi                                                                                                                &
         &                *radiusInitial**2                                                                                                  &
         &                *self%massDistribution_%density                                        (coordinatesInitial                       ) &
         &                *(                                                                                                                 &
         &                  -1.0d0/radiusFinal                                                                                               &
         &                  +1.0d0/radiusInitial                                                                                             &
         &                 )                                                                                                                 &
         &                -massEnclosed                                                                                                      &
         &                /radiusInitial**2                                                                                                  &
         &               )
    return
  end function sphericalHeatedNoShellCrossingIsValid

  double precision function sphericalHeatedRadiusEnclosingMass(self,mass,massFractional) result(radius)
    !!{
    Computes the radius enclosing a given mass or mass fraction for heated spherical mass distributions.
    !!}
    use :: Galactic_Structure_Options      , only : radiusLarge
    use :: Numerical_Constants_Astronomical, only : gravitationalConstantGalacticus
    implicit none
    class           (massDistributionSphericalHeated), intent(inout), target   :: self
    double precision                                 , intent(in   ), optional :: mass          , massFractional
    double precision                                                           :: radiusInitial
    double precision                                                           :: energySpecific

    radiusInitial =self%massDistribution_       %radiusEnclosingMass(mass         ,     massFractional   )
    energySpecific=self%massDistributionHeating_%specificEnergy     (radiusInitial,self%massDistribution_)
    if (radiusInitial <= 0.0d0) then
       radius=+radiusLarge
    else       
       radius=+1.0d0                                                       &
            & /(                                                           &
            &   +1.0d0/radiusInitial                                       &
            &   -2.0d0/gravitationalConstantGalacticus/mass*energySpecific &
            &  )
       ! If the radius found is negative, which means the initial shell has expanded to infinity, return the largest radius.
       if (radius < 0.0d0) radius=radiusLarge
    end if
    return
  end function sphericalHeatedRadiusEnclosingMass
