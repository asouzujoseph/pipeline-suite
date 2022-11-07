#!/usr/bin/env perl
### get_sequencing_metrics.pl ######################################################################
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
use List::Util qw(any);
use IO::Handle;

my $cwd = dirname(__FILE__);
require "$cwd/utilities.pl";

our ($reference, $dictionary, $gnomad, $gatk_v4);

####################################################################################################
# version	author		comment
# 1.0		sprokopec	script to collect sequencing metrics on GATK processed BAMs

### USAGE ##########################################################################################
# get_sequencing_metrics.pl -t tool.yaml -d data.yaml -o /path/to/output/dir -c slurm --remove --dry_run
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
# format command to convert intervals.bed to picard-style intervals.list
sub get_format_intervals_command {
	my %args = (
		input_bed	=> undef,
		picard_out	=> undef,
		@_
		);

	my $format_command .= "\n\n" . join(' ',
		'java -jar $picard_dir/picard.jar BedToIntervalList',
		'I=' . $args{input_bed},
		'SD=' . $dictionary,
		'O=' . $args{picard_out}
		);

	return($format_command);
	}

# format command to extract insert size metrics
sub get_insert_sizes_command {
	my %args = (
		input		=> undef,
		output_stem	=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		@_
		);

	my $qc_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $picard_dir/picard.jar CollectInsertSizeMetrics',
		'I=' . $args{input},
		'O=' . $args{output_stem} . '.txt',
		'H=' . $args{output_stem} . '.pdf',
		'M=0 W=600'
		);

	$qc_command .= "\n\necho 'CollectInsertSizeMetrics completed successfully.' > $args{output_stem}.COMPLETE";

	return($qc_command);
	}

# format command to extract alignment metrics
sub get_alignment_metrics_command {
	my %args = (
		input		=> undef,
		output_stem	=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		@_
		);

	my $qc_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $picard_dir/picard.jar CollectAlignmentSummaryMetrics',
		'R=' . $reference,
		'I=' . $args{input},
		'O=' . $args{output_stem} . '.txt',
		'LEVEL=ALL_READS LEVEL=SAMPLE LEVEL=LIBRARY LEVEL=READ_GROUP'
		);

	$qc_command .= "\n\necho 'CollectAlignmentSummaryMetrics completed successfully.' > $args{output_stem}.COMPLETE";

	return($qc_command);
	}

# format command to extract metrics for WGS experiments
sub get_wgs_metrics_command {
	my %args = (
		input		=> undef,
		output_stem	=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		@_
		);

	my $qc_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $picard_dir/picard.jar CollectWgsMetrics',
		'R=' . $reference,
		'I=' . $args{input},
		'O=' . $args{output_stem} . '.txt'
		);

	$qc_command .= "\n\necho 'CollectWGSMetrics completed successfully.' > $args{output_stem}.COMPLETE";

	return($qc_command);
	}

# format command to extract metrics on sequencing artefacts
sub get_artefacts_command {
	my %args = (
		input		=> undef,
		output_stem	=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		intervals	=> undef,
		@_
		);

	my $qc_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $picard_dir/picard.jar CollectSequencingArtifactMetrics',
		'R=' . $reference,
		'I=' . $args{input},
		'O=' . $args{output_stem}
		);

	if (defined($args{intervals})) {
		$qc_command .= " INTERVALS=$args{intervals}";
		}

	$qc_command .= "\n\necho 'CollectSequencingArtifactMetrics completed successfully.' > $args{output_stem}.COMPLETE";

	return($qc_command);
	}

# format command for GetPileupSummaries
sub get_pileup_command {
	my %args = (
		input		=> undef,
		output		=> undef,
		tmp_dir		=> undef,
		intervals	=> undef,
		@_
		);

	my $qc_command = join(' ',
		'gatk GetPileupSummaries',
		'--input', $args{input},
		'--output', $args{output},
		'--tmp-dir', $args{tmp_dir},
		'--reference', $reference,
		'--variant', $gnomad
		);

	if (defined($args{intervals})) {
		$qc_command .= " --intervals $args{intervals}";
		}

	$qc_command .= "\n\nmd5sum $args{output} > $args{output}.md5";

	return($qc_command);
	}

# format command to estimate contamination
sub get_estimate_contamination_command {
	my %args = (
		tumour		=> undef,
		normal		=> undef,
		output		=> undef,
		tmp_dir		=> undef,
		intervals	=> undef,
		@_
		);

	my $qc_command = join(' ',
		'gatk CalculateContamination',
		'--input', $args{tumour},
		'--output', $args{output},
		'--tmp-dir', $args{tmp_dir}
		);

	if (defined($args{normal})) {
		$qc_command .= " --matched-normal $args{normal}";
		}

	if (defined($args{intervals})) {
		$qc_command .= " --intervals $args{intervals}";
		}

	$qc_command .= "\n\nmd5sum $args{output} > $args{output}.md5";

	return($qc_command);
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
		print "Initiating SequenceMetrics (QC) pipeline...\n";
		}

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'gatk');

	# confirm version
	my $needed = version->declare('4.1')->numify;
	my $given = version->declare($tool_data->{gatk_cnv_version})->numify;

	if ($given < $needed) {
		die("Incompatible GATK version requested! QC pipeline is currently only compatible with GATK >4.1");
		}

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_SequenceMetrics_pipeline.log');

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

		$log_file = join('/', $log_directory, 'run_SequenceMetrics_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running SequenceMetrics (QC) pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};
	$dictionary = $reference;
	$dictionary =~ s/.fa/.dict/;

	if (defined($tool_data->{gnomad})) {
		$gnomad = $tool_data->{gnomad};
		print $log "\n    gnomAD SNPs: $tool_data->{gnomad}";
		} else {
		die("No gnomAD file provided; please provide path to gnomAD VCF");
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---\n";

	my $string;
	if ( ('hg38' eq $tool_data->{ref_type}) || ('hg19' eq $tool_data->{ref_type})) {
		$string = 'chr' . join(',chr', 1..22) . ',chrX,chrY';
		} elsif ( ('GRCh37' eq $tool_data->{ref_type}) || ('GRCh37' eq $tool_data->{ref_type})) {
		$string = join(',', 1..22) . ',X,Y';
		} else {
		die("Unrecognized ref_type; must be one of hg19, hg38, GRCh37 or GRCh38");
		}

	my @chroms = split(',', $string);

	# set tools and versions
	my $gatk	= 'gatk/' . $tool_data->{gatk_cnv_version};
	my $picard	= 'picard/' . $tool_data->{picard_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};
	my $bedtools	= 'bedtools/' . $tool_data->{bedtools_version};
	my $r_version	= 'R/' . $tool_data->{r_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{bamqc}->{parameters};

	# get optional HPC group
	my $hpc_group = defined($tool_data->{hpc_group}) ? "-A $tool_data->{hpc_group}" : undef;

	### RUN ###########################################################################################
	my ($run_script, $run_id, $link, $cleanup_cmd, $picard_intervals, $should_run_final);
	my @all_jobs;

	# use picard-style intervals list
	if (defined($tool_data->{intervals_bed})) {
		$picard_intervals = $tool_data->{intervals_bed};
		$picard_intervals =~ s/\.bed/\.interval_list/;
		} else {
		$picard_intervals = join(' -L ', @chroms);
		}

	# get sample data
	my $smp_data = LoadFile($data_config);

	unless($args{dry_run}) {
		print "Processing " . scalar(keys %{$smp_data}) . " patients.\n";
		}

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $tmp_directory = join('/', $patient_directory, 'TEMP');
		unless(-e $tmp_directory) { make_path($tmp_directory); }

		# indicate this should be removed at the end
		$cleanup_cmd = "rm -rf $tmp_directory";

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

		# create an array to hold final outputs and all patient job ids
		my (@final_outputs, @patient_jobs, @pileup_jobs);

		my @sample_ids = @tumour_ids;
		push @sample_ids, @normal_ids;
		@sample_ids = sort(@sample_ids);

		foreach my $sample (@sample_ids) {

			# if there are any samples to run, we will run the final combine job
			$should_run_final = 1;

			print $log "  SAMPLE: $sample\n\n";

			my $type;
			if ( (any { $_ =~ m/$sample/ } @normal_ids) ) {
				$type = 'normal';
				} else {
				$type = 'tumour';
				}

			## Collect artefact metrics on all input BAMs
			my $output_stem = join('/', $patient_directory, $sample . '_artifact_metrics');

			my $qc_command = get_artefacts_command(
				input		=> $smp_data->{$patient}->{$type}->{$sample},
				output_stem	=> $output_stem,
				intervals	=> $picard_intervals,
				java_mem	=> $parameters->{qc}->{java_mem},
				tmp_dir		=> $tmp_directory
				);

			if ('wgs' eq $tool_data->{seq_type}) {
				$qc_command = get_artefacts_command(
					input		=> $smp_data->{$patient}->{$type}->{$sample},
					output_stem	=> $output_stem,
					java_mem	=> $parameters->{qc}->{java_mem},
					tmp_dir		=> $tmp_directory
					);
				}

			# check if this should be run
			if ('Y' eq missing_file($output_stem . '.COMPLETE')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for CollectSequenceArtefacts...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_collect_sequencing_artefacts_' . $sample,
					cmd	=> $qc_command,
					modules	=> [$picard],
					max_time	=> $parameters->{qc}->{time},
					mem		=> $parameters->{qc}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_collect_sequencing_artefacts_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping CollectSequenceArtefacts because this has already been completed!\n";
				}

			push @final_outputs, $output_stem . '.bait_bias_summary_metrics';
			push @final_outputs, $output_stem . '.pre_adapter_summary_metrics';

			## Collect InsertSize metrics 
			$output_stem = join('/', $patient_directory, $sample . '_insert_size');

			$qc_command = get_insert_sizes_command(
				input		=> $smp_data->{$patient}->{$type}->{$sample},
				output_stem	=> $output_stem,
				java_mem	=> $parameters->{qc}->{java_mem},
				tmp_dir		=> $tmp_directory
				);

			# check if this should be run
			if ('Y' eq missing_file($output_stem . '.COMPLETE')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for CollectInsertSizeMetrics...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_collect_insert_sizes_' . $sample,
					cmd	=> $qc_command,
					modules	=> [$picard,'R/4.1.0'],
					max_time	=> $parameters->{qc}->{time},
					mem		=> $parameters->{qc}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_collect_insert_sizes_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping CollectInsertSizeMetrics because this has already been completed!\n";
				}

			push @final_outputs, $output_stem . '.txt';

			## Collect alignment metrics
			$output_stem = join('/', $patient_directory, $sample . '_alignment_metrics');

			$qc_command = get_alignment_metrics_command(
				input		=> $smp_data->{$patient}->{$type}->{$sample},
				output_stem	=> $output_stem,
				java_mem	=> $parameters->{qc}->{java_mem},
				tmp_dir		=> $tmp_directory
				);

			# check if this should be run
			if ('Y' eq missing_file($output_stem . '.COMPLETE')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for CollectAlignmentMetrics...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_collect_alignment_metrics_' . $sample,
					cmd	=> $qc_command,
					modules	=> [$picard],
					max_time	=> $parameters->{qc}->{time},
					mem		=> $parameters->{qc}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_collect_alignment_metrics_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping CollectAlignmentMetrics because this has already been completed!\n";
				}

			push @final_outputs, $output_stem . '.txt';

			## Collect WGS metrics
			if ('wgs' eq $tool_data->{seq_type}) {

				$output_stem = join('/', $patient_directory, $sample . '_wgs_metrics');

				$qc_command = get_wgs_metrics_command(
					input		=> $smp_data->{$patient}->{$type}->{$sample},
					output_stem	=> $output_stem,
					java_mem	=> $parameters->{qc}->{java_mem},
					tmp_dir		=> $tmp_directory
					);

				# check if this should be run
				if ('Y' eq missing_file($output_stem . '.COMPLETE')) {

					# record command (in log directory) and then run job
					print $log "Submitting job for CollectWgsMetrics...\n";

					$run_script = write_script(
						log_dir	=> $log_directory,
						name	=> 'run_collect_wgs_metrics_' . $sample,
						cmd	=> $qc_command,
						modules	=> [$picard],
						max_time	=> $parameters->{qc}->{time},
						mem		=> $parameters->{qc}->{mem},
						hpc_driver	=> $args{hpc_driver},
						extra_args	=> [$hpc_group]
						);

					$run_id = submit_job(
						jobname		=> 'run_collect_wgs_metrics_' . $sample,
						shell_command	=> $run_script,
						hpc_driver	=> $args{hpc_driver},
						dry_run		=> $args{dry_run},
						log_file	=> $log
						);

					push @patient_jobs, $run_id;
					push @all_jobs, $run_id;
					} else {
					print $log "Skipping CollectWgsMetrics because this has already been completed!\n";
					}

				push @final_outputs, $output_stem . '.txt';
				}

			## Collect contamination estimates
			my $pileup_out = join('/', $patient_directory, $sample . '_pileup.table');

			my $pileup_command = get_pileup_command(
				input		=> $smp_data->{$patient}->{$type}->{$sample},
				output		=> $pileup_out,
				intervals	=> $picard_intervals,
				tmp_dir		=> $tmp_directory
				);

			$cleanup_cmd .= "\nrm $pileup_out";

			# check if this should be run
			if ('Y' eq missing_file($pileup_out . '.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for GetPileupSummaries...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_get_pileup_summaries_' . $sample,
					cmd	=> $pileup_command,
					modules	=> [$gatk],
					max_time	=> $parameters->{qc}->{time},
					mem		=> $parameters->{qc}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_get_pileup_summaries_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @pileup_jobs, $run_id;
				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping GetPileupSummaries because this has already been completed!\n";
				}

			# find contamination
			my $tumour_pileup = join('/', $patient_directory, $sample . '_pileup.table');
			my $normal_pileup = undef;

			if (scalar(@normal_ids) > 0) {
				if ( !(any { $_ =~ m/$sample/ } @normal_ids) ) {
					$normal_pileup = join('/',
						$patient_directory,
						$normal_ids[0] . '_pileup.table'
						);
					}
				}

			my $contest_output = join('/', $patient_directory, $sample . '_contamination.table');
			my $contest_command = get_estimate_contamination_command(
				tumour		=> $tumour_pileup,
				normal		=> $normal_pileup,
				output		=> $contest_output,
				tmp_dir		=> $tmp_directory
				);

			# check if this should be run
			if ('Y' eq missing_file($contest_output . '.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for CalculateContamination...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_calculate_contamination_' . $sample,
					cmd	=> $contest_command,
					modules	=> [$gatk],
					dependencies	=> join(':', @pileup_jobs),
					max_time	=> ('wgs' eq $tool_data->{seq_type}) ? '12:00:00' : '01:00:00',
					mem		=> ('wgs' eq $tool_data->{seq_type}) ? '4G' : '1G',
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_calculate_contamination_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping CalculateContamination because this has already been completed!\n";
				}

			push @final_outputs, $contest_output;

			}

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			if (scalar(@patient_jobs) == 0) {
				`rm -rf $tmp_directory`;
				} else {

				print $log "Submitting job to clean up temporary/intermediate files...\n";

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
			}

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @final_outputs) . "\n";
		print $log "---\n";
		}

	# collate results
	if ($should_run_final) {

		my $collect_output = join(' ',
			"Rscript $cwd/collect_sequencing_metrics.R",
			'-d', $output_directory,
			'-p', $tool_data->{project_name},
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'combine_qc_output',
			cmd	=> $collect_output,
			modules	=> [$r_version],
			dependencies	=> join(':', @all_jobs),
			mem		=> '4G',
			max_time	=> '12:00:00',
			hpc_driver	=> $args{hpc_driver},
			extra_args	=> [$hpc_group]
			);

		$run_id = submit_job(
			jobname		=> 'combine_qc_output',
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
my ($remove_junk, $dry_run, $help, $no_wait);

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
