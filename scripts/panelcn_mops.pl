#!/usr/bin/env perl
### panelcn_mops.pl ################################################################################
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
use List::Util qw(any sum);
use IO::Handle;

my $cwd = dirname(__FILE__);
require "$cwd/utilities.pl";

our ($reference, $ref_type, $cnmops_path);

####################################################################################################
# version	author		comment
# 1.0		sprokopec	script to run panelCN.mops

### USAGE ##########################################################################################
# panelcn_mops.pl -t tool.yaml -d data.yaml -o /path/to/output/dir -c slurm --remove --dry_run
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
# format command to find read length
sub get_read_lengths_command {
	my %args = (
		input	=> undef,
		@_
		);

	my @read_lengths;

	# extract first 1000000 lines from BAM that pass flag 66
	open (my $bam_fh, "samtools view -f66 $args{input} | awk '{print length(\$10)}' | head -n 1000000 |") or die "Could not run samtools view; did you forget to module load samtools?";

	while (<$bam_fh>) {
		my $line = $_;
		chomp($line);
		$line = abs($line);
		next if ($line > 10000);
		push @read_lengths, $line;
		}

	close($bam_fh);

	return(int(sum(@read_lengths) / scalar(@read_lengths)));
	}

# format command to run panelcn.mops
sub get_panelcn_mops_command {
	my %args = (
		sample_list	=> undef,
		read_length	=> 100,
		intervals_bed	=> undef,
		output_dir	=> undef,
		make_pon	=> 0,
		pon		=> undef,
		@_
		);

	my $mops_command = join(' ',
		'Rscript', $cnmops_path,
		'--sample_list', $args{sample_list},
		'--read_length', $args{read_length},
		'--output_directory', $args{output_dir}
		);

	if ( ('hg38' eq $ref_type) || ('hg19' eq $ref_type) ) {
		$mops_command .= " --genome_build $ref_type";
		} else {
		if ('GRCh37' eq $ref_type) {
			$mops_command .= " --genome_build hg19";
			} elsif ('GRCh38' eq $ref_type) {
			$mops_command .= " --genome_build hg38";
			}
		}

	if (defined($args{intervals_bed})) {
		$mops_command .= " --bed_file $args{intervals_bed}";
		}

	if ($args{make_pon}) {
		$mops_command .= " --make_pon TRUE";
		} elsif (defined($args{pon})) {
		$mops_command .= " --pon $args{pon}";
		}

	return($mops_command);
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
		print "Initiating panelCN.mops pipeline...\n";
		}

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'mops');

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_PanelCN_mops_pipeline.log');

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

		$log_file = join('/', $log_directory, 'run_PanelCN_mops_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running panelCN.mops pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};
	$ref_type  = $tool_data->{ref_type};

	print $log "\n    Target intervals: $tool_data->{intervals_bed}";
	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---\n\n";

	# set tools and versions
	$cnmops_path = "$cwd/run_panelCN_mops.R";
	my $cnmops_r = 'R/4.1.0'; # . $tool_data->{mops_r_version};
	my $r_version	= 'R/'. $tool_data->{r_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{panelcn_mops}->{parameters};

	# get optional HPC group
	my $hpc_group = defined($tool_data->{hpc_group}) ? "-A $tool_data->{hpc_group}" : undef;

	### RUN ###########################################################################################
	my ($run_script, $run_id, $link, $cleanup_cmd, $should_run_final);
	my @all_jobs;

	# get sample data
	my $smp_data = LoadFile($data_config);

	unless($args{dry_run}) {
		print "Processing " . scalar(keys %{$smp_data}) . " patients.\n";
		}

	# create empty lists
	my @sample_sheet_normal;
	my @control_read_lengths;

	# begin by creating panel of normals
	my $pon_directory = join('/', $output_directory, 'PanelOfNormals');
	unless(-e $pon_directory) { make_path($pon_directory); }

	my $pon_link_directory = join('/', $pon_directory, 'bam_links');
	unless(-e $pon_link_directory) { make_path($pon_link_directory); }

	# find all samples in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $link_directory = join('/', $patient_directory, 'bam_links');
		unless(-e $link_directory) { make_path($link_directory); }

		# create some symlinks and add samples to sheet
		foreach my $normal (@normal_ids) {
			my $bam = $smp_data->{$patient}->{normal}->{$normal};
			$link = join('/', $pon_link_directory, basename($bam));
			symlink($bam, $link);

			push @sample_sheet_normal, "$normal\tcontrol\t$bam\n";

			# find average read length
			my $read_length = 151;
			unless($args{dry_run}) {
				$read_length = get_read_lengths_command(input => $bam);
				}
			push @control_read_lengths, $read_length;
			}

		foreach my $tumour (@tumour_ids) {
			my $bam = $smp_data->{$patient}->{tumour}->{$tumour};
			$link = join('/', $link_directory, basename($bam));
			symlink($bam, $link);
			}
		}

	# if no normals were provided, don't bother running further
	if (scalar(@sample_sheet_normal) == 0) {
		die("No normal BAMs provided; can not make PoN so exiting now.");
		}

	# prepare panel of normals
	my $pon_run_id = '';

	my $sample_sheet = join('/', $pon_directory, 'sample_sheet.tsv');
	open(my $fh, '>', $sample_sheet) or die "Cannot open '$sample_sheet' !";

	foreach my $i ( @sample_sheet_normal ) {
		print $fh $i;
		}

	close $fh;

	my $avg_read_length = int(sum(@control_read_lengths) / scalar(@control_read_lengths));
	my $pon_file = join('/', $pon_directory, 'merged_GRanges_count_obj_for_panelcn.RData');
	my $new_targets_bed = join('/', $pon_directory, 'formatted_countWindows.bed');

	my $mops_pon_command = get_panelcn_mops_command(
		sample_list	=> $sample_sheet,
		read_length	=> $avg_read_length,
		intervals_bed	=> $tool_data->{intervals_bed},
		output_dir	=> $pon_directory,
		make_pon	=> 1
		);

	# check if this should be run
	if ('Y' eq missing_file($pon_file)) {

		# record command (in log directory) and then run job
		print $log "Submitting job for panelCN.mops PanelOfNormals...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_panelCN_mops_create_PoN',
			cmd	=> $mops_pon_command,
			modules	=> [$cnmops_r],
			max_time	=> $parameters->{cn_mops}->{time},
			mem		=> $parameters->{cn_mops}->{mem},
			hpc_driver	=> $args{hpc_driver},
			extra_args	=> [$hpc_group]
			);

		$pon_run_id = submit_job(
			jobname		=> 'run_panelCN_mops_create_PoN',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $pon_run_id;
		} else {
		print $log "Skipping panelCN.mops PoN because this has already been completed!\n";
		}

	# process each tumour sample
	my @sample_sheet_tumour;
	my @tumour_read_lengths;

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		# create an array to hold final outputs and all patient job ids
		my (@final_outputs, @patient_jobs);

		my $patient_directory = join('/', $output_directory, $patient);

		# find bams
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		# now, for each tumour sample
		foreach my $sample (@tumour_ids) {

			# if there are any samples to run, we will run the final combine job
			$should_run_final = 1;

			print $log "  SAMPLE: $sample\n\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			# find tumour bam
			my $input_bam = $smp_data->{$patient}->{tumour}->{$sample};

			# generate necessary samples.tsv
			my $sample_sheet = join('/', $sample_directory, 'sample_sheet.tsv');
			open(my $fh, '>', $sample_sheet) or die "Cannot open '$sample_sheet' !";
			print $fh "$sample\ttumour\t$input_bam\n";
			push @sample_sheet_tumour, "$sample\ttumour\t$input_bam\n";
			close $fh;

			# find average read length
			my $read_length = 151;
			unless($args{dry_run}) {
				$read_length = get_read_lengths_command(input => $input_bam);
				}
			push @tumour_read_lengths, $read_length;

			# format panelCN.mops command
			my $output_file = join('/',
				$sample_directory, 
				$sample . '_panelcn.mops_results.tsv'
				);

			my $mops_command = get_panelcn_mops_command(
				sample_list	=> $sample_sheet,
				read_length	=> $read_length,
				intervals_bed	=> $new_targets_bed,
				output_dir	=> $sample_directory,
				pon		=> $pon_file
				);

			$mops_command .= "\n\n" . "md5sum $output_file > $output_file.md5";

			# check if this should be run
			if ('Y' eq missing_file($output_file . '.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for panelCN.mops...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_panelCN_mops_' . $sample,
					cmd	=> $mops_command,
					modules	=> [$cnmops_r],
					dependencies	=> $pon_run_id,
					max_time	=> $parameters->{cn_mops}->{time},
					mem		=> $parameters->{cn_mops}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_panelCN_mops_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping panelCN.mops because this has already been completed!\n";
				}

			push @final_outputs, $output_file;
			}

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			if (scalar(@patient_jobs) > 0) {

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

	# run full cohort as well
	if ('Y' eq $parameters->{run_cohort}) {

		# create directory
		my $cohort_directory = join('/', $output_directory, 'cohort');
		unless(-e $cohort_directory) { make_path($cohort_directory); }

		# write all tumour samples to list
		my $sample_sheet = join('/', $cohort_directory, 'sample_sheet.tsv');
		open(my $fh, '>', $sample_sheet) or die "Cannot open '$sample_sheet' !";

		foreach my $i ( @sample_sheet_tumour ) {
			print $fh $i;
			}

		close $fh;

		# find average read length
		my $avg_read_length = int(sum(@tumour_read_lengths) / scalar(@tumour_read_lengths));

		# format panelCN.mops command
		my $output_file = join('/',
			$cohort_directory, 
			'cohort_panelcn.mops_results.tsv'
			);

		# write command
		my $mops_command = get_panelcn_mops_command(
			sample_list	=> $sample_sheet,
			read_length	=> $avg_read_length,
			intervals_bed	=> $new_targets_bed,
			output_dir	=> $cohort_directory,
			pon		=> $pon_file
			);

		$mops_command .= "\n\n" . "md5sum $output_file > $output_file.md5";

		# check if this should be run
		if ('Y' eq missing_file($output_file . '.md5')) {

			# record command (in log directory) and then run job
			print $log "Submitting job for panelCN.mops...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_panelCN_mops_cohort',
				cmd	=> $mops_command,
				modules	=> [$cnmops_r],
				dependencies	=> $pon_run_id,
				max_time	=> $parameters->{cn_mops}->{time},
				mem		=> $parameters->{cn_mops}->{mem},
				hpc_driver	=> $args{hpc_driver},
				extra_args	=> [$hpc_group]
				);

			$run_id = submit_job(
				jobname		=> 'run_panelCN_mops_cohort',
				shell_command	=> $run_script,
				hpc_driver	=> $args{hpc_driver},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);

			push @all_jobs, $run_id;
			} else {
			print $log "Skipping panelCN.mops because this has already been completed!\n";
			}
		}

	# collate results
	if ($should_run_final) {

		my $collect_output = join(' ',
			"Rscript $cwd/collect_panelCN_mops_output.R",
			'-d', $output_directory,
			'-p', $tool_data->{project_name}
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'combine_panelCN_mops_output',
			cmd	=> $collect_output,
			modules	=> [$r_version],
			dependencies	=> join(':', @all_jobs),
			mem		=> '4G',
			max_time	=> '12:00:00',
			hpc_driver	=> $args{hpc_driver},
			extra_args	=> [$hpc_group]
			);

		$run_id = submit_job(
			jobname		=> 'combine_panelCN_mops_output',
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
	del_intermediates	=> 0, # $remove_junk,
	dry_run			=> $dry_run,
	no_wait			=> $no_wait
	);
