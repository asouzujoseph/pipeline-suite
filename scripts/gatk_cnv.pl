#!/usr/bin/env perl
### gatk_cnv.pl ####################################################################################
use AutoLoader 'AUTOLOAD';
use strict;
use warnings;
use version;
use Carp;
use Getopt::Std;
use Getopt::Long;
use POSIX qw(strftime);
use File::Basename;
use File::Path qw(make_path);
use YAML qw(LoadFile);
use List::Util qw(any min);
use IO::Handle;

my $cwd = dirname(__FILE__);
require "$cwd/utilities.pl";

# define some global variables
our ($reference, $dictionary, $intervals_bed, $gnomad, $min_length) = undef;

####################################################################################################
# version	author		comment
# 1.0		sprokopec	script to run GATKs CNV caller

### USAGE ##########################################################################################
# gatk_cnv.pl -t tool.yaml -d data.yaml -o /path/to/output/dir -c slurm --remove --dry_run
#
# where:
# 	-t (tool.yaml) contains tool versions and parameters, reference information, etc.
# 	-d (data.yaml) contains sample information (YAML file containing paths to BWA-aligned,
# 	GATK-processed BAMs, generated by gatk.pl)
# 	-o (/path/to/output/dir) indicates tool-specific output directory
# 	-c indicates hpc driver (ie, slurm)
# 	--remove indicates that intermediates will be removed
# 	--dry_run indicates that this is a dry run

### DEFINE SUBROUTINES #############################################################################
# format command to run PreprocessIntervals
sub get_format_intervals_command {
	my %args = (
		is_wgs		=> 0,
		intervals	=> undef,
		gc_out		=> undef,
		output		=> undef,
		@_
		);

	my $gatk_command;

	if (! $args{is_wgs}) {
		$gatk_command .= "\n\n" . join(' ',
			'gatk PreprocessIntervals', # by default, this adds 250bp padding to each interval
			'-L', $args{intervals},
			'-R', $reference,
			'--bin-length 0',
			'--padding 250',
			'--interval-merging-rule OVERLAPPING_ONLY',
			'-O', $args{output}
			);

		} else {

		$gatk_command .= "\n\n" . join(' ',
			'gatk PreprocessIntervals',
			'-L', $args{intervals},
			'-R', $reference,
			'--bin-length 1000',
			'--padding 0',
			'--interval-merging-rule OVERLAPPING_ONLY',
			'-O', $args{output}
			);
		}

	$gatk_command .= "\n\n" . join(' ',
		'gatk AnnotateIntervals',
		'-L', $args{output},
		'--interval-merging-rule OVERLAPPING_ONLY',
		'-R', $reference,
		'-O', $args{gc_out}
		);

	return($gatk_command);
	}

# format command to run PreprocessIntervals
sub get_format_gnomad_command {
	my %args = (
		input_vcf	=> undef,
		intervals	=> undef,
		output_stem	=> undef,
		wgs		=> 0,
		chrom_list	=> undef,
		@_
		);

	my $gatk_command = join(' ',
		'gatk SelectVariants',
		'-V', $args{input_vcf},
		'-L', $args{intervals},
		'-O', $args{output_stem} . '.vcf',
		'--exclude-non-variants true --keep-original-ac true',
		'--select-type-to-include SNP',
		'--restrict-alleles-to BIALLELIC'
		);

	if ($args{wgs}) {
		$gatk_command .= " --select 'AF > 0.0001'";
		}

	$gatk_command .= "\n\n" . join("\n",
		"bgzip $args{output_stem}.vcf",
		"tabix -p vcf $args{output_stem}.vcf.gz"
		);

	if ($args{wgs}) {

		$gatk_command .= "\n\n" . join("\n",
			"for chr in $args{chrom_list}; do",
			join(' ',
				'  bcftools filter -r $chr -O v -o',
				$args{output_stem} . '_minAF_$chr.vcf',
				"$args{output_stem}.vcf.gz"
				),
			join(' ',
				'  java -Xmx7g -jar $picard_dir/picard.jar VcfToIntervalList',
				"I=$args{output_stem}" . '_minAF_$chr.vcf',
				"O=$args{output_stem}" . '_minAF_$chr.interval_list'
				),
			"  rm $args{output_stem}" . '_minAF_$chr.vcf',
			'done'
			);
		}

	$gatk_command .= "\n\n" . join(' ',
		"echo 'Finished formatting gnomAD intervals.'", '>', "$args{output_stem}.COMPLETE"
		);

	return($gatk_command);
	}

# format command to run CollectReadCounts
sub get_readcounts_command {
	my %args = (
		input		=> undef,
		intervals	=> undef,
		output		=> undef,
		@_
		);

	my $gatk_command = join(' ',
		'gatk CollectReadCounts',
		'-I', $args{input},
		'-O', $args{output},
		'-R', $reference,
		'-L', $args{intervals},
		'--interval-merging-rule OVERLAPPING_ONLY'
		);

	return($gatk_command);	
	}

# format command to run CreateReadCountPanelOfNormals
sub get_create_pon_command {
	my %args = (
		input		=> undef,
		output		=> undef,
		gc_intervals	=> undef,
		java_mem	=> undef,
		@_
		);

	my $gatk_command = join(' ',
		'gatk --java-options "-Xmx' . $args{java_mem} . '" CreateReadCountPanelOfNormals',
		'-I', $args{input},
		'--minimum-interval-median-percentile 5.0',
		'--annotated-intervals', $args{gc_intervals},
		'-O', $args{output}
		);

	$gatk_command .= "\n\n" . join(' ',
		"echo 'Finished PoN creation.'", '>', "$args{output}.COMPLETE"
		);

	return($gatk_command);
	}

# format command to run DenoiseReadCounts
sub get_denoise_command {
	my %args = (
		input		=> undef,
		pon		=> undef,
		output_stem	=> undef,
		java_mem	=> undef,
		@_
		);

	my $gatk_command = join(' ',
		'gatk --java-options "-Xmx' . $args{java_mem} . '" DenoiseReadCounts',
		'-I', $args{input},
		'--count-panel-of-normals', $args{pon},
		'--standardized-copy-ratios', $args{output_stem} . '_standardizedCR.tsv',
		'--denoised-copy-ratios', $args{output_stem} . '_denoisedCR.tsv'
		);

	return($gatk_command);
	}

# format command to run PlotDenoisedCopyRatios
sub get_plot_denoise_command {
	my %args = (
		input_stem	=> undef,
		plot_dir	=> undef,
		output_stem	=> undef,
		@_
		);

	my $gatk_command = 'module unload openblas/0.3.13';
	$gatk_command .= "\nmodule load R";

	$gatk_command .= "\n\n" . join(' ',
		'gatk PlotDenoisedCopyRatios',
		'--standardized-copy-ratios', $args{input_stem} . '_standardizedCR.tsv',
		'--denoised-copy-ratios', $args{input_stem} . '_denoisedCR.tsv',
		'--sequence-dictionary', $dictionary,
		'--minimum-contig-length', $min_length, # minimum primary chr length from dictionary
		'--output', $args{plot_dir},
		'--output-prefix', $args{output_stem}
		);

	return($gatk_command);
	}

# format command to run CollectAllelicCounts
sub get_allele_counts_command {
	my %args = (
		input		=> undef,
		intervals	=> undef,
		output		=> undef,
		java_mem	=> undef,
		wgs		=> 0,
		chrom_list	=> undef,
		@_
		);

	my $gatk_command;

	if (!$args{wgs}) {

		$gatk_command = join(' ',
			'gatk --java-options "-Xmx' . $args{java_mem} . '" CollectAllelicCounts',
			'-L', $args{intervals},
			'-I', $args{input},
			'-R', $reference,
			'-O', $args{output}
			);

	} elsif ($args{wgs}) {

		$gatk_command = join("\n",
			"for CHR in $args{chrom_list}; do",
			join(' ',
				'  gatk --java-options "-Xmx' . $args{java_mem} . '" CollectAllelicCounts',
				'-L', $args{intervals},
				'-I', $args{input},
				'-R', $reference,
				'-O', $args{output} . '_$CHR'
				),
			'done'
			);

		$gatk_command .= "\n\n" . join(' ',
			"grep -e '\@' -e 'CONTIG'",
			$args{output} . '_$CHR',
			'>', $args{output} . '.header'
			);
		$gatk_command .= "\n\n" . join(' ',
			"cat $args{output}_*",
			"| grep -v -e '\@' -e 'CONTIG'",
			"| sort -k1,1V -k2,2n > $args{output}.sorted"
			);
		$gatk_command .= "\n\n" . join(' ',
			'cat', $args{output} . '.header', $args{output} . '.sorted',
			'>', $args{output}
			);
		$gatk_command .= "\n\n" . "rm $args{output}.sorted;\nrm $args{output}.header;\nrm $args{output}_*;";
		}

	return($gatk_command);
	}

# format command to run ModelSegments
sub get_modelsegments_command {
	my %args = (
		input_stem	=> undef,
		normal_counts	=> undef,
		output_dir	=> undef,
		output_stem	=> undef,
		java_mem	=> undef,
		seq_type	=> undef,
		@_
		);

	my $gatk_command = join(' ',
		'gatk --java-options "-Xmx' . $args{java_mem} . '" ModelSegments',
		'--denoised-copy-ratios', $args{input_stem} . '_denoisedCR.tsv',
		'--allelic-counts', $args{input_stem} . '_allelicCounts.tsv',
		'--output', $args{output_dir},
		'--output-prefix', $args{output_stem}
		);

	if (('exome' eq $args{seq_type}) || ('targeted' eq $args{seq_type})) {
		$gatk_command .= ' --number-of-smoothing-iterations-per-fit 1';
		} elsif ('wgs' eq $args{seq_type}) {
		$gatk_command .= ' --number-of-changepoints-penalty-factor 2.0 --number-of-smoothing-iterations-per-fit 1';
		}

	if ($args{normal_counts}) {
		$gatk_command .= " --normal-allelic-counts $args{normal_counts}";
		}

	$gatk_command .= "\n\n" . join(' ',
		'gatk CallCopyRatioSegments',
		'--input', join('/', $args{output_dir}, $args{output_stem} . '.cr.seg'),
		'--output', join('/', $args{output_dir},  $args{output_stem} . '.called.seg')
		);

	return($gatk_command);
	}

# format command to run PlotModeledSegments
sub get_plot_segments_command {
	my %args = (
		input_stem	=> undef,
		plot_dir	=> undef,
		output_stem	=> undef,
		@_
		);

	my $gatk_command = 'module unload openblas/0.3.13';
	$gatk_command .= "\nmodule load R";

	$gatk_command .= "\n\n" . join(' ',
		'gatk PlotModeledSegments',
		'--denoised-copy-ratios', $args{input_stem} . '_denoisedCR.tsv',
		'--allelic-counts', $args{input_stem} . '.hets.tsv',
		'--segments', $args{input_stem} . '.modelFinal.seg',
		'--sequence-dictionary', $dictionary,
		'--minimum-contig-length', $min_length, # minimum primary chr length from dictionary
		'--output', $args{plot_dir},
		'--output-prefix', $args{output_stem}
		);

	return($gatk_command);
	}

### MAIN ###########################################################################################
sub main {
	my %args = (
		tool_config		=> undef,
		data_config		=> undef,
		output_directory	=> undef,
		hpc_driver		=> undef,
		del_intermediates	=> undef,
		dry_run			=> undef,
		no_wait			=> undef,
		@_
		);

	my $tool_config = $args{tool_config};
	my $data_config = $args{data_config};

	### PREAMBLE ######################################################################################
	unless($args{dry_run}) {
		print "Initiating GATK:CNV pipeline...\n";
		}

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'gatk');
	my $date = strftime "%F", localtime;

	my $needed = version->declare('4.1')->numify;
	my $given = version->declare($tool_data->{gatk_cnv_version})->numify;

	if ($given < $needed) {
		die("Incompatible GATK version requested! GATK-CNV pipeline is currently only compatible with GATK >4.1");
		}

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_GATK-CNV_pipeline.log');

	# create a file to hold job metrics
	my (@files, $run_count, $outfile, $touch_exit_status);
	unless ($args{dry_run}) {
		# initiate a file to hold job metrics
		opendir(LOGFILES, $log_directory) or die "Cannot open $log_directory";
		@files = grep { /slurm_job_metrics/ } readdir(LOGFILES);
		$run_count = scalar(@files) + 1;
		closedir(LOGFILES);

		$outfile = $log_directory . '/slurm_job_metrics_' . $run_count . '.out';
		$touch_exit_status = system("touch $outfile");
		if (0 != $touch_exit_status) { Carp::croak("Cannot touch file $outfile"); }

		$log_file = join('/', $log_directory, 'run_GATK-CNV_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running GATKs CNV pipeline.\n";
	print $log "\n  Tool config used: $tool_config";

	$reference = $tool_data->{reference};
	$dictionary = $reference;
	$dictionary =~ s/.fa/.dict/;
	print $log "\n    Reference used: $tool_data->{reference}";

	if ( (('exome' eq $tool_data->{seq_type}) || ('targeted' eq $tool_data->{seq_type})) &&
		(defined($tool_data->{intervals_bed}))) {
		$intervals_bed = $tool_data->{intervals_bed};
		print $log "\n    Target intervals (exome): $intervals_bed";
		}

	my $is_wgs = 0;
	if ('wgs' eq $tool_data->{seq_type}) {
		$is_wgs = 1;
		$tool_data->{intervals_bed} = undef;
		}

	if (defined($tool_data->{gnomad})) {
		$gnomad = $tool_data->{gnomad};
		print $log "\n    gnomAD SNPs: $tool_data->{gnomad}";
		} else {
		die("No gnomAD file provided; please provide path to gnomAD VCF");
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---\n";

	# set tools and versions
	my $gatk	= 'gatk/' . $tool_data->{gatk_cnv_version};
	my $picard	= 'picard/' . $tool_data->{picard_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};
	my $r_version	= 'R/' . $tool_data->{r_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{gatk_cnv}->{parameters};

	# get optional HPC group
	my $hpc_group = defined($tool_data->{hpc_group}) ? "-A $tool_data->{hpc_group}" : undef;

	######################
	### CHECK REGIONS ####
	# read in sequence dictionary to identify smallest contig of interest
	my $string;
	if (defined($tool_data->{gatk_cnv}->{chromosomes})) {
		$string = $tool_data->{gatk_cnv}->{chromosomes};
		} elsif ( ('hg38' eq $tool_data->{ref_type}) || ('hg19' eq $tool_data->{ref_type})) {
		$string = 'chr' . join(',chr', 1..22) . ',chrX,chrY';
		} elsif ( ('GRCh37' eq $tool_data->{ref_type}) || ('GRCh37' eq $tool_data->{ref_type})) {
		$string = join(',', 1..22) . ',X,Y';
		}

	my @chroms = split(',', $string);

	open(my $dict_fh, $dictionary) or die "Could not open $dictionary\n";

	my @chr_lengths;
	while (<$dict_fh>) {
		my $line = $_;
		chomp($line);

		if ($line =~ /\@SQ/) {
			my @parts = split /\t/, $line;
			my $chr = $parts[1];
			$chr =~ s/SN://;
			next if ( !any { /$chr/ } @chroms );

			my $length = $parts[2];
			$length =~ s/LN://;
			push @chr_lengths, int($length);
			}
		}

	close($dict_fh);

	$min_length = min @chr_lengths;
	######################

	### RUN ###########################################################################################
	# begin by loading sample data
	my $smp_data = LoadFile($data_config);

	unless($args{dry_run}) {
		print "Processing " . scalar(keys %{$smp_data}) . " patients.\n";
		}

	# begin by formatting intervals for gatk
	my ($run_script, $run_id, $tmp_run_id, $intervals_run_id, $intervals_run_id2, $cleanup_cmd);
	my $should_run_final;
	my @all_jobs;

	# do an initial check for normals; no normals = don't bother running
	my @has_normals;
	foreach my $patient (sort keys %{$smp_data}) {
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		if (scalar(@normal_ids) > 0) { push @has_normals, $patient; }
		}

	if (scalar(@has_normals) < 1) {
		die("Insufficient normals provided for PoN. Either increase available normals and re-run, or set gatk_cnv->{run} = N in tool config.");
		}	

	# generate processed picard-style intervals list
	my ($picard_intervals, $gatk_intervals, $gc_intervals, $format_intervals_cmd);
	my $memory = '1G';
	if (defined($intervals_bed)) {

		$picard_intervals = $intervals_bed;
		$picard_intervals =~ s/\.bed/.interval_list/;
		$gatk_intervals = join('/', $output_directory, basename($intervals_bed));
		$gatk_intervals =~ s/\.bed/.preprocessed.interval_list/;
		$gc_intervals	= $gatk_intervals;
		$gc_intervals	=~ s/\.interval_list/.gc.interval_list/;

		$format_intervals_cmd = get_format_intervals_command(
			reference	=> $reference,
			intervals	=> $picard_intervals,
			gc_out		=> $gc_intervals,
			output		=> $gatk_intervals
			);
		
		} else {

		$gatk_intervals = join('/',
			$output_directory,
			$tool_data->{ref_type} . '.preprocessed.interval_list'
			);

		$gc_intervals = join('/',
			$output_directory,
			$tool_data->{ref_type} . '.preprocessed.gc.interval_list'
			);
	
		$format_intervals_cmd = get_format_intervals_command(
			intervals	=> join(' -L ', @chroms),
			reference	=> $reference,
			gc_out		=> $gc_intervals,
			output		=> $gatk_intervals
			);

		$memory = '4G';
		}

	# check if this should be run
	if ('Y' eq missing_file($gatk_intervals)) {

		# record command (in log directory) and then run job
		print $log "Submitting job for PreprocessIntervals...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_gatk_process_intervals',
			cmd	=> $format_intervals_cmd,
			modules	=> [$gatk, $picard],
			max_time	=> '02:00:00',
			mem		=> $memory,
			hpc_driver	=> $args{hpc_driver},
			extra_args	=> [$hpc_group]
			);

		$intervals_run_id = submit_job(
			jobname		=> 'run_gatk_process_intervals', 
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $intervals_run_id;
		} else {
		print $log "Skipping PreprocessIntervals as this has already been completed!\n";
		}

	# prep common SNPs for phase 2
	my $gnomad_snps = join('/', $output_directory, 'gnomAD_filtered.vcf.gz');
	my $gnomad_directory = $output_directory;

	if ($is_wgs) {
		$gnomad_directory = join('/', $output_directory, 'gnomAD');
		unless(-e $gnomad_directory) { make_path($gnomad_directory); }
		$gnomad_snps = join('/', $gnomad_directory, 'gnomAD_filtered_minAF_$CHR.interval_list');
		$memory = '8G';
		}

	my $prep_gnomad_cmd = get_format_gnomad_command(
		input_vcf	=> $gnomad,
		intervals	=> $gatk_intervals,
		output_stem	=> join('/', $gnomad_directory, 'gnomAD_filtered'),
		wgs		=> $is_wgs,
		chrom_list	=> join(' ', @chroms)
		);

	# check if this should be run
	if ('Y' eq missing_file(join('/', $gnomad_directory,'gnomAD_filtered.COMPLETE'))) {

		# record command (in log directory) and then run job
		print $log "Submitting job for gnomAD SelectVariants...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_filter_gnomad',
			cmd	=> $prep_gnomad_cmd,
			modules	=> [$gatk, 'tabix', $samtools, $picard],
			dependencies	=> $intervals_run_id,
			max_time	=> '12:00:00',
			mem		=> $memory,
			hpc_driver	=> $args{hpc_driver},
			extra_args	=> [$hpc_group]
			);

		$intervals_run_id2 = submit_job(
			jobname		=> 'run_filter_gnomad', 
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $intervals_run_id2;
		} else {
		print $log "Skipping gnomAD SelectVariants as this has already been completed!\n";
		}

	# return to a reasonable memory
	if ($is_wgs) {
		$memory = '4G';
		}

	# initiate objects to hold key info
	my (%final_outputs, %patient_jobs);

	# prep directories for pon
	my $pon_directory = join('/', $output_directory, 'PanelOfNormals');
	unless(-e $pon_directory) { make_path($pon_directory); }

	my $pon_intermediates = join('/', $pon_directory, 'intermediate_files');
	unless(-e $pon_intermediates) { make_path($pon_intermediates); }

	my (@normal_jobs, @pon_inputs);
	print $log "\nCreating Panel of Normals:\n";

	# process each patient in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $link_directory = join('/', $patient_directory, 'bam_links');
		unless(-e $link_directory) { make_path($link_directory); }

		# create some symlinks
		foreach my $normal (@normal_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{normal}->{$normal};
			my $link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{normal}->{$normal}, $link);
			}
		foreach my $tumour (@tumour_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{tumour}->{$tumour};
			my $link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{tumour}->{$tumour}, $link);
			}

		# create an array to hold final outputs and all patient job ids
		@patient_jobs{$patient} = [];
		@final_outputs{$patient} = [];

		# collect read counts for the normal sample(s)
		foreach my $sample (@normal_ids) {

			# if there are any samples to run, we will run the final combine job
			$should_run_final = 1;

			print $log "  SAMPLE: $sample\n\n";

			# run get read counts on each normal
			my $norm_readcounts = join('/', $pon_intermediates, $sample . '.readCounts.hdf5');
			push @pon_inputs, $norm_readcounts;

			my $readcounts_cmd = get_readcounts_command(
				input		=> $smp_data->{$patient}->{normal}->{$sample},
				intervals	=> $gatk_intervals,
				output		=> $norm_readcounts
				);

			# check if this should be run
			if ('Y' eq missing_file($norm_readcounts)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for CollectReadCounts...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_collect_read_counts_' . $sample,
					cmd	=> $readcounts_cmd,
					modules	=> [$gatk],
					dependencies	=> $intervals_run_id,
					max_time	=> $parameters->{readcounts}->{time},
					mem		=> $parameters->{readcounts}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_collect_read_counts_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @{$patient_jobs{$patient}}, $run_id;
				push @normal_jobs, $run_id;
				} else {
				print $log "Skipping CollectReadCounts as this has already been completed!\n";
				}
			}
		}

	# combine normals to create a panel of normals
	my $pon_run_id = '';

	my $pon = join('/',
		$pon_directory,
		join('_', $date, $tool_data->{project_name}, 'gatk_cnv.pon.hdf5')
		);
		
	my $pon_cmd = get_create_pon_command(
		input		=> join(' -I ', @pon_inputs),
		output		=> $pon,
		gc_intervals	=> $gc_intervals,
		java_mem	=> $parameters->{create_pon}->{java_mem}
		);

	# check if this should be run
	if ('Y' eq missing_file("$pon.COMPLETE")) {

		# record command (in log directory) and then run job
		print $log "Submitting job for CreateReadCountPanelOfNormals...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_create_readcount_pon',
			cmd	=> $pon_cmd,
			modules	=> [$gatk],
			dependencies	=> join(':', @normal_jobs),
			max_time	=> $parameters->{create_pon}->{time},
			mem		=> $parameters->{create_pon}->{mem},
			hpc_driver	=> $args{hpc_driver},
			extra_args	=> [$hpc_group]
			);

		$pon_run_id = submit_job(
			jobname		=> 'run_create_readcount_pon',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $pon_run_id;
		} else {
		print $log "Skipping CreateReadCountPanelOfNormals as this has already been completed!\n";
		}

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		$cleanup_cmd = '';

		print $log "\nInitiating process for PATIENT: $patient\n";

		# find sample IDs
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		# continue processing the normal for this patient
		my $sample;
		my $norm_allelic_counts = 0;
		my $norm_run_id = '';

		if (scalar(@normal_ids) > 0) {

			$sample = $normal_ids[0];

			print $log "  SAMPLE: $sample\n\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			# run collect allelic counts
			$norm_allelic_counts = join('/', $sample_directory, $sample . '_allelicCounts.tsv');
			my $allelic_counts_cmd = get_allele_counts_command(
				input		=> $smp_data->{$patient}->{normal}->{$sample},
				intervals	=> $gnomad_snps,
				output		=> $norm_allelic_counts,
				java_mem	=> $parameters->{allele_counts}->{java_mem},
				wgs		=> $is_wgs,
				chrom_list	=> join(' ', @chroms)
				);

			# check if this should be run
			if ('Y' eq missing_file($norm_allelic_counts)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for CollectAllelicCounts...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_collect_allelic_counts_' . $sample,
					cmd	=> $allelic_counts_cmd,
					modules	=> [$gatk],
					dependencies	=> $intervals_run_id2,
					max_time	=> $parameters->{allele_counts}->{time},
					mem		=> $parameters->{allele_counts}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$norm_run_id = submit_job(
					jobname		=> 'run_collect_allelic_counts_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @{$patient_jobs{$patient}}, $run_id;
				} else {
				print $log "Skipping CollectAllelicCounts as this has already been completed!\n";
				}
			}

		# collect read counts for the tumour sample(s)
		foreach $sample (@tumour_ids) {

			print $log "  SAMPLE: $sample\n\n";

			my @sample_jobs;
			$run_id = '';

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			my $plot_directory = join('/', $sample_directory, 'plots');
			unless(-e $plot_directory) { make_path($plot_directory); }

			my $output_stem = join('/', $sample_directory, $sample);

			# run get read counts on each tumour
			my $readcounts = $output_stem . '.readCounts.hdf5';

			my $readcounts_cmd = get_readcounts_command(
				input		=> $smp_data->{$patient}->{tumour}->{$sample},
				intervals	=> $gatk_intervals,
				output		=> $readcounts
				);

			# check if this should be run
			if ('Y' eq missing_file($readcounts)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for CollectReadCounts...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_collect_read_counts_' . $sample,
					cmd	=> $readcounts_cmd,
					modules	=> [$gatk],
					dependencies	=> $intervals_run_id,
					max_time	=> $parameters->{readcounts}->{time},
					mem		=> $parameters->{readcounts}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_collect_read_counts_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @sample_jobs, $run_id;
				push @{$patient_jobs{$patient}}, $run_id;
				} else {
				print $log "Skipping CollectReadCounts as this has already been completed!\n";
				}

			# run command to get copy-number ratios
			my $denoised_cr = $output_stem . '_denoisedCR.tsv';

			my $denoise_cmd = get_denoise_command(
				input		=> $readcounts,
				pon		=> $pon,
				output_stem	=> $output_stem,
				java_mem	=> $parameters->{denoise}->{java_mem}
				);

			# check if this should be run
			if ('Y' eq missing_file($denoised_cr)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for DenoiseReadCounts...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_denoise_read_counts_' . $sample,
					cmd	=> $denoise_cmd,
					modules	=> [$gatk],
					dependencies	=> join(':', $pon_run_id, @sample_jobs),
					max_time	=> $parameters->{denoise}->{time},
					mem		=> $parameters->{denoise}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_denoise_read_counts_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @sample_jobs, $run_id;
				push @{$patient_jobs{$patient}}, $run_id;
				} else {
				print $log "Skipping DenoiseReadCounts as this has already been completed!\n";
				}

			# plot the denoised copy number ratios
			my $denoised_plot = join('/', $plot_directory, $sample . '.denoised.png');
			my $plot_cmd = get_plot_denoise_command(
				input_stem	=> $output_stem,
				plot_dir	=> $plot_directory,
				output_stem	=> $sample
				);

			# check if this should be run
			if ('Y' eq missing_file($denoised_plot)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for PlotDenoisedCopyRatios...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_plot_copy_ratios_' . $sample,
					cmd	=> $plot_cmd,
					modules	=> [$gatk],
					dependencies	=> join(':', @sample_jobs),
					max_time	=> '01:00:00',
					mem		=> $memory,
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$tmp_run_id = submit_job(
					jobname		=> 'run_plot_copy_ratios_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @{$patient_jobs{$patient}}, $tmp_run_id;
				} else {
				print $log "Skipping PlotDenoisedCopyRatios as this has already been completed!\n";
				}

			# run collect allelic counts
			my $tumour_allelic_counts = $output_stem . '_allelicCounts.tsv';

			my $allelic_counts_cmd = get_allele_counts_command(
				input		=> $smp_data->{$patient}->{tumour}->{$sample},
				intervals	=> $gnomad_snps,
				output		=> $tumour_allelic_counts,
				java_mem	=> $parameters->{allele_counts}->{java_mem},
				wgs		=> $is_wgs,
				chrom_list	=> join(' ', @chroms)
				);

			# check if this should be run
			if ('Y' eq missing_file($tumour_allelic_counts)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for CollectAllelicCounts...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_collect_allelic_counts_' . $sample,
					cmd	=> $allelic_counts_cmd,
					modules	=> [$gatk],
					dependencies	=> $intervals_run_id2,
					max_time	=> $parameters->{allele_counts}->{time},
					mem		=> $parameters->{allele_counts}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_collect_allelic_counts_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @sample_jobs, $run_id;
				push @{$patient_jobs{$patient}}, $run_id;
				} else {
				print $log "Skipping CollectAllelicCounts as this has already been completed!\n";
				}

			# run Model Segments
			my $modelled_segments = $output_stem . '.called.seg';

			my $model_cmd = get_modelsegments_command(
				input_stem	=> $output_stem,
				normal_counts	=> $norm_allelic_counts,
				output_dir	=> $sample_directory,
				output_stem	=> $sample,
				java_mem	=> $parameters->{model}->{java_mem},
				seq_type	=> $tool_data->{seq_type}
				);

			# check if this should be run
			if ('Y' eq missing_file($modelled_segments)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for ModelSegments...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_model_segments_' . $sample,
					cmd	=> $model_cmd,
					modules	=> [$gatk],
					dependencies	=> join(':', @sample_jobs, $norm_run_id),
					max_time	=> $parameters->{model}->{time},
					mem		=> $parameters->{model}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_model_segments_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @sample_jobs, $run_id;
				push @{$patient_jobs{$patient}}, $run_id;
				} else {
				print $log "Skipping ModelSegments as this has already been completed!\n";
				}

			push @{$final_outputs{$patient}}, $modelled_segments;

			# run plot modeled segments
			my $modeled_plot = join('/', $plot_directory, $sample . '.modeled.png');
			$plot_cmd = get_plot_segments_command(
				input_stem	=> $output_stem,
				plot_dir	=> $plot_directory,
				output_stem	=> $sample
				);

			# check if this should be run
			if ('Y' eq missing_file($modeled_plot)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for PlotModeledSegments...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_plot_modeled_segments_' . $sample,
					cmd	=> $plot_cmd,
					modules	=> [$gatk],
					dependencies	=> join(':', @sample_jobs),
					max_time	=> '01:00:00',
					mem		=> $memory,
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$tmp_run_id = submit_job(
					jobname		=> 'run_plot_modeled_segments_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @{$patient_jobs{$patient}}, $tmp_run_id;
				} else {
				print $log "Skipping PlotModeledSegments as this has already been completed!\n";
				}
			}

		if (scalar(@{$patient_jobs{$patient}}) > 0) { push @all_jobs, @{$patient_jobs{$patient}}; }

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			unless (scalar(@{$patient_jobs{$patient}}) == 0) {

				print $log "Submitting job to clean up temporary/intermediate files...\n";

				# make sure final output exists before removing intermediate files!
				my @files_to_check;
				foreach my $tmp ( @{$final_outputs{$patient}} ) {
					push @files_to_check, $tmp . '.md5';
					}

				$cleanup_cmd = join("\n",
					"if [ -s " . join(" ] && [ -s ", @files_to_check) . " ]; then",
					"  $cleanup_cmd",
					"else",
					'  echo "One or more FINAL OUTPUT FILES is missing; not removing intermediates"',
					"fi"
					);

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_cleanup_' . $patient,
					cmd	=> $cleanup_cmd,
					dependencies	=> join(':', @{$patient_jobs{$patient}}),
					mem		=> '256M',
					hpc_driver	=> $args{hpc_driver},
					kill_on_error	=> 0,
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_cleanup_' . $patient,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);
				}
			}

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @{$final_outputs{$patient}}) . "\n";
		print $log "---\n";
		}

	# collate results
	if ($should_run_final) {

		my $collect_output = join(' ',
			"Rscript $cwd/collect_gatk_cnv_output.R",
			'-d', $output_directory,
			'-p', $tool_data->{project_name}
			);

		if (defined($intervals_bed)) {
			$collect_output .= " -t $picard_intervals";
			}

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'combine_gatk_cnv_output',
			cmd	=> $collect_output,
			modules	=> [$r_version],
			dependencies	=> join(':', @all_jobs),
			mem		=> '4G',
			max_time	=> '12:00:00',
			hpc_driver	=> $args{hpc_driver},
			extra_args	=> [$hpc_group]
			);

		$run_id = submit_job(
			jobname		=> 'combine_gatk_cnv_output',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $run_id;
		}

	# if this is not a dry run OR there are jobs to assess (run or resumed with jobs submitted) then
	# collect job metrics (exit status, mem, run time)
	unless ( ($args{dry_run}) || (scalar(@all_jobs) == 0) ) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids	=> join(',', @all_jobs),
			outfile	=> $outfile
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'output_job_metrics_' . $run_count,
			cmd	=> $collect_metrics,
			dependencies	=> join(':', @all_jobs),
			mem		=> '256M',
			hpc_driver	=> $args{hpc_driver},
			kill_on_error	=> 0,
			extra_args	=> [$hpc_group]
			);

		$run_id = submit_job(
			jobname		=> 'output_job_metrics',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $run_id;

		# do some logging
		print "Number of jobs submitted: " . scalar(@all_jobs) . "\n";

		my $n_queued = `squeue -r | wc -l`;
		print "Total number of jobs in queue: " . $n_queued . "\n";

		# wait until it finishes
		unless ($args{no_wait}) {
			check_final_status(job_id => $run_id);
			}
		}

	# finish up
	print $log "\nProgramming terminated successfully.\n\n";
	close $log;
	}

### GETOPTS AND DEFAULT VALUES #####################################################################
# declare variables
my ($tool_config, $data_config, $output_directory);
my $hpc_driver = 'slurm';
my ($remove_junk, $dry_run, $no_wait, $help);

# get command line arguments
GetOptions(
	'h|help'	=> \$help,
	'd|data=s'	=> \$data_config,
	't|tool=s'	=> \$tool_config,
	'o|out_dir=s'	=> \$output_directory,
	'c|cluster=s'	=> \$hpc_driver,
	'remove'	=> \$remove_junk,
	'dry-run'	=> \$dry_run,
	'no-wait'	=> \$no_wait
	);

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--data|-d\t<string> data config (yaml format)",
		"\t--tool|-t\t<string> tool config (yaml format)",
		"\t--out_dir|-o\t<string> path to output directory",
		"\t--cluster|-c\t<string> cluster scheduler (default: slurm)",
		"\t--remove\t<boolean> should intermediates be removed? (default: false)",
		"\t--dry-run\t<boolean> should jobs be submitted? (default: false)",
		"\t--no-wait\t<boolean> should we exit after job submission (true) or wait until all jobs have completed (false)? (default: false)"
		);

	print "$help_msg\n";
	exit;
	}

# do some quick error checks to confirm valid arguments	
if (!defined($tool_config)) { die("No tool config file defined; please provide -t | --tool (ie, tool_config.yaml)"); }
if (!defined($data_config)) { die("No data config file defined; please provide -d | --data (ie, sample_config.yaml)"); }
if (!defined($output_directory)) { die("No output directory defined; please provide -o | --out_dir"); }

main(
	tool_config		=> $tool_config,
	data_config		=> $data_config,
	output_directory	=> $output_directory,
	hpc_driver		=> $hpc_driver,
	del_intermediates	=> $remove_junk,
	dry_run			=> $dry_run,
	no_wait			=> $no_wait
	);
