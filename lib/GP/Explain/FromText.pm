package GP::Explain::FromText;
use strict;
use Carp;
use GP::Explain::Node;

=head1 NAME

GP::Explain::FromText - Parser for text based explains

=head1 VERSION

Version 0.03

=cut

our $VERSION = '0.03';

=head1 SYNOPSIS

It's internal class to wrap some work. It should be used by GP::Explain, and not directly.

=head1 FUNCTIONS

=head2 new

Object constructor.

This is not really useful in this particular class, but it's to have the same API for all GP::Explain::From* classes.

=cut

sub new {
    my $class = shift;
    my $self = bless {}, $class;
    return $self;
}

=head2 parse_source

Function which parses actual plan, and constructs GP::Explain::Node objects
which represent it.

Returns Top node of query plan.

=cut

sub parse_source {
    my $self   = shift;
    my $source = shift;

    my $top_node         = undef;
    my %element_at_depth = ();      # element is hashref, contains 2 keys: node (GP::Explain::Node) and subelement-type, which can be: subnode, initplan or subplan.

    my @lines = split /\r?\n/, $source;

    LINE:
    for my $line ( @lines ) {

        # There could be stray " at the end. No idea why, but some people paste such explains on explain.depesz.com
        $line =~ s/"\z//;

        if (
            $line =~ m{
                \A
                (?<prefix>\s* -> \s* | \s* )
                (?<type>\S.*?)
                \s+
                \( cost=(?<estimated_startup_cost>\d+\.\d+)\.\.(?<estimated_total_cost>\d+\.\d+) \s+ rows=(?<estimated_rows>\d+) \s+ width=(?<estimated_row_width>\d+) \)
                (?:
                    \s+
                    \(
                        (?:
                            actual \s time=(?<actual_time_first>\d+\.\d+)\.\.(?<actual_time_last>\d+\.\d+) \s rows=(?<actual_rows>\d+) \s loops=(?<actual_loops>\d+)
                            |
                            actual \s rows=(?<actual_rows>\d+) \s loops=(?<actual_loops>\d+)
                            |
                            (?<never_executed> never \s+ executed )
                        )
                    \)
                )?
                \s*
                \z
            }xms
           )
        {
            my $new_node = GP::Explain::Node->new( %+ );
            if ( defined $+{ 'never_executed' } ) {
                $new_node->actual_loops( 0 );
                $new_node->never_executed( 1 );
            }
            my $element = { 'node' => $new_node, 'subelement-type' => 'subnode', };

            my $prefix_length = length $+{ 'prefix' };

            if ( 0 == scalar keys %element_at_depth ) {
                $element_at_depth{ $prefix_length } = $element;
                $top_node = $new_node;
                next LINE;
            }
            my @existing_depths = sort { $a <=> $b } keys %element_at_depth;
            for my $key ( grep { $_ >= $prefix_length } @existing_depths ) {
                delete $element_at_depth{ $key };
            }

            my $maximal_depth = ( sort { $b <=> $a } keys %element_at_depth )[ 0 ];
            my $previous_element = $element_at_depth{ $maximal_depth };

            $element_at_depth{ $prefix_length } = $element;

            if ( $previous_element->{ 'subelement-type' } eq 'subnode' ) {
                $previous_element->{ 'node' }->add_sub_node( $new_node );
            }
            elsif ( $previous_element->{ 'subelement-type' } eq 'initplan' ) {
                $previous_element->{ 'node' }->add_initplan( $new_node );
            }
            elsif ( $previous_element->{ 'subelement-type' } eq 'subplan' ) {
                $previous_element->{ 'node' }->add_subplan( $new_node );
            }
            elsif ( $previous_element->{ 'subelement-type' } =~ /^cte:(.+)$/ ) {
                $previous_element->{ 'node' }->add_cte( $1, $new_node );
                delete $element_at_depth{ $maximal_depth };
            }
            else {
                my $msg = "Bad subelement-type in previous_element - this shouldn't happen - please contact author.\n";
                croak( $msg );
            }

        }
        elsif ( $line =~ m{ \A (\s*) ((?:Sub|Init)Plan) \s* (?: \d+ \s* )? \s* (?: \( returns .* \) \s* )? \z }xms ) {
            my ( $prefix, $type ) = ( $1, $2 );

            my @remove_elements = grep { $_ >= length $prefix } keys %element_at_depth;
            delete @element_at_depth{ @remove_elements } unless 0 == scalar @remove_elements;

            my $maximal_depth = ( sort { $b <=> $a } keys %element_at_depth )[ 0 ];
            my $previous_element = $element_at_depth{ $maximal_depth };

            $element_at_depth{ length $prefix } = {
                'node'            => $previous_element->{ 'node' },
                'subelement-type' => lc $type,
            };
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) CTE \s+ (\S+) \s* \z }xms ) {
            my ( $prefix, $cte_name ) = ( $1, $2 );

            my @remove_elements = grep { $_ >= length $prefix } keys %element_at_depth;
            delete @element_at_depth{ @remove_elements } unless 0 == scalar @remove_elements;

            my $maximal_depth = ( sort { $b <=> $a } keys %element_at_depth )[ 0 ];
            my $previous_element = $element_at_depth{ $maximal_depth };

            $element_at_depth{ length $prefix } = {
                'node'            => $previous_element->{ 'node' },
                'subelement-type' => 'cte:' . $cte_name,
            };

            next LINE;
        }
       #"Rows out:  0 rows (seg0) with 21 ms to end, start offset by 24 ms."
        elsif ( $line =~ m{
                  \A
                  (\s*) Rows \s out: \s*
                  (?:
                    Avg \s (?<rows_out_avg_rows>\S+) \s rows \s x \s (?<rows_out_workers>\S+) \s workers \s at \s destination\.
                   |
                    Avg \s (?<rows_out_avg_rows>\S+) \s rows \s x \s (?<rows_out_workers>\S+) \s workers\.
                   |
                    (?<rows_out_count>\S+) \s rows \s at \s destination
                   |
                    (?<rows_out_count>\S+) \s rows \s \( (?<rows_out_max_rows_segment>\S+?) \) 
                   |
                    (?<rows_out_count>\S+) \s rows
                  )
                  \s*
                  (?:
                    Max \s (?<rows_out_max_rows>\S+) \s rows \s \( (?<rows_out_max_rows_segment>\S+?) \) \s
                    with \s (?<rows_out_ms_to_first_row>\S+?) \s ms \s to \s first \s row, \s (?<rows_out_ms_to_end>\S+?) \s ms \s to \s end, \s
                    start \s offset \s by \s (?<rows_out_offset>\S+) \s ms\.
                   |
                    Max \s (?<rows_out_max_rows>\S+) \s rows \s \( (?<rows_out_max_rows_segment>\S+?) \) \s
                    with \s (?<rows_out_ms_to_end>\S+?) \s ms \s to \s end, \s
                    start \s offset \s by \s (?<rows_out_offset>\S+) \s ms\.
                   |
                    with \s (?<rows_out_ms_to_first_row>\S+?) \s ms \s to \s first \s row, \s (?<rows_out_ms_to_end>\S+?) \s ms \s to \s end, \s
                    start \s offset \s by \s (?<rows_out_offset>\S+) \s ms\.
                   |
                    with \s (?<rows_out_ms_to_end>\S+?) \s ms \s to \s end, \s
                    start \s offset \s by \s (?<rows_out_offset>\S+) \s ms\.
                  )
                  \s* \z
                }xms
              ) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{
                  \A
                  (\s*) Rows \s in: \s*
                  (?:
                    Avg \s (?<rows_in_avg_rows>\S+) \s rows \s x \s (?<rows_in_workers>\S+) \s workers\.
                  )
                  \s*
                  (?:
                    Max \s (?<rows_in_max_rows>\S+) \s rows \s \( (?<rows_in_max_rows_segment>\S+?) \) \s
                    with \s (?<rows_in_ms_to_end>\S+?) \s ms \s to \s end, \s
                    start \s offset \s by \s (?<rows_in_offset>\S+) \s ms\.
                  )
                  \s* \z
                }xms
              ) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Work_mem \s used: \s*
                            (?<work_mem_bytes_avg>\S+) \s bytes \s avg, \s 
                            (?<work_mem_bytes_max>\S+) \s bytes \s max \s 
                            \( (?<work_mem_bytes_max_segment>\S+) \) \. \s* 
                            Workfile: \s* \( (?<workfile_number_spilling>\S+) \s spilling, \s
                            (?<workfile_number_reused>\S+) \s reused \) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Executor \s memory: \s* (?<executor_bytes_avg>\S+) \s bytes \s avg, \s (?<executor_bytes_max>\S+) \s 
                            bytes \s max \s \( (?<executor_bytes_max_segment>\S+?) \) \. \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Hash \s Cond: \s* (?<hash_condition>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Index \s Cond: \s* (?<index_condition>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Hash \s Key: \s* (?<hash_key>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Merge \s Key: \s* (?<merge_key>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Merge \s Cond: \s* (?<merge_cond>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Partition \s By: \s* (?<partition_by>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Order \s By: \s* (?<order_by>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Filter: \s* (?<filter>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Join \s Filter: \s* (?<filter>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Group \s By: \s* (?<group_by>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Sort \s Key \s \( Distinct \): \s* (?<sort_key_distinct>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Sort \s Key \s \( Limit \): \s* (?<sort_key_limit>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) Sort \s Key\: \s* (?<sort_key>\S .* \S ) \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) \( (seg\S+?) \) \s* Hash \s chain \s length \s (?<hash_chain_length_avg>\S+) \s avg,
                            \s (?<hash_chain_length_max>\S+) \s max, \s using \s (?<hash_chain_buckets_used>\S+)
                            \s of \s (?<hash_chain_buckets>\S+) \s buckets\. \s* \z }xms) {
            my ( $prefix ) = ( $1 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $prefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            $previous_element->{ 'node' }->add_additional_info( %+ );
            next LINE;
        }
        elsif ( $line =~ m{ \A (\s*) ( \S .* \S ) \s* \z }xms ) {
            my ( $infoprefix, $info ) = ( $1, $2 );
            my $maximal_depth = ( sort { $b <=> $a } grep { $_ < length $infoprefix } keys %element_at_depth )[ 0 ];
            next LINE unless defined $maximal_depth;
            my $previous_element = $element_at_depth{ $maximal_depth };
            next LINE unless $previous_element;
            $previous_element->{ 'node' }->add_extra_info( $info );
        }
    }
    return $top_node;
}

=head1 AUTHOR

scott kahler <scott.kahler@gmail.com>

=head1 BUGS

Please report any bugs or feature requests to <scott.kahler@gmail.com>.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc GP::Explain

=head1 COPYRIGHT & LICENSE

Copyright 2015 scott kahler, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;    # End of GP::Explain::FromText
