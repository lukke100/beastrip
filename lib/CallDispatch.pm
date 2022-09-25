#!/usr/bin/env perl
package CallDispatch;
use Modern::Perl '2012';
our $VERSION = '0.1';

use English qw{-no_match_vars};
use Moose;

has _map => (
	is => 'rw',
	default  => sub { [] },
	init_arg => undef,
	);

sub add {
	my ($self, $func) = @ARG;
	push @{$self->_map}, $func;
	return;
}

sub apply {
	my ($self, @args) = @ARG;
	my @results;

	for (@{$self->_map}) {
		push @results, scalar $ARG->(@args);
	}

	return @results;
}

1;
