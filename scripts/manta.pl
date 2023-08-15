#!/usr/bin/env perl
### manta.pl #######################################################################################
use AutoLoader 'AUTOLOAD';
use strict;
use warnings;
use Carp;
use Getopt::Std;
use Getopt::Long;
use POSIX qw(strftime);
use File::Basename;
use File::Path qw(make_path);
use List::Util qw(any first);
use YAML qw(LoadFile);
use IO::Handle;

my $cwd = dirname(__FILE__);
require "$cwd/utilities.pl";

# define some global variables
our ($reference, $intervals, $seq_type, $dictionary) = undef;

####################################################################################################
# version       author		comment
# 1.0		sprokopec       script to run Strelka
# 1.1		sprokopec	added help msg and cleaned up code
# 1.2           sprokopec       minor updates for tool config
# 1.3		sprokopec	strip out strelka commands to run manta only

### USAGE ##########################################################################################
# manta.pl -t tool_config.yaml -d data_config.yaml -o /path/to/output/dir -c slurm --remove --dry_run
#
# where:
#	-t (tool.yaml) contains tool versions and parameters, reference information, etc.
#	-d (data.yaml) contains sample information (YAML file containing paths to BWA-aligned,
#		GATK-processed BAMs, generated by gatk.pl)
#	-o (/path/to/output/dir) indicates tool-specific output directory
#	-c indicates hpc driver (ie, slurm)
#	--remove indicates that intermediates will be removed
#	--dry_run indicates that this is a dry run

### DEFINE SUBROUTINES #############################################################################
# format command to run Manta
sub get_manta_command {
	my %args = (
		tumour		=> undef,
		normal		=> undef,
		output_dir	=> undef,
		intervals	=> undef,
		@_
		);

	my $manta_cmd = 'configManta.py ';
	
	if ('targeted' eq $seq_type) {
		$manta_cmd = join("\n",
			'DIRNAME=$(which configManta.py | xargs dirname)',
			'cp $DIRNAME/configManta.py.ini ' . $args{output_dir},
			"sed -i 's/minEdgeObservations = 3/minEdgeObservations = 2/' $args{output_dir}/configManta.py.ini",
			"sed -i 's/minCandidateSpanningCount = 3/minCandidateSpanningCount = 2/' $args{output_dir}/configManta.py.ini",
			"\n" . "configManta.py --config $args{output_dir}/configManta.py.ini "
			);
		}

	if (defined($args{normal})) {
		$manta_cmd .= join(' ',
			'--normalBam', $args{normal},
			'--tumorBam', $args{tumour},
			'--referenceFasta', $reference,
			'--runDir', $args{output_dir}
			);
		} else {
		$manta_cmd .= join(' ',
			'--tumorBam', $args{tumour},
			'--referenceFasta', $reference,
			'--runDir', $args{output_dir}
			);
		}

	if ('wgs' eq $seq_type) {
		$manta_cmd .= " --callRegions $args{intervals}";
		} elsif (('exome' eq $seq_type) || ('targeted' eq $seq_type)) {
		$manta_cmd .= " --exome --callRegions $args{intervals}";
		} elsif ( ('rna' eq $seq_type) && (!defined($args{normal})) ) {
		$manta_cmd .= " --rna";
		}

	return($manta_cmd);
	}

### PON ############################################################################################
sub pon {
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
		print "Initiating Manta germline SV calling pipeline...\n";
		}

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'strelka');
	my $date = strftime "%F", localtime;

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_MANTA_SV_pipeline.log');

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

		$log_file = join('/', $log_directory, 'run_MANTA_SV_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running Manta SV calling pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};
	$dictionary = $reference;
	$dictionary =~ s/.fa/.dict/;
	$seq_type = $tool_data->{seq_type};

	my $string;
	if (defined($tool_data->{strelka}->{chromosomes})) {
		$string = $tool_data->{strelka}->{chromosomes};
		} elsif (('hg38' eq $tool_data->{ref_type}) || ('hg19' eq $tool_data->{ref_type})) {
		$string = 'chr' . join(',chr', 1..22) . ',chrX,chrY';
		} elsif (('GRCh37' eq $tool_data->{ref_type}) || ('GRCh37' eq $tool_data->{ref_type})) {
		$string = join(',', 1..22) . ',X,Y';
		}

	my @chroms = split(',', $string);

	if ( ('exome' eq $seq_type) || ('targeted' eq $seq_type) ) {
		$intervals = $tool_data->{intervals_bed};
		$intervals =~ s/\.bed/_padding100bp.bed.gz/;
		print $log "\n    Target intervals: $intervals";
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---";

	# set tools and versions
	my $manta	= 'manta/' . $tool_data->{manta_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};
	my $r_version	= 'R/' . $tool_data->{r_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{manta}->{parameters};

	# get optional HPC group
	my $hpc_group = defined($tool_data->{hpc_group}) ? "-A $tool_data->{hpc_group}" : undef;

	### RUN ###########################################################################################
	my ($run_script, $run_id, $link, $should_run_final, $prep_run_id);
	my (@all_jobs);

	# start by preparing callable regions for WGS (exclude short contigs)
	if ('wgs' eq $seq_type) {

		my $chr_file = join('/', $output_directory, 'chromosome_list.bed');
		$intervals = $chr_file;
		$intervals =~ s/bed/bed.gz/;

		if ('Y' eq missing_file($intervals)) {	

			my @chr_lengths;

			# read in sequence dictionary
			open(my $dict_fh, $dictionary) or die "Could not open $dictionary\n";

			# get total length of each chromosome of interest
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
					push @chr_lengths, "$chr\t0\t$length";
					}
				}

			close($dict_fh);

			# write lengths to file
			open (my $chr_list, '>', $chr_file) or die "Could not open $chr_file for writing.";	
			foreach my $line ( @chr_lengths ) {
				print $chr_list "$line\n";
				}

			close($chr_list);

			# format file for input to manta (bgzip + index)
			my $format_command = "bgzip $chr_file\n";
			$format_command .= "tabix -p bed $chr_file.gz";

			# record command (in log directory) and then run job
			print $log ">> Prepare callable regions bed...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_prepare_callableRegions_bed',
				cmd	=> $format_command,
				modules	=> ['tabix'],
				hpc_driver	=> $args{hpc_driver},
				extra_args	=> [$hpc_group]
				);

			$prep_run_id = submit_job(
				jobname		=> 'run_prepare_callableRegions_bed',,
				shell_command	=> $run_script,
				hpc_driver	=> $args{hpc_driver},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);

			push @all_jobs, $prep_run_id;
			}
		}

	# get sample data
	my $smp_data = LoadFile($data_config);

	unless($args{dry_run}) {
		print "Processing " . scalar(keys %{$smp_data}) . " patients.\n";
		}

	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient";

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};

		if (scalar(@normal_ids) == 0) {
			print $log "\n>> No normal BAM provided. Skipping $patient...\n";
			next;
			}

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $link_directory = join('/', $patient_directory, 'bam_links');
		unless(-e $link_directory) { make_path($link_directory); }

		# create some symlinks
		foreach my $normal (@normal_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{normal}->{$normal};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{normal}->{$normal}, $link);
			}

		my (@final_outputs, @patient_jobs, $cleanup_cmd);

		# for each normal sample
		foreach my $sample (@normal_ids) {

			print $log "\n  NORMAL: $sample\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			$run_id = '';

			my $manta_command = get_manta_command(
				tumour		=> $smp_data->{$patient}->{tumour}->{$sample},
				output_dir	=> $sample_directory,
				intervals	=> $intervals
				);

			$manta_command .= ";\n\n$sample_directory/runWorkflow.py --quiet";

			my $manta_output = join('/',
				$sample_directory,
				'results/variants/candidateSmallIndels.vcf.gz'
				);

			$cleanup_cmd .= "\nrm -rf " . join('/', $sample_directory, 'workspace');

			# check if this should be run
			if ('Y' eq missing_file($manta_output)) {

				# record command (in log directory) and then run job
				print $log "  >> Submitting job for Manta...\n";

				# if this has been run once before and failed, we need to clean up
				# the previous attempt before initiating a new one
				if ('N' eq missing_file("$sample_directory/runWorkflow.py")) {
					`rm -rf $sample_directory/*`;
					}

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_manta_' . $sample,
					cmd	=> $manta_command,
					modules	=> [$manta],
					dependencies	=> $prep_run_id,
					max_time	=> $parameters->{manta}->{time},
					mem		=> $parameters->{manta}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_manta_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @all_jobs, $run_id;
				push @patient_jobs, $run_id;
				} else {
				print $log "  >> Skipping MANTA because this has already been completed!\n";
				}

			push @final_outputs, $manta_output;

			}

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			print $log "\n>> Submitting job to clean up temporary/intermediate files...\n";

			# make sure final output exists before removing intermediate files!
			$cleanup_cmd = join("\n",
				"if [ -s " . join(" ] && [ -s ", @final_outputs) . " ]; then",
				"  $cleanup_cmd",
				"else",
				'  echo "One or more FINAL OUTPUT FILES is missing; not removing intermediates"',
				"fi"
				);

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_cleanup_' . $patient,
				cmd	=> $cleanup_cmd,
				dependencies	=> join(':', @patient_jobs),
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

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @final_outputs) . "\n";
		print $log "---\n";
		}

	# if this is not a dry run OR there are jobs to assess (run or resumed with jobs submitted) then
	# collect job metrics (exit status, mem, run time)
	unless ( ($args{dry_run}) || (scalar(@all_jobs) == 0) ) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids		=> join(',', @all_jobs),
			outfile		=> $outfile,
			hpc_driver	=> $args{hpc_driver}
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
		print "Initiating Manta somatic SV calling pipeline...\n";
		}

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'strelka');
	my $date = strftime "%F", localtime;

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_MANTA_SV_pipeline.log');

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

		$log_file = join('/', $log_directory, 'run_MANTA_SV_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running Manta SV calling pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};
	$dictionary = $reference;
	$dictionary =~ s/.fa/.dict/;
	$seq_type = $tool_data->{seq_type};

	my $string;
	if (defined($tool_data->{strelka}->{chromosomes})) {
		$string = $tool_data->{strelka}->{chromosomes};
		} elsif (('hg38' eq $tool_data->{ref_type}) || ('hg19' eq $tool_data->{ref_type})) {
		$string = 'chr' . join(',chr', 1..22) . ',chrX,chrY';
		} elsif (('GRCh37' eq $tool_data->{ref_type}) || ('GRCh37' eq $tool_data->{ref_type})) {
		$string = join(',', 1..22) . ',X,Y';
		}

	my @chroms = split(',', $string);

	if ( ('exome' eq $seq_type) || ('targeted' eq $seq_type) ) {
		$intervals = $tool_data->{intervals_bed};
		$intervals =~ s/\.bed/_padding100bp.bed.gz/;
		print $log "\n    Target intervals: $intervals";
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---";

	# set tools and versions
	my $manta	= 'manta/' . $tool_data->{manta_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};
	my $r_version	= 'R/' . $tool_data->{r_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{manta}->{parameters};

	# get optional HPC group
	my $hpc_group = defined($tool_data->{hpc_group}) ? "-A $tool_data->{hpc_group}" : undef;

	### RUN ###########################################################################################
	my ($run_script, $run_id, $link, $should_run_final, $prep_run_id);
	my (@all_jobs);

	# start by preparing callable regions for WGS (exclude short contigs)
	if ('wgs' eq $seq_type) {

		my $chr_file = join('/', $output_directory, 'chromosome_list.bed');
		$intervals = $chr_file;
		$intervals =~ s/bed/bed.gz/;

		if ('Y' eq missing_file($intervals)) {	

			my @chr_lengths;

			# read in sequence dictionary
			open(my $dict_fh, $dictionary) or die "Could not open $dictionary\n";

			# get total length of each chromosome of interest
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
					push @chr_lengths, "$chr\t0\t$length";
					}
				}

			close($dict_fh);

			# write lengths to file
			open (my $chr_list, '>', $chr_file) or die "Could not open $chr_file for writing.";	
			foreach my $line ( @chr_lengths ) {
				print $chr_list "$line\n";
				}

			close($chr_list);

			# format file for input to manta (bgzip + index)
			my $format_command = "bgzip $chr_file\n";
			$format_command .= "tabix -p bed $chr_file.gz";

			# record command (in log directory) and then run job
			print $log ">> Prepare callable regions bed...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_prepare_callableRegions_bed',
				cmd	=> $format_command,
				modules	=> ['tabix'],
				hpc_driver	=> $args{hpc_driver},
				extra_args	=> [$hpc_group]
				);

			$prep_run_id = submit_job(
				jobname		=> 'run_prepare_callableRegions_bed',,
				shell_command	=> $run_script,
				hpc_driver	=> $args{hpc_driver},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);

			push @all_jobs, $prep_run_id;
			}
		}

	# get sample data
	my $smp_data = LoadFile($data_config);

	unless($args{dry_run}) {
		print "Processing " . scalar(keys %{$smp_data}) . " patients.\n";
		}

	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient";

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		if (scalar(@tumour_ids) == 0) {
			print $log "\n>> No tumour BAM provided. Skipping $patient...\n";
			next;
			}

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $link_directory = join('/', $patient_directory, 'bam_links');
		unless(-e $link_directory) { make_path($link_directory); }

		# create some symlinks
		foreach my $normal (@normal_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{normal}->{$normal};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{normal}->{$normal}, $link);
			}
		foreach my $tumour (@tumour_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{tumour}->{$tumour};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{tumour}->{$tumour}, $link);
			}

		my (@final_outputs, @patient_jobs, $cleanup_cmd);

		# for each tumour sample
		foreach my $sample (@tumour_ids) {

			# if there are any samples to run, we will run the final combine job
			$should_run_final = 1;

			print $log "\n  TUMOUR: $sample\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			$run_id = '';

			my $manta_command;

			# run on tumour-only (includes RNA)
			if (scalar(@normal_ids) == 0) {

				$manta_command = get_manta_command(
					tumour		=> $smp_data->{$patient}->{tumour}->{$sample},
					output_dir	=> $sample_directory,
					intervals	=> $intervals
					);

				} else { # run on T/N pairs

				$manta_command = get_manta_command(
					tumour		=> $smp_data->{$patient}->{tumour}->{$sample},
					normal		=> $smp_data->{$patient}->{normal}->{$normal_ids[0]},
					output_dir	=> $sample_directory,
					intervals	=> $intervals
					);
				}

			$manta_command .= ";\n\n$sample_directory/runWorkflow.py --quiet";

			my $manta_output = join('/',
				$sample_directory,
				'results/variants/candidateSmallIndels.vcf.gz'
				);

			$cleanup_cmd .= "\nrm -rf " . join('/', $sample_directory, 'workspace');

			# check if this should be run
			if ('Y' eq missing_file($manta_output)) {

				# record command (in log directory) and then run job
				print $log "  >> Submitting job for Manta...\n";

				# if this has been run once before and failed, we need to clean up
				# the previous attempt before initiating a new one
				if ('N' eq missing_file("$sample_directory/runWorkflow.py")) {
					`rm -rf $sample_directory/*`;
					}

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_manta_' . $sample,
					cmd	=> $manta_command,
					modules	=> [$manta],
					dependencies	=> $prep_run_id,
					max_time	=> $parameters->{manta}->{time},
					mem		=> $parameters->{manta}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_manta_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @all_jobs, $run_id;
				push @patient_jobs, $run_id;
				} else {
				print $log "  >> Skipping MANTA because this has already been completed!\n";
				}

			push @final_outputs, $manta_output;

			}

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			print $log "\n>> Submitting job to clean up temporary/intermediate files...\n";

			# make sure final output exists before removing intermediate files!
			$cleanup_cmd = join("\n",
				"if [ -s " . join(" ] && [ -s ", @final_outputs) . " ]; then",
				"  $cleanup_cmd",
				"else",
				'  echo "One or more FINAL OUTPUT FILES is missing; not removing intermediates"',
				"fi"
				);

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_cleanup_' . $patient,
				cmd	=> $cleanup_cmd,
				dependencies	=> join(':', @patient_jobs),
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

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @final_outputs) . "\n";
		print $log "---\n";
		}

	# if this is not a dry run OR there are jobs to assess (run or resumed with jobs submitted) then
	# collect job metrics (exit status, mem, run time)
	unless ( ($args{dry_run}) || (scalar(@all_jobs) == 0) ) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids		=> join(',', @all_jobs),
			outfile		=> $outfile,
			hpc_driver	=> $args{hpc_driver}
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
my ($remove_junk, $dry_run, $help, $no_wait, $germline);

# get command line arguments
GetOptions(
	'h|help'	=> \$help,
	'd|data=s'	=> \$data_config,
	't|tool=s'	=> \$tool_config,
	'o|out_dir=s'	=> \$output_directory,
	'germline'	=> \$germline,
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
		"\t--germline\t<boolean> should we look for germline variants? (will run normal samples in addition to any tumour)",
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

if ($germline) {
	pon(
		tool_config		=> $tool_config,
		data_config		=> $data_config,
		output_directory	=> $output_directory,
		hpc_driver		=> $hpc_driver,
		del_intermediates	=> $remove_junk,
		dry_run			=> $dry_run,
		no_wait			=> $no_wait
		);
	} else {
	main(
		tool_config		=> $tool_config,
		data_config		=> $data_config,
		output_directory	=> $output_directory,
		hpc_driver		=> $hpc_driver,
		del_intermediates	=> $remove_junk,
		dry_run			=> $dry_run,
		no_wait			=> $no_wait
		);
	}
