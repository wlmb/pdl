use strict;
use warnings;
use ExtUtils::MakeMaker;

our ($GSL_includes, $GSL_libs); 

sub gsl_sf_links_ok {
  my($lib,$inc) = @_;
  return defined($lib) && defined($inc) &&
  trylink('',
  << 'EOI',
#include <gsl/gsl_sf_bessel.h>
EOI
  << 'EOB', $lib, $inc);
  double x = 5.0;
  double expected = -0.17759677131433830434739701;
  double y = gsl_sf_bessel_J0 (x);
  return 0;
EOB
}

if (!gsl_sf_links_ok($GSL_libs, $GSL_includes)) {
  write_dummy_make( "Skipping build of PDL::GSLSF." );
  return;
}

WriteMakefile(
	'NAME' => 'PDL::GSLSF',
	VERSION => '0.5',
	# VERSION_FROM => '../../Basic/PDL.pm',
       #DIR =>  [ qw/airy bessel chebyshev clausen coulomb coupling dawson debye dilog elementary ellint elljac erf exp expint fermi_dirac gamma gegenbauer hyperg laguerre legendre log poly pow_int psi synchrotron transport trig zeta/ ],
	NO_MYMETA => 1,
);
