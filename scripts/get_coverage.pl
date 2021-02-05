#!/usr/bin/env perl
### get_coverage.pl ################################################################################
use AutoLoader 'AUTOLOAD';
use strict;
use warnings;
use Carp;
use Getopt::Std;
use Getopt::Long;
use POSIX qw(strftime);
use File::Basename;
use File::Path qw(make_path);
use YAML qw(LoadFile);
use List::Util qw(any);
use IO::Handle;

my $cwd = dirname($0);
require "$cwd/utilities.pl";

####################################################################################################
# version	author		comment
# 1.0		sprokopec	script to run DepthOfCoverage on GATK processed bams
# 1.1		sprokopec	added help msg and cleaned up code
# 1.2		sprokopec	minor updates for tool config

### USAGE ##########################################################################################
# get_coverage.pl -t tool.yaml -d data.yaml -o /path/to/output/dir -c slurm --remove --dry_run
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
# format command to extract callability metrics (exome data only)
sub get_callableLoci_command {
	my %args = (
		input		=> undef,
		output		=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		reference	=> undef,
		intervals	=> undef,
		@_
		);

	my $coverage_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $gatk_dir/GenomeAnalysisTK.jar -T DiagnoseTargets',
		'-R', $args{reference},
		'-I', $args{input},
		'-o', $args{output},
		'--intervals', $args{intervals},
		'--minimum_coverage 10',
		'--maximum_coverage 1000000' #default is 1073741823
		);

	return($coverage_command);
	}

# format command to extract coverage metrics
sub get_coverage_command {
	my %args = (
		input		=> undef,
		output		=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		reference	=> undef,
		intervals	=> undef,
		@_
		);

	my $coverage_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $gatk_dir/GenomeAnalysisTK.jar -T DepthOfCoverage',
		'-R', $args{reference},
		'-I', $args{input},
		'-o', $args{output},
		'-omitBaseOutput -omitIntervals -omitLocusTable',
		'-nt 2',
		'-pt sample -pt readgroup'
		);

	if (defined($args{intervals})) {

		$coverage_command .= ' ' . join(' ',
			'--intervals', $args{intervals},
			'--interval_padding 100'
			);
		}

	return($coverage_command);
	}

# format command to find callable bases
# start with finding callable bases per sample
sub find_callable_bases_step1 {
	my %args = (
		input		=> undef,
		output_stem	=> undef,
		min_depth	=> undef,
		tmp_dir		=> undef,
		@_
		);

	my $output1 = join('/', $args{tmp_dir}, $args{output_stem} . "\_$args{min_depth}.bed");
	my $output2 = join('/', $args{tmp_dir}, $args{output_stem} . "\_$args{min_depth}\_collapsed.bed");
	my $output3 = join('/', $args{tmp_dir}, $args{output_stem} . '_mincov_collapsed_sorted.bed');

	my $cb_command = join(' ',
		'samtools view -b', $args{input},
		'| bedtools genomecov -bg -ibam -',
		'| awk \'$4 >=', $args{min_depth},
		'{print $0}\' >', $output1
		);

	$cb_command .= ";\n" . join(' ',
		'bedtools merge',
		'-i', $output1,
		'>', $output2
		);

	$cb_command .= ";\n" . join(' ',
		'sort -k1,1V -k2,2n', $output2,
		'>', $output3
		);

	$cb_command .= ";\n" . join(' ',
		'md5sum', $output3,
		'>', $output3 . '.md5'
		);

	return($cb_command);
	}

# and finish by finding callable bases across all samples for a patient
sub find_callable_bases_step2 {
	my %args = (
		input_files	=> undef,
		sample_names	=> undef,
		output		=> undef,
		intervals	=> undef,
		@_
		);

	my ($input, $smps);
	if (defined($args{intervals})) {
		$input = join(' ', $args{intervals}, @{$args{input_files}});
		$smps = join(' ', 'TargetRegions', @{$args{sample_names}});
		} else {
		$input = join(' ', @{$args{input_files}});
		$smps = join(' ', @{$args{sample_names}});
		}

	my $cb_command = join(' ',
		'bedtools multiinter',
		'-i', $input,
		'-header -names', $smps,
		'>', $args{output}
		);

	$cb_command .= ";\n\n" . join(' ',
		'md5sum', $args{output},
		'>', $args{output} . '.md5'
		);

	return($cb_command);
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

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'gatk');

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_CoverageMetrics_pipeline.log');

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

		$log_file = join('/', $log_directory, 'run_CoverageMetrics_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running Coverage pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";
	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---\n";

	# set tools and versions
	my $gatk	= 'gatk/' . $tool_data->{gatk_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};
	my $bedtools	= 'bedtools/' . $tool_data->{bedtools_version};
	my $r_version	= 'R/' . $tool_data->{r_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{bamqc}->{parameters};

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $run_id, $link, $cleanup_cmd);
	my @all_jobs;

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
		my (@final_outputs, @patient_jobs, @cb_jobs, @patient_cb_files);

		my @sample_ids = @tumour_ids;
		push @sample_ids, @normal_ids;
		@sample_ids = sort(@sample_ids);

		foreach my $sample (@sample_ids) {

			print $log "  SAMPLE: $sample\n\n";

			my $type;
			if ( (any { $_ =~ m/$sample/ } @normal_ids) ) {
				$type = 'normal';
				} else {
				$type = 'tumour';
				}

			# Run DepthOfCoverage on all input BAMs
			my $coverage_out = join('/', $patient_directory, $sample . '_DepthOfCoverage');

			my $cov_command = get_coverage_command(
				input		=> $smp_data->{$patient}->{$type}->{$sample},
				output		=> $coverage_out,
				reference	=> $tool_data->{reference},
				intervals	=> $tool_data->{intervals_bed},
				java_mem	=> $parameters->{coverage}->{java_mem},
				tmp_dir		=> $tmp_directory
				);
				
			my $md5_cmds = "  " . join("\n  ",
				"md5sum $coverage_out\.read_group_statistics > $coverage_out\.read_group_statistics.md5",
				"md5sum $coverage_out\.read_group_summary > $coverage_out\.read_group_summary.md5",
				"md5sum $coverage_out\.sample_statistics > $coverage_out\.sample_statistics.md5",
				"md5sum $coverage_out\.sample_summary > $coverage_out\.sample_summary.md5"
				);

			$cov_command .= "\n" . check_java_output(
				extra_cmd => $md5_cmds
				);

			# check if this should be run
			if ('Y' eq missing_file($coverage_out . '.sample_summary.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for DepthOfCoverage...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_depth_of_coverage_' . $sample,
					cmd	=> $cov_command,
					modules	=> [$gatk],
					cpus_per_taks	=> 2,
					max_time	=> $parameters->{coverage}->{time},
					mem		=> $parameters->{coverage}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_depth_of_coverage_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping DepthOfCoverage because this has already been completed!\n";
				}

			push @final_outputs, $coverage_out . ".read_group_statistics";

			## Find CallableBases on all input BAMs
			my $cb_output = join('/', $tmp_directory, $sample . '_mincov_collapsed_sorted.bed');

			my $cb_command = find_callable_bases_step1(
				input		=> $smp_data->{$patient}->{$type}->{$sample},
				output_stem	=> $sample,
				min_depth	=> $parameters->{callable_bases}->{min_depth}->{$type},
				tmp_dir		=> $tmp_directory
				);

			push @patient_cb_files, $sample . "_mincov_collapsed_sorted.bed";

			# check if this should be run
			if (
				('Y' eq missing_file($cb_output . '.md5')) &&
				('Y' eq missing_file("$patient_directory/callable_bases.tar.gz"))
				) {

				# record command (in log directory) and then run job
				print $log "Submitting job for Callable Bases...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_get_callable_bases_' . $sample,
					cmd	=> $cb_command,
					modules	=> [$samtools, $bedtools],
					max_time	=> $parameters->{callable_bases}->{time},
					mem		=> $parameters->{callable_bases}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_get_callable_bases_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @cb_jobs, $run_id;
				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping Get Callable Bases because this has already been completed!\n";
				}
			}

		# run callable bases per patient (intersect) ONLY IF there are multiple samples for this patient
		my $cb_intersect = join('/', $patient_directory, 'CallableBases.tsv');

		if ( (scalar(@sample_ids) == 1) && (!defined($tool_data->{intervals_bed})) ) {
			`mv $patient_cb_files[0] $cb_intersect`;
			`mv $patient_cb_files[0].md5 $cb_intersect.md5`;
			} elsif ( (scalar(@sample_ids) > 1) || (defined($tool_data->{intervals_bed})) ) {

			my $cb_command2 = "\ncd $tmp_directory\n\n";
			$cb_command2 .= find_callable_bases_step2(
				input_files	=> \@patient_cb_files,
				sample_names	=> \@sample_ids,
				output		=> $cb_intersect,
				intervals	=> $tool_data->{intervals_bed}
				);

			$cb_command2 .= "\n\n" . join(' ',
				"tar -czf $patient_directory/callable_bases.tar.gz",
				"*_mincov_collapsed_sorted.bed*"
				);

			if ('Y' eq missing_file($cb_intersect . '.md5')) {

				print $log "Submitting job for CallableBases Intersect...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_callable_bases_intersect_' . $patient,
					cmd	=> $cb_command2,
					modules	=> [$samtools, $bedtools],
					dependencies	=> join(':', @cb_jobs),
					max_time	=> $parameters->{callable_bases}->{time},
					mem		=> $parameters->{callable_bases}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_callable_bases_intersect_' . $patient,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);
				}
			else {
				print $log "Skipping CallableBases Intersect because this has already been completed!\n";
				}

			push @final_outputs, $cb_intersect;

			}

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			if (scalar(@patient_jobs) == 0) {
				`rm -rf $tmp_directory`;
				} else {

				print $log "Submitting job to clean up temporary/intermediate files...\n";

				# make sure final output exists before removing intermediate files!
				my @files_to_check;
				foreach my $tmp ( @final_outputs ) {
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
					dependencies	=> join(':', @patient_jobs),
					mem		=> '256M',
					hpc_driver	=> $args{hpc_driver},
					kill_on_error	=> 0
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
	my $collect_output = join(' ',
		"Rscript $cwd/collect_coverage_output.R",
		'-d', $output_directory,
		'-p', $tool_data->{project_name},
		"\n\nRscript $cwd/count_callable_bases.R",
		'-d', $output_directory,
		'-p', $tool_data->{project_name}
		);

	$run_script = write_script(
		log_dir	=> $log_directory,
		name	=> 'combine_coverage_output',
		cmd	=> $collect_output,
		modules	=> [$r_version],
		dependencies	=> join(':', @all_jobs),
		mem		=> '4G',
		max_time	=> '12:00:00',
		hpc_driver	=> $args{hpc_driver}
		);

	$run_id = submit_job(
		jobname		=> 'combine_coverage_output',
		shell_command	=> $run_script,
		hpc_driver	=> $args{hpc_driver},
		dry_run		=> $args{dry_run},
		log_file	=> $log
		);

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
			kill_on_error	=> 0
			);

		$run_id = submit_job(
			jobname		=> 'output_job_metrics',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		# wait until it finishes
		unless ($args{no_wait}) {

			my $complete = 0;
			my $timeouts = 0;

			while (!$complete && $timeouts < 20 ) {
				sleep(30);
				my $status = `sacct --format='State' -j $run_id`;

				# if final job has finished successfully:
				if ($status =~ m/COMPLETED/s) { $complete = 1; }
				# if we run into a server connection error (happens rarely with sacct)
				# increment timeouts (if we continue to repeatedly timeout, we will exit)
				elsif ($status =~ m/Connection timed out/) {
					$timeouts++;
					}
				# if the job is still pending or running, try again in a bit
				# but also reset timeouts, because we only care about consecutive timeouts
				elsif ($status =~ m/PENDING|RUNNING/) {
					$timeouts = 0;
					}
				# if none of the above, we will exit with an error
				else {
					die("Final Coverage accounting job: $run_id finished with errors.");
					}
				}
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
